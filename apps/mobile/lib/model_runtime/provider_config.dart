import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

enum ProviderKind {
  toApis,
  deepSeek,
  openAI,
  anthropic,
  gemini,
  customOpenAICompatible,
}

enum ProviderProtocol { openAICompatible, openAI, anthropic, gemini }

@immutable
class ProviderConfig {
  static final _headerTokenPattern = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

  ProviderConfig._({
    required this.providerId,
    required this.kind,
    required this.protocol,
    required this.displayName,
    required this.baseUri,
    required this.enabled,
    required this.secretRef,
    required this.headerSecretRefs,
    required this.allowInsecureHttp,
  }) {
    if (providerId.trim().isEmpty) {
      throw ArgumentError.value(providerId, 'providerId');
    }
    if (!baseUri.hasScheme ||
        baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment) {
      throw ArgumentError.value(baseUri, 'baseUri');
    }
    final validScheme =
        baseUri.scheme == 'https' ||
        (baseUri.scheme == 'http' && allowInsecureHttp);
    if (!validScheme) {
      throw ArgumentError.value(
        baseUri,
        'baseUri',
        'Only HTTPS, or explicitly confirmed HTTP, is allowed',
      );
    }
    for (final headerName in headerSecretRefs.keys) {
      if (!_headerTokenPattern.hasMatch(headerName)) {
        throw ArgumentError.value(
          headerName,
          'headerSecretRefs',
          'Header name must be an RFC token',
        );
      }
    }
  }

  factory ProviderConfig.toApis({bool enabled = true, SecretRef? secretRef}) =>
      ProviderConfig._(
        providerId: 'toapis',
        kind: ProviderKind.toApis,
        protocol: ProviderProtocol.openAICompatible,
        displayName: 'ToAPIs',
        baseUri: Uri.parse('https://toapis.com/v1'),
        enabled: enabled,
        secretRef: secretRef,
        headerSecretRefs: const {},
        allowInsecureHttp: false,
      );

  factory ProviderConfig.deepSeek({
    bool enabled = true,
    SecretRef? secretRef,
  }) => ProviderConfig._(
    providerId: 'deepseek',
    kind: ProviderKind.deepSeek,
    protocol: ProviderProtocol.openAICompatible,
    displayName: 'DeepSeek',
    baseUri: Uri.parse('https://api.deepseek.com/v1'),
    enabled: enabled,
    secretRef: secretRef,
    headerSecretRefs: const {},
    allowInsecureHttp: false,
  );

  factory ProviderConfig.openAI({bool enabled = true, SecretRef? secretRef}) =>
      ProviderConfig._(
        providerId: 'openai',
        kind: ProviderKind.openAI,
        protocol: ProviderProtocol.openAI,
        displayName: 'OpenAI',
        baseUri: Uri.parse('https://api.openai.com/v1'),
        enabled: enabled,
        secretRef: secretRef,
        headerSecretRefs: const {},
        allowInsecureHttp: false,
      );

  factory ProviderConfig.anthropic({
    bool enabled = true,
    SecretRef? secretRef,
  }) => ProviderConfig._(
    providerId: 'anthropic',
    kind: ProviderKind.anthropic,
    protocol: ProviderProtocol.anthropic,
    displayName: 'Anthropic Claude',
    baseUri: Uri.parse('https://api.anthropic.com/v1'),
    enabled: enabled,
    secretRef: secretRef,
    headerSecretRefs: const {},
    allowInsecureHttp: false,
  );

  factory ProviderConfig.gemini({bool enabled = true, SecretRef? secretRef}) =>
      ProviderConfig._(
        providerId: 'gemini',
        kind: ProviderKind.gemini,
        protocol: ProviderProtocol.gemini,
        displayName: 'Google Gemini',
        baseUri: Uri.parse('https://generativelanguage.googleapis.com/v1beta'),
        enabled: enabled,
        secretRef: secretRef,
        headerSecretRefs: const {},
        allowInsecureHttp: false,
      );

  factory ProviderConfig.customOpenAICompatible({
    required String providerId,
    required String displayName,
    required Uri baseUri,
    bool enabled = true,
    SecretRef? secretRef,
    Map<String, SecretRef> headerSecretRefs = const {},
    bool allowInsecureHttp = false,
  }) => ProviderConfig._(
    providerId: providerId,
    kind: ProviderKind.customOpenAICompatible,
    protocol: ProviderProtocol.openAICompatible,
    displayName: displayName,
    baseUri: baseUri,
    enabled: enabled,
    secretRef: secretRef,
    headerSecretRefs: Map.unmodifiable(headerSecretRefs),
    allowInsecureHttp: allowInsecureHttp,
  );

  final String providerId;
  final ProviderKind kind;
  final ProviderProtocol protocol;
  final String displayName;
  final Uri baseUri;
  final bool enabled;
  final SecretRef? secretRef;
  final Map<String, SecretRef> headerSecretRefs;
  final bool allowInsecureHttp;

  Map<String, Object?> toSafeJson() => {
    'providerId': providerId,
    'kind': kind.name,
    'protocol': protocol.name,
    'displayName': displayName,
    'baseOrigin': baseUri.origin,
    'basePath': baseUri.path.isEmpty || baseUri.path == '/' ? '/' : '/***/',
    'enabled': enabled,
    'hasSecret': secretRef != null,
    'secretScheme': secretRef?.scheme,
    'headerSecretNames': headerSecretRefs.keys.toList()..sort(),
    'allowInsecureHttp': allowInsecureHttp,
  };
}
