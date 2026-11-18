/// A Bluetooth UUID, normalised so values from different platforms compare
/// equal.
///
/// Mirrors SwiftBLEKit's `BLEUUID`, with one extra rule: a 128-bit UUID built
/// on the Bluetooth Base UUID (`0000XXXX-0000-1000-8000-00805F9B34FB`) is
/// shortened to its 16-bit form. Android always reports full 128-bit UUIDs,
/// so this is what makes `BleUuid('0000180d-0000-1000-8000-00805f9b34fb')`
/// equal to [BleUuid.heartRate].
final class BleUuid {
  /// Creates a UUID from a 16-bit (`180D`), 32-bit or 128-bit string.
  factory BleUuid(String value) => BleUuid._(_normalize(value));

  const BleUuid._(this.value);

  /// The normalised, upper-case string form.
  final String value;

  static final RegExp _base = RegExp(
    r'^0000([0-9A-F]{4})-0000-1000-8000-00805F9B34FB$',
  );

  static String _normalize(String raw) {
    final upper = raw.trim().toUpperCase();
    final match = _base.firstMatch(upper);
    return match != null ? match.group(1)! : upper;
  }

  // Services
  static const BleUuid genericAccess = BleUuid._('1800');
  static const BleUuid deviceInformation = BleUuid._('180A');
  static const BleUuid batteryService = BleUuid._('180F');
  static const BleUuid heartRate = BleUuid._('180D');
  static const BleUuid cyclingPower = BleUuid._('1818');
  static const BleUuid humanInterfaceDevice = BleUuid._('1812');

  // Characteristics
  static const BleUuid batteryLevel = BleUuid._('2A19');
  static const BleUuid heartRateMeasurement = BleUuid._('2A37');
  static const BleUuid bodySensorLocation = BleUuid._('2A38');
  static const BleUuid manufacturerName = BleUuid._('2A29');
  static const BleUuid modelNumber = BleUuid._('2A24');
  static const BleUuid serialNumber = BleUuid._('2A25');
  static const BleUuid firmwareRevision = BleUuid._('2A26');
  static const BleUuid hardwareRevision = BleUuid._('2A27');
  static const BleUuid softwareRevision = BleUuid._('2A28');
  static const BleUuid cyclingPowerMeasurement = BleUuid._('2A63');
  static const BleUuid hidReport = BleUuid._('2A4D');

  @override
  bool operator ==(Object other) => other is BleUuid && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
