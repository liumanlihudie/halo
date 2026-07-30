import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
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
import 'package:halo_mobile/features/media/voice_call_page.dart';
import 'package:halo_mobile/features/media/media_preview_page.dart';
import 'package:halo_mobile/features/single_chat/chat_details_page.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/chat_history_page.dart';
import 'package:halo_mobile/features/single_chat/single_chat_page.dart';
import 'package:halo_mobile/features/settings/settings_page.dart';
import 'package:halo_mobile/features/settings/app_lock.dart';
import 'package:halo_mobile/features/settings/local_data_maintenance.dart';
import 'package:halo_mobile/features/settings/local_data_page.dart';
import 'package:halo_mobile/features/settings/model_providers_page.dart';
import 'package:halo_mobile/features/settings/provider_detail_page.dart';
import 'package:halo_mobile/features/settings/self_hosted_gateway_page.dart';
import 'package:halo_mobile/features/settings/service_credentials_page.dart';

GoRouter createAppRouter({
  String initialLocation = '/conversations',
  AppDependencies? dependencies,
  AppDependencies Function()? dependencyResolver,
  Listenable? dependencyListenable,
  AppLockController? Function()? appLock,
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
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                pageBuilder: (context, state) {
                  Widget buildPage(AppDependencies? current) => SettingsPage(
                    key: ValueKey(current),
                    modelRouting: current?.modelRouting,
                    appLock: appLock?.call(),
                    localData: current?.localData,
                  );
                  final listenable = dependencyListenable;
                  if (listenable == null) {
                    return NoTransitionPage(
                      child: buildPage(fixedDependencies),
                    );
                  }
                  return NoTransitionPage(
                    child: ListenableBuilder(
                      listenable: listenable,
                      builder: (context, _) => buildPage(resolveDependencies()),
                    ),
                  );
                },
              ),
            ],
          ),
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
            modelRouting: current?.modelRouting,
            speech: current?.speech,
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
        builder: (context, state) {
          final groupId = state.pathParameters['groupId']!;
          Widget buildPage(AppDependencies? current) => GroupChatPage(
            key: ValueKey(current),
            groupId: groupId,
            runPort: current?.groupChatPort,
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
        builder: (context, state) {
          final expertId = state.pathParameters['expertId']!;
          // The entry may pass an installed profile id ('general') rather than
          // the canonical expert id, so resolve it the way chat does.
          final canonicalId =
              _executableExperts
                  .installedIdentityForProfileId(expertId)
                  ?.canonicalExpertId ??
              expertId;
          final expert = _executableExperts.singleChatById(canonicalId);
          Widget buildPage(AppDependencies? current) => VoiceCallPage(
            key: ValueKey(current),
            expertName: expert?.profile.displayName ?? expertId,
            // The expert's own prompt travels with the call, so the caller
            // reaches that expert instead of the vendor's default assistant.
            systemRole:
                expert?.profile.promptPackage.render() ?? '你是一位助理，回答简短、如实。',
            controller: current?.callFactory?.call(),
            onCallEnded: (summary) async {
              final repository = current?.chatRepository;
              if (repository == null) return;
              final identity = _executableExperts.installedIdentityForProfileId(
                expertId,
              );
              await repository.append(
                identity?.conversationId ?? expertId,
                ChatMessageProjection(
                  id: 'call-${DateTime.now().microsecondsSinceEpoch}',
                  kind: ChatMessageKind.systemNotice,
                  text: summary,
                ),
              );
            },
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
        path: '/settings/service-keys',
        builder: (context, state) {
          Widget buildPage(AppDependencies? current) => ServiceCredentialsPage(
            key: ValueKey(current),
            controller: current?.serviceCredentials,
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
        path: '/settings/local-data',
        builder: (context, state) {
          Widget buildPage(AppDependencies? current) => LocalDataPage(
            key: ValueKey(current),
            maintenance: current?.localData,
            shareExport: current?.localData == null ? null : shareExportBundle,
          );
          final listenable = dependencyListenable;
          if (listenable == null) return buildPage(fixedDependencies);
          return ListenableBuilder(
            listenable: listenable,
            builder: (context, _) => buildPage(resolveDependencies()),
          );
        },
      ),
    ],
  );
}

final _executableExperts = ExecutableExpertRegistry(
  gateway: const ExpertOutputValidationGateway(),
);

/// Hands the written bundle to the iOS share sheet, which is also how it
/// reaches 存储到文件. Only the file the caller just produced is shared.
Future<void> shareExportBundle(LocalDataExportBundle bundle) =>
    SharePlus.instance.share(ShareParams(files: [XFile(bundle.file.path)]));

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
