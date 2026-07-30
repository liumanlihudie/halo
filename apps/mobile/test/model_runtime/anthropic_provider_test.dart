import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_anthropic_transport.dart';
import 'package:halo_mobile/model_runtime/testing/fake_secret_resolver.dart';

void main() {
  test(
    'Anthropic adapter maps system separately and normalizes response',
    () async {
      final transport = FakeAnthropicTransport()
        ..enqueue(
          const AnthropicTransportResponse(
            statusCode: 200,
            body: {
              'id': 'msg-1',
              'content': [
                {'type': 'text', 'text': 'Claude answer'},
              ],
              'stop_reason': 'end_turn',
              'usage': {'input_tokens': 31, 'output_tokens': 12},
            },
          ),
        );
      final provider = _provider(transport: transport);

      final response = await provider.chat(
        ChatRequest(
          requestId: 'anthropic-request',
          model: ModelRef(providerId: 'anthropic', modelId: 'claude-text'),
          messages: [
            ChatMessage(role: ChatRole.system, content: 'first system'),
            ChatMessage(role: ChatRole.system, content: 'second system'),
            ChatMessage(role: ChatRole.user, content: 'question'),
            ChatMessage(role: ChatRole.assistant, content: 'earlier answer'),
          ],
          temperature: 0.2,
          maxOutputTokens: 600,
        ),
      );

      expect(response.outputText, 'Claude answer');
      expect(response.finishReason, ChatFinishReason.completed);
      expect(
        response.usage,
        const ChatUsage(inputTokens: 31, outputTokens: 12),
      );
      expect(transport.records.single.body, const {
        'model': 'claude-text',
        'system': 'first system\n\nsecond system',
        'messages': [
          {'role': 'user', 'content': 'question'},
          {'role': 'assistant', 'content': 'earlier answer'},
        ],
        'temperature': 0.2,
        'max_tokens': 600,
      });
      expect(transport.records.single.metadata['apiVersion'], '2023-06-01');
      expect(
        transport.records.single.endpoint,
        Uri.parse('https://api.anthropic.com/v1/messages'),
      );
    },
  );

  test(
    'Anthropic adapter rejects wrong protocol unknown model and capability',
    () async {
      expect(
        () => AnthropicModelProvider(
          config: ProviderConfig.gemini(),
          modelCatalog: [_model('gemini', 'gemini-text')],
          secretResolver: FakeSecretResolver(),
          transport: FakeAnthropicTransport(),
        ),
        throwsA(_errorCode(ModelRuntimeErrorCode.unsupportedProtocol)),
      );

      final provider = _provider();
      await expectLater(
        provider.chat(_request('unknown')),
        throwsA(_errorCode(ModelRuntimeErrorCode.modelNotFound)),
      );

      final limited = AnthropicModelProvider(
        config: ProviderConfig.anthropic(
          secretRef: SecretRef.parse('memory://test/anthropic'),
        ),
        modelCatalog: [
          ModelDescriptor(
            ref: ModelRef(providerId: 'anthropic', modelId: 'limited'),
            displayName: 'Limited',
            capabilities: const ModelCapabilities(
              textGeneration: true,
              systemMessages: true,
              maxOutputTokens: 10,
            ),
          ),
        ],
        secretResolver: _resolver(),
        transport: FakeAnthropicTransport(),
      );
      await expectLater(
        limited.chat(
          ChatRequest(
            requestId: 'too-large',
            model: ModelRef(providerId: 'anthropic', modelId: 'limited'),
            messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
            maxOutputTokens: 11,
          ),
        ),
        throwsA(_errorCode(ModelRuntimeErrorCode.unsupportedCapability)),
      );
    },
  );

  test('Anthropic adapter fails closed without a valid credential', () async {
    final provider = AnthropicModelProvider(
      config: ProviderConfig.anthropic(),
      modelCatalog: [_model('anthropic', 'claude-text')],
      secretResolver: FakeSecretResolver(),
      transport: FakeAnthropicTransport(),
    );

    await expectLater(
      provider.chat(_request('claude-text')),
      throwsA(_errorCode(ModelRuntimeErrorCode.invalidCredential)),
    );
  });

  test(
    'Anthropic adapter sanitizes thrown errors and HTTP response body',
    () async {
      final thrownTransport = FakeAnthropicTransport()
        ..enqueueError(
          const ModelRuntimeException(
            code: ModelRuntimeErrorCode.invalidCredential,
            safeMessage: 'x-api-key sk-anthropic upstream body',
            retryable: false,
          ),
        );
      await expectLater(
        _provider(transport: thrownTransport).chat(_request('claude-text')),
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
                  isNot(contains('sk-anthropic')),
                  isNot(contains('x-api-key')),
                  isNot(contains('upstream body')),
                ),
              ),
        ),
      );

      final httpTransport = FakeAnthropicTransport()
        ..enqueue(
          const AnthropicTransportResponse(
            statusCode: 401,
            body: {'error': 'sk-anthropic private upstream body'},
          ),
        );
      await expectLater(
        _provider(transport: httpTransport).chat(_request('claude-text')),
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
                isNot(contains('sk-anthropic')),
              ),
        ),
      );
    },
  );

  test('Anthropic finish reasons normalize to the shared contract', () async {
    final cases = {
      'end_turn': ChatFinishReason.completed,
      'stop_sequence': ChatFinishReason.completed,
      'max_tokens': ChatFinishReason.length,
      'model_context_window_exceeded': ChatFinishReason.length,
      'refusal': ChatFinishReason.contentFiltered,
      'future_reason': ChatFinishReason.unknown,
    };
    for (final entry in cases.entries) {
      final transport = FakeAnthropicTransport()..enqueue(_response(entry.key));
      final response = await _provider(
        transport: transport,
      ).chat(_request('claude-text'));
      expect(response.finishReason, entry.value, reason: entry.key);
    }
  });

  test('Anthropic refusal may complete without visible text', () async {
    final transport = FakeAnthropicTransport()
      ..enqueue(
        const AnthropicTransportResponse(
          statusCode: 200,
          body: {
            'content': [],
            'stop_reason': 'refusal',
            'usage': {'input_tokens': 3, 'output_tokens': 0},
          },
        ),
      );
    final response = await _provider(
      transport: transport,
    ).chat(_request('claude-text'));
    expect(response.outputText, isEmpty);
    expect(response.finishReason, ChatFinishReason.contentFiltered);
  });

  test(
    'Anthropic accepts empty successful text and includes cache usage',
    () async {
      final transport = FakeAnthropicTransport()
        ..enqueue(
          const AnthropicTransportResponse(
            statusCode: 200,
            body: {
              'content': [],
              'stop_reason': 'end_turn',
              'usage': {
                'input_tokens': 3,
                'cache_creation_input_tokens': 5,
                'cache_read_input_tokens': 7,
                'output_tokens': 0,
              },
            },
          ),
        );

      final response = await _provider(
        transport: transport,
      ).chat(_request('claude-text'));

      expect(response.outputText, isEmpty);
      expect(response.finishReason, ChatFinishReason.completed);
      expect(response.usage, const ChatUsage(inputTokens: 15, outputTokens: 0));
    },
  );

  test(
    'Anthropic enforces provider temperature range before transport',
    () async {
      final transport = FakeAnthropicTransport();
      final provider = _provider(transport: transport);

      await expectLater(
        provider.chat(
          ChatRequest(
            requestId: 'temperature-too-high',
            model: ModelRef(providerId: 'anthropic', modelId: 'claude-text'),
            messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
            temperature: 1.1,
          ),
        ),
        throwsA(_errorCode(ModelRuntimeErrorCode.unsupportedCapability)),
      );
      expect(transport.records, isEmpty);
    },
  );

  test(
    'Anthropic rejects temperature for a model without that capability',
    () async {
      final transport = FakeAnthropicTransport();
      final provider = AnthropicModelProvider(
        config: ProviderConfig.anthropic(
          secretRef: SecretRef.parse('memory://test/anthropic'),
        ),
        modelCatalog: [
          ModelDescriptor(
            ref: ModelRef(
              providerId: 'anthropic',
              modelId: 'fixed-temperature',
            ),
            displayName: 'Fixed temperature',
            capabilities: const ModelCapabilities.text(
              supportsTemperature: false,
            ),
          ),
        ],
        secretResolver: _resolver(),
        transport: transport,
      );

      await expectLater(
        provider.chat(
          ChatRequest(
            requestId: 'unsupported-temperature',
            model: ModelRef(
              providerId: 'anthropic',
              modelId: 'fixed-temperature',
            ),
            messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
            temperature: 0.5,
          ),
        ),
        throwsA(_errorCode(ModelRuntimeErrorCode.unsupportedCapability)),
      );
      expect(transport.records, isEmpty);
    },
  );
}

AnthropicModelProvider _provider({FakeAnthropicTransport? transport}) =>
    AnthropicModelProvider(
      config: ProviderConfig.anthropic(
        secretRef: SecretRef.parse('memory://test/anthropic'),
      ),
      modelCatalog: [_model('anthropic', 'claude-text')],
      secretResolver: _resolver(),
      transport: transport ?? FakeAnthropicTransport(),
    );

FakeSecretResolver _resolver() {
  final ref = SecretRef.parse('memory://test/anthropic');
  return FakeSecretResolver()..put(
    ref,
    EphemeralCredential(
      value: 'test-anthropic-credential',
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
  model: ModelRef(providerId: 'anthropic', modelId: modelId),
  messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
  maxOutputTokens: 300,
);

Matcher _errorCode(ModelRuntimeErrorCode code) =>
    isA<ModelRuntimeException>().having((error) => error.code, 'code', code);

AnthropicTransportResponse _response(String stopReason) =>
    AnthropicTransportResponse(
      statusCode: 200,
      body: {
        'content': const [
          {'type': 'text', 'text': 'answer'},
        ],
        'stop_reason': stopReason,
        'usage': const {'input_tokens': 1, 'output_tokens': 1},
      },
    );
