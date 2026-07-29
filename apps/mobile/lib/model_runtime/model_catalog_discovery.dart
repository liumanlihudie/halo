import 'dart:async';

import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_models.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_support.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_transport.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

class ModelCatalogDiscovery {
  ModelCatalogDiscovery({
    required Iterable<ProviderConfig> configs,
    required this.transport,
    required this.secretResolver,
    this.ttl = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _configs = indexInspectionConfigs(configs),
       _now = now ?? defaultInspectionNow {
    if (ttl <= Duration.zero) {
      throw ArgumentError.value(ttl, 'ttl');
    }
  }

  static const maximumModelCount = 500;
  static const maximumModelIdLength = 128;
  static const maximumDisplayNameLength = 120;
  static const maximumCapabilityHintCount = 32;

  final Map<String, ProviderConfig> _configs;
  final ProviderInspectionTransport transport;
  final SecretResolver secretResolver;
  final Duration ttl;
  final DateTime Function() _now;
  final Map<String, ModelCatalogSnapshot> _cache = {};
  final Map<String, _CatalogFlight> _flights = {};

  Future<ModelCatalogSnapshot> discover(
    String providerId, {
    bool forceRefresh = false,
    CancellationToken? cancellationToken,
  }) async {
    final config = requireInspectionConfig(_configs, providerId);
    final callerToken = cancellationToken ?? CancellationToken();
    if (callerToken.isCancelled) {
      throw inspectionCancelled();
    }

    final cached = _cache[providerId];
    if (!forceRefresh && cached != null) {
      final age = _now().difference(cached.discoveredAt);
      if (!age.isNegative && age < ttl) {
        return cached.asCached();
      }
    }

    final flight = _flights[providerId] ?? _createFlight(config);
    flight.waiterCount++;
    var callerCancelled = false;
    try {
      return await Future.any([
        flight.future,
        callerToken.whenCancelled.then<ModelCatalogSnapshot>((_) {
          callerCancelled = true;
          throw inspectionCancelled();
        }),
      ]);
    } finally {
      flight.waiterCount--;
      if (callerCancelled && flight.waiterCount == 0 && !flight.completed) {
        flight.cancellationToken.cancel();
      }
    }
  }

  _CatalogFlight _createFlight(ProviderConfig config) {
    final token = CancellationToken();
    late final _CatalogFlight flight;
    final future = _fetch(config, token);
    flight = _CatalogFlight(future: future, cancellationToken: token);
    _flights[config.providerId] = flight;
    future.then(
      (snapshot) {
        flight.completed = true;
        _cache[config.providerId] = snapshot;
        if (identical(_flights[config.providerId], flight)) {
          _flights.remove(config.providerId);
        }
      },
      onError: (_, _) {
        flight.completed = true;
        if (identical(_flights[config.providerId], flight)) {
          _flights.remove(config.providerId);
        }
      },
    );
    return flight;
  }

  Future<ModelCatalogSnapshot> _fetch(
    ProviderConfig config,
    CancellationToken token,
  ) async {
    final request = await buildInspectionRequest(
      config: config,
      secretResolver: secretResolver,
      cancellationToken: token,
      now: _now,
    );
    late final ProviderCatalogTransportResult upstream;
    try {
      upstream = await awaitInspectionOrCancellation(
        transport.discoverModels(request),
        token,
      );
    } on ModelRuntimeException catch (error) {
      if (error.code == ModelRuntimeErrorCode.streamInterrupted) {
        rethrow;
      }
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.transportFailure,
        safeMessage: '无法获取模型目录',
        retryable: true,
      );
    } catch (_) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.transportFailure,
        safeMessage: '无法获取模型目录',
        retryable: true,
      );
    }
    try {
      return ModelCatalogSnapshot(
        providerId: config.providerId,
        models: _sanitizeModels(config, upstream.models),
        discoveredAt: _now(),
        fromCache: false,
      );
    } catch (_) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.malformedResponse,
        safeMessage: '模型目录数据无效',
        retryable: false,
      );
    }
  }

  List<ModelDescriptor> _sanitizeModels(
    ProviderConfig config,
    List<UpstreamModelMetadata> upstream,
  ) {
    if (upstream.length > maximumModelCount) {
      throw const FormatException();
    }
    final deduplicated = <String, ModelDescriptor>{};
    for (final raw in upstream) {
      if (raw.providerId != config.providerId) {
        throw const FormatException();
      }
      final modelId = raw.modelId.trim();
      final displayName = raw.displayName.trim();
      if (!_safeModelId(modelId) || !_safeDisplayName(displayName)) {
        throw const FormatException();
      }
      if (raw.capabilityHints.length > maximumCapabilityHintCount) {
        throw const FormatException();
      }
      _validateHintValues(raw.capabilityHints);
      deduplicated.putIfAbsent(
        modelId,
        () => ModelDescriptor(
          ref: ModelRef(providerId: config.providerId, modelId: modelId),
          displayName: displayName,
          capabilities: _mapCapabilities(config, raw.capabilityHints),
        ),
      );
    }
    final models = deduplicated.values.toList()
      ..sort((left, right) {
        final byName = left.displayName.toLowerCase().compareTo(
          right.displayName.toLowerCase(),
        );
        return byName != 0
            ? byName
            : left.ref.modelId.compareTo(right.ref.modelId);
      });
    return models;
  }

  bool _safeModelId(String value) =>
      value.isNotEmpty &&
      value.length <= maximumModelIdLength &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]*$').hasMatch(value);

  bool _safeDisplayName(String value) =>
      value.isNotEmpty &&
      value.length <= maximumDisplayNameLength &&
      !RegExp(
        r'[\x00-\x1F\x7F-\x9F\u00AD\u061C\u180E'
        r'\u200B-\u200F\u2028-\u202E\u2060-\u206F'
        r'\uFEFF\uFFF9-\uFFFB]',
      ).hasMatch(value);

  void _validateHintValues(Map<String, Object?> hints) {
    for (final entry in hints.entries) {
      if (entry.key.isEmpty ||
          entry.key.length > 64 ||
          !RegExp(r'^[a-z0-9_]+$').hasMatch(entry.key) ||
          (entry.value is! bool && entry.value is! int)) {
        throw const FormatException();
      }
    }
  }

  ModelCapabilities _mapCapabilities(
    ProviderConfig config,
    Map<String, Object?> hints,
  ) {
    final (textKey, systemKey, temperatureKey) = switch (config.protocol) {
      ProviderProtocol.openAICompatible => (
        'supports_chat',
        'supports_system',
        'supports_temperature',
      ),
      ProviderProtocol.openAI => (
        'chat_completions',
        'system_messages',
        'temperature',
      ),
      ProviderProtocol.anthropic => (
        'messages',
        'system_messages',
        'temperature',
      ),
      ProviderProtocol.gemini => (
        'generate_content',
        'system_instruction',
        'temperature',
      ),
    };
    final maxTokens = hints['max_output_tokens'] as int? ?? 16384;
    if (maxTokens <= 0 || maxTokens > ChatRequest.maximumOutputTokens) {
      throw const FormatException();
    }
    return ModelCapabilities(
      textGeneration: hints[textKey] as bool? ?? false,
      systemMessages: hints[systemKey] as bool? ?? false,
      maxOutputTokens: maxTokens,
      supportsTemperature: hints[temperatureKey] as bool? ?? false,
    );
  }
}

class _CatalogFlight {
  _CatalogFlight({required this.future, required this.cancellationToken});

  final Future<ModelCatalogSnapshot> future;
  final CancellationToken cancellationToken;
  int waiterCount = 0;
  bool completed = false;
}
