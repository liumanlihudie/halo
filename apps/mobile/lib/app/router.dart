import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/app/app_shell.dart';
import 'package:halo_mobile/features/circle/circle_page.dart';
import 'package:halo_mobile/features/conversations/conversations_page.dart';
import 'package:halo_mobile/features/expert_team/expert_team_page.dart';
import 'package:halo_mobile/features/expert_market/expert_data_page.dart';
import 'package:halo_mobile/features/expert_market/expert_market_page.dart';
import 'package:halo_mobile/features/expert_market/expert_profile_page.dart';
import 'package:halo_mobile/features/group_chat/group_chat_page.dart';
import 'package:halo_mobile/features/group_chat/group_context_page.dart';
import 'package:halo_mobile/features/group_chat/group_info_page.dart';
import 'package:halo_mobile/features/single_chat/chat_details_page.dart';
import 'package:halo_mobile/features/single_chat/single_chat_page.dart';
import 'package:halo_mobile/features/settings/settings_page.dart';

GoRouter createAppRouter({String initialLocation = '/conversations'}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return AppShell(navigationShell: navigationShell);
        },
        branches: [
          _branch('/conversations', const ConversationsPage()),
          _branch('/experts', const ExpertTeamPage()),
          _branch('/circle', const CirclePage()),
          _branch('/settings', const SettingsPage()),
        ],
      ),
      GoRoute(
        path: '/chat/:conversationId',
        builder: (context, state) => SingleChatPage(
          conversationId: state.pathParameters['conversationId']!,
        ),
      ),
      GoRoute(
        path: '/chat/:conversationId/details',
        builder: (context, state) => ChatDetailsPage(
          conversationId: state.pathParameters['conversationId']!,
        ),
      ),
      GoRoute(
        path: '/group/:groupId',
        builder: (context, state) =>
            GroupChatPage(groupId: state.pathParameters['groupId']!),
      ),
      GoRoute(
        path: '/group/:groupId/info',
        builder: (context, state) =>
            GroupInfoPage(groupId: state.pathParameters['groupId']!),
      ),
      GoRoute(
        path: '/group/:groupId/context',
        builder: (context, state) =>
            GroupContextPage(groupId: state.pathParameters['groupId']!),
      ),
      GoRoute(
        path: '/market',
        builder: (context, state) => const ExpertMarketPage(),
      ),
      GoRoute(
        path: '/market/:expertId',
        builder: (context, state) => ExpertProfilePage(
          expertId: state.pathParameters['expertId']!,
          marketMode: true,
        ),
      ),
      GoRoute(
        path: '/expert/:expertId',
        builder: (context, state) =>
            ExpertProfilePage(expertId: state.pathParameters['expertId']!),
      ),
      GoRoute(
        path: '/expert/:expertId/data',
        builder: (context, state) =>
            ExpertDataPage(expertId: state.pathParameters['expertId']!),
      ),
    ],
  );
}

StatefulShellBranch _branch(String path, Widget child) {
  return StatefulShellBranch(
    routes: [
      GoRoute(
        path: path,
        pageBuilder: (context, state) => NoTransitionPage(child: child),
      ),
    ],
  );
}
