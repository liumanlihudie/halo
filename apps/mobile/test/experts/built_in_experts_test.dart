import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/experts/built_in_experts.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';

void main() {
  test('catalog contains exactly three validated benchmark experts', () {
    expect(BuiltInExperts.all.map((profile) => profile.id), [
      'product-manager',
      'technical-architect',
      'fact-checker',
    ]);

    for (final profile in BuiltInExperts.all) {
      expect(
        profile.promptPackage.guards,
        containsAll({
          PromptGuard.roleIntegrity,
          PromptGuard.evidenceBoundaries,
          PromptGuard.noFabrication,
        }),
      );
      expect(profile.memoryPolicy.canReadPrivateMemory, isFalse);
      expect(profile.evaluationCases, isNotEmpty);
      expect(
        ExpertProfile.fromJson(
          jsonDecode(jsonEncode(profile.toJson())) as Map<String, Object?>,
        ).toJson(),
        profile.toJson(),
      );
    }
  });

  test('catalog routes product, architecture, and verification requests', () {
    expect(
      BuiltInExperts.route(
        '请把这个想法整理成产品需求并排优先级',
      ).matchedExperts.map((profile) => profile.id),
      ['product-manager'],
    );
    expect(
      BuiltInExperts.route(
        '请评审系统架构、API 边界与扩展性',
      ).matchedExperts.map((profile) => profile.id),
      ['technical-architect'],
    );
    expect(
      BuiltInExperts.route(
        '请核查这条事实并给出证据与来源',
      ).matchedExperts.map((profile) => profile.id),
      ['fact-checker'],
    );
  });

  test('negative triggers exclude a superficially matching expert', () {
    expect(
      BuiltInExperts.productManager.routingCard.matches('请根据产品需求直接写代码'),
      isFalse,
    );
    expect(
      BuiltInExperts.technicalArchitect.routingCard.matches('请做系统架构的营销文案'),
      isFalse,
    );
    expect(
      BuiltInExperts.factChecker.routingCard.matches('请围绕证据自由创作一个故事'),
      isFalse,
    );
  });

  test('catalog route preserves clarification from expert routing cards', () {
    final ambiguous = BuiltInExperts.route('不是不需要产品需求分析');

    expect(ambiguous.matchedExperts, isEmpty);
    expect(ambiguous.needsClarification, isTrue);

    final matched = BuiltInExperts.route('请整理产品需求');
    expect(matched.matchedExperts.map((profile) => profile.id), [
      'product-manager',
    ]);
    expect(matched.needsClarification, isFalse);
  });

  test('routing capability requirements are enforced deterministically', () {
    expect(
      BuiltInExperts.route(
        '请核查这条事实',
        requiredCapabilities: const {'source.verification'},
      ).matchedExperts.map((profile) => profile.id),
      ['fact-checker'],
    );
    expect(
      BuiltInExperts.route(
        '请核查这条事实',
        requiredCapabilities: const {'architecture.design'},
      ).matchedExperts,
      isEmpty,
    );
    expect(
      BuiltInExperts.byId('technical-architect'),
      same(BuiltInExperts.technicalArchitect),
    );
    expect(BuiltInExperts.byId('missing-expert'), isNull);
  });

  test(
    'fact checker enforces Claim Evidence Verdict Confidence and abstain',
    () {
      final checker = BuiltInExperts.factChecker;

      expect(
        checker.promptPackage.guards,
        contains(PromptGuard.abstainWithoutEvidence),
      );
      expect(checker.outputSchema.fields.keys, [
        'Claim',
        'Evidence',
        'Verdict',
        'Confidence',
      ]);
      expect(
        checker.outputSchema.fields['Evidence'],
        OutputValueType.evidenceList,
      );
      expect(
        checker.outputSchema.unsafeShapeOnly(const {
          'Claim': 'The metric increased.',
          'Evidence': <String>[],
          'Verdict': 'supported',
          'Confidence': 70,
        }),
        isFalse,
      );
      expect(
        checker.outputSchema.unsafeShapeOnly(const {
          'Claim': 'The metric increased.',
          'Evidence': <String>[],
          'Verdict': 'abstain',
          'Confidence': 0,
        }),
        isTrue,
      );
    },
  );

  test('built-in evaluation cases agree with routing cards', () {
    for (final profile in BuiltInExperts.all) {
      for (final evaluation in profile.evaluationCases) {
        expect(
          profile.routingCard.matches(evaluation.input),
          evaluation.shouldRoute,
          reason: '${profile.id}/${evaluation.id}',
        );
      }
    }
  });
}
