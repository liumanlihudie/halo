import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/experts/built_in_experts.dart';
import 'package:halo_mobile/experts/expert_catalog_batch_one.dart';
import 'package:halo_mobile/experts/expert_catalog_batch_two.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';

void main() {
  const expectedIds = [
    'ios-engineer',
    'flutter-engineer',
    'backend-architect',
    'database-engineer',
    'devops-sre-engineer',
    'security-auditor',
    'qa-test-engineer',
    'ai-ml-engineer',
    'prompt-engineer',
    'automation-engineer',
    'customer-support-specialist',
    'recruiting-advisor',
    'fitness-planner',
  ];
  const trustedIds = {'security-auditor'};

  test(
    'batch two exposes thirteen unique profiles without prior collisions',
    () {
      final profiles = ExpertCatalogBatchTwo.all;
      final ids = profiles.map((profile) => profile.id).toList();
      final priorIds = {
        ...BuiltInExperts.all.map((profile) => profile.id),
        ...ExpertCatalogBatchOne.all.map((profile) => profile.id),
      };

      expect(ids, expectedIds);
      expect(ids.toSet(), hasLength(13));
      expect(ids.toSet().intersection(priorIds), isEmpty);
      for (final id in expectedIds) {
        expect(ExpertCatalogBatchTwo.byId(id)?.id, id);
      }
      expect(ExpertCatalogBatchTwo.byId('missing-expert'), isNull);
    },
  );

  test('every profile keeps the complete serialized safety contract', () {
    for (final profile in ExpertCatalogBatchTwo.all) {
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
      expect(profile.memoryPolicy.retention, MemoryRetention.session);
      expect(profile.evaluationCases, hasLength(greaterThanOrEqualTo(3)));
      for (final tool in [
        'shell.execute',
        'production.write',
        'production.deploy',
        'database.drop',
        'secret.read',
        'memory.private.read',
      ]) {
        expect(
          profile.toolPolicy.decisionFor(tool),
          ToolDecision.denied,
          reason: '${profile.id}/$tool',
        );
      }
      expect(
        ExpertProfile.fromJson(
          jsonDecode(jsonEncode(profile.toJson())) as Map<String, Object?>,
        ).toJson(),
        profile.toJson(),
        reason: profile.id,
      );
    }
  });

  test('structural experts use a typed verification envelope', () {
    for (final profile in ExpertCatalogBatchTwo.all.where(
      (profile) => !trustedIds.contains(profile.id),
    )) {
      expect(
        profile.validationPolicy,
        ExpertValidationPolicy.structural,
        reason: profile.id,
      );
      expect(
        profile.outputSchema.fields['Verification'],
        OutputValueType.verificationEnvelope,
        reason: profile.id,
      );
      final rendered = profile.promptPackage.render();
      expect(rendered, contains('claimType=advice'), reason: profile.id);
      expect(rendered, contains('claimType=execution'), reason: profile.id);

      final validator = StructuralExpertOutputValidator(
        profile: profile,
        verificationRegistry: null,
      );
      expect(
        validator.preflight(const {
          'Analysis': 'A bounded recommendation, not a verified result.',
          'Recommendations': [
            {
              'verb': 'verify',
              'target': 'expert-output',
              'conditions': ['authorized-environment'],
            },
          ],
          'Risks': ['Inputs may be incomplete.'],
          'Verification': {
            'claimType': 'advice',
            'tense': 'proposed',
            'verified': false,
            'source': 'none',
            'proposedActions': [
              {
                'verb': 'verify',
                'target': 'expert-output',
                'conditions': ['authorized-environment'],
              },
            ],
            'executedFacts': <String>[],
          },
        }),
        isTrue,
        reason: profile.id,
      );
    }
  });

  test('literal intent fixtures route mutually exclusively', () {
    const cases = {
      '请评审iOS开发和SwiftUI实现方案': 'ios-engineer',
      '请评审Flutter开发和Dart应用架构': 'flutter-engineer',
      '请设计后端架构和API服务边界': 'backend-architect',
      '请评审数据库工程和SQL调优方案': 'database-engineer',
      '请设计DevOps和SRE可靠性方案': 'devops-sre-engineer',
      '请进行安全审计并核验漏洞风险': 'security-auditor',
      '请制定QA测试策略和测试用例': 'qa-test-engineer',
      '请评审AI/ML工程和模型训练方案': 'ai-ml-engineer',
      '请设计Prompt工程和提示词评测方案': 'prompt-engineer',
      '请规划自动化工程和工作流自动化': 'automation-engineer',
      '请制定客户支持和客诉处理方案': 'customer-support-specialist',
      '请优化招聘顾问流程和候选人评估': 'recruiting-advisor',
      '请制定健身计划和训练饮食计划': 'fitness-planner',
    };

    for (final entry in cases.entries) {
      final result = ExpertCatalogBatchTwo.route(entry.key);
      expect(result.matchedExperts.map((profile) => profile.id), [
        entry.value,
      ], reason: entry.key);
      expect(result.needsClarification, isFalse, reason: entry.key);
    }
  });

  test('catalog preserves clarification and evaluation fixtures route', () {
    final ambiguous = ExpertCatalogBatchTwo.route('不是不需要iOS开发');
    expect(ambiguous.matchedExperts, isEmpty);
    expect(ambiguous.needsClarification, isTrue);

    for (final profile in ExpertCatalogBatchTwo.all) {
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
  });

  test('security auditor requires trusted receipts and fails closed', () {
    final profile = ExpertCatalogBatchTwo.securityAuditor;
    expect(profile.validationPolicy, ExpertValidationPolicy.trustedEvidence);
    expect(
      profile.promptPackage.guards,
      contains(PromptGuard.abstainWithoutEvidence),
    );

    const claim = '目标组件存在可利用漏洞。';
    final fakeEvidence = EvidenceItem(
      sourceId: 'untrusted-source',
      ref: 'https://fake.invalid/advisory',
      quoteOrSummary: 'A fabricated vulnerability statement.',
      receiptId: 'rcpt_AAAAAAAAAAAAAAAAAAAAAA',
      receiptToken: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      stance: EvidenceStance.supports,
    );
    final fabricated = {
      'Claim': claim,
      'Evidence': [fakeEvidence.toJson()],
      'Verdict': 'supported',
      'Confidence': 80,
    };
    const abstained = {
      'Claim': claim,
      'Evidence': <Object?>[],
      'Verdict': 'abstain',
      'Confidence': 0,
    };
    final context = ExpertValidationContext(
      runId: 'run-security',
      turnId: 'turn-1',
      outputId: 'output-1',
    );

    expect(profile.validationPolicy, ExpertValidationPolicy.trustedEvidence);

    final registry = EvidenceTrustRegistry.forTesting(
      utf8.encode('0123456789abcdef0123456789abcdef'),
      clock: _FixedEvidenceClock(DateTime.utc(2026, 7, 29, 10)),
    );
    final validator = TrustedExpertOutputValidator(
      schema: profile.outputSchema,
      trustRegistry: registry,
      expertId: profile.id,
      schemaId: profile.outputSchema.schemaId,
      profileVersion: profile.version,
    );
    expect(validator.validate(fabricated, context), isFalse);
    expect(validator.validate(abstained, context), isTrue);

    final unsignedOutput = {
      'Claim': claim,
      'Evidence': [
        {
          'sourceId': 'trusted-advisory',
          'ref': 'artifact://security/advisory',
          'quoteOrSummary': 'The advisory confirms the affected component.',
          'stance': EvidenceStance.supports.name,
        },
      ],
      'Verdict': 'supported',
      'Confidence': 80,
    };
    final receipt = registry.issue(
      expertId: profile.id,
      schemaId: profile.outputSchema.schemaId,
      profileVersion: profile.version,
      context: context,
      validFor: const Duration(minutes: 5),
      outputDigest: expertOutputDigestFor(unsignedOutput),
      claimDigest: claimDigestFor(claim),
      sourceId: 'trusted-advisory',
      ref: 'artifact://security/advisory',
      stance: EvidenceStance.supports,
      quoteOrSummary: 'The advisory confirms the affected component.',
    );
    final trustedEvidence = EvidenceItem(
      sourceId: 'trusted-advisory',
      ref: 'artifact://security/advisory',
      quoteOrSummary: 'The advisory confirms the affected component.',
      receiptId: receipt.receiptId,
      receiptToken: receipt.token,
      stance: EvidenceStance.supports,
    );
    expect(
      validator.validate({
        'Claim': claim,
        'Evidence': [trustedEvidence.toJson()],
        'Verdict': 'supported',
        'Confidence': 80,
      }, context),
      isTrue,
    );
  });
}

class _FixedEvidenceClock implements EvidenceClock {
  const _FixedEvidenceClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}
