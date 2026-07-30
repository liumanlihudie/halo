// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';

/// Services configured by a credential alone.
///
/// These are not providers: none has a model catalogue to discover, and none
/// speaks an OpenAI-compatible chat protocol. Adding a fourth means adding an
/// entry here and nothing else.
enum KeyOnlyService {
  /// Volcano Engine (豆包) speech: the v3 TTS and ASR endpoints, one API key.
  doubaoSpeech('doubao-speech', '豆包语音', '语音消息的合成与转写'),

  /// Volcano Engine duplex realtime dialogue over WebSocket.
  doubaoRealtimeAudio('doubao-realtime-audio', '豆包端到端音频', '实时语音通话'),

  /// Vidu, used by the video call.
  vidu('vidu', 'Vidu 视频通话', '视频通话的画面生成');

  const KeyOnlyService(this.id, this.displayName, this.purpose);

  final String id;
  final String displayName;
  final String purpose;

  static KeyOnlyService? byId(String id) {
    for (final service in values) {
      if (service.id == id) return service;
    }
    return null;
  }
}

/// What the settings row may say about a service. Never the key, never the
/// locator: a service id is safe to render, a locator is not.
@immutable
class ServiceCredentialStatus {
  const ServiceCredentialStatus({
    required this.configured,
    required this.enabled,
    this.configuredAt,
    this.unreadable = false,
  });

  static const absent = ServiceCredentialStatus(
    configured: false,
    enabled: false,
  );

  final bool configured;

  /// A key was saved but can no longer be read back, so it must be entered
  /// again. Distinct from never having configured one.
  final bool unreadable;
  final bool enabled;
  final DateTime? configuredAt;
}

/// Durable half of the credential records, so tests need no SQLite.
abstract interface class ServiceCredentialPersistence {
  Future<List<PersistedServiceCredential>> loadServiceCredentials();

  /// Records the credential and returns any locator it displaced.
  Future<SecretRef?> putServiceCredential(
    String serviceId,
    SecretRef secretRef, {
    required bool enabled,
    required DateTime configuredAt,
  });

  Future<SecretRef?> removeServiceCredential(String serviceId);
}

/// Saves and forgets credentials for [KeyOnlyService]s.
///
/// **Ordering is the whole point.** The Keychain is written first and the row
/// second: a crash between the two leaves an unreferenced Keychain item, which
/// is inert, whereas the reverse order would leave a row pointing at a key that
/// does not exist and every call would fail with no way to fix it from the UI.
/// If the row write fails, the just-written key is deleted so no orphan
/// accumulates.
///
/// Key material passes through [save] and goes straight to the platform store.
/// It is never logged, never persisted to SQLite, never held in state, and
/// never read back for display — the UI can only learn *whether* a key exists.
final class ServiceCredentialsController extends ChangeNotifier {
  ServiceCredentialsController({
    required SecureCredentialStore credentials,
    required ServiceCredentialPersistence persistence,
    ProviderSecretRefFactory? secretRefs,
    ProviderMutationCoordinator? mutationCoordinator,
    DateTime Function()? now,
  }) : _credentials = credentials,
       _persistence = persistence,
       _secretRefs = secretRefs ?? SecureUuidProviderSecretRefFactory(),
       _mutationCoordinator =
           mutationCoordinator ?? SerializedProviderMutationCoordinator(),
       _now = now ?? DateTime.now;

  final SecureCredentialStore _credentials;
  final ServiceCredentialPersistence _persistence;
  final ProviderSecretRefFactory _secretRefs;

  /// Shared with the provider settings controller so a credential write cannot
  /// interleave with a provider mutation touching the same Keychain service.
  final ProviderMutationCoordinator _mutationCoordinator;
  final DateTime Function() _now;

  final Map<String, ServiceCredentialStatus> _statuses = {};
  var _loaded = false;
  var _busy = false;

  bool get loaded => _loaded;
  bool get busy => _busy;

  ServiceCredentialStatus statusFor(KeyOnlyService service) =>
      _statuses[service.id] ?? ServiceCredentialStatus.absent;

  Future<void> load() async {
    try {
      final records = await _persistence.loadServiceCredentials();
      _statuses.clear();
      for (final record in records) {
        if (KeyOnlyService.byId(record.serviceId) == null) continue;
        // A row proves a key was saved once, not that it can still be read.
        // Showing 已配置 on the row alone is how the settings page came to
        // disagree with the features, which report 尚未配置 when the secret no
        // longer resolves. The row is only believed if the key comes back.
        var readable = false;
        try {
          readable = await _credentials.get(record.secretRef) != null;
        } catch (_) {
          readable = false;
        }
        _statuses[record.serviceId] = ServiceCredentialStatus(
          configured: readable,
          enabled: record.enabled && readable,
          configuredAt: record.configuredAt,
          unreadable: !readable,
        );
      }
    } catch (_) {
      // Leaves the rows reading 未配置 rather than claiming a key exists.
      _statuses.clear();
    }
    _loaded = true;
    notifyListeners();
  }

  /// Stores [apiKey] for [service]. Returns false when nothing was saved.
  ///
  /// [apiKey] is trimmed of surrounding whitespace only — pasted keys routinely
  /// carry a trailing newline, and silently storing it would produce a header
  /// the upstream rejects for a reason the user cannot see.
  Future<bool> save(KeyOnlyService service, String apiKey) async {
    final secret = apiKey.trim();
    if (secret.isEmpty || _busy) return false;
    _busy = true;
    notifyListeners();
    try {
      return await _mutationCoordinator.runExclusive(() async {
        final ref = _secretRefs.next();
        await _credentials.set(ref, secret);
        final SecretRef? displaced;
        try {
          displaced = await _persistence.putServiceCredential(
            service.id,
            ref,
            enabled: true,
            configuredAt: _now().toUtc(),
          );
        } catch (_) {
          // Do not leave a key nobody references.
          await _deleteQuietly(ref);
          rethrow;
        }
        if (displaced != null) {
          // Best effort: the record already points at the new key, so a failed
          // cleanup costs an inert leftover, never a broken configuration.
          await _deleteQuietly(displaced);
        }
        _statuses[service.id] = ServiceCredentialStatus(
          configured: true,
          enabled: true,
          configuredAt: _now().toUtc(),
        );
        return true;
      });
    } catch (_) {
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Forgets [service] entirely, deleting the key after the row is gone.
  Future<bool> remove(KeyOnlyService service) async {
    if (_busy) return false;
    _busy = true;
    notifyListeners();
    try {
      return await _mutationCoordinator.runExclusive(() async {
        final removed = await _persistence.removeServiceCredential(service.id);
        // The row is authoritative, so it goes first here: a key left behind is
        // inert, while a row pointing at a deleted key would keep failing.
        if (removed != null) {
          await _deleteQuietly(removed);
        }
        _statuses.remove(service.id);
        return true;
      });
    } catch (_) {
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _deleteQuietly(SecretRef ref) async {
    try {
      await _credentials.delete(ref);
    } catch (_) {
      // Never surfaced: the caller's outcome does not depend on cleanup, and
      // the error could name the locator.
    }
  }
}
