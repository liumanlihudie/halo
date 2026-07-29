import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_unary_http_adapter.dart';

void main() {
  final credential = EphemeralCredential(
    value: 'sk-test-credential-that-must-not-be-recorded',
    expiresAt: DateTime.utc(2030),
  );

  SecureJsonHttpClient client(FakeUnaryHttpAdapter adapter) =>
      SecureJsonHttpClient(
        adapter: adapter,
        endpointPolicy: _AllowingEndpointPolicy(),
      );

  test(
    'OpenAI-compatible transport fixes POST path headers and JSON body',
    () async {
      final adapter = FakeUnaryHttpAdapter(
        retainSafeHeaderValuesForTesting: true,
        retainRequestContentForTesting: true,
      )..enqueueJson(statusCode: 200, body: {'choices': <Object?>[]});
      final transport = ProductionOpenAICompatibleHttpTransport(
        client: client(adapter),
        now: () => DateTime.utc(2029),
      );

      final response = await transport.sendChat(
        OpenAICompatibleTransportRequest(
          endpoint: Uri.parse('https://gateway.example/v1/chat/completions'),
          body: {'model': 'example', 'messages': <Object?>[], 'stream': false},
          credential: credential,
          headerCredentials: {'X-Tenant-Key': credential},
        ),
      );

      expect(response.statusCode, 200);
      final record = adapter.records.single;
      expect(record.method, 'POST');
      expect(record.path, '/v1/chat/completions');
      expect(record.contentType, 'application/json');
      expect(record.accept, 'application/json');
      expect(record.hadCredential, isTrue);
      expect(record.authorizationWasBearer, isTrue);
      expect(record.body['stream'], isFalse);
      expect(record.toString(), isNot(contains(credential.value)));
    },
  );

  test(
    'OpenAI native transport uses bearer auth and fixed chat path',
    () async {
      final adapter = FakeUnaryHttpAdapter(retainRequestContentForTesting: true)
        ..enqueueJson(statusCode: 200, body: {'id': 'response'});
      final transport = ProductionOpenAINativeHttpTransport(
        client: client(adapter),
        now: () => DateTime.utc(2029),
      );

      await transport.sendChat(
        OpenAINativeTransportRequest(
          endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
          body: {'model': 'gpt-5', 'messages': <Object?>[]},
          credential: credential,
        ),
      );

      final record = adapter.records.single;
      expect(record.path, '/v1/chat/completions');
      expect(record.authorizationWasBearer, isTrue);
      expect(record.hadCredential, isTrue);
    },
  );

  test('Anthropic transport uses x-api-key and version header', () async {
    final adapter = FakeUnaryHttpAdapter(
      retainSafeHeaderValuesForTesting: true,
      retainRequestContentForTesting: true,
    )..enqueueJson(statusCode: 200, body: {'content': <Object?>[]});
    final transport = ProductionAnthropicHttpTransport(
      client: client(adapter),
      now: () => DateTime.utc(2029),
    );

    await transport.sendMessage(
      AnthropicTransportRequest(
        endpoint: Uri.parse('https://api.anthropic.com/v1/messages'),
        body: {'model': 'claude', 'messages': <Object?>[]},
        credential: credential,
        apiVersion: '2023-06-01',
      ),
    );

    final record = adapter.records.single;
    expect(record.path, '/v1/messages');
    expect(record.hadApiKey, isTrue);
    expect(record.hadCredential, isTrue);
    expect(record.safeHeaders['anthropic-version'], '2023-06-01');
  });

  test('Gemini transport uses its API key header and generate path', () async {
    final adapter = FakeUnaryHttpAdapter(retainRequestContentForTesting: true)
      ..enqueueJson(statusCode: 200, body: {'candidates': <Object?>[]});
    final transport = ProductionGeminiHttpTransport(
      client: client(adapter),
      now: () => DateTime.utc(2029),
    );

    await transport.generateContent(
      GeminiTransportRequest(
        endpoint: Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/'
          'models/gemini-2.5-pro:generateContent',
        ),
        body: {'contents': <Object?>[]},
        credential: credential,
      ),
    );

    final record = adapter.records.single;
    expect(record.path, '/v1beta/models/gemini-2.5-pro:generateContent');
    expect(record.hadGoogleApiKey, isTrue);
    expect(record.hadCredential, isTrue);
  });

  test('redirect response is returned once and never followed', () async {
    final adapter = FakeUnaryHttpAdapter()
      ..enqueueJson(
        statusCode: 302,
        body: const {},
        headers: {'location': 'https://attacker.example/collect'},
      );
    final transport = ProductionOpenAINativeHttpTransport(
      client: client(adapter),
      now: () => DateTime.utc(2029),
    );

    final response = await transport.sendChat(
      OpenAINativeTransportRequest(
        endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
        body: {'model': 'gpt-5', 'messages': <Object?>[]},
        credential: credential,
      ),
    );

    expect(response.statusCode, 302);
    expect(adapter.records, hasLength(1));
    expect(adapter.records.single.followRedirects, isFalse);
  });

  test('credential never enters URI exception or string output', () async {
    final adapter = FakeUnaryHttpAdapter()
      ..enqueueError(
        StateError('Authorization ${credential.value} upstream response body'),
      );
    final transport = ProductionOpenAINativeHttpTransport(
      client: client(adapter),
      now: () => DateTime.utc(2029),
    );
    final request = OpenAINativeTransportRequest(
      endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
      body: {'model': 'gpt-5', 'messages': <Object?>[]},
      credential: credential,
    );

    await expectLater(
      transport.sendChat(request),
      throwsA(
        isA<UnaryTransportException>()
            .having(
              (error) => error.code,
              'code',
              UnaryTransportErrorCode.networkFailure,
            )
            .having(
              (error) => error.toString(),
              'safe output',
              isNot(contains(credential.value)),
            ),
      ),
    );
    expect(request.endpoint.toString(), isNot(contains(credential.value)));
    expect(request.toString(), isNot(contains(credential.value)));
    expect(
      adapter.records.single.toString(),
      isNot(contains(credential.value)),
    );
  });

  test('transport rejects a credential embedded in an endpoint path', () async {
    final adapter = FakeUnaryHttpAdapter();
    final transport = ProductionOpenAINativeHttpTransport(
      client: client(adapter),
      now: () => DateTime.utc(2029),
    );

    await expectLater(
      transport.sendChat(
        OpenAINativeTransportRequest(
          endpoint: Uri.parse(
            'https://api.openai.com/v1/${credential.value}/chat/completions',
          ),
          body: {'model': 'gpt-5', 'messages': <Object?>[]},
          credential: credential,
        ),
      ),
      throwsA(
        isA<UnaryTransportException>().having(
          (error) => error.code,
          'code',
          UnaryTransportErrorCode.invalidEndpoint,
        ),
      ),
    );
    expect(adapter.callCount, 0);
  });

  test('transport rejects a credential containing header injection', () async {
    final adapter = FakeUnaryHttpAdapter();
    final transport = ProductionOpenAINativeHttpTransport(
      client: client(adapter),
      now: () => DateTime.utc(2029),
    );

    await expectLater(
      transport.sendChat(
        OpenAINativeTransportRequest(
          endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
          body: {'model': 'gpt-5', 'messages': <Object?>[]},
          credential: EphemeralCredential(
            value: 'secret\r\nX-Injected: yes',
            expiresAt: DateTime.utc(2030),
          ),
        ),
      ),
      throwsA(
        isA<UnaryTransportException>().having(
          (error) => error.code,
          'code',
          UnaryTransportErrorCode.invalidCredential,
        ),
      ),
    );
    expect(adapter.callCount, 0);
  });

  test('compatible transport rejects credential header conflicts', () async {
    for (final headerName in [
      'Content-Type',
      'accept',
      'Host',
      'Transfer-Encoding',
      'Proxy-Authorization',
    ]) {
      final adapter = FakeUnaryHttpAdapter();
      final transport = ProductionOpenAICompatibleHttpTransport(
        client: client(adapter),
        now: () => DateTime.utc(2029),
      );

      await expectLater(
        transport.sendChat(
          OpenAICompatibleTransportRequest(
            endpoint: Uri.parse('https://gateway.example/v1/chat/completions'),
            body: {'model': 'example', 'messages': <Object?>[]},
            headerCredentials: {headerName: credential},
          ),
        ),
        throwsA(
          isA<UnaryTransportException>().having(
            (error) => error.code,
            'code',
            UnaryTransportErrorCode.invalidRequest,
          ),
        ),
        reason: headerName,
      );
      expect(adapter.callCount, 0);
    }
  });

  test(
    'HTTP retry-after metadata survives without parsing an error body',
    () async {
      final adapter = FakeUnaryHttpAdapter()
        ..enqueueRaw(
          statusCode: 429,
          headers: {'retry-after': '7'},
          bytes: utf8.encode('Authorization sk-upstream-secret invalid json'),
        );
      final transport = ProductionOpenAINativeHttpTransport(
        client: client(adapter),
        now: () => DateTime.utc(2029),
      );

      final response = await transport.sendChat(
        OpenAINativeTransportRequest(
          endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
          body: {'model': 'gpt-5', 'messages': <Object?>[]},
          credential: credential,
        ),
      );

      expect(response.statusCode, 429);
      expect(response.retryAfter, const Duration(seconds: 7));
      expect(response.body, isEmpty);
    },
  );

  test('compatible request string exposes only credential counts', () {
    final request = OpenAICompatibleTransportRequest(
      endpoint: Uri.parse('https://example.com/v1/chat/completions'),
      body: const {},
      credential: credential,
      headerCredentials: {
        'X-Secret-Name\r\nInjected': credential,
        'Authorization': credential,
      },
    );

    expect(request.toString(), contains('hasCredential: true'));
    expect(request.toString(), contains('headerCredentialCount: 2'));
    expect(request.toString(), isNot(contains('X-Secret-Name')));
    expect(request.toString(), isNot(contains('Authorization')));
    expect(request.toString(), isNot(contains(credential.value)));
  });

  test('Anthropic request string never includes API version text', () {
    final request = AnthropicTransportRequest(
      endpoint: Uri.parse('https://api.anthropic.com/v1/messages'),
      body: const {},
      credential: credential,
      apiVersion: '2023-06-01\r\nAuthorization: ${credential.value}',
    );

    expect(request.toString(), isNot(contains('apiVersion')));
    expect(request.toString(), isNot(contains('Authorization')));
    expect(request.toString(), isNot(contains(credential.value)));
  });
}

class _AllowingEndpointPolicy implements EndpointPolicy {
  @override
  Future<void> validateBeforeConnect(Uri endpoint) async {}

  @override
  void validateAfterConnect(Uri endpoint, InternetAddress remoteAddress) {}
}
