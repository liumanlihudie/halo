import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_provider_inspection_transport.dart';
import 'package:halo_mobile/model_runtime/testing/fake_secret_resolver.dart';

void main() {
  test(
    'catalog binds provider refs then sorts and deduplicates models',
    () async {
      final transport = FakeProviderInspectionTransport()
        ..enqueueCatalog(
          ProviderCatalogTransportResult(
            models: [
              _raw(
                'toapis',
                'z-model',
                'Zulu',
                hints: const {
                  'supports_chat': true,
                  'supports_system': true,
                  'supports_temperature': false,
                  'max_output_tokens': 4096,
                },
              ),
              _raw(
                'toapis',
                'a-model',
                'Alpha',
                hints: const {
                  'supports_chat': true,
                  'supports_system': false,
                  'supports_temperature': true,
                  'max_output_tokens': 2048,
                },
              ),
              _raw('toapis', 'a-model', 'Duplicate ignored'),
            ],
          ),
        );
      final discovery = _discovery(
        configs: [
          ProviderConfig.toApis(
            secretRef: SecretRef.parse('memory://test/toapis'),
          ),
        ],
        transport: transport,
      );

      final snapshot = await discovery.discover('toapis');

      expect(snapshot.providerId, 'toapis');
      expect(snapshot.models.map((model) => model.ref.modelId), [
        'a-model',
        'z-model',
      ]);
      expect(
        snapshot.models.every((model) => model.ref.providerId == 'toapis'),
        isTrue,
      );
      expect(snapshot.models.first.capabilities.systemMessages, isFalse);
      expect(snapshot.models.first.capabilities.supportsTemperature, isTrue);
      expect(snapshot.models.first.capabilities.maxOutputTokens, 2048);
      expect(transport.records.single.hadCredential, isTrue);
      expect(
        transport.records.single.toString(),
        isNot(contains('test-toapis-credential')),
      );
    },
  );

  test(
    'native protocols use only their own capability hint boundary',
    () async {
      final cases = [
        (
          ProviderConfig.openAI(),
          const {
            'chat_completions': true,
            'system_messages': true,
            'temperature': false,
            'supports_chat': false,
            'max_output_tokens': 1000,
          },
        ),
        (
          ProviderConfig.anthropic(),
          const {
            'messages': true,
            'system_messages': true,
            'temperature': true,
            'supports_chat': false,
            'max_output_tokens': 2000,
          },
        ),
        (
          ProviderConfig.gemini(),
          const {
            'generate_content': true,
            'system_instruction': false,
            'temperature': true,
            'supports_chat': false,
            'max_output_tokens': 3000,
          },
        ),
      ];

      for (final (config, hints) in cases) {
        final transport = FakeProviderInspectionTransport()
          ..enqueueCatalog(
            ProviderCatalogTransportResult(
              models: [
                _raw(config.providerId, 'native-model', 'Native', hints: hints),
              ],
            ),
          );
        final snapshot = await _discovery(
          configs: [config],
          transport: transport,
        ).discover(config.providerId);
        final capabilities = snapshot.models.single.capabilities;

        expect(capabilities.textGeneration, isTrue, reason: config.providerId);
        expect(
          capabilities.maxOutputTokens,
          hints['max_output_tokens'],
          reason: config.providerId,
        );
        if (config.protocol == ProviderProtocol.openAI) {
          expect(capabilities.supportsTemperature, isFalse);
        }
        if (config.protocol == ProviderProtocol.gemini) {
          expect(capabilities.systemMessages, isFalse);
        }
      }
    },
  );

  test(
    'custom OpenAI-compatible providers use compatible capability hints',
    () async {
      final config = ProviderConfig.customOpenAICompatible(
        providerId: 'private-gateway',
        displayName: 'Private Gateway',
        baseUri: Uri.parse('https://models.example.test/v1'),
      );
      final transport = FakeProviderInspectionTransport()
        ..enqueueCatalog(
          ProviderCatalogTransportResult(
            models: [
              _raw(
                'private-gateway',
                'private-chat',
                'Private Chat',
                hints: const {
                  'supports_chat': true,
                  'supports_system': true,
                  'supports_temperature': false,
                  'chat_completions': false,
                  'max_output_tokens': 8192,
                },
              ),
            ],
          ),
        );

      final model = (await _discovery(
        configs: [config],
        transport: transport,
      ).discover(config.providerId)).models.single;

      expect(
        model.ref,
        ModelRef(providerId: 'private-gateway', modelId: 'private-chat'),
      );
      expect(model.capabilities.textGeneration, isTrue);
      expect(model.capabilities.systemMessages, isTrue);
      expect(model.capabilities.supportsTemperature, isFalse);
      expect(model.capabilities.maxOutputTokens, 8192);
    },
  );

  test('catalog rejects unsafe or excessive upstream metadata', () async {
    final invalidResults = [
      ProviderCatalogTransportResult(
        models: [_raw('other', 'model', 'Wrong provider')],
      ),
      ProviderCatalogTransportResult(
        models: [_raw('toapis', List.filled(129, 'x').join(), 'Long id')],
      ),
      ProviderCatalogTransportResult(
        models: [_raw('toapis', 'model', 'unsafe\r\nheader')],
      ),
      for (final unsafe in [
        'line\u2028separator',
        'paragraph\u2029separator',
        'byte\uFEFForder-mark',
        'c1\u0085control',
        'arabic\u061Cletter-mark',
      ])
        ProviderCatalogTransportResult(
          models: [_raw('toapis', 'model', unsafe)],
        ),
      ProviderCatalogTransportResult(
        models: [
          _raw(
            'toapis',
            'model',
            'Oversized',
            hints: const {'supports_chat': true, 'max_output_tokens': 1000001},
          ),
        ],
      ),
      ProviderCatalogTransportResult(
        models: List.generate(
          ModelCatalogDiscovery.maximumModelCount + 1,
          (index) => _raw('toapis', 'model-$index', 'Model $index'),
        ),
      ),
    ];

    for (final result in invalidResults) {
      final transport = FakeProviderInspectionTransport()
        ..enqueueCatalog(result);
      await expectLater(
        _discovery(
          configs: [ProviderConfig.toApis()],
          transport: transport,
        ).discover('toapis'),
        throwsA(_safeError(ModelRuntimeErrorCode.malformedResponse)),
      );
    }
  });

  test(
    'catalog TTL cache and force refresh use deterministic snapshots',
    () async {
      var now = DateTime.utc(2026, 7, 29, 10);
      final transport = FakeProviderInspectionTransport()
        ..enqueueCatalog(
          ProviderCatalogTransportResult(
            models: [_raw('toapis', 'first', 'First')],
          ),
        )
        ..enqueueCatalog(
          ProviderCatalogTransportResult(
            models: [_raw('toapis', 'second', 'Second')],
          ),
        );
      final discovery = _discovery(
        configs: [ProviderConfig.toApis()],
        transport: transport,
        now: () => now,
        ttl: const Duration(minutes: 5),
      );

      final first = await discovery.discover('toapis');
      now = now.add(const Duration(minutes: 4));
      final cached = await discovery.discover('toapis');
      final refreshed = await discovery.discover('toapis', forceRefresh: true);

      expect(first.models.single.ref.modelId, 'first');
      expect(cached.models.single.ref.modelId, 'first');
      expect(cached.fromCache, isTrue);
      expect(refreshed.models.single.ref.modelId, 'second');
      expect(transport.catalogCallCount, 2);
    },
  );

  test('catalog refreshes after its TTL expires', () async {
    var now = DateTime.utc(2026, 7, 29, 10);
    final transport = FakeProviderInspectionTransport()
      ..enqueueCatalog(
        ProviderCatalogTransportResult(
          models: [_raw('toapis', 'before-expiry', 'Before Expiry')],
        ),
      )
      ..enqueueCatalog(
        ProviderCatalogTransportResult(
          models: [_raw('toapis', 'after-expiry', 'After Expiry')],
        ),
      );
    final discovery = _discovery(
      configs: [ProviderConfig.toApis()],
      transport: transport,
      now: () => now,
      ttl: const Duration(minutes: 5),
    );

    await discovery.discover('toapis');
    now = now.add(const Duration(minutes: 5));
    final refreshed = await discovery.discover('toapis');

    expect(refreshed.fromCache, isFalse);
    expect(refreshed.models.single.ref.modelId, 'after-expiry');
    expect(transport.catalogCallCount, 2);
  });

  test('catalog refreshes when the injected clock moves backwards', () async {
    var now = DateTime.utc(2030, 1, 1, 10);
    final transport = FakeProviderInspectionTransport()
      ..enqueueCatalog(
        ProviderCatalogTransportResult(
          models: [_raw('toapis', 'before-rollback', 'Before Rollback')],
        ),
      )
      ..enqueueCatalog(
        ProviderCatalogTransportResult(
          models: [_raw('toapis', 'after-rollback', 'After Rollback')],
        ),
      );
    final discovery = _discovery(
      configs: [ProviderConfig.toApis()],
      transport: transport,
      now: () => now,
    );

    await discovery.discover('toapis');
    now = DateTime.utc(2029, 12, 31, 10);
    final refreshed = await discovery.discover('toapis');

    expect(refreshed.fromCache, isFalse);
    expect(refreshed.models.single.ref.modelId, 'after-rollback');
    expect(transport.catalogCallCount, 2);
  });

  test('concurrent discovery calls share one upstream flight', () async {
    final upstream = Completer<ProviderCatalogTransportResult>();
    final transport = FakeProviderInspectionTransport()
      ..enqueueCatalogFuture(upstream.future);
    final discovery = _discovery(
      configs: [ProviderConfig.toApis()],
      transport: transport,
    );

    final first = discovery.discover('toapis');
    final second = discovery.discover('toapis');
    await Future<void>.delayed(Duration.zero);
    expect(transport.catalogCallCount, 1);

    upstream.complete(
      ProviderCatalogTransportResult(
        models: [_raw('toapis', 'shared', 'Shared')],
      ),
    );
    final results = await Future.wait([first, second]);
    expect(results[0].models.single.ref.modelId, 'shared');
    expect(results[1].models.single.ref.modelId, 'shared');
  });

  test('cancelling the final catalog waiter stops the shared flight', () async {
    final upstream = Completer<ProviderCatalogTransportResult>();
    final token = CancellationToken();
    final transport = FakeProviderInspectionTransport()
      ..enqueueCatalogFuture(upstream.future);
    final future = _discovery(
      configs: [ProviderConfig.toApis()],
      transport: transport,
    ).discover('toapis', cancellationToken: token);

    await Future<void>.delayed(Duration.zero);
    token.cancel();

    await expectLater(
      future.timeout(const Duration(seconds: 1)),
      throwsA(_safeError(ModelRuntimeErrorCode.streamInterrupted)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(transport.cancelledCatalogCallCount, 1);
  });

  test('one cancelled waiter does not stop another shared waiter', () async {
    final upstream = Completer<ProviderCatalogTransportResult>();
    final cancelledToken = CancellationToken();
    final transport = FakeProviderInspectionTransport()
      ..enqueueCatalogFuture(upstream.future);
    final discovery = _discovery(
      configs: [ProviderConfig.toApis()],
      transport: transport,
    );

    final cancelled = discovery.discover(
      'toapis',
      cancellationToken: cancelledToken,
    );
    final remaining = discovery.discover('toapis');
    await Future<void>.delayed(Duration.zero);
    cancelledToken.cancel();
    await expectLater(
      cancelled,
      throwsA(_safeError(ModelRuntimeErrorCode.streamInterrupted)),
    );

    upstream.complete(
      ProviderCatalogTransportResult(
        models: [_raw('toapis', 'remaining', 'Remaining')],
      ),
    );
    expect((await remaining).models.single.ref.modelId, 'remaining');
    expect(transport.catalogCallCount, 1);
    expect(transport.cancelledCatalogCallCount, 0);
  });

  test(
    'catalog cancellation interrupts pending credential resolution',
    () async {
      final token = CancellationToken();
      final discovery = ModelCatalogDiscovery(
        configs: [
          ProviderConfig.toApis(
            secretRef: SecretRef.parse('memory://test/pending'),
          ),
        ],
        transport: FakeProviderInspectionTransport(),
        secretResolver: _PendingSecretResolver(),
      );

      final future = discovery.discover('toapis', cancellationToken: token);
      await Future<void>.delayed(Duration.zero);
      token.cancel();

      await expectLater(
        future.timeout(const Duration(seconds: 1)),
        throwsA(_safeError(ModelRuntimeErrorCode.streamInterrupted)),
      );
    },
  );

  test(
    'catalog atomically rechecks a primary credential after headers resolve',
    () async {
      var now = DateTime.utc(2030, 1, 1, 10);
      final primaryRef = SecretRef.parse('memory://test/primary-toctou');
      final headerRef = SecretRef.parse('memory://test/header-toctou');
      final header = Completer<EphemeralCredential?>();
      final resolver = _ScriptedSecretResolver({
        primaryRef: () async => EphemeralCredential(
          value: 'primary',
          expiresAt: DateTime.utc(2030, 1, 1, 10, 1),
        ),
        headerRef: () => header.future,
      });
      final transport = FakeProviderInspectionTransport();
      final discovery = ModelCatalogDiscovery(
        configs: [
          ProviderConfig.customOpenAICompatible(
            providerId: 'toctou-primary',
            displayName: 'TOCTOU Primary',
            baseUri: Uri.parse('https://models.example.test/v1'),
            secretRef: primaryRef,
            headerSecretRefs: {'X-Secondary-Key': headerRef},
          ),
        ],
        transport: transport,
        secretResolver: resolver,
        now: () => now,
      );

      final future = discovery.discover('toctou-primary');
      await Future<void>.delayed(Duration.zero);
      now = DateTime.utc(2030, 1, 1, 10, 2);
      header.complete(
        EphemeralCredential(
          value: 'header',
          expiresAt: DateTime.utc(2030, 1, 1, 11),
        ),
      );

      await expectLater(
        future,
        throwsA(_safeError(ModelRuntimeErrorCode.invalidCredential)),
      );
      expect(transport.catalogCallCount, 0);
    },
  );

  test(
    'catalog atomically rechecks early headers after later headers resolve',
    () async {
      var now = DateTime.utc(2030, 1, 1, 10);
      final earlyRef = SecretRef.parse('memory://test/early-header');
      final laterRef = SecretRef.parse('memory://test/later-header');
      final later = Completer<EphemeralCredential?>();
      final resolver = _ScriptedSecretResolver({
        earlyRef: () async => EphemeralCredential(
          value: 'early',
          expiresAt: DateTime.utc(2030, 1, 1, 10, 1),
        ),
        laterRef: () => later.future,
      });
      final transport = FakeProviderInspectionTransport();
      final discovery = ModelCatalogDiscovery(
        configs: [
          ProviderConfig.customOpenAICompatible(
            providerId: 'toctou-headers',
            displayName: 'TOCTOU Headers',
            baseUri: Uri.parse('https://models.example.test/v1'),
            headerSecretRefs: {
              'X-Early-Key': earlyRef,
              'X-Later-Key': laterRef,
            },
          ),
        ],
        transport: transport,
        secretResolver: resolver,
        now: () => now,
      );

      final future = discovery.discover('toctou-headers');
      await Future<void>.delayed(Duration.zero);
      now = DateTime.utc(2030, 1, 1, 10, 2);
      later.complete(
        EphemeralCredential(
          value: 'later',
          expiresAt: DateTime.utc(2030, 1, 1, 11),
        ),
      );

      await expectLater(
        future,
        throwsA(_safeError(ModelRuntimeErrorCode.invalidCredential)),
      );
      expect(transport.catalogCallCount, 0);
    },
  );

  test('catalog credential validation uses the injected clock', () async {
    final ref = SecretRef.parse('memory://test/injected-clock');
    final resolver = _ScriptedSecretResolver({
      ref: () async => EphemeralCredential(
        value: 'already-expired',
        expiresAt: DateTime.utc(2027),
      ),
    });
    final transport = FakeProviderInspectionTransport();
    final discovery = ModelCatalogDiscovery(
      configs: [ProviderConfig.toApis(secretRef: ref)],
      transport: transport,
      secretResolver: resolver,
      now: () => DateTime.utc(2030),
    );

    await expectLater(
      discovery.discover('toapis'),
      throwsA(_safeError(ModelRuntimeErrorCode.invalidCredential)),
    );
    expect(transport.catalogCallCount, 0);
  });

  test(
    'catalog rebuilds transport exceptions with a fixed safe error',
    () async {
      final transport = FakeProviderInspectionTransport()
        ..enqueueCatalogError(
          const ModelRuntimeException(
            code: ModelRuntimeErrorCode.invalidCredential,
            safeMessage: 'Authorization Bearer sk-catalog upstream body',
            retryable: false,
          ),
        );

      await expectLater(
        _discovery(
          configs: [ProviderConfig.toApis()],
          transport: transport,
        ).discover('toapis'),
        throwsA(_safeError(ModelRuntimeErrorCode.transportFailure)),
      );
    },
  );

  test('unknown and disabled providers fail before transport', () async {
    final transport = FakeProviderInspectionTransport();
    final discovery = _discovery(
      configs: [ProviderConfig.toApis(enabled: false)],
      transport: transport,
    );

    await expectLater(
      discovery.discover('missing'),
      throwsA(_safeError(ModelRuntimeErrorCode.providerNotFound)),
    );
    await expectLater(
      discovery.discover('toapis'),
      throwsA(_safeError(ModelRuntimeErrorCode.providerDisabled)),
    );
    expect(transport.catalogCallCount, 0);
  });
}

ModelCatalogDiscovery _discovery({
  required Iterable<ProviderConfig> configs,
  required FakeProviderInspectionTransport transport,
  DateTime Function()? now,
  Duration ttl = const Duration(minutes: 5),
}) => ModelCatalogDiscovery(
  configs: configs,
  transport: transport,
  secretResolver: _resolver(),
  ttl: ttl,
  now: now,
);

FakeSecretResolver _resolver() {
  final resolver = FakeSecretResolver();
  for (final name in ['toapis', 'openai', 'anthropic', 'gemini']) {
    final ref = SecretRef.parse('memory://test/$name');
    resolver.put(
      ref,
      EphemeralCredential(
        value: 'test-$name-credential',
        expiresAt: DateTime.utc(2099),
      ),
    );
  }
  return resolver;
}

UpstreamModelMetadata _raw(
  String providerId,
  String modelId,
  String displayName, {
  Map<String, Object?> hints = const {'supports_chat': true},
}) => UpstreamModelMetadata(
  providerId: providerId,
  modelId: modelId,
  displayName: displayName,
  capabilityHints: hints,
);

Matcher _safeError(ModelRuntimeErrorCode code) => isA<ModelRuntimeException>()
    .having((error) => error.code, 'code', code)
    .having(
      (error) => error.toString(),
      'safe',
      allOf(
        isNot(contains('Authorization')),
        isNot(contains('sk-')),
        isNot(contains('upstream body')),
      ),
    );

class _PendingSecretResolver implements SecretResolver {
  final Completer<EphemeralCredential?> _pending =
      Completer<EphemeralCredential?>();

  @override
  Future<EphemeralCredential?> resolve(SecretRef ref) => _pending.future;
}

class _ScriptedSecretResolver implements SecretResolver {
  _ScriptedSecretResolver(this._scripts);

  final Map<SecretRef, Future<EphemeralCredential?> Function()> _scripts;

  @override
  Future<EphemeralCredential?> resolve(SecretRef ref) {
    final script = _scripts[ref];
    if (script == null) return Future.value();
    return script();
  }
}
