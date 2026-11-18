import 'dart:async';
import 'dart:typed_data';

import '../core/central.dart';
import '../core/uuid.dart';

/// Receives a raw characteristic value.
typedef BleValueHandler = FutureOr<void> Function(Uint8List value);

/// Declares what to do with one characteristic. Built fluently:
///
/// ```dart
/// characteristic(BleUuid.batteryLevel).notifyAs(BatteryLevel.fromBytes, onBattery)
/// ```
final class CharacteristicSpec {
  const CharacteristicSpec(this.uuid, {this.onRead, this.onNotify});

  final BleUuid uuid;

  /// Called once with the value read during [BleGattAttach.attach].
  final BleValueHandler? onRead;

  /// Called for every notification after [BleGattAttach.attach].
  final BleValueHandler? onNotify;

  /// Reads the value once on attach.
  CharacteristicSpec read(BleValueHandler handler) =>
      CharacteristicSpec(uuid, onRead: handler, onNotify: onNotify);

  /// Reads once and decodes with [decode]; values that fail to decode are
  /// skipped.
  CharacteristicSpec readAs<T>(
    T Function(Uint8List value) decode,
    FutureOr<void> Function(T value) handler,
  ) => read(_decoding(decode, handler));

  /// Subscribes to notifications.
  CharacteristicSpec notify(BleValueHandler handler) =>
      CharacteristicSpec(uuid, onRead: onRead, onNotify: handler);

  /// Subscribes and decodes with [decode]; malformed payloads are skipped.
  CharacteristicSpec notifyAs<T>(
    T Function(Uint8List value) decode,
    FutureOr<void> Function(T value) handler,
  ) => notify(_decoding(decode, handler));

  static BleValueHandler _decoding<T>(
    T Function(Uint8List) decode,
    FutureOr<void> Function(T) handler,
  ) {
    return (Uint8List value) {
      final T decoded;
      try {
        decoded = decode(value);
      } catch (_) {
        return null;
      }
      return handler(decoded);
    };
  }
}

/// A service and the characteristics to use within it.
final class ServiceSpec {
  const ServiceSpec(this.uuid, this.characteristics);

  final BleUuid uuid;
  final List<CharacteristicSpec> characteristics;
}

/// A declarative description of the services and characteristics an app
/// cares about. Apply it with [BleGattAttach.attach].
final class GattProfile {
  const GattProfile(this.services);

  final List<ServiceSpec> services;
}

/// Shorthand for [ServiceSpec].
ServiceSpec service(
  BleUuid uuid, [
  List<CharacteristicSpec> characteristics = const [],
]) => ServiceSpec(uuid, characteristics);

/// Shorthand for an empty [CharacteristicSpec] to chain from.
CharacteristicSpec characteristic(BleUuid uuid) => CharacteristicSpec(uuid);

/// The live result of attaching a [GattProfile]. Call [cancel] to stop
/// delivering notifications to the profile's handlers.
final class GattSession {
  GattSession(this._subscriptions);

  final List<StreamSubscription<void>> _subscriptions;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    await Future.wait(_subscriptions.map((s) => s.cancel()));
    _subscriptions.clear();
  }
}

extension BleGattAttach on BlePeripheral {
  /// Discovers everything [profile] names, performs its reads, enables its
  /// notifications and routes values to the handlers. Notification handlers
  /// for one characteristic run one at a time, in order.
  Future<GattSession> attach(GattProfile profile) async {
    final subscriptions = <StreamSubscription<void>>[];
    try {
      await discoverServices(profile.services.map((s) => s.uuid).toList());
      for (final svc in profile.services) {
        await discoverCharacteristics(
          svc.characteristics.map((c) => c.uuid).toList(),
          service: svc.uuid,
        );
        for (final spec in svc.characteristics) {
          final onRead = spec.onRead;
          if (onRead != null) {
            await onRead(await readValue(spec.uuid));
          }
          final onNotify = spec.onNotify;
          if (onNotify != null) {
            await setNotify(true, spec.uuid);
            subscriptions.add(
              notifications(spec.uuid)
                  .asyncMap((value) => onNotify(value))
                  .listen(null, onError: (Object _) {}),
            );
          }
        }
      }
    } catch (_) {
      for (final s in subscriptions) {
        await s.cancel();
      }
      rethrow;
    }
    return GattSession(subscriptions);
  }
}
