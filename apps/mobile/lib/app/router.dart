import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/app/app_kernel.dart';
import 'package:halo_mobile/app/app_shell.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/circle/circle_page.dart';
import 'package:halo_mobile/features/circle/moment_detail_page.dart';
import 'package:halo_mobile/features/conversations/conversations_page.dart';
import 'package:halo_mobile/features/expert_team/expert_team_page.dart';
import 'package:halo_mobile/features/expert_market/expert_data_page.dart';
import 'package:halo_mobile/features/expert_market/expert_market_page.dart';
import 'package:halo_mobile/features/expert_market/expert_profile_page.dart';
import 'package:halo_mobile/features/group_chat/group_chat_page.dart';
import 'package:halo_mobile/features/group_chat/group_context_page.dart';
import 'package:halo_mobile/features/group_chat/group_info_page.dart';
import 'package:halo_mobile/features/group_chat/new_group_page.dart';
import 'package:halo_mobile/features/media/call_demo_page.dart';
import 'package:halo_mobile/features/media/media_preview_page.dart';
import 'package:halo_mobile/features/single_chat/chat_details_page.dart';
import 'package:halo_mobile/features/single_chat/chat_history_page.dart';
import 'package:halo_mobile/features/single_chat/single_chat_page.dart';
import 'package:halo_mobile/features/settings/settings_page.dart';
import 'package:halo_mobile/features/settings/local_data_page.dart';
import 'package:halo_mobile/features/settings/model_providers_page.dart';
import 'package:halo_mobile/features/settings/provider_detail_page.dart';
import 'package:halo_mobile/features/settings/self_hosted_gateway_page.dart';

GoRouter createAppRouter({
  String initialLocation = '/conversations',
  AppDependencies? dependencies,
  AppDependencies Function()? dependencyResolver,
  Listenable? dependencyListenable,
}) {
  final fixedDependencies = dependencies;
  AppDependencies? resolveDependencies() =>
      dependencyResolver?.call() ?? fixedDependencies;

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
        builder: (context, state) {
          Widget buildPage(AppDependencies? current) => SingleChatPage(
            key: ValueKey(current),
            conversationId: state.pathParameters['conversationId']!,
            service: current?.singleChatPort,
            repository: current?.chatRepository,
            allowEphemeralRepositoryForTesting:
                current?.allowEphemeralChatRepositoryForTesting ?? false,
          );
          final listenable = dependencyListenable;
          if (listenable == null) return buildPage(fixedDependencies);
          return ListenableBuilder(
            listenable: listenable,
            builder: (context, _) => buildPage(resolveDependencies()),
          );
        },
      ),
      GoRoute(
        path: '/chat/:conversationId/details',
        builder: (context, state) => ChatDetailsPage(
          conversationId: state.pathParameters['conversationId']!,
        ),
      ),
      GoRoute(
        path: '/chat/:conversationId/history',
        builder: (context, state) => ChatHistoryPage(
          conversationId: state.pathParameters['conversationId']!,
        ),
      ),
      GoRoute(
        path: '/group/new',
        builder: (context, state) => const NewGroupPage(),
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
        path: '/circle/:postId',
        builder: (context, state) =>
            MomentDetailPage(postId: state.pathParameters['postId']!),
      ),
      GoRoute(
        path: '/media/:kind',
        builder: (context, state) =>
            MediaPreviewPage(kind: state.pathParameters['kind']!),
      ),
      GoRoute(
        path: '/call/voice/:expertId',
        builder: (context, state) => CallDemoPage(
          expertId: state.pathParameters['expertId']!,
          video: false,
        ),
      ),
      GoRoute(
        path: '/call/video/:expertId',
        builder: (context, state) => CallDemoPage(
          expertId: state.pathParameters['expertId']!,
          video: true,
        ),
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
        builder: (context, state) {
          final expertId = state.pathParameters['expertId']!;
          final installedIdentity = _executableExperts
              .installedIdentityForProfileId(expertId);
          Widget buildPage(AppDependencies? current) => ExpertProfilePage(
            key: ValueKey(current),
            expertId: expertId,
            installedIdentity: installedIdentity,
            routingController: current?.modelRouting,
          );
          final listenable = dependencyListenable;
          if (listenable == null) return buildPage(fixedDependencies);
          return ListenableBuilder(
            listenable: listenable,
            builder: (context, _) => buildPage(resolveDependencies()),
          );
        },
      ),
      GoRoute(
        path: '/expert/:expertId/data',
        builder: (context, state) =>
            ExpertDataPage(expertId: state.pathParameters['expertId']!),
      ),
      GoRoute(
        path: '/settings/providers',
        builder: (context, state) {
          Widget buildPage(AppDependencies? current) => ModelProvidersPage(
            key: ValueKey(current),
            controller: current?.providerSettings,
            routingController: current?.modelRouting,
          );
          final listenable = dependencyListenable;
          if (listenable == null) return buildPage(fixedDependencies);
          return ListenableBuilder(
            listenable: listenable,
            builder: (context, _) => buildPage(resolveDependencies()),
          );
        },
      ),
      GoRoute(
        path: '/settings/providers/:providerId',
        builder: (context, state) {
          Widget buildPage(AppDependencies? current) => ProviderDetailPage(
            key: ValueKey(current),
            providerId: state.pathParameters['providerId']!,
            controller: current?.providerSettings,
          );
          final listenable = dependencyListenable;
          if (listenable == null) return buildPage(fixedDependencies);
          return ListenableBuilder(
            listenable: listenable,
            builder: (context, _) => buildPage(resolveDependencies()),
          );
        },
      ),
      GoRoute(
        path: '/settings/gateway',
        builder: (context, state) => const SelfHostedGatewayPage(),
      ),
      GoRoute(
        path: '/settings/local-data',
        builder: (context, state) => const LocalDataPage(),
      ),
    ],
  );
}

final _executableExperts = ExecutableExpertRegistry(
  gateway: const ExpertOutputValidationGateway(),
);

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
