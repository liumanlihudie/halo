enum ModelRuntimeErrorCode {
  invalidRequest,
  unsupportedEndpoint,
  invalidCredential,
  insufficientBalance,
  modelNotAllowed,
  modelNotFound,
  assetTooLarge,
  contentRejected,
  rateLimited,
  providerUnavailable,
  streamInterrupted,
  providerNotFound,
  providerDisabled,
  unsupportedCapability,
  unsupportedProtocol,
  invalidConfiguration,
  transportFailure,
  malformedResponse,
}

class ModelRuntimeException implements Exception {
  const ModelRuntimeException({
    required this.code,
    required this.safeMessage,
    required this.retryable,
    this.httpStatus,
    this.retryAfter,
  });

  final ModelRuntimeErrorCode code;
  final String safeMessage;
  final bool retryable;
  final int? httpStatus;
  final Duration? retryAfter;

  @override
  String toString() => 'ModelRuntimeException(${code.name}): $safeMessage';
}

abstract final class ModelRuntimeErrorMapper {
  static ModelRuntimeException fromHttpStatus(
    int statusCode, {
    Duration? retryAfter,
  }) {
    final (code, message, retryable) = switch (statusCode) {
      400 => (ModelRuntimeErrorCode.invalidRequest, '请求参数无效', false),
      401 => (ModelRuntimeErrorCode.invalidCredential, '模型服务凭证无效', false),
      402 => (ModelRuntimeErrorCode.insufficientBalance, '模型服务额度不足', false),
      403 => (ModelRuntimeErrorCode.modelNotAllowed, '当前模型不可用', false),
      404 => (ModelRuntimeErrorCode.modelNotFound, '未找到当前模型', false),
      413 => (ModelRuntimeErrorCode.assetTooLarge, '输入内容过大', false),
      422 => (ModelRuntimeErrorCode.contentRejected, '内容未通过模型服务检查', false),
      429 => (ModelRuntimeErrorCode.rateLimited, '请求过于频繁，请稍后再试', true),
      >= 500 && <= 599 => (
        ModelRuntimeErrorCode.providerUnavailable,
        '模型服务暂时不可用',
        true,
      ),
      _ => (ModelRuntimeErrorCode.transportFailure, '模型服务请求失败', false),
    };
    return ModelRuntimeException(
      code: code,
      safeMessage: message,
      retryable: retryable,
      httpStatus: statusCode,
      retryAfter: retryAfter,
    );
  }
}
