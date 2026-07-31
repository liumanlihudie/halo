import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

@immutable
class UpstreamModelMetadata {
  UpstreamModelMetadata({
    required this.providerId,
    required this.modelId,
    required this.displayName,
    Map<String, Object?> capabilityHints = const {},
    Set<String> declaredModalities = const {},
  }) : capabilityHints = Map.unmodifiable(capabilityHints),
       declaredModalities = Set.unmodifiable(
         declaredModalities.map((type) => type.toLowerCase()),
       );

  final String providerId;
  final String modelId;
  final String displayName;
  final Map<String, Object?> capabilityHints;

  /// Endpoint types the provider declared, lowercased and otherwise verbatim.
  /// Empty when the provider declared nothing — which is not the same as "text
  /// only", and must not be read as such.
  final Set<String> declaredModalities;
}

@immutable
class ProviderCatalogTransportResult {
  ProviderCatalogTransportResult({required List<UpstreamModelMetadata> models})
    : models = List.unmodifiable(models);

  final List<UpstreamModelMetadata> models;
}

@immutable
class ProviderHealthTransportResult {
  const ProviderHealthTransportResult({
    required this.statusCode,
    Object? unsafeBody,
  }) : hasUnsafeBody = unsafeBody != null;

  final int? statusCode;
  final bool hasUnsafeBody;

  @override
  String toString() =>
      'ProviderHealthTransportResult(statusCode: $statusCode, '
      'hasUnsafeBody: $hasUnsafeBody)';
}

@immutable
class ProviderInspectionRequest {
  ProviderInspectionRequest({
    required this.config,
    required this.cancellationToken,
    this.credential,
    Map<String, EphemeralCredential> headerCredentials = const {},
  }) : headerCredentials = Map.unmodifiable(headerCredentials);

  final ProviderConfig config;
  final CancellationToken cancellationToken;
  final EphemeralCredential? credential;
  final Map<String, EphemeralCredential> headerCredentials;

  @override
  String toString() =>
      'ProviderInspectionRequest(providerId: ${config.providerId}, '
      'protocol: ${config.protocol.name}, hasCredential: '
      '${credential != null}, headerCredentialNames: '
      '${headerCredentials.keys.toList()..sort()})';
}

abstract interface class ProviderInspectionTransport {
  Future<ProviderCatalogTransportResult> discoverModels(
    ProviderInspectionRequest request,
  );

  Future<ProviderHealthTransportResult> probeHealth(
    ProviderInspectionRequest request,
  );
}
