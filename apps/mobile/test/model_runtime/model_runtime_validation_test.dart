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
