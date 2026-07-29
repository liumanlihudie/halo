import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

@immutable
class AnthropicTransportRequest {
  AnthropicTransportRequest({
    required this.endpoint,
    required Map<String, Object?> body,
    required this.credential,
    required this.apiVersion,
    this.cancellationToken,
  }) : body = Map.unmodifiable(body);

  final Uri endpoint;
  final Map<String, Object?> body;
  final EphemeralCredential credential;
  final String apiVersion;
  final CancellationToken? cancellationToken;

  @override
  String toString() =>
      'AnthropicTransportRequest(origin: ${endpoint.origin}, '
      'path: /***/, hasCredential: true)';
}

@immutable
class AnthropicTransportResponse {
  const AnthropicTransportResponse({
    required this.statusCode,
    required this.body,
    this.retryAfter,
  });

  final int statusCode;
  final Map<String, Object?> body;
  final Duration? retryAfter;
}

abstract interface class AnthropicHttpTransport {
  Future<AnthropicTransportResponse> sendMessage(
    AnthropicTransportRequest request,
  );
}
