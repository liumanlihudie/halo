import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_unary_http_adapter.dart';

void main() {
  const credentialValue = 'catalog-credential-that-must-stay-redacted';
  final credential = EphemeralCredential(
    value: credentialValue,
    expiresAt: DateTime.utc(2099),
  );

  test('a declared non-text model is excluded from the catalog', () async {
    final adapter =
        FakeUnaryHttpAdapter(
          retainSafeHeaderValuesForTesting: true,
          retainRequestContentForTesting: true,
        )..enqueueRaw(
          statusCode: 200,
          bytes: utf8.encode(
            '{"object":"list","data":['
            '{"id":"chat-model","object":"model",'
            '"supported_endpoint_types":["chat_completions"]},'
            '{"id":"image-model","object":"model",'
            '"supported_endpoint_types":["images"]},'
            '{"id":"embedding-model","object":"model",'
            '"supported_endpoint_types":["embeddings"]},'
            // Declares nothing, so it is assumed usable rather than dropped.
            '{"id":"unknown-model","object":"model"}'
            ']}',
          ),
        );
    final transport = _transport(adapter);

    final result = await transport.discoverModels(
      _request(config: ProviderConfig.deepSeek(), credential: credential),
    );

    // An image or embedding model persisted as chat-capable would be offered as
    // the default text model and fail on first use.
    expect(result.models.map((model) => model.modelId), [
      'chat-model',
      'unknown-model',
    ]);
  });

  test(
    'DeepSeek models response becomes confirmed text metadata in order',
    () async {
      final adapter =
          FakeUnaryHttpAdapter(
            retainSafeHeaderValuesForTesting: true,
            retainRequestContentForTesting: true,
          )..enqueueRaw(
            statusCode: 200,
            bytes: utf8.encode(
              '{"object":"list","data":['
              '{"id":"deepseek-chat","object":"model"},'
              '{"id":"deepseek-reasoner","object":"model"}'
              ']}',
            ),
          );
      final transport = _transport(adapter);
      final request = _request(
        config: ProviderConfig.deepSeek(),
        credential: credential,
      );

      final result = await transport.discoverModels(request);

      expect(
        result.models
            .map(
              (model) => {
                'providerId': model.providerId,
                'modelId': model.modelId,
                'displayName': model.displayName,
                'capabilityHints': model.capabilityHints,
              },
            )
            .toList(),
        [
          {
            'providerId': 'deepseek',
            'modelId': 'deepseek-chat',
            'displayName': 'deepseek-chat',
            'capabilityHints': {
              'supports_chat': true,
              'supports_system': true,
              'supports_temperature': true,
            },
          },
          {
            'providerId': 'deepseek',
            'modelId': 'deepseek-reasoner',
            'displayName': 'deepseek-reasoner',
            'capabilityHints': {
              'supports_chat': true,
              'supports_system': true,
              'supports_temperature': true,
            },
          },
        ],
      );
      final record = adapter.records.single;
      expect(record.method, 'GET');
      expect(record.path, '/v1/models');
      expect(record.hasBody, isFalse);
      expect(record.contentType, isNull);
      expect(record.accept, 'application/json');
      expect(record.authorizationWasBearer, isTrue);
      expect(record.followRedirects, isFalse);
      expect(record.safeHeaders, isNot(contains('authorization')));
      expect(record.toString(), isNot(contains(credentialValue)));
      expect(request.toString(), isNot(contains(credentialValue)));
    },
  );

  test('enabled ToAPIs requests its exact models endpoint', () async {
    final adapter = FakeUnaryHttpAdapter(retainRequestContentForTesting: true)
      ..enqueueJson(
        statusCode: 200,
        body: {'object': 'list', 'data': <Object?>[]},
      );

    final result = await _transport(
      adapter,
    ).discoverModels(_request(config: ProviderConfig.toApis()));

    expect(result.models, isEmpty);
    expect(adapter.records.single.method, 'GET');
    expect(adapter.records.single.path, '/v1/models');
  });

  test('HTTP 401 429 and 500 map to fixed safe runtime errors', () async {
    final cases =
        <
          ({
            int status,
            ModelRuntimeErrorCode code,
            bool retryable,
            Duration? retryAfter,
          })
        >[
          (
            status: 401,
            code: ModelRuntimeErrorCode.invalidCredential,
            retryable: false,
            retryAfter: null,
          ),
          (
            status: 429,
            code: ModelRuntimeErrorCode.rateLimited,
            retryable: true,
            retryAfter: const Duration(seconds: 9),
          ),
          (
            status: 500,
            code: ModelRuntimeErrorCode.providerUnavailable,
            retryable: true,
            retryAfter: null,
          ),
        ];

    for (final value in cases) {
      final adapter = FakeUnaryHttpAdapter()
        ..enqueueRaw(
          statusCode: value.status,
          headers: value.retryAfter == null
              ? const {}
              : const {'retry-after': '9'},
          bytes: utf8.encode(
            'Authorization Bearer $credentialValue unsafe upstream body',
          ),
        );

      await expectLater(
        _transport(
          adapter,
        ).discoverModels(_request(config: ProviderConfig.deepSeek())),
        throwsA(
          _safeRuntimeError(value.code)
              .having((error) => error.httpStatus, 'status', value.status)
              .having((error) => error.retryable, 'retryable', value.retryable)
              .having(
                (error) => error.retryAfter,
                'retryAfter',
                value.retryAfter,
              ),
        ),
        reason: '${value.status}',
      );
      expect(adapter.callCount, 1);
    }
  });

  test(
    'oversized HTTP error body preserves status mapping without parsing',
    () async {
      final adapter = FakeUnaryHttpAdapter()
        ..enqueueRaw(
          statusCode: 429,
          headers: const {'retry-after': '11'},
          bytes: List<int>.filled(
            SecureJsonHttpClient.maximumBodyBytes + 1,
            0x61,
          ),
        );

      await expectLater(
        _transport(
          adapter,
        ).discoverModels(_request(config: ProviderConfig.deepSeek())),
        throwsA(
          _safeRuntimeError(ModelRuntimeErrorCode.rateLimited)
              .having((error) => error.httpStatus, 'status', 429)
              .having(
                (error) => error.retryAfter,
                'retryAfter',
                const Duration(seconds: 11),
              ),
        ),
      );
    },
  );

  test('malformed response roots fail with a fixed safe error', () async {
    final bodies = <List<int>>[
      utf8.encode('["not-a-map"]'),
      utf8.encode('{"object":"list","data":"not-a-list"}'),
      utf8.encode('{"object":"not-a-list","data":[]}'),
    ];

    for (final body in bodies) {
      final adapter = FakeUnaryHttpAdapter()
        ..enqueueRaw(statusCode: 200, bytes: body);

      await expectLater(
        _transport(
          adapter,
        ).discoverModels(_request(config: ProviderConfig.deepSeek())),
        throwsA(_safeRuntimeError(ModelRuntimeErrorCode.malformedResponse)),
      );
    }
  });

  test('catalog items require the model object discriminator', () async {
    final items = <Map<String, Object?>>[
      {'id': 'deepseek-chat'},
      {'id': 'deepseek-chat', 'object': 'not-a-model'},
    ];

    for (final item in items) {
      final adapter = FakeUnaryHttpAdapter()
        ..enqueueJson(
          statusCode: 200,
          body: {
            'object': 'list',
            'data': [item],
          },
        );

      await expectLater(
        _transport(
          adapter,
        ).discoverModels(_request(config: ProviderConfig.deepSeek())),
        throwsA(_safeRuntimeError(ModelRuntimeErrorCode.malformedResponse)),
      );
    }
  });

  test('missing and invalid model IDs fail closed', () async {
    final dataCases = <List<Object?>>[
      [
        {'object': 'model'},
      ],
      [
        {'id': '', 'object': 'model'},
      ],
      [
        {'id': ' model-with-space ', 'object': 'model'},
      ],
      ['not-an-object'],
    ];

    for (final data in dataCases) {
      final adapter = FakeUnaryHttpAdapter()
        ..enqueueJson(statusCode: 200, body: {'object': 'list', 'data': data});

      await expectLater(
        _transport(
          adapter,
        ).discoverModels(_request(config: ProviderConfig.deepSeek())),
        throwsA(_safeRuntimeError(ModelRuntimeErrorCode.malformedResponse)),
      );
    }
  });

  test(
    'duplicate model IDs fail instead of being silently collapsed',
    () async {
      final adapter = FakeUnaryHttpAdapter()
        ..enqueueJson(
          statusCode: 200,
          body: {
            'object': 'list',
            'data': [
              {'id': 'deepseek-chat', 'object': 'model'},
              {'id': 'deepseek-chat', 'object': 'model'},
            ],
          },
        );

      await expectLater(
        _transport(
          adapter,
        ).discoverModels(_request(config: ProviderConfig.deepSeek())),
        throwsA(_safeRuntimeError(ModelRuntimeErrorCode.malformedResponse)),
      );
    },
  );

  test('unsupported or disabled configs fail before HTTP dispatch', () async {
    final cases = [
      (
        config: ProviderConfig.customOpenAICompatible(
          providerId: 'wrong-endpoint',
          displayName: 'Wrong Endpoint',
          baseUri: Uri.parse('https://api.deepseek.com/not-v1'),
        ),
        code: ModelRuntimeErrorCode.unsupportedEndpoint,
      ),
      (
        config: ProviderConfig.openAI(),
        code: ModelRuntimeErrorCode.unsupportedEndpoint,
      ),
      (
        config: ProviderConfig.toApis(enabled: false),
        code: ModelRuntimeErrorCode.providerDisabled,
      ),
    ];

    for (final value in cases) {
      final adapter = FakeUnaryHttpAdapter();
      await expectLater(
        _transport(adapter).discoverModels(_request(config: value.config)),
        throwsA(_safeRuntimeError(value.code)),
      );
      expect(adapter.callCount, 0);
    }
  });

  test('cancellation aborts catalog HTTP and returns a safe error', () async {
    final adapter = FakeUnaryHttpAdapter()..enqueuePending();
    final token = CancellationToken();
    final future = _transport(
      adapter,
    ).discoverModels(_request(config: ProviderConfig.deepSeek(), token: token));
    await Future<void>.delayed(Duration.zero);

    token.cancel();

    await expectLater(
      future,
      throwsA(_safeRuntimeError(ModelRuntimeErrorCode.streamInterrupted)),
    );
    expect(adapter.cancellationObserved, isTrue);
  });

  test(
    'credential and upstream error body never enter retained or thrown data',
    () async {
      final adapter =
          FakeUnaryHttpAdapter(
            retainSafeHeaderValuesForTesting: true,
            retainRequestContentForTesting: true,
          )..enqueueRaw(
            statusCode: 500,
            bytes: utf8.encode(
              'Authorization Bearer $credentialValue unsafe upstream body',
            ),
          );
      final request = _request(
        config: ProviderConfig.deepSeek(),
        credential: credential,
      );

      await expectLater(
        _transport(adapter).discoverModels(request),
        throwsA(_safeRuntimeError(ModelRuntimeErrorCode.providerUnavailable)),
      );

      final record = adapter.records.single;
      expect(record.safeHeaders.values, isNot(contains(credentialValue)));
      expect(record.safeHeaders, isNot(contains('authorization')));
      expect(record.body, isEmpty);
      expect(record.toString(), isNot(contains(credentialValue)));
      expect(request.toString(), isNot(contains(credentialValue)));
    },
  );
}

ProductionProviderInspectionTransport _transport(
  FakeUnaryHttpAdapter adapter,
) => ProductionProviderInspectionTransport(
  client: SecureJsonHttpClient(
    adapter: adapter,
    endpointPolicy: _AllowingEndpointPolicy(),
  ),
);

ProviderInspectionRequest _request({
  required ProviderConfig config,
  EphemeralCredential? credential,
  CancellationToken? token,
}) => ProviderInspectionRequest(
  config: config,
  cancellationToken: token ?? CancellationToken(),
  credential:
      credential ??
      EphemeralCredential(
        value: 'fixture-catalog-key',
        expiresAt: DateTime.utc(2099),
      ),
);

TypeMatcher<ModelRuntimeException> _safeRuntimeError(
  ModelRuntimeErrorCode code,
) => isA<ModelRuntimeException>()
    .having((error) => error.code, 'code', code)
    .having(
      (error) => error.toString(),
      'safe output',
      allOf(
        isNot(contains('Authorization')),
        isNot(contains('Bearer')),
        isNot(contains('catalog-credential')),
        isNot(contains('upstream body')),
      ),
    );

class _AllowingEndpointPolicy implements EndpointPolicy {
  @override
  Future<void> validateBeforeConnect(Uri endpoint) async {}

  @override
  void validateAfterConnect(Uri endpoint, InternetAddress remoteAddress) {}
}
