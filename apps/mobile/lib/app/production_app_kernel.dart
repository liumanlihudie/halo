import 'dart:io';

// ignore_for_file: prefer_initializing_formals

import 'package:halo_mobile/app/app_kernel.dart';
import 'package:halo_mobile/app/production_single_chat_port.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_persistence.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/drift_chat_message_repository.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/production_model_runtime_factory.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_transport.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
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
    });

final class ProductionAppKernelFactory {
  ProductionAppKernelFactory({
    ApplicationSupportDirectoryProvider? applicationSupportDirectory,
    ProviderStorePathOpener? openProviderStore,
    ProviderSettingsPersistenceBuilder? buildSettingsPersistence,
    SecureCredentialStore? credentials,
    DurableChatRepositoryOpener? openChatRepository,
  }) : _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory,
       _openProviderStore =
           openProviderStore ?? SqliteProviderConfigurationStore.open,
       _buildSettingsPersistence =
           buildSettingsPersistence ?? AtomicProviderSettingsPersistence.new,
       _credentials = credentials ?? const MethodChannelSecureCredentialStore(),
       _openChatRepository =
           openChatRepository ?? _openDriftChatMessageRepository;

  final ApplicationSupportDirectoryProvider _applicationSupportDirectory;
  final ProviderStorePathOpener _openProviderStore;
  final ProviderSettingsPersistenceBuilder _buildSettingsPersistence;
  final SecureCredentialStore _credentials;
  final DurableChatRepositoryOpener _openChatRepository;

  Future<ApplicationKernel> create() async {
    ProviderConfigurationStore? settingsStore;
    ProductionModelRuntimeSlot? runtimeSlot;
    ProductionSingleChatPort? singleChatPort;
    DurableChatMessageRepository? chatRepository;
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
      await recoveryPersistence.recoverPending(_credentials);
      chatRepository = await _openChatRepository(
        databasePath: singleChatDatabasePath,
        commandOutbox: FileSingleChatCommandOutbox(singleChatOutboxPath),
        conversations: _productionSingleChatConversations,
      );
      final runtimeFactory = _runtimeFactory(databasePath);
      final initialRuntime = await runtimeFactory.create();
      runtimeSlot = ProductionModelRuntimeSlot(initialRuntime);
      singleChatPort = ProductionSingleChatPort(
        runtime: _SlotSingleChatRuntime(runtimeSlot),
        experts: ExecutableExpertRegistry(
          gateway: const ExpertOutputValidationGateway(),
        ),
      );
      final settings = ProviderSettingsController(
        credentials: _credentials,
        persistence: settingsPersistence,
        runtime: _SlotRuntimeReloader(runtimeSlot, runtimeFactory),
      );
      return _ProductionAppKernel(
        dependencies: AppDependencies(
          singleChatPort: singleChatPort,
          chatRepository: chatRepository,
          providerSettings: settings,
        ),
        port: singleChatPort,
        chatRepository: chatRepository,
        settings: settings,
        runtimeSlot: runtimeSlot,
        settingsStore: settingsStore,
      );
    } catch (error, stackTrace) {
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

  ProductionModelRuntimeFactory _runtimeFactory(String databasePath) =>
      ProductionModelRuntimeFactory(
        openConfigurationStore: () => _openProviderStore(databasePath),
        credentialStore: _credentials,
        loadModelCatalog: _loadProductionModels,
        inspectionTransport: const _UnavailableInspectionTransport(),
        endpointPolicy: TrustedProviderEndpointPolicy(
          providerHosts: const {'api.deepseek.com', 'toapis.com'},
        ),
      );
}

Future<DurableChatMessageRepository> _openDriftChatMessageRepository({
  required String databasePath,
  required FileSingleChatCommandOutbox commandOutbox,
  required Map<String, SingleChatConversationProjection> conversations,
}) => DriftChatMessageRepository.open(
  databasePath: databasePath,
  commandOutbox: commandOutbox,
  conversations: conversations,
);

Future<List<ModelDescriptor>> _loadProductionModels(
  String providerId,
  CancellationToken cancellationToken,
) async {
  if (cancellationToken.isCancelled) {
    throw StateError('Runtime creation was cancelled');
  }
  return switch (providerId) {
    'toapis' => [
      ModelDescriptor(
        ref: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
        displayName: 'GPT-5 mini',
        capabilities: const ModelCapabilities.text(),
      ),
    ],
    'deepseek' => [
      ModelDescriptor(
        ref: ModelRef(providerId: 'deepseek', modelId: 'deepseek-chat'),
        displayName: 'DeepSeek Chat',
        capabilities: const ModelCapabilities.text(),
      ),
    ],
    _ => throw StateError('Provider is not enabled for production chat'),
  };
}

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
    required ProductionModelRuntimeSlot runtimeSlot,
    required ProviderConfigurationStore settingsStore,
  }) : _port = port,
       _chatRepository = chatRepository,
       _settings = settings,
       _runtimeSlot = runtimeSlot,
       _settingsStore = settingsStore;

  @override
  String get name => 'production';

  @override
  final AppDependencies dependencies;
  final ProductionSingleChatPort _port;
  final DurableChatMessageRepository _chatRepository;
  final ProviderSettingsController _settings;
  final ProductionModelRuntimeSlot _runtimeSlot;
  final ProviderConfigurationStore _settingsStore;
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

final class _UnavailableInspectionTransport
    implements ProviderInspectionTransport {
  const _UnavailableInspectionTransport();

  @override
  Future<ProviderCatalogTransportResult> discoverModels(
    ProviderInspectionRequest request,
  ) => throw const ModelRuntimeException(
    code: ModelRuntimeErrorCode.unsupportedEndpoint,
    safeMessage: '模型目录暂不可用',
    retryable: false,
  );

  @override
  Future<ProviderHealthTransportResult> probeHealth(
    ProviderInspectionRequest request,
  ) => throw const ModelRuntimeException(
    code: ModelRuntimeErrorCode.unsupportedEndpoint,
    safeMessage: '连接测试暂不可用',
    retryable: false,
  );
}

const _productionSingleChatConversations = {
  'general-assistant': SingleChatConversationProjection(
    conversationId: 'general-assistant',
    expertId: 'product-manager',
    title: '产品经理',
    agentName: '产品经理',
    modelLabel: '已配置文字模型',
    avatarLetter: '产',
  ),
  'data-analyst-chat': SingleChatConversationProjection(
    conversationId: 'data-analyst-chat',
    expertId: 'technical-architect',
    title: '技术架构师',
    agentName: '技术架构师',
    modelLabel: '已配置文字模型',
    avatarLetter: '技',
  ),
};
