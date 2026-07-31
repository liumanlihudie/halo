// ignore_for_file: prefer_initializing_formals

import 'package:dartantic_ai/dartantic_ai.dart' as dartantic;
import 'package:halo_mobile/app/dartantic_single_chat_port.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

/// Resolves the configured model and its credential into a dartantic agent.
///
/// The API key is read from the Keychain here and handed straight to the
/// client library; it is never returned to, or stored by, the chat layer.
final class ProductionSingleChatAgentFactory
    implements SingleChatAgentFactory, ModelAgentFactory {
  ProductionSingleChatAgentFactory({
    required ProviderConfigurationStore store,
    required SecretResolver secretResolver,
    required Future<ModelRef> Function({required String agentId}) resolveModel,
  }) : _store = store,
       _secretResolver = secretResolver,
       _resolveModel = resolveModel;

  final ProviderConfigurationStore _store;
  final SecretResolver _secretResolver;
  final Future<ModelRef> Function({required String agentId}) _resolveModel;

  @override
  Future<dartantic.Agent> agentFor(
    String expertId, {
    List<dartantic.Tool> tools = const [],
  }) async {
    final ModelRef model;
    try {
      model = await _resolveModel(agentId: expertId);
    } catch (_) {
      throw StateError('No model is configured for this expert');
    }
    return agentForModel(model, tools: tools);
  }

  @override
  Future<dartantic.Agent> agentForModel(
    ModelRef model, {
    List<dartantic.Tool> tools = const [],
  }) async {
    final config = await _enabledConfig(model.providerId);
    if (config == null) {
      throw StateError('The configured provider is not enabled');
    }
    final ref = config.secretRef;
    if (ref == null) {
      throw StateError('The configured provider has no credential');
    }
    final credential = await _secretResolver.resolve(ref);
    if (credential == null) {
      throw StateError('The provider credential is unavailable');
    }
    return dartantic.Agent.forProvider(
      dartantic.OpenAIProvider(
        name: config.providerId,
        apiKey: credential.value,
        baseUrl: config.baseUri,
      ),
      chatModelName: model.modelId,
      tools: tools.isEmpty ? null : tools,
    );
  }

  Future<ProviderConfig?> _enabledConfig(String providerId) async {
    for (final config in await _store.loadEnabled()) {
      if (config.providerId == providerId) return config;
    }
    return null;
  }
}
