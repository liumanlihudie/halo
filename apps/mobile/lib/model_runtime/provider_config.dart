import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/runtime_string_validation.dart'
    as validation;
import 'package:halo_mobile/model_runtime/secret_ref.dart';

enum ProviderKind {
  toApis,
  deepSeek,
  moonshot,
  openAI,
  anthropic,
  gemini,
  customOpenAICompatible,
}

enum ProviderProtocol { openAICompatible, openAI, anthropic, gemini }

bool isCanonicalRuntimeId(String value) =>
    validation.isCanonicalRuntimeId(value);

bool isSafeRuntimeDisplayText(String value) =>
    validation.isSafeRuntimeDisplayText(value);

@immutable
class ProviderConfig {
  static final _headerTokenPattern = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
  static final Uri toApisCanonicalBaseUri = Uri.parse('https://toapis.com/v1');
  static final Uri deepSeekCanonicalBaseUri = Uri.parse(
    'https://api.deepseek.com/v1',
  );

  /// Moonshot (Kimi). OpenAI-compatible chat, so it needs no new protocol.
  static final Uri moonshotCanonicalBaseUri = Uri.parse(
    'https://api.moonshot.cn/v1',
  );
  static final Uri openAICanonicalBaseUri = Uri.parse(
    'https://api.openai.com/v1',
  );
  static final Uri anthropicCanonicalBaseUri = Uri.parse(
    'https://api.anthropic.com/v1',
  );
  static final Uri geminiCanonicalBaseUri = Uri.parse(
    'https://generativelanguage.googleapis.com/v1beta',
  );

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
    if (!isCanonicalRuntimeId(providerId)) {
      throw ArgumentError.value(providerId, 'providerId');
    }
    if (!isSafeRuntimeDisplayText(displayName)) {
      throw ArgumentError.value(displayName, 'displayName');
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
    providerCredentialBindings(this);
  }

  factory ProviderConfig.toApis({bool enabled = true, SecretRef? secretRef}) =>
      ProviderConfig._(
        providerId: 'toapis',
        kind: ProviderKind.toApis,
        protocol: ProviderProtocol.openAICompatible,
        displayName: 'ToAPIs',
        baseUri: toApisCanonicalBaseUri,
        enabled: enabled,
        secretRef: secretRef,
        headerSecretRefs: const {},
        allowInsecureHttp: false,
      );

  factory ProviderConfig.persisted({
    required String providerId,
    required ProviderKind kind,
    required ProviderProtocol protocol,
    required String displayName,
    required Uri baseUri,
    required bool enabled,
    SecretRef? secretRef,
    Map<String, SecretRef> headerSecretRefs = const {},
    required bool allowInsecureHttp,
  }) {
    final (expectedProviderId, expectedProtocol, expectedUri) = switch (kind) {
      ProviderKind.toApis => (
        'toapis',
        ProviderProtocol.openAICompatible,
        toApisCanonicalBaseUri,
      ),
      ProviderKind.deepSeek => (
        'deepseek',
        ProviderProtocol.openAICompatible,
        deepSeekCanonicalBaseUri,
      ),
      ProviderKind.moonshot => (
        'moonshot',
        ProviderProtocol.openAICompatible,
        moonshotCanonicalBaseUri,
      ),
      ProviderKind.openAI => (
        'openai',
        ProviderProtocol.openAI,
        openAICanonicalBaseUri,
      ),
      ProviderKind.anthropic => (
        'anthropic',
        ProviderProtocol.anthropic,
        anthropicCanonicalBaseUri,
      ),
      ProviderKind.gemini => (
        'gemini',
        ProviderProtocol.gemini,
        geminiCanonicalBaseUri,
      ),
      ProviderKind.customOpenAICompatible => (
        null,
        ProviderProtocol.openAICompatible,
        null,
      ),
    };
    const builtInIds = {
      'toapis',
      'deepseek',
      'moonshot',
      'openai',
      'anthropic',
      'gemini',
    };
    final invalidIdentity = expectedProviderId == null
        ? builtInIds.contains(providerId)
        : providerId != expectedProviderId;
    if (invalidIdentity ||
        protocol != expectedProtocol ||
        (expectedUri != null && baseUri != expectedUri)) {
      throw StateError('Invalid persisted provider configuration');
    }
    return ProviderConfig._(
      providerId: providerId,
      kind: kind,
      protocol: protocol,
      displayName: displayName,
      baseUri: baseUri,
      enabled: enabled,
      secretRef: secretRef,
      headerSecretRefs: Map.unmodifiable(headerSecretRefs),
      allowInsecureHttp: allowInsecureHttp,
    );
  }

  factory ProviderConfig.deepSeek({
    bool enabled = true,
    SecretRef? secretRef,
  }) => ProviderConfig._(
    providerId: 'deepseek',
    kind: ProviderKind.deepSeek,
    protocol: ProviderProtocol.openAICompatible,
    displayName: 'DeepSeek',
    baseUri: deepSeekCanonicalBaseUri,
    enabled: enabled,
    secretRef: secretRef,
    headerSecretRefs: const {},
    allowInsecureHttp: false,
  );

  factory ProviderConfig.moonshot({
    bool enabled = true,
    SecretRef? secretRef,
  }) => ProviderConfig._(
    providerId: 'moonshot',
    kind: ProviderKind.moonshot,
    protocol: ProviderProtocol.openAICompatible,
    displayName: 'Kimi (Moonshot)',
    baseUri: moonshotCanonicalBaseUri,
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
        baseUri: openAICanonicalBaseUri,
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
    baseUri: anthropicCanonicalBaseUri,
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
        baseUri: geminiCanonicalBaseUri,
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

  ProviderConfig copyWith({
    bool? enabled,
    SecretRef? secretRef,
    Map<String, SecretRef>? headerSecretRefs,
  }) => ProviderConfig.persisted(
    providerId: providerId,
    kind: kind,
    protocol: protocol,
    displayName: displayName,
    baseUri: baseUri,
    enabled: enabled ?? this.enabled,
    secretRef: secretRef ?? this.secretRef,
    headerSecretRefs: headerSecretRefs ?? this.headerSecretRefs,
    allowInsecureHttp: allowInsecureHttp,
  );

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

Map<String, SecretRef> providerCredentialBindings(ProviderConfig config) {
  final bindings = <String, SecretRef>{};
  final ownersByLocator = <String, String>{};

  void bind(String slot, SecretRef ref) {
    if (bindings.containsKey(slot)) {
      throw ArgumentError.value(
        config.headerSecretRefs,
        'headerSecretRefs',
        'Credential slots are case-insensitively unique',
      );
    }
    final locator = ref.locator.toString();
    final priorSlot = ownersByLocator[locator];
    if (priorSlot != null && priorSlot != slot) {
      throw ArgumentError.value(
        ref,
        'secretRef',
        'A credential reference can belong to only one slot',
      );
    }
    bindings[slot] = ref;
    ownersByLocator[locator] = slot;
  }

  final primary = config.secretRef;
  if (primary != null) bind('primary', primary);
  for (final entry in config.headerSecretRefs.entries) {
    bind('header:${entry.key.toLowerCase()}', entry.value);
  }
  return Map<String, SecretRef>.unmodifiable(bindings);
}
