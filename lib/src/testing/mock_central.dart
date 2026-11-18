import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/central.dart';
import '../core/errors.dart';
import '../core/manager_state.dart';
import '../core/uuid.dart';

/// What the next [MockBleCentral.connect] call should do.
sealed class ConnectBehavior {
  const ConnectBehavior();

  static const ConnectBehavior succeed = _Succeed();
  static const ConnectBehavior timeout = _Timeout();
  const factory ConnectBehavior.fail(BleError error) = _Fail;
}

final class _Succeed extends ConnectBehavior {
  const _Succeed();
}

final class _Timeout extends ConnectBehavior {
  const _Timeout();
}

final class _Fail extends ConnectBehavior {
  const _Fail(this.error);
  final BleError error;
}

/// Creates a stream whose controller is registered in [registry] immediately
/// (so events sent before anyone listens are buffered) and removed on cancel.
Stream<T> _registered<T>(Set<StreamController<T>> registry, [List<T>? seed]) {
  late final StreamController<T> controller;
  // Async onCancel so cancel() returns a future in the caller's zone (a sync
  // onCancel yields a root-zone future that FakeAsync widget tests never flush).
  controller = StreamController<T>(
    onCancel: () async => registry.remove(controller),
  );
  seed?.forEach(controller.add);
  registry.add(controller);
  return controller.stream;
}

/// An in-memory [BleCentral] for tests and simulators. Mirrors SwiftBLEKit's
/// `MockCentralManager`.
class MockBleCentral implements BleCentral {
  MockBleCentral({BleManagerState state = BleManagerState.poweredOn})
    : _state = state;

  BleManagerState _state;
  final Map<String, BlePeripheral> _known = {};
  final Set<String> _connected = {};
  final List<ConnectBehavior> _behaviors = [];
  final List<BleRestorationState> _restorations = [];
  int _connectCalls = 0;

  final Set<StreamController<BleManagerState>> _stateStreams = {};
  final Set<StreamController<BleDiscovery>> _scanStreams = {};
  final Set<StreamController<BleDisconnection>> _dropStreams = {};
  final Set<StreamController<BleRestorationState>> _restoreStreams = {};

  /// How many times [connect] has been called.
  int get connectCallCount => _connectCalls;

  /// Whether [identifier] is currently connected.
  bool isConnected(String identifier) => _connected.contains(identifier);

  /// Registers [peripheral] so [retrievePeripheral] can find it.
  void add(BlePeripheral peripheral) =>
      _known[peripheral.identifier] = peripheral;

  /// Queues behaviours consumed by subsequent [connect] calls, in order.
  /// When the queue is empty, connects succeed.
  void enqueueConnectBehaviors(List<ConnectBehavior> behaviors) =>
      _behaviors.addAll(behaviors);

  void simulateState(BleManagerState state) {
    _state = state;
    for (final c in _stateStreams.toList()) {
      c.add(state);
    }
  }

  void simulateDiscovery(
    BlePeripheral peripheral, {
    AdvertisementData advertisement = const AdvertisementData(),
    int rssi = -60,
  }) {
    add(peripheral);
    final discovery = BleDiscovery(
      peripheral: peripheral,
      advertisement: advertisement,
      rssi: rssi,
    );
    for (final c in _scanStreams.toList()) {
      c.add(discovery);
    }
  }

  /// Drops the link. Unexpected drops carry reason "simulated drop".
  void simulateDisconnect(BlePeripheral peripheral, {bool expected = false}) {
    _connected.remove(peripheral.identifier);
    _emitDrop(
      BleDisconnection(
        identifier: peripheral.identifier,
        error: DisconnectedError(
          isExpected: expected,
          reason: expected ? null : 'simulated drop',
        ),
      ),
    );
  }

  void simulateRestoration(
    List<BlePeripheral> peripherals, {
    List<BleUuid> scanServices = const [],
  }) {
    peripherals.forEach(add);
    final event = BleRestorationState(
      peripherals: peripherals,
      scanServices: scanServices,
    );
    _restorations.add(event);
    for (final c in _restoreStreams.toList()) {
      c.add(event);
    }
  }

  void _emitDrop(BleDisconnection event) {
    for (final c in _dropStreams.toList()) {
      c.add(event);
    }
  }

  @override
  Future<BleManagerState> get state async => _state;

  @override
  Stream<BleManagerState> stateUpdates() =>
      _registered(_stateStreams, [_state]);

  @override
  Stream<BleDiscovery> scan({List<BleUuid>? services}) =>
      _registered(_scanStreams);

  @override
  Future<void> stopScan() async {
    final streams = _scanStreams.toList();
    _scanStreams.clear();
    for (final c in streams) {
      unawaited(c.close());
    }
  }

  @override
  Future<void> connect(BlePeripheral peripheral, {Duration? timeout}) async {
    _connectCalls += 1;
    final behavior = _behaviors.isEmpty
        ? ConnectBehavior.succeed
        : _behaviors.removeAt(0);
    switch (behavior) {
      case _Succeed():
        add(peripheral);
        _connected.add(peripheral.identifier);
      case _Fail(:final error):
        throw error;
      case _Timeout():
        throw const ConnectionTimeoutError();
    }
  }

  @override
  Future<void> disconnect(BlePeripheral peripheral) async {
    if (!_connected.remove(peripheral.identifier)) return;
    _emitDrop(
      BleDisconnection(
        identifier: peripheral.identifier,
        error: const DisconnectedError(isExpected: true),
      ),
    );
  }

  @override
  Stream<BleDisconnection> disconnections() => _registered(_dropStreams);

  @override
  Future<BlePeripheral?> retrievePeripheral(String identifier) async =>
      _known[identifier];

  @override
  Stream<BleRestorationState> restorationEvents() =>
      _registered(_restoreStreams, _restorations);
}

/// An in-memory [BlePeripheral] with a fixed GATT table. Mirrors
/// SwiftBLEKit's `SimulatedPeripheral`.
class SimulatedPeripheral implements BlePeripheral {
  SimulatedPeripheral({
    String? identifier,
    String? name,
    Map<BleUuid, List<BleUuid>> services = const {},
    Map<BleUuid, Uint8List> values = const {},
  }) : identifier = identifier ?? _randomId(),
       _name = name,
       _services = Map.of(services),
       _values = Map.of(values);

  @override
  final String identifier;

  String? _name;
  final Map<BleUuid, List<BleUuid>> _services;
  final Map<BleUuid, Uint8List> _values;
  final Set<BleUuid> _notifying = {};
  final Map<BleUuid, Set<StreamController<Uint8List>>> _streams = {};

  /// Thrown by the next [readValue], then cleared.
  BleError? readError;

  /// Thrown by the next [writeValue], then cleared.
  BleError? writeError;

  static String _randomId() {
    final r = math.Random();
    String hex(int n) => List.generate(
      n,
      (_) => r.nextInt(16).toRadixString(16),
    ).join().toUpperCase();
    return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
  }

  void setName(String? name) => _name = name;

  bool isNotifying(BleUuid characteristic) =>
      _notifying.contains(characteristic);

  /// The stored value of [characteristic] (including written values).
  Uint8List? valueFor(BleUuid characteristic) => _values[characteristic];

  /// Stores [data] and, if notifications are enabled, pushes it.
  void simulateValue(Uint8List data, BleUuid characteristic) {
    _values[characteristic] = data;
    if (!_notifying.contains(characteristic)) return;
    for (final c in (_streams[characteristic] ?? const {}).toList()) {
      c.add(data);
    }
  }

  @override
  Future<String?> get name async => _name;

  @override
  Future<List<BleUuid>> discoverServices([List<BleUuid>? services]) async {
    if (services == null) return _services.keys.toList();
    return services.where(_services.containsKey).toList();
  }

  @override
  Future<List<BleUuid>> discoverCharacteristics(
    List<BleUuid>? characteristics, {
    required BleUuid service,
  }) async {
    final all = _services[service];
    if (all == null) throw ServiceNotFoundError(service);
    if (characteristics == null) return List.of(all);
    return characteristics.where(all.contains).toList();
  }

  @override
  Future<Uint8List> readValue(BleUuid characteristic) async {
    final error = readError;
    if (error != null) {
      readError = null;
      throw error;
    }
    final value = _values[characteristic];
    if (value == null) throw CharacteristicNotFoundError(characteristic);
    return value;
  }

  @override
  Future<void> writeValue(
    Uint8List data,
    BleUuid characteristic, {
    bool withResponse = true,
  }) async {
    final error = writeError;
    if (error != null) {
      writeError = null;
      throw error;
    }
    _values[characteristic] = data;
  }

  @override
  Future<void> setNotify(bool enabled, BleUuid characteristic) async {
    if (enabled) {
      _notifying.add(characteristic);
    } else {
      _notifying.remove(characteristic);
    }
  }

  @override
  Stream<Uint8List> notifications(BleUuid characteristic) =>
      _registered(_streams.putIfAbsent(characteristic, () => {}));
}
