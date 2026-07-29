import 'package:flutter/foundation.dart';

@immutable
class SecretRef {
  const SecretRef._(this._uri);

  factory SecretRef.parse(String value) {
    final normalized = value.trim();
    final uri = Uri.tryParse(normalized);
    if (normalized.isEmpty ||
        normalized != value ||
        normalized.toLowerCase().startsWith('sk-') ||
        uri == null ||
        !const {'keychain', 'vault', 'memory'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        (uri.scheme == 'memory' && uri.host != 'test') ||
        normalized.contains('%')) {
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
    : value = value {
    if (value.isEmpty || value != value.trim()) {
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

abstract final class ProviderSecretRefPolicy {
  static const service = 'halo.provider';
  static final RegExp _uuidAccount = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-'
    r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  static bool isValid(SecretRef ref) {
    final uri = ref.locator;
    if (ref.scheme != 'keychain' ||
        uri.host != service ||
        uri.pathSegments.length != 1) {
      return false;
    }
    final account = uri.pathSegments.single;
    final canonical = 'keychain://$service/$account';
    return ref.scheme == 'keychain' &&
        _uuidAccount.hasMatch(account) &&
        uri.toString() == canonical;
  }

  static void validate(SecretRef ref) {
    if (!isValid(ref)) {
      throw ArgumentError.value(
        ref,
        'secretRef',
        'Provider secrets require the fixed Keychain service and UUID account',
      );
    }
  }
}
