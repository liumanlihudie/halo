import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';

void main() {
  test('built-in provider contracts preserve identity and native protocol', () {
    final configs = [
      ProviderConfig.toApis(),
      ProviderConfig.deepSeek(),
      ProviderConfig.openAI(),
      ProviderConfig.anthropic(),
      ProviderConfig.gemini(),
    ];

    expect(
      configs
          .map(
            (config) =>
                '${config.providerId}:${config.kind.name}:${config.protocol.name}',
          )
          .toList(),
      const [
        'toapis:toApis:openAICompatible',
        'deepseek:deepSeek:openAICompatible',
        'openai:openAI:openAI',
        'anthropic:anthropic:anthropic',
        'gemini:gemini:gemini',
      ],
    );
    expect(configs.map((config) => config.enabled), everyElement(isTrue));
    expect(configs.map((config) => config.secretRef), everyElement(isNull));
    expect(configs.first.baseUri, Uri.parse('https://toapis.com/v1'));
  });

  test('safe config output never serializes secret locators', () {
    final config = ProviderConfig.customOpenAICompatible(
      providerId: 'office-gateway',
      displayName: 'Office Gateway',
      baseUri: Uri.parse('https://models.example.com/v1'),
      secretRef: SecretRef.parse('vault://provider/office-gateway'),
      headerSecretRefs: {
        'X-Tenant-Token': SecretRef.parse(
          'keychain://provider/office-gateway/tenant',
        ),
      },
    );

    final safeJson = config.toSafeJson();
    expect(safeJson['hasSecret'], isTrue);
    expect(safeJson['secretScheme'], 'vault');
    expect(safeJson['headerSecretNames'], const ['X-Tenant-Token']);
    expect(safeJson.toString(), isNot(contains('office-gateway/tenant')));
    expect(safeJson.toString(), isNot(contains('vault://provider')));
    expect(safeJson, isNot(contains('secretRef')));
    expect(safeJson, isNot(contains('headerSecretRefs')));
  });

  test('safe config output redacts arbitrary endpoint paths', () {
    final config = ProviderConfig.customOpenAICompatible(
      providerId: 'secret-path',
      displayName: 'Secret path',
      baseUri: Uri.parse(
        'https://models.example.com:8443/v1/sk-path-secret/private',
      ),
    );

    final safeJson = config.toSafeJson();
    expect(safeJson['baseOrigin'], 'https://models.example.com:8443');
    expect(safeJson['basePath'], '/***/');
    expect(safeJson.toString(), isNot(contains('sk-path-secret')));
    expect(safeJson.toString(), isNot(contains('/v1/')));
  });

  test('custom compatible config rejects insecure HTTP unless confirmed', () {
    expect(
      () => ProviderConfig.customOpenAICompatible(
        providerId: 'lan-models',
        displayName: 'LAN Models',
        baseUri: Uri.parse('http://192.168.1.20:11434/v1'),
      ),
      throwsArgumentError,
    );

    final confirmed = ProviderConfig.customOpenAICompatible(
      providerId: 'lan-models',
      displayName: 'LAN Models',
      baseUri: Uri.parse('http://192.168.1.20:11434/v1'),
      allowInsecureHttp: true,
    );

    expect(confirmed.allowInsecureHttp, isTrue);
  });

  test('provider base URL cannot embed credentials', () {
    expect(
      () => ProviderConfig.customOpenAICompatible(
        providerId: 'unsafe-endpoint',
        displayName: 'Unsafe endpoint',
        baseUri: Uri.parse('https://sk-user:plain-secret@example.com/v1'),
      ),
      throwsArgumentError,
    );
  });

  test('explicit insecure confirmation allows only HTTP', () {
    for (final scheme in ['ftp', 'ws', 'wss', 'file']) {
      expect(
        () => ProviderConfig.customOpenAICompatible(
          providerId: '$scheme-endpoint',
          displayName: '$scheme endpoint',
          baseUri: Uri.parse('$scheme://models.example.com/v1'),
          allowInsecureHttp: true,
        ),
        throwsArgumentError,
        reason: scheme,
      );
    }
  });

  test('header secret names must be RFC token values', () {
    final ref = SecretRef.parse('memory://test/header');
    for (final headerName in [
      '',
      'X Header',
      'X-Test\r\nAuthorization',
      'X-Test:Injected',
      ' X-Test',
    ]) {
      expect(
        () => ProviderConfig.customOpenAICompatible(
          providerId: 'bad-header',
          displayName: 'Bad header',
          baseUri: Uri.parse('https://models.example.com/v1'),
          headerSecretRefs: {headerName: ref},
        ),
        throwsArgumentError,
        reason: headerName,
      );
    }
  });
}
