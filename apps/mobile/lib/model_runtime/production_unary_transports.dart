import 'dart:convert';

import 'package:halo_mobile/model_runtime/anthropic_transport.dart';
import 'package:halo_mobile/model_runtime/gemini_transport.dart';
import 'package:halo_mobile/model_runtime/openai_compatible_transport.dart';
import 'package:halo_mobile/model_runtime/openai_native_transport.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/unary_http_transport.dart';

class ProductionOpenAICompatibleHttpTransport
    implements OpenAICompatibleHttpTransport {
  ProductionOpenAICompatibleHttpTransport({
    required this.client,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.timestamp;

  final SecureJsonHttpClient client;
  final DateTime Function() _now;

  @override
  Future<OpenAICompatibleTransportResponse> sendChat(
    OpenAICompatibleTransportRequest request,
  ) async {
    _requirePath(request.endpoint, '/chat/completions');
    final headers = _baseHeaders();
    final sensitive = <String>{};
    final credential = request.credential;
    if (credential != null) {
      _requireCredential(credential, _now());
      _requireCredentialOutsideEndpoint(request.endpoint, credential);
      headers['authorization'] = 'Bearer ${credential.value}';
      sensitive.add('authorization');
    }
    for (final entry in request.headerCredentials.entries) {
      _requireCredential(entry.value, _now());
      _requireCredentialOutsideEndpoint(request.endpoint, entry.value);
      _addCompatibleCredentialHeader(
        headers,
        sensitive,
        entry.key,
        entry.value.value,
      );
    }
    final response = await client.postJson(
      endpoint: request.endpoint,
      body: request.body,
      headers: headers,
      sensitiveHeaderNames: sensitive,
      cancellationToken: request.cancellationToken,
    );
    return OpenAICompatibleTransportResponse(
      statusCode: response.statusCode,
      body: response.body,
      retryAfter: response.retryAfter,
    );
  }
}

class ProductionOpenAINativeHttpTransport implements OpenAINativeHttpTransport {
  ProductionOpenAINativeHttpTransport({
    required this.client,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.timestamp;

  final SecureJsonHttpClient client;
  final DateTime Function() _now;

  @override
  Future<OpenAINativeTransportResponse> sendChat(
    OpenAINativeTransportRequest request,
  ) async {
    _requirePath(request.endpoint, '/chat/completions');
    _requireCredential(request.credential, _now());
    _requireCredentialOutsideEndpoint(request.endpoint, request.credential);
    final response = await client.postJson(
      endpoint: request.endpoint,
      body: request.body,
      headers: {
        ..._baseHeaders(),
        'authorization': 'Bearer ${request.credential.value}',
      },
      sensitiveHeaderNames: const {'authorization'},
      cancellationToken: request.cancellationToken,
    );
    return OpenAINativeTransportResponse(
      statusCode: response.statusCode,
      body: response.body,
      retryAfter: response.retryAfter,
    );
  }
}

class ProductionAnthropicHttpTransport implements AnthropicHttpTransport {
  ProductionAnthropicHttpTransport({
    required this.client,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.timestamp;

  final SecureJsonHttpClient client;
  final DateTime Function() _now;

  @override
  Future<AnthropicTransportResponse> sendMessage(
    AnthropicTransportRequest request,
  ) async {
    _requirePath(request.endpoint, '/messages');
    _requireCredential(request.credential, _now());
    _requireCredentialOutsideEndpoint(request.endpoint, request.credential);
    final response = await client.postJson(
      endpoint: request.endpoint,
      body: request.body,
      headers: {
        ..._baseHeaders(),
        'x-api-key': request.credential.value,
        'anthropic-version': request.apiVersion,
      },
      sensitiveHeaderNames: const {'x-api-key'},
      cancellationToken: request.cancellationToken,
    );
    return AnthropicTransportResponse(
      statusCode: response.statusCode,
      body: response.body,
      retryAfter: response.retryAfter,
    );
  }
}

class ProductionGeminiHttpTransport implements GeminiHttpTransport {
  ProductionGeminiHttpTransport({
    required this.client,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.timestamp;

  final SecureJsonHttpClient client;
  final DateTime Function() _now;

  @override
  Future<GeminiTransportResponse> generateContent(
    GeminiTransportRequest request,
  ) async {
    final path = request.endpoint.path;
    if (!RegExp(r'/models/[A-Za-z0-9._-]+:generateContent$').hasMatch(path)) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.invalidEndpoint,
      );
    }
    _requireCredential(request.credential, _now());
    _requireCredentialOutsideEndpoint(request.endpoint, request.credential);
    final response = await client.postJson(
      endpoint: request.endpoint,
      body: request.body,
      headers: {..._baseHeaders(), 'x-goog-api-key': request.credential.value},
      sensitiveHeaderNames: const {'x-goog-api-key'},
      cancellationToken: request.cancellationToken,
    );
    return GeminiTransportResponse(
      statusCode: response.statusCode,
      body: response.body,
      retryAfter: response.retryAfter,
    );
  }
}

Map<String, String> _baseHeaders() => {
  'content-type': 'application/json',
  'accept': 'application/json',
  'accept-encoding': 'gzip',
};

void _requirePath(Uri endpoint, String suffix) {
  if (!endpoint.path.endsWith(suffix)) {
    throw const UnaryTransportException(
      UnaryTransportErrorCode.invalidEndpoint,
    );
  }
}

void _requireCredential(EphemeralCredential credential, DateTime now) {
  if (!credential.isValidAt(now) ||
      utf8.encode(credential.value).length > 64 * 1024 ||
      RegExp(r'[\x00-\x1F\x7F]').hasMatch(credential.value)) {
    throw const UnaryTransportException(
      UnaryTransportErrorCode.invalidCredential,
    );
  }
}

void _requireCredentialOutsideEndpoint(
  Uri endpoint,
  EphemeralCredential credential,
) {
  final serialized = endpoint.toString();
  String decoded;
  try {
    decoded = Uri.decodeFull(serialized);
  } catch (_) {
    decoded = serialized;
  }
  if (serialized.contains(credential.value) ||
      decoded.contains(credential.value)) {
    throw const UnaryTransportException(
      UnaryTransportErrorCode.invalidEndpoint,
    );
  }
}

void _addCompatibleCredentialHeader(
  Map<String, String> headers,
  Set<String> sensitive,
  String name,
  String value,
) {
  final normalized = name.toLowerCase();
  const forbidden = {
    'accept',
    'accept-encoding',
    'connection',
    'content-length',
    'content-type',
    'host',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };
  final allowedAuthenticationName =
      normalized == 'authorization' || normalized.startsWith('x-');
  final conflicts = headers.keys.any(
    (existing) => existing.toLowerCase() == normalized,
  );
  if (!allowedAuthenticationName ||
      forbidden.contains(normalized) ||
      conflicts) {
    throw const UnaryTransportException(UnaryTransportErrorCode.invalidRequest);
  }
  headers[name] = value;
  sensitive.add(normalized);
}
