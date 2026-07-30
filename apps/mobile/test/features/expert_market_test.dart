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

  testWidgets('expert data page renders the real executable profile', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const HaloApp(initialLocation: '/expert/general/data'),
    );
    await tester.pumpAndSettle();

    // 'general' binds canonical expert 'project-manager'.
    expect(find.text('专家数据'), findsOneWidget);
    expect(find.text('Halo 助理'), findsOneWidget);

    // 提示词: the real system prompt, personality, and constraints.
    expect(find.text('提示词'), findsOneWidget);
    expect(find.textContaining('你是本次任务中被明确指派的Halo 助理'), findsOneWidget);
    expect(find.textContaining('直接、务实、说人话'), findsOneWidget);
    expect(find.textContaining('保持halo-assistant职责边界'), findsOneWidget);

    // 技能与路由: routing card capabilities, intents, negative triggers.
    expect(find.text('技能与路由'), findsOneWidget);
    expect(find.text('general.assistance'), findsOneWidget);
    expect(find.text('writing.support'), findsOneWidget);
    expect(find.text('explanation.support'), findsOneWidget);
    expect(find.textContaining('通用问答'), findsOneWidget);
    expect(find.text('拒绝触发'), findsOneWidget);
    expect(find.textContaining('伪造事实'), findsOneWidget);

    // 工具权限: the three real decisions from the tool policy.
    expect(find.text('工具权限'), findsOneWidget);
    expect(find.text('可用'), findsOneWidget);
    expect(find.text('web.search'), findsOneWidget);
    expect(find.text('需授权'), findsOneWidget);
    expect(find.textContaining('artifact.read'), findsOneWidget);
    expect(find.text('已禁用'), findsOneWidget);
    expect(find.textContaining('shell.execute'), findsOneWidget);

    // 输出合同: schema id, fields, and the honest validation caveat.
    expect(find.text('输出合同'), findsOneWidget);
    expect(find.text('halo-assistant-answer.v1'), findsOneWidget);
    expect(find.textContaining('Recommendations'), findsOneWidget);
    expect(find.text('结构化校验 · 建议式回答（未核验）'), findsOneWidget);

    // 记忆策略: readable scopes and retention, no invented counts.
    expect(find.text('记忆策略'), findsOneWidget);
    expect(find.textContaining('会话上下文'), findsOneWidget);
    expect(find.text('仅本次会话'), findsOneWidget);
    expect(find.textContaining('私有关系记忆'), findsNothing);
    expect(find.textContaining('18 条'), findsNothing);
    expect(find.textContaining('128 条'), findsNothing);
  });

  testWidgets('expert data page degrades gracefully without a catalog entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      const HaloApp(initialLocation: '/expert/market-1/data'),
    );
    await tester.pumpAndSettle();

    expect(find.text('专家数据'), findsOneWidget);
    expect(find.text('任务规划师'), findsOneWidget);
    expect(find.text('该专家暂无可执行数据'), findsOneWidget);
  });

  testWidgets('installed profile shows catalog skills and tool permissions', (
    tester,
  ) async {
    await tester.pumpWidget(const HaloApp(initialLocation: '/expert/general'));
    await tester.pumpAndSettle();

    // 'general' binds canonical expert 'project-manager'.
    expect(find.text('技能'), findsOneWidget);
    expect(find.text('general.assistance'), findsOneWidget);
    expect(find.text('writing.support'), findsOneWidget);
    expect(find.text('explanation.support'), findsOneWidget);
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
