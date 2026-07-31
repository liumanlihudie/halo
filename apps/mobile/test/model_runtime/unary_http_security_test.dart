import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_unary_http_adapter.dart';

void main() {
  test(
    'client rejects endpoint userinfo query fragment and insecure HTTP',
    () async {
      final adapter = FakeUnaryHttpAdapter();
      final client = SecureJsonHttpClient(
        adapter: adapter,
        endpointPolicy: _AllowingEndpointPolicy(),
      );

      for (final endpoint in [
        Uri.parse('https://user:pass@example.com/v1/chat'),
        Uri.parse('https://example.com/v1/chat?key=secret'),
        Uri.parse('https://example.com/v1/chat#secret'),
        Uri.parse('http://example.com/v1/chat'),
      ]) {
        await expectLater(
          client.postJson(endpoint: endpoint, body: const {}),
          throwsA(_transportError(UnaryTransportErrorCode.invalidEndpoint)),
        );
      }
      expect(adapter.callCount, 0);
    },
  );

  test(
    'explicit HTTP remains possible only for an explicitly local client',
    () async {
      final adapter = FakeUnaryHttpAdapter()
        ..enqueueJson(
          statusCode: 200,
          body: {'ok': true},
          remoteAddress: InternetAddress('127.0.0.1'),
        );
      final client = SecureJsonHttpClient(
        adapter: adapter,
        endpointPolicy: LocalEndpointPolicy(
          resolver: _FixedResolver([InternetAddress('127.0.0.1')]),
        ),
        allowInsecureHttp: true,
      );

      final response = await client.postJson(
        endpoint: Uri.parse('http://127.0.0.1:11434/v1/chat/completions'),
        body: const {},
      );

      expect(response.body['ok'], isTrue);
    },
  );

  test('insecure HTTP never becomes available to a public endpoint', () async {
    final adapter = FakeUnaryHttpAdapter();
    final client = SecureJsonHttpClient(
      adapter: adapter,
      endpointPolicy: PublicEndpointPolicy(
        resolver: _FixedResolver([InternetAddress('8.8.8.8')]),
      ),
      allowInsecureHttp: true,
    );

    await expectLater(
      client.postJson(
        endpoint: Uri.parse('http://example.com/v1/chat/completions'),
        body: const {},
      ),
      throwsA(_transportError(UnaryTransportErrorCode.invalidEndpoint)),
    );
    expect(adapter.callCount, 0);
  });

  test(
    'public endpoint policy rejects private IPv4 and IPv6 before connect',
    () async {
      for (final address in [
        '0.0.0.1',
        '127.0.0.1',
        '10.0.0.1',
        '100.64.0.1',
        '172.16.1.1',
        '192.168.1.1',
        '169.254.10.1',
        '192.0.0.1',
        '192.0.2.1',
        '192.88.99.1',
        '198.51.100.1',
        '203.0.113.1',
        '240.0.0.1',
        '::1',
        'fe80::1',
        'fc00::1',
        'fec0::1',
        '64:ff9b::192.0.2.1',
        '64:ff9b:1::1',
        '::10.0.0.1',
        '::172.16.0.1',
        '::192.168.1.1',
        '::ffff:0:192.0.2.1',
        '::ffff:127.0.0.1',
        '::ffff:10.0.0.1',
        '2001:db8::1',
        '2002::1',
      ]) {
        final policy = PublicEndpointPolicy(
          resolver: _FixedResolver([InternetAddress(address)]),
        );
        await expectLater(
          policy.validateBeforeConnect(Uri.parse('https://example.com/v1')),
          throwsA(_transportError(UnaryTransportErrorCode.endpointRejected)),
          reason: address,
        );
      }
    },
  );

  test('public endpoint policy allows public addresses', () async {
    final policy = PublicEndpointPolicy(
      resolver: _FixedResolver([
        InternetAddress('8.8.8.8'),
        InternetAddress('2001:4860:4860::8888'),
      ]),
    );

    await policy.validateBeforeConnect(Uri.parse('https://example.com/v1'));
    policy.validateAfterConnect(
      Uri.parse('https://example.com/v1'),
      InternetAddress('8.8.4.4'),
    );
  });

  test(
    'public endpoint policy tolerates fake-IP DNS for named hosts only',
    () async {
      // Behind a fake-IP proxy every name resolves into 198.18/15; a
      // generation result on an arbitrary CDN host must still download.
      for (final fake in ['198.18.0.151', '198.19.255.1']) {
        final policy = PublicEndpointPolicy(
          resolver: _FixedResolver([InternetAddress(fake)]),
        );
        await policy.validateBeforeConnect(
          Uri.parse('https://cdn.example.com/result.png'),
        );
        policy.validateAfterConnect(
          Uri.parse('https://cdn.example.com/result.png'),
          InternetAddress(fake),
        );
        // A literal-IP URL targets the address itself: still blocked.
        await expectLater(
          policy.validateBeforeConnect(Uri.parse('https://$fake/result.png')),
          throwsA(_transportError(UnaryTransportErrorCode.endpointRejected)),
        );
        expect(
          () => policy.validateAfterConnect(
            Uri.parse('https://$fake/result.png'),
            InternetAddress(fake),
          ),
          throwsA(_transportError(UnaryTransportErrorCode.endpointRejected)),
        );
      }
    },
  );

  test(
    'trusted provider policy accepts fake-IP DNS only for allowlisted hosts',
    () async {
      final policy = TrustedProviderEndpointPolicy(
        providerHosts: const {'api.deepseek.com'},
        resolver: _FixedResolver([InternetAddress('198.18.0.101')]),
      );

      await policy.validateBeforeConnect(
        Uri.parse('https://api.deepseek.com/v1/chat/completions'),
      );
      policy.validateAfterConnect(
        Uri.parse('https://api.deepseek.com/v1/chat/completions'),
        InternetAddress('198.18.0.101'),
      );
      await expectLater(
        policy.validateBeforeConnect(
          Uri.parse('https://attacker.example/v1/chat/completions'),
        ),
        throwsA(_transportError(UnaryTransportErrorCode.endpointRejected)),
      );
      expect(
        () => policy.validateAfterConnect(
          Uri.parse('https://attacker.example/v1/chat/completions'),
          InternetAddress('198.18.0.101'),
        ),
        throwsA(_transportError(UnaryTransportErrorCode.endpointRejected)),
      );
    },
  );

  test(
    'IPv4-compatible IPv6 is rejected as a literal and across DNS checks',
    () async {
      final embeddedPrivate = InternetAddress('::10.0.0.1');
      final policy = PublicEndpointPolicy(
        resolver: _FixedResolver([embeddedPrivate]),
      );
      await expectLater(
        policy.validateBeforeConnect(
          Uri.parse('https://[::a00:1]/v1/chat/completions'),
        ),
        throwsA(_transportError(UnaryTransportErrorCode.endpointRejected)),
      );
      expect(
        () => policy.validateAfterConnect(
          Uri.parse('https://example.com/v1/chat/completions'),
          embeddedPrivate,
        ),
        throwsA(_transportError(UnaryTransportErrorCode.endpointRejected)),
      );
    },
  );

  test(
    'local policy is loopback-only and LAN requires explicit policy',
    () async {
      final localPolicy = LocalEndpointPolicy(
        resolver: _FixedResolver([InternetAddress('192.168.1.10')]),
      );
      await expectLater(
        localPolicy.validateBeforeConnect(Uri.parse('http://lan.test/v1')),
        throwsA(_transportError(UnaryTransportErrorCode.endpointRejected)),
      );

      final lanPolicy = LanEndpointPolicy(
        resolver: _FixedResolver([InternetAddress('192.168.1.10')]),
      );
      await lanPolicy.validateBeforeConnect(Uri.parse('http://lan.test/v1'));
      lanPolicy.validateAfterConnect(
        Uri.parse('http://lan.test/v1'),
        InternetAddress('192.168.1.10'),
      );
    },
  );

  test(
    'LAN policy does not accept credential headers without explicit opt-in',
    () async {
      final adapter = FakeUnaryHttpAdapter()
        ..enqueueJson(
          statusCode: 200,
          body: {'ok': true},
          remoteAddress: InternetAddress('192.168.1.10'),
        );
      final client = SecureJsonHttpClient(
        adapter: adapter,
        endpointPolicy: LanEndpointPolicy(
          resolver: _FixedResolver([InternetAddress('192.168.1.10')]),
        ),
        allowInsecureHttp: true,
      );

      await expectLater(
        client.postJson(
          endpoint: Uri.parse('http://192.168.1.10/v1/chat'),
          body: const {},
          headers: const {'authorization': 'Bearer cloud-secret'},
          sensitiveHeaderNames: const {'authorization'},
        ),
        throwsA(_transportError(UnaryTransportErrorCode.invalidCredential)),
      );
      expect(adapter.callCount, 0);
    },
  );

  test(
    'post-connect validation blocks DNS rebinding to a private address',
    () async {
      final adapter = FakeUnaryHttpAdapter()
        ..enqueueJson(
          statusCode: 200,
          body: {'ok': true},
          remoteAddress: InternetAddress('10.0.0.2'),
        );
      final client = SecureJsonHttpClient(
        adapter: adapter,
        endpointPolicy: PublicEndpointPolicy(
          resolver: _FixedResolver([InternetAddress('8.8.8.8')]),
        ),
      );

      await expectLater(
        client.postJson(
          endpoint: Uri.parse('https://example.com/v1/chat'),
          body: const {},
        ),
        throwsA(_transportError(UnaryTransportErrorCode.endpointRejected)),
      );
      expect(adapter.callCount, 1);
    },
  );

  test('response and decompressed gzip bodies are capped at 2 MiB', () async {
    final oversized = List<int>.filled(
      SecureJsonHttpClient.maximumBodyBytes + 1,
      0x61,
    );
    final adapter = FakeUnaryHttpAdapter()
      ..enqueueRaw(statusCode: 200, bytes: oversized)
      ..enqueueRaw(
        statusCode: 200,
        headers: {'content-encoding': 'gzip'},
        bytes: gzip.encode(oversized),
      );
    final client = SecureJsonHttpClient(
      adapter: adapter,
      endpointPolicy: _AllowingEndpointPolicy(),
    );

    for (var index = 0; index < 2; index++) {
      await expectLater(
        client.postJson(
          endpoint: Uri.parse('https://example.com/v1/chat'),
          body: const {},
        ),
        throwsA(_transportError(UnaryTransportErrorCode.bodyTooLarge)),
      );
    }
  });

  test('valid gzip JSON is decoded inside both size boundaries', () async {
    final adapter = FakeUnaryHttpAdapter()
      ..enqueueRaw(
        statusCode: 200,
        headers: {'content-encoding': 'gzip'},
        bytes: gzip.encode(utf8.encode('{"ok":true}')),
      );
    final client = SecureJsonHttpClient(
      adapter: adapter,
      endpointPolicy: _AllowingEndpointPolicy(),
    );

    final response = await client.postJson(
      endpoint: Uri.parse('https://example.com/v1/chat'),
      body: const {},
    );

    expect(response.body, {'ok': true});
  });

  test('JSON root type and excessive depth fail closed', () async {
    final deepJson =
        '${List.filled(65, '{"a":').join()}'
        'null${List.filled(65, '}').join()}';
    final adapter = FakeUnaryHttpAdapter()
      ..enqueueRaw(statusCode: 200, bytes: utf8.encode('["not-a-map"]'))
      ..enqueueRaw(statusCode: 200, bytes: utf8.encode(deepJson));
    final client = SecureJsonHttpClient(
      adapter: adapter,
      endpointPolicy: _AllowingEndpointPolicy(),
    );

    for (var index = 0; index < 2; index++) {
      await expectLater(
        client.postJson(
          endpoint: Uri.parse('https://example.com/v1/chat'),
          body: const {},
        ),
        throwsA(_transportError(UnaryTransportErrorCode.malformedResponse)),
      );
    }
  });

  test('total timeout cancels the in-flight adapter operation', () async {
    final adapter = FakeUnaryHttpAdapter()..enqueuePending();
    final client = SecureJsonHttpClient(
      adapter: adapter,
      endpointPolicy: _AllowingEndpointPolicy(),
      timeouts: const UnaryHttpTimeouts(
        connect: Duration(seconds: 1),
        response: Duration(seconds: 1),
        total: Duration(milliseconds: 20),
      ),
    );

    await expectLater(
      client.postJson(
        endpoint: Uri.parse('https://example.com/v1/chat'),
        body: const {},
      ),
      throwsA(_transportError(UnaryTransportErrorCode.timeout)),
    );
    expect(adapter.cancellationObserved, isTrue);
  });

  test('caller cancellation terminates the in-flight adapter safely', () async {
    final adapter = FakeUnaryHttpAdapter()..enqueuePending();
    final token = CancellationToken();
    final client = SecureJsonHttpClient(
      adapter: adapter,
      endpointPolicy: _AllowingEndpointPolicy(),
    );
    final future = client.postJson(
      endpoint: Uri.parse('https://example.com/v1/chat'),
      body: const {},
      cancellationToken: token,
    );
    await Future<void>.delayed(Duration.zero);

    token.cancel();

    await expectLater(
      future,
      throwsA(_transportError(UnaryTransportErrorCode.cancelled)),
    );
    expect(adapter.cancellationObserved, isTrue);
  });

  test('request JSON over 2 MiB is rejected before adapter dispatch', () async {
    final adapter = FakeUnaryHttpAdapter();
    final client = SecureJsonHttpClient(
      adapter: adapter,
      endpointPolicy: _AllowingEndpointPolicy(),
    );

    await expectLater(
      client.postJson(
        endpoint: Uri.parse('https://example.com/v1/chat'),
        body: {
          'text': List.filled(
            SecureJsonHttpClient.maximumBodyBytes + 1,
            'x',
          ).join(),
        },
      ),
      throwsA(_transportError(UnaryTransportErrorCode.bodyTooLarge)),
    );
    expect(adapter.callCount, 0);
  });

  test('request JSON depth is rejected before adapter dispatch', () async {
    final adapter = FakeUnaryHttpAdapter();
    final client = SecureJsonHttpClient(
      adapter: adapter,
      endpointPolicy: _AllowingEndpointPolicy(),
    );
    Object? value;
    for (var index = 0; index < 65; index++) {
      value = <Object?>[value];
    }

    await expectLater(
      client.postJson(
        endpoint: Uri.parse('https://example.com/v1/chat'),
        body: {'value': value},
      ),
      throwsA(_transportError(UnaryTransportErrorCode.invalidRequest)),
    );
    expect(adapter.callCount, 0);
  });

  test(
    'request headers reject CRLF names and values before dispatch',
    () async {
      final adapter = FakeUnaryHttpAdapter();
      final client = SecureJsonHttpClient(
        adapter: adapter,
        endpointPolicy: _AllowingEndpointPolicy(),
      );

      for (final headers in [
        {'X-Test\r\nInjected': 'value'},
        {'X-Test': 'value\r\nInjected: yes'},
      ]) {
        await expectLater(
          client.postJson(
            endpoint: Uri.parse('https://example.com/v1/chat'),
            body: const {},
            headers: headers,
          ),
          throwsA(_transportError(UnaryTransportErrorCode.invalidRequest)),
        );
      }
      expect(adapter.callCount, 0);
    },
  );

  test(
    'lowest HTTP layer rejects reserved connection and forwarding headers',
    () async {
      for (final name in [
        'Host',
        'Content-Length',
        'Transfer-Encoding',
        'Connection',
        'TE',
        'Upgrade',
        'Proxy-Authorization',
        'Proxy-Foo',
        'Forwarded',
        'X-Forwarded-For',
        'X-HTTP-Method-Override',
      ]) {
        final adapter = FakeUnaryHttpAdapter();
        final client = SecureJsonHttpClient(
          adapter: adapter,
          endpointPolicy: _AllowingEndpointPolicy(),
        );
        await expectLater(
          client.postJson(
            endpoint: Uri.parse('https://example.com/v1/chat'),
            body: const {},
            headers: {name: 'unsafe'},
          ),
          throwsA(_transportError(UnaryTransportErrorCode.invalidRequest)),
          reason: name,
        );
        expect(adapter.callCount, 0, reason: name);
      }
    },
  );

  test('adapter requests accept only canonical GET and POST methods', () {
    for (final method in [
      '',
      ' ',
      'PATCH',
      'get',
      'post',
      ' GET',
      'GET ',
      ' POST',
      'POST ',
      'GET\r\nInjected',
      'POST\r\nInjected',
      'GET\tInjected',
      'POST\tInjected',
    ]) {
      expect(
        () => _adapterRequest(method),
        throwsA(isA<ArgumentError>()),
        reason: method,
      );
    }

    for (final method in ['GET', 'POST']) {
      final request = _adapterRequest(method);
      expect(request.method, method);
      expect(request.toString(), contains('method: $method'));
    }
  });

  test('safe fake records accept only canonical GET and POST methods', () {
    for (final method in [
      '',
      'get',
      'post',
      ' GET',
      'GET ',
      'GET\r\nInjected',
      'POST\r\nInjected',
      'GET Injected',
      'POST Injected',
    ]) {
      expect(
        () => _safeRecord(method),
        throwsA(isA<ArgumentError>()),
        reason: method,
      );
    }

    for (final method in ['GET', 'POST']) {
      final record = _safeRecord(method);
      expect(record.method, method);
      expect(record.toString(), contains('method: $method'));
    }
  });

  test(
    'GET sends no body or content type and safe fake redacts credentials',
    () async {
      const credential = 'catalog-secret-that-must-not-be-retained';
      final adapter =
          FakeUnaryHttpAdapter(
            retainSafeHeaderValuesForTesting: true,
            retainRequestContentForTesting: true,
          )..enqueueJson(
            statusCode: 302,
            body: const {},
            headers: const {'location': 'https://attacker.example/collect'},
          );
      final client = SecureJsonHttpClient(
        adapter: adapter,
        endpointPolicy: _AllowingEndpointPolicy(),
      );

      final response = await client.getJson(
        endpoint: Uri.parse('https://example.com/v1/models'),
        headers: const {
          'accept': 'application/json',
          'authorization': 'Bearer $credential',
        },
        sensitiveHeaderNames: const {'authorization'},
        cancellationToken: CancellationToken(),
      );

      expect(response.statusCode, 302);
      final record = adapter.records.single;
      expect(record.method, 'GET');
      expect(record.path, '/v1/models');
      expect(record.hasBody, isFalse);
      expect(record.bodyByteLength, 0);
      expect(record.body, isEmpty);
      expect(record.contentType, isNull);
      expect(record.accept, 'application/json');
      expect(record.followRedirects, isFalse);
      expect(record.authorizationWasBearer, isTrue);
      expect(record.hadCredential, isTrue);
      expect(record.safeHeaders, isNot(containsValue(credential)));
      expect(record.safeHeaders, isNot(contains('authorization')));
      expect(record.toString(), isNot(contains(credential)));
    },
  );

  test('GET cancellation aborts the shared fake request', () async {
    final adapter = FakeUnaryHttpAdapter()..enqueuePending();
    final token = CancellationToken();
    final client = SecureJsonHttpClient(
      adapter: adapter,
      endpointPolicy: _AllowingEndpointPolicy(),
    );
    final future = client.getJson(
      endpoint: Uri.parse('https://example.com/v1/models'),
      headers: const {},
      sensitiveHeaderNames: const {},
      cancellationToken: token,
    );
    await Future<void>.delayed(Duration.zero);

    token.cancel();

    await expectLater(
      future,
      throwsA(_transportError(UnaryTransportErrorCode.cancelled)),
    );
    expect(adapter.cancellationObserved, isTrue);
  });

  test('GET runs endpoint policy before and after adapter dispatch', () async {
    final adapter = FakeUnaryHttpAdapter()
      ..enqueueJson(statusCode: 200, body: {'data': <Object?>[]});
    final policy = _TrackingEndpointPolicy();
    final client = SecureJsonHttpClient(
      adapter: adapter,
      endpointPolicy: policy,
    );
    final endpoint = Uri.parse('https://models.example/v1/models');

    await client.getJson(
      endpoint: endpoint,
      headers: const {},
      sensitiveHeaderNames: const {},
      cancellationToken: CancellationToken(),
    );

    expect(policy.beforeEndpoints, [endpoint]);
    expect(policy.afterEndpoints, [endpoint]);
    expect(policy.remoteAddresses.single.address, '8.8.8.8');
  });

  test('safe fake retains no header values by default', () async {
    final adapter = FakeUnaryHttpAdapter()
      ..enqueueJson(statusCode: 200, body: {'ok': true});
    final client = SecureJsonHttpClient(
      adapter: adapter,
      endpointPolicy: _AllowingEndpointPolicy(),
    );
    await client.postJson(
      endpoint: Uri.parse('https://example.com/v1/chat'),
      body: const {},
      headers: const {
        'content-type': 'application/json',
        'x-test-metadata': 'must-not-be-retained',
      },
    );

    final record = adapter.records.single;
    expect(record.safeHeaders, isEmpty);
    expect(record.contentType, isNull);
    expect(record.path, '/***/');
    expect(record.hasPath, isTrue);
    expect(record.pathSegmentCount, 2);
    expect(record.body, isEmpty);
    expect(record.hasBody, isTrue);
    expect(record.toString(), isNot(contains('x-test-metadata')));
    expect(record.toString(), isNot(contains('/v1/chat')));
  });

  test(
    'long-lived cancellation tokens do not retain completed requests',
    () async {
      final token = CancellationToken();
      final adapter = FakeUnaryHttpAdapter();
      final client = SecureJsonHttpClient(
        adapter: adapter,
        endpointPolicy: _AllowingEndpointPolicy(),
      );
      for (var index = 0; index < 25; index++) {
        adapter.enqueueJson(statusCode: 200, body: {'ok': true});
        await client.postJson(
          endpoint: Uri.parse('https://example.com/v1/chat'),
          body: {'request': index},
          cancellationToken: token,
        );
        expect(token.activeListenerCount, 0, reason: 'request $index');
      }
    },
  );

  test(
    'safe fake supports explicit request-content retention and disposal',
    () async {
      final adapter = FakeUnaryHttpAdapter(retainRequestContentForTesting: true)
        ..enqueueJson(statusCode: 200, body: {'ok': true});
      final client = SecureJsonHttpClient(
        adapter: adapter,
        endpointPolicy: _AllowingEndpointPolicy(),
      );
      await client.postJson(
        endpoint: Uri.parse('https://example.com/v1/chat'),
        body: const {'prompt': 'fixture-only'},
      );
      expect(adapter.records.single.path, '/v1/chat');
      expect(adapter.records.single.body['prompt'], 'fixture-only');

      adapter.clear();
      expect(adapter.records, isEmpty);
      adapter.dispose();
      expect(() => adapter.enqueuePending(), throwsA(isA<StateError>()));
    },
  );
}

UnaryHttpAdapterRequest _adapterRequest(String method) =>
    UnaryHttpAdapterRequest(
      method: method,
      endpoint: Uri.parse('https://example.com/v1/chat'),
      headers: const {'content-type': 'application/json'},
      sensitiveHeaderNames: const {},
      bodyBytes: Uint8List.fromList(utf8.encode('{}')),
      timeouts: const UnaryHttpTimeouts(),
      cancellationToken: CancellationToken(),
    );

SafeUnaryHttpRecord _safeRecord(String method) => SafeUnaryHttpRecord(
  method: method,
  path: '/***/',
  hasPath: true,
  pathSegmentCount: 2,
  contentType: null,
  accept: null,
  followRedirects: false,
  authorizationWasBearer: false,
  hadApiKey: false,
  hadGoogleApiKey: false,
  hadCredential: false,
  hasBody: true,
  bodyByteLength: 2,
  safeHeaders: const {},
  body: const {},
);

Matcher _transportError(UnaryTransportErrorCode code) =>
    isA<UnaryTransportException>()
        .having((error) => error.code, 'code', code)
        .having(
          (error) => error.toString(),
          'safe output',
          allOf(
            isNot(contains('Authorization')),
            isNot(contains('sk-')),
            isNot(contains('upstream')),
          ),
        );

class _FixedResolver implements HostResolver {
  _FixedResolver(this.addresses);

  final List<InternetAddress> addresses;

  @override
  Future<List<InternetAddress>> lookup(String host) async => addresses;
}

class _AllowingEndpointPolicy implements EndpointPolicy {
  @override
  Future<void> validateBeforeConnect(Uri endpoint) async {}

  @override
  void validateAfterConnect(Uri endpoint, InternetAddress remoteAddress) {}
}

class _TrackingEndpointPolicy implements EndpointPolicy {
  final List<Uri> beforeEndpoints = [];
  final List<Uri> afterEndpoints = [];
  final List<InternetAddress> remoteAddresses = [];

  @override
  Future<void> validateBeforeConnect(Uri endpoint) async {
    beforeEndpoints.add(endpoint);
  }

  @override
  void validateAfterConnect(Uri endpoint, InternetAddress remoteAddress) {
    afterEndpoints.add(endpoint);
    remoteAddresses.add(remoteAddress);
  }
}
