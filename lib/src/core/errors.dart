import 'manager_state.dart';
import 'uuid.dart';

/// Errors surfaced by flutter_blekit. Mirrors SwiftBLEKit's `BLEError`.
sealed class BleError implements Exception {
  const BleError();
}

/// The adapter is not powered on (or not usable) in [state].
final class BluetoothUnavailableError extends BleError {
  const BluetoothUnavailableError(this.state);
  final BleManagerState state;

  @override
  bool operator ==(Object other) =>
      other is BluetoothUnavailableError && other.state == state;
  @override
  int get hashCode => Object.hash(BluetoothUnavailableError, state);
  @override
  String toString() => 'BluetoothUnavailableError($state)';
}

/// A connection attempt did not complete within its timeout.
final class ConnectionTimeoutError extends BleError {
  const ConnectionTimeoutError();

  @override
  bool operator ==(Object other) => other is ConnectionTimeoutError;
  @override
  int get hashCode => (ConnectionTimeoutError).hashCode;
  @override
  String toString() => 'ConnectionTimeoutError()';
}

/// The link went down. [isExpected] is true for app-initiated disconnects.
final class DisconnectedError extends BleError {
  const DisconnectedError({required this.isExpected, this.reason});
  final bool isExpected;
  final String? reason;

  @override
  bool operator ==(Object other) =>
      other is DisconnectedError &&
      other.isExpected == isExpected &&
      other.reason == reason;
  @override
  int get hashCode => Object.hash(DisconnectedError, isExpected, reason);
  @override
  String toString() =>
      'DisconnectedError(isExpected: $isExpected, reason: $reason)';
}

/// No peripheral is known for the given identifier.
final class PeripheralNotFoundError extends BleError {
  const PeripheralNotFoundError([this.identifier]);
  final String? identifier;

  @override
  bool operator ==(Object other) =>
      other is PeripheralNotFoundError && other.identifier == identifier;
  @override
  int get hashCode => Object.hash(PeripheralNotFoundError, identifier);
  @override
  String toString() => 'PeripheralNotFoundError($identifier)';
}

/// The service was not discovered on the peripheral.
final class ServiceNotFoundError extends BleError {
  const ServiceNotFoundError(this.uuid);
  final BleUuid uuid;

  @override
  bool operator ==(Object other) =>
      other is ServiceNotFoundError && other.uuid == uuid;
  @override
  int get hashCode => Object.hash(ServiceNotFoundError, uuid);
  @override
  String toString() => 'ServiceNotFoundError($uuid)';
}

/// The characteristic was not discovered (or has no value).
final class CharacteristicNotFoundError extends BleError {
  const CharacteristicNotFoundError(this.uuid);
  final BleUuid uuid;

  @override
  bool operator ==(Object other) =>
      other is CharacteristicNotFoundError && other.uuid == uuid;
  @override
  int get hashCode => Object.hash(CharacteristicNotFoundError, uuid);
  @override
  String toString() => 'CharacteristicNotFoundError($uuid)';
}

/// The reconnection budget ran out after [attempts] failed attempts.
final class ReconnectionExhaustedError extends BleError {
  const ReconnectionExhaustedError(this.attempts);
  final int attempts;

  @override
  bool operator ==(Object other) =>
      other is ReconnectionExhaustedError && other.attempts == attempts;
  @override
  int get hashCode => Object.hash(ReconnectionExhaustedError, attempts);
  @override
  String toString() => 'ReconnectionExhaustedError($attempts)';
}

/// The operation was cancelled.
final class CancelledError extends BleError {
  const CancelledError();

  @override
  bool operator ==(Object other) => other is CancelledError;
  @override
  int get hashCode => (CancelledError).hashCode;
  @override
  String toString() => 'CancelledError()';
}

/// A platform or decoding error described by [message].
final class UnderlyingBleError extends BleError {
  const UnderlyingBleError(this.message);
  final String message;

  @override
  bool operator ==(Object other) =>
      other is UnderlyingBleError && other.message == message;
  @override
  int get hashCode => Object.hash(UnderlyingBleError, message);
  @override
  String toString() => 'UnderlyingBleError($message)';
}
