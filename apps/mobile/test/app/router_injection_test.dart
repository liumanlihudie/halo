import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app_kernel.dart';
import 'package:halo_mobile/app/router.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';

void main() {
  testWidgets('router injects the same chat port and repository dependencies', (
    tester,
  ) async {
    final port = _RecordingPort();
    final repository = _DurableRouterRepository(
      conversations: const {
        'conversation-1': SingleChatConversationProjection(
          conversationId: 'conversation-1',
          expertId: 'product-manager',
          title: 'Injected conversation',
          agentName: 'Product manager',
          modelLabel: 'Configured model',
          avatarLetter: 'P',
        ),
      },
    );
    addTearDown(repository.close);
    final router = createAppRouter(
      initialLocation: '/chat/conversation-1',
      dependencies: AppDependencies(
        singleChatPort: port,
        chatRepository: repository,
      ),
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'hello');
    await tester.tap(find.bySemanticsLabel('发送'));
    await tester.pumpAndSettle();

    expect(find.text('Injected conversation'), findsOneWidget);
    expect(repository, isA<DurableChatMessageRepository>());
    expect(port.requests.single.expertId, 'product-manager');
    expect(port.requests.single.text, 'hello');
  });
}

final class _DurableRouterRepository extends InMemoryChatMessageRepository
    implements DurableChatMessageRepository {
  _DurableRouterRepository({required super.conversations});

  @override
  Future<void> close() async {}
}

final class _RecordingPort implements SingleChatPort {
  final requests = <StartSingleAgentRunRequest>[];

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) async {
    requests.add(request);
    return SingleAgentRunHandle(
      runId: request.clientCommandId,
      outcome: Future.value(
        const SingleAgentRunOutcome.completed(answer: 'real port response'),
      ),
    );
  }

  @override
  Future<void> stopSingleAgentRun(String runId) async {}
}
