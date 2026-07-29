import 'package:flutter/foundation.dart';

@immutable
class SecretRef {
  const SecretRef._(this._uri);

  factory SecretRef.parse(String value) {
    final normalized = value.trim();
    final uri = Uri.tryParse(normalized);
    if (normalized.isEmpty ||
        normalized.toLowerCase().startsWith('sk-') ||
        uri == null ||
        !const {'keychain', 'vault', 'memory'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        (uri.scheme == 'memory' && uri.host != 'test')) {
      throw ArgumentError.value(value, 'value', 'Invalid secret reference');
    }
    return SecretRef._(uri);
  }

  final Uri _uri;

  String get scheme => _uri.scheme;
  Uri get locator => _uri;

  @override
  bool operator ==(Object other) => other is SecretRef && other._uri == _uri;

  @override
  int get hashCode => _uri.hashCode;

  @override
  String toString() => '$scheme://***/***';
}

@immutable
class EphemeralCredential {
  EphemeralCredential({required String value, required this.expiresAt})
    : value = value.trim() {
    if (this.value.isEmpty) {
      throw ArgumentError.value(value, 'value');
    }
  }

  final String value;
  final DateTime expiresAt;

  bool isValidAt(DateTime instant) => expiresAt.isAfter(instant);

  @override
  String toString() => 'EphemeralCredential([REDACTED])';
}

abstract interface class SecretResolver {
  Future<EphemeralCredential?> resolve(SecretRef ref);
}
