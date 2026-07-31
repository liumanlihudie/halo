// Walks the app on a real device the way a person would, asserting only that
// nothing throws. Unit tests missed three unregistered icon names that threw
// the moment their screen was opened; this is the cheapest net for that class.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every reachable screen opens without throwing', (tester) async {
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details.exceptionAsString());
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);

    await tester.pumpWidget(const HaloApp());

    // Bounded pumps everywhere: a live kernel keeps animating, so
    // pumpAndSettle would hang rather than fail.
    Future<void> settle([int steps = 20]) async {
      for (var i = 0; i < steps; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> openTab(String label) async {
      final tab = find.text(label);
      if (tab.evaluate().isEmpty) return;
      await tester.tap(tab.last);
      await settle();
    }

    Future<void> openRow(String label) async {
      final row = find.text(label);
      if (row.evaluate().isEmpty) return;
      await tester.tap(row.first);
      await settle();
      final back = find.bySemanticsLabel('返回');
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back.first);
        await settle();
      }
    }

    Future<void> tapBack() async {
      final back = find.bySemanticsLabel('返回');
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back.first);
        await settle();
      }
    }

    await settle(30);
    for (final tab in const ['对话', '专家团', '圈层', '设置']) {
      await openTab(tab);
    }

    // The market: banner → list → one profile that is executable and one
    // that is not.
    await openTab('专家团');
    await openRow('AI 市场');
    if (find.text('AI 市场').evaluate().isNotEmpty) {
      await tester.tap(find.text('AI 市场').last);
      await settle();
      for (final market in const ['任务规划师', '项目协调员']) {
        final row = find.text(market);
        if (row.evaluate().isNotEmpty) {
          await tester.tap(row.first);
          await settle();
          await tapBack();
        }
      }
      await tapBack();
    }

    // An installed expert's profile.
    await openTab('专家团');
    await openRow('产品经理');

    // A conversation, its details and its history with every category.
    await openTab('对话');
    final conversation = find.text('Halo 助理');
    if (conversation.evaluate().isNotEmpty) {
      await tester.tap(conversation.first);
      await settle();
      final details = find.bySemanticsLabel('聊天详情');
      if (details.evaluate().isNotEmpty) {
        await tester.tap(details.first);
        await settle();
        await openRow('查找聊天记录');
        for (final category in const ['图片与视频', '文件', '链接', 'AI 成果']) {
          final shortcut = find.text(category);
          if (shortcut.evaluate().isNotEmpty) {
            await tester.tap(shortcut.first);
            await settle();
            await tapBack();
          }
        }
        await tapBack();
      }
      await tapBack();
    }

    // Settings is where the unregistered icons lived.
    await openTab('设置');
    for (final row in const [
      '模型服务',
      '资讯中心',
      '语音与通话 Key',
      '自托管 Gateway',
      '本地数据与备份',
    ]) {
      await openRow(row);
    }

    expect(
      errors,
      isEmpty,
      reason: 'opening a screen threw:\n${errors.join("\n")}',
    );
  });
}
