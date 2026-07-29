import 'dart:convert';

import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_transport.dart';
import 'package:halo_mobile/model_runtime/runtime_string_validation.dart'
    as validation;
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/unary_http_transport.dart';

final class ProductionProviderInspectionTransport
    implements ProviderInspectionTransport {
  ProductionProviderInspectionTransport({required this.client});

  static const _capabilityHints = <String, Object?>{
    'supports_chat': true,
    'supports_system': true,
    'supports_temperature': true,
  };

  final SecureJsonHttpClient client;

  @override
  Future<ProviderCatalogTransportResult> discoverModels(
    ProviderInspectionRequest request,
  ) async {
    final response = await _sendCatalogRequest(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ModelRuntimeErrorMapper.fromHttpStatus(
        response.statusCode,
        retryAfter: response.retryAfter,
      );
    }

    try {
      final body = response.body;
      final data = body['data'];
      if (body['object'] != 'list' || data is! List<Object?>) {
        throw const FormatException();
      }
      final seen = <String>{};
      final models = <UpstreamModelMetadata>[];
      for (final item in data) {
        if (item is! Map<String, Object?> || item['object'] != 'model') {
          throw const FormatException();
        }
        final modelId = item['id'];
        if (modelId is! String ||
            !_isValidModelId(modelId) ||
            !seen.add(modelId)) {
          throw const FormatException();
        }
        models.add(
          UpstreamModelMetadata(
            providerId: request.config.providerId,
            modelId: modelId,
            displayName: modelId,
            capabilityHints: _capabilityHints,
          ),
        );
      }
      return ProviderCatalogTransportResult(models: models);
    } catch (_) {
      throw _malformedCatalog();
    }
  }

  @override
  Future<ProviderHealthTransportResult> probeHealth(
    ProviderInspectionRequest request,
  ) async {
    final response = await _sendCatalogRequest(request);
    return ProviderHealthTransportResult(statusCode: response.statusCode);
  }

  Future<SecureJsonHttpResponse> _sendCatalogRequest(
    ProviderInspectionRequest request,
  ) async {
    final endpoint = _requireCatalogEndpoint(request.config);
    if (request.cancellationToken.isCancelled) {
      throw _cancelled();
    }
    if (request.headerCredentials.isNotEmpty) {
      throw _invalidCredential();
    }
    final credential = request.credential;
    if (credential == null || !_isValidCredential(credential)) {
      throw _invalidCredential();
    }
    _requireCredentialOutsideEndpoint(endpoint, credential);

    try {
      return await client.getJson(
        endpoint: endpoint,
        headers: {
          'accept': 'application/json',
          'accept-encoding': 'gzip',
          'authorization': 'Bearer ${credential.value}',
        },
        sensitiveHeaderNames: const {'authorization'},
        cancellationToken: request.cancellationToken,
      );
    } on UnaryTransportException catch (error) {
      if (error.code == UnaryTransportErrorCode.cancelled) {
        throw _cancelled();
      }
      if (error.code == UnaryTransportErrorCode.malformedResponse ||
          error.code == UnaryTransportErrorCode.bodyTooLarge) {
        throw _malformedCatalog();
      }
      throw _transportFailure();
    }
  }
}

Uri _requireCatalogEndpoint(ProviderConfig config) {
  if (!config.enabled) {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.providerDisabled,
      safeMessage: '模型服务已停用',
      retryable: false,
    );
  }
  final supported = switch (config.kind) {
    ProviderKind.toApis =>
      config.providerId == 'toapis' &&
          config.protocol == ProviderProtocol.openAICompatible &&
          config.baseUri == ProviderConfig.toApisCanonicalBaseUri,
    ProviderKind.deepSeek =>
      config.providerId == 'deepseek' &&
          config.protocol == ProviderProtocol.openAICompatible &&
          config.baseUri == ProviderConfig.deepSeekCanonicalBaseUri,
    _ => false,
  };
  if (!supported) {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.unsupportedEndpoint,
      safeMessage: '模型目录端点不受支持',
      retryable: false,
    );
  }
  return Uri.parse('${config.baseUri}/models');
}

bool _isValidCredential(EphemeralCredential credential) =>
    credential.isValidAt(DateTime.timestamp()) &&
    utf8.encode(credential.value).length <= 64 * 1024 &&
    !RegExp(r'[\x00-\x1F\x7F]').hasMatch(credential.value);

void _requireCredentialOutsideEndpoint(
  Uri endpoint,
  EphemeralCredential credential,
) {
  final serialized = endpoint.toString();
  String decoded;
  try {
    decoded = Uri.decodeFull(serialized);
  } catch (_) {
    decoded = serialized;
  }
  if (serialized.contains(credential.value) ||
      decoded.contains(credential.value)) {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.unsupportedEndpoint,
      safeMessage: '模型目录端点不受支持',
      retryable: false,
    );
  }
}

bool _isValidModelId(String value) =>
    validation.isSafeRuntimeIdentifier(value, maxUtf8Bytes: 128) &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]*$').hasMatch(value);

ModelRuntimeException _invalidCredential() => const ModelRuntimeException(
  code: ModelRuntimeErrorCode.invalidCredential,
  safeMessage: '模型服务凭证无效',
  retryable: false,
);

ModelRuntimeException _cancelled() => const ModelRuntimeException(
  code: ModelRuntimeErrorCode.streamInterrupted,
  safeMessage: '模型目录请求已取消',
  retryable: false,
);

ModelRuntimeException _malformedCatalog() => const ModelRuntimeException(
  code: ModelRuntimeErrorCode.malformedResponse,
  safeMessage: '模型目录响应无效',
  retryable: false,
);

ModelRuntimeException _transportFailure() => const ModelRuntimeException(
  code: ModelRuntimeErrorCode.transportFailure,
  safeMessage: '模型目录请求失败',
  retryable: true,
);
