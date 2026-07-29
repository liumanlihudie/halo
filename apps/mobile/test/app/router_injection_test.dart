import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app_kernel.dart';
import 'package:halo_mobile/app/router.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';

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

  // One end-to-end widget journey. The per-profile identity equalities are
  // pinned as pure contracts in
  // test/experts/executable_expert_registry_test.dart, because driving nine
  // widget journeys adds no coverage and `ModelRoutingController.close()`
  // cannot be awaited from `addTearDown`: `_mutationTail` was created inside
  // the FakeAsync zone, which stops flushing microtasks once the body returns.
  testWidgets('expert model override and chat request share one identity', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final identity = ExecutableExpertRegistry.installedExpertIdentities
        .singleWhere((identity) => identity.profileId == 'product');
    final installed = HaloFixtures.installedExperts.singleWhere(
      (expert) => expert.id == identity.profileId,
    );
    final deepSeek = ModelRef(providerId: 'deepseek', modelId: 'deepseek-chat');
    final selected = ModelRef(
      providerId: 'toapis',
      modelId: 'selected-model-id',
    );
    final persistence = _RoutingPersistence(
      options: [
        AvailableModelOption(
          ref: deepSeek,
          providerName: 'DeepSeek',
          modelName: 'DeepSeek Chat',
        ),
        AvailableModelOption(
          ref: selected,
          providerName: 'ToAPIs',
          modelName: 'Selected Model',
        ),
      ],
      globalDefault: deepSeek,
    );
    final routing = ModelRoutingController(
      persistence: persistence,
      runtime: _Reloader(),
    );
    addTearDown(routing.dispose);
    final port = _RecordingPort();
    final repository = _DurableRouterRepository(
      conversations: {
        identity.conversationId: SingleChatConversationProjection(
          conversationId: identity.conversationId,
          expertId: identity.canonicalExpertId,
          title: installed.name,
          agentName: installed.name,
          modelLabel: installed.model,
          avatarLetter: installed.avatarLetter,
        ),
      },
    );
    addTearDown(repository.close);
    final router = createAppRouter(
      initialLocation: '/expert/${identity.profileId}',
      dependencies: AppDependencies(
        singleChatPort: port,
        chatRepository: repository,
        modelRouting: routing,
      ),
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selected Model'));
    await tester.pumpAndSettle();

    expect(persistence.loadedExpertIds, contains(identity.canonicalExpertId));
    expect(persistence.expertWrites, [(identity.canonicalExpertId, selected)]);

    await tester.tap(find.text('发消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField).last, 'identity check');
    await tester.tap(find.bySemanticsLabel('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final request = port.requests.single;
    expect(request.conversationId, identity.conversationId);
    expect(request.expertId, identity.canonicalExpertId);
    expect(request.expertId, persistence.expertWrites.last.$1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await routing.close();
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

final class _RoutingPersistence
    implements ModelRoutingPersistence, ModelRoutingRollbackPersistence {
  _RoutingPersistence({required this.options, required this.globalDefault});

  final List<AvailableModelOption> options;
  ModelRef? globalDefault;
  final Map<String, ModelRef> overrides = {};
  final List<String> loadedExpertIds = [];
  final List<(String, ModelRef?)> expertWrites = [];

  @override
  Future<List<AvailableModelOption>> loadAvailableModels() async => options;

  @override
  Future<ModelRef?> loadGlobalDefault() async => globalDefault;

  @override
  Future<void> setGlobalDefault(ModelRef model) async {
    globalDefault = model;
  }

  @override
  Future<void> restoreGlobalDefault(ModelRef? model) async {
    globalDefault = model;
  }

  @override
  Future<ModelRef?> loadExpertOverride(String expertId) async {
    loadedExpertIds.add(expertId);
    return overrides[expertId];
  }

  @override
  Future<void> setExpertOverride(String expertId, ModelRef? model) async {
    if (model == null) {
      overrides.remove(expertId);
    } else {
      overrides[expertId] = model;
    }
    expertWrites.add((expertId, model));
  }
}

final class _Reloader implements ProviderRuntimeReloader {
  @override
  Future<void> reload() async {}
}
