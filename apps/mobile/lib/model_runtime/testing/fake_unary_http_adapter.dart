import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/unary_http_transport.dart';

@immutable
class SafeUnaryHttpRecord {
  SafeUnaryHttpRecord({
    required String method,
    required this.path,
    required this.hasPath,
    required this.pathSegmentCount,
    required this.contentType,
    required this.accept,
    required this.followRedirects,
    required this.authorizationWasBearer,
    required this.hadApiKey,
    required this.hadGoogleApiKey,
    required this.hadCredential,
    required this.hasBody,
    required this.bodyByteLength,
    required Map<String, String> safeHeaders,
    required Map<String, Object?> body,
  }) : method = _normalizeSafeRecordMethod(method),
       safeHeaders = Map.unmodifiable(safeHeaders),
       body = Map.unmodifiable(body);

  final String method;
  final String path;
  final bool hasPath;
  final int pathSegmentCount;
  final String? contentType;
  final String? accept;
  final bool followRedirects;
  final bool authorizationWasBearer;
  final bool hadApiKey;
  final bool hadGoogleApiKey;
  final bool hadCredential;
  final bool hasBody;
  final int bodyByteLength;
  final Map<String, String> safeHeaders;
  final Map<String, Object?> body;

  @override
  String toString() =>
      'SafeUnaryHttpRecord(method: $method, path: /***/, '
      'hadCredential: $hadCredential)';
}

class FakeUnaryHttpAdapter implements UnaryHttpAdapter {
  FakeUnaryHttpAdapter({
    this.retainSafeHeaderValuesForTesting = false,
    this.retainRequestContentForTesting = false,
  });

  final bool retainSafeHeaderValuesForTesting;
  final bool retainRequestContentForTesting;
  final Queue<Object> _outcomes = Queue();
  final List<SafeUnaryHttpRecord> records = [];
  bool cancellationObserved = false;
  bool _disposed = false;

  int get callCount => records.length;

  void enqueueJson({
    required int statusCode,
    required Map<String, Object?> body,
    Map<String, String> headers = const {},
    InternetAddress? remoteAddress,
  }) {
    _ensureActive();
    enqueueRaw(
      statusCode: statusCode,
      headers: headers,
      bytes: utf8.encode(jsonEncode(body)),
      remoteAddress: remoteAddress,
    );
  }

  void enqueueRaw({
    required int statusCode,
    required List<int> bytes,
    Map<String, String> headers = const {},
    InternetAddress? remoteAddress,
  }) {
    _ensureActive();
    _outcomes.add(
      RawUnaryHttpResponse(
        statusCode: statusCode,
        headers: headers,
        body: Stream.value(bytes),
        remoteAddress: remoteAddress ?? InternetAddress('8.8.8.8'),
      ),
    );
  }

  void enqueueError(Object error) {
    _ensureActive();
    _outcomes.add(error);
  }

  void enqueuePending() {
    _ensureActive();
    _outcomes.add(_PendingOutcome());
  }

  void clear() {
    records.clear();
    _outcomes.clear();
    cancellationObserved = false;
  }

  void dispose() {
    if (_disposed) return;
    clear();
    _disposed = true;
  }

  @override
  Future<RawUnaryHttpResponse> send(UnaryHttpAdapterRequest request) async {
    _ensureActive();
    records.add(_safeRecord(request));
    if (_outcomes.isEmpty) {
      throw StateError('No fake unary HTTP outcome enqueued');
    }
    final outcome = _outcomes.removeFirst();
    if (outcome is RawUnaryHttpResponse) return outcome;
    if (outcome is _PendingOutcome) {
      await request.cancellationToken.whenCancelled;
      cancellationObserved = true;
      throw const UnaryTransportException(UnaryTransportErrorCode.cancelled);
    }
    throw outcome;
  }

  SafeUnaryHttpRecord _safeRecord(UnaryHttpAdapterRequest request) {
    final normalizedHeaders = request.headers.map(
      (key, value) => MapEntry(key.toLowerCase(), value),
    );
    final safeHeaders = <String, String>{};
    if (retainSafeHeaderValuesForTesting) {
      for (final entry in normalizedHeaders.entries) {
        if (!request.sensitiveHeaderNames.contains(entry.key)) {
          safeHeaders[entry.key] = entry.value;
        }
      }
    }
    Map<String, Object?> body = const {};
    if (retainRequestContentForTesting) {
      try {
        body = Map<String, Object?>.from(
          jsonDecode(utf8.decode(request.bodyBytes)) as Map,
        );
      } catch (_) {
        body = const {};
      }
    }
    return SafeUnaryHttpRecord(
      method: request.method,
      path: retainRequestContentForTesting
          ? request.endpoint.path
          : request.endpoint.path.isEmpty
          ? '/'
          : '/***/',
      hasPath: request.endpoint.path.isNotEmpty,
      pathSegmentCount: request.endpoint.pathSegments
          .where((segment) => segment.isNotEmpty)
          .length,
      contentType:
          !retainSafeHeaderValuesForTesting ||
              request.sensitiveHeaderNames.contains('content-type')
          ? null
          : normalizedHeaders['content-type'],
      accept:
          !retainSafeHeaderValuesForTesting ||
              request.sensitiveHeaderNames.contains('accept')
          ? null
          : normalizedHeaders['accept'],
      followRedirects: false,
      authorizationWasBearer:
          normalizedHeaders['authorization']?.startsWith('Bearer ') ?? false,
      hadApiKey: normalizedHeaders.containsKey('x-api-key'),
      hadGoogleApiKey: normalizedHeaders.containsKey('x-goog-api-key'),
      hadCredential: request.sensitiveHeaderNames.isNotEmpty,
      hasBody: request.bodyBytes.isNotEmpty,
      bodyByteLength: request.bodyBytes.length,
      safeHeaders: safeHeaders,
      body: body,
    );
  }

  void _ensureActive() {
    if (_disposed) throw StateError('Fake unary HTTP adapter is disposed');
  }
}

class _PendingOutcome {}

String _normalizeSafeRecordMethod(String method) {
  if (method != 'POST') {
    throw ArgumentError('Unsupported unary HTTP method');
  }
  return 'POST';
}
