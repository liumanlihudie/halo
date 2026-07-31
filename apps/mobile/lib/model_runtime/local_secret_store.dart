// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';

import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';

/// Keeps credentials working when the Keychain will not take them.
///
/// The Keychain stays the first choice: it is encrypted by the system and
/// survives nothing else. But a development build that cannot write there
/// leaves the owner retyping a key after every install, and a key that will
/// not save is a feature that does not run. Writes that the Keychain rejects
/// fall back to a file inside the app sandbox, and reads try both.
///
/// The trade-off is real and deliberate: a fallback secret is readable by
/// anything that can read this app's container — a device backup, a jailbroken
/// phone. It is used only when the system store has already refused.
final class FallbackCredentialStore implements SecureCredentialStore {
  FallbackCredentialStore({
    required SecureCredentialStore primary,
    required Directory directory,
  }) : _primary = primary,
       _file = File('${directory.path}${Platform.pathSeparator}secrets.json');

  final SecureCredentialStore _primary;
  final File _file;

  @override
  Future<void> set(
    SecretRef ref,
    String secret, {
    CancellationToken? cancellationToken,
  }) async {
    try {
      await _primary.set(ref, secret, cancellationToken: cancellationToken);
      // A previous fallback copy must not outlive a successful system write.
      await _removeLocal(ref);
      return;
    } catch (_) {
      await _writeLocal(ref, secret);
    }
  }

  @override
  Future<String?> get(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async {
    try {
      final value = await _primary.get(
        ref,
        cancellationToken: cancellationToken,
      );
      if (value != null) return value;
    } catch (_) {
      // Fall through: the local copy may still hold it.
    }
    return (await _readLocal())[ref.locator.toString()];
  }

  @override
  Future<bool> delete(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async {
    var removed = false;
    try {
      removed = await _primary.delete(
        ref,
        cancellationToken: cancellationToken,
      );
    } catch (_) {
      // The local copy is still ours to remove.
    }
    return await _removeLocal(ref) || removed;
  }

  @override
  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  }) => _primary.listMetadata(
    service: service,
    cancellationToken: cancellationToken,
  );

  Future<Map<String, String>> _readLocal() async {
    try {
      if (!_file.existsSync()) return {};
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeLocal(SecretRef ref, String secret) async {
    final secrets = await _readLocal()
      ..[ref.locator.toString()] = secret;
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(secrets), flush: true);
  }

  Future<bool> _removeLocal(SecretRef ref) async {
    final secrets = await _readLocal();
    if (secrets.remove(ref.locator.toString()) == null) return false;
    await _file.writeAsString(jsonEncode(secrets), flush: true);
    return true;
  }
}
