import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

@immutable
class OpenAINativeTransportRequest {
  OpenAINativeTransportRequest({
    required this.endpoint,
    required Map<String, Object?> body,
    required this.credential,
  }) : body = Map.unmodifiable(body);

  final Uri endpoint;
  final Map<String, Object?> body;
  final EphemeralCredential credential;

  @override
  String toString() =>
      'OpenAINativeTransportRequest(origin: ${endpoint.origin}, '
      'path: /***/, hasCredential: true)';
}

@immutable
class OpenAINativeTransportResponse {
  const OpenAINativeTransportResponse({
    required this.statusCode,
    required this.body,
    this.retryAfter,
  });

  final int statusCode;
  final Map<String, Object?> body;
  final Duration? retryAfter;
}

abstract interface class OpenAINativeHttpTransport {
  Future<OpenAINativeTransportResponse> sendChat(
    OpenAINativeTransportRequest request,
  );
}
