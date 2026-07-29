import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';

void main() {
  testWidgets(
    'single chat reproduces rich messages and keeps calls in plus menu',
    (tester) async {
      await tester.pumpWidget(
        const HaloApp(initialLocation: '/chat/general-assistant'),
      );
      await tester.pumpAndSettle();

      expect(find.text('通用助理'), findsOneWidget);
      expect(find.text('个人 AI 通讯竞品分析.pdf'), findsOneWidget);
      expect(find.text('任务进行中'), findsOneWidget);
      expect(find.bySemanticsLabel('语音通话'), findsNothing);
      expect(find.bySemanticsLabel('视频通话'), findsNothing);

      await tester.tap(find.bySemanticsLabel('添加附件'));
      await tester.pumpAndSettle();
      expect(find.text('端到端语音通话'), findsOneWidget);
      expect(find.text('Vidu 视频通话'), findsOneWidget);
      expect(find.text('拍照'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);
    },
  );

  testWidgets('chat detail contains history categories and local controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      const HaloApp(initialLocation: '/chat/general-assistant/details'),
    );
    await tester.pumpAndSettle();

    expect(find.text('聊天详情'), findsOneWidget);
    expect(find.text('添加到群聊'), findsOneWidget);
    expect(find.text('图片与视频'), findsOneWidget);
    expect(find.text('AI 成果'), findsOneWidget);
    expect(find.text('重要消息提醒'), findsOneWidget);
  });
}
