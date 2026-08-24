import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:streamer_co_pilot/providers/streamer_bot_provider.dart';
import 'package:streamer_co_pilot/widgets/alert_overlay.dart';

void main() {
  Widget wrap(StreamerBotProvider provider) => ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: AlertOverlay())),
      );

  testWidgets('shows nothing when no current alert', (tester) async {
    final provider = StreamerBotProvider();
    await tester.pumpWidget(wrap(provider));
    expect(find.byType(AlertOverlay), findsOneWidget);
    expect(find.textContaining('RAIDING'), findsNothing);
  });

  testWidgets('renders a raid alert with viewer count', (tester) async {
    final provider = StreamerBotProvider();
    // Use the public SSE handler to inject an alert.
    provider.handleSseEventForTest('channel_event', {
      'type': 'raid',
      'user': 'alice',
      'count': 42,
    });
    await tester.pumpWidget(wrap(provider));
    await tester.pumpAndSettle();

    expect(find.text('alice  IS RAIDING  42 viewers!'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7)); // flush dismiss timer
  });

  testWidgets('renders a resub with message', (tester) async {
    final provider = StreamerBotProvider();
    provider.handleSseEventForTest('channel_event', {
      'type': 'resub',
      'user': 'bob',
      'count': 12,
      'message': 'love the streams',
    });
    await tester.pumpWidget(wrap(provider));
    await tester.pumpAndSettle();

    expect(find.text('bob  RESUBSCRIBED  12 months!'), findsOneWidget);
    expect(find.text('"love the streams"'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7)); // flush dismiss timer
  });

  testWidgets('unknown event type falls back to generic styling', (tester) async {
    final provider = StreamerBotProvider();
    provider.handleSseEventForTest('channel_event', {
      'type': 'mystery',
      'user': 'carol',
    });
    await tester.pumpWidget(wrap(provider));
    await tester.pumpAndSettle();
    expect(find.textContaining('MYSTERY'), findsOneWidget); // Text.rich span
    await tester.pump(const Duration(seconds: 7)); // flush dismiss timer
  });
}
