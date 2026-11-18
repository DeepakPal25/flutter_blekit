import 'dart:async';

import 'package:flutter/services.dart';

import '../core/central.dart';
import '../core/errors.dart';
import '../core/manager_state.dart';
import '../core/uuid.dart';
import '../messages.g.dart';

/// Converts a platform-channel failure into a typed [BleError].
///
/// The native side sends the `BleErrorCodeMessage` case name as the
/// [PlatformException.code] and the detail (reason, UUID, state name or
/// attempt count) as the message.
BleError bleErrorFromPlatform(PlatformException e) {
  final message = e.message;
  switch (e.code) {
    case 'bluetoothUnavailable':
      return BluetoothUnavailableError(
        BleManagerState.values.firstWhere(
          (s) => s.name == message,
          orElse: () => BleManagerState.unknown,
        ),
      );
    case 'connectionTimeout':
      return const ConnectionTimeoutError();
    case 'disconnected':
      return DisconnectedError(isExpected: false, reason: message);
    case 'peripheralNotFound':
      return PeripheralNotFoundError(message);
    case 'serviceNotFound':
      return ServiceNotFoundError(BleUuid(message ?? ''));
    case 'characteristicNotFound':
      return CharacteristicNotFoundError(BleUuid(message ?? ''));
    case 'reconnectionExhausted':
      return ReconnectionExhaustedError(int.tryParse(message ?? '') ?? 0);
    case 'cancelled':
      return const CancelledError();
    default:
      return UnderlyingBleError(message ?? e.code);
  }
}

BleError _errorFromMessage(BleErrorMessage m) => switch (m.code) {
  BleErrorCodeMessage.bluetoothUnavailable => BluetoothUnavailableError(
    _state(m.managerState ?? BleManagerStateMessage.unknown),
  ),
  BleErrorCodeMessage.connectionTimeout => const ConnectionTimeoutError(),
  BleErrorCodeMessage.disconnected => DisconnectedError(
    isExpected: m.isExpectedDisconnect ?? false,
    reason: m.message,
  ),
  BleErrorCodeMessage.peripheralNotFound => const PeripheralNotFoundError(),
  BleErrorCodeMessage.serviceNotFound => ServiceNotFoundError(
    BleUuid(m.uuid ?? ''),
  ),
  BleErrorCodeMessage.characteristicNotFound => CharacteristicNotFoundError(
    BleUuid(m.uuid ?? ''),
  ),
  BleErrorCodeMessage.reconnectionExhausted => ReconnectionExhaustedError(
    m.attempts ?? 0,
  ),
  BleErrorCodeMessage.cancelled => const CancelledError(),
  BleErrorCodeMessage.underlying => UnderlyingBleError(m.message ?? ''),
};

BleManagerState _state(BleManagerStateMessage m) =>
    BleManagerState.values.byName(m.name);

/// Runs [call], rethrowing platform failures as [BleError].
Future<T> _guard<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on PlatformException catch (e) {
    throw bleErrorFromPlatform(e);
  }
}

/// The production [BleCentral], backed by Core Bluetooth on iOS (via
/// SwiftBLEKit) and `BluetoothGatt` on Android.
///
/// Create one per app; it registers itself as the receiver of platform
/// events.
class LiveBleCentral implements BleCentral {
  LiveBleCentral({BinaryMessenger? binaryMessenger})
    : _host = BleHostApi(binaryMessenger: binaryMessenger) {
    BleFlutterApi.setUp(_Receiver(this), binaryMessenger: binaryMessenger);
  }

  final BleHostApi _host;
  final Map<String, LiveBlePeripheral> _peripherals = {};
  final List<BleRestorationState> _restorations = [];

  final StreamController<BleManagerState> _stateChanges =
      StreamController<BleManagerState>.broadcast();
  final StreamController<BleDisconnection> _drops =
      StreamController<BleDisconnection>.broadcast();
  final StreamController<NotificationMessage> _notifications =
      StreamController<NotificationMessage>.broadcast();
  final StreamController<BleRestorationState> _restorationChanges =
      StreamController<BleRestorationState>.broadcast();
  StreamController<BleDiscovery>? _scan;

  LiveBlePeripheral _peripheral(String id, [String? name]) {
    final p = _peripherals.putIfAbsent(id, () => LiveBlePeripheral._(this, id));
    if (name != null) p._cachedName = name;
    return p;
  }

  /// Asks for the runtime permissions BLE needs (Android 12+ scan/connect,
  /// or location on older Android). Always true on iOS, where Core Bluetooth
  /// prompts on first use.
  Future<bool> requestPermissions() => _guard(_host.requestPermissions);

  @override
  Future<BleManagerState> get state async =>
      _state(await _guard(_host.getState));

  @override
  Stream<BleManagerState> stateUpdates() async* {
    // Subscribe before reading the current state so no change is missed.
    final changes = StreamController<BleManagerState>();
    final sub = _stateChanges.stream.listen(changes.add);
    try {
      yield await state;
      yield* changes.stream;
    } finally {
      await sub.cancel();
      await changes.close();
    }
  }

  @override
  Stream<BleDiscovery> scan({List<BleUuid>? services}) {
    final previous = _scan;
    _scan = null;
    if (previous != null) unawaited(previous.close());

    late final StreamController<BleDiscovery> controller;
    controller = StreamController<BleDiscovery>(
      onListen: () async {
        try {
          await _guard(
            () => _host.startScan(services?.map((u) => u.value).toList()),
          );
        } catch (e) {
          if (!controller.isClosed) {
            controller.addError(e);
            unawaited(controller.close());
          }
        }
      },
      onCancel: () {
        if (identical(_scan, controller)) {
          _scan = null;
          return _guard(_host.stopScan);
        }
        return null;
      },
    );
    _scan = controller;
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    final controller = _scan;
    _scan = null;
    await _guard(_host.stopScan);
    if (controller != null) unawaited(controller.close());
  }

  @override
  Future<void> connect(BlePeripheral peripheral, {Duration? timeout}) => _guard(
    () => _host.connect(peripheral.identifier, timeout?.inMilliseconds),
  );

  @override
  Future<void> disconnect(BlePeripheral peripheral) =>
      _guard(() => _host.disconnect(peripheral.identifier));

  @override
  Stream<BleDisconnection> disconnections() => _drops.stream;

  @override
  Future<BlePeripheral?> retrievePeripheral(String identifier) async {
    final info = await _guard(() => _host.retrievePeripheral(identifier));
    if (info == null) return null;
    return _peripheral(info.peripheralId, info.name);
  }

  @override
  Stream<BleRestorationState> restorationEvents() async* {
    final changes = StreamController<BleRestorationState>();
    final sub = _restorationChanges.stream.listen(changes.add);
    try {
      for (final event in List.of(_restorations)) {
        yield event;
      }
      yield* changes.stream;
    } finally {
      await sub.cancel();
      await changes.close();
    }
  }
}

/// A peripheral reached through [LiveBleCentral].
class LiveBlePeripheral implements BlePeripheral {
  LiveBlePeripheral._(this._central, this.identifier);

  final LiveBleCentral _central;
  String? _cachedName;

  @override
  final String identifier;

  BleHostApi get _host => _central._host;

  @override
  Future<String?> get name async =>
      await _guard(() => _host.peripheralName(identifier)) ?? _cachedName;

  /// Requests an ATT MTU of [mtu] bytes and returns the negotiated value.
  /// On iOS the MTU is negotiated by the system and the current value is
  /// returned.
  Future<int> requestMtu(int mtu) =>
      _guard(() => _host.requestMtu(identifier, mtu));

  @override
  Future<List<BleUuid>> discoverServices([List<BleUuid>? services]) async {
    final found = await _guard(
      () => _host.discoverServices(
        identifier,
        services?.map((u) => u.value).toList(),
      ),
    );
    return found.map(BleUuid.new).toList();
  }

  @override
  Future<List<BleUuid>> discoverCharacteristics(
    List<BleUuid>? characteristics, {
    required BleUuid service,
  }) async {
    final found = await _guard(
      () => _host.discoverCharacteristics(
        identifier,
        service.value,
        characteristics?.map((u) => u.value).toList(),
      ),
    );
    return found.map(BleUuid.new).toList();
  }

  @override
  Future<Uint8List> readValue(BleUuid characteristic) =>
      _guard(() => _host.readValue(identifier, characteristic.value));

  @override
  Future<void> writeValue(
    Uint8List data,
    BleUuid characteristic, {
    bool withResponse = true,
  }) => _guard(
    () =>
        _host.writeValue(identifier, characteristic.value, data, withResponse),
  );

  @override
  Future<void> setNotify(bool enabled, BleUuid characteristic) =>
      _guard(() => _host.setNotify(identifier, characteristic.value, enabled));

  @override
  Stream<Uint8List> notifications(BleUuid characteristic) => _central
      ._notifications
      .stream
      .where(
        (n) =>
            n.peripheralId == identifier &&
            BleUuid(n.characteristicUuid) == characteristic,
      )
      .map((n) => n.value);

  @override
  bool operator ==(Object other) =>
      other is LiveBlePeripheral && other.identifier == identifier;

  @override
  int get hashCode => identifier.hashCode;

  @override
  String toString() => 'LiveBlePeripheral($identifier)';
}

class _Receiver extends BleFlutterApi {
  _Receiver(this._central);

  final LiveBleCentral _central;

  @override
  void onManagerStateChanged(BleManagerStateMessage state) =>
      _central._stateChanges.add(_state(state));

  @override
  void onDiscovery(DiscoveryMessage discovery) {
    final scan = _central._scan;
    if (scan == null || scan.isClosed) return;
    final ad = discovery.advertisement;
    scan.add(
      BleDiscovery(
        peripheral: _central._peripheral(
          discovery.peripheralId,
          discovery.peripheralName ?? ad.localName,
        ),
        advertisement: AdvertisementData(
          localName: ad.localName,
          serviceUuids: ad.serviceUuids.map(BleUuid.new).toList(),
          manufacturerData: ad.manufacturerData,
          isConnectable: ad.isConnectable,
        ),
        rssi: discovery.rssi,
      ),
    );
  }

  @override
  void onDisconnection(DisconnectionMessage event) {
    final error = event.error;
    _central._drops.add(
      BleDisconnection(
        identifier: event.peripheralId,
        error: error == null ? null : _errorFromMessage(error),
      ),
    );
  }

  @override
  void onNotificationValue(NotificationMessage notification) =>
      _central._notifications.add(notification);

  @override
  void onRestoration(RestorationMessage restoration) {
    final peripherals = <BlePeripheral>[
      for (var i = 0; i < restoration.peripheralIds.length; i++)
        _central._peripheral(
          restoration.peripheralIds[i],
          i < restoration.peripheralNames.length
              ? restoration.peripheralNames[i]
              : null,
        ),
    ];
    final event = BleRestorationState(
      peripherals: peripherals,
      scanServices: restoration.scanServiceUuids.map(BleUuid.new).toList(),
    );
    _central._restorations.add(event);
    _central._restorationChanges.add(event);
  }
}
