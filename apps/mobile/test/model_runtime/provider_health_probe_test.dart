import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_provider_inspection_transport.dart';
import 'package:halo_mobile/model_runtime/testing/fake_secret_resolver.dart';

void main() {
  test('health maps only the public provider status vocabulary', () async {
    final cases = <int?, ProviderHealthStatus>{
      null: ProviderHealthStatus.configured,
      200: ProviderHealthStatus.reachable,
      401: ProviderHealthStatus.authFailed,
      403: ProviderHealthStatus.authFailed,
      402: ProviderHealthStatus.quotaLimited,
      429: ProviderHealthStatus.rateLimited,
      503: ProviderHealthStatus.degraded,
      418: ProviderHealthStatus.unknown,
    };

    for (final entry in cases.entries) {
      final transport = FakeProviderInspectionTransport()
        ..enqueueProbe(
          ProviderHealthTransportResult(
            statusCode: entry.key,
            unsafeBody: 'Authorization sk-health upstream body',
          ),
        );
      final report = await _probe(
        configs: [ProviderConfig.toApis()],
        transport: transport,
      ).probe('toapis');

      expect(report.status, entry.value, reason: '${entry.key}');
      expect(report.toString(), isNot(contains('sk-health')));
      expect(report.toString(), isNot(contains('upstream body')));
    }
  });

  test(
    'health transport failures degrade without exposing exception text',
    () async {
      final transport = FakeProviderInspectionTransport()
        ..enqueueProbeError(
          StateError('Authorization Bearer sk-probe-secret upstream body'),
        );

      final report = await _probe(
        configs: [ProviderConfig.openAI()],
        transport: transport,
      ).probe('openai');

      expect(report.status, ProviderHealthStatus.degraded);
      expect(report.toString(), isNot(contains('sk-probe-secret')));
    },
  );

  test('health cancellation terminates a pending probe safely', () async {
    final upstream = Completer<ProviderHealthTransportResult>();
    final token = CancellationToken();
    final transport = FakeProviderInspectionTransport()
      ..enqueueProbeFuture(upstream.future);
    final future = _probe(
      configs: [ProviderConfig.toApis()],
      transport: transport,
    ).probe('toapis', cancellationToken: token);

    await Future<void>.delayed(Duration.zero);
    token.cancel();

    await expectLater(
      future.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.streamInterrupted,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(transport.cancelledProbeCallCount, 1);
  });

  test(
    'health cancellation interrupts pending credential resolution',
    () async {
      final token = CancellationToken();
      final probe = ProviderHealthProbe(
        configs: [
          ProviderConfig.toApis(
            secretRef: SecretRef.parse('memory://test/pending-health'),
          ),
        ],
        transport: FakeProviderInspectionTransport(),
        secretResolver: _PendingSecretResolver(),
      );

      final future = probe.probe('toapis', cancellationToken: token);
      await Future<void>.delayed(Duration.zero);
      token.cancel();

      await expectLater(
        future.timeout(const Duration(seconds: 1)),
        throwsA(_code(ModelRuntimeErrorCode.streamInterrupted)),
      );
    },
  );

  test(
    'health rejects unknown and disabled providers before probing',
    () async {
      final transport = FakeProviderInspectionTransport();
      final probe = _probe(
        configs: [ProviderConfig.toApis(enabled: false)],
        transport: transport,
      );

      await expectLater(
        probe.probe('missing'),
        throwsA(_code(ModelRuntimeErrorCode.providerNotFound)),
      );
      await expectLater(
        probe.probe('toapis'),
        throwsA(_code(ModelRuntimeErrorCode.providerDisabled)),
      );
      expect(transport.probeCallCount, 0);
    },
  );

  test(
    'health credential validation and report use the injected clock',
    () async {
      final ref = SecretRef.parse('memory://test/health-clock');
      final resolver = FakeSecretResolver()
        ..put(
          ref,
          EphemeralCredential(
            value: 'expired-at-injected-time',
            expiresAt: DateTime.utc(2027),
          ),
        );
      final transport = FakeProviderInspectionTransport();
      final probe = ProviderHealthProbe(
        configs: [ProviderConfig.toApis(secretRef: ref)],
        transport: transport,
        secretResolver: resolver,
        now: () => DateTime.utc(2030),
      );

      final report = await probe.probe('toapis');

      expect(report.status, ProviderHealthStatus.authFailed);
      expect(report.checkedAt, DateTime.utc(2030));
      expect(transport.probeCallCount, 0);
    },
  );

  test('fake inspection records never retain credential values', () async {
    final ref = SecretRef.parse('memory://test/toapis');
    final resolver = FakeSecretResolver()
      ..put(
        ref,
        EphemeralCredential(
          value: 'credential-must-not-be-recorded',
          expiresAt: DateTime.utc(2099),
        ),
      );
    final transport = FakeProviderInspectionTransport()
      ..enqueueProbe(const ProviderHealthTransportResult(statusCode: 200));
    final probe = ProviderHealthProbe(
      configs: [ProviderConfig.toApis(secretRef: ref)],
      transport: transport,
      secretResolver: resolver,
    );

    await probe.probe('toapis');

    expect(transport.records.single.hadCredential, isTrue);
    expect(
      transport.records.single.toString(),
      isNot(contains('credential-must-not-be-recorded')),
    );
  });
}

ProviderHealthProbe _probe({
  required Iterable<ProviderConfig> configs,
  required FakeProviderInspectionTransport transport,
}) => ProviderHealthProbe(
  configs: configs,
  transport: transport,
  secretResolver: FakeSecretResolver(),
);

Matcher _code(ModelRuntimeErrorCode code) =>
    isA<ModelRuntimeException>().having((error) => error.code, 'code', code);

class _PendingSecretResolver implements SecretResolver {
  final Completer<EphemeralCredential?> _pending =
      Completer<EphemeralCredential?>();

  @override
  Future<EphemeralCredential?> resolve(SecretRef ref) => _pending.future;
}
