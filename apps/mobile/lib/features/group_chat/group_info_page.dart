import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class GroupInfoPage extends StatelessWidget {
  const GroupInfoPage({required this.groupId, super.key});
  final String groupId;

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '群资料',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/group/$groupId'),
      ),
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-share-network',
          semanticLabel: '分享群聊',
          onPressed: () {},
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const _MemberStrip(),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: HaloSectionLabel('群聊信息'),
          ),
          _InsetGroup(
            children: [
              HaloSettingsRow(label: '群名称', detail: 'iOS 产品小组', onTap: () {}),
              HaloSettingsRow(label: '群目标', detail: '验证 iOS MVP', onTap: () {}),
              HaloSettingsRow(label: '主持 Agent', detail: '产品经理', onTap: () {}),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: HaloSectionLabel('发言与上下文'),
          ),
          _InsetGroup(
            children: [
              HaloSettingsRow(label: '默认发言规则', detail: '自动选择', onTap: () {}),
              HaloSettingsRow(
                label: '共享上下文',
                detail: '3 个来源',
                onTap: () => context.push('/group/$groupId/context'),
              ),
              const HaloSettingsRow(
                label: '每次讨论自动总结',
                trailing: HaloSwitch(value: true, onChanged: null),
              ),
              const HaloSettingsRow(
                label: '讨论总结发布到圈层',
                trailing: HaloSwitch(value: true, onChanged: null),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: HaloSectionLabel('群聊内容'),
          ),
          _InsetGroup(
            children: [HaloSettingsRow(label: '查找群聊记录', onTap: () {})],
          ),
          const _AssetShortcuts(),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: HaloSectionLabel('当前群聊'),
          ),
          const _InsetGroup(
            children: [
              HaloSettingsRow(
                label: '消息免打扰',
                trailing: HaloSwitch(value: false, onChanged: null),
              ),
              HaloSettingsRow(
                label: '置顶群聊',
                trailing: HaloSwitch(value: false, onChanged: null),
              ),
              HaloSettingsRow(
                label: '讨论完成提醒',
                trailing: HaloSwitch(value: true, onChanged: null),
              ),
              HaloSettingsRow(label: '设置当前群聊背景', detail: '默认浅灰'),
              HaloSettingsRow(label: '导出群聊记录', detail: 'Markdown / JSON / ZIP'),
            ],
          ),
          const SizedBox(height: 10),
          const _InsetGroup(
            children: [
              HaloSettingsRow(label: '清空群聊记录', detail: '保留群配置'),
              HaloSettingsRow(label: '删除群聊'),
            ],
          ),
        ],
      ),
    );
  }
}

class _MemberStrip extends StatelessWidget {
  const _MemberStrip();

  @override
  Widget build(BuildContext context) {
    const members = [
      (
        '产',
        '产品经理',
        'https://images.unsplash.com/photo-1573496359142-b8d87734a5a2?auto=format&fit=crop&w=100&q=75',
      ),
      (
        '交',
        '交互设计',
        'https://images.unsplash.com/photo-1494790108377-be9c29b29330?auto=format&fit=crop&w=100&q=75',
      ),
      (
        '技',
        '技术架构',
        'https://images.unsplash.com/photo-1560250097-0b93528c311a?auto=format&fit=crop&w=100&q=75',
      ),
      ('增', '增长顾问', null),
      ('+', '添加', null),
    ];
    return SizedBox(
      height: 94,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        scrollDirection: Axis.horizontal,
        itemCount: members.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) => SizedBox(
          width: 58,
          child: Column(
            children: [
              HaloAvatar(
                letter: members[index].$1,
                imageUrl: members[index].$3,
                size: 48,
                backgroundColor: index == members.length - 1
                    ? HaloColors.muted
                    : HaloColors.accent,
              ),
              const SizedBox(height: 5),
              Text(
                members[index].$2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HaloTextStyles.caption,
              ),
            ],
          ),
        ),
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

class _InsetGroup extends StatelessWidget {
  const _InsetGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13),
      child: HaloSettingsGroup(children: children),
    );
  }
}
