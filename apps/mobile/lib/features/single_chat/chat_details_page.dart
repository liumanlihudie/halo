import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

class ChatDetailsPage extends StatelessWidget {
  const ChatDetailsPage({required this.conversationId, super.key});
  final String conversationId;

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
          const _AssetShortcuts(),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: HaloSectionLabel('当前会话'),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 13),
            child: HaloSettingsGroup(
              children: [
                HaloSettingsRow(
                  label: '消息免打扰',
                  trailing: HaloSwitch(value: false, onChanged: null),
                ),
                HaloSettingsRow(
                  label: '置顶聊天',
                  trailing: HaloSwitch(value: false, onChanged: null),
                ),
                HaloSettingsRow(
                  label: '重要消息提醒',
                  trailing: HaloSwitch(value: true, onChanged: null),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: HaloSectionLabel('外观与数据'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: HaloSettingsGroup(
              children: [
                HaloSettingsRow(
                  label: '设置当前聊天背景',
                  detail: '默认浅灰',
                  onTap: () {},
                ),
                HaloSettingsRow(
                  label: '导出聊天记录',
                  detail: 'Markdown / JSON / ZIP',
                  onTap: () {},
                ),
                HaloSettingsRow(label: '清空聊天记录', onTap: () {}),
                HaloSettingsRow(label: '反馈专家问题', onTap: () {}),
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
                      imageUrl:
                          installed?.imageUrl ??
                          'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=120',
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
        ],
      ),
    );
  }
}

class _AssetShortcuts extends StatelessWidget {
  const _AssetShortcuts();

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
                    onTap: () {},
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
