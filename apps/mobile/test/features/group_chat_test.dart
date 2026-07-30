import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';

void main() {
  testWidgets('group chat keeps history and exposes live routing modes', (
    tester,
  ) async {
    await tester.pumpWidget(
      const HaloApp(initialLocation: '/group/group-product'),
    );
    await tester.pumpAndSettle();

    expect(find.text('iOS 产品小组'), findsOneWidget);
    expect(find.text('自动选择'), findsOneWidget);
    expect(find.text('@指定成员'), findsOneWidget);
    expect(find.text('@所有成员'), findsOneWidget);
    expect(find.text('让大家讨论'), findsNothing);
    expect(find.text('群聊运行服务待接入'), findsOneWidget);
    expect(find.text('用户价值是成立的，但首版必须把“联系人就是能力”做透。'), findsOneWidget);
    expect(find.text('群聊阶段总结'), findsOneWidget);
    expect(find.text('语音通话'), findsNothing);
    expect(find.text('视频通话'), findsNothing);
  });

  testWidgets('group info and shared context reproduce management controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      const HaloApp(initialLocation: '/group/group-product/info'),
    );
    await tester.pumpAndSettle();

    expect(find.text('群资料'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('默认发言规则'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('默认发言规则'), findsOneWidget);
    expect(find.text('共享上下文'), findsOneWidget);
    expect(find.text('每次讨论自动总结'), findsOneWidget);
    expect(find.text('讨论总结发布到圈层'), findsOneWidget);
  });
}
