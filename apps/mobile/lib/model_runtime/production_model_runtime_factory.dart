import 'dart:async';

import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_catalog_discovery.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/model_runtime_providers.dart';
import 'package:halo_mobile/model_runtime/production_unary_transports.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/provider_health_probe.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_transport.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_models.dart';
import 'package:halo_mobile/model_runtime/provider_registry.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/unary_http_transport.dart';

typedef ProviderConfigurationStoreOpener =
    ProviderConfigurationStore Function();
typedef ProviderModelCatalogLoader =
    Future<List<ModelDescriptor>> Function(
      String providerId,
      CancellationToken cancellationToken,
    );

final class ProductionModelRuntimeFactory {
  ProductionModelRuntimeFactory({
    required this.openConfigurationStore,
    required this.credentialStore,
    required this.loadModelCatalog,
    required this.inspectionTransport,
    UnaryHttpAdapter? unaryHttpAdapter,
    this.endpointPolicy = const PublicEndpointPolicy(),
    this.timeouts = const UnaryHttpTimeouts(),
    this.shutdownTimeout = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : unaryHttpAdapter = unaryHttpAdapter ?? DartIoUnaryHttpAdapter(),
       _now = now ?? DateTime.timestamp {
    if (shutdownTimeout <= Duration.zero) {
      throw ArgumentError.value(shutdownTimeout, 'shutdownTimeout');
    }
  }

  final ProviderConfigurationStoreOpener openConfigurationStore;
  final SecureCredentialStore credentialStore;
  final ProviderModelCatalogLoader loadModelCatalog;
  final ProviderInspectionTransport inspectionTransport;
  final UnaryHttpAdapter unaryHttpAdapter;
  final EndpointPolicy endpointPolicy;
  final UnaryHttpTimeouts timeouts;
  final Duration shutdownTimeout;
  final DateTime Function() _now;

  Future<ProductionModelRuntime> create({
    CancellationToken? cancellationToken,
  }) async {
    final creationToken = cancellationToken ?? CancellationToken();
    ProviderConfigurationStore? store;
    ProviderRegistry? registry;
    try {
      _requireCreationOpen(creationToken);
      store = openConfigurationStore();
      final allConfigs = List<ProviderConfig>.unmodifiable(
        await _awaitCreation(store.loadAll(), creationToken),
      );
      _requireCredentialOwnership(allConfigs);
      for (final config in allConfigs) {
        _requireKeychainRefs(config);
      }
      final configs = List<ProviderConfig>.unmodifiable(
        allConfigs.where((config) => config.enabled),
      );
      final secretResolver = KeychainSecretResolver(
        store: credentialStore,
        now: _now,
      );
      final client = SecureJsonHttpClient(
        adapter: unaryHttpAdapter,
        endpointPolicy: endpointPolicy,
        timeouts: timeouts,
        allowInsecureHttp: configs.any((config) => config.allowInsecureHttp),
      );
      final transports = ProductionModelTransports(
        openAICompatible: ProductionOpenAICompatibleHttpTransport(
          client: client,
          now: _now,
        ),
        openAI: ProductionOpenAINativeHttpTransport(client: client, now: _now),
        anthropic: ProductionAnthropicHttpTransport(client: client, now: _now),
        gemini: ProductionGeminiHttpTransport(client: client, now: _now),
      );
      final providers = <ModelProvider>[];
      for (final config in configs) {
        final catalog = await _awaitCreation(
          loadModelCatalog(config.providerId, creationToken),
          creationToken,
        );
        providers.add(
          buildProductionModelProvider(
            config: config,
            modelCatalog: catalog,
            secretResolver: secretResolver,
            transports: transports,
          ),
        );
      }
      final lifecycle = _ProductionRuntimeLifecycle();
      registry = ProviderRegistry.snapshot(
        providers,
        shutdownTimeout: shutdownTimeout,
      );
      final globalDefault = await _awaitCreation(
        store.loadGlobalDefaultModel(),
        creationToken,
      );
      final agentOverrides = Map<String, ModelRef>.unmodifiable(
        await _awaitCreation(store.loadAgentModelOverrides(), creationToken),
      );
      if (agentOverrides.keys.any(
        (agentId) => !isCanonicalRuntimeId(agentId),
      )) {
        throw const ModelRuntimeException(
          code: ModelRuntimeErrorCode.invalidConfiguration,
          safeMessage: 'Agent 模型绑定无效',
          retryable: false,
        );
      }
      if (globalDefault != null) {
        registry.resolveModel(globalDefault);
      }
      for (final model in agentOverrides.values) {
        registry.resolveModel(model);
      }
      return ProductionModelRuntime._(
        registry: registry,
        catalogDiscovery: ModelCatalogDiscovery(
          configs: configs,
          transport: inspectionTransport,
          secretResolver: secretResolver,
          now: _now,
        ),
        healthProbe: ProviderHealthProbe(
          configs: configs,
          transport: inspectionTransport,
          secretResolver: secretResolver,
          now: _now,
        ),
        configurationStore: store,
        globalDefault: globalDefault,
        agentOverrides: agentOverrides,
        lifecycle: lifecycle,
        shutdownTimeout: shutdownTimeout,
      );
    } on Object catch (error, stackTrace) {
      if (registry != null) {
        try {
          await _boundedCleanup(registry.close(), shutdownTimeout);
        } on Object {
          // Rollback failure must not replace the initialization error.
        }
      }
      if (store != null) {
        try {
          await _boundedCleanup(store.close(), shutdownTimeout);
        } on Object {
          // Rollback failure must not replace the initialization error.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<T> _awaitCreation<T>(
    Future<T> source,
    CancellationToken cancellationToken,
  ) {
    _requireCreationOpen(cancellationToken);
    final result = Completer<T>();
    late final CancellationSubscription subscription;
    subscription = cancellationToken.addListener(() {
      if (!result.isCompleted) {
        result.completeError(const _RuntimeCreationCancelled());
      }
    });
    source.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
      },
    );
    return result.future.whenComplete(subscription.dispose);
  }

  void _requireCreationOpen(CancellationToken token) {
    if (token.isCancelled) throw const _RuntimeCreationCancelled();
  }

  void _requireKeychainRefs(ProviderConfig config) {
    final refs = [
      if (config.secretRef != null) config.secretRef!,
      ...config.headerSecretRefs.values,
    ];
    if (refs.any((ref) => !ProviderSecretRefPolicy.isValid(ref))) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.invalidConfiguration,
        safeMessage: '模型服务凭证引用无效',
        retryable: false,
      );
    }
  }

  void _requireCredentialOwnership(Iterable<ProviderConfig> configs) {
    final ownersByLocator = <String, String>{};
    final locatorsByOwner = <String, String>{};
    for (final config in configs) {
      for (final entry in providerCredentialBindings(config).entries) {
        final owner = '${config.providerId}/${entry.key}';
        final locator = entry.value.locator.toString();
        final priorOwner = ownersByLocator.putIfAbsent(locator, () => owner);
        final priorLocator = locatorsByOwner.putIfAbsent(owner, () => locator);
        if (priorOwner != owner || priorLocator != locator) {
          throw const ModelRuntimeException(
            code: ModelRuntimeErrorCode.invalidConfiguration,
            safeMessage: '模型服务凭证归属冲突',
            retryable: false,
          );
        }
      }
    }
  }
}

final class ProductionModelRuntime {
  ProductionModelRuntime._({
    required ProviderRegistry registry,
    required this._catalogDiscovery,
    required this._healthProbe,
    required this._configurationStore,
    required this.globalDefault,
    required Map<String, ModelRef> agentOverrides,
    required this._lifecycle,
    required this._shutdownTimeout,
  }) : _registry = registry,
       _registryView = _ProductionProviderRegistryView(registry),
       agentOverrides = Map.unmodifiable(agentOverrides);

  final ProviderRegistry _registry;
  final ProviderRegistryView _registryView;
  final ModelCatalogDiscovery _catalogDiscovery;
  final ProviderHealthProbe _healthProbe;
  final ProviderConfigurationStore _configurationStore;
  final ModelRef? globalDefault;
  final Map<String, ModelRef> agentOverrides;
  final _ProductionRuntimeLifecycle _lifecycle;
  final Duration _shutdownTimeout;
  Future<void>? _closeFuture;

  ProviderRegistryView get registry => _registryView;

  bool get shutdownForced =>
      _registry.shutdownForced || _lifecycle.shutdownForced;

  Future<ModelRef> resolveConfiguredModel({String? agentId}) =>
      _lifecycle.run(() async {
        if (agentId != null && !isCanonicalRuntimeId(agentId)) {
          throw ArgumentError.value(agentId, 'agentId');
        }
        final override = agentId == null ? null : agentOverrides[agentId];
        final selected = override ?? globalDefault;
        if (selected == null) {
          throw const ModelRuntimeException(
            code: ModelRuntimeErrorCode.invalidConfiguration,
            safeMessage: '尚未配置默认模型',
            retryable: false,
          );
        }
        _registry.resolveModel(selected);
        return selected;
      });

  Future<ChatResponse> chat(ChatRequest request) => _registry.chat(request);

  Future<ModelCatalogSnapshot> discoverModels(
    String providerId, {
    bool forceRefresh = false,
  }) => _lifecycle.run(
    () => _catalogDiscovery.discover(
      providerId,
      forceRefresh: forceRefresh,
      cancellationToken: _lifecycle.cancellationToken,
    ),
  );

  Future<ProviderHealthReport> probeHealth(String providerId) => _lifecycle.run(
    () => _healthProbe.probe(
      providerId,
      cancellationToken: _lifecycle.cancellationToken,
    ),
  );

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final closeFuture = Future.wait<void>([
      _registry.close(),
      _lifecycle.close(_configurationStore.close, _shutdownTimeout),
    ]);
    _closeFuture = closeFuture;
    return closeFuture;
  }
}

final class _ProductionProviderRegistryView implements ProviderRegistryView {
  const _ProductionProviderRegistryView(this._registry);

  final ProviderRegistry _registry;

  @override
  Iterable<ProviderConfig> get configs => _registry.configs;

  @override
  ModelDescriptor resolveModel(ModelRef ref) => _registry.resolveModel(ref);

  @override
  Future<ChatResponse> chat(ChatRequest request) => _registry.chat(request);
}

final class ProductionModelRuntimeSlot {
  ProductionModelRuntimeSlot(ProductionModelRuntime initial)
    : _runtime = initial;

  ProductionModelRuntime? _runtime;
  int _generation = 0;
  bool _closed = false;
  Future<void>? _closeFuture;
  final Map<int, _PendingRuntimeCreation> _pending = {};

  Future<void> replaceWith(ProductionModelRuntimeFactory factory) async {
    if (_closed) {
      throw StateError('Production model runtime slot is closed');
    }
    final generation = ++_generation;
    for (final pending in _pending.values) {
      pending.cancellationToken.cancel();
    }
    final cancellationToken = CancellationToken();
    final creation = factory.create(cancellationToken: cancellationToken);
    _pending[generation] = _PendingRuntimeCreation(cancellationToken, creation);
    late final ProductionModelRuntime next;
    try {
      next = await creation;
    } on _RuntimeCreationCancelled {
      throw StateError(
        _closed
            ? 'Production model runtime slot is closed'
            : 'Production model runtime replacement was superseded',
      );
    } finally {
      _pending.remove(generation);
    }
    if (_closed || generation != _generation) {
      await next.close();
      throw StateError(
        _closed
            ? 'Production model runtime slot is closed'
            : 'Production model runtime replacement was superseded',
      );
    }
    final previous = _runtime!;
    _runtime = next;
    await previous.close();
  }

  Future<ModelRef> resolveConfiguredModel({String? agentId}) =>
      _requireRuntime().resolveConfiguredModel(agentId: agentId);

  Future<ChatResponse> chat(ChatRequest request) =>
      _requireRuntime().chat(request);

  Future<ModelCatalogSnapshot> discoverModels(
    String providerId, {
    bool forceRefresh = false,
  }) =>
      _requireRuntime().discoverModels(providerId, forceRefresh: forceRefresh);

  Future<ProviderHealthReport> probeHealth(String providerId) =>
      _requireRuntime().probeHealth(providerId);

  ProductionModelRuntime _requireRuntime() {
    if (_closed) {
      throw StateError('Production model runtime slot is closed');
    }
    return _runtime!;
  }

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closed = true;
    _generation++;
    final runtime = _runtime;
    _runtime = null;
    final closeFuture = _close(runtime);
    _closeFuture = closeFuture;
    return closeFuture;
  }

  Future<void> _close(ProductionModelRuntime? runtime) async {
    final pending = _pending.values.toList(growable: false);
    for (final creation in pending) {
      creation.cancellationToken.cancel();
    }
    await Future.wait<void>([
      for (final creation in pending)
        creation.future.then<void>(
          (next) => next.close(),
          onError: (Object _) {},
        ),
      if (runtime != null) runtime.close(),
    ]);
  }
}

final class _PendingRuntimeCreation {
  const _PendingRuntimeCreation(this.cancellationToken, this.future);

  final CancellationToken cancellationToken;
  final Future<ProductionModelRuntime> future;
}

final class _RuntimeCreationCancelled implements Exception {
  const _RuntimeCreationCancelled();
}

enum _RuntimeState { open, closing, closed }

final class _ProductionRuntimeLifecycle {
  final CancellationToken cancellationToken = CancellationToken();
  _RuntimeState _state = _RuntimeState.open;
  int _activeOperations = 0;
  Completer<void>? _drained;
  bool shutdownForced = false;

  void requireOpen() {
    if (_state != _RuntimeState.open) {
      throw StateError('Production model runtime is closed');
    }
  }

  Future<T> run<T>(Future<T> Function() operation) async {
    requireOpen();
    _activeOperations++;
    try {
      final result = await operation();
      if (_state != _RuntimeState.open) {
        throw _closedDuringOperation();
      }
      return result;
    } on Object {
      if (_state != _RuntimeState.open) {
        throw _closedDuringOperation();
      }
      rethrow;
    } finally {
      _activeOperations--;
      if (_activeOperations == 0) {
        _drained?.complete();
        _drained = null;
      }
    }
  }

  ModelRuntimeException _closedDuringOperation() => const ModelRuntimeException(
    code: ModelRuntimeErrorCode.streamInterrupted,
    safeMessage: '模型服务运行时已关闭',
    retryable: false,
  );

  Future<void> close(
    Future<void> Function() closeResource,
    Duration shutdownTimeout,
  ) async {
    if (_state == _RuntimeState.closed) return;
    if (_state == _RuntimeState.closing) {
      await _boundedCleanup(
        _drained?.future ?? Future<void>.value(),
        shutdownTimeout,
      );
      return;
    }
    _state = _RuntimeState.closing;
    cancellationToken.cancel();
    if (_activeOperations > 0) {
      _drained = Completer<void>();
      final drained = await _boundedCleanup(_drained!.future, shutdownTimeout);
      if (!drained) {
        shutdownForced = true;
        _drained = null;
      }
    }
    try {
      final cleaned = await _boundedCleanup(
        Future<void>.sync(closeResource),
        shutdownTimeout,
      );
      if (!cleaned) shutdownForced = true;
    } finally {
      _state = _RuntimeState.closed;
    }
  }
}

Future<bool> _boundedCleanup(Future<void> cleanup, Duration timeout) async {
  try {
    await cleanup.timeout(timeout);
    return true;
  } on Object {
    return false;
  }
}
