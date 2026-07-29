import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/app/app_shell.dart';
import 'package:halo_mobile/features/circle/circle_page.dart';
import 'package:halo_mobile/features/conversations/conversations_page.dart';
import 'package:halo_mobile/features/expert_team/expert_team_page.dart';
import 'package:halo_mobile/features/settings/settings_page.dart';

GoRouter createAppRouter() {
  return GoRouter(
    initialLocation: '/conversations',
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
