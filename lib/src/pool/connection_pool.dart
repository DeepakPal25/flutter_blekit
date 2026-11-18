import 'dart:async';

import '../connection/coordinator.dart';
import '../core/backoff.dart';
import '../core/central.dart';
import '../core/connection_state.dart';

/// A state change for one pooled peripheral.
final class PoolEvent {
  const PoolEvent(this.identifier, this.state);

  final String identifier;
  final BleConnectionState state;

  @override
  bool operator ==(Object other) =>
      other is PoolEvent &&
      other.identifier == identifier &&
      other.state == state;

  @override
  int get hashCode => Object.hash(identifier, state);

  @override
  String toString() => 'PoolEvent($identifier, $state)';
}

class _Entry {
  _Entry(this.peripheral, this.priority, this.order);

  final BlePeripheral peripheral;
  final int priority;
  final int order;
  BleConnectionState state = BleConnectionState.disconnected;
  ConnectionCoordinator? coordinator;
  StreamSubscription<BleConnectionState>? observer;
}

/// Manages many peripherals, keeping at most [maxConcurrent] actively
/// connecting/connected. Extra peripherals wait in a priority queue and are
/// promoted when a slot frees up. Mirrors SwiftBLEKit's `ConnectionPool`.
class ConnectionPool {
  ConnectionPool({
    required this.central,
    int maxConcurrent = 4,
    this.backoff = const ExponentialBackoff(),
    this.connectTimeout = const Duration(seconds: 10),
    BleSleep? sleep,
    double Function()? random,
  }) : maxConcurrent = maxConcurrent < 1 ? 1 : maxConcurrent,
       _sleep = sleep,
       _random = random;

  final BleCentral central;
  final int maxConcurrent;
  final ExponentialBackoff backoff;
  final Duration? connectTimeout;
  final BleSleep? _sleep;
  final double Function()? _random;

  final Map<String, _Entry> _entries = {};
  final List<String> _waiting = [];
  final StreamController<PoolEvent> _events =
      StreamController<PoolEvent>.broadcast(sync: true);
  int _activeCount = 0;
  int _insertions = 0;

  /// Every state change of every pooled peripheral.
  Stream<PoolEvent> get events => _events.stream;

  /// Peripherals currently holding a slot.
  int get activeConnections => _activeCount;

  /// Peripherals waiting for a slot.
  int get queuedCount => _waiting.length;

  /// The last known state of [identifier], or null if it is not pooled.
  BleConnectionState? state(String identifier) => _entries[identifier]?.state;

  /// Adds [peripheral] to the pool. Higher [priority] is promoted first;
  /// equal priorities are promoted in insertion order. Duplicates are ignored.
  void manage(BlePeripheral peripheral, {int priority = 0}) {
    final id = peripheral.identifier;
    if (_entries.containsKey(id)) return;
    _entries[id] = _Entry(peripheral, priority, _insertions++);
    if (_activeCount < maxConcurrent) {
      _activate(id);
    } else {
      _waiting.add(id);
    }
  }

  /// Removes [identifier] from the pool, disconnecting it if active.
  Future<void> drop(String identifier) async {
    final entry = _entries.remove(identifier);
    if (entry == null) return;
    _waiting.remove(identifier);
    await entry.observer?.cancel();
    entry.observer = null;
    final coordinator = entry.coordinator;
    entry.coordinator = null;
    if (coordinator != null) {
      _activeCount -= 1;
      await coordinator.stop();
      _promoteNext();
    }
  }

  /// Drops every peripheral.
  Future<void> stopAll() async {
    for (final id in _entries.keys.toList()) {
      await drop(id);
    }
  }

  void _activate(String id) {
    final entry = _entries[id];
    if (entry == null) return;
    final coordinator = ConnectionCoordinator(
      central: central,
      peripheral: entry.peripheral,
      backoff: backoff,
      connectTimeout: connectTimeout,
      sleep: _sleep ?? (d) => Future<void>.delayed(d),
      random: _random,
    );
    entry.coordinator = coordinator;
    _activeCount += 1;
    entry.observer = coordinator.states().listen(
      (state) => _handleStateChange(id, coordinator, state),
    );
    coordinator.start();
  }

  void _handleStateChange(
    String id,
    ConnectionCoordinator coordinator,
    BleConnectionState state,
  ) {
    final entry = _entries[id];
    if (entry == null || !identical(entry.coordinator, coordinator)) return;
    entry.state = state;
    _events.add(PoolEvent(id, state));
    if (state.isTerminal) _finishActive(entry);
  }

  /// A terminal failure frees the slot; the entry stays visible as failed.
  void _finishActive(_Entry entry) {
    unawaited(entry.observer?.cancel());
    entry.observer = null;
    entry.coordinator = null;
    _activeCount -= 1;
    _promoteNext();
  }

  void _promoteNext() {
    while (_activeCount < maxConcurrent && _waiting.isNotEmpty) {
      var best = 0;
      for (var i = 1; i < _waiting.length; i++) {
        final candidate = _entries[_waiting[i]]!;
        final current = _entries[_waiting[best]]!;
        if (candidate.priority > current.priority ||
            (candidate.priority == current.priority &&
                candidate.order < current.order)) {
          best = i;
        }
      }
      _activate(_waiting.removeAt(best));
    }
  }
}
