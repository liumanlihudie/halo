import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_openai_native_transport.dart';
import 'package:halo_mobile/model_runtime/testing/fake_secret_resolver.dart';

void main() {
  test(
    'OpenAI adapter maps text messages parameters response and usage',
    () async {
      final transport = FakeOpenAINativeTransport()
        ..enqueue(
          const OpenAINativeTransportResponse(
            statusCode: 200,
            body: {
              'id': 'chatcmpl-1',
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'OpenAI answer'},
                  'finish_reason': 'length',
                },
              ],
              'usage': {'prompt_tokens': 21, 'completion_tokens': 9},
            },
          ),
        );
      final provider = _provider(transport: transport);

      final response = await provider.chat(
        ChatRequest(
          requestId: 'openai-request',
          model: ModelRef(providerId: 'openai', modelId: 'gpt-text'),
          messages: [
            ChatMessage(role: ChatRole.system, content: 'system rule'),
            ChatMessage(role: ChatRole.user, content: 'question'),
            ChatMessage(role: ChatRole.assistant, content: 'earlier answer'),
          ],
          temperature: 0.4,
          maxOutputTokens: 700,
        ),
      );

      expect(response.outputText, 'OpenAI answer');
      expect(response.finishReason, ChatFinishReason.length);
      expect(response.usage, const ChatUsage(inputTokens: 21, outputTokens: 9));
      expect(transport.records.single.body, const {
        'model': 'gpt-text',
        'messages': [
          {'role': 'system', 'content': 'system rule'},
          {'role': 'user', 'content': 'question'},
          {'role': 'assistant', 'content': 'earlier answer'},
        ],
        'temperature': 0.4,
        'max_completion_tokens': 700,
      });
      expect(transport.records.single.hadCredential, isTrue);
      expect(
        transport.records.single.endpoint,
        Uri.parse('https://api.openai.com/v1/chat/completions'),
      );
    },
  );

  test('OpenAI adapter rejects wrong protocol and unknown model', () async {
    expect(
      () => OpenAINativeModelProvider(
        config: ProviderConfig.anthropic(),
        modelCatalog: [_model('anthropic', 'claude')],
        secretResolver: FakeSecretResolver(),
        transport: FakeOpenAINativeTransport(),
      ),
      throwsA(_errorCode(ModelRuntimeErrorCode.unsupportedProtocol)),
    );

    final provider = _provider();
    await expectLater(
      provider.chat(_request('unknown')),
      throwsA(_errorCode(ModelRuntimeErrorCode.modelNotFound)),
    );
  });

  test('OpenAI adapter enforces capabilities before transport', () async {
    final transport = FakeOpenAINativeTransport();
    final provider = OpenAINativeModelProvider(
      config: ProviderConfig.openAI(
        secretRef: SecretRef.parse('memory://test/openai'),
      ),
      modelCatalog: [
        ModelDescriptor(
          ref: ModelRef(providerId: 'openai', modelId: 'no-system'),
          displayName: 'No system',
          capabilities: const ModelCapabilities(
            textGeneration: true,
            systemMessages: false,
            maxOutputTokens: 64,
          ),
        ),
      ],
      secretResolver: _resolver('openai'),
      transport: transport,
    );

    await expectLater(
      provider.chat(
        ChatRequest(
          requestId: 'capability',
          model: ModelRef(providerId: 'openai', modelId: 'no-system'),
          messages: [
            ChatMessage(role: ChatRole.system, content: 'system'),
            ChatMessage(role: ChatRole.user, content: 'hello'),
          ],
        ),
      ),
      throwsA(_errorCode(ModelRuntimeErrorCode.unsupportedCapability)),
    );
    expect(transport.records, isEmpty);
  });

  test('OpenAI adapter fails closed when credential is unavailable', () async {
    final provider = OpenAINativeModelProvider(
      config: ProviderConfig.openAI(),
      modelCatalog: [_model('openai', 'gpt-text')],
      secretResolver: FakeSecretResolver(),
      transport: FakeOpenAINativeTransport(),
    );

    await expectLater(
      provider.chat(_request('gpt-text')),
      throwsA(_errorCode(ModelRuntimeErrorCode.invalidCredential)),
    );
  });

  test(
    'OpenAI adapter sanitizes transport errors and response bodies',
    () async {
      final transport = FakeOpenAINativeTransport()
        ..enqueueError(
          const ModelRuntimeException(
            code: ModelRuntimeErrorCode.invalidCredential,
            safeMessage: 'Authorization Bearer sk-openai upstream body',
            retryable: false,
          ),
        );
      final provider = _provider(transport: transport);

      await expectLater(
        provider.chat(_request('gpt-text')),
        throwsA(
          isA<ModelRuntimeException>()
              .having(
                (error) => error.code,
                'code',
                ModelRuntimeErrorCode.transportFailure,
              )
              .having(
                (error) => error.toString(),
                'toString',
                allOf(
                  isNot(contains('sk-openai')),
                  isNot(contains('Authorization')),
                  isNot(contains('upstream body')),
                ),
              ),
        ),
      );

      final httpTransport = FakeOpenAINativeTransport()
        ..enqueue(
          const OpenAINativeTransportResponse(
            statusCode: 401,
            body: {'error': 'Authorization sk-openai private body'},
          ),
        );
      await expectLater(
        _provider(transport: httpTransport).chat(_request('gpt-text')),
        throwsA(
          isA<ModelRuntimeException>()
              .having(
                (error) => error.code,
                'code',
                ModelRuntimeErrorCode.invalidCredential,
              )
              .having(
                (error) => error.toString(),
                'toString',
                isNot(contains('sk-openai')),
              ),
        ),
      );
    },
  );

  test('OpenAI finish reasons normalize to the shared contract', () async {
    final cases = {
      'stop': ChatFinishReason.completed,
      'length': ChatFinishReason.length,
      'content_filter': ChatFinishReason.contentFiltered,
      'future_reason': ChatFinishReason.unknown,
    };
    for (final entry in cases.entries) {
      final transport = FakeOpenAINativeTransport()
        ..enqueue(_response(entry.key));
      final response = await _provider(
        transport: transport,
      ).chat(_request('gpt-text'));
      expect(response.finishReason, entry.value, reason: entry.key);
    }
  });

  test('OpenAI content filtering may complete without visible text', () async {
    final transport = FakeOpenAINativeTransport()
      ..enqueue(
        const OpenAINativeTransportResponse(
          statusCode: 200,
          body: {
            'choices': [
              {
                'message': {'content': null},
                'finish_reason': 'content_filter',
              },
            ],
            'usage': {'prompt_tokens': 3, 'completion_tokens': 0},
          },
        ),
      );
    final response = await _provider(
      transport: transport,
    ).chat(_request('gpt-text'));
    expect(response.outputText, isEmpty);
    expect(response.finishReason, ChatFinishReason.contentFiltered);
  });

  test(
    'OpenAI parses text parts and defaults optional usage to zero',
    () async {
      final transport = FakeOpenAINativeTransport()
        ..enqueue(
          const OpenAINativeTransportResponse(
            statusCode: 200,
            body: {
              'choices': [
                {
                  'message': {
                    'content': [
                      {'type': 'text', 'text': 'first '},
                      {'type': 'text', 'text': 'second'},
                    ],
                  },
                  'finish_reason': 'stop',
                },
              ],
            },
          ),
        );

      final response = await _provider(
        transport: transport,
      ).chat(_request('gpt-text'));

      expect(response.outputText, 'first second');
      expect(response.finishReason, ChatFinishReason.completed);
      expect(response.usage, const ChatUsage(inputTokens: 0, outputTokens: 0));
    },
  );

  test(
    'OpenAI maps refusal parts and message refusal to content filtered',
    () async {
      final responses = [
        const OpenAINativeTransportResponse(
          statusCode: 200,
          body: {
            'choices': [
              {
                'message': {
                  'content': [
                    {'type': 'refusal', 'refusal': 'Cannot help with that.'},
                  ],
                },
                'finish_reason': 'stop',
              },
            ],
          },
        ),
        const OpenAINativeTransportResponse(
          statusCode: 200,
          body: {
            'choices': [
              {
                'message': {'content': null, 'refusal': 'Request refused.'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {'prompt_tokens': 4},
          },
        ),
      ];

      for (final transportResponse in responses) {
        final transport = FakeOpenAINativeTransport()
          ..enqueue(transportResponse);
        final response = await _provider(
          transport: transport,
        ).chat(_request('gpt-text'));

        expect(response.outputText, isNotEmpty);
        expect(response.finishReason, ChatFinishReason.contentFiltered);
        expect(response.usage.outputTokens, 0);
      }
    },
  );

  test('OpenAI sanitizes SecretResolver failures', () async {
    final provider = OpenAINativeModelProvider(
      config: ProviderConfig.openAI(
        secretRef: SecretRef.parse('memory://test/openai'),
      ),
      modelCatalog: [_model('openai', 'gpt-text')],
      secretResolver: _SensitiveFailingResolver(),
      transport: FakeOpenAINativeTransport(),
    );

    await expectLater(
      provider.chat(_request('gpt-text')),
      throwsA(
        isA<ModelRuntimeException>()
            .having(
              (error) => error.code,
              'code',
              ModelRuntimeErrorCode.invalidCredential,
            )
            .having(
              (error) => error.toString(),
              'toString',
              isNot(contains('sk-resolver-secret')),
            ),
      ),
    );
  });
}

OpenAINativeModelProvider _provider({FakeOpenAINativeTransport? transport}) =>
    OpenAINativeModelProvider(
      config: ProviderConfig.openAI(
        secretRef: SecretRef.parse('memory://test/openai'),
      ),
      modelCatalog: [_model('openai', 'gpt-text')],
      secretResolver: _resolver('openai'),
      transport: transport ?? FakeOpenAINativeTransport(),
    );

ModelDescriptor _model(String providerId, String modelId) => ModelDescriptor(
  ref: ModelRef(providerId: providerId, modelId: modelId),
  displayName: modelId,
  capabilities: const ModelCapabilities.text(),
);

FakeSecretResolver _resolver(String name) {
  final ref = SecretRef.parse('memory://test/$name');
  return FakeSecretResolver()..put(
    ref,
    EphemeralCredential(
      value: 'test-$name-credential',
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    ),
  );
}

ChatRequest _request(String modelId) => ChatRequest(
  requestId: 'request',
  model: ModelRef(providerId: 'openai', modelId: modelId),
  messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
);

Matcher _errorCode(ModelRuntimeErrorCode code) =>
    isA<ModelRuntimeException>().having((error) => error.code, 'code', code);

OpenAINativeTransportResponse _response(String finishReason) =>
    OpenAINativeTransportResponse(
      statusCode: 200,
      body: {
        'choices': [
          {
            'message': {'content': 'answer'},
            'finish_reason': finishReason,
          },
        ],
        'usage': const {'prompt_tokens': 1, 'completion_tokens': 1},
      },
    );

class _SensitiveFailingResolver implements SecretResolver {
  @override
  Future<EphemeralCredential?> resolve(SecretRef ref) async {
    throw StateError('Authorization sk-resolver-secret');
  }
}
