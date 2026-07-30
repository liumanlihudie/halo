import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';

@immutable
class SafeSecureCredentialChannelRecord {
  const SafeSecureCredentialChannelRecord({
    required this.method,
    required this.service,
    required this.hadAccount,
    required this.hadSecret,
    required this.secretWasBytes,
  });

  final String method;
  final String? service;
  final bool hadAccount;
  final bool hadSecret;
  final bool secretWasBytes;

  @override
  String toString() =>
      'SafeSecureCredentialChannelRecord(method: $method, '
      'service: $service, hadAccount: $hadAccount, hadSecret: $hadSecret, '
      'secretWasBytes: $secretWasBytes)';
}

class FakeSecureCredentialChannel implements SecureCredentialChannel {
  final Queue<Future<Object?> Function()> _scripts = Queue();
  final List<SafeSecureCredentialChannelRecord> records = [];
  int callCount = 0;

  void enqueueResult(Object? result) {
    _scripts.add(() => Future.value(result));
  }

  void enqueueFuture(Future<Object?> result) {
    _scripts.add(() => result);
  }

  void enqueueError(Object error) {
    _scripts.add(() => Future.error(error));
  }

  @override
  Future<Object?> invokeMethod(String method, Map<String, Object?> arguments) {
    callCount++;
    records.add(
      SafeSecureCredentialChannelRecord(
        method: method,
        service: arguments['service'] as String?,
        hadAccount: arguments.containsKey('account'),
        hadSecret: arguments.containsKey('value'),
        secretWasBytes: arguments['value'] is Uint8List,
      ),
    );
    if (_scripts.isEmpty) {
      return Future.error(
        const SecureCredentialStoreException(
          SecureCredentialStoreError.unavailable,
        ),
      );
    }
    return _scripts.removeFirst()();
  }

  @override
  String toString() => 'FakeSecureCredentialChannel([REDACTED])';
}
