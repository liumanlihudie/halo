import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_support.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_transport.dart';

@immutable
class SafeProviderInspectionRecord {
  const SafeProviderInspectionRecord({
    required this.providerId,
    required this.operation,
    required this.hadCredential,
  });

  final String providerId;
  final String operation;
  final bool hadCredential;

  @override
  String toString() =>
      'SafeProviderInspectionRecord(providerId: $providerId, '
      'operation: $operation, hadCredential: $hadCredential)';
}

class FakeProviderInspectionTransport implements ProviderInspectionTransport {
  final Queue<Future<ProviderCatalogTransportResult> Function()>
  _catalogScripts = Queue();
  final Queue<Future<ProviderHealthTransportResult> Function()> _probeScripts =
      Queue();
  final List<SafeProviderInspectionRecord> records = [];
  int catalogCallCount = 0;
  int probeCallCount = 0;
  int cancelledCatalogCallCount = 0;
  int cancelledProbeCallCount = 0;

  void enqueueCatalog(ProviderCatalogTransportResult result) {
    _catalogScripts.add(() => Future.value(result));
  }

  void enqueueCatalogFuture(Future<ProviderCatalogTransportResult> result) {
    _catalogScripts.add(() => result);
  }

  void enqueueCatalogError(Object error) {
    _catalogScripts.add(() => Future.error(error));
  }

  void enqueueProbe(ProviderHealthTransportResult result) {
    _probeScripts.add(() => Future.value(result));
  }

  void enqueueProbeFuture(Future<ProviderHealthTransportResult> result) {
    _probeScripts.add(() => result);
  }

  void enqueueProbeError(Object error) {
    _probeScripts.add(() => Future.error(error));
  }

  @override
  Future<ProviderCatalogTransportResult> discoverModels(
    ProviderInspectionRequest request,
  ) {
    catalogCallCount++;
    records.add(_record(request, 'catalog'));
    if (_catalogScripts.isEmpty) {
      return Future.error(_unscripted());
    }
    return _withCancellation(
      _catalogScripts.removeFirst()(),
      request,
      onCancelled: () => cancelledCatalogCallCount++,
    );
  }

  @override
  Future<ProviderHealthTransportResult> probeHealth(
    ProviderInspectionRequest request,
  ) {
    probeCallCount++;
    records.add(_record(request, 'health'));
    if (_probeScripts.isEmpty) {
      return Future.error(_unscripted());
    }
    return _withCancellation(
      _probeScripts.removeFirst()(),
      request,
      onCancelled: () => cancelledProbeCallCount++,
    );
  }

  Future<T> _withCancellation<T>(
    Future<T> scripted,
    ProviderInspectionRequest request, {
    required void Function() onCancelled,
  }) => Future.any([
    scripted,
    request.cancellationToken.whenCancelled.then<T>((_) {
      onCancelled();
      throw inspectionCancelled();
    }),
  ]);

  SafeProviderInspectionRecord _record(
    ProviderInspectionRequest request,
    String operation,
  ) => SafeProviderInspectionRecord(
    providerId: request.config.providerId,
    operation: operation,
    hadCredential:
        request.credential != null || request.headerCredentials.isNotEmpty,
  );

  ModelRuntimeException _unscripted() => const ModelRuntimeException(
    code: ModelRuntimeErrorCode.transportFailure,
    safeMessage: 'Fake inspection transport is not scripted',
    retryable: false,
  );
}
