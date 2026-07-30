import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';
import 'package:halo_mobile/features/single_chat/single_chat_page.dart';

void main() {
  const prototypeRoutes = <String, String>{
    '/conversations': '对话',
    '/chat/general-assistant': '通用助理',
    '/chat/general-assistant/details': '聊天详情',
    '/chat/general-assistant/history': '查找聊天记录',
    '/group/group-product': 'iOS 产品小组',
    '/group/group-product/info': '群资料',
    '/group/group-product/context': '共享上下文',
    '/group/new': '创建 AI 群聊',
    '/experts': '专家团',
    '/market': 'AI 市场',
    '/market/market-1': 'Agent 详情',
    '/expert/general': 'Agent 资料',
    '/expert/general/data': '专家数据',
    '/circle': '专家动态',
    '/circle/post-1': '动态详情',
    '/call/voice/general-assistant': '尚未配置语音服务',
    '/call/video/general-assistant': 'Vidu 视频通话',
    '/media/image': '图片预览',
    '/settings': 'Halo 本地空间',
    '/settings/providers': 'Bring Your Own Key',
    '/settings/providers/toapis': 'ToAPIs',
    '/settings/gateway': '可选，不影响本地使用',
    '/settings/local-data': '数据默认保存在本机',
  };

  testWidgets('all 23 HTML prototype pages have a Flutter route', (
    tester,
  ) async {
    for (final route in prototypeRoutes.entries) {
      await tester.pumpWidget(
        HaloApp(key: UniqueKey(), initialLocation: route.key),
      );
      await tester.pumpAndSettle();
      if (route.key == '/chat/general-assistant') {
        expect(
          find.byType(SingleChatPage),
          findsOneWidget,
          reason: 'Missing prototype route ${route.key}',
        );
        continue;
      }
      expect(
        find.text(route.value),
        findsAtLeastNWidgets(1),
        reason: 'Missing prototype route ${route.key}',
      );
    }
  });
}
