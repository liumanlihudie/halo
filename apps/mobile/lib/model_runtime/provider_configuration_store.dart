import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

@immutable
final class ProviderConfigurationRevision {
  factory ProviderConfigurationRevision(int value) {
    if (value <= 0) throw ArgumentError.value(value, 'value');
    return ProviderConfigurationRevision._(value);
  }

  const ProviderConfigurationRevision._(this.value);

  final int value;

  @override
  bool operator ==(Object other) =>
      other is ProviderConfigurationRevision && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

@immutable
final class PendingProviderOperationId {
  factory PendingProviderOperationId.parse(String value) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw ArgumentError.value(value, 'value');
    }
    return PendingProviderOperationId._(value);
  }

  const PendingProviderOperationId._(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is PendingProviderOperationId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'PendingProviderOperationId([REDACTED])';
}

enum PendingProviderOperationKind { create, replace, rotate, remove }

enum PendingProviderOperationState { pending }

enum PendingProviderTerminalAction { finalize, rollback, restore }

@immutable
final class ProviderModelBindingSnapshot {
  ProviderModelBindingSnapshot({
    this.globalDefault,
    Map<String, ModelRef> agentOverrides = const {},
  }) : agentOverrides = Map.unmodifiable(agentOverrides) {
    if (agentOverrides.keys.any((agentId) => !isCanonicalRuntimeId(agentId))) {
      throw ArgumentError.value(agentOverrides, 'agentOverrides');
    }
  }

  final ModelRef? globalDefault;
  final Map<String, ModelRef> agentOverrides;
}

@immutable
final class PendingProviderOperationDescriptor {
  PendingProviderOperationDescriptor({
    required this.operationId,
    required this.providerId,
    required this.kind,
    required this.revision,
    required this.createdAt,
    required this.previousConfiguration,
    required this.nextConfiguration,
    required this.previousBindings,
    required this.nextBindings,
    required Map<String, SecretRef> previousCredentialRefs,
    required Map<String, SecretRef> nextCredentialRefs,
    required Set<PendingProviderTerminalAction> allowedActions,
  }) : previousCredentialRefs = Map.unmodifiable(previousCredentialRefs),
       nextCredentialRefs = Map.unmodifiable(nextCredentialRefs),
       allowedActions = Set.unmodifiable(allowedActions) {
    final previous = previousConfiguration;
    final next = nextConfiguration;
    final hasValidShape = switch (kind) {
      PendingProviderOperationKind.create => previous == null && next != null,
      PendingProviderOperationKind.replace ||
      PendingProviderOperationKind.rotate => previous != null && next != null,
      PendingProviderOperationKind.remove => previous != null && next == null,
    };
    final expectedPreviousRefs = previous == null
        ? const <String, SecretRef>{}
        : providerCredentialBindings(previous);
    final expectedNextRefs = next == null
        ? const <String, SecretRef>{}
        : providerCredentialBindings(next);
    bool sameRefs(Map<String, SecretRef> left, Map<String, SecretRef> right) =>
        left.length == right.length &&
        left.entries.every((entry) => right[entry.key] == entry.value);
    if (!isCanonicalRuntimeId(providerId) ||
        previous != null && previous.providerId != providerId ||
        next != null && next.providerId != providerId ||
        !hasValidShape ||
        !createdAt.isUtc ||
        createdAt.millisecondsSinceEpoch <= 0 ||
        !sameRefs(this.previousCredentialRefs, expectedPreviousRefs) ||
        !sameRefs(this.nextCredentialRefs, expectedNextRefs)) {
      throw ArgumentError('Invalid pending provider operation descriptor');
    }
    final expectedActions = kind == PendingProviderOperationKind.remove
        ? const {
            PendingProviderTerminalAction.finalize,
            PendingProviderTerminalAction.restore,
          }
        : const {
            PendingProviderTerminalAction.finalize,
            PendingProviderTerminalAction.rollback,
          };
    if (allowedActions.length != expectedActions.length ||
        !allowedActions.containsAll(expectedActions)) {
      throw ArgumentError.value(allowedActions, 'allowedActions');
    }
  }

  final PendingProviderOperationId operationId;
  final String providerId;
  final PendingProviderOperationKind kind;
  final PendingProviderOperationState state =
      PendingProviderOperationState.pending;
  final ProviderConfigurationRevision revision;
  final DateTime createdAt;
  final ProviderConfig? previousConfiguration;
  final ProviderConfig? nextConfiguration;
  final ProviderModelBindingSnapshot previousBindings;
  final ProviderModelBindingSnapshot nextBindings;
  final Map<String, SecretRef> previousCredentialRefs;
  final Map<String, SecretRef> nextCredentialRefs;
  final Set<PendingProviderTerminalAction> allowedActions;

  @override
  String toString() =>
      'PendingProviderOperationDescriptor(providerId: $providerId, '
      'kind: ${kind.name}, state: ${state.name}, revision: ${revision.value}, '
      'previousCredentialCount: ${previousCredentialRefs.length}, '
      'nextCredentialCount: ${nextCredentialRefs.length})';
}

abstract interface class PendingProviderOperationRecovery {
  PendingProviderOperationDescriptor get descriptor;
  ProviderConfigurationMutationLease? get mutationLease;
  ProviderRemovalLease? get removalLease;
}

@immutable
final class VersionedProviderConfiguration {
  const VersionedProviderConfiguration({
    required this.config,
    required this.revision,
  });

  final ProviderConfig config;
  final ProviderConfigurationRevision revision;
}

@immutable
final class ProviderCredentialSlot {
  const ProviderCredentialSlot._(this.value);

  static const primary = ProviderCredentialSlot._('primary');

  factory ProviderCredentialSlot.header(String headerName) {
    if (!RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(headerName)) {
      throw ArgumentError.value(headerName, 'headerName');
    }
    return ProviderCredentialSlot._('header:${headerName.toLowerCase()}');
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is ProviderCredentialSlot && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

abstract interface class ProviderConfigurationMutationLease {
  PendingProviderOperationId get operationId;
  String get providerId;
  ProviderConfigurationRevision get newRevision;
}

abstract interface class ProviderCredentialRotationResult
    implements ProviderConfigurationMutationLease {
  ProviderCredentialSlot get slot;
  SecretRef get oldRefForCleanup;
}

abstract interface class ProviderConfigurationReplacementResult
    implements ProviderConfigurationMutationLease {
  VersionedProviderConfiguration get configuration;
}

@immutable
final class ProviderModelBindingMutation {
  ProviderModelBindingMutation({
    this.replaceGlobalDefault = false,
    this.globalDefault,
    Map<String, ModelRef?> agentOverrides = const {},
  }) : agentOverrides = Map.unmodifiable(agentOverrides) {
    if (!replaceGlobalDefault && globalDefault != null) {
      throw ArgumentError.value(globalDefault, 'globalDefault');
    }
  }

  final bool replaceGlobalDefault;
  final ModelRef? globalDefault;
  final Map<String, ModelRef?> agentOverrides;
}

@immutable
final class ProviderConfigurationReplacement {
  ProviderConfigurationReplacement({
    required this.config,
    ProviderModelBindingMutation? modelBindings,
  }) : modelBindings = modelBindings ?? ProviderModelBindingMutation();

  final ProviderConfig config;
  final ProviderModelBindingMutation modelBindings;
}

abstract interface class ProviderRemovalLease {
  PendingProviderOperationId get operationId;
  String get providerId;
  ProviderConfigurationRevision get removedRevision;
}

enum ProviderConfigurationMutationErrorCode {
  conflict,
  invalidLease,
  restoreFailed,
}

final class ProviderConfigurationMutationException implements Exception {
  const ProviderConfigurationMutationException(this.code);

  final ProviderConfigurationMutationErrorCode code;

  @override
  String toString() => 'Provider configuration mutation failed (${code.name})';
}

abstract interface class ProviderConfigurationStore {
  Future<List<ProviderConfig>> loadEnabled();

  Future<List<ProviderConfig>> loadAll();

  Future<void> upsert(ProviderConfig config);

  Future<void> remove(String providerId);

  Future<VersionedProviderConfiguration?> loadProvider(String providerId);

  Future<ProviderConfigurationReplacementResult> replaceProviderConfiguration({
    required ProviderConfigurationRevision? expectedRevision,
    required ProviderConfigurationReplacement replacement,
  });

  Future<ProviderCredentialRotationResult> rotateCredential({
    required String providerId,
    required ProviderCredentialSlot slot,
    required ProviderConfigurationRevision expectedRevision,
    required SecretRef expectedOldRef,
    required SecretRef newRef,
    required ProviderConfigurationReplacement replacement,
  });

  Future<ProviderRemovalLease> removeProviderAtomically({
    required String providerId,
    required ProviderConfigurationRevision expectedRevision,
  });

  Future<void> restoreRemovedProvider(ProviderRemovalLease lease);

  Future<void> finalizeProviderRemoval(ProviderRemovalLease lease);

  Future<void> rollbackProviderMutation(
    ProviderConfigurationMutationLease lease,
  );

  Future<void> finalizeProviderMutation(
    ProviderConfigurationMutationLease lease,
  );

  Future<List<PendingProviderOperationDescriptor>>
  listPendingProviderOperations();

  Future<PendingProviderOperationRecovery> recoverPendingProviderOperation({
    required PendingProviderOperationId operationId,
    required String expectedProviderId,
    required PendingProviderOperationKind expectedKind,
  });

  Future<ModelRef?> loadGlobalDefaultModel();

  Future<void> setGlobalDefaultModel(ModelRef? model);

  Future<ModelRef?> loadAgentModelOverride(String agentId);

  Future<Map<String, ModelRef>> loadAgentModelOverrides();

  Future<void> setAgentModelOverride(String agentId, ModelRef? model);

  Future<void> close();
}
