import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

@immutable
class OpenAICompatibleTransportRequest {
  OpenAICompatibleTransportRequest({
    required this.endpoint,
    required Map<String, Object?> body,
    this.credential,
    Map<String, EphemeralCredential> headerCredentials = const {},
  }) : body = Map.unmodifiable(body),
       headerCredentials = Map.unmodifiable(headerCredentials);

  final Uri endpoint;
  final Map<String, Object?> body;
  final EphemeralCredential? credential;
  final Map<String, EphemeralCredential> headerCredentials;

  @override
  String toString() =>
      'OpenAICompatibleTransportRequest(origin: ${endpoint.origin}, '
      'path: ${_redactedPath(endpoint)}, '
      'hasCredential: ${credential != null}, '
      'headerCredentialNames: ${headerCredentials.keys.toList()})';
}

String _redactedPath(Uri uri) =>
    uri.path.isEmpty || uri.path == '/' ? '/' : '/***/';

@immutable
class OpenAICompatibleTransportResponse {
  const OpenAICompatibleTransportResponse({
    required this.statusCode,
    required this.body,
    this.retryAfter,
  });

  final int statusCode;
  final Map<String, Object?> body;
  final Duration? retryAfter;
}

abstract interface class OpenAICompatibleHttpTransport {
  Future<OpenAICompatibleTransportResponse> sendChat(
    OpenAICompatibleTransportRequest request,
  );
}
