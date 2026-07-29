import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/foundation/design_system/halo_wave_keys_indicator.dart';

import 'chat_message_repository.dart';
import 'single_chat_controller.dart';

class SingleChatPage extends StatefulWidget {
  const SingleChatPage({
    required this.conversationId,
    this.expertId,
    this.service,
    this.repository,
    this.repositoryLoader,
    this.modelRouting,
    this.verifier = const RejectingVerifierReceiptRegistry(),
    this.allowEphemeralRepositoryForTesting = false,
    super.key,
  }) : assert(repository == null || repositoryLoader == null);

  final String conversationId;
  final String? expertId;
  final SingleChatPort? service;
  final ChatMessageRepository? repository;
  final FutureOr<ChatMessageRepository> Function()? repositoryLoader;

  /// Supplies the model actually bound to this expert. Absent in prototype
  /// routes, where the seeded label is the only thing available.
  final ModelRoutingController? modelRouting;
  final TrustedVerifierReceiptRegistry verifier;
  final bool allowEphemeralRepositoryForTesting;

  @override
  State<SingleChatPage> createState() => _SingleChatPageState();
}

class _SingleChatPageState extends State<SingleChatPage> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  late SingleChatConversationProjection _conversation;
  SingleChatController? _chatController;
  bool _dependencyLoadFailed = false;
  bool _conversationNotInstalled = false;
  int _dependencyGeneration = 0;
  String? _modelLabel;

  @override
  void initState() {
    super.initState();
    _resetConversationPlaceholder();
    _startDependencyInitialization();
  }

  @override
  void didUpdateWidget(covariant SingleChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId == widget.conversationId &&
        oldWidget.expertId == widget.expertId &&
        identical(oldWidget.service, widget.service) &&
        identical(oldWidget.repository, widget.repository) &&
        identical(oldWidget.repositoryLoader, widget.repositoryLoader) &&
        identical(oldWidget.verifier, widget.verifier) &&
        oldWidget.allowEphemeralRepositoryForTesting ==
            widget.allowEphemeralRepositoryForTesting) {
      return;
    }
    if (oldWidget.conversationId != widget.conversationId ||
        oldWidget.expertId != widget.expertId) {
      _textController.clear();
    }
    _chatController
      ?..removeListener(_onChatChanged)
      ..dispose();
    _chatController = null;
    _dependencyLoadFailed = false;
    _conversationNotInstalled = false;
    _resetConversationPlaceholder();
    _startDependencyInitialization();
  }

  void _resetConversationPlaceholder() {
    final placeholderExpertId = widget.expertId ?? widget.conversationId;
    _conversation = SingleChatConversationProjection(
      conversationId: widget.conversationId,
      expertId: placeholderExpertId,
      title: widget.conversationId,
      agentName: placeholderExpertId,
      modelLabel: 'Provider / model',
      avatarLetter: placeholderExpertId.isEmpty ? '?' : placeholderExpertId[0],
    );
  }

  void _startDependencyInitialization() {
    final generation = ++_dependencyGeneration;
    final conversationId = widget.conversationId;
    final expertId = widget.expertId;
    final service = widget.service;
    final repository = widget.repository;
    final repositoryLoader = widget.repositoryLoader;
    final verifier = widget.verifier;
    final allowEphemeral = widget.allowEphemeralRepositoryForTesting;
    unawaited(
      _initializeDependencies(
        generation: generation,
        conversationId: conversationId,
        expertId: expertId,
        service: service,
        repository: repository,
        repositoryLoader: repositoryLoader,
        verifier: verifier,
        allowEphemeral: allowEphemeral,
      ),
    );
  }

  Future<void> _initializeDependencies({
    required int generation,
    required String conversationId,
    required String? expertId,
    required SingleChatPort? service,
    required ChatMessageRepository? repository,
    required FutureOr<ChatMessageRepository> Function()? repositoryLoader,
    required TrustedVerifierReceiptRegistry verifier,
    required bool allowEphemeral,
  }) async {
    try {
      final resolvedRepository =
          repository ??
          await Future<ChatMessageRepository>.sync(
            repositoryLoader ?? SingleChatCatalogRepository.new,
          );
      if (service != null &&
          resolvedRepository is! DurableChatMessageRepository &&
          !allowEphemeral) {
        throw StateError(
          'A production single-chat service requires durable repository injection.',
        );
      }
      final SingleChatConversationProjection described;
      try {
        described = resolvedRepository.describe(conversationId);
      } on StateError {
        // The conversation exists in the prototype list but has no installed
        // expert behind it. That is a catalog gap, not a storage failure, and
        // saying "storage is unavailable" sends the user chasing the wrong
        // problem.
        if (mounted && generation == _dependencyGeneration) {
          setState(() => _conversationNotInstalled = true);
        }
        return;
      }
      if (expertId case final override? when override != described.expertId) {
        throw StateError(
          'Single chat expert identity does not match its conversation.',
        );
      }
      if (!mounted || generation != _dependencyGeneration) {
        return;
      }
      final controller = SingleChatController(
        conversationId: conversationId,
        expertId: described.expertId,
        service: service ?? const _UnavailableSingleChatPort(),
        repository: resolvedRepository,
        commandIdFactory: _newCommandId,
        verifier: verifier,
      )..addListener(_onChatChanged);
      setState(() {
        _conversation = described;
        _chatController = controller;
      });
      unawaited(_loadModelLabel(described.expertId));
      await controller.initialize();
    } catch (_) {
      if (mounted && generation == _dependencyGeneration) {
        setState(() {
          _dependencyLoadFailed = true;
        });
      }
    }
  }

  /// Replaces the seeded model label with the binding actually in effect.
  ///
  /// The seed ships a static string, so without this the header can claim a
  /// model is configured when none is.
  Future<void> _loadModelLabel(String canonicalExpertId) async {
    final routing = widget.modelRouting;
    if (routing == null) return;
    try {
      await routing.load();
      await routing.loadExpertOverride(canonicalExpertId);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final effective = routing.effectiveModelFor(canonicalExpertId);
    final option = routing.optionFor(effective);
    setState(() {
      _modelLabel = option == null
          ? '尚未配置模型'
          : '${option.providerName} / ${option.ref.modelId}';
    });
  }

  @override
  void dispose() {
    _chatController
      ?..removeListener(_onChatChanged)
      ..dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onChatChanged() {
    if (mounted) {
      setState(() {});
      _scrollToBottomSoon();
    }
  }

  /// Keeps the newest bubble visible after a send, a projected reply, or a run
  /// status change. Scheduled post-frame because the new extent only exists
  /// once the rebuilt list has laid out.
  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if ((_scrollController.offset - target).abs() < 1) return;
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _send() {
    final text = _textController.text;
    if (text.trim().isEmpty) {
      return;
    }
    final controller = _chatController;
    if (controller == null) {
      return;
    }
    unawaited(controller.submit(text));
    if (controller.activeText == text.trim()) {
      _textController.clear();
    }
    _scrollToBottomSoon();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _chatController;
    final state = controller?.state ?? SingleChatState();
    return HaloPageScaffold(
      title: _conversation.title,
      titleBadge: _conversation.tag,
      titleBadgeTone: _conversation.tagTone,
      compactTitle: true,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/conversations'),
      ),
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-dots-three',
          semanticLabel: '聊天详情',
          onPressed: () =>
              context.push('/chat/${widget.conversationId}/details'),
        ),
      ],
      backgroundColor: HaloColors.soft,
      body: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        children: [
          if (_conversationNotInstalled)
            const _SystemNotice('这个联系人还没有可执行的专家，暂时无法对话。')
          else if (_dependencyLoadFailed)
            const _SystemNotice('聊天存储暂不可用，请稍后重试'),
          if (state.historyLoadFailed) const _SystemNotice('历史消息加载失败，可继续当前对话'),
          for (final message in state.messages)
            _ProjectedMessage(
              message: message,
              conversation: _conversation,
              modelLabel: _modelLabel,
            ),
          if (state.status == SingleChatRunStatus.running)
            _AgentBubble(
              conversation: _conversation,
              modelLabel: _modelLabel,
              child: _ProgressMessage(onStop: controller!.stop),
            ),
          if (_terminalMessage(state.status) case final terminal?)
            _AgentBubble(
              conversation: _conversation,
              modelLabel: _modelLabel,
              child: _RunStatusMessage(
                text: terminal,
                canRetry: state.canRetry,
                onRetry: controller!.retry,
                onConfigure: state.status == SingleChatRunStatus.notConfigured
                    ? () => context.push('/settings/providers')
                    : null,
              ),
            ),
        ],
      ),
      bottom: _Composer(
        controller: _textController,
        onAttach: () => _showAttachmentSheet(context),
        onSend: _send,
        enabled:
            controller != null &&
            !_dependencyLoadFailed &&
            !_conversationNotInstalled,
      ),
    );
  }
}

class _ProjectedMessage extends StatelessWidget {
  const _ProjectedMessage({
    required this.message,
    required this.conversation,
    this.modelLabel,
  });

  final ChatMessageProjection message;
  final SingleChatConversationProjection conversation;
  final String? modelLabel;

  @override
  Widget build(BuildContext context) {
    return switch (message.kind) {
      ChatMessageKind.systemNotice => _SystemNotice(message.text ?? ''),
      ChatMessageKind.userText => _MineBubble(message.text ?? ''),
      ChatMessageKind.agentText => _AgentBubble(
        conversation: conversation,
        modelLabel: modelLabel,
        child: _AgentTextMessage(message),
      ),
      ChatMessageKind.progress => _AgentBubble(
        conversation: conversation,
        modelLabel: modelLabel,
        child: _ProgressMessage(message: message),
      ),
      ChatMessageKind.file => _AgentBubble(
        conversation: conversation,
        child: _FileMessage(message),
      ),
      ChatMessageKind.userImage => _MineImageMessage(message.imageUrl),
      ChatMessageKind.quote => _AgentBubble(
        conversation: conversation,
        child: _QuoteMessage(message),
      ),
    };
  }
}

class _AgentTextMessage extends StatelessWidget {
  const _AgentTextMessage(this.message);

  final ChatMessageProjection message;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message.text ?? '', style: HaloTextStyles.body),
        if (message.sourceType case final source?) ...[
          const SizedBox(height: 7),
          Text(
            _sourceLabel(source, message.evidenceReferences),
            style: const TextStyle(
              color: HaloColors.muted,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (message.sourceType == ChatMessageSourceType.verifiedEvidence ||
            isSafeSingleChatUncertaintyDisclosure(message.uncertainty)) ...[
          const SizedBox(height: 5),
          Text(
            '不确定性：${isSafeSingleChatUncertaintyDisclosure(message.uncertainty) ? message.uncertainty : '未提供不确定性说明'}',
            style: HaloTextStyles.caption,
          ),
        ],
      ],
    );
  }
}

class _SystemNotice extends StatelessWidget {
  const _SystemNotice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFE5E7EB),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: HaloTextStyles.caption),
      ),
    );
  }
}

class _MineBubble extends StatelessWidget {
  const _MineBubble(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 286),
        margin: const EdgeInsets.only(left: 55, bottom: 13),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: const BoxDecoration(
          color: HaloColors.accent,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(13),
            topRight: Radius.circular(4),
            bottomLeft: Radius.circular(13),
            bottomRight: Radius.circular(13),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

class _AgentBubble extends StatelessWidget {
  const _AgentBubble({
    required this.conversation,
    required this.child,
    this.modelLabel,
  });

  final SingleChatConversationProjection conversation;
  final Widget child;

  /// The binding actually in effect. Falls back to the seeded label only when
  /// no routing controller is available (prototype routes).
  final String? modelLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HaloAvatar(
            imageUrl: conversation.avatarImageUrl,
            letter: conversation.avatarLetter,
            size: 36,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${conversation.agentName} · ${modelLabel ?? conversation.modelLabel}',
                  style: HaloTextStyles.caption,
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: HaloColors.paper,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: child,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressMessage extends StatelessWidget {
  const _ProgressMessage({this.message, this.onStop});

  final ChatMessageProjection? message;
  final Future<void> Function()? onStop;

  @override
  Widget build(BuildContext context) {
    final progress = message?.progress;
    return SizedBox(
      width: 235,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  message?.text ?? '任务进行中',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              if (progress != null)
                Text(
                  '${(progress * 100).round()}%',
                  style: const TextStyle(
                    color: HaloColors.accentDeep,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (progress == null)
            const HaloWaveKeysIndicator()
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 5,
                backgroundColor: HaloColors.line,
                color: HaloColors.accent,
              ),
            ),
          if (message?.secondaryText case final secondary?) ...[
            const SizedBox(height: 7),
            Text(secondary, style: HaloTextStyles.caption),
          ],
          if (onStop != null) ...[
            const SizedBox(height: 8),
            Semantics(
              button: true,
              label: '停止生成',
              child: ExcludeSemantics(
                child: OutlinedButton.icon(
                  onPressed: () => unawaited(onStop!()),
                  icon: Icon(
                    HaloIcon.requirePrototypeClass('ph ph-stop-circle'),
                    size: 15,
                  ),
                  label: const Text('停止'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RunStatusMessage extends StatelessWidget {
  const _RunStatusMessage({
    required this.text,
    required this.canRetry,
    required this.onRetry,
    this.onConfigure,
  });

  final String text;
  final bool canRetry;
  final Future<void> Function() onRetry;

  /// Present only when the run failed because nothing is configured yet, so the
  /// user gets the one action that can actually resolve it.
  final VoidCallback? onConfigure;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: HaloTextStyles.body),
        if (canRetry) ...[
          const SizedBox(height: 8),
          Semantics(
            button: true,
            label: '重试发送',
            child: ExcludeSemantics(
              child: OutlinedButton(
                onPressed: () => unawaited(onRetry()),
                child: const Text('重试'),
              ),
            ),
          ),
        ],
        if (onConfigure case final configure?) ...[
          const SizedBox(height: 8),
          Semantics(
            button: true,
            label: '配置模型服务',
            child: ExcludeSemantics(
              child: FilledButton(
                onPressed: configure,
                child: const Text('去配置模型服务'),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _FileMessage extends StatelessWidget {
  const _FileMessage(this.message);
  final ChatMessageProjection message;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 235,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 43,
                height: 50,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFE95A61),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'PDF',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message.text ?? '',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      message.secondaryText ?? '',
                      style: HaloTextStyles.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 18),
          Text(message.tertiaryText ?? '', style: HaloTextStyles.caption),
        ],
      ),
    );
  }
}

class _MineImageMessage extends StatelessWidget {
  const _MineImageMessage(this.imageUrl);
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    if (imageUrl == null) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.centerRight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Image.network(
          imageUrl!,
          width: 210,
          height: 128,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _QuoteMessage extends StatelessWidget {
  const _QuoteMessage(this.message);
  final ChatMessageProjection message;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 235,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(
                left: BorderSide(color: HaloColors.accent, width: 3),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                message.secondaryText ?? '',
                style: HaloTextStyles.caption,
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(message.text ?? '', style: HaloTextStyles.body),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onAttach,
    required this.onSend,
    required this.enabled,
  });

  final TextEditingController controller;
  final VoidCallback onAttach;
  final VoidCallback onSend;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFFF8F9FB),
        border: Border(top: BorderSide(color: HaloColors.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  _QuickAction('导出成果'),
                  SizedBox(width: 7),
                  _QuickAction('查看来源'),
                ],
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  HaloIconButton(
                    prototypeIconClass: 'ph ph-microphone',
                    semanticLabel: '语音输入（暂不可用）',
                    onPressed: () => _showUnavailable(context),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      enabled: enabled,
                      minLines: 1,
                      maxLines: 4,
                      onSubmitted: (_) => onSend(),
                      decoration: const InputDecoration(
                        hintText: '输入消息，或继续追问成果',
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
                  const SizedBox(width: 5),
                  HaloIconButton(
                    prototypeIconClass: 'ph ph-plus',
                    semanticLabel: '添加附件',
                    onPressed: enabled ? onAttach : null,
                  ),
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

class _QuickAction extends StatelessWidget {
  const _QuickAction(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: HaloColors.line),
      ),
      child: Text(label, style: HaloTextStyles.caption),
    );
  }
}

void _showAttachmentSheet(BuildContext context) {
  const abilities = <(String, String)>[
    ('ph ph-phone', '端到端语音通话'),
    ('ph ph-video-camera', 'Vidu 视频通话'),
    ('ph ph-camera', '拍照'),
    ('ph ph-image', '图片'),
    ('ph ph-file', '文件'),
    ('ph ph-scan', '扫描'),
    ('ph ph-link', '网页'),
    ('ph ph-microphone', '录音'),
  ];
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) => Container(
      padding: const EdgeInsets.fromLTRB(15, 9, 15, 24),
      decoration: const BoxDecoration(
        color: HaloColors.soft,
        borderRadius: BorderRadius.vertical(top: Radius.circular(23)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 13),
              decoration: BoxDecoration(
                color: const Color(0xFFC9CCD2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Text(
              '发送与通话',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 13),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: .82,
              children: [
                for (final ability in abilities)
                  Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(13),
                    child: InkWell(
                      onTap: () => _showUnavailable(sheetContext),
                      borderRadius: BorderRadius.circular(13),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              HaloIcon.requirePrototypeClass(ability.$1),
                              size: 23,
                              color: HaloColors.ink,
                            ),
                            const SizedBox(height: 7),
                            Text(
                              ability.$2,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              '暂不可用',
                              style: TextStyle(
                                fontSize: 7,
                                color: HaloColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

void _showUnavailable(BuildContext context) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(const SnackBar(content: Text('该能力暂不可用')));
}

String _newCommandId() {
  return MonotonicUlidGenerator.shared.next();
}

String? _terminalMessage(SingleChatRunStatus status) {
  return switch (status) {
    SingleChatRunStatus.stopped => '任务已停止',
    SingleChatRunStatus.failed => '发送失败，请重试',
    SingleChatRunStatus.quotaLimited => '模型额度不足，请检查 Provider 配额',
    SingleChatRunStatus.authentication => '模型认证失败，请检查 Provider 配置',
    SingleChatRunStatus.filtered => '内容未通过安全检查',
    SingleChatRunStatus.notConfigured => '尚未配置可用的文字模型，请先在设置里保存模型服务并选择默认模型。',
    SingleChatRunStatus.idle ||
    SingleChatRunStatus.running ||
    SingleChatRunStatus.completed => null,
  };
}

class _UnavailableSingleChatPort implements SingleChatPort {
  const _UnavailableSingleChatPort();

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) async {
    return SingleAgentRunHandle(
      runId: request.clientCommandId,
      outcome: Future.value(
        const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.authentication,
        ),
      ),
    );
  }

  @override
  Future<void> stopSingleAgentRun(String runId) async {}
}

String _sourceLabel(
  ChatMessageSourceType source,
  List<String> evidenceReferences,
) {
  return switch (source) {
    ChatMessageSourceType.verifiedEvidence => '已核验',
    ChatMessageSourceType.userVisibleSummary => '用户可见摘要',
    ChatMessageSourceType.modelOutput =>
      evidenceReferences.isEmpty ? '未核验' : '模型输出 · 附来源',
  };
}
