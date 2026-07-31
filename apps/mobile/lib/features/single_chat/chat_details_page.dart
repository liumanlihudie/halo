import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';
import 'package:share_plus/share_plus.dart';

import 'chat_message_repository.dart';

/// Details for one conversation: every control here does what it says.
///
/// The rows this page used to show — do-nothing switches, a chat background,
/// a feedback entry — described a product that was not running and are gone
/// rather than dead to the touch.
class ChatDetailsPage extends StatelessWidget {
  const ChatDetailsPage({
    required this.conversationId,
    this.repository,
    this.shareText,
    super.key,
  });

  final String conversationId;

  /// Absent when storage failed to boot; export then reports that instead of
  /// sharing an empty transcript.
  final ChatMessageRepository? repository;

  /// Injectable so tests exercise export without the system share sheet.
  final Future<void> Function(String text)? shareText;

  Future<void> _exportTranscript(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final store = repository;
    if (store == null) {
      messenger?.showSnackBar(const SnackBar(content: Text('聊天存储不可用，无法导出')));
      return;
    }
    final List<ChatMessageProjection> messages;
    final String title;
    try {
      title = store.describe(conversationId).title;
      messages = await store.load(conversationId);
    } catch (_) {
      messenger?.showSnackBar(const SnackBar(content: Text('聊天记录读取失败')));
      return;
    }
    final lines = <String>['# 与$title的对话', ''];
    for (final message in messages) {
      final text = message.text?.trim() ?? '';
      final media = message.imageUrl;
      final speaker = switch (message.kind) {
        ChatMessageKind.userText || ChatMessageKind.userImage => '我',
        ChatMessageKind.systemNotice => '系统',
        _ => title,
      };
      if (text.isNotEmpty) {
        lines.add('**$speaker**：$text');
      } else if (media != null && media.isNotEmpty) {
        lines.add('**$speaker**：[媒体文件] $media');
      } else {
        continue;
      }
      lines.add('');
    }
    if (lines.length <= 2) {
      messenger?.showSnackBar(const SnackBar(content: Text('这个对话还没有可导出的消息')));
      return;
    }
    final share =
        shareText ??
        (text) => SharePlus.instance.share(ShareParams(text: text));
    await share(lines.join('\n'));
  }

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '聊天详情',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () => context.canPop()
            ? context.pop()
            : context.go('/chat/$conversationId'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        children: [
          _PeerGrid(conversationId: conversationId),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: HaloSectionLabel('聊天内容'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: HaloSettingsGroup(
              children: [
                HaloSettingsRow(
                  label: '查找聊天记录',
                  onTap: () => context.push('/chat/$conversationId/history'),
                  trailing: Icon(
                    HaloIcon.requirePrototypeClass('ph ph-caret-right'),
                    size: 14,
                    color: HaloColors.muted,
                  ),
                ),
              ],
            ),
          ),
          _AssetShortcuts(conversationId: conversationId),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: HaloSectionLabel('数据'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: HaloSettingsGroup(
              children: [
                HaloSettingsRow(
                  label: '导出聊天记录',
                  detail: 'Markdown',
                  onTap: () => unawaited(_exportTranscript(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PeerGrid extends StatelessWidget {
  const _PeerGrid({required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final identity = ExecutableExpertRegistry.installedExpertIdentities
        .where((identity) => identity.conversationId == conversationId)
        .firstOrNull;
    final installed = identity == null
        ? null
        : HaloFixtures.installedExperts
              .where((expert) => expert.id == identity.profileId)
              .firstOrNull;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Semantics(
              button: identity != null,
              label: '${installed?.name ?? 'Halo 助理'} 资料',
              child: InkWell(
                // Only an installed profile has a profile page to open.
                onTap: identity == null
                    ? null
                    : () => context.push('/expert/${identity.profileId}'),
                borderRadius: BorderRadius.circular(HaloRadii.avatar),
                child: Column(
                  children: [
                    HaloAvatar(
                      imageUrl: installed?.imageUrl,
                      letter: installed?.avatarLetter ?? '助',
                      tone: installed?.avatarTone ?? HaloAvatarTone.blue,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      installed?.name ?? 'Halo 助理',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HaloTextStyles.caption,
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            width: 78,
            child: Semantics(
              button: true,
              label: '添加到群聊',
              child: InkWell(
                onTap: () => context.push('/group/new'),
                borderRadius: BorderRadius.circular(HaloRadii.avatar),
                child: Column(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        border: Border.all(color: HaloColors.line),
                        borderRadius: BorderRadius.circular(HaloRadii.avatar),
                      ),
                      child: Icon(
                        HaloIcon.requirePrototypeClass('ph ph-plus'),
                        color: HaloColors.muted,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text('添加到群聊', style: HaloTextStyles.caption),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssetShortcuts extends StatelessWidget {
  const _AssetShortcuts({required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context) {
    const items = [
      ('ph ph-images', '图片与视频'),
      ('ph ph-files', '文件'),
      ('ph ph-link', '链接'),
      ('ph ph-sparkle', 'AI 成果'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 10, 15, 0),
      child: Row(
        children: [
          for (final item in items)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(11),
                  child: InkWell(
                    onTap: () => context.push(
                      Uri(
                        path: '/chat/$conversationId/history',
                        queryParameters: {'category': item.$2},
                      ).toString(),
                    ),
                    borderRadius: BorderRadius.circular(11),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      child: Column(
                        children: [
                          Icon(
                            HaloIcon.requirePrototypeClass(item.$1),
                            size: 20,
                            color: HaloColors.accentDeep,
                          ),
                          const SizedBox(height: 5),
                          Text(item.$2, style: HaloTextStyles.caption),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
