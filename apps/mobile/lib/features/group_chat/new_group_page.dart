import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class NewGroupPage extends StatefulWidget {
  const NewGroupPage({super.key});

  @override
  State<NewGroupPage> createState() => _NewGroupPageState();
}

class _NewGroupPageState extends State<NewGroupPage> {
  final selected = <String>{'product', 'architect', 'growth'};

  static const choices = [
    (
      'product',
      '产品经理',
      '需求拆解与产品判断',
      'https://images.unsplash.com/photo-1573496359142-b8d87734a5a2?auto=format&fit=crop&w=100&q=75',
      '产',
    ),
    (
      'architect',
      '技术架构师',
      '实现路径与工程风险',
      'https://images.unsplash.com/photo-1560250097-0b93528c311a?auto=format&fit=crop&w=100&q=75',
      '技',
    ),
    ('growth', '增长顾问', '分发、留存和商业化', null, '增'),
    (
      'writing',
      '写作顾问',
      '文档结构与表达',
      'https://images.unsplash.com/photo-1438761681033-6461ffad8d80?auto=format&fit=crop&w=100&q=75',
      '写',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '创建 AI 群聊',
      compactTitle: true,
      backgroundColor: HaloColors.paper,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-x',
        semanticLabel: '取消',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/conversations'),
      ),
      actions: [
        TextButton(
          onPressed: selected.length >= 2
              ? () => context.go('/group/group-product')
              : null,
          child: const Text(
            '完成',
            style: TextStyle(
              color: HaloColors.accentDeep,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(15, 9, 15, 24),
        children: [
          const HaloSearchField(placeholder: '搜索 Agent'),
          const HaloSectionLabel('群名称'),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: HaloColors.soft,
              borderRadius: BorderRadius.circular(HaloRadii.card),
            ),
            child: const Text('新项目评审组', style: HaloTextStyles.body),
          ),
          HaloSectionLabel('选择成员 · 已选 ${selected.length} 个'),
          for (final choice in choices)
            _AgentChoiceRow(
              name: choice.$2,
              description: choice.$3,
              imageUrl: choice.$4,
              letter: choice.$5,
              selected: selected.contains(choice.$1),
              onTap: () => setState(
                () => selected.contains(choice.$1)
                    ? selected.remove(choice.$1)
                    : selected.add(choice.$1),
              ),
            ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => context.push('/market'),
              child: SizedBox(
                height: 62,
                child: Row(
                  children: [
                    const HaloAvatar(letter: '+', size: 46),
                    const SizedBox(width: 11),
                    const Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('从 AI 市场添加', style: HaloTextStyles.rowTitle),
                          SizedBox(height: 4),
                          Text('发现更多专业 Agent', style: HaloTextStyles.caption),
                        ],
                      ),
                    ),
                    Icon(
                      HaloIcon.requirePrototypeClass('ph ph-caret-right'),
                      size: 14,
                      color: HaloColors.muted,
                    ),
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

class _AgentChoiceRow extends StatelessWidget {
  const _AgentChoiceRow({
    required this.name,
    required this.description,
    required this.letter,
    required this.selected,
    required this.onTap,
    this.imageUrl,
  });

  final String name;
  final String description;
  final String letter;
  final String? imageUrl;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              HaloAvatar(imageUrl: imageUrl, letter: letter, size: 46),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: HaloTextStyles.rowTitle),
                    const SizedBox(height: 4),
                    Text(description, style: HaloTextStyles.caption),
                  ],
                ),
              ),
              if (selected)
                const HaloTag('已选', tone: HaloTagTone.green)
              else
                Icon(
                  HaloIcon.requirePrototypeClass('ph ph-plus'),
                  size: 18,
                  color: HaloColors.muted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
