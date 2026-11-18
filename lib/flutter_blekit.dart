/// Testable, coordinator-driven Bluetooth Low Energy for Flutter.
///
/// A port of SwiftBLEKit: program against [BleCentral] / [BlePeripheral],
/// use [LiveBleCentral] in production and `MockBleCentral` (from
/// `package:flutter_blekit/testing.dart`) in tests and simulators.
library;

export 'src/connection/coordinator.dart';
export 'src/core/backoff.dart';
export 'src/core/central.dart';
export 'src/core/connection_state.dart';
export 'src/core/errors.dart';
export 'src/core/manager_state.dart';
export 'src/core/uuid.dart';
export 'src/gatt/gatt_profile.dart';
export 'src/live/live_central.dart';
export 'src/pool/connection_pool.dart';
export 'src/profiles/standard_profiles.dart';
