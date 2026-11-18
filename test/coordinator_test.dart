import 'dart:async';

import 'package:flutter_blekit/flutter_blekit.dart';
import 'package:flutter_blekit/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const _noJitter = ExponentialBackoff(jitter: 0);

void main() {
  late MockBleCentral central;
  late SimulatedPeripheral device;
  late List<Duration> sleeps;

  Future<void> instantSleep(Duration d) async => sleeps.add(d);

  ConnectionCoordinator make({
    ExponentialBackoff backoff = _noJitter,
    BleSleep? sleep,
  }) => ConnectionCoordinator(
    central: central,
    peripheral: device,
    backoff: backoff,
    sleep: sleep ?? instantSleep,
  );

  setUp(() {
    central = MockBleCentral();
    device = SimulatedPeripheral(identifier: 'A');
    sleeps = [];
  });

  test('publishes disconnected -> connecting -> connected', () async {
    final c = make();
    final states = record(c.states());
    c.start();
    await settle();
    expect(states, [
      BleConnectionState.disconnected,
      BleConnectionState.connecting,
      BleConnectionState.connected,
    ]);
    expect(central.isConnected('A'), isTrue);
  });

  test('reconnects after an unexpected drop', () async {
    final c = make();
    final states = record(c.states());
    c.start();
    await settle();
    central.simulateDisconnect(device);
    await settle();
    expect(states, [
      BleConnectionState.disconnected,
      BleConnectionState.connecting,
      BleConnectionState.connected,
      const BleConnectionState.reconnecting(1),
      BleConnectionState.connected,
    ]);
    expect(central.connectCallCount, 2);
    expect(sleeps, [const Duration(milliseconds: 500)]);
  });

  test('an expected drop ends in disconnected without reconnecting', () async {
    final c = make();
    final states = record(c.states());
    c.start();
    await settle();
    central.simulateDisconnect(device, expected: true);
    await settle();
    expect(states.last, BleConnectionState.disconnected);
    expect(central.connectCallCount, 1);
  });

  test('ignores drops of other peripherals', () async {
    final c = make();
    c.start();
    await settle();
    central.simulateDisconnect(SimulatedPeripheral(identifier: 'B'));
    await settle();
    expect(c.state, BleConnectionState.connected);
    expect(central.connectCallCount, 1);
  });

  test('fails with ReconnectionExhaustedError after the budget', () async {
    central.enqueueConnectBehaviors(
      List.filled(5, const ConnectBehavior.fail(UnderlyingBleError('boom'))),
    );
    final c = make(
      backoff: const ExponentialBackoff(maxAttempts: 2, jitter: 0),
    );
    final states = record(c.states());
    c.start();
    await settle();
    expect(states, [
      BleConnectionState.disconnected,
      BleConnectionState.connecting,
      const BleConnectionState.reconnecting(1),
      const BleConnectionState.reconnecting(2),
      const BleConnectionState.failed(ReconnectionExhaustedError(3)),
    ]);
    expect(central.connectCallCount, 3);
    expect(c.state.isTerminal, isTrue);
  });

  test('maxAttempts 0 fails on the first error', () async {
    central.enqueueConnectBehaviors([ConnectBehavior.timeout]);
    final c = make(backoff: const ExponentialBackoff(maxAttempts: 0));
    c.start();
    await settle();
    expect(
      c.state,
      const BleConnectionState.failed(ReconnectionExhaustedError(1)),
    );
    expect(central.connectCallCount, 1);
  });

  test('a timeout counts as a failed attempt', () async {
    central.enqueueConnectBehaviors([ConnectBehavior.timeout]);
    final c = make();
    final states = record(c.states());
    c.start();
    await settle();
    expect(states, contains(const BleConnectionState.reconnecting(1)));
    expect(c.state, BleConnectionState.connected);
    expect(central.connectCallCount, 2);
  });

  test('backoff delays grow exponentially between attempts', () async {
    central.enqueueConnectBehaviors(
      List.filled(3, const ConnectBehavior.fail(UnderlyingBleError('x'))),
    );
    final c = make();
    c.start();
    await settle();
    expect(sleeps, const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
    ]);
    expect(c.state, BleConnectionState.connected);
  });

  test('the attempt budget resets after a successful connection', () async {
    central.enqueueConnectBehaviors([
      const ConnectBehavior.fail(UnderlyingBleError('1')),
      ConnectBehavior.succeed,
    ]);
    // One retry allowed. The initial failure uses it; after connecting, the
    // drop must get a fresh budget (without a reset it would fail at once).
    final c = make(
      backoff: const ExponentialBackoff(maxAttempts: 1, jitter: 0),
    );
    final states = record(c.states());
    c.start();
    await settle();
    expect(c.state, BleConnectionState.connected);
    central.simulateDisconnect(device);
    await settle();
    expect(c.state, BleConnectionState.connected);
    expect(central.connectCallCount, 3);
    expect(
      states.where((s) => s == const BleConnectionState.reconnecting(1)),
      hasLength(2),
    );
  });

  test(
    'stop() during backoff is prompt and prevents further attempts',
    () async {
      central.enqueueConnectBehaviors([
        const ConnectBehavior.fail(UnderlyingBleError('x')),
      ]);
      final never = Completer<void>();
      final c = make(sleep: (_) => never.future);
      final states = record(c.states());
      c.start();
      await settle();
      expect(c.state, const BleConnectionState.reconnecting(1));

      await c.stop().timeout(const Duration(seconds: 1));
      await settle();
      expect(c.state, BleConnectionState.disconnected);
      expect(central.connectCallCount, 1);
      expect(states.last, BleConnectionState.disconnected);
    },
  );

  test('stop() while connected disconnects without reconnecting', () async {
    final c = make();
    c.start();
    await settle();
    await c.stop();
    await settle();
    expect(c.state, BleConnectionState.disconnected);
    expect(central.isConnected('A'), isFalse);
    expect(central.connectCallCount, 1);
  });

  test('can be restarted after stop()', () async {
    final c = make();
    c.start();
    await settle();
    await c.stop();
    await settle();
    c.start();
    await settle();
    expect(c.state, BleConnectionState.connected);
    expect(central.connectCallCount, 2);
  });

  test('can be restarted after failing', () async {
    central.enqueueConnectBehaviors([ConnectBehavior.timeout]);
    final c = make(backoff: const ExponentialBackoff(maxAttempts: 0));
    c.start();
    await settle();
    expect(c.state.isTerminal, isTrue);
    c.start();
    await settle();
    expect(c.state, BleConnectionState.connected);
  });

  test('start() while running is a no-op', () async {
    final c = make();
    c.start();
    c.start();
    await settle();
    expect(central.connectCallCount, 1);
  });

  test(
    'states() supports independent listeners that start at current',
    () async {
      final c = make();
      final first = record(c.states());
      c.start();
      await settle();
      final late = record(c.states());
      await settle();
      expect(first.last, BleConnectionState.connected);
      expect(late, [BleConnectionState.connected]);
    },
  );

  test('a throwing sleep ends the run as disconnected', () async {
    central.enqueueConnectBehaviors([ConnectBehavior.timeout]);
    final c = make(sleep: (_) async => throw StateError('no timers'));
    c.start();
    await settle();
    expect(c.state, BleConnectionState.disconnected);
    expect(central.connectCallCount, 1);
  });
}
