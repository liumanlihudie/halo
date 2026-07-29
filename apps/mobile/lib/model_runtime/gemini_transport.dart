import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

@immutable
class GeminiTransportRequest {
  GeminiTransportRequest({
    required this.endpoint,
    required Map<String, Object?> body,
    required this.credential,
  }) : body = Map.unmodifiable(body);

  final Uri endpoint;
  final Map<String, Object?> body;
  final EphemeralCredential credential;

  @override
  String toString() =>
      'GeminiTransportRequest(origin: ${endpoint.origin}, '
      'path: /***/, hasCredential: true)';
}

@immutable
class GeminiTransportResponse {
  const GeminiTransportResponse({
    required this.statusCode,
    required this.body,
    this.retryAfter,
  });

  final int statusCode;
  final Map<String, Object?> body;
  final Duration? retryAfter;
}

abstract interface class GeminiHttpTransport {
  Future<GeminiTransportResponse> generateContent(
    GeminiTransportRequest request,
  );
}
