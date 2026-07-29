import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';

void main() {
  const routes = <String, String>{
    '/chat/general-assistant/history': '查找聊天记录',
    '/group/new': '创建 AI 群聊',
    '/circle/post-1': '动态详情',
    '/media/image': '图片预览',
    '/call/voice/general-assistant': '端到端语音通话',
    '/call/video/general-assistant': 'Vidu 视频通话',
  };

  for (final route in routes.entries) {
    testWidgets('${route.key} builds its prototype page', (tester) async {
      await tester.pumpWidget(HaloApp(initialLocation: route.key));
      await tester.pumpAndSettle();
      expect(find.text(route.value), findsOneWidget);
    });
  }
}
