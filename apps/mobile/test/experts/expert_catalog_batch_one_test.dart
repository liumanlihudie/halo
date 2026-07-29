import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/experts/built_in_experts.dart';
import 'package:halo_mobile/experts/expert_catalog_batch_one.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';

void main() {
  const expectedIds = [
    'content-strategist',
    'growth-marketer',
    'user-researcher',
    'ux-designer',
    'data-analyst',
    'industry-researcher',
    'operations-manager',
    'project-manager',
    'finance-tax-analyst',
    'legal-risk-advisor',
    'localization-specialist',
    'editor-proofreader',
  ];

  test(
    'batch one exposes twelve unique profiles without benchmark collisions',
    () {
      final profiles = ExpertCatalogBatchOne.all;
      final ids = profiles.map((profile) => profile.id).toList();

      expect(ids, expectedIds);
      expect(ids.toSet(), hasLength(12));
      expect(
        ids.toSet().intersection(
          BuiltInExperts.all.map((profile) => profile.id).toSet(),
        ),
        isEmpty,
      );
      for (final id in expectedIds) {
        expect(ExpertCatalogBatchOne.byId(id)?.id, id);
      }
      expect(ExpertCatalogBatchOne.byId('missing-expert'), isNull);
    },
  );

  test(
    'every profile keeps the prompt, memory, and fixture safety baseline',
    () {
      for (final profile in ExpertCatalogBatchOne.all) {
        expect(
          profile.promptPackage.guards,
          containsAll({
            PromptGuard.roleIntegrity,
            PromptGuard.evidenceBoundaries,
            PromptGuard.noFabrication,
          }),
          reason: profile.id,
        );
        expect(profile.memoryPolicy.canReadPrivateMemory, isFalse);
        expect(profile.evaluationCases, hasLength(greaterThanOrEqualTo(3)));
        expect(
          profile.toolPolicy.decisionFor('shell.execute'),
          ToolDecision.denied,
          reason: profile.id,
        );
        expect(
          profile.toolPolicy.decisionFor('production.write'),
          ToolDecision.denied,
          reason: profile.id,
        );
        expect(
          ExpertProfile.fromJson(
            jsonDecode(jsonEncode(profile.toJson())) as Map<String, Object?>,
          ).toJson(),
          profile.toJson(),
          reason: profile.id,
        );
      }
    },
  );

  test('literal intent fixtures route mutually exclusively', () {
    const cases = {
      '请制定内容策略和内容治理方案': 'content-strategist',
      '请设计增长营销漏斗和获客实验': 'growth-marketer',
      '请制定用户研究访谈和可用性测试': 'user-researcher',
      '请评审UX设计和交互体验': 'ux-designer',
      '请做数据分析并解释指标异常': 'data-analyst',
      '请做行业研究和市场格局分析': 'industry-researcher',
      '请优化运营管理流程和SOP': 'operations-manager',
      '请制定项目管理里程碑和依赖计划': 'project-manager',
      '请做财税分析并提示税务风险': 'finance-tax-analyst',
      '请识别合同条款中的法律风险': 'legal-risk-advisor',
      '请做翻译本地化并维护术语一致性': 'localization-specialist',
      '请编辑校对这篇稿件并修正病句': 'editor-proofreader',
    };

    for (final entry in cases.entries) {
      final result = ExpertCatalogBatchOne.route(entry.key);
      expect(result.matchedExperts.map((profile) => profile.id), [
        entry.value,
      ], reason: entry.key);
      expect(result.needsClarification, isFalse, reason: entry.key);
    }
  });

  test(
    'catalog preserves clarification instead of silently dropping ambiguity',
    () {
      final result = ExpertCatalogBatchOne.route('不是不需要内容策略');

      expect(result.matchedExperts, isEmpty);
      expect(result.needsClarification, isTrue);

      final recognized = ExpertCatalogBatchOne.route('请识别内容策略中的风险');
      expect(recognized.matchedExperts.map((profile) => profile.id), [
        'content-strategist',
      ]);
      expect(recognized.needsClarification, isFalse);

      for (final request in ['不需要识别内容策略中的风险', '请告别内容策略', '离别内容策略']) {
        final negated = ExpertCatalogBatchOne.route(request);
        expect(negated.matchedExperts, isEmpty, reason: request);
        expect(negated.needsClarification, isFalse, reason: request);
      }
    },
  );

  test(
    'all evaluation fixtures agree with routing cards and negative scope',
    () {
      for (final profile in ExpertCatalogBatchOne.all) {
        expect(
          profile.evaluationCases.any((fixture) => fixture.shouldRoute),
          isTrue,
          reason: profile.id,
        );
        expect(
          profile.evaluationCases.any((fixture) => !fixture.shouldRoute),
          isTrue,
          reason: profile.id,
        );
        for (final fixture in profile.evaluationCases) {
          expect(
            profile.routingCard.matches(fixture.input),
            fixture.shouldRoute,
            reason: '${profile.id}/${fixture.id}',
          );
        }
      }
    },
  );

  test('catalog executable validation enforces profile policy fail closed', () {
    const trustedIds = {
      'user-researcher',
      'industry-researcher',
      'finance-tax-analyst',
      'legal-risk-advisor',
    };
    for (final profile in ExpertCatalogBatchOne.all) {
      expect(
        profile.validationPolicy,
        trustedIds.contains(profile.id)
            ? ExpertValidationPolicy.trustedEvidence
            : ExpertValidationPolicy.structural,
        reason: profile.id,
      );
    }

    final structural = ExpertCatalogBatchOne.executableById(
      'content-strategist',
      gateway: const ExpertOutputValidationGateway(),
    )!;
    expect(
      structural.validateOutput(const {
        'Analysis': 'A bounded analysis.',
        'Recommendations': ['A recommendation.'],
        'Risks': ['A risk.'],
      }),
      isTrue,
    );

    final trustedWithoutRegistry = ExpertCatalogBatchOne.executableById(
      'legal-risk-advisor',
      gateway: const ExpertOutputValidationGateway(),
    )!;
    const abstained = {
      'Claim': 'A legal-risk claim.',
      'Evidence': <Object?>[],
      'Verdict': 'abstain',
      'Confidence': 0,
    };
    expect(
      trustedWithoutRegistry.validateOutput(abstained),
      isFalse,
      reason: 'trusted policy must fail closed without a context',
    );
    expect(
      trustedWithoutRegistry.validateOutput(
        abstained,
        context: ExpertValidationContext(
          runId: 'run-legal',
          turnId: 'turn-1',
          outputId: 'output-1',
        ),
      ),
      isFalse,
      reason: 'trusted policy must fail closed without a registry',
    );
  });

  test('research, finance, and legal profiles require trusted evidence', () {
    const highRiskIds = {
      'user-researcher',
      'industry-researcher',
      'finance-tax-analyst',
      'legal-risk-advisor',
    };
    const claim = '该结论已得到可信资料支持。';
    final fakeEvidence = EvidenceItem(
      sourceId: 'untrusted-source',
      ref: 'https://fake.invalid/report',
      quoteOrSummary: 'A fabricated supporting statement.',
      receiptId: 'rcpt_AAAAAAAAAAAAAAAAAAAAAA',
      receiptToken: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      stance: EvidenceStance.supports,
    );

    for (final id in highRiskIds) {
      final profile = ExpertCatalogBatchOne.byId(id)!;
      final schema = profile.outputSchema;
      final unsupported = {
        'Claim': claim,
        'Evidence': <Object?>[],
        'Verdict': 'supported',
        'Confidence': 70,
      };
      final abstained = {
        'Claim': claim,
        'Evidence': <Object?>[],
        'Verdict': 'abstain',
        'Confidence': 0,
      };
      final fabricated = {
        'Claim': claim,
        'Evidence': [fakeEvidence.toJson()],
        'Verdict': 'supported',
        'Confidence': 70,
      };

      expect(
        profile.promptPackage.guards,
        contains(PromptGuard.abstainWithoutEvidence),
        reason: id,
      );
      expect(schema.unsafeShapeOnly(unsupported), isFalse, reason: id);
      expect(schema.unsafeShapeOnly(abstained), isTrue, reason: id);
      expect(schema.unsafeShapeOnly(fabricated), isTrue, reason: id);
      final registry = EvidenceTrustRegistry.forTesting(
        utf8.encode('0123456789abcdef0123456789abcdef'),
        clock: _FixedEvidenceClock(DateTime.utc(2026, 7, 29, 10)),
      );
      final executable = ExpertCatalogBatchOne.executableById(
        id,
        gateway: ExpertOutputValidationGateway(trustRegistry: registry),
      )!;
      final context = ExpertValidationContext(
        runId: 'run-$id',
        turnId: 'turn-1',
        outputId: 'output-1',
      );
      expect(
        executable.validateOutput(fabricated),
        isFalse,
        reason: '$id must fail closed without a validation context',
      );
      expect(
        executable.validateOutput(fabricated, context: context),
        isFalse,
        reason: id,
      );

      final receipt = registry.issue(
        context: context,
        validFor: const Duration(minutes: 5),
        claimDigest: claimDigestFor(claim),
        sourceId: 'trusted-source',
        ref: 'artifact://trusted/report',
        stance: EvidenceStance.supports,
        quoteOrSummary: 'A traceable supporting statement.',
      );
      final trustedEvidence = EvidenceItem(
        sourceId: 'trusted-source',
        ref: 'artifact://trusted/report',
        quoteOrSummary: 'A traceable supporting statement.',
        receiptId: receipt.receiptId,
        receiptToken: receipt.token,
        stance: EvidenceStance.supports,
      );
      expect(
        executable.validateOutput({
          'Claim': claim,
          'Evidence': [trustedEvidence.toJson()],
          'Verdict': 'supported',
          'Confidence': 70,
        }, context: context),
        isTrue,
        reason: '$id must accept a trusted receipt through the catalog gateway',
      );
    }
  });
}

class _FixedEvidenceClock implements EvidenceClock {
  const _FixedEvidenceClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}
