// One app instance per process: the production kernel owns exclusive SQLite and
// outbox files, so several HaloApp instances in one test process contend for
// them and produce failures the real app can never hit.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('single chat sends a real message and reports a real outcome', (
    tester,
  ) async {
    await tester.pumpWidget(
      const HaloApp(initialLocation: '/chat/general-assistant'),
    );

    // Bounded pumps: a running turn animates forever, so pumpAndSettle cannot
    // be used anywhere on this screen.
    Future<void> settle([int steps = 40]) async {
      for (var i = 0; i < steps; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    List<String> visibleText() => tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .where((text) => text.isNotEmpty)
        .toList();

    await settle();
    // ignore: avoid_print
    print('AFTER BOOT >>> ${visibleText().join(" | ")}');

    expect(
      find.text('聊天存储暂不可用，请稍后重试'),
      findsNothing,
      reason: 'the production kernel must have replaced the unavailable one',
    );

    final composer = find.byType(TextField).last;
    await tester.enterText(composer, '你好，请做个自我介绍');
    await tester.pump();
    // Enter sends: the send button was removed, and a test still reaching for
    // it fails for a reason that has nothing to do with the product.
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await settle(80);

    // ignore: avoid_print
    print('AFTER SEND >>> ${visibleText().join(" | ")}');

    expect(find.text('你好，请做个自我介绍'), findsOneWidget);
  });
}
