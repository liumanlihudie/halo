// One app instance per process: see single_chat_real_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('expert profile exposes actions and the real model binding', (
    tester,
  ) async {
    await tester.pumpWidget(const HaloApp(initialLocation: '/expert/product'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .where((text) => text.isNotEmpty)
        .toList();
    // ignore: avoid_print
    print('PROFILE >>> ${texts.join(" | ")}');

    expect(find.text('发消息'), findsOneWidget);
    expect(find.text('语音通话'), findsOneWidget);
    expect(find.text('视频通话'), findsOneWidget);
    // The routing row only renders once the production kernel published a
    // ModelRoutingController, so this also proves the kernel swap reached the UI.
    expect(find.text('模型'), findsOneWidget);
  });
}
