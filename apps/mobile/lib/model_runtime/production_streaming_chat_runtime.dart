// ignore_for_file: prefer_initializing_formals

import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/chat_stream_models.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/openai_stream_normalizer.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/streaming_chat_runtime.dart';
import 'package:halo_mobile/model_runtime/structured_sse_frame.dart';

/// Builds one transport per streaming request. The caller injects the
/// production SSE transport constructor so this runtime stays decoupled from
/// the concrete HTTP implementation.
typedef SseTransportFactory =
    StructuredSseFrameTransport Function({
      required Uri endpoint,
      required Map<String, Object?> jsonBody,
      required Map<String, String> headers,
      required Set<String> sensitiveHeaderNames,
      CancellationToken? cancellationToken,
    });

/// Streams chat completions from openAI-compatible providers.
///
/// Configuration is re-resolved on every call so a settings change made
/// between messages applies to the next message without restarting the app.
/// Every failure surfaces as a terminal [ChatStreamEvent.error] carrying only
/// pre-approved safe text — raw exception content never reaches the UI.
final class ProductionStreamingChatRuntime
    implements StreamingChatModelRuntime {
  ProductionStreamingChatRuntime({
    required ProviderConfigurationStore store,
    required SecretResolver secretResolver,
    required SseTransportFactory transportFactory,
    DateTime Function()? now,
  }) : _store = store,
       _secretResolver = secretResolver,
       _transportFactory = transportFactory,
       _now = now ?? DateTime.now;

  final ProviderConfigurationStore _store;
  final SecretResolver _secretResolver;
  final SseTransportFactory _transportFactory;
  final DateTime Function() _now;

  @override
  Stream<ChatStreamEvent> streamChat(
    ChatRequest request, {
    required CancellationToken cancellationToken,
  }) async* {
    late final Stream<StructuredSseFrame> frames;
    try {
      frames = await _openFrameStream(request, cancellationToken);
    } on ModelRuntimeException catch (exception) {
      if (!cancellationToken.isCancelled) {
        yield _errorEvent(seq: 1, exception: exception);
      }
      return;
    } catch (_) {
      if (!cancellationToken.isCancelled) {
        yield _errorEvent(seq: 1, exception: _transportFailure);
      }
      return;
    }

    var lastSeq = 0;
    try {
      final events = OpenAICompatibleStreamNormalizer().normalize(
        frames,
        cancellationToken: cancellationToken,
      );
      await for (final event in events) {
        lastSeq = event.seq > lastSeq ? event.seq : lastSeq;
        yield event;
      }
    } catch (_) {
      if (!cancellationToken.isCancelled) {
        yield _errorEvent(seq: lastSeq + 1, exception: _transportFailure);
      }
    }
  }

  Future<Stream<StructuredSseFrame>> _openFrameStream(
    ChatRequest request,
    CancellationToken cancellationToken,
  ) async {
    final config = await _loadConfig(request.model.providerId);
    if (config == null || !config.enabled) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.invalidConfiguration,
        safeMessage: '模型服务不可用',
        retryable: false,
      );
    }
    if (config.protocol != ProviderProtocol.openAICompatible) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.unsupportedEndpoint,
        safeMessage: '暂不支持该服务的流式输出',
        retryable: false,
      );
    }

    final credential = await _resolveCredential(config.secretRef);
    final headers = <String, String>{
      if (credential != null) 'authorization': 'Bearer ${credential.value}',
    };
    final sensitiveHeaderNames = <String>{'authorization'};
    for (final entry in config.headerSecretRefs.entries) {
      final headerCredential = await _requiredCredential(entry.value);
      headers[entry.key] = headerCredential.value;
      sensitiveHeaderNames.add(entry.key.toLowerCase());
    }

    final body = <String, Object?>{
      'model': request.model.modelId,
      'messages': request.messages.map((message) => message.toJson()).toList(),
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxOutputTokens != null)
        'max_tokens': request.maxOutputTokens,
      'stream': true,
      'stream_options': {'include_usage': true},
    };

    final transport = _transportFactory(
      endpoint: _chatEndpoint(config.baseUri),
      jsonBody: body,
      headers: headers,
      sensitiveHeaderNames: sensitiveHeaderNames,
      cancellationToken: cancellationToken,
    );
    return transport.openFrameStream();
  }

  Future<ProviderConfig?> _loadConfig(String providerId) async {
    final configs = await _store.loadEnabled();
    for (final config in configs) {
      if (config.providerId == providerId) {
        return config;
      }
    }
    return null;
  }

  Future<EphemeralCredential?> _resolveCredential(SecretRef? ref) async {
    if (ref == null) return null;
    return _requiredCredential(ref);
  }

  Future<EphemeralCredential> _requiredCredential(SecretRef ref) async {
    final EphemeralCredential? credential;
    try {
      credential = await _secretResolver.resolve(ref);
    } catch (_) {
      throw _invalidCredential;
    }
    if (credential == null || !credential.isValidAt(_now())) {
      throw _invalidCredential;
    }
    return credential;
  }

  Uri _chatEndpoint(Uri baseUri) {
    final basePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(path: '$basePath/chat/completions');
  }

  ChatStreamEvent _errorEvent({
    required int seq,
    required ModelRuntimeException exception,
  }) => ChatStreamEvent.error(
    seq: seq,
    code: exception.code,
    safeMessage: exception.safeMessage,
    retryable: exception.retryable,
  );

  static const _invalidCredential = ModelRuntimeException(
    code: ModelRuntimeErrorCode.invalidCredential,
    safeMessage: '模型服务凭证不可用',
    retryable: false,
  );

  static const _transportFailure = ModelRuntimeException(
    code: ModelRuntimeErrorCode.transportFailure,
    safeMessage: '无法连接模型服务',
    retryable: true,
  );
}
