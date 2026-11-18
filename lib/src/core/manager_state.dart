/// The Bluetooth adapter state. Mirrors SwiftBLEKit's `BLEManagerState`.
enum BleManagerState {
  unknown,
  resetting,
  unsupported,
  unauthorized,
  poweredOff,
  poweredOn,
}
