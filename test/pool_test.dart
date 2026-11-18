import 'package:flutter_blekit/flutter_blekit.dart';
import 'package:flutter_blekit/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late MockBleCentral central;

  Future<void> instant(Duration _) async {}

  ConnectionPool make({
    int maxConcurrent = 2,
    ExponentialBackoff backoff = const ExponentialBackoff(jitter: 0),
  }) => ConnectionPool(
    central: central,
    maxConcurrent: maxConcurrent,
    backoff: backoff,
    sleep: instant,
  );

  SimulatedPeripheral p(String id) => SimulatedPeripheral(identifier: id);

  setUp(() => central = MockBleCentral());

  test('caps active connections at maxConcurrent', () async {
    final pool = make();
    pool
      ..manage(p('A'))
      ..manage(p('B'))
      ..manage(p('C'));
    await settle();
    expect(pool.activeConnections, 2);
    expect(pool.queuedCount, 1);
    expect(pool.state('A'), BleConnectionState.connected);
    expect(pool.state('B'), BleConnectionState.connected);
    expect(pool.state('C'), BleConnectionState.disconnected);
    expect(central.isConnected('C'), isFalse);
  });

  test('promotes the highest-priority waiter when a slot frees', () async {
    final pool = make(maxConcurrent: 1);
    pool
      ..manage(p('A'))
      ..manage(p('low'), priority: 1)
      ..manage(p('high'), priority: 5);
    await settle();
    await pool.drop('A');
    await settle();
    expect(pool.state('high'), BleConnectionState.connected);
    expect(pool.state('low'), BleConnectionState.disconnected);
    expect(pool.queuedCount, 1);
  });

  test('equal priorities are promoted in insertion order', () async {
    final pool = make(maxConcurrent: 1);
    pool
      ..manage(p('A'))
      ..manage(p('B'))
      ..manage(p('C'));
    await settle();
    await pool.drop('A');
    await settle();
    expect(pool.state('B'), BleConnectionState.connected);
    expect(pool.state('C'), BleConnectionState.disconnected);
  });

  test(
    'a terminal failure frees the slot and the entry stays failed',
    () async {
      central.enqueueConnectBehaviors([
        const ConnectBehavior.fail(UnderlyingBleError('nope')),
      ]);
      final pool = make(
        maxConcurrent: 1,
        backoff: const ExponentialBackoff(maxAttempts: 0),
      );
      pool
        ..manage(p('A'))
        ..manage(p('B'));
      await settle();
      expect(pool.state('A')?.isTerminal, isTrue);
      expect(
        pool.state('A'),
        const BleConnectionState.failed(ReconnectionExhaustedError(1)),
      );
      expect(pool.state('B'), BleConnectionState.connected);
      expect(pool.activeConnections, 1);
      expect(pool.queuedCount, 0);
    },
  );

  test('managing the same peripheral twice is ignored', () async {
    final pool = make();
    pool
      ..manage(p('A'))
      ..manage(p('A'));
    await settle();
    expect(pool.activeConnections, 1);
    expect(central.connectCallCount, 1);
  });

  test('events report every state change per peripheral', () async {
    final pool = make();
    final events = record(pool.events);
    pool.manage(p('A'));
    await settle();
    expect(events, const [
      PoolEvent('A', BleConnectionState.disconnected),
      PoolEvent('A', BleConnectionState.connecting),
      PoolEvent('A', BleConnectionState.connected),
    ]);
  });

  test('stopAll disconnects and forgets everything', () async {
    final pool = make();
    pool
      ..manage(p('A'))
      ..manage(p('B'))
      ..manage(p('C'));
    await settle();
    await pool.stopAll();
    await settle();
    expect(pool.activeConnections, 0);
    expect(pool.queuedCount, 0);
    expect(pool.state('A'), isNull);
    expect(central.isConnected('A'), isFalse);
    expect(central.isConnected('B'), isFalse);
    expect(central.isConnected('C'), isFalse);
  });

  test('maxConcurrent below 1 is clamped to 1', () async {
    final pool = make(maxConcurrent: 0);
    expect(pool.maxConcurrent, 1);
    pool
      ..manage(p('A'))
      ..manage(p('B'));
    await settle();
    expect(pool.activeConnections, 1);
    expect(pool.queuedCount, 1);
  });

  test('dropping a queued peripheral removes it without connecting', () async {
    final pool = make(maxConcurrent: 1);
    pool
      ..manage(p('A'))
      ..manage(p('B'));
    await settle();
    await pool.drop('B');
    expect(pool.queuedCount, 0);
    expect(pool.state('B'), isNull);
    await pool.drop('A');
    await settle();
    expect(central.connectCallCount, 1);
  });
}
