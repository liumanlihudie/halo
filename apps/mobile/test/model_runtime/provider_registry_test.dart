import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';

void main() {
  test(
    'registry routes the same model id through distinct providers',
    () async {
      final registry = ProviderRegistry()
        ..register(
          _EchoProvider(
            ProviderConfig.deepSeek(),
            prefix: 'deepseek',
            models: [_model('deepseek', 'shared-model')],
          ),
        )
        ..register(
          _EchoProvider(
            ProviderConfig.toApis(),
            prefix: 'toapis',
            models: [_model('toapis', 'shared-model')],
          ),
        );

      final deepSeek = await registry.chat(
        _request(ModelRef(providerId: 'deepseek', modelId: 'shared-model')),
      );
      final toApis = await registry.chat(
        _request(ModelRef(providerId: 'toapis', modelId: 'shared-model')),
      );

      expect(deepSeek.outputText, 'deepseek:shared-model:hello');
      expect(toApis.outputText, 'toapis:shared-model:hello');
    },
  );

  test('registry rejects a model outside the provider catalog', () async {
    final provider = _EchoProvider(
      ProviderConfig.deepSeek(),
      prefix: 'deepseek',
      models: [_model('deepseek', 'allowed-model')],
    );
    final registry = ProviderRegistry()..register(provider);

    await expectLater(
      registry.chat(
        _request(ModelRef(providerId: 'deepseek', modelId: 'unknown-model')),
      ),
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.modelNotFound,
        ),
      ),
    );
    expect(provider.callCount, 0);
  });

  test('registry rejects unsupported system-message capability', () async {
    final provider = _EchoProvider(
      ProviderConfig.deepSeek(),
      prefix: 'deepseek',
      models: [
        _model(
          'deepseek',
          'no-system',
          capabilities: const ModelCapabilities(
            textGeneration: true,
            systemMessages: false,
            maxOutputTokens: 4096,
          ),
        ),
      ],
    );
    final registry = ProviderRegistry()..register(provider);

    await expectLater(
      registry.chat(
        ChatRequest(
          requestId: 'request-system',
          model: ModelRef(providerId: 'deepseek', modelId: 'no-system'),
          messages: [
            ChatMessage(role: ChatRole.system, content: 'be concise'),
            ChatMessage(role: ChatRole.user, content: 'hello'),
          ],
        ),
      ),
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.unsupportedCapability,
        ),
      ),
    );
    expect(provider.callCount, 0);
  });

  test('registry enforces the catalog output-token limit', () async {
    final provider = _EchoProvider(
      ProviderConfig.toApis(),
      prefix: 'toapis',
      models: [
        _model(
          'toapis',
          'small-model',
          capabilities: const ModelCapabilities(
            textGeneration: true,
            systemMessages: true,
            maxOutputTokens: 128,
          ),
        ),
      ],
    );
    final registry = ProviderRegistry()..register(provider);

    await expectLater(
      registry.chat(
        ChatRequest(
          requestId: 'too-many-tokens',
          model: ModelRef(providerId: 'toapis', modelId: 'small-model'),
          messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
          maxOutputTokens: 129,
        ),
      ),
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.unsupportedCapability,
        ),
      ),
    );
    expect(provider.callCount, 0);
  });

  test(
    'registry rejects temperature when the model does not support it',
    () async {
      final provider = _EchoProvider(
        ProviderConfig.deepSeek(),
        prefix: 'deepseek',
        models: [
          _model(
            'deepseek',
            'fixed-temperature',
            capabilities: const ModelCapabilities.text(
              supportsTemperature: false,
            ),
          ),
        ],
      );
      final registry = ProviderRegistry()..register(provider);

      await expectLater(
        registry.chat(
          ChatRequest(
            requestId: 'temperature-not-supported',
            model: ModelRef(
              providerId: 'deepseek',
              modelId: 'fixed-temperature',
            ),
            messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
            temperature: 0.5,
          ),
        ),
        throwsA(
          isA<ModelRuntimeException>().having(
            (error) => error.code,
            'code',
            ModelRuntimeErrorCode.unsupportedCapability,
          ),
        ),
      );
      expect(provider.callCount, 0);
    },
  );

  test('registry rejects unknown disabled and duplicate providers', () async {
    final disabled = _EchoProvider(
      ProviderConfig.deepSeek(enabled: false),
      prefix: 'disabled',
      models: [_model('deepseek', 'chat')],
    );
    final registry = ProviderRegistry()..register(disabled);

    await expectLater(
      registry.chat(_request(ModelRef(providerId: 'missing', modelId: 'chat'))),
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.providerNotFound,
        ),
      ),
    );
    await expectLater(
      registry.chat(
        _request(ModelRef(providerId: 'deepseek', modelId: 'chat')),
      ),
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.providerDisabled,
        ),
      ),
    );
    expect(
      () => registry.register(
        _EchoProvider(
          ProviderConfig.deepSeek(),
          prefix: 'duplicate',
          models: [_model('deepseek', 'chat')],
        ),
      ),
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.invalidConfiguration,
        ),
      ),
    );
  });
}

ModelDescriptor _model(
  String providerId,
  String modelId, {
  ModelCapabilities capabilities = const ModelCapabilities.text(),
}) => ModelDescriptor(
  ref: ModelRef(providerId: providerId, modelId: modelId),
  displayName: modelId,
  capabilities: capabilities,
);

ChatRequest _request(ModelRef model) => ChatRequest(
  requestId: 'request-1',
  model: model,
  messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
);

class _EchoProvider implements ModelProvider {
  _EchoProvider(this.config, {required this.prefix, required this.models});

  @override
  final ProviderConfig config;
  final String prefix;
  final List<ModelDescriptor> models;
  int callCount = 0;

  @override
  Iterable<ModelDescriptor> get modelCatalog => models;

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    callCount++;
    return ChatResponse(
      requestId: request.requestId,
      model: request.model,
      outputText:
          '$prefix:${request.model.modelId}:${request.messages.single.content}',
      finishReason: ChatFinishReason.completed,
      usage: const ChatUsage(inputTokens: 4, outputTokens: 2),
    );
  }
}
