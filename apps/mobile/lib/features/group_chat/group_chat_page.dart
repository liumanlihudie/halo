import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/features/group_chat/group_chat_controller.dart';
import 'package:halo_mobile/features/group_chat/group_chat_history_repository.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/orchestration/orchestration_kernel.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/orchestration_providers.dart';

enum _ComposerChoice { auto, mentioned, all, discuss }

class GroupChatPage extends ConsumerStatefulWidget {
  const GroupChatPage({
    required this.groupId,
    this.orchestrationKernel,
    super.key,
  });

  final String groupId;
  final OrchestrationKernel? orchestrationKernel;

  @override
  ConsumerState<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends ConsumerState<GroupChatPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  GroupChatController? _controller;
  late final List<GroupChatHistoryItem> _history;
  _ComposerChoice _choice = _ComposerChoice.auto;
  String? _mentionedAgentId;

  @override
  void initState() {
    super.initState();
    final OrchestrationKernel kernel =
        widget.orchestrationKernel ?? ref.read(orchestrationKernelProvider);
    _history = const PrototypeGroupChatHistoryRepository().load(widget.groupId);
    _controller = GroupChatController(
      kernel: kernel,
      conversationId: widget.groupId,
    )..addListener(_refresh);
  }

  @override
  void dispose() {
    _controller
      ?..removeListener(_refresh)
      ..dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  String get _modeDescription => switch (_choice) {
    _ComposerChoice.auto => '自动选择 1–2 个合适的 Agent',
    _ComposerChoice.mentioned =>
      _mentionedAgentId == null
          ? '选择一个 Agent 回答'
          : '仅${_agent(_mentionedAgentId!).name}回答',
    _ComposerChoice.all => '所有 Agent 依次回答',
    _ComposerChoice.discuss => '所有 Agent 讨论并生成总结',
  };

  ConversationReplyMode get _replyMode => switch (_choice) {
    _ComposerChoice.auto => ConversationReplyMode.auto,
    _ComposerChoice.mentioned => ConversationReplyMode.mentioned,
    _ComposerChoice.all || _ComposerChoice.discuss => ConversationReplyMode.all,
  };

  Future<void> _selectChoice(_ComposerChoice choice) async {
    if (_controller?.isRunning ?? false) return;
    if (choice == _ComposerChoice.mentioned) {
      final selected = await _showAgentPicker();
      if (selected == null || !mounted) return;
      setState(() {
        _choice = choice;
        _mentionedAgentId = selected;
      });
      return;
    }
    setState(() {
      _choice = choice;
      _mentionedAgentId = null;
    });
  }

  Future<String?> _showAgentPicker() => showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.55,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 2, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('选择回答的 Agent', style: HaloTextStyles.compactTitle),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final agentId in groupChatMemberAgentIds)
                    ListTile(
                      leading: HaloAvatar(
                        letter: _agent(agentId).letter,
                        size: 36,
                      ),
                      title: Text(_agent(agentId).name),
                      subtitle: Text(_agent(agentId).role),
                      onTap: () => Navigator.pop(context, agentId),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _send() async {
    final controller = _controller;
    if (controller == null) return;
    if (_choice == _ComposerChoice.mentioned && _mentionedAgentId == null) {
      await _selectChoice(_ComposerChoice.mentioned);
      if (_mentionedAgentId == null) return;
    }
    final input = _inputController.text;
    if (input.trim().isEmpty) return;
    _inputController.clear();
    await controller.submit(
      input: input,
      mode: _replyMode,
      mentionedAgentIds: _mentionedAgentId == null
          ? const []
          : [_mentionedAgentId!],
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return HaloPageScaffold(
      title: 'iOS 产品小组',
      titleBadge: '4 AI',
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
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 16),
        children: [
          const _CenterNotice('群目标：判断个人 AI 通讯产品的 iOS MVP 是否值得做'),
          _HistoricalGroupTimeline(items: _history),
          if (controller != null)
            for (final turn in controller.pastTurns) ...[
              _MineGroupBubble(text: turn.input),
              for (final message in turn.messages)
                _ExpertGroupBubble(message: message),
              if (turn.summary case final summary?)
                _SummaryCard(summary: summary),
              _RunStatus(
                status: turn.status,
                stage: turn.stage,
                errorCode: turn.errorCode,
              ),
            ],
          if (controller?.submittedInput case final input?)
            _MineGroupBubble(text: input),
          if (controller != null) ...[
            if (controller.selectedAgentIds.isNotEmpty)
              _CenterNotice(
                '已选择 ${controller.selectedAgentIds.map((id) => _agent(id).name).join('、')}',
              ),
            if (controller.replyMode == ConversationReplyMode.all &&
                controller.runId != null)
              _DiscussionProgress(stage: controller.stage),
            for (final message in controller.messages)
              _ExpertGroupBubble(message: message),
            if (controller.summary case final summary?)
              _SummaryCard(summary: summary),
            if (controller.status case final status?)
              _RunStatus(
                status: status,
                stage: controller.stage,
                errorCode: controller.errorCode,
              ),
          ],
        ],
      ),
      bottom: _GroupComposer(
        selected: _choice,
        description: _modeDescription,
        inputController: _inputController,
        enabled: controller != null,
        isRunning: controller?.isRunning ?? false,
        stopRequested: controller?.stopRequested ?? false,
        onSelected: _selectChoice,
        onMention: () => _selectChoice(_ComposerChoice.mentioned),
        onSend: _send,
        onStop: controller?.stop,
      ),
    );
  }
}

class _AgentPresentation {
  const _AgentPresentation(this.name, this.role, this.letter);
  final String name;
  final String role;
  final String letter;
}

_AgentPresentation _agent(String agentId) => switch (agentId) {
  'product-manager' => const _AgentPresentation('产品经理', '产品判断与需求拆解', '产'),
  'interaction-designer' => const _AgentPresentation('交互设计师', '体验与交互方案', '设'),
  'technical-architect' => const _AgentPresentation('技术架构师', '架构与工程风险', '技'),
  'growth-advisor' => const _AgentPresentation('增长顾问', '增长与验证策略', '增'),
  _ => _AgentPresentation(agentId, 'Agent', 'AI'),
};

class _CenterNotice extends StatelessWidget {
  const _CenterNotice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Align(
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

class _HistoricalGroupTimeline extends StatelessWidget {
  const _HistoricalGroupTimeline({required this.items});

  final List<GroupChatHistoryItem> items;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final item in items)
        switch (item.type) {
          GroupChatHistoryItemType.notice => _CenterNotice(item.text),
          GroupChatHistoryItemType.userMessage => _MineGroupBubble(
            text: item.text,
          ),
          GroupChatHistoryItemType.agentMessage => _ExpertGroupBubble(
            message: GroupChatAgentMessage(
              agentId: item.agentId!,
              text: item.text,
              status: GroupChatMessageStatus.completed,
            ),
          ),
          GroupChatHistoryItemType.summary => _SummaryCard(
            title: item.title ?? '群聊总结',
            summary: item.text,
          ),
        },
    ],
  );
}

class _MineGroupBubble extends StatelessWidget {
  const _MineGroupBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      margin: const EdgeInsets.only(left: 60, bottom: 12),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: HaloColors.accent,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
      ),
    ),
  );
}

class _ExpertGroupBubble extends StatelessWidget {
  const _ExpertGroupBubble({required this.message});
  final GroupChatAgentMessage message;

  @override
  Widget build(BuildContext context) {
    final agent = _agent(message.agentId);
    final isRunning = message.status == GroupChatMessageStatus.running;
    final isFailed = message.status == GroupChatMessageStatus.failed;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HaloAvatar(letter: agent.letter, size: 36),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(agent.name, style: HaloTextStyles.caption),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: isFailed ? const Color(0xFFFFF1F0) : Colors.white,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Text(
                    isRunning
                        ? '正在思考…'
                        : message.text.isEmpty && isFailed
                        ? '回答失败'
                        : message.text,
                    style: HaloTextStyles.body,
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

class _DiscussionProgress extends StatelessWidget {
  const _DiscussionProgress({required this.stage});
  final ConversationStage? stage;

  int get _activeIndex => switch (stage) {
    ConversationStage.crossDiscussion => 1,
    ConversationStage.summarizing || ConversationStage.completed => 2,
    _ => 0,
  };

  @override
  Widget build(BuildContext context) {
    const labels = ['观点收集', '交叉讨论', '群聊总结'];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (var index = 0; index < labels.length; index++) ...[
            Expanded(
              child: Column(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: index <= _activeIndex
                          ? HaloColors.accent
                          : HaloColors.line,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    labels[index],
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: index == _activeIndex
                          ? FontWeight.w700
                          : FontWeight.w400,
                      color: index <= _activeIndex
                          ? HaloColors.accentDeep
                          : HaloColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (index < labels.length - 1)
              const Expanded(child: Divider(height: 1)),
          ],
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary, this.title = '群聊总结'});
  final String summary;
  final String title;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 44, bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: HaloColors.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: HaloColors.accentDeep,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(summary, style: HaloTextStyles.body),
      ],
    ),
  );
}

class _RunStatus extends StatelessWidget {
  const _RunStatus({
    required this.status,
    required this.stage,
    required this.errorCode,
  });

  final OrchestrationRunStatus status;
  final ConversationStage? stage;
  final String? errorCode;

  String get _label => switch (status) {
    OrchestrationRunStatus.running => switch (stage) {
      ConversationStage.selectingAgents => '正在选择 Agent',
      ConversationStage.collectingOpinions => '观点收集中',
      ConversationStage.crossDiscussion => '交叉讨论中',
      ConversationStage.summarizing => '正在生成群聊总结',
      _ => '运行中',
    },
    OrchestrationRunStatus.completed => '已完成',
    OrchestrationRunStatus.failed => '运行失败',
    OrchestrationRunStatus.stopped => '已停止',
  };

  @override
  Widget build(BuildContext context) => _CenterNotice(
    errorCode == null || status != OrchestrationRunStatus.failed
        ? _label
        : '$_label · $errorCode',
  );
}

class _GroupComposer extends StatelessWidget {
  const _GroupComposer({
    required this.selected,
    required this.description,
    required this.inputController,
    required this.enabled,
    required this.isRunning,
    required this.stopRequested,
    required this.onSelected,
    required this.onMention,
    required this.onSend,
    required this.onStop,
  });

  final _ComposerChoice selected;
  final String description;
  final TextEditingController inputController;
  final bool enabled;
  final bool isRunning;
  final bool stopRequested;
  final ValueChanged<_ComposerChoice> onSelected;
  final VoidCallback onMention;
  final VoidCallback onSend;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    const modes = <(_ComposerChoice, String)>[
      (_ComposerChoice.auto, '自动选择'),
      (_ComposerChoice.mentioned, '@某个 Agent'),
      (_ComposerChoice.all, '@所有人'),
      (_ComposerChoice.discuss, '让大家讨论'),
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
              Text(
                '当前：$description',
                style: const TextStyle(
                  fontSize: 10,
                  color: HaloColors.accentDeep,
                  fontWeight: FontWeight.w600,
                ),
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
                          onSelected: enabled && !isRunning
                              ? (_) => onSelected(mode.$1)
                              : null,
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
                    onPressed: enabled && !isRunning ? onMention : null,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: TextField(
                      controller: inputController,
                      enabled: enabled && !isRunning,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      decoration: InputDecoration(
                        hintText: enabled ? '发消息给这个 AI 小组' : '编排服务待接入',
                        filled: true,
                        fillColor: Colors.white,
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  if (isRunning)
                    HaloIconButton(
                      prototypeIconClass: 'ph ph-stop-circle',
                      semanticLabel: '停止生成',
                      primary: true,
                      onPressed: stopRequested ? null : onStop,
                    )
                  else
                    HaloIconButton(
                      prototypeIconClass: 'ph ph-arrow-up',
                      semanticLabel: '发送',
                      primary: true,
                      onPressed: enabled ? onSend : null,
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
