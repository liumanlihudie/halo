import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
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
          HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '群名称',
                detail: 'iOS 产品小组',
                prototypeIconClass: 'ph ph-users-three',
                onTap: () {},
              ),
              HaloSettingsRow(
                label: '群目标',
                detail: '验证 iOS MVP',
                prototypeIconClass: 'ph ph-target',
                onTap: () {},
              ),
              HaloSettingsRow(
                label: '主持 Agent',
                detail: '产品经理',
                prototypeIconClass: 'ph ph-user',
                onTap: () {},
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: HaloSectionLabel('发言与上下文'),
          ),
          HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '默认发言规则',
                detail: '自动选择',
                prototypeIconClass: 'ph ph-path',
                onTap: () {},
              ),
              HaloSettingsRow(
                label: '共享上下文',
                detail: '3 个来源',
                prototypeIconClass: 'ph ph-brain',
                onTap: () => context.push('/group/$groupId/context'),
              ),
              const HaloSettingsRow(
                label: '每次讨论自动总结',
                prototypeIconClass: 'ph ph-sparkle',
                trailing: Switch.adaptive(value: true, onChanged: null),
              ),
              const HaloSettingsRow(
                label: '讨论总结发布到圈层',
                prototypeIconClass: 'ph ph-circles-three',
                trailing: Switch.adaptive(value: true, onChanged: null),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: HaloSectionLabel('群聊内容'),
          ),
          HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '查找群聊记录',
                prototypeIconClass: 'ph ph-magnifying-glass',
                onTap: () {},
              ),
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
      ('产', '产品经理'),
      ('交', '交互设计'),
      ('技', '技术架构'),
      ('增', '增长顾问'),
      ('+', '添加'),
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
