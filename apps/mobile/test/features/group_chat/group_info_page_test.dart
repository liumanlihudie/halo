import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/features/group_chat/group_info_page.dart';
import 'package:halo_mobile/features/group_chat/group_members_repository.dart';

void main() {
  Future<GoRouter> pumpInfo(
    WidgetTester tester, {
    GroupMembersRepository repository = const PrototypeGroupMembersRepository(),
  }) async {
    final router = GoRouter(
      initialLocation: '/group/group-product/info',
      routes: [
        GoRoute(
          path: '/group/:groupId/info',
          builder: (context, state) => GroupInfoPage(
            groupId: state.pathParameters['groupId']!,
            membersRepository: repository,
          ),
        ),
        GoRoute(
          path: '/expert/:expertId',
          builder: (context, state) =>
              Scaffold(body: Text('资料:${state.pathParameters['expertId']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('the strip shows the group its real members', (tester) async {
    await pumpInfo(tester);

    // Previously hardcoded names that were not in this group at all.
    expect(find.text('交互设计'), findsNothing);
    expect(find.text('增长顾问'), findsNothing);
    // Scoped to the strip: 主持 Agent below also reads 产品经理.
    expect(
      find.byKey(const ValueKey('group-member-product-manager')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('group-member-technical-architect')),
      findsOneWidget,
    );
  });

  testWidgets('tapping a member avatar opens that expert profile', (
    tester,
  ) async {
    await pumpInfo(tester);

    await tester.tap(
      find.byKey(const ValueKey('group-member-product-manager')),
    );
    await tester.pumpAndSettle();

    // The roster stores the canonical id (product-manager) while the route
    // takes the profile id (product); the mapping is what is under test.
    expect(find.text('资料:product'), findsOneWidget);
  });

  testWidgets('an uninstalled member is not tappable', (tester) async {
    await pumpInfo(tester, repository: _RosterWithStranger());

    await tester.tap(
      find.byKey(const ValueKey('group-member-not-installed-expert')),
    );
    await tester.pumpAndSettle();

    // Better a dead avatar than navigation to a profile that does not exist.
    expect(find.text('外部顾问'), findsOneWidget);
    expect(find.textContaining('资料:'), findsNothing);
  });

  testWidgets('an unreadable roster shows no members rather than fixtures', (
    tester,
  ) async {
    await pumpInfo(tester, repository: _FailingRoster());

    expect(
      find.byKey(const ValueKey('group-member-product-manager')),
      findsNothing,
    );
    // The add tile is the page's own affordance, not roster data.
    expect(find.text('添加'), findsOneWidget);
  });
}

class _RosterWithStranger implements GroupMembersRepository {
  @override
  Future<List<GroupChatMember>> loadMembers(String conversationId) async => [
    GroupChatMember(
      expertId: 'not-installed-expert',
      displayName: '外部顾问',
      role: '不在已装列表里',
      avatarLetter: '外',
    ),
  ];
}

class _FailingRoster implements GroupMembersRepository {
  @override
  Future<List<GroupChatMember>> loadMembers(String conversationId) async =>
      throw StateError('unavailable');
}
