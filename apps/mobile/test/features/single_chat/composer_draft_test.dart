import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/composer_draft_store.dart';
import 'package:halo_mobile/features/single_chat/single_chat_page.dart';

/// Leaving a chat must not throw away what was being typed.
///
/// The composer's text lived only in the page state, so glancing at another
/// screen and coming back meant retyping the whole message.
void main() {
  Widget page() => MaterialApp(
    home: SingleChatPage(
      conversationId: 'general-assistant',
      repository: FixtureChatMessageRepository(
        commandOutbox: InMemorySingleChatCommandOutbox(),
      ),
    ),
  );

  testWidgets('a draft survives leaving the page and returning', (
    tester,
  ) async {
    ComposerDraftStore.instance.clear('general-assistant');
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '写到一半的想法');
    await tester.pump();

    // Navigating away disposes the page entirely.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('写到一半的想法'), findsOneWidget);
  });

  testWidgets('an emptied composer leaves no ghost draft behind', (
    tester,
  ) async {
    ComposerDraftStore.instance.clear('general-assistant');
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '先打字');
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('先打字'), findsNothing);
  });
}
