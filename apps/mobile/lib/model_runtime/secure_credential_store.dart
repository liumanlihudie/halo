import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

enum SecureCredentialStoreError {
  invalidReference,
  invalidSecret,
  notFound,
  deviceLocked,
  cancelled,
  unavailable,
  invalidResponse,
  operationFailed,
}

class SecureCredentialStoreException implements Exception {
  const SecureCredentialStoreException(this.code);

  final SecureCredentialStoreError code;

  @override
  String toString() => 'SecureCredentialStoreException(${code.name})';
}

@immutable
class SecureCredentialMetadata {
  const SecureCredentialMetadata({
    required this.service,
    required this.account,
    required this.createdAt,
    required this.updatedAt,
  });

  final String service;
  final String account;
  final DateTime createdAt;
  final DateTime updatedAt;

  @override
  String toString() =>
      'SecureCredentialMetadata(service: $service, account: [REDACTED])';
}

abstract interface class SecureCredentialStore {
  Future<void> set(
    SecretRef ref,
    String secret, {
    CancellationToken? cancellationToken,
  });

  Future<String?> get(SecretRef ref, {CancellationToken? cancellationToken});

  Future<bool> delete(SecretRef ref, {CancellationToken? cancellationToken});

  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  });
}

abstract interface class SecureCredentialChannel {
  Future<Object?> invokeMethod(String method, Map<String, Object?> arguments);
}

class FlutterSecureCredentialChannel implements SecureCredentialChannel {
  const FlutterSecureCredentialChannel({
    this.channel = const MethodChannel(
      MethodChannelSecureCredentialStore.channelName,
    ),
  });

  final MethodChannel channel;

  @override
  Future<Object?> invokeMethod(String method, Map<String, Object?> arguments) =>
      channel.invokeMethod<Object?>(method, arguments);

  @override
  String toString() => 'FlutterSecureCredentialChannel([REDACTED])';
}

class MethodChannelSecureCredentialStore implements SecureCredentialStore {
  const MethodChannelSecureCredentialStore({
    this.channel = const FlutterSecureCredentialChannel(),
  });

  static const channelName = 'halo/secure_credential_store';
  static const maximumSecretBytes = 64 * 1024;
  static const maximumMetadataCount = 1024;

  final SecureCredentialChannel channel;

  @override
  Future<void> set(
    SecretRef ref,
    String secret, {
    CancellationToken? cancellationToken,
  }) async {
    final location = _location(ref);
    if (secret.isEmpty) {
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.invalidSecret,
      );
    }
    final secretBytes = Uint8List.fromList(utf8.encode(secret));
    if (secretBytes.length > maximumSecretBytes) {
      secretBytes.fillRange(0, secretBytes.length, 0);
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.invalidSecret,
      );
    }
    try {
      final result = await _invoke(
        'set',
        {
          'service': location.service,
          'account': location.account,
          'value': secretBytes,
        },
        cancellationToken,
        allowCancellationAfterDispatch: false,
      );
      if (result != null && result != true) {
        throw const SecureCredentialStoreException(
          SecureCredentialStoreError.invalidResponse,
        );
      }
    } finally {
      secretBytes.fillRange(0, secretBytes.length, 0);
    }
  }

  @override
  Future<String?> get(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async {
    final location = _location(ref);
    final result = await _invoke('get', {
      'service': location.service,
      'account': location.account,
    }, cancellationToken);
    if (result == null) return null;
    if (result is! Uint8List || result.isEmpty) {
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.invalidResponse,
      );
    }
    final mutableBytes = Uint8List.fromList(result);
    _wipeBytes(result);
    try {
      return utf8.decode(mutableBytes, allowMalformed: false);
    } catch (_) {
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.invalidResponse,
      );
    } finally {
      _wipeBytes(mutableBytes);
    }
  }

  @override
  Future<bool> delete(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async {
    final location = _location(ref);
    final result = await _invoke(
      'delete',
      {'service': location.service, 'account': location.account},
      cancellationToken,
      allowCancellationAfterDispatch: false,
    );
    if (result is! bool) {
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.invalidResponse,
      );
    }
    return result;
  }

  @override
  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  }) async {
    if (service != null && !_safeIdentifier(service, maximumLength: 128)) {
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.invalidReference,
      );
    }
    final arguments = <String, Object?>{};
    if (service != null) arguments['service'] = service;
    final result = await _invoke('listMetadata', arguments, cancellationToken);
    if (result is! List || result.length > maximumMetadataCount) {
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.invalidResponse,
      );
    }
    try {
      return List.unmodifiable(result.map(_parseMetadata));
    } catch (_) {
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.invalidResponse,
      );
    }
  }

  Future<Object?> _invoke(
    String method,
    Map<String, Object?> arguments,
    CancellationToken? cancellationToken, {
    bool allowCancellationAfterDispatch = true,
  }) async {
    final token = cancellationToken ?? CancellationToken();
    if (token.isCancelled) {
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.cancelled,
      );
    }
    try {
      final operation = channel.invokeMethod(
        method,
        UnmodifiableMapView(arguments),
      );
      if (!allowCancellationAfterDispatch) {
        return await operation;
      }
      final race = Completer<Object?>();
      var cancellationWon = false;

      operation.then<void>(
        (value) {
          if (race.isCompleted) {
            if (cancellationWon && value is Uint8List) {
              _wipeBytes(value);
            }
            return;
          }
          race.complete(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!race.isCompleted) race.completeError(error, stackTrace);
        },
      );
      token.whenCancelled.then<void>((_) {
        if (race.isCompleted) return;
        cancellationWon = true;
        race.completeError(
          const SecureCredentialStoreException(
            SecureCredentialStoreError.cancelled,
          ),
          StackTrace.current,
        );
      });
      return await race.future;
    } on SecureCredentialStoreException {
      rethrow;
    } on PlatformException catch (error) {
      throw SecureCredentialStoreException(_mapPlatformCode(error.code));
    } on MissingPluginException {
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.unavailable,
      );
    } catch (_) {
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.operationFailed,
      );
    }
  }

  static _KeychainLocation _location(SecretRef ref) {
    final uri = ref.locator;
    final segments = uri.pathSegments;
    if (ref.scheme != 'keychain' ||
        uri.hasPort ||
        segments.length != 1 ||
        !_safeIdentifier(uri.host, maximumLength: 128) ||
        !_safeIdentifier(segments.single, maximumLength: 256) ||
        segments.single == '.' ||
        segments.single == '..' ||
        segments.single.contains('/')) {
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.invalidReference,
      );
    }
    return _KeychainLocation(service: uri.host, account: segments.single);
  }

  static bool _safeIdentifier(String value, {required int maximumLength}) {
    if (value.isEmpty ||
        utf8.encode(value).length > maximumLength ||
        RegExp(
          r'[\x00-\x20\x7F-\x9F\u00AD\u061C\u180E'
          r'\u200B-\u200F\u2028-\u202E\u2060-\u206F'
          r'\uFEFF\uFFF9-\uFFFB]',
        ).hasMatch(value)) {
      return false;
    }
    final lower = value.toLowerCase();
    final isCompleteOpenAiStyleToken =
        lower.startsWith('sk-') &&
        value.length >= 23 &&
        RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
    return !isCompleteOpenAiStyleToken;
  }

  static SecureCredentialMetadata _parseMetadata(Object? raw) {
    if (raw is! Map) throw const FormatException();
    final service = raw['service'];
    final account = raw['account'];
    final createdAt = DateTime.tryParse(raw['createdAt'] as String? ?? '');
    final updatedAt = DateTime.tryParse(raw['updatedAt'] as String? ?? '');
    if (service is! String ||
        account is! String ||
        !_safeIdentifier(service, maximumLength: 128) ||
        !_safeIdentifier(account, maximumLength: 256) ||
        createdAt == null ||
        updatedAt == null) {
      throw const FormatException();
    }
    return SecureCredentialMetadata(
      service: service,
      account: account,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  static SecureCredentialStoreError _mapPlatformCode(String code) =>
      switch (code) {
        'locked' => SecureCredentialStoreError.deviceLocked,
        'cancelled' => SecureCredentialStoreError.cancelled,
        'not_found' => SecureCredentialStoreError.notFound,
        'invalid_arguments' => SecureCredentialStoreError.invalidReference,
        'unavailable' => SecureCredentialStoreError.unavailable,
        _ => SecureCredentialStoreError.operationFailed,
      };

  @override
  String toString() => 'MethodChannelSecureCredentialStore([REDACTED])';
}

void _wipeBytes(Uint8List bytes) {
  try {
    bytes.fillRange(0, bytes.length, 0);
  } on UnsupportedError {
    // StandardMessageCodec can return an unmodifiable typed-data view.
  }
}

class KeychainSecretResolver implements SecretResolver {
  KeychainSecretResolver({
    required this.store,
    this.leaseDuration = const Duration(seconds: 15),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.timestamp {
    if (leaseDuration <= Duration.zero ||
        leaseDuration > const Duration(minutes: 1)) {
      throw ArgumentError.value(leaseDuration, 'leaseDuration');
    }
  }

  final SecureCredentialStore store;
  final Duration leaseDuration;
  final DateTime Function() _now;

  @override
  Future<EphemeralCredential?> resolve(SecretRef ref) async {
    if (ref.scheme != 'keychain') {
      throw const SecureCredentialStoreException(
        SecureCredentialStoreError.invalidReference,
      );
    }
    final value = await store.get(ref);
    if (value == null) return null;
    return EphemeralCredential(
      value: value,
      expiresAt: _now().add(leaseDuration),
    );
  }

  @override
  String toString() => 'KeychainSecretResolver([REDACTED])';
}

@immutable
class _KeychainLocation {
  const _KeychainLocation({required this.service, required this.account});

  final String service;
  final String account;
}
