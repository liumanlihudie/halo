import 'package:halo_mobile/model_runtime/anthropic_model_provider.dart';
import 'package:halo_mobile/model_runtime/anthropic_transport.dart';
import 'package:halo_mobile/model_runtime/gemini_model_provider.dart';
import 'package:halo_mobile/model_runtime/gemini_transport.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/openai_compatible_model_provider.dart';
import 'package:halo_mobile/model_runtime/openai_compatible_transport.dart';
import 'package:halo_mobile/model_runtime/openai_native_model_provider.dart';
import 'package:halo_mobile/model_runtime/openai_native_transport.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_registry.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

final class ProductionModelTransports {
  const ProductionModelTransports({
    required this.openAICompatible,
    required this.openAI,
    required this.anthropic,
    required this.gemini,
  });

  final OpenAICompatibleHttpTransport openAICompatible;
  final OpenAINativeHttpTransport openAI;
  final AnthropicHttpTransport anthropic;
  final GeminiHttpTransport gemini;
}

ModelProvider buildProductionModelProvider({
  required ProviderConfig config,
  required Iterable<ModelDescriptor> modelCatalog,
  required SecretResolver secretResolver,
  required ProductionModelTransports transports,
}) => switch (config.protocol) {
  ProviderProtocol.openAICompatible => OpenAICompatibleModelProvider(
    config: config,
    modelCatalog: modelCatalog,
    secretResolver: secretResolver,
    transport: transports.openAICompatible,
  ),
  ProviderProtocol.openAI => OpenAINativeModelProvider(
    config: config,
    modelCatalog: modelCatalog,
    secretResolver: secretResolver,
    transport: transports.openAI,
  ),
  ProviderProtocol.anthropic => AnthropicModelProvider(
    config: config,
    modelCatalog: modelCatalog,
    secretResolver: secretResolver,
    transport: transports.anthropic,
  ),
  ProviderProtocol.gemini => GeminiModelProvider(
    config: config,
    modelCatalog: modelCatalog,
    secretResolver: secretResolver,
    transport: transports.gemini,
  ),
};
