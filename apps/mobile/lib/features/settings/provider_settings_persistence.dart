import 'dart:collection';

import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

abstract interface class ProviderSettingsRecoveryPersistence {
  /// Resumes durable staged operations without ever reading Key bytes.
  Future<void> recoverPending(SecureCredentialStore credentials);
}

/// Adapts the trusted store's staged CAS mutations to the settings workflow.
///
/// The adapter never handles API Key bytes. It only moves canonical SecretRef
/// identities already embedded in validated ProviderConfig values.
final class AtomicProviderSettingsPersistence
    implements
        ProviderSettingsPersistence,
        ProviderSettingsRecoveryPersistence {
  AtomicProviderSettingsPersistence(this._store);

  final ProviderConfigurationStore _store;
  final Map<ProviderSettingsSnapshot, VersionedProviderConfiguration>
  _versions = HashMap.identity();
  final Map<ProviderSettingsSnapshot, ProviderRemovalLease> _removals =
      HashMap.identity();

  ProviderConfigurationMutationLease? _pendingMutation;
  ProviderSettingsSnapshot? _pendingPrevious;
  ProviderSettingsSnapshot? _pendingNext;

  @override
  Future<ProviderSettingsSnapshot?> load(String providerId) async {
    final versioned = await _store.loadProvider(providerId);
    if (versioned == null) return null;
    final global = await _store.loadGlobalDefaultModel();
    final model = global?.providerId == providerId
        ? global!
        : _defaultModel(providerId);
    final snapshot = ProviderSettingsSnapshot(
      config: versioned.config,
      model: model,
    );
    _versions[snapshot] = versioned;
    return snapshot;
  }

  @override
  Future<void> replace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {
    if (_pendingMutation != null ||
        (previous != null &&
            previous.config.providerId != next.config.providerId)) {
      throw StateError('Provider settings mutation conflict');
    }
    final replacement = ProviderConfigurationReplacement(
      config: next.config,
      modelBindings: ProviderModelBindingMutation(
        replaceGlobalDefault: true,
        globalDefault: next.model,
      ),
    );
    late final ProviderConfigurationMutationLease lease;
    if (previous == null) {
      lease = await _store.replaceProviderConfiguration(
        expectedRevision: null,
        replacement: replacement,
      );
    } else {
      final versioned = _versions[previous];
      if (versioned == null) {
        throw StateError('Provider settings snapshot identity is stale');
      }
      final oldRef = previous.config.secretRef;
      final newRef = next.config.secretRef;
      if (oldRef != null && newRef != null && oldRef != newRef) {
        lease = await _store.rotateCredential(
          providerId: next.config.providerId,
          slot: ProviderCredentialSlot.primary,
          expectedRevision: versioned.revision,
          expectedOldRef: oldRef,
          newRef: newRef,
          replacement: replacement,
        );
      } else {
        lease = await _store.replaceProviderConfiguration(
          expectedRevision: versioned.revision,
          replacement: replacement,
        );
      }
    }
    _pendingMutation = lease;
    _pendingPrevious = previous;
    _pendingNext = next;
  }

  @override
  Future<void> rollbackReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {
    final lease = _requirePending(previous, next);
    await _store.rollbackProviderMutation(lease);
    _clearPending();
  }

  @override
  Future<void> finalizeReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {
    final lease = _requirePending(previous, next);
    await _store.finalizeProviderMutation(lease);
    _versions[next] = VersionedProviderConfiguration(
      config: next.config,
      revision: lease.newRevision,
    );
    _clearPending();
  }

  @override
  Future<void> remove(ProviderSettingsSnapshot snapshot) async {
    if (_removals.containsKey(snapshot)) {
      throw StateError('Provider removal is already staged');
    }
    final versioned = _versions[snapshot];
    if (versioned == null) {
      throw StateError('Provider settings snapshot identity is stale');
    }
    _removals[snapshot] = await _store.removeProviderAtomically(
      providerId: snapshot.config.providerId,
      expectedRevision: versioned.revision,
    );
  }

  @override
  Future<void> restore(ProviderSettingsSnapshot snapshot) async {
    final lease = _removals[snapshot];
    if (lease == null) throw StateError('Provider removal lease is missing');
    await _store.restoreRemovedProvider(lease);
    _removals.remove(snapshot);
  }

  @override
  Future<void> finalizeRemoval(ProviderSettingsSnapshot snapshot) async {
    final lease = _removals[snapshot];
    if (lease == null) throw StateError('Provider removal lease is missing');
    await _store.finalizeProviderRemoval(lease);
    _removals.remove(snapshot);
    _versions.remove(snapshot);
  }

  ProviderConfigurationMutationLease _requirePending(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) {
    final lease = _pendingMutation;
    if (lease == null ||
        !identical(previous, _pendingPrevious) ||
        !identical(next, _pendingNext)) {
      throw StateError('Provider mutation lease identity mismatch');
    }
    return lease;
  }

  void _clearPending() {
    _pendingMutation = null;
    _pendingPrevious = null;
    _pendingNext = null;
  }

  @override
  Future<void> recoverPending(SecureCredentialStore credentials) async {
    final metadata = await credentials.listMetadata(
      service: ProviderSecretRefPolicy.service,
    );
    final existingAccounts = {
      for (final item in metadata)
        if (item.service == ProviderSecretRefPolicy.service) item.account,
    };
    final operations = await _store.listPendingProviderOperations();
    for (final descriptor in operations) {
      final recovery = await _store.recoverPendingProviderOperation(
        operationId: descriptor.operationId,
        expectedProviderId: descriptor.providerId,
        expectedKind: descriptor.kind,
      );
      if (descriptor.kind == PendingProviderOperationKind.remove) {
        await _deleteExistingRefs(
          credentials,
          descriptor.previousCredentialRefs.values,
          existingAccounts,
        );
        final lease = recovery.removalLease;
        if (lease == null) {
          throw StateError('Pending provider removal recovery is invalid');
        }
        await _store.finalizeProviderRemoval(lease);
        continue;
      }

      final newRefs = descriptor.nextCredentialRefs.values.toSet();
      final allNewRefsExist = newRefs.every(
        (ref) => existingAccounts.contains(_account(ref)),
      );
      final lease = recovery.mutationLease;
      if (lease == null) {
        throw StateError('Pending provider mutation recovery is invalid');
      }
      if (!allNewRefsExist) {
        final previousRefs = descriptor.previousCredentialRefs.values;
        final allPreviousRefsExist = previousRefs.every(
          (ref) => existingAccounts.contains(_account(ref)),
        );
        if (previousRefs.isNotEmpty && !allPreviousRefsExist) {
          throw StateError(
            'Pending provider mutation has no intact credential state',
          );
        }
        await _store.rollbackProviderMutation(lease);
        continue;
      }
      await _deleteExistingRefs(
        credentials,
        descriptor.previousCredentialRefs.values.where(
          (ref) => !newRefs.contains(ref),
        ),
        existingAccounts,
      );
      await _store.finalizeProviderMutation(lease);
    }
    await _cleanupUnreferencedCredentials(
      credentials,
      metadata,
      existingAccounts,
    );
  }

  Future<void> _deleteExistingRefs(
    SecureCredentialStore credentials,
    Iterable<SecretRef> refs,
    Set<String> existingAccounts,
  ) async {
    for (final ref in refs) {
      final account = _account(ref);
      if (!existingAccounts.contains(account)) continue;
      final deleted = await credentials.delete(ref);
      if (!deleted) {
        throw StateError('Provider credential cleanup remains pending');
      }
      existingAccounts.remove(account);
    }
  }

  Future<void> _cleanupUnreferencedCredentials(
    SecureCredentialStore credentials,
    List<SecureCredentialMetadata> metadata,
    Set<String> existingAccounts,
  ) async {
    final referencedAccounts = <String>{};
    for (final config in await _store.loadAll()) {
      referencedAccounts.addAll(
        providerCredentialBindings(config).values.map(_account),
      );
    }
    for (final operation in await _store.listPendingProviderOperations()) {
      referencedAccounts.addAll(
        operation.previousCredentialRefs.values.map(_account),
      );
      referencedAccounts.addAll(
        operation.nextCredentialRefs.values.map(_account),
      );
    }
    for (final item in metadata) {
      if (item.service != ProviderSecretRefPolicy.service ||
          referencedAccounts.contains(item.account) ||
          !existingAccounts.contains(item.account)) {
        continue;
      }
      final ref = SecretRef.parse(
        'keychain://${ProviderSecretRefPolicy.service}/${item.account}',
      );
      ProviderSecretRefPolicy.validate(ref);
      final deleted = await credentials.delete(ref);
      if (!deleted) {
        throw StateError('Provider credential orphan cleanup remains pending');
      }
      existingAccounts.remove(item.account);
    }
  }
}

String _account(SecretRef ref) {
  ProviderSecretRefPolicy.validate(ref);
  return ref.locator.pathSegments.single;
}

ModelRef _defaultModel(String providerId) => switch (providerId) {
  'toapis' => ModelRef(providerId: providerId, modelId: 'gpt-5-mini'),
  'deepseek' => ModelRef(providerId: providerId, modelId: 'deepseek-chat'),
  _ => throw StateError('Provider is not enabled for production chat'),
};
