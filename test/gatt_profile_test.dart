import 'dart:typed_data';

import 'package:flutter_blekit/flutter_blekit.dart';
import 'package:flutter_blekit/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  late SimulatedPeripheral device;

  setUp(() {
    device = SimulatedPeripheral(
      identifier: 'HRM',
      services: {
        BleUuid.heartRate: [BleUuid.heartRateMeasurement],
        BleUuid.batteryService: [BleUuid.batteryLevel],
        BleUuid.deviceInformation: [BleUuid.manufacturerName],
      },
      values: {
        BleUuid.batteryLevel: bytes([87]),
        BleUuid.manufacturerName: bytes('Acme'.codeUnits),
      },
    );
  });

  test('reads on attach and delivers notifications', () async {
    final battery = <int>[];
    final hr = <int>[];
    String? maker;
    final session = await device.attach(
      GattProfile([
        service(BleUuid.batteryService, [
          characteristic(BleUuid.batteryLevel)
              .readAs(BatteryLevel.fromBytes, (b) => battery.add(b.percent))
              .notifyAs(BatteryLevel.fromBytes, (b) => battery.add(b.percent)),
        ]),
        StandardProfile.heartRate((m) => hr.add(m.beatsPerMinute)),
        StandardProfile.deviceInformation(manufacturer: (s) => maker = s),
      ]),
    );
    expect(battery, [87]);
    expect(maker, 'Acme');
    expect(device.isNotifying(BleUuid.heartRateMeasurement), isTrue);
    expect(device.isNotifying(BleUuid.batteryLevel), isTrue);

    device.simulateValue(bytes([0x00, 72]), BleUuid.heartRateMeasurement);
    device.simulateValue(bytes([86]), BleUuid.batteryLevel);
    await settle();
    expect(hr, [72]);
    expect(battery, [87, 86]);
    expect(session.isCancelled, isFalse);
  });

  test('cancel() stops delivery and is idempotent', () async {
    final hr = <int>[];
    final session = await device.attach(
      GattProfile([StandardProfile.heartRate((m) => hr.add(m.beatsPerMinute))]),
    );
    device.simulateValue(bytes([0x00, 60]), BleUuid.heartRateMeasurement);
    await settle();
    await session.cancel();
    await session.cancel();
    expect(session.isCancelled, isTrue);
    device.simulateValue(bytes([0x00, 61]), BleUuid.heartRateMeasurement);
    await settle();
    expect(hr, [60]);
  });

  test('notifyAs skips malformed payloads and keeps delivering', () async {
    final hr = <int>[];
    await device.attach(
      GattProfile([StandardProfile.heartRate((m) => hr.add(m.beatsPerMinute))]),
    );
    device.simulateValue(bytes([]), BleUuid.heartRateMeasurement);
    device.simulateValue(bytes([0x01, 0x10]), BleUuid.heartRateMeasurement);
    device.simulateValue(bytes([0x00, 90]), BleUuid.heartRateMeasurement);
    await settle();
    expect(hr, [90]);
  });

  test('a throwing handler does not end the subscription', () async {
    final seen = <int>[];
    await device.attach(
      GattProfile([
        service(BleUuid.heartRate, [
          characteristic(BleUuid.heartRateMeasurement).notify((v) {
            seen.add(v[1]);
            if (v[1] == 1) throw StateError('handler bug');
          }),
        ]),
      ]),
    );
    device.simulateValue(bytes([0, 1]), BleUuid.heartRateMeasurement);
    device.simulateValue(bytes([0, 2]), BleUuid.heartRateMeasurement);
    await settle();
    expect(seen, [1, 2]);
  });

  test('handlers for one characteristic run one at a time, in order', () async {
    final log = <String>[];
    await device.attach(
      GattProfile([
        service(BleUuid.heartRate, [
          characteristic(BleUuid.heartRateMeasurement).notify((v) async {
            log.add('start ${v[1]}');
            await Future<void>.delayed(Duration.zero);
            log.add('end ${v[1]}');
          }),
        ]),
      ]),
    );
    device.simulateValue(bytes([0, 1]), BleUuid.heartRateMeasurement);
    device.simulateValue(bytes([0, 2]), BleUuid.heartRateMeasurement);
    await settle();
    expect(log, ['start 1', 'end 1', 'start 2', 'end 2']);
  });

  test('a missing service throws ServiceNotFoundError', () async {
    await expectLater(
      device.attach(GattProfile([service(BleUuid.cyclingPower)])),
      throwsA(isA<ServiceNotFoundError>()),
    );
  });

  test('a read error propagates out of attach', () async {
    device.readError = const UnderlyingBleError('read failed');
    await expectLater(
      device.attach(
        GattProfile([
          service(BleUuid.batteryService, [
            characteristic(BleUuid.batteryLevel).read((_) {}),
          ]),
        ]),
      ),
      throwsA(isA<UnderlyingBleError>()),
    );
  });

  test('a failing attach cancels subscriptions it already made', () async {
    final hr = <int>[];
    await expectLater(
      device.attach(
        GattProfile([
          StandardProfile.heartRate((m) => hr.add(m.beatsPerMinute)),
          service(BleUuid.cyclingPower),
        ]),
      ),
      throwsA(isA<ServiceNotFoundError>()),
    );
    device.simulateValue(bytes([0x00, 70]), BleUuid.heartRateMeasurement);
    await settle();
    expect(hr, isEmpty);
  });
}
