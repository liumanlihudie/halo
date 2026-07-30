import 'dart:io';

// ignore_for_file: prefer_initializing_formals

import 'package:halo_mobile/app/app_kernel.dart';
import 'package:halo_mobile/app/production_group_chat_port.dart';
import 'package:halo_mobile/app/production_single_chat_port.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_persistence.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/drift_chat_message_repository.dart';
import 'package:halo_mobile/orchestration/sqlite_model_call_journal.dart';
import 'package:halo_mobile/orchestration/wiring/orchestration_kernel_factory.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_catalog_discovery.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/production_model_runtime_factory.dart';
import 'package:halo_mobile/model_runtime/production_provider_inspection_transport.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_transport.dart';
import 'package:halo_mobile/model_runtime/provider_registry.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/sqlite_provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/unary_http_transport.dart';
import 'package:path_provider/path_provider.dart';

typedef ApplicationSupportDirectoryProvider = Future<Directory> Function();
typedef ProviderStorePathOpener =
    ProviderConfigurationStore Function(String path);
typedef ProviderSettingsPersistenceBuilder =
    ProviderSettingsPersistence Function(ProviderConfigurationStore store);
typedef DurableChatRepositoryOpener =
    Future<DurableChatMessageRepository> Function({
      required String databasePath,
      required FileSingleChatCommandOutbox commandOutbox,
      required Map<String, SingleChatConversationProjection> conversations,
      required Map<String, String> supersededExpertBindings,
    });

final class ProductionAppKernelFactory {
  ProductionAppKernelFactory({
    ApplicationSupportDirectoryProvider? applicationSupportDirectory,
    ProviderStorePathOpener? openProviderStore,
    ProviderSettingsPersistenceBuilder? buildSettingsPersistence,
    SecureCredentialStore? credentials,
    DurableChatRepositoryOpener? openChatRepository,
    UnaryHttpAdapter? unaryHttpAdapter,
  }) : _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory,
       _openProviderStore =
           openProviderStore ?? SqliteProviderConfigurationStore.open,
       _buildSettingsPersistence =
           buildSettingsPersistence ?? AtomicProviderSettingsPersistence.new,
       _credentials = credentials ?? const MethodChannelSecureCredentialStore(),
       _openChatRepository =
           openChatRepository ?? _openDriftChatMessageRepository,
       _unaryHttpAdapter = unaryHttpAdapter ?? DartIoUnaryHttpAdapter(),
       _endpointPolicy = TrustedProviderEndpointPolicy(
         providerHosts: const {'api.deepseek.com', 'toapis.com'},
       );

  final ApplicationSupportDirectoryProvider _applicationSupportDirectory;
  final ProviderStorePathOpener _openProviderStore;
  final ProviderSettingsPersistenceBuilder _buildSettingsPersistence;
  final SecureCredentialStore _credentials;
  final DurableChatRepositoryOpener _openChatRepository;
  final UnaryHttpAdapter _unaryHttpAdapter;
  final TrustedProviderEndpointPolicy _endpointPolicy;

  Future<ApplicationKernel> create() async {
    ProviderConfigurationStore? settingsStore;
    ProductionModelRuntimeSlot? runtimeSlot;
    ProductionSingleChatPort? singleChatPort;
    DurableChatMessageRepository? chatRepository;
    SqliteModelCallJournal? modelCallJournal;
    OrchestrationKernelFactory? orchestrationFactory;
    try {
      final supportDirectory = await _applicationSupportDirectory();
      await supportDirectory.create(recursive: true);
      final databasePath =
          '${supportDirectory.path}${Platform.pathSeparator}halo_providers.sqlite';
      final singleChatDatabasePath =
          '${supportDirectory.path}${Platform.pathSeparator}halo_single_chat.sqlite';
      final singleChatOutboxPath =
          '${supportDirectory.path}${Platform.pathSeparator}single-chat-commands.json';
      settingsStore = _openProviderStore(databasePath);
      final settingsPersistence = _buildSettingsPersistence(settingsStore);
      final ProviderSettingsRecoveryPersistence recoveryPersistence;
      if (settingsPersistence is ProviderSettingsRecoveryPersistence) {
        recoveryPersistence =
            settingsPersistence as ProviderSettingsRecoveryPersistence;
      } else {
        throw StateError(
          'Production provider settings require durable recovery support',
        );
      }
      final mutationCoordinator = SerializedProviderMutationCoordinator();
      await mutationCoordinator.runExclusive(
        () => recoveryPersistence.recoverPending(_credentials),
      );
      chatRepository = await _openChatRepository(
        databasePath: singleChatDatabasePath,
        commandOutbox: FileSingleChatCommandOutbox(singleChatOutboxPath),
        conversations: productionSingleChatConversations,
        supersededExpertBindings: supersededSingleChatExpertBindings,
      );
      final inspectionTransport = _inspectionTransport();
      final runtimeFactory = _runtimeFactory(databasePath, inspectionTransport);
      final initialRuntime = await runtimeFactory.create();
      runtimeSlot = ProductionModelRuntimeSlot(initialRuntime);
      final runtimeReloader = SerializedProviderRuntimeReloader(
        _SlotRuntimeReloader(runtimeSlot, runtimeFactory),
      );
      singleChatPort = ProductionSingleChatPort(
        runtime: _SlotSingleChatRuntime(runtimeSlot),
        experts: ExecutableExpertRegistry(
          gateway: const ExpertOutputValidationGateway(),
        ),
      );
      final experts = ExecutableExpertRegistry(
        gateway: const ExpertOutputValidationGateway(),
      );
      modelCallJournal = SqliteModelCallJournal.open(
        '${supportDirectory.path}${Platform.pathSeparator}halo_model_calls.sqlite',
      );
      orchestrationFactory = OrchestrationKernelFactory.production(
        appSupportDirectory: _FixedAppSupportDirectory(supportDirectory.path),
        selector: RoutingCardAgentSelector(experts),
        runtime: LiveRoutingAgentRuntime(
          modelRuntime: _SlotChatModelRuntime(runtimeSlot),
          experts: experts,
          journal: modelCallJournal,
          store: settingsStore,
        ),
      );
      final orchestrationKernel = await orchestrationFactory.create();
      final settings = ProviderSettingsController(
        credentials: _credentials,
        bindingDefaults: _StoreModelBindingDefaults(settingsStore),
        catalogFetcher: _ProductionProviderModelCatalogFetcher(
          transport: inspectionTransport,
          secretResolver: KeychainSecretResolver(store: _credentials),
        ),
        persistence: settingsPersistence,
        runtime: runtimeReloader,
        mutationCoordinator: mutationCoordinator,
      );
      final modelRouting = ModelRoutingController(
        persistence: SqliteModelRoutingPersistence(settingsStore),
        runtime: runtimeReloader,
        mutationCoordinator: mutationCoordinator,
      );
      return _ProductionAppKernel(
        dependencies: AppDependencies(
          singleChatPort: singleChatPort,
          chatRepository: chatRepository,
          providerSettings: settings,
          modelRouting: modelRouting,
          groupChatPort: ProductionGroupChatPort(orchestrationKernel),
        ),
        port: singleChatPort,
        orchestrationKernel: orchestrationKernel,
        modelCallJournal: modelCallJournal,
        chatRepository: chatRepository,
        settings: settings,
        modelRouting: modelRouting,
        runtimeSlot: runtimeSlot,
        settingsStore: settingsStore,
      );
    } catch (error, stackTrace) {
      try {
        await orchestrationFactory?.close();
      } catch (_) {}
      try {
        modelCallJournal?.close();
      } catch (_) {}
      try {
        await singleChatPort?.close();
      } catch (_) {}
      try {
        await chatRepository?.close();
      } catch (_) {}
      try {
        await runtimeSlot?.close();
      } catch (_) {}
      try {
        await settingsStore?.close();
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  ProductionModelRuntimeFactory _runtimeFactory(
    String databasePath,
    ProviderInspectionTransport inspectionTransport,
  ) => ProductionModelRuntimeFactory(
    openConfigurationStore: () => _openProviderStore(databasePath),
    credentialStore: _credentials,
    loadModelCatalog: (providerId, cancellationToken) =>
        _loadPersistedProductionModels(
          databasePath,
          providerId,
          cancellationToken,
        ),
    inspectionTransport: inspectionTransport,
    unaryHttpAdapter: _unaryHttpAdapter,
    endpointPolicy: _endpointPolicy,
  );

  ProductionProviderInspectionTransport _inspectionTransport() =>
      ProductionProviderInspectionTransport(
        client: SecureJsonHttpClient(
          adapter: _unaryHttpAdapter,
          endpointPolicy: _endpointPolicy,
        ),
      );

  Future<List<ModelDescriptor>> _loadPersistedProductionModels(
    String databasePath,
    String providerId,
    CancellationToken cancellationToken,
  ) async {
    if (cancellationToken.isCancelled) {
      throw StateError('Runtime creation was cancelled');
    }
    final store = _openProviderStore(databasePath);
    try {
      if (store is! ProviderModelCatalogStore) {
        throw const ModelRuntimeException(
          code: ModelRuntimeErrorCode.invalidConfiguration,
          safeMessage: '模型服务目录缺失',
          retryable: false,
        );
      }
      final catalog = await (store as ProviderModelCatalogStore)
          .loadProviderModelCatalog(providerId);
      if (cancellationToken.isCancelled) {
        throw StateError('Runtime creation was cancelled');
      }
      if (catalog == null ||
          catalog.providerId != providerId ||
          catalog.models.isEmpty) {
        throw const ModelRuntimeException(
          code: ModelRuntimeErrorCode.invalidConfiguration,
          safeMessage: '模型服务目录缺失',
          retryable: false,
        );
      }
      return catalog.models;
    } finally {
      await store.close();
    }
  }
}

Future<DurableChatMessageRepository> _openDriftChatMessageRepository({
  required String databasePath,
  required FileSingleChatCommandOutbox commandOutbox,
  required Map<String, SingleChatConversationProjection> conversations,
  required Map<String, String> supersededExpertBindings,
}) => DriftChatMessageRepository.open(
  databasePath: databasePath,
  commandOutbox: commandOutbox,
  conversations: conversations,
  supersededExpertBindings: supersededExpertBindings,
);

final class _SlotRuntimeReloader implements ProviderRuntimeReloader {
  const _SlotRuntimeReloader(this.slot, this.factory);

  final ProductionModelRuntimeSlot slot;
  final ProductionModelRuntimeFactory factory;

  @override
  Future<void> reload() => slot.replaceWith(factory);
}

final class _SlotSingleChatRuntime implements ProductionSingleChatRuntime {
  const _SlotSingleChatRuntime(this.slot);

  final ProductionModelRuntimeSlot slot;

  @override
  Future<ChatResponse> chat(ChatRequest request) => slot.chat(request);

  @override
  Future<ModelRef> resolveConfiguredModel({required String agentId}) =>
      slot.resolveConfiguredModel(agentId: agentId);
}

final class _ProductionAppKernel implements ApplicationKernel {
  _ProductionAppKernel({
    required this.dependencies,
    required ProductionSingleChatPort port,
    required DurableChatMessageRepository chatRepository,
    required ProviderSettingsController settings,
    required ModelRoutingController modelRouting,
    required ProductionModelRuntimeSlot runtimeSlot,
    required ProviderConfigurationStore settingsStore,
    required ManagedOrchestrationKernel orchestrationKernel,
    required SqliteModelCallJournal modelCallJournal,
  }) : _port = port,
       _orchestrationKernel = orchestrationKernel,
       _modelCallJournal = modelCallJournal,
       _chatRepository = chatRepository,
       _settings = settings,
       _modelRouting = modelRouting,
       _runtimeSlot = runtimeSlot,
       _settingsStore = settingsStore;

  @override
  String get name => 'production';

  @override
  final AppDependencies dependencies;
  final ProductionSingleChatPort _port;
  final DurableChatMessageRepository _chatRepository;
  final ProviderSettingsController _settings;
  final ModelRoutingController _modelRouting;
  final ProductionModelRuntimeSlot _runtimeSlot;
  final ProviderConfigurationStore _settingsStore;
  final ManagedOrchestrationKernel _orchestrationKernel;
  final SqliteModelCallJournal _modelCallJournal;
  Future<void>? _closeFuture;

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final future = _close();
    _closeFuture = future;
    return future;
  }

  Future<void> _close() async {
    Object? firstError;
    StackTrace? firstStack;
    Future<void> closeOne(Future<void> Function() close) async {
      try {
        await close();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
    }

    // Drain orchestration before the runtime it calls into disappears.
    await closeOne(_orchestrationKernel.close);
    await closeOne(() async => _modelCallJournal.close());
    await closeOne(_modelRouting.close);
    await closeOne(_settings.close);
    await closeOne(_runtimeSlot.close);
    await closeOne(_port.close);
    await closeOne(_chatRepository.close);
    await closeOne(_settingsStore.close);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
  }
}

final class _ProductionProviderModelCatalogFetcher
    implements ProviderModelCatalogFetcher {
  _ProductionProviderModelCatalogFetcher({
    required this.transport,
    required this.secretResolver,
  });

  final ProviderInspectionTransport transport;
  final SecretResolver secretResolver;

  @override
  Future<PersistedProviderModelCatalog> fetch(ProviderConfig config) async {
    final snapshot = await ModelCatalogDiscovery(
      configs: [config],
      transport: transport,
      secretResolver: secretResolver,
    ).discover(config.providerId, forceRefresh: true);
    return PersistedProviderModelCatalog(
      providerId: snapshot.providerId,
      models: snapshot.models,
      discoveredAt: DateTime.fromMillisecondsSinceEpoch(
        snapshot.discoveredAt.millisecondsSinceEpoch,
        isUtc: true,
      ),
    );
  }
}

/// Conversations shipped earlier under a different expert.
///
/// `general-assistant` was the 产品经理 chat and `data-analyst-chat` was the
/// 技术架构师 chat before installed contacts each got their own conversation.
/// Existing databases still hold those rows, and the history schema has no
/// upgrade path, so without this the fail-closed rebinding guard would keep
/// every upgraded install from ever building a kernel again.
const supersededSingleChatExpertBindings = <String, String>{
  'general-assistant': 'product-manager',
  'data-analyst-chat': 'technical-architect',
};

/// Durable conversation seeds for every installed expert profile.
///
/// Each key must equal an [InstalledExpertIdentity.conversationId] and each
/// `expertId` must equal that identity's canonical expert ID, because the chat
/// controller derives [StartSingleAgentRunRequest.expertId] from this
/// projection while the profile page binds the model override to the same
/// canonical ID.
const productionSingleChatConversations = {
  'general-assistant': SingleChatConversationProjection(
    conversationId: 'general-assistant',
    expertId: 'project-manager',
    title: '通用助理',
    agentName: '通用助理',
    modelLabel: '文字模型',
    avatarLetter: '助',
  ),
  'product-manager-chat': SingleChatConversationProjection(
    conversationId: 'product-manager-chat',
    expertId: 'product-manager',
    title: '产品经理',
    agentName: '产品经理',
    modelLabel: '文字模型',
    avatarLetter: '产',
  ),
  'data-analyst-chat': SingleChatConversationProjection(
    conversationId: 'data-analyst-chat',
    expertId: 'data-analyst',
    title: '数据分析师',
    agentName: '数据分析师',
    modelLabel: '文字模型',
    avatarLetter: '数',
  ),
  'writing-advisor-chat': SingleChatConversationProjection(
    conversationId: 'writing-advisor-chat',
    expertId: 'content-strategist',
    title: '写作顾问',
    agentName: '写作顾问',
    modelLabel: '文字模型',
    avatarLetter: '写',
  ),
  'calendar-assistant': SingleChatConversationProjection(
    conversationId: 'calendar-assistant',
    expertId: 'operations-manager',
    title: '日程管家',
    agentName: '日程管家',
    modelLabel: '文字模型',
    avatarLetter: '日',
  ),
  'contract-review-chat': SingleChatConversationProjection(
    conversationId: 'contract-review-chat',
    expertId: 'legal-risk-advisor',
    title: '合同审阅助手',
    agentName: '合同审阅助手',
    modelLabel: '文字模型',
    avatarLetter: '合',
  ),
  'monitoring-chat': SingleChatConversationProjection(
    conversationId: 'monitoring-chat',
    expertId: 'fact-checker',
    title: '信息监控',
    agentName: '信息观察员',
    modelLabel: '文字模型',
    avatarLetter: '监',
  ),
  'deep-research-task': SingleChatConversationProjection(
    conversationId: 'deep-research-task',
    expertId: 'industry-researcher',
    title: '深度研究任务',
    agentName: '研究员',
    modelLabel: '文字模型',
    avatarLetter: '研',
  ),
  'fitness-planner-chat': SingleChatConversationProjection(
    conversationId: 'fitness-planner-chat',
    expertId: 'fitness-planner',
    title: '健身计划师',
    agentName: '健身计划师',
    modelLabel: '文字模型',
    avatarLetter: '健',
  ),
};

final class _FixedAppSupportDirectory implements AppSupportDirectoryProvider {
  const _FixedAppSupportDirectory(this.path);

  final String path;

  @override
  Future<String> getDirectoryPath() async => path;
}

final class _SlotChatModelRuntime implements ChatModelRuntime {
  const _SlotChatModelRuntime(this.slot);

  final ProductionModelRuntimeSlot slot;

  @override
  Future<ChatResponse> chat(ChatRequest request) => slot.chat(request);
}

/// Routes the auto-default binding through the same store the runtime reads.
final class _StoreModelBindingDefaults implements ModelBindingDefaults {
  _StoreModelBindingDefaults(this._store);

  final ProviderConfigurationStore _store;

  @override
  Future<ModelRef?> loadGlobalDefault() => _store.loadGlobalDefaultModel();

  @override
  Future<void> setGlobalDefault(ModelRef? model) =>
      _store.setGlobalDefaultModel(model);
}
