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
    const sources = [
      ('ph ph-file-text', 'iOS MVP 产品范围.md', '文件 · 28 KB · 全部 Agent 可读'),
      ('ph ph-link', '竞品功能与价格快照', '网页 · 今天 09:40 更新'),
      ('ph ph-brain', '产品决策共享记忆', '记忆 · 42 条事实'),
    ];
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
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 24),
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              color: HaloColors.accentSoft,
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '群内 Agent 只会读取你明确添加的文件、网页与共享记忆。移除后不会继续用于新回答。',
                style: TextStyle(
                  color: HaloColors.accentDeep,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ),
          ),
          const HaloSectionLabel('当前来源 · 3'),
          HaloSettingsGroup(
            children: [
              for (final source in sources)
                HaloSettingsRow(
                  label: source.$2,
                  detail: source.$3,
                  prototypeIconClass: source.$1,
                  trailing: Icon(
                    HaloIcon.requirePrototypeClass('ph ph-dots-three'),
                    size: 16,
                    color: HaloColors.muted,
                  ),
                  onTap: () {},
                ),
            ],
          ),
          const HaloSectionLabel('上下文规则'),
          const HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '允许 Agent 相互引用观点',
                prototypeIconClass: 'ph ph-chat-circle-dots',
                trailing: Switch.adaptive(value: true, onChanged: null),
              ),
              HaloSettingsRow(
                label: '回答必须附带来源',
                prototypeIconClass: 'ph ph-check-circle',
                trailing: Switch.adaptive(value: true, onChanged: null),
              ),
              HaloSettingsRow(
                label: '冲突证据自动交给核查员',
                prototypeIconClass: 'ph ph-warning-circle',
                trailing: Switch.adaptive(value: true, onChanged: null),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
