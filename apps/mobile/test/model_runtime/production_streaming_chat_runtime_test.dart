import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/chat_stream_models.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/production_streaming_chat_runtime.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/sqlite_provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/structured_sse_frame.dart';
import 'package:halo_mobile/model_runtime/testing/fake_secret_resolver.dart';
import 'package:halo_mobile/model_runtime/testing/fake_structured_sse_transport.dart';

void main() {
  final secretRef = SecretRef.parse(
    'keychain://halo.provider/11111111-1111-4111-8111-111111111111',
  );
  final deepSeek = ProviderConfig.deepSeek(secretRef: secretRef);
  final chatModel = ModelRef(providerId: 'deepseek', modelId: 'deepseek-chat');
  final now = DateTime.utc(2026, 7, 30, 12);

  late Directory directory;
  late SqliteProviderConfigurationStore store;
  late FakeSecretResolver resolver;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('halo-stream-runtime-');
    store = SqliteProviderConfigurationStore.open(
      '${directory.path}/providers.sqlite',
    );
    resolver = FakeSecretResolver();
    final mutation = await store.replaceProviderConfiguration(
      expectedRevision: null,
      replacement: ProviderConfigurationReplacement(
        config: deepSeek,
        modelCatalog: PersistedProviderModelCatalog(
          providerId: 'deepseek',
          models: [
            ModelDescriptor(
              ref: chatModel,
              displayName: 'DeepSeek Chat',
              capabilities: const ModelCapabilities.text(),
            ),
          ],
          discoveredAt: DateTime.utc(2026, 7, 30),
        ),
      ),
    );
    await store.markProviderMutationRuntimePublished(mutation);
    await store.finalizeProviderMutation(mutation);
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  void putValidCredential() {
    resolver.put(
      secretRef,
      EphemeralCredential(
        value: 'test-key',
        expiresAt: now.add(const Duration(hours: 1)),
      ),
    );
  }

  ChatRequest request({ModelRef? model}) => ChatRequest(
    requestId: 'req-1',
    model: model ?? chatModel,
    messages: [ChatMessage(role: ChatRole.user, content: '你好')],
  );

  test('the happy path streams delta, usage and finish from the transport '
      'and sends a stream-enabled body to the chat completions endpoint '
      'with a sensitive auth header', () async {
    putValidCredential();
    Uri? capturedEndpoint;
    Map<String, Object?>? capturedBody;
    Map<String, String>? capturedHeaders;
    Set<String>? capturedSensitiveNames;
    CancellationToken? capturedToken;
    final runtime = ProductionStreamingChatRuntime(
      store: store,
      secretResolver: resolver,
      now: () => now,
      transportFactory:
          ({
            required Uri endpoint,
            required Map<String, Object?> jsonBody,
            required Map<String, String> headers,
            required Set<String> sensitiveHeaderNames,
            CancellationToken? cancellationToken,
          }) {
            capturedEndpoint = endpoint;
            capturedBody = jsonBody;
            capturedHeaders = headers;
            capturedSensitiveNames = sensitiveHeaderNames;
            capturedToken = cancellationToken;
            return FakeStructuredSseTransport.fromFrames([
              StructuredSseFrame.data({
                'choices': [
                  {
                    'delta': {'content': '你好，'},
                  },
                ],
              }),
              StructuredSseFrame.data({
                'choices': [
                  {
                    'delta': {'content': '世界'},
                  },
                ],
              }),
              StructuredSseFrame.data({
                'choices': [
                  {'delta': <String, Object?>{}, 'finish_reason': 'stop'},
                ],
              }),
              StructuredSseFrame.data({
                'choices': <Object?>[],
                'usage': {'prompt_tokens': 3, 'completion_tokens': 7},
              }),
              StructuredSseFrame.done(),
            ]);
          },
    );

    final token = CancellationToken();
    final events = await runtime
        .streamChat(request(), cancellationToken: token)
        .toList();

    expect(events, hasLength(4));
    expect(events[0].type, ChatStreamEventType.delta);
    expect(events[0].text, '你好，');
    expect(events[1].type, ChatStreamEventType.delta);
    expect(events[1].text, '世界');
    expect(events[2].type, ChatStreamEventType.usage);
    expect(events[2].usage, const ChatUsage(inputTokens: 3, outputTokens: 7));
    expect(events[3].type, ChatStreamEventType.finish);
    expect(events[3].finishReason, ChatFinishReason.completed);
    expect(events.map((event) => event.seq), orderedEquals(const [1, 2, 3, 4]));

    expect(
      capturedEndpoint,
      Uri.parse('https://api.deepseek.com/v1/chat/completions'),
    );
    expect(capturedBody?['model'], 'deepseek-chat');
    expect(capturedBody?['stream'], isTrue);
    // Deliberately absent: relays that reject the unknown field would demote
    // every run to the unary path, and streamed usage totals are unused.
    expect(capturedBody?.containsKey('stream_options'), isFalse);
    expect(capturedBody?['messages'], [
      {'role': 'user', 'content': '你好'},
    ]);
    expect(capturedHeaders?['authorization'], 'Bearer test-key');
    expect(capturedSensitiveNames, contains('authorization'));
    expect(capturedToken, same(token));
  });

  test('an unknown provider yields a single invalidConfiguration error '
      'without touching the transport', () async {
    putValidCredential();
    var factoryCalls = 0;
    final runtime = ProductionStreamingChatRuntime(
      store: store,
      secretResolver: resolver,
      now: () => now,
      transportFactory:
          ({
            required Uri endpoint,
            required Map<String, Object?> jsonBody,
            required Map<String, String> headers,
            required Set<String> sensitiveHeaderNames,
            CancellationToken? cancellationToken,
          }) {
            factoryCalls++;
            return FakeStructuredSseTransport.fromFrames(const []);
          },
    );

    final events = await runtime
        .streamChat(
          request(
            model: ModelRef(providerId: 'toapis', modelId: 'gpt-5.2'),
          ),
          cancellationToken: CancellationToken(),
        )
        .toList();

    expect(events, hasLength(1));
    expect(events.single.seq, 1);
    expect(events.single.type, ChatStreamEventType.error);
    expect(events.single.errorCode, ModelRuntimeErrorCode.invalidConfiguration);
    expect(events.single.safeMessage, '模型服务不可用');
    expect(events.single.retryable, isFalse);
    expect(factoryCalls, 0);
  });

  test('a provider on a non-openAI-compatible protocol yields '
      'unsupportedEndpoint so the caller can fall back to unary', () async {
    await store.upsert(ProviderConfig.anthropic());
    final runtime = ProductionStreamingChatRuntime(
      store: store,
      secretResolver: resolver,
      now: () => now,
      transportFactory:
          ({
            required Uri endpoint,
            required Map<String, Object?> jsonBody,
            required Map<String, String> headers,
            required Set<String> sensitiveHeaderNames,
            CancellationToken? cancellationToken,
          }) => FakeStructuredSseTransport.fromFrames(const []),
    );

    final events = await runtime
        .streamChat(
          request(
            model: ModelRef(
              providerId: 'anthropic',
              modelId: 'claude-sonnet-4-5',
            ),
          ),
          cancellationToken: CancellationToken(),
        )
        .toList();

    expect(events, hasLength(1));
    expect(events.single.type, ChatStreamEventType.error);
    expect(events.single.errorCode, ModelRuntimeErrorCode.unsupportedEndpoint);
    expect(events.single.safeMessage, '暂不支持该服务的流式输出');
    expect(events.single.retryable, isFalse);
  });

  test(
    'a credential the resolver cannot produce yields invalidCredential',
    () async {
      // No credential registered in the fake resolver.
      final runtime = ProductionStreamingChatRuntime(
        store: store,
        secretResolver: resolver,
        now: () => now,
        transportFactory:
            ({
              required Uri endpoint,
              required Map<String, Object?> jsonBody,
              required Map<String, String> headers,
              required Set<String> sensitiveHeaderNames,
              CancellationToken? cancellationToken,
            }) => FakeStructuredSseTransport.fromFrames(const []),
      );

      final events = await runtime
          .streamChat(request(), cancellationToken: CancellationToken())
          .toList();

      expect(events, hasLength(1));
      expect(events.single.seq, 1);
      expect(events.single.type, ChatStreamEventType.error);
      expect(events.single.errorCode, ModelRuntimeErrorCode.invalidCredential);
      expect(events.single.safeMessage, '模型服务凭证不可用');
      expect(events.single.retryable, isFalse);
    },
  );

  test('an expired credential yields invalidCredential', () async {
    resolver.put(
      secretRef,
      EphemeralCredential(
        value: 'stale-key',
        expiresAt: now.subtract(const Duration(minutes: 1)),
      ),
    );
    final runtime = ProductionStreamingChatRuntime(
      store: store,
      secretResolver: resolver,
      now: () => now,
      transportFactory:
          ({
            required Uri endpoint,
            required Map<String, Object?> jsonBody,
            required Map<String, String> headers,
            required Set<String> sensitiveHeaderNames,
            CancellationToken? cancellationToken,
          }) => FakeStructuredSseTransport.fromFrames(const []),
    );

    final events = await runtime
        .streamChat(request(), cancellationToken: CancellationToken())
        .toList();

    expect(events, hasLength(1));
    expect(events.single.errorCode, ModelRuntimeErrorCode.invalidCredential);
  });

  test('a throwing transport factory yields a single safe transportFailure '
      'that never leaks the exception text', () async {
    putValidCredential();
    final runtime = ProductionStreamingChatRuntime(
      store: store,
      secretResolver: resolver,
      now: () => now,
      transportFactory:
          ({
            required Uri endpoint,
            required Map<String, Object?> jsonBody,
            required Map<String, String> headers,
            required Set<String> sensitiveHeaderNames,
            CancellationToken? cancellationToken,
          }) => throw StateError('socket exploded: host=internal.example'),
    );

    final events = await runtime
        .streamChat(request(), cancellationToken: CancellationToken())
        .toList();

    expect(events, hasLength(1));
    expect(events.single.seq, 1);
    expect(events.single.type, ChatStreamEventType.error);
    expect(events.single.errorCode, ModelRuntimeErrorCode.transportFailure);
    expect(events.single.safeMessage, '无法连接模型服务');
    expect(events.single.retryable, isTrue);
    expect(events.single.safeMessage, isNot(contains('socket')));
    expect(events.single.safeMessage, isNot(contains('internal.example')));
  });

  test('cancellation before the first frame ends the stream without a '
      'terminal event', () async {
    putValidCredential();
    final transport = FakeStructuredSseTransport.controlled();
    final runtime = ProductionStreamingChatRuntime(
      store: store,
      secretResolver: resolver,
      now: () => now,
      transportFactory:
          ({
            required Uri endpoint,
            required Map<String, Object?> jsonBody,
            required Map<String, String> headers,
            required Set<String> sensitiveHeaderNames,
            CancellationToken? cancellationToken,
          }) => transport,
    );

    final token = CancellationToken();
    final eventsFuture = runtime
        .streamChat(request(), cancellationToken: token)
        .toList();
    token.cancel();
    // The runtime never subscribes once the token is cancelled, so awaiting
    // close() on the sync controller would wait for a done delivery that can
    // never happen.
    unawaited(transport.close());

    expect(await eventsFuture, isEmpty);
  });
}
