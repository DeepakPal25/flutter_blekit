# flutter_blekit

A testable Bluetooth LE layer for Flutter, ported from
[SwiftBLEKit](https://github.com/DeepakPal25/SwiftBLEKit).

- **Automatic reconnection.** `ConnectionCoordinator` retries with exponential
  backoff and jitter, and reports each step as a typed state stream.
- **Declarative GATT.** You describe the services and characteristics you care
  about, and the library handles discovery, reads and notifications.
- **Typed standard profiles.** Battery, Heart Rate, Cycling Power, Device
  Information and HID reports.
- **Connection pool.** Caps concurrent links and promotes queued devices by
  priority.
- **Hardware-free testing.** `MockBleCentral` and `SimulatedPeripheral` run
  your BLE code in unit tests, widget tests and emulators.

| Platform | Backend |
| --- | --- |
| Android (API 24+) | `BluetoothGatt` |
| iOS | SwiftBLEKit's Core Bluetooth adapter (vendored) |

## Setup

**Android:** the plugin manifest declares `BLUETOOTH_SCAN` and
`BLUETOOTH_CONNECT` (Android 12+), plus location permissions for older
versions. Call `LiveBleCentral.requestPermissions()` before scanning.

**iOS:** add a usage description to `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Connects to your heart-rate monitor.</string>
```

## Usage

### Scan, then connect with automatic reconnection

```dart
import 'package:flutter_blekit/flutter_blekit.dart';

Future<void> connectToFirstHrm() async {
  final central = LiveBleCentral();
  if (!await central.requestPermissions()) return;

  final discovery = await central.scan(services: [BleUuid.heartRate]).first;
  await central.stopScan();

  final coordinator = ConnectionCoordinator(
    central: central,
    peripheral: discovery.peripheral,
    backoff: const ExponentialBackoff(maxAttempts: 5),
  );
  coordinator.states().listen(print); // connecting, connected, reconnecting(attempt: 1), ...
  coordinator.start();

  // Later:
  await coordinator.stop();
}
```

### Declare the GATT you need

```dart
Future<GattSession> subscribe(BlePeripheral peripheral) {
  return peripheral.attach(
    GattProfile([
      StandardProfile.heartRate((m) => print('${m.beatsPerMinute} bpm, RR ${m.rrIntervals}')),
      StandardProfile.deviceInformation(manufacturer: print, model: print),
      service(BleUuid.batteryService, [
        characteristic(BleUuid.batteryLevel)
            .readAs(BatteryLevel.fromBytes, (b) => print('${b.percent}%'))
            .notifyAs(BatteryLevel.fromBytes, (b) => print('${b.percent}%')),
      ]),
    ]),
  );
}
// Call `await session.cancel()` to stop all notifications. A payload that
// fails to decode is skipped and does not end the stream.
```

Re-attach after each `connected` state, because a reconnect starts a fresh
GATT session.

### Many devices

```dart
final pool = ConnectionPool(central: central, maxConcurrent: 3);
pool.events.listen((e) => print('${e.identifier}: ${e.state}'));
pool.manage(chestStrap, priority: 10); // promoted ahead of priority 0
pool.manage(powerMeter);
await pool.drop(powerMeter.identifier); // frees a slot for the next queued device
```

### Testing without hardware

```dart
import 'package:flutter_blekit/flutter_blekit.dart';
import 'package:flutter_blekit/testing.dart';

final central = MockBleCentral();
final hrm = SimulatedPeripheral(
  identifier: 'HRM-1',
  name: 'Test HRM',
  services: {BleUuid.heartRate: [BleUuid.heartRateMeasurement]},
);
central.add(hrm);
central.enqueueConnectBehaviors([ConnectBehavior.timeout, ConnectBehavior.succeed]);

final coordinator = ConnectionCoordinator(central: central, peripheral: hrm);
coordinator.start(); // the first attempt times out, then it reconnects

hrm.simulateValue(Uint8List.fromList([0x00, 72]), BleUuid.heartRateMeasurement);
central.simulateDisconnect(hrm); // exercise the reconnect path
```

The [example app](example/lib/main.dart) has a **Simulated** mode built on
these doubles, so the full scan, connect, drop and reconnect flow runs on an
emulator.

## Platform notes

- **iOS:** `requestMtu` returns the MTU that iOS negotiated, because iOS does
  not let apps choose one. `requestPermissions` reports the current
  authorization, and the system prompts on first use.
- **iOS state restoration:** not enabled in 0.1.0. `central.restorationEvents()`
  is part of the API but does not emit on iOS yet.

## License

MIT. See [LICENSE](LICENSE).
