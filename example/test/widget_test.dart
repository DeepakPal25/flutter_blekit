import 'package:flutter/material.dart';
import 'package:flutter_blekit_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('simulated HRM: scan, connect, drop, reconnect, disconnect', (
    tester,
  ) async {
    await tester.pumpWidget(const BleKitDemoApp());
    await tester.pump();
    expect(find.text('Bluetooth: poweredOn'), findsOneWidget);

    await tester.tap(find.text('Scan'));
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(find.text('Simulated HRM'), findsOneWidget);

    await tester.tap(find.text('Simulated HRM'));
    // Not pumpAndSettle: the 1s heartbeat keeps scheduling frames once connected.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('State: connected'), findsOneWidget);
    expect(find.text('Battery: 87%'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining(' bpm'), findsOneWidget);
    expect(find.textContaining(RegExp(r'RR: \d+ ms')), findsOneWidget);

    await tester.tap(find.text('Simulate drop'));
    await tester.pump();
    expect(find.text('State: reconnecting(attempt: 1)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('State: connected'), findsOneWidget);

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
  });
}
