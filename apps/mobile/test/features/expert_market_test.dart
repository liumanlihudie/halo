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
}
