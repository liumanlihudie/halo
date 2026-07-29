/// Contract and fake scaffold for model-runtime integration.
///
/// This package intentionally contains no production HTTP client, native
/// provider SDK, credential storage, or tool-calling contract.
library;

export 'anthropic_model_provider.dart';
export 'anthropic_stream_normalizer.dart';
export 'anthropic_transport.dart';
export 'cancellation_token.dart';
export 'chat_stream_models.dart';
export 'chat_stream_normalizer.dart';
export 'gemini_model_provider.dart';
export 'gemini_stream_normalizer.dart';
export 'gemini_transport.dart';
export 'model_runtime_errors.dart';
export 'model_runtime_models.dart';
export 'model_catalog_discovery.dart';
export 'openai_compatible_model_provider.dart';
export 'openai_compatible_transport.dart';
export 'openai_native_model_provider.dart';
export 'openai_native_transport.dart';
export 'openai_stream_normalizer.dart';
export 'provider_config.dart';
export 'provider_health_probe.dart';
export 'provider_inspection_models.dart';
export 'provider_inspection_transport.dart';
export 'provider_registry.dart';
export 'secret_ref.dart';
export 'streaming_chat_runtime.dart';
export 'structured_sse_frame.dart';
