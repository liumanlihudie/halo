import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_gemini_transport.dart';
import 'package:halo_mobile/model_runtime/testing/fake_secret_resolver.dart';

void main() {
  test(
    'Gemini adapter maps roles generation config response and usage',
    () async {
      final transport = FakeGeminiTransport()
        ..enqueue(
          const GeminiTransportResponse(
            statusCode: 200,
            body: {
              'responseId': 'gemini-response-1',
              'candidates': [
                {
                  'content': {
                    'role': 'model',
                    'parts': [
                      {'text': 'Gemini answer'},
                    ],
                  },
                  'finishReason': 'STOP',
                },
              ],
              'usageMetadata': {
                'promptTokenCount': 18,
                'candidatesTokenCount': 7,
              },
            },
          ),
        );
      final provider = _provider(transport: transport);

      final response = await provider.chat(
        ChatRequest(
          requestId: 'gemini-request',
          model: ModelRef(providerId: 'gemini', modelId: 'gemini-text'),
          messages: [
            ChatMessage(role: ChatRole.system, content: 'first system'),
            ChatMessage(role: ChatRole.system, content: 'second system'),
            ChatMessage(role: ChatRole.user, content: 'question'),
            ChatMessage(role: ChatRole.assistant, content: 'earlier answer'),
          ],
          temperature: 0.6,
          maxOutputTokens: 500,
        ),
      );

      expect(response.outputText, 'Gemini answer');
      expect(response.finishReason, ChatFinishReason.completed);
      expect(response.usage, const ChatUsage(inputTokens: 18, outputTokens: 7));
      expect(transport.records.single.body, const {
        'systemInstruction': {
          'parts': [
            {'text': 'first system\n\nsecond system'},
          ],
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': 'question'},
            ],
          },
          {
            'role': 'model',
            'parts': [
              {'text': 'earlier answer'},
            ],
          },
        ],
        'generationConfig': {'temperature': 0.6, 'maxOutputTokens': 500},
      });
      expect(
        transport.records.single.endpoint,
        Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/'
          'models/gemini-text:generateContent',
        ),
      );
      expect(transport.records.single.hadCredential, isTrue);
    },
  );

  test(
    'Gemini adapter maps safety finish reason without leaking body',
    () async {
      final transport = FakeGeminiTransport()
        ..enqueue(
          const GeminiTransportResponse(
            statusCode: 200,
            body: {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'blocked'},
                    ],
                  },
                  'finishReason': 'SAFETY',
                },
              ],
              'usageMetadata': {
                'promptTokenCount': 5,
                'candidatesTokenCount': 0,
              },
            },
          ),
        );

      final response = await _provider(
        transport: transport,
      ).chat(_request('gemini-text'));
      expect(response.finishReason, ChatFinishReason.contentFiltered);
    },
  );

  test('Gemini safety block may omit content', () async {
    final transport = FakeGeminiTransport()
      ..enqueue(
        const GeminiTransportResponse(
          statusCode: 200,
          body: {
            'candidates': [
              {'finishReason': 'SAFETY'},
            ],
            'usageMetadata': {'promptTokenCount': 5, 'candidatesTokenCount': 0},
          },
        ),
      );
    final response = await _provider(
      transport: transport,
    ).chat(_request('gemini-text'));
    expect(response.outputText, isEmpty);
    expect(response.finishReason, ChatFinishReason.contentFiltered);
  });

  test('Gemini prompt feedback block may omit candidates', () async {
    final transport = FakeGeminiTransport()
      ..enqueue(
        const GeminiTransportResponse(
          statusCode: 200,
          body: {
            'promptFeedback': {'blockReason': 'SAFETY'},
            'usageMetadata': {'promptTokenCount': 5, 'thoughtsTokenCount': 2},
          },
        ),
      );

    final response = await _provider(
      transport: transport,
    ).chat(_request('gemini-text'));

    expect(response.outputText, isEmpty);
    expect(response.finishReason, ChatFinishReason.contentFiltered);
    expect(response.usage, const ChatUsage(inputTokens: 5, outputTokens: 2));
  });

  test('Gemini includes thought tokens in output usage', () async {
    final transport = FakeGeminiTransport()
      ..enqueue(
        const GeminiTransportResponse(
          statusCode: 200,
          body: {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'answer'},
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
            'usageMetadata': {
              'promptTokenCount': 8,
              'candidatesTokenCount': 3,
              'thoughtsTokenCount': 4,
            },
          },
        ),
      );

    final response = await _provider(
      transport: transport,
    ).chat(_request('gemini-text'));

    expect(response.usage, const ChatUsage(inputTokens: 8, outputTokens: 7));
  });

  test('Gemini max-token and unknown finish reasons normalize', () async {
    final cases = {
      'MAX_TOKENS': ChatFinishReason.length,
      'future_reason': ChatFinishReason.unknown,
    };
    for (final entry in cases.entries) {
      final transport = FakeGeminiTransport()..enqueue(_response(entry.key));
      final response = await _provider(
        transport: transport,
      ).chat(_request('gemini-text'));
      expect(response.finishReason, entry.value, reason: entry.key);
    }
  });

  test(
    'Gemini adapter rejects wrong protocol unknown model and capability',
    () async {
      expect(
        () => GeminiModelProvider(
          config: ProviderConfig.openAI(),
          modelCatalog: [_model('openai', 'gpt')],
          secretResolver: FakeSecretResolver(),
          transport: FakeGeminiTransport(),
        ),
        throwsA(_errorCode(ModelRuntimeErrorCode.unsupportedProtocol)),
      );

      final provider = _provider();
      await expectLater(
        provider.chat(_request('unknown')),
        throwsA(_errorCode(ModelRuntimeErrorCode.modelNotFound)),
      );

      final noText = GeminiModelProvider(
        config: ProviderConfig.gemini(
          secretRef: SecretRef.parse('memory://test/gemini'),
        ),
        modelCatalog: [
          ModelDescriptor(
            ref: ModelRef(providerId: 'gemini', modelId: 'no-text'),
            displayName: 'No text',
            capabilities: const ModelCapabilities(
              textGeneration: false,
              systemMessages: true,
              maxOutputTokens: 100,
            ),
          ),
        ],
        secretResolver: _resolver(),
        transport: FakeGeminiTransport(),
      );
      await expectLater(
        noText.chat(_request('no-text')),
        throwsA(_errorCode(ModelRuntimeErrorCode.unsupportedCapability)),
      );
    },
  );

  test('Gemini adapter fails closed without a valid credential', () async {
    final provider = GeminiModelProvider(
      config: ProviderConfig.gemini(),
      modelCatalog: [_model('gemini', 'gemini-text')],
      secretResolver: FakeSecretResolver(),
      transport: FakeGeminiTransport(),
    );

    await expectLater(
      provider.chat(_request('gemini-text')),
      throwsA(_errorCode(ModelRuntimeErrorCode.invalidCredential)),
    );
  });

  test(
    'Gemini adapter sanitizes thrown errors and HTTP response body',
    () async {
      final thrownTransport = FakeGeminiTransport()
        ..enqueueError(
          const ModelRuntimeException(
            code: ModelRuntimeErrorCode.invalidCredential,
            safeMessage: 'x-goog-api-key sk-gemini upstream body',
            retryable: false,
          ),
        );
      await expectLater(
        _provider(transport: thrownTransport).chat(_request('gemini-text')),
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
                  isNot(contains('sk-gemini')),
                  isNot(contains('x-goog-api-key')),
                  isNot(contains('upstream body')),
                ),
              ),
        ),
      );

      final httpTransport = FakeGeminiTransport()
        ..enqueue(
          const GeminiTransportResponse(
            statusCode: 403,
            body: {'error': 'sk-gemini private upstream body'},
          ),
        );
      await expectLater(
        _provider(transport: httpTransport).chat(_request('gemini-text')),
        throwsA(
          isA<ModelRuntimeException>()
              .having(
                (error) => error.code,
                'code',
                ModelRuntimeErrorCode.modelNotAllowed,
              )
              .having(
                (error) => error.toString(),
                'toString',
                isNot(contains('sk-gemini')),
              ),
        ),
      );
    },
  );
}

GeminiModelProvider _provider({FakeGeminiTransport? transport}) =>
    GeminiModelProvider(
      config: ProviderConfig.gemini(
        secretRef: SecretRef.parse('memory://test/gemini'),
      ),
      modelCatalog: [_model('gemini', 'gemini-text')],
      secretResolver: _resolver(),
      transport: transport ?? FakeGeminiTransport(),
    );

FakeSecretResolver _resolver() {
  final ref = SecretRef.parse('memory://test/gemini');
  return FakeSecretResolver()..put(
    ref,
    EphemeralCredential(
      value: 'test-gemini-credential',
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    ),
  );
}

ModelDescriptor _model(String providerId, String modelId) => ModelDescriptor(
  ref: ModelRef(providerId: providerId, modelId: modelId),
  displayName: modelId,
  capabilities: const ModelCapabilities.text(),
);

ChatRequest _request(String modelId) => ChatRequest(
  requestId: 'request',
  model: ModelRef(providerId: 'gemini', modelId: modelId),
  messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
  maxOutputTokens: 300,
);

Matcher _errorCode(ModelRuntimeErrorCode code) =>
    isA<ModelRuntimeException>().having((error) => error.code, 'code', code);

GeminiTransportResponse _response(String finishReason) =>
    GeminiTransportResponse(
      statusCode: 200,
      body: {
        'candidates': [
          {
            'content': {
              'parts': const [
                {'text': 'answer'},
              ],
            },
            'finishReason': finishReason,
          },
        ],
        'usageMetadata': const {
          'promptTokenCount': 1,
          'candidatesTokenCount': 1,
        },
      },
    );
