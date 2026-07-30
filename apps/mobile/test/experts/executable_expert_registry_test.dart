import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/production_app_kernel.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

void main() {
  late ExecutableExpertRegistry registry;

  setUp(() {
    registry = ExecutableExpertRegistry(
      gateway: const ExpertOutputValidationGateway(),
    );
  });

  test('unifies all 28 experts under unique canonical IDs', () {
    expect(registry.all, hasLength(28));
    expect(registry.all.map((profile) => profile.id).toSet(), hasLength(28));
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
    expect(registry.routingCards, hasLength(28));
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
        'data-analyst',
        'content-strategist',
        'operations-manager',
        'legal-risk-advisor',
        'fact-checker',
        'industry-researcher',
        'fitness-planner',
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

  test('only explicitly installed trusted-evidence experts enter chat', () {
    const unavailable = {
      'user-researcher',
      'finance-tax-analyst',
      'security-auditor',
      'database-engineer',
      'devops-sre-engineer',
      'automation-engineer',
    };
    // legal-risk-advisor, fact-checker and industry-researcher were downgraded
    // to structural, so no trusted-evidence profile is launchable any more.
    const installedTrusted = <String>{};

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
      installedTrusted,
    );
  });

  test('market IDs resolve only through the explicit canonical mapping', () {
    expect(registry.canonicalIdForMarketId('market-5'), 'project-manager');
    expect(registry.canonicalIdForMarketId('market-10'), 'user-researcher');
    expect(registry.canonicalIdForMarketId('market-15'), 'fact-checker');
    expect(registry.canonicalIdForMarketId('market-27'), 'data-analyst');
    expect(registry.canonicalIdForMarketId('market-50'), isNull);
    expect(registry.canonicalIdForMarketId('用户研究员'), isNull);
    expect(registry.singleChatByMarketId('market-50'), isNull);
  });

  test(
    'every installed profile resolves to one executable conversation identity',
    () {
      final conversations = SingleChatCatalogRepository();
      final resolved = {
        for (final installed in HaloFixtures.installedExperts)
          installed.id: registry.installedIdentityForProfileId(installed.id),
      };

      expect(resolved.values, everyElement(isNotNull));
      expect(
        resolved,
        hasLength(ExecutableExpertRegistry.installedExpertIdentities.length),
      );
      expect(
        resolved.values.map((identity) => identity!.canonicalExpertId).toSet(),
        hasLength(resolved.length),
      );
      expect(
        resolved.values.map((identity) => identity!.conversationId).toSet(),
        hasLength(resolved.length),
      );
      for (final entry in resolved.entries) {
        final identity = entry.value!;
        expect(identity.profileId, entry.key);
        expect(
          registry.catalogById(identity.canonicalExpertId),
          isNotNull,
          reason: '${entry.key} -> ${identity.canonicalExpertId}',
        );
        expect(
          registry.singleChatById(identity.canonicalExpertId),
          isNotNull,
          reason: 'single/${identity.canonicalExpertId}',
        );
        expect(
          conversations.describe(identity.conversationId).expertId,
          identity.canonicalExpertId,
          reason: 'conversation/${identity.conversationId}',
        );
      }
      expect(
        registry
            .installedIdentityForProfileId('general-assistant')
            ?.canonicalExpertId,
        resolved['general']?.canonicalExpertId,
      );
      expect(registry.installedIdentityForProfileId('missing-profile'), isNull);
    },
  );

  test(
    'production and fallback conversations agree on every installed identity',
    () {
      final fallback = SingleChatCatalogRepository();
      final identities = ExecutableExpertRegistry.installedExpertIdentities;

      expect(identities.map((identity) => identity.profileId), const [
        'general',
        'product',
        'data',
        'writing',
        'calendar',
        'contract',
        'watcher',
        'researcher',
        'fitness',
      ]);
      final fixtureIds = HaloFixtures.installedExperts
          .map((expert) => expert.id)
          .toSet();
      expect(
        identities.every((identity) => fixtureIds.contains(identity.profileId)),
        isTrue,
      );
      expect(
        productionSingleChatConversations.keys.toSet(),
        identities.map((identity) => identity.conversationId).toSet(),
      );

      for (final identity in identities) {
        final production =
            productionSingleChatConversations[identity.conversationId]!;
        expect(
          production.conversationId,
          identity.conversationId,
          reason: 'production key/conversationId ${identity.profileId}',
        );
        // The chat controller derives StartSingleAgentRunRequest.expertId from
        // this projection, while the profile page binds the model override to
        // InstalledExpertIdentity.canonicalExpertId. They must be one ID.
        expect(
          production.expertId,
          identity.canonicalExpertId,
          reason: 'production expertId ${identity.profileId}',
        );
        expect(
          fallback.describe(identity.conversationId).expertId,
          production.expertId,
          reason: 'fallback expertId ${identity.profileId}',
        );
        expect(
          registry.singleChatById(production.expertId),
          isNotNull,
          reason: 'executable ${production.expertId}',
        );
        expect(
          registry
              .installedIdentityForProfileId(identity.profileId)!
              .canonicalExpertId,
          production.expertId,
          reason: 'routed override target ${identity.profileId}',
        );
      }
    },
  );

  test('catalog lookup cannot bypass production chat authorization', () {
    const blockedCanonicalIds = {
      'automation-engineer',
      'database-engineer',
      'devops-sre-engineer',
      'user-researcher',
      'finance-tax-analyst',
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
    expect(
      registry.singleChatByMarketId('market-27')?.profile.id,
      'data-analyst',
    );
    expect(
      registry.singleChatByMarketId('market-15')?.profile.id,
      'fact-checker',
    );
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
