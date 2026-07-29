import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_openai_compatible_transport.dart';
import 'package:halo_mobile/model_runtime/testing/fake_secret_resolver.dart';

void main() {
  test(
    'compatible provider resolves a short-lived credential before transport',
    () async {
      final secretRef = SecretRef.parse('memory://test/toapis');
      final headerRef = SecretRef.parse('memory://test/tenant-header');
      final resolver = FakeSecretResolver()
        ..put(
          secretRef,
          EphemeralCredential(
            value: 'test-only-token',
            expiresAt: DateTime.now().add(const Duration(minutes: 1)),
          ),
        )
        ..put(
          headerRef,
          EphemeralCredential(
            value: 'test-only-header',
            expiresAt: DateTime.now().add(const Duration(minutes: 1)),
          ),
        );
      final transport = FakeOpenAICompatibleTransport()
        ..enqueue(_successfulResponse('统一回答'));
      final provider = _compatibleProvider(
        config: ProviderConfig.customOpenAICompatible(
          providerId: 'toapis',
          displayName: 'ToAPIs test',
          baseUri: Uri.parse('https://toapis.com/v1'),
          secretRef: secretRef,
          headerSecretRefs: {'X-Tenant': headerRef},
        ),
        modelId: 'claude-compatible',
        resolver: resolver,
        transport: transport,
      );

      final response = await provider.chat(
        ChatRequest(
          requestId: 'request-7',
          model: ModelRef(providerId: 'toapis', modelId: 'claude-compatible'),
          messages: [
            ChatMessage(role: ChatRole.system, content: '你是产品专家'),
            ChatMessage(role: ChatRole.user, content: '给出结论'),
          ],
          temperature: 0.3,
          maxOutputTokens: 800,
        ),
      );

      expect(response.outputText, '统一回答');
      expect(response.usage, const ChatUsage(inputTokens: 12, outputTokens: 5));
      expect(
        transport.records.single.endpoint,
        Uri.parse('https://toapis.com/v1/chat/completions'),
      );
      expect(transport.records.single.hadCredential, isTrue);
      expect(transport.records.single.headerCredentialNames, const [
        'X-Tenant',
      ]);
      expect(transport.records.single.body['model'], 'claude-compatible');
      expect(
        transport.records.single.toString(),
        isNot(contains('test-only-token')),
      );
      expect(
        transport.records.single.toString(),
        isNot(contains('memory://test')),
      );
      expect(
        transport.records.single.toString(),
        isNot(contains('test-only-header')),
      );
      expect(
        transport.records.single.toString(),
        'SafeTransportRecord(origin: https://toapis.com, path: /***/, '
        'hadCredential: true, headerCredentialNames: [X-Tenant])',
      );
    },
  );

  test('transport request string redacts arbitrary endpoint path', () {
    final request = OpenAICompatibleTransportRequest(
      endpoint: Uri.parse(
        'https://models.example.com:8443/v1/sk-path-secret/chat/completions',
      ),
      body: const {'model': 'chat'},
    );

    expect(
      request.toString(),
      'OpenAICompatibleTransportRequest(origin: '
      'https://models.example.com:8443, path: /***/, '
      'hasCredential: false, headerCredentialCount: 0)',
    );
    expect(request.toString(), isNot(contains('sk-path-secret')));
  });

  test(
    'missing or expired resolved credential is rejected before transport',
    () async {
      final secretRef = SecretRef.parse('memory://test/toapis');
      final resolver = FakeSecretResolver()
        ..put(
          secretRef,
          EphemeralCredential(
            value: 'expired-test-token',
            expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
          ),
        );
      final transport = FakeOpenAICompatibleTransport();
      final provider = _compatibleProvider(
        config: ProviderConfig.toApis(secretRef: secretRef),
        modelId: 'chat',
        resolver: resolver,
        transport: transport,
      );

      await expectLater(
        provider.chat(_request('toapis', 'chat')),
        throwsA(
          isA<ModelRuntimeException>().having(
            (error) => error.code,
            'code',
            ModelRuntimeErrorCode.invalidCredential,
          ),
        ),
      );
      expect(transport.records, isEmpty);
    },
  );

  test(
    'cancellation after credential lookup fences transport dispatch',
    () async {
      final ref = SecretRef.parse('memory://test/delayed');
      final resolver = _DelayedSecretResolver();
      final transport = FakeOpenAICompatibleTransport()
        ..enqueue(_successfulResponse('must-not-dispatch'));
      final provider = _compatibleProvider(
        config: ProviderConfig.toApis(secretRef: ref),
        modelId: 'chat',
        resolver: resolver,
        transport: transport,
      );
      final cancellationToken = CancellationToken();
      final chat = provider.chat(
        ChatRequest(
          requestId: 'cancel-before-dispatch',
          model: ModelRef(providerId: 'toapis', modelId: 'chat'),
          messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
          cancellationToken: cancellationToken,
        ),
      );
      await resolver.requested.future;

      cancellationToken.cancel();
      resolver.complete();

      await expectLater(
        chat,
        throwsA(
          isA<ModelRuntimeException>().having(
            (error) => error.code,
            'code',
            ModelRuntimeErrorCode.streamInterrupted,
          ),
        ),
      );
      expect(transport.records, isEmpty);
    },
  );

  test('native provider configs cannot enter the compatible adapter', () {
    final nativeConfigs = [
      ProviderConfig.openAI(),
      ProviderConfig.anthropic(),
      ProviderConfig.gemini(),
    ];

    for (final config in nativeConfigs) {
      expect(
        () => OpenAICompatibleModelProvider(
          config: config,
          modelCatalog: [_model(config.providerId, 'native-model')],
          secretResolver: FakeSecretResolver(),
          transport: FakeOpenAICompatibleTransport(),
        ),
        throwsA(
          isA<ModelRuntimeException>().having(
            (error) => error.code,
            'code',
            ModelRuntimeErrorCode.unsupportedProtocol,
          ),
        ),
        reason: config.providerId,
      );
    }
  });

  test('compatible adapter rejects models outside its own catalog', () async {
    final provider = _compatibleProvider(
      config: ProviderConfig.deepSeek(),
      modelId: 'deepseek-chat',
      resolver: FakeSecretResolver(),
      transport: FakeOpenAICompatibleTransport(),
    );

    await expectLater(
      provider.chat(_request('deepseek', 'unknown-model')),
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.modelNotFound,
        ),
      ),
    );
  });

  test('HTTP failures map to safe retry policy', () {
    final cases = <int, (ModelRuntimeErrorCode, bool)>{
      400: (ModelRuntimeErrorCode.invalidRequest, false),
      401: (ModelRuntimeErrorCode.invalidCredential, false),
      402: (ModelRuntimeErrorCode.insufficientBalance, false),
      403: (ModelRuntimeErrorCode.modelNotAllowed, false),
      404: (ModelRuntimeErrorCode.modelNotFound, false),
      413: (ModelRuntimeErrorCode.assetTooLarge, false),
      422: (ModelRuntimeErrorCode.contentRejected, false),
      429: (ModelRuntimeErrorCode.rateLimited, true),
      503: (ModelRuntimeErrorCode.providerUnavailable, true),
    };

    for (final entry in cases.entries) {
      final error = ModelRuntimeErrorMapper.fromHttpStatus(entry.key);
      expect(error.code, entry.value.$1, reason: 'status ${entry.key}');
      expect(error.retryable, entry.value.$2, reason: 'status ${entry.key}');
    }
  });

  test('malformed success payload becomes a safe typed error', () async {
    final transport = FakeOpenAICompatibleTransport()
      ..enqueue(
        const OpenAICompatibleTransportResponse(
          statusCode: 200,
          body: {'raw': 'sk-secret upstream stack trace'},
        ),
      );
    final provider = _compatibleProvider(
      config: ProviderConfig.deepSeek(),
      modelId: 'deepseek-chat',
      resolver: FakeSecretResolver(),
      transport: transport,
    );

    await expectLater(
      provider.chat(_request('deepseek', 'deepseek-chat')),
      throwsA(
        isA<ModelRuntimeException>()
            .having(
              (error) => error.code,
              'code',
              ModelRuntimeErrorCode.malformedResponse,
            )
            .having(
              (error) => error.toString(),
              'toString',
              isNot(contains('sk-secret')),
            ),
      ),
    );
  });

  test(
    'transport ModelRuntimeException is rebuilt without sensitive text',
    () async {
      final provider = _compatibleProvider(
        config: ProviderConfig.deepSeek(),
        modelId: 'deepseek-chat',
        resolver: FakeSecretResolver(),
        transport: _SensitiveFailingTransport(),
      );

      await expectLater(
        provider.chat(_request('deepseek', 'deepseek-chat')),
        throwsA(
          isA<ModelRuntimeException>()
              .having(
                (error) => error.code,
                'code',
                ModelRuntimeErrorCode.transportFailure,
              )
              .having((error) => error.safeMessage, 'safeMessage', '无法连接模型服务')
              .having(
                (error) => error.toString(),
                'toString',
                allOf(
                  isNot(contains('sk-live-secret')),
                  isNot(contains('Authorization')),
                  isNot(contains('upstream body')),
                ),
              ),
        ),
      );
    },
  );
}

OpenAICompatibleModelProvider _compatibleProvider({
  required ProviderConfig config,
  required String modelId,
  required SecretResolver resolver,
  required OpenAICompatibleHttpTransport transport,
}) => OpenAICompatibleModelProvider(
  config: config,
  modelCatalog: [_model(config.providerId, modelId)],
  secretResolver: resolver,
  transport: transport,
);

ModelDescriptor _model(String providerId, String modelId) => ModelDescriptor(
  ref: ModelRef(providerId: providerId, modelId: modelId),
  displayName: modelId,
  capabilities: const ModelCapabilities.text(),
);

ChatRequest _request(String providerId, String modelId) => ChatRequest(
  requestId: 'request',
  model: ModelRef(providerId: providerId, modelId: modelId),
  messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
);

OpenAICompatibleTransportResponse _successfulResponse(String text) =>
    OpenAICompatibleTransportResponse(
      statusCode: 200,
      body: {
        'id': 'completion-1',
        'choices': [
          {
            'message': {'role': 'assistant', 'content': text},
            'finish_reason': 'stop',
          },
        ],
        'usage': const {
          'prompt_tokens': 12,
          'completion_tokens': 5,
          'total_tokens': 17,
        },
      },
    );

class _SensitiveFailingTransport implements OpenAICompatibleHttpTransport {
  @override
  Future<OpenAICompatibleTransportResponse> sendChat(
    OpenAICompatibleTransportRequest request,
  ) async {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.invalidCredential,
      safeMessage:
          'Authorization: Bearer sk-live-secret; upstream body: private',
      retryable: false,
    );
  }
}

final class _DelayedSecretResolver implements SecretResolver {
  final Completer<void> requested = Completer<void>();
  final Completer<EphemeralCredential?> _credential =
      Completer<EphemeralCredential?>();

  @override
  Future<EphemeralCredential?> resolve(SecretRef ref) {
    if (!requested.isCompleted) requested.complete();
    return _credential.future;
  }

  void complete() {
    _credential.complete(
      EphemeralCredential(
        value: 'test-only-delayed-token',
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      ),
    );
  }
}
