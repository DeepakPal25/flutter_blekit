import 'package:flutter/services.dart';
import 'package:flutter_blekit/flutter_blekit.dart';
import 'package:flutter_blekit/src/messages.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const _host = 'dev.flutter.pigeon.flutter_blekit.BleHostApi';
const _flutter = 'dev.flutter.pigeon.flutter_blekit.BleFlutterApi';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Calls recorded per host method, as their argument lists.
  late Map<String, List<List<Object?>>> calls;

  /// Installs a fake host method. [reply] returns the value, or throws
  /// a [PlatformException] to send an error envelope.
  void host(String method, [Object? Function(List<Object?> args)? reply]) {
    messenger.setMockDecodedMessageHandler<Object?>(
      BasicMessageChannel('$_host.$method', BleHostApi.pigeonChannelCodec),
      (message) async {
        final args = (message as List<Object?>?) ?? const [];
        (calls[method] ??= []).add(args);
        try {
          return [reply?.call(args)];
        } on PlatformException catch (e) {
          return [e.code, e.message, e.details];
        }
      },
    );
  }

  /// Delivers a platform → Dart event, as the native side would.
  Future<void> emit(String method, Object? arg) async {
    await messenger.handlePlatformMessage(
      '$_flutter.$method',
      BleFlutterApi.pigeonChannelCodec.encodeMessage([arg]),
      (_) {},
    );
  }

  setUp(() {
    calls = {};
    for (final m in [
      'startScan',
      'stopScan',
      'connect',
      'disconnect',
      'setNotify',
      'writeValue',
      // Returns null, so `name` falls back to the advertised/cached name.
      'peripheralName',
    ]) {
      host(m);
    }
  });

  test('state and stateUpdates map platform states', () async {
    host('getState', (_) => BleManagerStateMessage.poweredOff);
    final central = LiveBleCentral();
    expect(await central.state, BleManagerState.poweredOff);
    final states = record(central.stateUpdates());
    await settle();
    await emit('onManagerStateChanged', BleManagerStateMessage.poweredOn);
    await settle();
    expect(states, [BleManagerState.poweredOff, BleManagerState.poweredOn]);
  });

  test('scan starts on listen, maps discoveries, stops on cancel', () async {
    final central = LiveBleCentral();
    final found = record(central.scan(services: [BleUuid.heartRate]));
    await settle();
    expect(calls['startScan'], [
      [
        ['180D'],
      ],
    ]);
    await emit(
      'onDiscovery',
      DiscoveryMessage(
        peripheralId: 'AA:BB',
        advertisement: AdvertisementDataMessage(
          localName: 'Simulated HRM',
          serviceUuids: ['0000180d-0000-1000-8000-00805f9b34fb'],
          isConnectable: true,
        ),
        rssi: -55,
      ),
    );
    await settle();
    expect(found, hasLength(1));
    final d = found.single;
    expect(d.peripheral.identifier, 'AA:BB');
    expect(await d.peripheral.name, 'Simulated HRM');
    expect(d.advertisement.serviceUuids, [BleUuid.heartRate]);
    expect(d.advertisement.isConnectable, isTrue);
    expect(d.rssi, -55);

    await central.stopScan();
    expect(calls['stopScan'], isNotEmpty);
  });

  test('connect passes the timeout in milliseconds', () async {
    final central = LiveBleCentral();
    host('retrievePeripheral', (_) => PeripheralInfoMessage(peripheralId: 'X'));
    final p = (await central.retrievePeripheral('X'))!;
    await central.connect(p, timeout: const Duration(seconds: 3));
    expect(calls['connect'], [
      ['X', 3000],
    ]);
    await central.disconnect(p);
    expect(calls['disconnect'], [
      ['X'],
    ]);
  });

  test(
    'retrievePeripheral returns null when the platform has no record',
    () async {
      host('retrievePeripheral', (_) => null);
      expect(await LiveBleCentral().retrievePeripheral('nope'), isNull);
    },
  );

  test('platform errors surface as typed BleErrors', () async {
    host('connect', (_) => throw PlatformException(code: 'connectionTimeout'));
    host('retrievePeripheral', (_) => PeripheralInfoMessage(peripheralId: 'X'));
    final central = LiveBleCentral();
    final p = (await central.retrievePeripheral('X'))!;
    await expectLater(
      central.connect(p),
      throwsA(isA<ConnectionTimeoutError>()),
    );
  });

  test('disconnection events carry mapped errors', () async {
    final central = LiveBleCentral();
    final drops = record(central.disconnections());
    await emit(
      'onDisconnection',
      DisconnectionMessage(
        peripheralId: 'X',
        error: BleErrorMessage(
          code: BleErrorCodeMessage.disconnected,
          message: 'GATT 8',
          isExpectedDisconnect: false,
        ),
      ),
    );
    await emit('onDisconnection', DisconnectionMessage(peripheralId: 'Y'));
    await settle();
    expect(drops[0].identifier, 'X');
    expect(
      drops[0].error,
      const DisconnectedError(isExpected: false, reason: 'GATT 8'),
    );
    expect(drops[1].error, isNull);
  });

  test('notifications are routed by peripheral and normalised UUID', () async {
    host(
      'retrievePeripheral',
      (args) => PeripheralInfoMessage(peripheralId: args[0]! as String),
    );
    final central = LiveBleCentral();
    final a = (await central.retrievePeripheral('A'))!;
    final values = record(a.notifications(BleUuid.heartRateMeasurement));
    await a.setNotify(true, BleUuid.heartRateMeasurement);
    expect(calls['setNotify'], [
      ['A', '2A37', true],
    ]);
    await emit(
      'onNotificationValue',
      NotificationMessage(
        peripheralId: 'A',
        characteristicUuid: '00002a37-0000-1000-8000-00805f9b34fb',
        value: Uint8List.fromList([0, 70]),
      ),
    );
    await emit(
      'onNotificationValue',
      NotificationMessage(
        peripheralId: 'B',
        characteristicUuid: '2A37',
        value: Uint8List.fromList([0, 99]),
      ),
    );
    await settle();
    expect(values, [
      [0, 70],
    ]);
  });

  test('restoration events are buffered for late subscribers', () async {
    final central = LiveBleCentral();
    await emit(
      'onRestoration',
      RestorationMessage(
        peripheralIds: ['A'],
        peripheralNames: ['HRM'],
        scanServiceUuids: ['180D'],
      ),
    );
    await settle();
    final events = record(central.restorationEvents());
    await settle();
    expect(events, hasLength(1));
    expect(events.single.peripherals.single.identifier, 'A');
    expect(await events.single.peripherals.single.name, 'HRM');
    expect(events.single.scanServices, [BleUuid.heartRate]);
  });

  group('bleErrorFromPlatform', () {
    BleError map(String code, [String? message]) =>
        bleErrorFromPlatform(PlatformException(code: code, message: message));

    test('maps every code', () {
      expect(
        map('bluetoothUnavailable', 'poweredOff'),
        const BluetoothUnavailableError(BleManagerState.poweredOff),
      );
      expect(
        map('bluetoothUnavailable', 'garbage'),
        const BluetoothUnavailableError(BleManagerState.unknown),
      );
      expect(map('connectionTimeout'), const ConnectionTimeoutError());
      expect(
        map('disconnected', 'link lost'),
        const DisconnectedError(isExpected: false, reason: 'link lost'),
      );
      expect(
        map('peripheralNotFound', 'X'),
        const PeripheralNotFoundError('X'),
      );
      expect(
        map('serviceNotFound', '180d'),
        ServiceNotFoundError(BleUuid.heartRate),
      );
      expect(
        map('characteristicNotFound', '2A37'),
        CharacteristicNotFoundError(BleUuid.heartRateMeasurement),
      );
      expect(
        map('reconnectionExhausted', '4'),
        const ReconnectionExhaustedError(4),
      );
      expect(
        map('reconnectionExhausted', 'x'),
        const ReconnectionExhaustedError(0),
      );
      expect(map('cancelled'), const CancelledError());
      expect(
        map('underlying', 'status 133'),
        const UnderlyingBleError('status 133'),
      );
      expect(map('weird'), const UnderlyingBleError('weird'));
    });
  });
}
