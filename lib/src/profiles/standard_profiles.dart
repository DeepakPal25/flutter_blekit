import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/uuid.dart';
import '../gatt/gatt_profile.dart';

/// Little-endian cursor over a characteristic value. Underflow throws
/// [UnderlyingBleError].
final class ByteReader {
  ByteReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  int get remaining => _bytes.length - _offset;

  void _need(int count) {
    if (remaining < count) {
      throw const UnderlyingBleError('unexpected end of characteristic data');
    }
  }

  int uint8() {
    _need(1);
    return _bytes[_offset++];
  }

  int uint16LE() {
    _need(2);
    final v = _bytes[_offset] | (_bytes[_offset + 1] << 8);
    _offset += 2;
    return v;
  }

  int int16LE() {
    final v = uint16LE();
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  Uint8List rest() {
    final out = Uint8List.sublistView(_bytes, _offset);
    _offset = _bytes.length;
    return out;
  }
}

/// Battery Level (0x2A19).
final class BatteryLevel {
  const BatteryLevel(this.percent);

  factory BatteryLevel.fromBytes(Uint8List data) =>
      BatteryLevel(ByteReader(data).uint8());

  final int percent;

  @override
  bool operator ==(Object other) =>
      other is BatteryLevel && other.percent == percent;
  @override
  int get hashCode => percent.hashCode;
  @override
  String toString() => 'BatteryLevel($percent%)';
}

/// Heart Rate Measurement (0x2A37).
final class HeartRateMeasurement {
  const HeartRateMeasurement({
    required this.beatsPerMinute,
    this.sensorContactDetected,
    this.energyExpended,
    this.rrIntervals = const [],
  });

  factory HeartRateMeasurement.fromBytes(Uint8List data) {
    final r = ByteReader(data);
    final flags = r.uint8();
    final bpm = (flags & 0x01) != 0 ? r.uint16LE() : r.uint8();
    final contactBits = (flags >> 1) & 0x03;
    final bool? contact = switch (contactBits) {
      0x02 => false,
      0x03 => true,
      _ => null,
    };
    final energy = (flags & 0x08) != 0 ? r.uint16LE() : null;
    final rr = <double>[];
    if ((flags & 0x10) != 0) {
      while (r.remaining >= 2) {
        rr.add(r.uint16LE() / 1024.0);
      }
    }
    return HeartRateMeasurement(
      beatsPerMinute: bpm,
      sensorContactDetected: contact,
      energyExpended: energy,
      rrIntervals: List.unmodifiable(rr),
    );
  }

  final int beatsPerMinute;

  /// Null when the sensor does not support contact detection.
  final bool? sensorContactDetected;

  /// Kilojoules, when present.
  final int? energyExpended;

  /// RR intervals in seconds.
  final List<double> rrIntervals;

  @override
  bool operator ==(Object other) =>
      other is HeartRateMeasurement &&
      other.beatsPerMinute == beatsPerMinute &&
      other.sensorContactDetected == sensorContactDetected &&
      other.energyExpended == energyExpended &&
      _listEquals(other.rrIntervals, rrIntervals);
  @override
  int get hashCode => Object.hash(
    beatsPerMinute,
    sensorContactDetected,
    energyExpended,
    Object.hashAll(rrIntervals),
  );
  @override
  String toString() =>
      'HeartRateMeasurement(bpm: $beatsPerMinute, contact: '
      '$sensorContactDetected, energy: $energyExpended, rr: $rrIntervals)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Body Sensor Location (0x2A38).
enum BodySensorLocation {
  other(0),
  chest(1),
  wrist(2),
  finger(3),
  hand(4),
  earLobe(5),
  foot(6),
  unknown(255);

  const BodySensorLocation(this.rawValue);

  final int rawValue;

  static BodySensorLocation fromBytes(Uint8List data) {
    final raw = ByteReader(data).uint8();
    return values.firstWhere(
      (l) => l.rawValue == raw,
      orElse: () => BodySensorLocation.unknown,
    );
  }
}

/// A UTF-8 string characteristic (e.g. Manufacturer Name).
final class GattString {
  const GattString(this.value);

  factory GattString.fromBytes(Uint8List data) {
    try {
      return GattString(utf8.decode(data));
    } on FormatException {
      throw const UnderlyingBleError('characteristic value is not valid UTF-8');
    }
  }

  final String value;

  @override
  bool operator ==(Object other) => other is GattString && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// Cycling Power Measurement (0x2A63).
final class CyclingPowerMeasurement {
  const CyclingPowerMeasurement({
    required this.instantaneousPower,
    this.pedalPowerBalance,
  });

  factory CyclingPowerMeasurement.fromBytes(Uint8List data) {
    final r = ByteReader(data);
    final flags = r.uint16LE();
    final power = r.int16LE();
    final balance = (flags & 0x01) != 0 ? r.uint8() / 2.0 : null;
    return CyclingPowerMeasurement(
      instantaneousPower: power,
      pedalPowerBalance: balance,
    );
  }

  /// Watts.
  final int instantaneousPower;

  /// Percent, in 0.5% steps, when present.
  final double? pedalPowerBalance;

  @override
  bool operator ==(Object other) =>
      other is CyclingPowerMeasurement &&
      other.instantaneousPower == instantaneousPower &&
      other.pedalPowerBalance == pedalPowerBalance;
  @override
  int get hashCode => Object.hash(instantaneousPower, pedalPowerBalance);
  @override
  String toString() =>
      'CyclingPowerMeasurement($instantaneousPower W, '
      'balance: $pedalPowerBalance)';
}

/// A raw HID report (0x2A4D).
final class HidReport {
  const HidReport(this.bytes);

  factory HidReport.fromBytes(Uint8List data) =>
      HidReport(Uint8List.fromList(data));

  final Uint8List bytes;

  @override
  bool operator ==(Object other) =>
      other is HidReport && _listEquals(other.bytes, bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
}

/// Ready-made [ServiceSpec]s for common Bluetooth SIG services.
abstract final class StandardProfile {
  /// Battery Service: notifications of Battery Level.
  static ServiceSpec battery(FutureOr<void> Function(BatteryLevel) onLevel) =>
      service(BleUuid.batteryService, [
        characteristic(
          BleUuid.batteryLevel,
        ).notifyAs(BatteryLevel.fromBytes, onLevel),
      ]);

  /// Heart Rate Service: Heart Rate Measurement notifications.
  static ServiceSpec heartRate(
    FutureOr<void> Function(HeartRateMeasurement) onMeasurement,
  ) => service(BleUuid.heartRate, [
    characteristic(
      BleUuid.heartRateMeasurement,
    ).notifyAs(HeartRateMeasurement.fromBytes, onMeasurement),
  ]);

  /// Cycling Power Service: measurement notifications.
  static ServiceSpec cyclingPower(
    FutureOr<void> Function(CyclingPowerMeasurement) onMeasurement,
  ) => service(BleUuid.cyclingPower, [
    characteristic(
      BleUuid.cyclingPowerMeasurement,
    ).notifyAs(CyclingPowerMeasurement.fromBytes, onMeasurement),
  ]);

  /// Device Information Service: one-off reads of the strings you ask for.
  static ServiceSpec deviceInformation({
    FutureOr<void> Function(String)? manufacturer,
    FutureOr<void> Function(String)? model,
    FutureOr<void> Function(String)? firmware,
  }) {
    CharacteristicSpec reading(
      BleUuid uuid,
      FutureOr<void> Function(String) handler,
    ) => characteristic(
      uuid,
    ).readAs(GattString.fromBytes, (GattString s) => handler(s.value));

    return service(BleUuid.deviceInformation, [
      if (manufacturer != null) reading(BleUuid.manufacturerName, manufacturer),
      if (model != null) reading(BleUuid.modelNumber, model),
      if (firmware != null) reading(BleUuid.firmwareRevision, firmware),
    ]);
  }
}
