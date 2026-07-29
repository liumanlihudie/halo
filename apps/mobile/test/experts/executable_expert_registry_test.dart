import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';

void main() {
  late ExecutableExpertRegistry registry;

  setUp(() {
    registry = ExecutableExpertRegistry(
      gateway: const ExpertOutputValidationGateway(),
    );
  });

  test('unifies all 27 experts under unique canonical IDs', () {
    expect(registry.all, hasLength(27));
    expect(registry.all.map((profile) => profile.id).toSet(), hasLength(27));
    expect(registry.catalogById('product-manager')?.id, 'product-manager');
    expect(registry.catalogById('user-researcher')?.id, 'user-researcher');
    expect(registry.catalogById('ios-engineer')?.id, 'ios-engineer');
    expect(registry.catalogById('missing-expert'), isNull);
    expect(registry.all, everyElement(isA<ExpertProfile>()));
    expect(registry.all, everyElement(isNot(isA<ExecutableExpert>())));
    expect(registry.catalogById('product-manager'), isA<ExpertProfile>());
    expect(
      registry.catalogById('product-manager'),
      isNot(isA<ExecutableExpert>()),
    );
  });

  test('exposes a routing card for every canonical expert ID', () {
    expect(registry.routingCards, hasLength(27));
    expect(
      registry.routingCards.keys.toSet(),
      registry.all.map((profile) => profile.id).toSet(),
    );
    expect(
      registry.routingCards['product-manager']?.matches('请整理产品需求'),
      isTrue,
    );
  });

  test('single-chat availability is the explicit first-launch union', () {
    expect(
      registry.availableForSingleChat.map((expert) => expert.profile.id),
      const [
        'product-manager',
        'technical-architect',
        'ux-designer',
        'project-manager',
        'qa-test-engineer',
        'ios-engineer',
        'flutter-engineer',
      ],
    );
  });

  test('group-chat availability exposes the two approved launch teams', () {
    expect(
      registry.productDeliveryGroup.map((expert) => expert.profile.id),
      const [
        'product-manager',
        'technical-architect',
        'ux-designer',
        'project-manager',
        'qa-test-engineer',
      ],
    );
    expect(
      registry.mobileReviewGroup.map((expert) => expert.profile.id),
      const [
        'product-manager',
        'technical-architect',
        'ios-engineer',
        'flutter-engineer',
        'qa-test-engineer',
      ],
    );
    expect(
      registry.availableForGroupChat.map((expert) => expert.profile.id).toSet(),
      const {
        'product-manager',
        'technical-architect',
        'ux-designer',
        'project-manager',
        'qa-test-engineer',
        'ios-engineer',
        'flutter-engineer',
      },
    );
  });

  test(
    'trusted-evidence and tool-dependent experts stay out of production chat',
    () {
      const unavailable = {
        'fact-checker',
        'user-researcher',
        'industry-researcher',
        'finance-tax-analyst',
        'legal-risk-advisor',
        'security-auditor',
        'database-engineer',
        'devops-sre-engineer',
        'automation-engineer',
      };

      final singleIds = registry.availableForSingleChat
          .map((expert) => expert.profile.id)
          .toSet();
      final groupIds = registry.availableForGroupChat
          .map((expert) => expert.profile.id)
          .toSet();
      expect(singleIds.intersection(unavailable), isEmpty);
      expect(groupIds.intersection(unavailable), isEmpty);
      expect(
        registry.all
            .where(
              (profile) =>
                  profile.validationPolicy ==
                  ExpertValidationPolicy.trustedEvidence,
            )
            .map((profile) => profile.id)
            .toSet()
            .intersection(singleIds.union(groupIds)),
        isEmpty,
      );
    },
  );

  test('market IDs resolve only through the explicit canonical mapping', () {
    expect(registry.canonicalIdForMarketId('market-5'), 'project-manager');
    expect(registry.canonicalIdForMarketId('market-10'), 'user-researcher');
    expect(registry.canonicalIdForMarketId('market-15'), 'fact-checker');
    expect(registry.canonicalIdForMarketId('market-27'), 'data-analyst');
    expect(registry.canonicalIdForMarketId('market-50'), isNull);
    expect(registry.canonicalIdForMarketId('用户研究员'), isNull);
    expect(registry.singleChatByMarketId('market-50'), isNull);
  });

  test('catalog lookup cannot bypass production chat authorization', () {
    const blockedCanonicalIds = {
      'automation-engineer',
      'database-engineer',
      'devops-sre-engineer',
      'fact-checker',
      'user-researcher',
      'industry-researcher',
      'finance-tax-analyst',
      'legal-risk-advisor',
      'security-auditor',
    };

    for (final id in blockedCanonicalIds) {
      expect(registry.catalogById(id), isNotNull, reason: 'catalog/$id');
      expect(registry.singleChatById(id), isNull, reason: 'single/$id');
      expect(registry.groupChatById(id), isNull, reason: 'group/$id');
    }
    expect(registry.singleChatById('product-manager'), isNotNull);
    expect(registry.groupChatById('ios-engineer'), isNotNull);
  });

  test('catalog profile cannot be rebound through the validation gateway', () {
    final blockedProfile = registry.catalogById('security-auditor')!;
    dynamic gateway = const ExpertOutputValidationGateway();

    expect(() => gateway.bind(blockedProfile), throwsNoSuchMethodError);
    expect(registry.singleChatById(blockedProfile.id), isNull);
    expect(registry.groupChatById(blockedProfile.id), isNull);
  });

  test('executable capability has no consumptive validateOutput API', () {
    dynamic expert = registry.singleChatById('ios-engineer')!;

    expect(
      () => expert.validateOutput(<String, Object?>{}),
      throwsNoSuchMethodError,
    );
  });

  test('market aliases cannot bypass canonical chat authorization', () {
    expect(
      registry.singleChatByMarketId('market-5')?.profile.id,
      'project-manager',
    );
    expect(registry.singleChatByMarketId('market-9'), isNull);
    expect(registry.singleChatByMarketId('market-10'), isNull);
    expect(registry.singleChatByMarketId('market-15'), isNull);
    expect(registry.singleChatByMarketId('market-28'), isNull);
  });

  test('team resolution accepts only approved immutable teams', () {
    expect(
      registry
          .resolveTeam('product-delivery')
          ?.map((expert) => expert.profile.id),
      const [
        'product-manager',
        'technical-architect',
        'ux-designer',
        'project-manager',
        'qa-test-engineer',
      ],
    );
    expect(
      registry.resolveTeam('mobile-review')?.map((expert) => expert.profile.id),
      const [
        'product-manager',
        'technical-architect',
        'ios-engineer',
        'flutter-engineer',
        'qa-test-engineer',
      ],
    );
    expect(registry.resolveTeam('automation-engineer'), isNull);
    expect(
      registry.resolveTeam('product-delivery,automation-engineer'),
      isNull,
    );
  });
}
