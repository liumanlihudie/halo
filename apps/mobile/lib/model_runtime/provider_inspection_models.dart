import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';

@immutable
class ModelCatalogSnapshot {
  ModelCatalogSnapshot({
    required this.providerId,
    required List<ModelDescriptor> models,
    required this.discoveredAt,
    required this.fromCache,
  }) : models = List.unmodifiable(models);

  final String providerId;
  final List<ModelDescriptor> models;
  final DateTime discoveredAt;
  final bool fromCache;

  ModelCatalogSnapshot asCached() => ModelCatalogSnapshot(
    providerId: providerId,
    models: models,
    discoveredAt: discoveredAt,
    fromCache: true,
  );
}

enum ProviderHealthStatus {
  configured,
  reachable,
  authFailed,
  quotaLimited,
  rateLimited,
  degraded,
  unknown,
}

@immutable
class ProviderHealthReport {
  const ProviderHealthReport({
    required this.providerId,
    required this.status,
    required this.checkedAt,
  });

  final String providerId;
  final ProviderHealthStatus status;
  final DateTime checkedAt;

  @override
  String toString() =>
      'ProviderHealthReport(providerId: $providerId, '
      'status: ${status.name})';
}
