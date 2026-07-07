// Pigeon schema for the flutter_blekit platform channel.
//
// Mirrors SwiftBLEKit's BLECentralManaging / BLEPeripheralProtocol surface:
// HostApi is Dart -> native commands, FlutterApi is native -> Dart events
// (the wire-level equivalent of SwiftBLEKit's AsyncStreams).
//
// Regenerate with: dart run pigeon --input pigeons/messages.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    swiftOut: 'ios/Classes/Messages.g.swift',
    kotlinOut:
        'android/src/main/kotlin/com/deepakpal/flutter_blekit/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.deepakpal.flutter_blekit'),
    dartPackageName: 'flutter_blekit',
  ),
)

/// Mirrors `BLEManagerState`.
enum BleManagerStateMessage {
  unknown,
  resetting,
  unsupported,
  unauthorized,
  poweredOff,
  poweredOn,
}

/// Mirrors the payload shapes of `BLEError`'s cases in one envelope.
enum BleErrorCodeMessage {
  bluetoothUnavailable,
  connectionTimeout,
  disconnected,
  peripheralNotFound,
  serviceNotFound,
  characteristicNotFound,
  reconnectionExhausted,
  cancelled,
  underlying,
}

class BleErrorMessage {
  BleErrorMessage({
    required this.code,
    this.message,
    this.managerState,
    this.isExpectedDisconnect,
    this.attempts,
    this.uuid,
  });

  final BleErrorCodeMessage code;
  final String? message;
  final BleManagerStateMessage? managerState;
  final bool? isExpectedDisconnect;
  final int? attempts;
  final String? uuid;
}

/// Mirrors `AdvertisementData`.
class AdvertisementDataMessage {
  AdvertisementDataMessage({
    this.localName,
    required this.serviceUuids,
    this.manufacturerData,
    required this.isConnectable,
  });

  final String? localName;
  final List<String> serviceUuids;
  final Uint8List? manufacturerData;
  final bool isConnectable;
}

/// Mirrors `BLEDiscovery`.
class DiscoveryMessage {
  DiscoveryMessage({
    required this.peripheralId,
    this.peripheralName,
    required this.advertisement,
    required this.rssi,
  });

  final String peripheralId;
  final String? peripheralName;
  final AdvertisementDataMessage advertisement;
  final int rssi;
}

/// Mirrors `BLEDisconnection`.
class DisconnectionMessage {
  DisconnectionMessage({required this.peripheralId, this.error});

  final String peripheralId;
  final BleErrorMessage? error;
}

/// Mirrors a `notifications(for:)` element for one characteristic.
class NotificationMessage {
  NotificationMessage({
    required this.peripheralId,
    required this.characteristicUuid,
    required this.value,
  });

  final String peripheralId;
  final String characteristicUuid;
  final Uint8List value;
}

/// Mirrors `BLERestorationState`.
class RestorationMessage {
  RestorationMessage({
    required this.peripheralIds,
    required this.peripheralNames,
    required this.scanServiceUuids,
  });

  final List<String> peripheralIds;
  final List<String?> peripheralNames;
  final List<String> scanServiceUuids;
}

class PeripheralInfoMessage {
  PeripheralInfoMessage({required this.peripheralId, this.name});

  final String peripheralId;
  final String? name;
}

/// Dart -> native commands. One instance backs one native
/// `BLECentralManaging` implementation (LiveCentralManager on iOS, the
/// BluetoothLeScanner/BluetoothGatt adapter on Android).
@HostApi()
abstract class BleHostApi {
  BleManagerStateMessage getState();

  void startScan(List<String>? serviceUuids);

  void stopScan();

  @async
  void connect(String peripheralId, int? timeoutMs);

  @async
  void disconnect(String peripheralId);

  @async
  PeripheralInfoMessage? retrievePeripheral(String identifier);

  @async
  List<String> discoverServices(String peripheralId, List<String>? serviceUuids);

  @async
  List<String> discoverCharacteristics(
    String peripheralId,
    String serviceUuid,
    List<String>? characteristicUuids,
  );

  @async
  Uint8List readValue(String peripheralId, String characteristicUuid);

  @async
  void writeValue(
    String peripheralId,
    String characteristicUuid,
    Uint8List value,
    bool withResponse,
  );

  @async
  void setNotify(String peripheralId, String characteristicUuid, bool enabled);

  @async
  String? peripheralName(String peripheralId);
}

/// Native -> Dart events. The wire-level equivalent of SwiftBLEKit's
/// AsyncStreams; the Dart side fans these back out into broadcast Streams.
@FlutterApi()
abstract class BleFlutterApi {
  void onManagerStateChanged(BleManagerStateMessage state);

  void onDiscovery(DiscoveryMessage discovery);

  void onDisconnection(DisconnectionMessage event);

  void onNotificationValue(NotificationMessage notification);

  void onRestoration(RestorationMessage restoration);
}
