import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_models.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_support.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_transport.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

class ProviderHealthProbe {
  ProviderHealthProbe({
    required Iterable<ProviderConfig> configs,
    required this.transport,
    required this.secretResolver,
    DateTime Function()? now,
  }) : _configs = indexInspectionConfigs(configs),
       _now = now ?? defaultInspectionNow;

  final Map<String, ProviderConfig> _configs;
  final ProviderInspectionTransport transport;
  final SecretResolver secretResolver;
  final DateTime Function() _now;

  Future<ProviderHealthReport> probe(
    String providerId, {
    CancellationToken? cancellationToken,
  }) async {
    final config = requireInspectionConfig(_configs, providerId);
    final token = cancellationToken ?? CancellationToken();
    if (token.isCancelled) {
      throw inspectionCancelled();
    }

    late final ProviderInspectionRequest request;
    try {
      request = await buildInspectionRequest(
        config: config,
        secretResolver: secretResolver,
        cancellationToken: token,
        now: _now,
      );
    } on ModelRuntimeException catch (error) {
      if (error.code == ModelRuntimeErrorCode.streamInterrupted) {
        rethrow;
      }
      return _report(providerId, ProviderHealthStatus.authFailed);
    }

    try {
      final result = await awaitInspectionOrCancellation(
        transport.probeHealth(request),
        token,
      );
      return _report(providerId, _statusFor(result.statusCode));
    } on ModelRuntimeException catch (error) {
      if (error.code == ModelRuntimeErrorCode.streamInterrupted) {
        rethrow;
      }
      return _report(providerId, ProviderHealthStatus.degraded);
    } catch (_) {
      return _report(providerId, ProviderHealthStatus.degraded);
    }
  }

  ProviderHealthReport _report(
    String providerId,
    ProviderHealthStatus status,
  ) => ProviderHealthReport(
    providerId: providerId,
    status: status,
    checkedAt: _now(),
  );

  ProviderHealthStatus _statusFor(int? statusCode) => switch (statusCode) {
    null => ProviderHealthStatus.configured,
    >= 200 && <= 299 => ProviderHealthStatus.reachable,
    401 || 403 => ProviderHealthStatus.authFailed,
    402 => ProviderHealthStatus.quotaLimited,
    429 => ProviderHealthStatus.rateLimited,
    >= 500 && <= 599 => ProviderHealthStatus.degraded,
    _ => ProviderHealthStatus.unknown,
  };
}
