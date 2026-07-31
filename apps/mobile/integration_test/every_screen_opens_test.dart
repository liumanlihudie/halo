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

    await settle(30);
    for (final tab in const ['对话', '专家团', '圈层', '设置']) {
      await openTab(tab);
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
