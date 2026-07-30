import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_transport.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

DateTime defaultInspectionNow() => DateTime.timestamp();

Map<String, ProviderConfig> indexInspectionConfigs(
  Iterable<ProviderConfig> configs,
) {
  final indexed = <String, ProviderConfig>{};
  for (final config in configs) {
    if (indexed.containsKey(config.providerId)) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.invalidConfiguration,
        safeMessage: '模型服务配置重复',
        retryable: false,
      );
    }
    indexed[config.providerId] = config;
  }
  return Map.unmodifiable(indexed);
}

ProviderConfig requireInspectionConfig(
  Map<String, ProviderConfig> configs,
  String providerId,
) {
  final config = configs[providerId];
  if (config == null) {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.providerNotFound,
      safeMessage: '模型服务不可用',
      retryable: false,
    );
  }
  if (!config.enabled) {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.providerDisabled,
      safeMessage: '模型服务已停用',
      retryable: false,
    );
  }
  return config;
}

Future<ProviderInspectionRequest> buildInspectionRequest({
  required ProviderConfig config,
  required SecretResolver secretResolver,
  required CancellationToken cancellationToken,
  required DateTime Function() now,
}) async {
  try {
    final credential = await resolveOptionalInspectionCredential(
      config.secretRef,
      secretResolver,
      cancellationToken: cancellationToken,
    );
    final headers = <String, EphemeralCredential>{};
    for (final entry in config.headerSecretRefs.entries) {
      final resolved = await awaitInspectionOrCancellation(
        secretResolver.resolve(entry.value),
        cancellationToken,
      );
      if (resolved == null) {
        throw const FormatException();
      }
      headers[entry.key] = resolved;
    }
    final validationInstant = now();
    if ((credential != null && !credential.isValidAt(validationInstant)) ||
        headers.values.any((header) => !header.isValidAt(validationInstant))) {
      throw const FormatException();
    }
    return ProviderInspectionRequest(
      config: config,
      cancellationToken: cancellationToken,
      credential: credential,
      headerCredentials: headers,
    );
  } on ModelRuntimeException catch (error) {
    if (error.code == ModelRuntimeErrorCode.streamInterrupted) {
      rethrow;
    }
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.invalidCredential,
      safeMessage: '模型服务凭证不可用',
      retryable: false,
    );
  } catch (_) {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.invalidCredential,
      safeMessage: '模型服务凭证不可用',
      retryable: false,
    );
  }
}

Future<EphemeralCredential?> resolveOptionalInspectionCredential(
  SecretRef? ref,
  SecretResolver resolver, {
  required CancellationToken cancellationToken,
}) async {
  if (ref == null) return null;
  final credential = await awaitInspectionOrCancellation(
    resolver.resolve(ref),
    cancellationToken,
  );
  if (credential == null) {
    throw const FormatException();
  }
  return credential;
}

ModelRuntimeException inspectionCancelled() => const ModelRuntimeException(
  code: ModelRuntimeErrorCode.streamInterrupted,
  safeMessage: '模型服务检查已取消',
  retryable: false,
);

Future<T> awaitInspectionOrCancellation<T>(
  Future<T> future,
  CancellationToken token,
) {
  if (token.isCancelled) {
    throw inspectionCancelled();
  }
  return Future.any([
    future,
    token.whenCancelled.then<T>((_) => throw inspectionCancelled()),
  ]);
}
