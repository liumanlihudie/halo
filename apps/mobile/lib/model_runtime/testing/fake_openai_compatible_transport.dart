import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/openai_compatible_transport.dart';

@immutable
class SafeTransportRecord {
  SafeTransportRecord({
    required this.endpoint,
    required Map<String, Object?> body,
    required this.hadCredential,
    required Iterable<String> headerCredentialNames,
  }) : body = Map.unmodifiable(body),
       headerCredentialNames = List.unmodifiable(headerCredentialNames);

  final Uri endpoint;
  final Map<String, Object?> body;
  final bool hadCredential;
  final List<String> headerCredentialNames;

  @override
  String toString() =>
      'SafeTransportRecord(origin: ${endpoint.origin}, '
      'path: ${endpoint.path.isEmpty || endpoint.path == '/' ? '/' : '/***/'}, '
      'hadCredential: $hadCredential, '
      'headerCredentialNames: $headerCredentialNames)';
}

class FakeOpenAICompatibleTransport implements OpenAICompatibleHttpTransport {
  final Queue<OpenAICompatibleTransportResponse> _responses = Queue();
  final List<SafeTransportRecord> records = [];

  void enqueue(OpenAICompatibleTransportResponse response) {
    _responses.add(response);
  }

  @override
  Future<OpenAICompatibleTransportResponse> sendChat(
    OpenAICompatibleTransportRequest request,
  ) async {
    records.add(
      SafeTransportRecord(
        endpoint: request.endpoint,
        body: request.body,
        hadCredential: request.credential != null,
        headerCredentialNames: request.headerCredentials.keys,
      ),
    );
    if (_responses.isEmpty) {
      throw StateError('No fake transport response enqueued');
    }
    return _responses.removeFirst();
  }
}
