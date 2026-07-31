import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/conversations/conversations_page.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';

void main() {
  testWidgets('conversations are listed on the first build', (tester) async {
    // The regression this pins: loading was wired only to a dependency change,
    // so the list came up empty until something happened to change, which on a
    // cold start is never.
    await tester.pumpWidget(
      MaterialApp(home: ConversationsPage(repository: _Repository())),
    );
    await tester.pumpAndSettle();

    expect(find.text('产品经理'), findsOneWidget);
  });

  testWidgets('a conversation with no messages says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ConversationsPage(repository: _Repository())),
    );
    await tester.pumpAndSettle();

    // Never an invented last message for a conversation that has none.
    expect(find.text('还没有消息'), findsWidgets);
  });
}

class _Repository extends InMemoryChatMessageRepository {
  _Repository()
    : super(
        conversations: const {
          'product-manager-chat': SingleChatConversationProjection(
            conversationId: 'product-manager-chat',
            expertId: 'product-manager',
            title: '产品经理',
            agentName: '产品经理',
            modelLabel: '已配置文字模型',
            avatarLetter: '产',
          ),
        },
      );
}
