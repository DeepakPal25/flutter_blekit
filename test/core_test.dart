import 'dart:typed_data';

import 'package:flutter_blekit/flutter_blekit.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  group('ExponentialBackoff', () {
    test('base delays double and cap at maxDelay', () {
      const b = ExponentialBackoff(maxDelay: Duration(seconds: 3));
      expect(b.baseDelay(0), Duration.zero);
      expect(b.baseDelay(1), const Duration(milliseconds: 500));
      expect(b.baseDelay(2), const Duration(seconds: 1));
      expect(b.baseDelay(3), const Duration(seconds: 2));
      expect(b.baseDelay(4), const Duration(seconds: 3));
      expect(b.baseDelay(40), const Duration(seconds: 3));
    });

    test('jitter spreads delays by the configured fraction', () {
      const b = ExponentialBackoff(jitter: 0.2);
      expect(b.delay(2, randomUnit: 0), const Duration(milliseconds: 800));
      expect(b.delay(2, randomUnit: 0.5), const Duration(seconds: 1));
      expect(b.delay(2, randomUnit: 1), const Duration(milliseconds: 1200));
    });

    test('allowsAttempt respects the budget; persistent never stops', () {
      const b = ExponentialBackoff(maxAttempts: 2);
      expect(b.allowsAttempt(after: 0), isTrue);
      expect(b.allowsAttempt(after: 1), isTrue);
      expect(b.allowsAttempt(after: 2), isFalse);
      expect(
        ExponentialBackoff.persistent.allowsAttempt(after: 1000000),
        isTrue,
      );
    });
  });

  group('BleUuid', () {
    test('normalises case and whitespace', () {
      expect(BleUuid(' 180d '), BleUuid.heartRate);
      expect(BleUuid('180d').value, '180D');
    });

    test('shortens Bluetooth Base UUIDs so Android forms compare equal', () {
      expect(
        BleUuid('0000180d-0000-1000-8000-00805f9b34fb'),
        BleUuid.heartRate,
      );
      expect(
        BleUuid('0000180d-0000-1000-8000-00805f9b34fb').hashCode,
        BleUuid.heartRate.hashCode,
      );
    });

    test('keeps custom 128-bit UUIDs intact', () {
      const raw = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
      expect(BleUuid(raw.toLowerCase()).value, raw);
      expect(
        BleUuid(raw),
        isNot(BleUuid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E')),
      );
    });
  });

  group('BleConnectionState', () {
    test('equality, terminality and descriptions', () {
      expect(
        const BleConnectionState.reconnecting(2),
        const BleConnectionState.reconnecting(2),
      );
      expect(
        const BleConnectionState.reconnecting(1),
        isNot(const BleConnectionState.reconnecting(2)),
      );
      expect(
        const BleConnectionState.failed(CancelledError()).isTerminal,
        isTrue,
      );
      expect(BleConnectionState.connected.isTerminal, isFalse);
      expect(
        const BleConnectionState.reconnecting(1).toString(),
        'reconnecting(attempt: 1)',
      );
    });
  });

  group('standard profile decoders', () {
    test('BatteryLevel', () {
      expect(BatteryLevel.fromBytes(bytes([87])), const BatteryLevel(87));
      expect(() => BatteryLevel.fromBytes(bytes([])), throwsA(isA<BleError>()));
    });

    test('HeartRateMeasurement, uint8 bpm without extras', () {
      expect(
        HeartRateMeasurement.fromBytes(bytes([0x00, 72])),
        const HeartRateMeasurement(beatsPerMinute: 72),
      );
    });

    test('HeartRateMeasurement, uint16 bpm, contact, energy and RR', () {
      // flags: 16-bit bpm | contact supported+detected | energy | RR
      final m = HeartRateMeasurement.fromBytes(
        bytes([0x1F, 0x2C, 0x01, 0x10, 0x00, 0x00, 0x04, 0x00, 0x02]),
      );
      expect(m.beatsPerMinute, 300);
      expect(m.sensorContactDetected, isTrue);
      expect(m.energyExpended, 16);
      expect(m.rrIntervals, [1.0, 0.5]);
    });

    test('HeartRateMeasurement contact states', () {
      expect(
        HeartRateMeasurement.fromBytes(bytes([0x04, 60])).sensorContactDetected,
        isFalse,
      );
      expect(
        HeartRateMeasurement.fromBytes(bytes([0x00, 60])).sensorContactDetected,
        isNull,
      );
    });

    test('HeartRateMeasurement truncated 16-bit value throws', () {
      expect(
        () => HeartRateMeasurement.fromBytes(bytes([0x01, 0x10])),
        throwsA(isA<BleError>()),
      );
    });

    test('BodySensorLocation maps known and unknown values', () {
      expect(
        BodySensorLocation.fromBytes(bytes([1])),
        BodySensorLocation.chest,
      );
      expect(
        BodySensorLocation.fromBytes(bytes([42])),
        BodySensorLocation.unknown,
      );
    });

    test('GattString decodes UTF-8 and rejects invalid bytes', () {
      expect(
        GattString.fromBytes(bytes([0x43, 0x61, 0x66, 0xC3, 0xA9])).value,
        'Café',
      );
      expect(
        () => GattString.fromBytes(bytes([0xFF])),
        throwsA(isA<BleError>()),
      );
    });

    test('CyclingPowerMeasurement with and without balance', () {
      expect(
        CyclingPowerMeasurement.fromBytes(bytes([0x00, 0x00, 0xFA, 0x00])),
        const CyclingPowerMeasurement(instantaneousPower: 250),
      );
      expect(
        CyclingPowerMeasurement.fromBytes(bytes([0x01, 0x00, 0xFF, 0xFF, 101])),
        const CyclingPowerMeasurement(
          instantaneousPower: -1,
          pedalPowerBalance: 50.5,
        ),
      );
    });

    test('HidReport copies its input', () {
      final raw = bytes([1, 2, 3]);
      final report = HidReport.fromBytes(raw);
      raw[0] = 9;
      expect(report.bytes, [1, 2, 3]);
      expect(report, HidReport(bytes([1, 2, 3])));
    });
  });
}
