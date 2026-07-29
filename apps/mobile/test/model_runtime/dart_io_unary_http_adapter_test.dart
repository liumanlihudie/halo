import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';

import 'testing/tls_test_credentials.dart';

void main() {
  test(
    'Dart IO adapter enforces connection timeout and closes client',
    () async {
      final client = _FakeHttpClient(openNeverCompletes: true);
      final adapter = DartIoUnaryHttpAdapter(clientFactory: () => client);

      await expectLater(
        adapter.send(_request(connect: const Duration(milliseconds: 10))),
        throwsA(_transportError(UnaryTransportErrorCode.timeout)),
      );
      expect(client.closed, isTrue);
    },
  );

  test(
    'Dart IO adapter enforces response timeout and aborts request',
    () async {
      final request = _FakeHttpClientRequest();
      final client = _FakeHttpClient(request: request);
      final adapter = DartIoUnaryHttpAdapter(clientFactory: () => client);

      await expectLater(
        adapter.send(_request(response: const Duration(milliseconds: 10))),
        throwsA(_transportError(UnaryTransportErrorCode.timeout)),
      );
      expect(request.aborted, isTrue);
      expect(client.closed, isTrue);
    },
  );

  test('Dart IO adapter aborts an in-flight request on cancellation', () async {
    final request = _FakeHttpClientRequest();
    final client = _FakeHttpClient(request: request);
    final adapter = DartIoUnaryHttpAdapter(clientFactory: () => client);
    final token = CancellationToken();
    final future = adapter.send(_request(cancellationToken: token));
    await Future<void>.delayed(Duration.zero);

    token.cancel();

    await expectLater(
      future,
      throwsA(_transportError(UnaryTransportErrorCode.cancelled)),
    );
    expect(request.aborted, isTrue);
    expect(client.closed, isTrue);
  });

  test(
    'Dart IO adapter itself rejects reserved headers before opening a socket',
    () async {
      final client = _FakeHttpClient();
      final adapter = DartIoUnaryHttpAdapter(clientFactory: () => client);

      await expectLater(
        adapter.send(_request(headers: const {'Host': 'attacker.test'})),
        throwsA(_transportError(UnaryTransportErrorCode.invalidRequest)),
      );
      expect(client.opened, isFalse);
    },
  );

  test(
    'second DNS answer fails closed when public and private IPs are mixed',
    () async {
      final adapter = DartIoUnaryHttpAdapter(
        resolver: _FixedResolver([
          InternetAddress('10.0.0.1'),
          InternetAddress('8.8.8.8'),
        ]),
      );

      await expectLater(
        adapter.send(
          _request(
            connect: const Duration(milliseconds: 20),
            endpointPolicy: PublicEndpointPolicy(
              resolver: _FixedResolver([InternetAddress('8.8.8.8')]),
            ),
          ),
        ),
        throwsA(_transportError(UnaryTransportErrorCode.endpointRejected)),
      );
    },
  );

  test(
    'Dart IO adapter sends a pinned local HTTP request end to end',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = Completer<void>();
      server.listen((request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/v1/chat/completions');
        expect(request.headers.value('authorization'), 'Bearer test-only');
        expect(await utf8.decoder.bind(request).join(), '{"model":"demo"}');
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write('{"ok":true}');
        await request.response.close();
        received.complete();
      });
      final endpoint = Uri.parse(
        'http://127.0.0.1:${server.port}/v1/chat/completions',
      );
      final response = await DartIoUnaryHttpAdapter().send(
        _request(
          endpoint: endpoint,
          endpointPolicy: const LocalEndpointPolicy(),
          headers: const {
            'content-type': 'application/json',
            'authorization': 'Bearer test-only',
          },
          bodyBytes: utf8.encode('{"model":"demo"}'),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(await utf8.decoder.bind(response.body).join(), '{"ok":true}');
      await response.close();
      await received.future;
    },
  );

  test('Dart IO adapter never follows redirects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var redirectedRequests = 0;
    server.listen((request) async {
      if (request.uri.path == '/target') redirectedRequests++;
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, '/target');
      await request.response.close();
    });
    final response = await DartIoUnaryHttpAdapter().send(
      _request(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/start'),
        endpointPolicy: const LocalEndpointPolicy(),
      ),
    );

    expect(response.statusCode, HttpStatus.found);
    expect(redirectedRequests, 0);
    await response.close();
  });

  test(
    'HTTPS pins the IP then completes a trusted TLS handshake with SNI',
    () async {
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        testServerContext(),
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer test-only');
        request.response
          ..statusCode = HttpStatus.ok
          ..write('{"ok":true}');
        await request.response.close();
      });
      String? tlsHost;
      final response =
          await DartIoUnaryHttpAdapter(
            resolver: _FixedResolver([InternetAddress.loopbackIPv4]),
            securityContext: trustedClientContext(),
            secureSocketConnector: (socket, host, context) {
              tlsHost = host;
              return SecureSocket.secure(socket, host: host, context: context);
            },
          ).send(
            _request(
              endpoint: Uri.parse('https://localhost:${server.port}/v1/chat'),
              endpointPolicy: LocalEndpointPolicy(
                resolver: _FixedResolver([InternetAddress.loopbackIPv4]),
              ),
              headers: const {
                'content-type': 'application/json',
                'authorization': 'Bearer test-only',
              },
            ),
          );

      expect(response.statusCode, HttpStatus.ok);
      expect(tlsHost, 'localhost');
      await response.close();
    },
  );

  test('HTTPS rejects an untrusted certificate', () async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      testServerContext(),
    );
    addTearDown(() => server.close(force: true));
    server.listen((request) => request.response.close());
    final adapter = DartIoUnaryHttpAdapter(
      resolver: _FixedResolver([InternetAddress.loopbackIPv4]),
    );

    await expectLater(
      adapter.send(
        _request(
          endpoint: Uri.parse('https://localhost:${server.port}/v1/chat'),
          endpointPolicy: LocalEndpointPolicy(
            resolver: _FixedResolver([InternetAddress.loopbackIPv4]),
          ),
        ),
      ),
      throwsA(_transportError(UnaryTransportErrorCode.networkFailure)),
    );
  });

  test('HTTPS rejects a trusted certificate for the wrong hostname', () async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      testServerContext(),
    );
    addTearDown(() => server.close(force: true));
    server.listen((request) => request.response.close());
    final adapter = DartIoUnaryHttpAdapter(
      resolver: _FixedResolver([InternetAddress.loopbackIPv4]),
      securityContext: trustedClientContext(),
    );

    await expectLater(
      adapter.send(
        _request(
          endpoint: Uri.parse('https://wrong.test:${server.port}/v1/chat'),
          endpointPolicy: LocalEndpointPolicy(
            resolver: _FixedResolver([InternetAddress.loopbackIPv4]),
          ),
        ),
      ),
      throwsA(_transportError(UnaryTransportErrorCode.networkFailure)),
    );
  });

  test('TLS handshake obeys connect timeout', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) {});
    final stopwatch = Stopwatch()..start();

    await expectLater(
      DartIoUnaryHttpAdapter(
        resolver: _FixedResolver([InternetAddress.loopbackIPv4]),
        securityContext: trustedClientContext(),
      ).send(
        _request(
          endpoint: Uri.parse('https://localhost:${server.port}/v1/chat'),
          endpointPolicy: LocalEndpointPolicy(
            resolver: _FixedResolver([InternetAddress.loopbackIPv4]),
          ),
          connect: const Duration(milliseconds: 30),
          response: const Duration(seconds: 2),
        ),
      ),
      throwsA(_transportError(UnaryTransportErrorCode.timeout)),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
  });

  test('cancellation destroys a socket stalled in TLS handshake', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final captured = BytesBuilder(copy: false);
    server.listen((socket) => socket.listen(captured.add));
    final token = CancellationToken();
    final future =
        DartIoUnaryHttpAdapter(
          resolver: _FixedResolver([InternetAddress.loopbackIPv4]),
          securityContext: trustedClientContext(),
        ).send(
          _request(
            endpoint: Uri.parse('https://localhost:${server.port}/v1/chat'),
            endpointPolicy: LocalEndpointPolicy(
              resolver: _FixedResolver([InternetAddress.loopbackIPv4]),
            ),
            cancellationToken: token,
            headers: const {
              'content-type': 'application/json',
              'authorization': 'Bearer test-only',
            },
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    token.cancel();

    await expectLater(
      future,
      throwsA(_transportError(UnaryTransportErrorCode.cancelled)),
    );
    expect(
      utf8.decode(captured.takeBytes(), allowMalformed: true),
      isNot(contains('Bearer test-only')),
    );
  });
}

UnaryHttpAdapterRequest _request({
  Duration connect = const Duration(seconds: 1),
  Duration response = const Duration(seconds: 1),
  CancellationToken? cancellationToken,
  Uri? endpoint,
  EndpointPolicy endpointPolicy = const PublicEndpointPolicy(),
  Map<String, String> headers = const {'content-type': 'application/json'},
  List<int> bodyBytes = const [123, 125],
}) => UnaryHttpAdapterRequest(
  method: 'POST',
  endpoint: endpoint ?? Uri.parse('https://example.com/v1/chat/completions'),
  headers: headers,
  sensitiveHeaderNames: headers.containsKey('authorization')
      ? const {'authorization'}
      : const {},
  bodyBytes: Uint8List.fromList(bodyBytes),
  timeouts: UnaryHttpTimeouts(
    connect: connect,
    response: response,
    total: const Duration(seconds: 2),
  ),
  cancellationToken: cancellationToken ?? CancellationToken(),
  endpointPolicy: endpointPolicy,
);

Matcher _transportError(UnaryTransportErrorCode code) =>
    isA<UnaryTransportException>().having((error) => error.code, 'code', code);

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient({
    this.openNeverCompletes = false,
    _FakeHttpClientRequest? request,
  }) : request = request ?? _FakeHttpClientRequest();

  final bool openNeverCompletes;
  final _FakeHttpClientRequest request;
  bool closed = false;
  bool opened = false;

  @override
  bool autoUncompress = true;

  @override
  Duration? connectionTimeout;

  @override
  String Function(Uri url)? findProxy;

  @override
  Future<ConnectionTask<Socket>> Function(
    Uri url,
    String? proxyHost,
    int? proxyPort,
  )?
  connectionFactory;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    if (openNeverCompletes) return Completer<HttpClientRequest>().future;
    opened = true;
    return Future.value(request);
  }

  @override
  void close({bool force = false}) {
    closed = true;
    if (force && opened) request.abort();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixedResolver implements HostResolver {
  const _FixedResolver(this.addresses);

  final List<InternetAddress> addresses;

  @override
  Future<List<InternetAddress>> lookup(String host) async => addresses;
}

class _FakeHttpClientRequest implements HttpClientRequest {
  final Completer<HttpClientResponse> _response = Completer();
  final _FakeHttpHeaders _headers = _FakeHttpHeaders();
  bool aborted = false;

  @override
  bool followRedirects = true;

  @override
  bool persistentConnection = true;

  @override
  HttpHeaders get headers => _headers;

  @override
  void add(List<int> data) {}

  @override
  Future<HttpClientResponse> close() => _response.future;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
    if (!_response.isCompleted) {
      _response.completeError(
        const SocketException('aborted'),
        stackTrace ?? StackTrace.current,
      );
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, Object> values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
