import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/production_sse_transport.dart';
import 'package:halo_mobile/model_runtime/structured_sse_frame.dart';
import 'package:halo_mobile/model_runtime/unary_http_transport.dart';

import 'testing/tls_test_credentials.dart';

// Test route: a real TLS `HttpServer` on 127.0.0.1 addressed as
// `https://localhost:<port>`. `TrustedProviderEndpointPolicy` rejects loopback
// answers from a real resolver, so the policy object itself is constructed for
// the test with an injected resolver returning a benchmark fake IP (198.18.x)
// for the allow-listed host `localhost` — its production matching logic then
// accepts the endpoint without weakening any transport check. The injectable
// `httpClientFactory` supplies an `HttpClient` trusting the test certificate.
void main() {
  Future<_SseServer> startServer(
    FutureOr<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      testServerContext(),
    );
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      await handler(request);
    });
    return _SseServer(server);
  }

  ProductionSseFrameTransport transportFor(
    _SseServer server, {
    CancellationToken? cancellationToken,
    Uri? endpoint,
  }) => ProductionSseFrameTransport(
    endpoint: endpoint ?? server.endpoint,
    jsonBody: const {'model': 'demo', 'stream': true},
    headers: const {'authorization': 'Bearer test-only'},
    sensitiveHeaderNames: const {'authorization'},
    endpointPolicy: _testPolicy(),
    cancellationToken: cancellationToken,
    httpClientFactory: () => HttpClient(context: trustedClientContext()),
  );

  test('happy path streams data events, comments, then done', () async {
    final server = await startServer((request) async {
      final response = _sseResponse(request);
      response.write(': ping comment\n');
      response.write('event: message\n');
      response.write('id: 7\n');
      response.write('retry: 1000\n');
      response.write('data: {"index":1}\n\n');
      response.write(': another comment\n\n');
      response.write('data: {"index":2,"text":"hi"}\n\n');
      response.write('data: [DONE]\n\n');
      await response.close();
    });

    final frames = await transportFor(server).openFrameStream().toList();

    expect(frames, hasLength(3));
    expect(frames[0].kind, StructuredSseFrameKind.data);
    expect(frames[0].data, {'index': 1});
    expect(frames[1].kind, StructuredSseFrameKind.data);
    expect(frames[1].data, {'index': 2, 'text': 'hi'});
    expect(frames[2].kind, StructuredSseFrameKind.done);
  });

  test('multi-line data fields are joined with newlines', () async {
    final server = await startServer((request) async {
      final response = _sseResponse(request);
      response.write('data: {"text":\n');
      response.write('data: "multi"}\n\n');
      response.write('data: [DONE]\n\n');
      await response.close();
    });

    final frames = await transportFor(server).openFrameStream().toList();

    expect(frames, hasLength(2));
    expect(frames[0].kind, StructuredSseFrameKind.data);
    expect(frames[0].data, {'text': 'multi'});
    expect(frames[1].kind, StructuredSseFrameKind.done);
  });

  test('CRLF line endings parse identically to LF', () async {
    final server = await startServer((request) async {
      final response = _sseResponse(request);
      response.write('data: {"crlf":true}\r\n\r\n');
      response.write('data: [DONE]\r\n\r\n');
      await response.close();
    });

    final frames = await transportFor(server).openFrameStream().toList();

    expect(frames, hasLength(2));
    expect(frames[0].data, {'crlf': true});
    expect(frames[1].kind, StructuredSseFrameKind.done);
  });

  test('non-2xx status yields one error frame without body content', () async {
    final server = await startServer((request) async {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('{"secret":"do-not-leak-this"}');
      await request.response.close();
    });

    final frames = await transportFor(server).openFrameStream().toList();

    expect(frames, hasLength(1));
    final frame = frames.single;
    expect(frame.kind, StructuredSseFrameKind.error);
    expect(frame.statusCode, HttpStatus.internalServerError);
    expect(frame.hasUnsafeBody, isTrue);
    expect(frame.data, isNull);
    expect(frame.toString(), isNot(contains('secret')));
    expect(frame.toString(), isNot(contains('do-not-leak-this')));
  });

  test('non-2xx status without a body reports hasUnsafeBody false', () async {
    final server = await startServer((request) async {
      request.response
        ..statusCode = HttpStatus.tooManyRequests
        ..contentLength = 0;
      await request.response.close();
    });

    final frames = await transportFor(server).openFrameStream().toList();

    expect(frames, hasLength(1));
    expect(frames.single.kind, StructuredSseFrameKind.error);
    expect(frames.single.statusCode, HttpStatus.tooManyRequests);
    expect(frames.single.hasUnsafeBody, isFalse);
  });

  test('malformed JSON event fails closed with an error frame', () async {
    final server = await startServer((request) async {
      final response = _sseResponse(request);
      response.write('data: {"good":1}\n\n');
      response.write('data: {not-valid-json}\n\n');
      response.write('data: {"never":"reached"}\n\n');
      await response.close();
    });

    final frames = await transportFor(server).openFrameStream().toList();

    expect(frames, hasLength(2));
    expect(frames[0].kind, StructuredSseFrameKind.data);
    expect(frames[1].kind, StructuredSseFrameKind.error);
    expect(frames[1].statusCode, isNull);
  });

  test('non-object JSON payload fails closed', () async {
    final server = await startServer((request) async {
      final response = _sseResponse(request);
      response.write('data: [1,2,3]\n\n');
      await response.close();
    });

    final frames = await transportFor(server).openFrameStream().toList();

    expect(frames, hasLength(1));
    expect(frames.single.kind, StructuredSseFrameKind.error);
  });

  test('connection ending without [DONE] emits an error frame', () async {
    final server = await startServer((request) async {
      final response = _sseResponse(request);
      response.write('data: {"partial":true}\n\n');
      await response.close();
    });

    final frames = await transportFor(server).openFrameStream().toList();

    expect(frames, hasLength(2));
    expect(frames[0].kind, StructuredSseFrameKind.data);
    expect(frames[0].data, {'partial': true});
    expect(frames[1].kind, StructuredSseFrameKind.error);
    expect(frames[1].statusCode, isNull);
  });

  test('cancellation mid-stream closes promptly without more frames', () async {
    final connectionHeld = Completer<void>();
    final server = await startServer((request) async {
      final response = _sseResponse(request);
      response.write('data: {"first":1}\n\n');
      await response.flush();
      // Hold the connection open; teardown closes it.
      await connectionHeld.future;
    });
    addTearDown(() {
      if (!connectionHeld.isCompleted) connectionHeld.complete();
    });
    final token = CancellationToken();
    final frames = <StructuredSseFrame>[];
    final closed = Completer<void>();
    final firstFrame = Completer<void>();
    transportFor(server, cancellationToken: token).openFrameStream().listen((
      frame,
    ) {
      frames.add(frame);
      if (!firstFrame.isCompleted) firstFrame.complete();
    }, onDone: closed.complete);

    await firstFrame.future.timeout(const Duration(seconds: 10));
    token.cancel();

    await closed.future.timeout(const Duration(seconds: 5));
    expect(frames, hasLength(1));
    expect(frames.single.kind, StructuredSseFrameKind.data);
  });

  test('single event exceeding the data size cap fails closed', () async {
    final oversized =
        'x' * (ProductionSseFrameTransport.maximumEventDataBytes + 64);
    final server = await startServer((request) async {
      final response = _sseResponse(request);
      response.write('data: {"ok":true}\n\n');
      response.write('data: $oversized\n\n');
      await response.close();
    });

    final frames = await transportFor(server).openFrameStream().toList();

    expect(frames, hasLength(2));
    expect(frames[0].kind, StructuredSseFrameKind.data);
    expect(frames[1].kind, StructuredSseFrameKind.error);
  });

  test('event count above the cap fails closed after the limit', () async {
    const cap = ProductionSseFrameTransport.maximumEventCount;
    final server = await startServer((request) async {
      final response = _sseResponse(request);
      final buffer = StringBuffer();
      for (var index = 0; index <= cap; index++) {
        buffer.write('data: {"n":$index}\n\n');
      }
      response.write(buffer.toString());
      await response.close();
    });

    final frames = await transportFor(server).openFrameStream().toList();

    expect(frames, hasLength(cap + 1));
    for (var index = 0; index < cap; index++) {
      expect(frames[index].kind, StructuredSseFrameKind.data);
    }
    expect(frames.last.kind, StructuredSseFrameKind.error);
  });

  test('endpoint with a query string is rejected before connecting', () async {
    final server = await startServer((request) async {
      fail('The transport must not connect for an invalid endpoint');
    });

    final frames = await transportFor(
      server,
      endpoint: server.endpoint.replace(query: 'debug=1'),
    ).openFrameStream().toList();

    expect(frames, hasLength(1));
    expect(frames.single.kind, StructuredSseFrameKind.error);
    expect(frames.single.statusCode, isNull);
  });
}

class _SseServer {
  _SseServer(this.server);

  final HttpServer server;

  Uri get endpoint => Uri.parse('https://localhost:${server.port}/v1/stream');
}

HttpResponse _sseResponse(HttpRequest request) {
  final response = request.response;
  response.bufferOutput = false;
  response.headers.set(HttpHeaders.contentTypeHeader, 'text/event-stream');
  return response;
}

TrustedProviderEndpointPolicy _testPolicy() => TrustedProviderEndpointPolicy(
  providerHosts: const {'localhost'},
  resolver: const _FixedResolver(),
);

class _FixedResolver implements HostResolver {
  const _FixedResolver();

  @override
  Future<List<InternetAddress>> lookup(String host) async => [
    InternetAddress('198.18.0.1'),
  ];
}
