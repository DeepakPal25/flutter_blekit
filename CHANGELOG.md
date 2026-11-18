## 0.1.0

Initial release, ported from SwiftBLEKit.

- `BleCentral` / `BlePeripheral` abstractions with `LiveBleCentral` (Android
  via `BluetoothGatt`, iOS via SwiftBLEKit's Core Bluetooth adapter).
- `ConnectionCoordinator`: automatic reconnection with exponential backoff and
  jitter, connect timeouts, and a typed `BleConnectionState` stream.
- `ConnectionPool`: caps concurrent connections, with priority-ordered queueing.
- Declarative GATT DSL (`GattProfile`, `service`, `characteristic`,
  `readAs` / `notifyAs`) with cancellable `GattSession`s.
- Typed standard profiles: Battery, Heart Rate, Cycling Power, Device
  Information, HID reports.
- `package:flutter_blekit/testing.dart`: `MockBleCentral` and
  `SimulatedPeripheral` for hardware-free tests and simulators.
