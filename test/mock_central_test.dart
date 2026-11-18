import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blekit/flutter_blekit.dart';
import 'package:flutter_blekit/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late MockBleCentral central;
  setUp(() => central = MockBleCentral());

  test('scan delivers discoveries and closes on stopScan', () async {
    final device = SimulatedPeripheral(identifier: 'A', name: 'HRM');
    final found = <BleDiscovery>[];
    final done = Completer<void>();
    central.scan().listen(found.add, onDone: done.complete);
    central.simulateDiscovery(
      device,
      advertisement: const AdvertisementData(localName: 'HRM'),
      rssi: -42,
    );
    await settle();
    await central.stopScan();
    await done.future.timeout(const Duration(seconds: 1));
    expect(found, hasLength(1));
    expect(found.single.peripheral.identifier, 'A');
    expect(found.single.advertisement.localName, 'HRM');
    expect(found.single.rssi, -42);
    expect(await central.retrievePeripheral('A'), same(device));
  });

  test('restoration events are buffered for late subscribers', () async {
    final a = SimulatedPeripheral(identifier: 'A');
    central.simulateRestoration([a], scanServices: [BleUuid.heartRate]);
    await settle();
    final events = record(central.restorationEvents());
    await settle();
    expect(events, hasLength(1));
    expect(events.single.peripherals.single.identifier, 'A');
    expect(events.single.scanServices, [BleUuid.heartRate]);
  });

  test('stateUpdates starts with the current state', () async {
    central.simulateState(BleManagerState.poweredOff);
    final states = record(central.stateUpdates());
    central.simulateState(BleManagerState.poweredOn);
    await settle();
    expect(states, [BleManagerState.poweredOff, BleManagerState.poweredOn]);
    expect(await central.state, BleManagerState.poweredOn);
  });

  test('disconnect emits an expected drop only when connected', () async {
    final device = SimulatedPeripheral(identifier: 'A');
    final drops = record(central.disconnections());
    await central.disconnect(device);
    await central.connect(device);
    expect(central.isConnected('A'), isTrue);
    await central.disconnect(device);
    await settle();
    expect(drops, hasLength(1));
    expect(drops.single.identifier, 'A');
    expect(drops.single.isExpected, isTrue);
    expect(central.isConnected('A'), isFalse);
  });

  test(
    'simulateDisconnect carries a reason only for unexpected drops',
    () async {
      final device = SimulatedPeripheral(identifier: 'A');
      final drops = record(central.disconnections());
      central.simulateDisconnect(device);
      central.simulateDisconnect(device, expected: true);
      await settle();
      expect(
        drops[0].error,
        const DisconnectedError(isExpected: false, reason: 'simulated drop'),
      );
      expect(drops[1].error, const DisconnectedError(isExpected: true));
    },
  );

  test('connect behaviours run in order, then connects succeed', () async {
    final device = SimulatedPeripheral(identifier: 'A');
    central.enqueueConnectBehaviors([
      ConnectBehavior.timeout,
      const ConnectBehavior.fail(UnderlyingBleError('x')),
    ]);
    await expectLater(
      central.connect(device),
      throwsA(isA<ConnectionTimeoutError>()),
    );
    await expectLater(
      central.connect(device),
      throwsA(isA<UnderlyingBleError>()),
    );
    await central.connect(device);
    expect(central.isConnected('A'), isTrue);
    expect(central.connectCallCount, 3);
  });

  test('retrievePeripheral returns null for unknown ids', () async {
    expect(await central.retrievePeripheral('nope'), isNull);
    final device = SimulatedPeripheral(identifier: 'B');
    central.add(device);
    expect(await central.retrievePeripheral('B'), same(device));
  });

  group('SimulatedPeripheral', () {
    final uuid = BleUuid.batteryLevel;

    test('read and write errors fire once', () async {
      final d = SimulatedPeripheral(
        values: {
          uuid: Uint8List.fromList([1]),
        },
      );
      d.readError = const UnderlyingBleError('r');
      d.writeError = const UnderlyingBleError('w');
      await expectLater(d.readValue(uuid), throwsA(isA<UnderlyingBleError>()));
      expect(await d.readValue(uuid), [1]);
      await expectLater(
        d.writeValue(Uint8List.fromList([2]), uuid),
        throwsA(isA<UnderlyingBleError>()),
      );
      await d.writeValue(Uint8List.fromList([2]), uuid);
      expect(d.valueFor(uuid), [2]);
    });

    test('reading an unknown characteristic throws', () async {
      final d = SimulatedPeripheral();
      await expectLater(
        d.readValue(uuid),
        throwsA(isA<CharacteristicNotFoundError>()),
      );
    });

    test('notifies only while notifications are enabled', () async {
      final d = SimulatedPeripheral();
      final values = record(d.notifications(uuid));
      d.simulateValue(Uint8List.fromList([1]), uuid);
      await d.setNotify(true, uuid);
      d.simulateValue(Uint8List.fromList([2]), uuid);
      await d.setNotify(false, uuid);
      d.simulateValue(Uint8List.fromList([3]), uuid);
      await settle();
      expect(values, [
        [2],
      ]);
      expect(d.valueFor(uuid), [3]);
    });

    test('discovery filters by the requested UUIDs', () async {
      final d = SimulatedPeripheral(
        services: {
          BleUuid.heartRate: [BleUuid.heartRateMeasurement],
        },
      );
      expect(await d.discoverServices(), [BleUuid.heartRate]);
      expect(await d.discoverServices([BleUuid.batteryService]), isEmpty);
      expect(
        await d.discoverCharacteristics(null, service: BleUuid.heartRate),
        [BleUuid.heartRateMeasurement],
      );
      await expectLater(
        d.discoverCharacteristics(null, service: BleUuid.batteryService),
        throwsA(isA<ServiceNotFoundError>()),
      );
    });

    test('generates distinct random identifiers', () {
      expect(
        SimulatedPeripheral().identifier,
        isNot(SimulatedPeripheral().identifier),
      );
    });
  });
}
