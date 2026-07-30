import 'package:flutter/foundation.dart';

@immutable
class SafeNativeTransportRecord {
  SafeNativeTransportRecord({
    required this.endpoint,
    required Map<String, Object?> body,
    required this.hadCredential,
    Map<String, Object?> metadata = const {},
  }) : body = Map.unmodifiable(body),
       metadata = Map.unmodifiable(metadata);

  final Uri endpoint;
  final Map<String, Object?> body;
  final bool hadCredential;
  final Map<String, Object?> metadata;

  @override
  String toString() =>
      'SafeNativeTransportRecord(origin: ${endpoint.origin}, '
      'path: /***/, hadCredential: $hadCredential, metadata: $metadata)';
}
