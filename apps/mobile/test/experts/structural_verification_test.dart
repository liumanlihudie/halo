import 'dart:convert';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/experts/built_in_experts.dart';
import 'package:halo_mobile/experts/expert_catalog_batch_one.dart';
import 'package:halo_mobile/experts/expert_catalog_batch_two.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';

void main() {
  late _FixedClock clock;
  late VerificationRegistry registry;
  late ExecutableExpertRegistry executableRegistry;
  late ExpertValidationContext context;

  setUp(() {
    clock = _FixedClock(DateTime.utc(2026, 7, 29, 12));
    registry = VerificationRegistry.forTesting(
      utf8.encode('0123456789abcdef0123456789abcdef'),
      clock: clock,
    );
    executableRegistry = ExecutableExpertRegistry(
      gateway: ExpertOutputValidationGateway(verificationRegistry: registry),
    );
    context = ExpertValidationContext(
      runId: 'run-structural',
      turnId: 'turn-1',
      outputId: 'output-1',
    );
  });

  ExecutableExpert executable(String id) =>
      executableRegistry.singleChatById(id)!;

  Map<String, Object?> adviceEnvelope() => const {
    'claimType': 'advice',
    'tense': 'proposed',
    'verified': false,
    'source': 'none',
    'proposedActions': [
      {
        'verb': 'test',
        'target': 'authorized-test-suite',
        'conditions': ['authorized-environment'],
      },
    ],
    'executedFacts': <String>[],
  };

  Map<String, Object?> executionEnvelope() => const {
    'claimType': 'execution',
    'tense': 'completed',
    'verified': true,
    'source': 'authorized-test-run',
    'proposedActions': <Object?>[],
    'executedFacts': ['The test suite passed.'],
  };

  Map<String, Object?> output({
    String analysis = 'A bounded recommendation.',
    Map<String, Object?>? verification,
  }) {
    final envelope = verification ?? adviceEnvelope();
    return {
      'Analysis': analysis,
      'Recommendations': List<Object?>.from(
        envelope['proposedActions']! as List,
      ),
      'Risks': ['Inputs may be incomplete.'],
      'Verification': envelope,
    };
  }

  test('every structural profile uses the same verification envelope', () {
    final structuralProfiles =
        [
          ...BuiltInExperts.all,
          ...ExpertCatalogBatchOne.all,
          ...ExpertCatalogBatchTwo.all,
        ].where(
          (profile) =>
              profile.validationPolicy == ExpertValidationPolicy.structural,
        );

    expect(structuralProfiles, hasLength(22));
    for (final profile in structuralProfiles) {
      expect(
        profile.outputSchema.fields['Verification'],
        OutputValueType.verificationEnvelope,
        reason: profile.id,
      );
      expect(profile.outputSchema.fields, isNot(contains('verified')));
      expect(profile.outputSchema.fields, isNot(contains('source')));
      final prompt = profile.promptPackage.render();
      expect(
        prompt,
        contains('Verification.proposedActions'),
        reason: profile.id,
      );
      expect(prompt, contains('claimType=advice'), reason: profile.id);
      expect(prompt, contains('tense=proposed'), reason: profile.id);
      expect(prompt, contains('verified=false'), reason: profile.id);
      expect(
        prompt,
        contains('Verification.executedFacts'),
        reason: profile.id,
      );
      expect(prompt, contains('claimType=execution'), reason: profile.id);
      expect(prompt, contains('tense=completed'), reason: profile.id);
      expect(prompt, contains('verified=true'), reason: profile.id);
      expect(prompt, contains('可信 receipt'), reason: profile.id);
    }
  });

  test('advice and completed execution are structurally distinct', () {
    expect(executable('ios-engineer').preflightOutput(output()), isTrue);
    expect(
      executable('ios-engineer').preflightOutput(
        output(
          verification: {
            ...executionEnvelope(),
            'verified': false,
            'source': 'none',
          },
        ),
      ),
      isFalse,
    );
  });

  test('top-level proposed actions must match the structured envelope', () {
    expect(
      executable('ios-engineer').preflightOutput({
        ...output(),
        'Recommendations': [
          {
            'verb': 'review',
            'target': 'different-target',
            'conditions': <String>[],
          },
        ],
      }),
      isFalse,
    );
  });

  test(
    'completed execution fails closed without a matching trusted receipt',
    () {
      final candidate = output(verification: executionEnvelope());

      expect(
        executable(
          'ios-engineer',
        ).validateAndProject(candidate, context: context),
        isNull,
      );
    },
  );

  test('verification receipt binds expert context and output digest', () {
    final candidate = output(verification: executionEnvelope());
    final receipt = registry.issue(
      expertId: 'ios-engineer',
      schemaId: 'ios-engineering-review.v1',
      profileVersion: 1,
      context: context,
      output: candidate,
      source: 'authorized-test-run',
      validFor: const Duration(minutes: 5),
    );

    expect(
      executable('qa-test-engineer').validateAndProject(
        candidate,
        context: context,
        verificationReceipt: receipt,
      ),
      isNull,
    );
    expect(
      executable('ios-engineer').validateAndProject(
        {...candidate, 'Analysis': 'Tampered result.'},
        context: context,
        verificationReceipt: receipt,
      ),
      isNull,
    );
    expect(
      executable('ios-engineer').validateAndProject(
        candidate,
        context: ExpertValidationContext(
          runId: 'run-structural',
          turnId: 'turn-2',
          outputId: 'output-1',
        ),
        verificationReceipt: receipt,
      ),
      isNull,
    );
    expect(
      executable('ios-engineer').validateAndProject(
        candidate,
        context: context,
        verificationReceipt: receipt,
      ),
      'The test suite passed.',
    );
  });

  test('verification receipt rejects cross-version fake token and replay', () {
    final candidate = output(verification: executionEnvelope());
    final receipt = registry.issue(
      expertId: 'ios-engineer',
      schemaId: 'ios-engineering-review.v1',
      profileVersion: 1,
      context: context,
      output: candidate,
      source: 'authorized-test-run',
      validFor: const Duration(minutes: 5),
    );

    expect(
      registry.verifyAndConsume(
        expertId: 'ios-engineer',
        schemaId: 'ios-engineering-review.v1',
        profileVersion: 2,
        context: context,
        output: candidate,
        receiptId: receipt.receiptId,
        receiptToken: receipt.token,
      ),
      isFalse,
    );
    final replacement = receipt.token.endsWith('A') ? 'B' : 'A';
    expect(
      registry.verifyAndConsume(
        expertId: 'ios-engineer',
        schemaId: 'ios-engineering-review.v1',
        profileVersion: 1,
        context: context,
        output: candidate,
        receiptId: receipt.receiptId,
        receiptToken: '${receipt.token.substring(0, 42)}$replacement',
      ),
      isFalse,
    );
    expect(
      executable('ios-engineer').validateAndProject(
        candidate,
        context: context,
        verificationReceipt: receipt,
      ),
      'The test suite passed.',
    );
    expect(
      executable('ios-engineer').validateAndProject(
        candidate,
        context: context,
        verificationReceipt: receipt,
      ),
      isNull,
    );
  });

  test('free text is not used as execution proof or rejection evidence', () {
    expect(
      executable('ios-engineer').preflightOutput(
        output(analysis: 'Avoid claiming the phrase "All tests are green."'),
      ),
      isTrue,
    );
  });

  test('user-visible projection never renders unverified execution text', () {
    final candidate = output(
      analysis: 'I ran tests; 100 passed.',
      verification: adviceEnvelope(),
    );
    final expert = executable('ios-engineer');
    final projected = expert.validateAndProject(candidate);

    expect(projected, isNot(contains('I ran tests; 100 passed.')));
    expect(
      projected,
      contains(
        'Proposed action: test authorized-test-suite '
        'when authorized-environment.',
      ),
    );
  });

  test('advice cannot smuggle completed or verified claims in free text', () {
    const maliciousRecommendations = [
      '我已执行部署并验证全部测试通过',
      'Deployment was completed and every check was verified successful.',
      'Ｉ　ａｌｒｅａｄｙ　ｒａｎ　ｔｈｅ　ｔｅｓｔｓ；１００％　ｐａｓｓｅｄ',
    ];

    for (final recommendation in maliciousRecommendations) {
      final candidate = {
        ...output(),
        'Recommendations': [recommendation],
        'Verification': {
          ...adviceEnvelope(),
          'proposedActions': [recommendation],
        },
      };

      expect(
        executable('ios-engineer').validateAndProject(candidate),
        isNull,
        reason: recommendation,
      );
    }

    final unicodeTypedCandidate = {
      ...output(),
      'Recommendations': [
        {'verb': 'verify', 'target': '我已验证全部测试通过', 'conditions': <String>[]},
      ],
      'Verification': {
        ...adviceEnvelope(),
        'proposedActions': [
          {'verb': 'verify', 'target': '我已验证全部测试通过', 'conditions': <String>[]},
        ],
      },
    };
    expect(
      executable('ios-engineer').validateAndProject(unicodeTypedCandidate),
      isNull,
    );
  });

  test(
    'validateAndProject returns an immutable controlled advice projection',
    () {
      final candidate = Map<String, Object?>.from(
        jsonDecode(jsonEncode(output())) as Map,
      );
      final projected = executable(
        'ios-engineer',
      ).validateAndProject(candidate);

      expect(
        projected,
        'Proposed action: test authorized-test-suite '
        'when authorized-environment.',
      );
      candidate['Analysis'] = 'I deployed and verified everything.';
      final envelope = candidate['Verification']! as Map<String, Object?>;
      final actions = envelope['proposedActions']! as List<Object?>;
      (actions.single! as Map<String, Object?>)['target'] = 'tampered-target';
      expect(
        projected,
        'Proposed action: test authorized-test-suite '
        'when authorized-environment.',
      );
    },
  );

  test('validateAndProject snapshots a stateful map before validation', () {
    final good = adviceEnvelope();
    final attack = {
      ...executionEnvelope(),
      'executedFacts': ['ATTACK: deployment and tests completed.'],
    };
    final candidate = _SwitchingVerificationMap(
      output(verification: good),
      good: good,
      attack: attack,
    );

    final projected = executable('ios-engineer').validateAndProject(candidate);

    expect(projected, isNot(contains('ATTACK')));
    expect(
      projected,
      'Proposed action: test authorized-test-suite '
      'when authorized-environment.',
    );
  });

  test('validateAndProject snapshots stateful action lists once', () {
    const safeAction = {
      'verb': 'test',
      'target': 'authorized-test-suite',
      'conditions': ['authorized-environment'],
    };
    const changedAction = {
      'verb': 'verify',
      'target': 'tests-passed',
      'conditions': <String>[],
    };
    final topActions = _SwitchingActionList(safeAction, changedAction);
    final envelopeActions = _SwitchingActionList(safeAction, changedAction);
    final candidate = {
      ...output(),
      'Recommendations': topActions,
      'Verification': {...adviceEnvelope(), 'proposedActions': envelopeActions},
    };

    expect(
      executable('ios-engineer').validateAndProject(candidate),
      'Proposed action: test authorized-test-suite '
      'when authorized-environment.',
    );
  });

  test('completed facts render only after receipt-backed verification', () {
    final candidate = output(
      analysis: 'Untrusted raw execution narrative.',
      verification: executionEnvelope(),
    );
    final receipt = registry.issue(
      expertId: 'ios-engineer',
      schemaId: 'ios-engineering-review.v1',
      profileVersion: 1,
      context: context,
      output: candidate,
      source: 'authorized-test-run',
      validFor: const Duration(minutes: 5),
    );

    expect(executable('ios-engineer').validateAndProject(candidate), isNull);
    final rendered = executable('ios-engineer').validateAndProject(
      candidate,
      context: context,
      verificationReceipt: receipt,
    );
    expect(rendered, 'The test suite passed.');
    expect(rendered, isNot(contains('Untrusted raw execution narrative.')));
    expect(
      executable('ios-engineer').validateAndProject(
        candidate,
        context: context,
        verificationReceipt: receipt,
      ),
      isNull,
    );
  });
}

class _FixedClock implements EvidenceClock {
  _FixedClock(this.value);

  DateTime value;

  @override
  DateTime now() => value;
}

class _SwitchingVerificationMap extends MapBase<String, Object?> {
  _SwitchingVerificationMap(
    Map<String, Object?> source, {
    required this.good,
    required this.attack,
  }) : _source = Map<String, Object?>.from(source);

  final Map<String, Object?> _source;
  final Map<String, Object?> good;
  final Map<String, Object?> attack;
  int _verificationReads = 0;

  @override
  Object? operator [](Object? key) {
    if (key == 'Verification') {
      _verificationReads++;
      return _verificationReads <= 2 ? good : attack;
    }
    return _source[key];
  }

  @override
  void operator []=(String key, Object? value) =>
      throw UnsupportedError('read only');

  @override
  void clear() => throw UnsupportedError('read only');

  @override
  Iterable<String> get keys => _source.keys;

  @override
  Object? remove(Object? key) => throw UnsupportedError('read only');
}

class _SwitchingActionList extends ListBase<Object?> {
  _SwitchingActionList(this.safeAction, this.changedAction);

  final Map<String, Object?> safeAction;
  final Map<String, Object?> changedAction;
  int _reads = 0;

  @override
  int get length => 1;

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  Object? operator [](int index) {
    if (index != 0) return null;
    _reads++;
    return _reads == 1 ? safeAction : changedAction;
  }

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('read only');
}
