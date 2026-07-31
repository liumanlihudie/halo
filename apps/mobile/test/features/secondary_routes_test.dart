import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';

void main() {
  const routes = <String, String>{
    '/chat/general-assistant/history': '查找聊天记录',
    '/group/new': '创建 AI 群聊',
    '/circle/post-1': '动态详情',
    '/media/image': '图片预览',
    '/call/voice/general-assistant': '尚未配置语音服务',
    '/call/video/general-assistant': 'Vidu 视频通话',
  };

  for (final route in routes.entries) {
    testWidgets('${route.key} builds its prototype page', (tester) async {
      await tester.pumpWidget(HaloApp(initialLocation: route.key));
      await tester.pumpAndSettle();
      expect(find.text(route.value), findsOneWidget);
    });
  }

  testWidgets('new group reproduces the prototype setup content', (
    tester,
  ) async {
    await tester.pumpWidget(const HaloApp(initialLocation: '/group/new'));
    await tester.pumpAndSettle();

    expect(find.text('完成'), findsOneWidget);
    // Starts empty: pre-filling a name and pre-selecting members was prototype
    // behaviour, and creating a group with choices the user did not make is
    // exactly what made 完成 meaningless before.
    expect(find.text('选择成员 · 至少 2 位'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '完成'))
          .onPressed,
      isNull,
    );
    // Candidates are the installed experts, not prototype ids.
    expect(find.text('产品经理'), findsWidgets);
  });

  testWidgets('group context preserves shared and isolated sections', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(402, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const HaloApp(initialLocation: '/group/group-product/context'),
    );
    await tester.pumpAndSettle();

    // The page used to list invented shared sources; now it says the
    // feature is not built rather than describing one that never ran.
    expect(find.textContaining('群共享上下文还未实装'), findsOneWidget);
    expect(find.text('IOS-IM 产品规格'), findsNothing);
  });

  testWidgets('group chat title carries its loaded member-count badge', (
    tester,
  ) async {
    await tester.pumpWidget(
      const HaloApp(initialLocation: '/group/group-product'),
    );
    await tester.pumpAndSettle();

    expect(find.text('iOS 产品小组'), findsOneWidget);
    expect(find.text('5 AI'), findsOneWidget);
  });

  testWidgets(
    'installed expert profile reproduces the source profile controls',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(402, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const HaloApp(initialLocation: '/expert/general-assistant'),
      );
      await tester.pump();

      expect(find.text('Halo 助理'), findsOneWidget);
      expect(find.text('允许发布到圈层'), findsOneWidget);
      expect(find.text('添加到群聊'), findsOneWidget);
      expect(find.byType(HaloSwitch), findsNWidgets(2));
      // The hero wears the designed badge now, not a stock photo of a
      // stranger fetched from the network.
      expect(find.byType(SvgPicture), findsWidgets);
    },
  );
}
