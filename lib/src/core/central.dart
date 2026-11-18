import 'dart:typed_data';

import 'errors.dart';
import 'manager_state.dart';
import 'uuid.dart';

/// A BLE central. Mirrors SwiftBLEKit's `BLECentralManaging`; implemented by
/// `LiveBleCentral` (platform channels) and `MockBleCentral` (tests).
abstract interface class BleCentral {
  /// The current adapter state.
  Future<BleManagerState> get state;

  /// Adapter state changes, starting with the current state.
  Stream<BleManagerState> stateUpdates();

  /// Scans for peripherals advertising any of [services] (all when null).
  /// The stream closes when [stopScan] is called.
  Stream<BleDiscovery> scan({List<BleUuid>? services});

  Future<void> stopScan();

  /// Connects to [peripheral], failing with [ConnectionTimeoutError] after
  /// [timeout] (no timeout when null).
  Future<void> connect(BlePeripheral peripheral, {Duration? timeout});

  /// Disconnects; emits an expected [BleDisconnection] if it was connected.
  Future<void> disconnect(BlePeripheral peripheral);

  /// Every link drop, expected or not.
  Stream<BleDisconnection> disconnections();

  /// Looks up a previously seen peripheral by identifier.
  Future<BlePeripheral?> retrievePeripheral(String identifier);

  /// State-restoration events. Events delivered before a listener subscribed
  /// are replayed to it.
  Stream<BleRestorationState> restorationEvents();
}

/// A BLE peripheral. Mirrors SwiftBLEKit's `BLEPeripheralProtocol`.
abstract interface class BlePeripheral {
  /// Platform identifier (a UUID on iOS, a MAC address on Android).
  String get identifier;

  Future<String?> get name;

  /// Discovers [services] (all when null) and returns those found.
  Future<List<BleUuid>> discoverServices([List<BleUuid>? services]);

  /// Discovers [characteristics] (all when null) of [service].
  /// Throws [ServiceNotFoundError] if [service] was not discovered.
  Future<List<BleUuid>> discoverCharacteristics(
    List<BleUuid>? characteristics, {
    required BleUuid service,
  });

  Future<Uint8List> readValue(BleUuid characteristic);

  Future<void> writeValue(
    Uint8List data,
    BleUuid characteristic, {
    bool withResponse = true,
  });

  Future<void> setNotify(bool enabled, BleUuid characteristic);

  /// Values pushed for [characteristic] while notifications are enabled.
  Stream<Uint8List> notifications(BleUuid characteristic);
}

/// Advertisement payload. Mirrors `AdvertisementData`.
final class AdvertisementData {
  const AdvertisementData({
    this.localName,
    this.serviceUuids = const [],
    this.manufacturerData,
    this.isConnectable = true,
  });

  final String? localName;
  final List<BleUuid> serviceUuids;
  final Uint8List? manufacturerData;
  final bool isConnectable;

  @override
  String toString() =>
      'AdvertisementData(localName: $localName, services: $serviceUuids)';
}

/// One scan result. Mirrors `BLEDiscovery`.
final class BleDiscovery {
  const BleDiscovery({
    required this.peripheral,
    this.advertisement = const AdvertisementData(),
    required this.rssi,
  });

  final BlePeripheral peripheral;
  final AdvertisementData advertisement;
  final int rssi;
}

/// A link drop. Mirrors `BLEDisconnection`.
final class BleDisconnection {
  const BleDisconnection({required this.identifier, this.error});

  final String identifier;
  final BleError? error;

  /// True when the app asked for this disconnect.
  bool get isExpected => switch (error) {
    DisconnectedError(isExpected: true) => true,
    _ => false,
  };

  @override
  bool operator ==(Object other) =>
      other is BleDisconnection &&
      other.identifier == identifier &&
      other.error == error;

  @override
  int get hashCode => Object.hash(identifier, error);

  @override
  String toString() => 'BleDisconnection($identifier, $error)';
}

/// Peripherals handed back by the OS after a relaunch.
/// Mirrors `BLERestorationState`.
final class BleRestorationState {
  const BleRestorationState({
    required this.peripherals,
    this.scanServices = const [],
  });

  final List<BlePeripheral> peripherals;
  final List<BleUuid> scanServices;
}
