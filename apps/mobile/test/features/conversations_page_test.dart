import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/conversations/conversations_page.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';

/// The list must fill in on first open.
///
/// It once loaded only from didUpdateWidget, so the screen came up empty and
/// stayed empty unless a dependency happened to change afterwards.
void main() {
  testWidgets('conversations appear without waiting for a rebuild', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationsPage(
          repository: InMemoryChatMessageRepository(
            conversations: const {
              'general-assistant': SingleChatConversationProjection(
                conversationId: 'general-assistant',
                expertId: 'halo-assistant',
                title: 'Halo 助理',
                agentName: 'Halo 助理',
                modelLabel: '文字模型',
                avatarLetter: '助',
              ),
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Halo 助理'), findsOneWidget);
  });
}
