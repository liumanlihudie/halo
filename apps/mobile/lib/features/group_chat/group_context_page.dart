import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class GroupContextPage extends StatelessWidget {
  const GroupContextPage({required this.groupId, super.key});
  final String groupId;

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '共享上下文',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () => context.canPop()
            ? context.pop()
            : context.go('/group/$groupId/info'),
      ),
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-plus',
          semanticLabel: '添加上下文',
          onPressed: () {},
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(15, 0, 15, 24),
        children: [
          const HaloSectionLabel('群内 Agent 均可读取'),
          HaloSettingsGroup(
            children: [
              _ContextRow(
                title: 'IOS-IM 产品规格',
                subtitle: 'Markdown · 今天更新',
                trailing: const Text('已共享', style: HaloTextStyles.caption),
                onTap: () => context.push('/media/file'),
              ),
              _ContextRow(
                title: '竞品研究资料',
                subtitle: '文件夹 · 8 个来源',
                trailing: _TrailingText('只读'),
                onTap: () {},
              ),
              const _ContextRow(
                title: '用户长期偏好',
                subtitle: '共享事实记忆',
                trailing: HaloSwitch(
                  value: true,
                  onChanged: null,
                  semanticLabel: '共享用户长期偏好',
                ),
              ),
            ],
          ),
          const HaloSectionLabel('不会共享'),
          HaloSettingsGroup(
            children: [
              _ContextRow(
                title: 'Agent 私有关系记忆',
                subtitle: '称呼、相处方式和私聊内容',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const HaloTag('隔离', tone: HaloTagTone.gray),
                    const SizedBox(width: 5),
                    Icon(
                      HaloIcon.requirePrototypeClass('ph ph-caret-right'),
                      size: 13,
                      color: HaloColors.muted,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ContextRow extends StatelessWidget {
  const _ContextRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 58),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: HaloColors.ink,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(subtitle, style: HaloTextStyles.caption),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrailingText extends StatelessWidget {
  const _TrailingText(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: HaloTextStyles.caption),
        const SizedBox(width: 5),
        Icon(
          HaloIcon.requirePrototypeClass('ph ph-caret-right'),
          size: 13,
          color: HaloColors.muted,
        ),
      ],
    );
  }
}
