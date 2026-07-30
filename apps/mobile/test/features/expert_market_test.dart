import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';

void main() {
  testWidgets(
    'market exposes 50 experts without a visible horizontal scrollbar',
    (tester) async {
      await tester.pumpWidget(const HaloApp(initialLocation: '/market'));
      await tester.pumpAndSettle();

      expect(find.text('AI 市场'), findsOneWidget);
      expect(find.text('已显示 50 / 50'), findsOneWidget);
      expect(find.text('任务规划师'), findsOneWidget);
      expect(find.text('法律财税'), findsOneWidget);
    },
  );

  testWidgets('installed expert profile and data expose executable settings', (
    tester,
  ) async {
    await tester.pumpWidget(const HaloApp(initialLocation: '/expert/general'));
    await tester.pumpAndSettle();

    expect(find.text('Agent 资料'), findsOneWidget);
    expect(find.text('发消息'), findsOneWidget);
    expect(find.text('语音通话'), findsOneWidget);
    expect(find.text('视频通话'), findsOneWidget);
    expect(find.text('专家数据'), findsOneWidget);
  });

  testWidgets('installed profile shows catalog skills and tool permissions', (
    tester,
  ) async {
    await tester.pumpWidget(const HaloApp(initialLocation: '/expert/general'));
    await tester.pumpAndSettle();

    // 'general' binds canonical expert 'project-manager'.
    expect(find.text('技能'), findsOneWidget);
    expect(find.text('project.planning'), findsOneWidget);
    expect(find.text('dependency.management'), findsOneWidget);
    expect(find.text('risk.tracking'), findsOneWidget);
    expect(find.text('工具权限'), findsOneWidget);
    expect(find.textContaining('web.search'), findsOneWidget);
    expect(find.textContaining('需授权'), findsOneWidget);
    expect(find.textContaining('已禁用'), findsOneWidget);
  });

  testWidgets('market profile resolves catalog facts for a mapped expert', (
    tester,
  ) async {
    await tester.pumpWidget(const HaloApp(initialLocation: '/market/market-5'));
    await tester.pumpAndSettle();

    // 'market-5' maps to canonical expert 'project-manager'.
    expect(find.text('专家简介'), findsOneWidget);
    expect(find.text('技能'), findsOneWidget);
    expect(find.text('project.planning'), findsOneWidget);
    expect(find.text('工具权限'), findsOneWidget);
  });

  testWidgets('market bottom actions stay on a single line on narrow phones', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const HaloApp(initialLocation: '/market/market-5'));
    await tester.pumpAndSettle();

    for (final label in const ['先聊聊', '添加到群聊', '添加到专家团']) {
      final size = tester.getSize(find.text(label));
      expect(
        size.height,
        lessThan(24),
        reason: '$label should render on one line',
      );
    }
  });
}
