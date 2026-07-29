import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/experts/built_in_experts.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';

void main() {
  const claim = 'Version 42 shipped.';
  final profile = BuiltInExperts.factChecker;
  late _FixedClock clock;
  late EvidenceTrustRegistry registry;
  late ExpertValidationContext context;

  setUp(() {
    clock = _FixedClock(DateTime.utc(2026, 7, 29, 10));
    registry = EvidenceTrustRegistry.forTesting(
      utf8.encode('0123456789abcdef0123456789abcdef'),
      clock: clock,
    );
    context = ExpertValidationContext(
      runId: 'run-42',
      turnId: 'turn-7',
      outputId: 'output-1',
    );
  });

  Map<String, Object?> unsignedOutput(List<Map<String, Object?>> evidence) => {
    'Claim': claim,
    'Evidence': evidence,
    'Verdict': 'supported',
    'Confidence': 95,
  };

  Map<String, Object?> unsignedEvidence(String sourceId, String quote) => {
    'sourceId': sourceId,
    'ref': 'artifact://$sourceId/result',
    'quoteOrSummary': quote,
    'stance': EvidenceStance.supports.name,
  };

  EvidenceItem issue(Map<String, Object?> rawEvidence, String outputDigest) {
    final receipt = registry.issue(
      expertId: profile.id,
      schemaId: profile.outputSchema.schemaId,
      profileVersion: profile.version,
      context: context,
      validFor: const Duration(minutes: 5),
      outputDigest: outputDigest,
      claimDigest: claimDigestFor(claim),
      sourceId: rawEvidence['sourceId']! as String,
      ref: rawEvidence['ref']! as String,
      stance: EvidenceStance.supports,
      quoteOrSummary: rawEvidence['quoteOrSummary']! as String,
    );
    return EvidenceItem(
      sourceId: rawEvidence['sourceId']! as String,
      ref: rawEvidence['ref']! as String,
      quoteOrSummary: rawEvidence['quoteOrSummary']! as String,
      receiptId: receipt.receiptId,
      receiptToken: receipt.token,
      stance: EvidenceStance.supports,
    );
  }

  TrustedExpertOutputValidator validator({
    String? expertId,
    String? schemaId,
    int? profileVersion,
  }) => TrustedExpertOutputValidator(
    schema: profile.outputSchema,
    trustRegistry: registry,
    expertId: expertId ?? profile.id,
    schemaId: schemaId ?? profile.outputSchema.schemaId,
    profileVersion: profileVersion ?? profile.version,
  );

  test('receipt is strict one shot even for the identical output digest', () {
    final raw = unsignedEvidence('release-notes', 'Version 42 shipped.');
    final unsigned = unsignedOutput([raw]);
    final evidence = issue(raw, expertOutputDigestFor(unsigned));
    final output = unsignedOutput([evidence.toJson()]);

    expect(validator().validate(output, context), isTrue);
    expect(validator().validate(output, context), isFalse);
  });

  test('canonical UTF-8 digest preserves whitespace and line breaks', () {
    final raw = unsignedEvidence('release-notes', 'Line one.\nLine  two.');
    final unsigned = unsignedOutput([raw]);
    final evidence = issue(raw, expertOutputDigestFor(unsigned));

    expect(
      validator().validate(
        unsignedOutput([
          {...evidence.toJson(), 'quoteOrSummary': 'Line one.\nLine two.'},
        ]),
        context,
      ),
      isFalse,
    );
  });

  test('receipt binds expert schema version and validation context', () {
    final raw = unsignedEvidence('release-notes', 'Version 42 shipped.');
    final unsigned = unsignedOutput([raw]);
    final evidence = issue(raw, expertOutputDigestFor(unsigned));
    final output = unsignedOutput([evidence.toJson()]);

    expect(
      validator(expertId: 'other-expert').validate(output, context),
      isFalse,
    );
    expect(
      validator(schemaId: 'other-schema.v1').validate(output, context),
      isFalse,
    );
    expect(validator(profileVersion: 2).validate(output, context), isFalse);
    expect(
      validator().validate(
        output,
        ExpertValidationContext(
          runId: 'run-42',
          turnId: 'turn-8',
          outputId: 'output-1',
        ),
      ),
      isFalse,
    );
    expect(validator().validate(output, context), isTrue);
  });

  test('multi-receipt failure commits none before all receipts verify', () {
    final firstRaw = unsignedEvidence('source-one', 'First source.');
    final secondRaw = unsignedEvidence('source-two', 'Second source.');
    final unsigned = unsignedOutput([firstRaw, secondRaw]);
    final digest = expertOutputDigestFor(unsigned);
    final first = issue(firstRaw, digest);
    final second = issue(secondRaw, digest);
    final validOutput = unsignedOutput([first.toJson(), second.toJson()]);
    final replacement = second.receiptToken.endsWith('A') ? 'B' : 'A';
    final tamperedOutput = unsignedOutput([
      first.toJson(),
      {
        ...second.toJson(),
        'receiptToken': '${second.receiptToken.substring(0, 42)}$replacement',
      },
    ]);

    expect(validator().validate(tamperedOutput, context), isFalse);
    expect(validator().validate(validOutput, context), isTrue);
  });

  test('concurrent consumers atomically allow exactly one winner', () async {
    final raw = unsignedEvidence('release-notes', 'Version 42 shipped.');
    final unsigned = unsignedOutput([raw]);
    final evidence = issue(raw, expertOutputDigestFor(unsigned));
    final output = unsignedOutput([evidence.toJson()]);

    final results = await Future.wait([
      Future(() => validator().validate(output, context)),
      Future(() => validator().validate(output, context)),
    ]);

    expect(results.where((result) => result), hasLength(1));
  });
}

class _FixedClock implements EvidenceClock {
  const _FixedClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}
