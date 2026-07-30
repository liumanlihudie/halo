import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';
import 'package:halo_mobile/app/app_kernel.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';

void main() {
  testWidgets(
    'chat route replaces unavailable storage after production kernel bootstrap',
    (tester) async {
      final bootstrap = Completer<ApplicationKernel>();
      final repository = _DurableRepository(
        conversations: const {
          'general-assistant': SingleChatConversationProjection(
            conversationId: 'general-assistant',
            expertId: 'product-manager',
            title: '产品经理',
            agentName: '产品经理',
            modelLabel: 'Configured model',
            avatarLetter: '产',
          ),
        },
      );
      addTearDown(repository.close);

      await tester.pumpWidget(
        HaloApp(
          initialLocation: '/chat/general-assistant',
          kernelBootstrap: () => bootstrap.future,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('聊天存储暂不可用，请稍后重试'), findsOneWidget);

      bootstrap.complete(_ChatKernel(repository));
      await tester.pumpAndSettle();

      expect(find.text('聊天存储暂不可用，请稍后重试'), findsNothing);
      expect(find.text('产品经理'), findsWidgets);
    },
  );

  testWidgets('kernel swap preserves the current complete provider URI', (
    tester,
  ) async {
    final bootstrap = Completer<ApplicationKernel>();
    await tester.pumpWidget(
      HaloApp(
        initialLocation: '/settings/providers?source=test',
        kernelBootstrap: () => bootstrap.future,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ToAPIs'));
    await tester.pumpAndSettle();
    expect(find.text('API Key'), findsOneWidget);

    bootstrap.complete(_Kernel());
    await tester.pumpAndSettle();

    expect(find.text('API Key'), findsOneWidget);
    expect(find.text('Bring Your Own Key'), findsNothing);
  });
}

final class _ChatKernel implements ApplicationKernel {
  _ChatKernel(DurableChatMessageRepository repository)
    : dependencies = AppDependencies(
        singleChatPort: _Port(),
        chatRepository: repository,
      );

  @override
  String get name => 'chat-test';

  @override
  final AppDependencies dependencies;

  @override
  Future<void> close() async {}
}

final class _DurableRepository extends InMemoryChatMessageRepository
    implements DurableChatMessageRepository {
  _DurableRepository({required super.conversations});

  @override
  Future<void> close() async {}
}

final class _Kernel implements ApplicationKernel {
  _Kernel()
    : dependencies = AppDependencies(
        singleChatPort: _Port(),
        chatRepository: InMemoryChatMessageRepository(),
      );

  @override
  String get name => 'test';

  @override
  final AppDependencies dependencies;

  @override
  Future<void> close() async {}
}

final class _Port implements SingleChatPort {
  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) => throw StateError('unused');

  @override
  Future<void> stopSingleAgentRun(String runId) async {}
}
