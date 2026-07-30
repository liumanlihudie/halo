import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/structured_sse_frame.dart';
import 'package:halo_mobile/model_runtime/unary_http_transport.dart';

/// Production SSE transport for provider streaming endpoints.
///
/// Mirrors the unary transport security posture: https-only endpoints with no
/// query, fragment, or user info; the host must satisfy the injected
/// [TrustedProviderEndpointPolicy]; redirects are never followed; and no header
/// values, request/response bodies, or exception details ever leak into
/// emitted frames or error text.
final class ProductionSseFrameTransport implements StructuredSseFrameTransport {
  ProductionSseFrameTransport({
    required this._endpoint,
    required Map<String, Object?> jsonBody,
    required Map<String, String> headers,
    required Set<String> sensitiveHeaderNames,
    required this._endpointPolicy,
    CancellationToken? cancellationToken,
    HttpClient Function()? httpClientFactory,
  }) : _jsonBody = Map.unmodifiable(jsonBody),
       _headers = Map.unmodifiable(headers),
       _sensitiveHeaderNames = Set.unmodifiable(
         sensitiveHeaderNames.map((name) => name.toLowerCase()),
       ),
       _cancellationToken = cancellationToken ?? CancellationToken(),
       _httpClientFactory = httpClientFactory ?? HttpClient.new;

  /// Maximum accumulated `data:` payload size for a single SSE event.
  static const maximumEventDataBytes = 262144;

  /// Maximum total bytes read from the streaming response body.
  static const maximumResponseBytes = 8 * 1024 * 1024;

  /// Maximum number of dispatched SSE events per stream.
  static const maximumEventCount = 10000;

  /// Maximum time allowed between consecutive response chunks.
  static const idleTimeout = Duration(seconds: 45);

  /// Maximum lifetime of the whole streaming request.
  static const overallTimeout = Duration(minutes: 10);

  /// Connection establishment timeout.
  static const connectTimeout = Duration(seconds: 10);

  /// Bounded drain limit used only to detect that a non-2xx body existed.
  static const maximumErrorBodyProbeBytes = 256 * 1024;

  final Uri _endpoint;
  final Map<String, Object?> _jsonBody;
  final Map<String, String> _headers;
  final Set<String> _sensitiveHeaderNames;
  final TrustedProviderEndpointPolicy _endpointPolicy;
  final CancellationToken _cancellationToken;
  final HttpClient Function() _httpClientFactory;

  @override
  Stream<StructuredSseFrame> openFrameStream() => _SseStreamSession(
    endpoint: _endpoint,
    jsonBody: _jsonBody,
    headers: _headers,
    endpointPolicy: _endpointPolicy,
    cancellationToken: _cancellationToken,
    httpClientFactory: _httpClientFactory,
  ).stream;

  @override
  String toString() =>
      'ProductionSseFrameTransport(origin: ${_endpoint.origin}, '
      'path: /***/, sensitiveHeaderCount: ${_sensitiveHeaderNames.length})';
}

final class _SseStreamSession {
  _SseStreamSession({
    required this.endpoint,
    required this.jsonBody,
    required this.headers,
    required this.endpointPolicy,
    required this.cancellationToken,
    required this.httpClientFactory,
  }) {
    _controller = StreamController<StructuredSseFrame>(
      onListen: () => unawaited(_start()),
      onCancel: () => _finish(abort: true),
    );
  }

  final Uri endpoint;
  final Map<String, Object?> jsonBody;
  final Map<String, String> headers;
  final TrustedProviderEndpointPolicy endpointPolicy;
  final CancellationToken cancellationToken;
  final HttpClient Function() httpClientFactory;

  late final StreamController<StructuredSseFrame> _controller;
  HttpClient? _client;
  HttpClientRequest? _request;
  StreamSubscription<List<int>>? _bodySubscription;
  CancellationSubscription? _cancellationSubscription;
  Timer? _idleTimer;
  Timer? _overallTimer;

  final List<int> _lineBuffer = [];
  final List<String> _dataLines = [];
  var _eventDataBytes = 0;
  var _totalResponseBytes = 0;
  var _eventCount = 0;
  var _finished = false;
  var _cancelled = false;

  Stream<StructuredSseFrame> get stream => _controller.stream;

  Future<void> _start() async {
    _cancellationSubscription = cancellationToken.addListener(_onCancelled);
    if (_finished) return;
    if (cancellationToken.isCancelled) {
      _cancelled = true;
      _finish(abort: true);
      return;
    }
    _overallTimer = Timer(
      ProductionSseFrameTransport.overallTimeout,
      _failClosed,
    );
    _resetIdleTimer();
    List<int> bodyBytes;
    try {
      _validateEndpoint(endpoint);
      _validateRequestHeaders(headers);
      await endpointPolicy.validateBeforeConnect(endpoint);
      bodyBytes = utf8.encode(jsonEncode(jsonBody));
    } catch (_) {
      // Fail closed without surfacing any validation or policy details.
      _failClosed();
      return;
    }
    if (_finished) return;
    try {
      final client = httpClientFactory();
      _client = client;
      client
        ..autoUncompress = false
        ..connectionTimeout = ProductionSseFrameTransport.connectTimeout;
      client.findProxy = (_) => 'DIRECT';
      final request = await client.openUrl('POST', endpoint);
      _request = request;
      if (_finished) {
        request.abort();
        return;
      }
      request
        ..followRedirects = false
        ..persistentConnection = false;
      request.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.acceptHeader, 'text/event-stream');
      headers.forEach(request.headers.set);
      request.add(bodyBytes);
      final response = await request.close();
      if (_finished) return;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _handleNonSuccessStatus(response);
        return;
      }
      _bodySubscription = response.listen(
        _onChunk,
        onError: (Object _, StackTrace _) => _onBodyEnded(),
        onDone: _onBodyEnded,
        cancelOnError: true,
      );
    } catch (_) {
      // Connection or protocol failure: no exception details may escape.
      if (_cancelled) {
        _finish(abort: true);
      } else {
        _failClosed();
      }
    }
  }

  Future<void> _handleNonSuccessStatus(HttpClientResponse response) async {
    final statusCode = response.statusCode;
    var bodyExisted = response.contentLength > 0;
    var drainedBytes = 0;
    try {
      await for (final chunk in response) {
        if (chunk.isNotEmpty) bodyExisted = true;
        drainedBytes += chunk.length;
        if (drainedBytes >=
            ProductionSseFrameTransport.maximumErrorBodyProbeBytes) {
          break;
        }
      }
    } catch (_) {
      // The body is untrusted and discarded; drain failures are irrelevant.
    }
    if (_finished) return;
    // Only the existence of a body is reported, never its content.
    _emit(
      StructuredSseFrame.error(
        statusCode: statusCode,
        unsafeBody: bodyExisted ? const Object() : null,
      ),
    );
    _finish(abort: true);
  }

  void _onChunk(List<int> chunk) {
    if (_finished) return;
    _resetIdleTimer();
    _totalResponseBytes += chunk.length;
    if (_totalResponseBytes >
        ProductionSseFrameTransport.maximumResponseBytes) {
      _failClosed();
      return;
    }
    final scanStart = _lineBuffer.length;
    _lineBuffer.addAll(chunk);
    var lineStart = 0;
    var index = scanStart;
    while (index < _lineBuffer.length) {
      if (_lineBuffer[index] == 0x0a) {
        var lineEnd = index;
        if (lineEnd > lineStart && _lineBuffer[lineEnd - 1] == 0x0d) {
          lineEnd--;
        }
        final handled = _handleLine(_lineBuffer.sublist(lineStart, lineEnd));
        if (!handled || _finished) return;
        lineStart = index + 1;
      }
      index++;
    }
    if (lineStart > 0) {
      _lineBuffer.removeRange(0, lineStart);
    }
  }

  bool _handleLine(List<int> lineBytes) {
    if (lineBytes.isEmpty) {
      return _dispatchEvent();
    }
    String line;
    try {
      line = utf8.decode(lineBytes);
    } on FormatException {
      _failClosed();
      return false;
    }
    if (line.startsWith(':')) return true;
    final colon = line.indexOf(':');
    final field = colon == -1 ? line : line.substring(0, colon);
    var value = colon == -1 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'data') {
      final separatorBytes = _dataLines.isEmpty ? 0 : 1;
      _eventDataBytes += utf8.encode(value).length + separatorBytes;
      if (_eventDataBytes > ProductionSseFrameTransport.maximumEventDataBytes) {
        _failClosed();
        return false;
      }
      _dataLines.add(value);
    }
    // event:, id:, retry:, and unknown fields are intentionally ignored.
    return true;
  }

  bool _dispatchEvent() {
    if (_dataLines.isEmpty) return true;
    final data = _dataLines.join('\n');
    _dataLines.clear();
    _eventDataBytes = 0;
    _eventCount++;
    if (_eventCount > ProductionSseFrameTransport.maximumEventCount) {
      _failClosed();
      return false;
    }
    if (data == '[DONE]') {
      _emit(StructuredSseFrame.done());
      _finish(abort: true);
      return false;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      _failClosed();
      return false;
    }
    if (decoded is! Map<String, Object?> || !_isValidJsonTree(decoded)) {
      _failClosed();
      return false;
    }
    _emit(StructuredSseFrame.data(decoded));
    return true;
  }

  void _onBodyEnded() {
    if (_finished) return;
    if (_cancelled) {
      _finish(abort: true);
      return;
    }
    // The stream ended without a terminal [DONE] event: report interruption.
    _failClosed();
  }

  void _onCancelled() {
    _cancelled = true;
    _finish(abort: true);
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(ProductionSseFrameTransport.idleTimeout, _failClosed);
  }

  void _failClosed() {
    if (_finished) return;
    _emit(StructuredSseFrame.error());
    _finish(abort: true);
  }

  void _emit(StructuredSseFrame frame) {
    if (_finished) return;
    _controller.add(frame);
  }

  void _finish({required bool abort}) {
    if (_finished) return;
    _finished = true;
    _idleTimer?.cancel();
    _overallTimer?.cancel();
    _cancellationSubscription?.dispose();
    final bodySubscription = _bodySubscription;
    _bodySubscription = null;
    unawaited(bodySubscription?.cancel());
    if (abort) {
      try {
        _request?.abort();
      } catch (_) {
        // Abort is best-effort teardown.
      }
    }
    try {
      _client?.close(force: abort);
    } catch (_) {
      // Closing is best-effort teardown.
    }
    unawaited(_controller.close());
  }

  static void _validateEndpoint(Uri endpoint) {
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.invalidEndpoint,
      );
    }
  }

  static void _validateRequestHeaders(Map<String, String> headers) {
    final headerName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
    final unsafeValue = RegExp(r'[\x00-\x1F\x7F]');
    const reserved = {
      'host',
      'content-length',
      'transfer-encoding',
      'connection',
      'te',
      'trailer',
      'upgrade',
      'forwarded',
      'x-http-method-override',
    };
    for (final entry in headers.entries) {
      final normalized = entry.key.toLowerCase();
      if (!headerName.hasMatch(entry.key) ||
          unsafeValue.hasMatch(entry.value) ||
          reserved.contains(normalized) ||
          normalized.startsWith('proxy-') ||
          normalized.startsWith('x-forwarded-')) {
        throw const UnaryTransportException(
          UnaryTransportErrorCode.invalidRequest,
        );
      }
    }
  }

  static bool _isValidJsonTree(Object? root) {
    final pending = <(Object?, int)>[(root, 0)];
    var nodes = 0;
    while (pending.isNotEmpty) {
      final (value, depth) = pending.removeLast();
      nodes++;
      if (nodes > SecureJsonHttpClient.maximumJsonNodes ||
          depth > SecureJsonHttpClient.maximumJsonDepth) {
        return false;
      }
      switch (value) {
        case null || bool() || String() || int():
          break;
        case double():
          if (!value.isFinite) return false;
        case List<Object?>():
          for (final item in value) {
            pending.add((item, depth + 1));
          }
        case Map<String, Object?>():
          for (final item in value.values) {
            pending.add((item, depth + 1));
          }
        default:
          return false;
      }
    }
    return true;
  }
}
