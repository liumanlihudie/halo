import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/features/group_chat/group_chat_controller.dart';
import 'package:halo_mobile/features/group_chat/group_chat_history_repository.dart';
import 'package:halo_mobile/features/group_chat/group_members_repository.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';

enum _ComposerChoice { auto, mentioned, all }

class GroupChatPage extends StatefulWidget {
  const GroupChatPage({
    required this.groupId,
    this.runPort,
    this.membersRepository = const PrototypeGroupMembersRepository(),
    this.historyRepository = const PrototypeGroupChatHistoryRepository(),
    super.key,
  });

  final String groupId;
  final GroupChatRunPort? runPort;
  final GroupMembersRepository membersRepository;
  final GroupChatHistoryRepository historyRepository;

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  late final GroupChatController _controller;
  _ComposerChoice _choice = _ComposerChoice.auto;
  List<String> _mentionedAgentIds = const [];

  @override
  void initState() {
    super.initState();
    _controller = GroupChatController(
      runPort: widget.runPort,
      conversationId: widget.groupId,
      membersRepository: widget.membersRepository,
      historyRepository: widget.historyRepository,
    )..addListener(_refresh);
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_refresh)
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
    _ComposerChoice.auto => '自动选择 1–2 位合适成员',
    _ComposerChoice.mentioned =>
      _mentionedAgentIds.isEmpty
          ? '选择 1–4 位成员'
          : '仅 ${_mentionedAgentIds.map(_memberName).join('、')}回答',
    _ComposerChoice.all => '所有 ${_controller.members.length} 位成员依次回答并总结',
  };

  String get _inputHint => switch (_choice) {
    _ComposerChoice.auto => '向小组提问，系统将自动选择成员',
    _ComposerChoice.mentioned =>
      _mentionedAgentIds.isEmpty
          ? '先选择 1–4 位成员'
          : '向已选 ${_mentionedAgentIds.length} 位成员提问',
    _ComposerChoice.all => '向全部成员提问',
  };

  ConversationReplyMode get _replyMode => switch (_choice) {
    _ComposerChoice.auto => ConversationReplyMode.auto,
    _ComposerChoice.mentioned => ConversationReplyMode.mentioned,
    _ComposerChoice.all => ConversationReplyMode.all,
  };

  Future<void> _selectChoice(_ComposerChoice choice) async {
    if (_controller.isRunning) return;
    if (choice == _ComposerChoice.mentioned) {
      final selected = await _showAgentPicker();
      if (selected == null || !mounted) return;
      setState(() {
        _choice = choice;
        _mentionedAgentIds = selected;
      });
      return;
    }
    setState(() {
      _choice = choice;
      _mentionedAgentIds = const [];
    });
  }

  Future<List<String>?> _showAgentPicker() {
    final selectedIds = <String>{..._mentionedAgentIds};
    return showModalBottomSheet<List<String>>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.62,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 2, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '选择 1–4 位成员',
                      style: HaloTextStyles.compactTitle,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final member in _controller.members)
                        CheckboxListTile(
                          value: selectedIds.contains(member.expertId),
                          secondary: HaloAvatar(
                            letter: member.avatarLetter,
                            size: 36,
                          ),
                          title: Text(member.displayName),
                          subtitle: Text(member.role),
                          onChanged:
                              selectedIds.contains(member.expertId) ||
                                  selectedIds.length < 4
                              ? (selected) => setModalState(() {
                                  if (selected ?? false) {
                                    selectedIds.add(member.expertId);
                                  } else {
                                    selectedIds.remove(member.expertId);
                                  }
                                })
                              : null,
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton(
                    onPressed: selectedIds.isEmpty
                        ? null
                        : () => Navigator.pop(
                            context,
                            _controller.members
                                .where(
                                  (member) =>
                                      selectedIds.contains(member.expertId),
                                )
                                .map((member) => member.expertId)
                                .toList(growable: false),
                          ),
                    child: Text('确定（${selectedIds.length}）'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _send() async {
    if (_choice == _ComposerChoice.mentioned && _mentionedAgentIds.isEmpty) {
      await _selectChoice(_ComposerChoice.mentioned);
      if (_mentionedAgentIds.isEmpty) return;
    }
    final input = _inputController.text;
    if (input.trim().isEmpty) return;
    _inputController.clear();
    await _controller.submit(
      input: input,
      mode: _replyMode,
      mentionedAgentIds: _mentionedAgentIds,
    );
  }

  String _memberName(String expertId) =>
      _controller.memberById(expertId)?.displayName ?? expertId;

  _AgentPresentation _presentation(String expertId) =>
      _agent(expertId, _controller.memberById(expertId));

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: 'iOS 产品小组',
      titleBadge: '${_controller.members.length} AI',
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
          _HistoricalGroupTimeline(
            items: _controller.historyItems,
            presentation: _presentation,
          ),
          for (final turn in _controller.pastTurns) ...[
            _MineGroupBubble(text: turn.input),
            for (final message in turn.messages)
              _ExpertGroupBubble(message: message, presentation: _presentation),
            if (turn.summary case final summary?)
              _SummaryCard(summary: summary),
            _RunStatus(
              status: turn.status,
              stage: turn.stage,
              errorCode: turn.errorCode,
            ),
          ],
          if (_controller.submittedInput case final input?)
            _MineGroupBubble(text: input),
          if (_controller.selectedAgentIds.isNotEmpty)
            _CenterNotice(
              '已选择 ${_controller.selectedAgentIds.map(_memberName).join('、')}',
            ),
          if (_controller.replyMode == ConversationReplyMode.all &&
              _controller.runId != null)
            _DiscussionProgress(stage: _controller.stage),
          for (final message in _controller.messages)
            _ExpertGroupBubble(message: message, presentation: _presentation),
          if (_controller.summary case final summary?)
            _SummaryCard(summary: summary),
          if (_controller.status case final status?)
            _RunStatus(
              status: status,
              stage: _controller.stage,
              errorCode: _controller.errorCode,
            ),
        ],
      ),
      bottom: _GroupComposer(
        selected: _choice,
        description: _modeDescription,
        inputHint: _inputHint,
        inputController: _inputController,
        enabled: _controller.canSubmit,
        isRunning: _controller.isRunning,
        stopRequested: _controller.stopRequested,
        onSelected: _selectChoice,
        onMention: () => _selectChoice(_ComposerChoice.mentioned),
        onSend: _send,
        onStop: _controller.stop,
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

_AgentPresentation _agent(String expertId, GroupChatMember? member) =>
    member == null
    ? _AgentPresentation(expertId, 'Agent', 'AI')
    : _AgentPresentation(member.displayName, member.role, member.avatarLetter);

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
  const _HistoricalGroupTimeline({
    required this.items,
    required this.presentation,
  });

  final List<GroupChatHistoryItem> items;
  final _AgentPresentation Function(String) presentation;

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
            presentation: presentation,
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
  const _ExpertGroupBubble({required this.message, required this.presentation});
  final GroupChatAgentMessage message;
  final _AgentPresentation Function(String) presentation;

  @override
  Widget build(BuildContext context) {
    final agent = presentation(message.agentId);
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
    required this.inputHint,
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
  final String inputHint;
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
      (_ComposerChoice.mentioned, '@指定成员'),
      (_ComposerChoice.all, '@所有成员'),
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
                        hintText: enabled ? inputHint : '群聊运行服务待接入',
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
