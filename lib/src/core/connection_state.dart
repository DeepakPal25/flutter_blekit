import 'errors.dart';

/// The lifecycle of one managed connection. Mirrors SwiftBLEKit's
/// `ConnectionState` (renamed so it does not clash with Flutter's
/// `ConnectionState` from `package:flutter/widgets.dart`).
sealed class BleConnectionState {
  const BleConnectionState();

  static const BleConnectionState disconnected = BleDisconnected();
  static const BleConnectionState scanning = BleScanning();
  static const BleConnectionState connecting = BleConnecting();
  static const BleConnectionState connected = BleConnected();

  /// Retrying after [attempt] failed attempts or drops.
  const factory BleConnectionState.reconnecting(int attempt) = BleReconnecting;

  /// Gave up permanently with [error].
  const factory BleConnectionState.failed(BleError error) = BleFailed;

  /// True for states the coordinator will not leave on its own.
  bool get isTerminal => this is BleFailed;
}

final class BleDisconnected extends BleConnectionState {
  const BleDisconnected();
  @override
  bool operator ==(Object other) => other is BleDisconnected;
  @override
  int get hashCode => (BleDisconnected).hashCode;
  @override
  String toString() => 'disconnected';
}

final class BleScanning extends BleConnectionState {
  const BleScanning();
  @override
  bool operator ==(Object other) => other is BleScanning;
  @override
  int get hashCode => (BleScanning).hashCode;
  @override
  String toString() => 'scanning';
}

final class BleConnecting extends BleConnectionState {
  const BleConnecting();
  @override
  bool operator ==(Object other) => other is BleConnecting;
  @override
  int get hashCode => (BleConnecting).hashCode;
  @override
  String toString() => 'connecting';
}

final class BleConnected extends BleConnectionState {
  const BleConnected();
  @override
  bool operator ==(Object other) => other is BleConnected;
  @override
  int get hashCode => (BleConnected).hashCode;
  @override
  String toString() => 'connected';
}

final class BleReconnecting extends BleConnectionState {
  const BleReconnecting(this.attempt);
  final int attempt;
  @override
  bool operator ==(Object other) =>
      other is BleReconnecting && other.attempt == attempt;
  @override
  int get hashCode => Object.hash(BleReconnecting, attempt);
  @override
  String toString() => 'reconnecting(attempt: $attempt)';
}

final class BleFailed extends BleConnectionState {
  const BleFailed(this.error);
  final BleError error;
  @override
  bool operator ==(Object other) => other is BleFailed && other.error == error;
  @override
  int get hashCode => Object.hash(BleFailed, error);
  @override
  String toString() => 'failed($error)';
}
