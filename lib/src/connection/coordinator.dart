import 'dart:async';

import '../core/backoff.dart';
import '../core/central.dart';
import '../core/connection_state.dart';
import '../core/errors.dart';

/// An injectable delay, so tests can drive backoff without real time.
typedef BleSleep = Future<void> Function(Duration delay);

Future<void> _defaultSleep(Duration delay) => Future<void>.delayed(delay);

/// Drives one peripheral connection through its lifecycle, reconnecting on
/// unexpected drops with [ExponentialBackoff]. Mirrors SwiftBLEKit's
/// `ConnectionCoordinator`.
///
/// Observe [states]; call [start] to begin and [stop] to tear down. An
/// app-initiated (expected) disconnect never triggers reconnection.
class ConnectionCoordinator {
  ConnectionCoordinator({
    required this.central,
    required this.peripheral,
    this.backoff = const ExponentialBackoff(),
    this.connectTimeout = const Duration(seconds: 10),
    BleSleep sleep = _defaultSleep,
    double Function()? random,
  }) : _sleep = sleep,
       _random = random;

  final BleCentral central;
  final BlePeripheral peripheral;
  final ExponentialBackoff backoff;

  /// Per-attempt connect timeout; `null` waits indefinitely.
  final Duration? connectTimeout;

  final BleSleep _sleep;
  final double Function()? _random;

  final StreamController<BleConnectionState> _changes =
      StreamController<BleConnectionState>.broadcast(sync: true);

  BleConnectionState _state = BleConnectionState.disconnected;

  /// Identifies the current run; bumped by [stop] so a stale run exits.
  int _runId = 0;
  bool _running = false;
  Completer<void>? _cancelled;
  Completer<BleDisconnection?>? _dropWaiter;
  StreamSubscription<BleDisconnection>? _dropSub;

  /// The current connection state.
  BleConnectionState get state => _state;

  /// State transitions, starting with the current state. Each call returns an
  /// independent single-subscription stream.
  Stream<BleConnectionState> states() {
    late final StreamController<BleConnectionState> controller;
    StreamSubscription<BleConnectionState>? forward;
    controller = StreamController<BleConnectionState>(
      onListen: () {
        controller.add(_state);
        forward = _changes.stream.listen(controller.add);
      },
      onCancel: () => forward?.cancel(),
    );
    return controller.stream;
  }

  /// Begins connecting. Does nothing if a run is already active.
  void start() {
    if (_running) return;
    _running = true;
    final id = ++_runId;
    _cancelled = Completer<void>();
    _dropSub = central
        .disconnections()
        .where((event) => event.identifier == peripheral.identifier)
        .listen(_onDisconnection);
    unawaited(_run(id));
  }

  /// Stops managing the connection and disconnects. Treated as an expected
  /// teardown: no reconnection follows.
  Future<void> stop() async {
    _runId++;
    _endRun();
    await central.disconnect(peripheral);
    _setState(BleConnectionState.disconnected);
  }

  void _onDisconnection(BleDisconnection event) {
    final waiter = _dropWaiter;
    _dropWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(event);
  }

  void _endRun() {
    _running = false;
    final cancelled = _cancelled;
    _cancelled = null;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
    final waiter = _dropWaiter;
    _dropWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(null);
    unawaited(_dropSub?.cancel());
    _dropSub = null;
  }

  bool _isCurrent(int id) => id == _runId;

  Future<void> _run(int id) async {
    var completed = 0;
    while (_isCurrent(id)) {
      _setState(
        completed == 0
            ? BleConnectionState.connecting
            : BleConnectionState.reconnecting(completed),
      );

      try {
        await central.connect(peripheral, timeout: connectTimeout);
      } catch (_) {
        if (!_isCurrent(id)) return;
        completed += 1;
        if (!await _scheduleRetry(id, completed)) break;
        continue;
      }
      if (!_isCurrent(id)) return;

      // Connected: reset the budget and wait for a drop. The waiter is armed
      // before the state is published so an immediate drop is not missed.
      completed = 0;
      final waiter = Completer<BleDisconnection?>();
      _dropWaiter = waiter;
      _setState(BleConnectionState.connected);

      final drop = await waiter.future;
      if (!_isCurrent(id)) return;
      if (drop == null || drop.isExpected) {
        // Expected teardown not initiated by stop(): reflect it.
        _setState(BleConnectionState.disconnected);
        break;
      }

      completed += 1;
      if (!await _scheduleRetry(id, completed)) break;
    }
    // The loop ended on its own (failed or expected disconnect): allow a
    // later start().
    if (_isCurrent(id)) _endRun();
  }

  /// Applies the backoff delay. Returns false (after publishing `failed`)
  /// when the budget is exhausted, or when the run was stopped meanwhile.
  Future<bool> _scheduleRetry(int id, int completed) async {
    if (!backoff.allowsAttempt(after: completed - 1)) {
      _setState(
        BleConnectionState.failed(ReconnectionExhaustedError(completed)),
      );
      return false;
    }
    _setState(BleConnectionState.reconnecting(completed));
    final delay = backoff.delay(completed, randomUnit: _random?.call());
    final cancelled = _cancelled;
    try {
      await Future.any<void>([
        _sleep(delay),
        if (cancelled != null) cancelled.future,
      ]);
    } catch (_) {
      if (_isCurrent(id)) _setState(BleConnectionState.disconnected);
      return false;
    }
    return _isCurrent(id);
  }

  void _setState(BleConnectionState next) {
    // Collapse consecutive duplicates (e.g. reconnecting(n) is published by
    // the retry step and again at the top of the loop).
    if (next == _state) return;
    _state = next;
    _changes.add(next);
  }
}
