import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

enum _GroupMode { auto, mention, all, discuss }

class GroupChatPage extends StatefulWidget {
  const GroupChatPage({required this.groupId, super.key});
  final String groupId;

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  _GroupMode mode = _GroupMode.auto;

  String get modeDescription => switch (mode) {
    _GroupMode.auto => '自动选择 1–2 个合适的 Agent',
    _GroupMode.mention => '仅被点名的 Agent 回答',
    _GroupMode.all => '所有 Agent 依次回答',
    _GroupMode.discuss => '所有 Agent 讨论并生成总结',
  };

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: 'iOS 产品小组',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/conversations'),
      ),
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-magnifying-glass',
          semanticLabel: '搜索群消息',
          onPressed: () {},
        ),
        HaloIconButton(
          prototypeIconClass: 'ph ph-dots-three',
          semanticLabel: '群资料',
          onPressed: () => context.push('/group/${widget.groupId}/info'),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 16),
        children: const [
          _CenterNotice('今天 10:12'),
          _CenterNotice('群目标：判断个人 AI 通讯产品的 iOS MVP 是否值得做'),
          _MineGroupBubble(),
          _CenterNotice('自动选择了 产品经理、技术架构师'),
          _ExpertGroupBubble(
            name: '产品经理',
            model: 'Anthropic / claude-sonnet-4',
            letter: '产',
            text: '用户价值是成立的，但首版必须把“联系人就是能力”做透。建议只验证高频工作与资讯场景。',
          ),
          _ExpertGroupBubble(
            name: '技术架构师',
            model: 'OpenAI / gpt-5',
            letter: '技',
            quote: '产品经理：首版只验证高频工作与资讯',
            text: '工程上可行。最大的风险不是 UI，而是消息可靠性、模型编排和长期记忆边界。',
          ),
          _SummaryCard(),
        ],
      ),
      bottom: _GroupComposer(
        selected: mode,
        description: modeDescription,
        onSelected: (value) => setState(() => mode = value),
      ),
    );
  }
}

class _CenterNotice extends StatelessWidget {
  const _CenterNotice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFE4E6EA),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: HaloTextStyles.caption,
        ),
      ),
    );
  }
}

class _MineGroupBubble extends StatelessWidget {
  const _MineGroupBubble();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 60, bottom: 12),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: HaloColors.accent,
          borderRadius: BorderRadius.circular(13),
        ),
        child: const Text(
          '先从用户价值、实现难度和商业化三个角度判断一下。',
          style: TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
        ),
      ),
    );
  }
}

class _ExpertGroupBubble extends StatelessWidget {
  const _ExpertGroupBubble({
    required this.name,
    required this.model,
    required this.letter,
    required this.text,
    this.quote,
  });
  final String name;
  final String model;
  final String letter;
  final String text;
  final String? quote;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HaloAvatar(letter: letter, size: 36),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$name · $model', style: HaloTextStyles.caption),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (quote case final quote?) ...[
                        Container(
                          padding: const EdgeInsets.only(left: 8),
                          decoration: const BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: HaloColors.accent,
                                width: 3,
                              ),
                            ),
                          ),
                          child: Text(quote, style: HaloTextStyles.caption),
                        ),
                        const SizedBox(height: 7),
                      ],
                      Text(text, style: HaloTextStyles.body),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 44),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: HaloColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ColoredBox(
            color: HaloColors.accentDeep,
            child: Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '群聊阶段总结',
                      style: TextStyle(color: Color(0xFFDCE1FF), fontSize: 10),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '先验证个人工作通讯闭环',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '首版聚焦文字对话、可控群聊、Agent 市场和结果沉淀。语音仅保留一对一，群聊不做通话。',
              style: HaloTextStyles.body,
            ),
          ),
          const Divider(height: 1),
          Row(
            children: [
              Expanded(
                child: TextButton(onPressed: null, child: const Text('保存总结')),
              ),
              const SizedBox(height: 38, child: VerticalDivider(width: 1)),
              Expanded(
                child: TextButton(onPressed: null, child: const Text('发布到圈层')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GroupComposer extends StatelessWidget {
  const _GroupComposer({
    required this.selected,
    required this.description,
    required this.onSelected,
  });
  final _GroupMode selected;
  final String description;
  final ValueChanged<_GroupMode> onSelected;

  @override
  Widget build(BuildContext context) {
    const modes = <(_GroupMode, String)>[
      (_GroupMode.auto, '自动选择'),
      (_GroupMode.mention, '@某个 Agent'),
      (_GroupMode.all, '@所有人'),
      (_GroupMode.discuss, '让大家讨论'),
    ];
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFFF8F9FB),
        border: Border(top: BorderSide(color: HaloColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '当前：$description',
                    style: const TextStyle(
                      fontSize: 10,
                      color: HaloColors.accentDeep,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  const Text('如何选择？', style: HaloTextStyles.caption),
                ],
              ),
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final mode in modes)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(mode.$2),
                          selected: selected == mode.$1,
                          onSelected: (_) => onSelected(mode.$1),
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          labelStyle: TextStyle(
                            fontSize: 10,
                            color: selected == mode.$1
                                ? Colors.white
                                : HaloColors.muted,
                          ),
                          selectedColor: HaloColors.accent,
                          backgroundColor: Colors.white,
                          side: BorderSide.none,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  HaloIconButton(
                    prototypeIconClass: 'ph ph-at',
                    semanticLabel: '提及 Agent',
                    onPressed: () {},
                  ),
                  const SizedBox(width: 5),
                  const Expanded(
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: '发消息给这个 AI 小组',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  HaloIconButton(
                    prototypeIconClass: 'ph ph-arrow-up',
                    semanticLabel: '发送',
                    primary: true,
                    onPressed: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
