import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';

void main() {
  test('ModelRef rejects blank provider and model identifiers', () {
    expect(
      () => ModelRef(providerId: ' ', modelId: 'model'),
      throwsArgumentError,
    );
    expect(
      () => ModelRef(providerId: 'provider', modelId: '\n'),
      throwsArgumentError,
    );
  });

  test('runtime identifiers reject trimming and Unicode attack aliases', () {
    for (final invalid in [
      ' chat',
      'chat ',
      'safe\u034fevil',
      'safe\u{e0001}evil',
      'safe\u{e0020}evil',
      'safe\u0600evil',
      'safe\u0605evil',
      'safe\u06ddevil',
      'safe\u070fevil',
      'safe\u0890evil',
      'safe\u0891evil',
      'safe\u08e2evil',
      'safe\u{110bd}evil',
      String.fromCharCode(0xd800),
      'a' * 257,
    ]) {
      expect(
        () => ModelRef(providerId: 'provider', modelId: invalid),
        throwsArgumentError,
      );
      expect(
        () => ChatRequest(
          requestId: invalid,
          model: ModelRef(providerId: 'provider', modelId: 'model'),
          messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
        ),
        throwsArgumentError,
      );
    }
  });

  test(
    'display names enforce scalar safety without rejecting CJK or emoji',
    () {
      for (final invalid in [
        ' model',
        'model ',
        'safe\u034fevil',
        'safe\u{e0001}evil',
        'safe\u{e0020}evil',
        String.fromCharCode(0xdfff),
      ]) {
        expect(
          () => ModelDescriptor(
            ref: ModelRef(providerId: 'provider', modelId: 'model'),
            displayName: invalid,
            capabilities: const ModelCapabilities.text(),
          ),
          throwsArgumentError,
        );
      }
      final descriptor = ModelDescriptor(
        ref: ModelRef(providerId: 'provider', modelId: 'model'),
        displayName: '模型 🚀',
        capabilities: const ModelCapabilities.text(),
      );
      expect(descriptor.displayName, '模型 🚀');
    },
  );

  test('chat response identifiers reject upstream Unicode aliases', () {
    final model = ModelRef(providerId: 'provider', modelId: 'model');
    for (final invalid in [
      ' response',
      'response ',
      'safe\u200bevil',
      'safe\u{e0001}evil',
      String.fromCharCode(0xd800),
    ]) {
      expect(
        () => ChatResponse(
          requestId: 'request',
          model: model,
          outputText: 'ok',
          finishReason: ChatFinishReason.completed,
          usage: const ChatUsage(inputTokens: 1, outputTokens: 1),
          providerRequestId: invalid,
        ),
        throwsArgumentError,
      );
    }
  });

  test('text chat roles are limited to system user and assistant', () {
    expect(ChatRole.values.map((role) => role.name).toList(), const [
      'system',
      'user',
      'assistant',
    ]);
  });

  test('ChatMessage rejects empty text in every supported role', () {
    for (final role in ChatRole.values) {
      expect(() => ChatMessage(role: role, content: '  '), throwsArgumentError);
    }
  });

  test('ChatRequest rejects blank request id and empty messages', () {
    final model = ModelRef(providerId: 'toapis', modelId: 'chat');
    final message = ChatMessage(role: ChatRole.user, content: 'hello');

    expect(
      () => ChatRequest(requestId: ' ', model: model, messages: [message]),
      throwsArgumentError,
    );
    expect(
      () => ChatRequest(requestId: 'request', model: model, messages: const []),
      throwsArgumentError,
    );
  });

  test('ChatRequest validates temperature and output token bounds', () {
    final model = ModelRef(providerId: 'toapis', modelId: 'chat');
    final messages = [ChatMessage(role: ChatRole.user, content: 'hello')];

    for (final temperature in [-0.1, 2.1, double.nan]) {
      expect(
        () => ChatRequest(
          requestId: 'request',
          model: model,
          messages: messages,
          temperature: temperature,
        ),
        throwsArgumentError,
      );
    }
    for (final tokens in [0, -1, ChatRequest.maximumOutputTokens + 1]) {
      expect(
        () => ChatRequest(
          requestId: 'request',
          model: model,
          messages: messages,
          maxOutputTokens: tokens,
        ),
        throwsArgumentError,
      );
    }
  });
}
