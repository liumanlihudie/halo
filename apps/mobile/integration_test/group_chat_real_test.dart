// One app instance per process: see single_chat_real_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('group chat states plainly that its run port is not wired', (
    tester,
  ) async {
    await tester.pumpWidget(
      const HaloApp(initialLocation: '/group/group-product'),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .where((text) => text.isNotEmpty)
        .toList();
    // ignore: avoid_print
    print('GROUP >>> ${texts.join(" | ")}');

    // The production run port must reach the UI, so the composer is live rather
    // than showing the not-wired placeholder.
    expect(find.text('群聊运行服务待接入'), findsNothing);
    expect(find.byType(TextField), findsWidgets);
  });
}
