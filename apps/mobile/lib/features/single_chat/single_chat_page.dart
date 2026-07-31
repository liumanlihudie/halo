import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/features/single_chat/attachments/voice_recorder_service.dart';
import 'package:halo_mobile/features/single_chat/voice_message_bubble.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_markdown_body.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/foundation/design_system/halo_wave_keys_indicator.dart';

import 'attachments/chat_attachment_service.dart';
import 'chat_message_repository.dart';
import 'message_actions_service.dart';
import 'single_chat_controller.dart';

class SingleChatPage extends StatefulWidget {
  const SingleChatPage({
    required this.conversationId,
    this.expertId,
    this.service,
    this.repository,
    this.repositoryLoader,
    this.modelRouting,
    this.messageActions,
    this.voiceRecorder,
    this.speech,
    this.verifier = const RejectingVerifierReceiptRegistry(),
    this.allowEphemeralRepositoryForTesting = false,
    super.key,
  }) : assert(repository == null || repositoryLoader == null);

  final String conversationId;
  final String? expertId;
  final SingleChatPort? service;

  /// Speech synthesis and transcription. Absent when no 豆包语音 key is stored,
  /// which disables voice rather than failing a text conversation.
  final SingleChatSpeech? speech;
  final ChatMessageRepository? repository;
  final FutureOr<ChatMessageRepository> Function()? repositoryLoader;

  /// Supplies the model actually bound to this expert. Absent in prototype
  /// routes, where the seeded label is the only thing available.
  final ModelRoutingController? modelRouting;

  /// Injectable so tests exercise the long-press menu without system channels.
  final MessageActionsService? messageActions;
  final VoiceRecorderService? voiceRecorder;
  final TrustedVerifierReceiptRegistry verifier;
  final bool allowEphemeralRepositoryForTesting;

  @override
  State<SingleChatPage> createState() => _SingleChatPageState();
}

class _SingleChatPageState extends State<SingleChatPage> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _composerFocus = FocusNode();
  final _attachmentService = ChatAttachmentService();
  late final _messageActions = widget.messageActions ?? MessageActionsService();
  late final _voiceRecorder = widget.voiceRecorder ?? VoiceRecorderService();
  Duration? _recordingElapsed;
  Timer? _recordingTicker;
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
        speech: widget.speech,
        verifier: verifier,
      )..addListener(_onChatChanged);
      setState(() {
        _conversation = described;
        _chatController = controller;
      });
      unawaited(_loadModelLabel(described.expertId));
      await controller.initialize();
      // Opening a conversation should land on the newest message.
      _jumpToBottomSoon();
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
    _recordingTicker?.cancel();
    unawaited(_voiceRecorder.dispose());
    _composerFocus.dispose();
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
  /// Jump (no animation) for the initial history load, so opening the page
  /// starts at the newest message instead of animating past the backlog.
  void _jumpToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

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

  /// Picks an attachment, appends it to the durable conversation, and — for an
  /// image — hands it to the controller so the next message carries it.
  Future<void> _attach(
    Future<ChatAttachment?> Function() pick,
    ChatMessageKind kind,
  ) async {
    final controller = _chatController;
    if (controller == null) return;
    try {
      final attachment = await pick();
      if (attachment == null || !mounted) return;
      await controller.repository.append(
        widget.conversationId,
        kind == ChatMessageKind.userImage
            ? ChatMessageProjection(
                id: attachment.id,
                kind: ChatMessageKind.userImage,
                imageUrl: attachment.storedPath,
                text: attachment.fileName,
              )
            : ChatMessageProjection(
                id: attachment.id,
                kind: ChatMessageKind.file,
                text: attachment.fileName,
                secondaryText: _formatAttachmentBytes(attachment.byteSize),
              ),
      );
      if (kind == ChatMessageKind.userImage) {
        controller.attachPendingImage(attachment.storedPath);
      }
      await controller.initialize();
      _scrollToBottomSoon();
    } on ChatAttachmentException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.safeMessage)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('附件保存失败，请重试')));
    }
  }

  void _showAttachmentSheet() {
    _showAttachmentSheetFor(
      context,
      onTakePhoto: () =>
          _attach(_attachmentService.takePhoto, ChatMessageKind.userImage),
      onPickImage: () =>
          _attach(_attachmentService.pickImage, ChatMessageKind.userImage),
      onPickFile: () =>
          _attach(_attachmentService.pickFile, ChatMessageKind.file),
    );
  }

  /// Long-press menu, resolved from what the message actually carries.
  void _showMessageActions(ChatMessageProjection message) {
    final text = message.text?.trim() ?? '';
    final imagePath = message.kind == ChatMessageKind.userImage
        ? message.imageUrl
        : null;
    final entries = <(String, String, Future<void> Function())>[
      if (text.isNotEmpty) ...[
        ('ph ph-copy', '复制', () => _messageActions.copyText(text)),
        ('ph ph-share-network', '分享', () => _messageActions.shareText(text)),
      ],
      if (imagePath != null) ...[
        (
          'ph ph-download-simple',
          '保存到相册',
          () => _messageActions.saveImageToGallery(imagePath),
        ),
        (
          'ph ph-share-network',
          '分享图片',
          () => _messageActions.shareFile(imagePath),
        ),
      ],
    ];
    if (entries.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
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
                margin: const EdgeInsets.only(bottom: 9),
                decoration: BoxDecoration(
                  color: const Color(0xFFC9CCD2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              for (final entry in entries)
                Material(
                  color: Colors.transparent,
                  child: ListTile(
                    leading: Icon(
                      HaloIcon.requirePrototypeClass(entry.$1),
                      size: 21,
                      color: HaloColors.ink,
                    ),
                    title: Text(entry.$2, style: HaloTextStyles.body),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_runMessageAction(entry.$2, entry.$3));
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runMessageAction(
    String label,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      if (!mounted) return;
      // The share sheet is its own confirmation; only quiet actions confirm.
      if (label == '复制' || label == '保存到相册') {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$label成功')));
      }
    } on MessageActionException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.safeMessage)));
    }
  }

  /// Tap to record, tap again to send. Holding while speaking is a nicer
  /// gesture but a worse first cut: it hides failures behind a gesture state
  /// machine before the pipeline itself is proven.
  Future<void> _toggleVoiceRecording() async {
    if (_voiceRecorder.isRecording) {
      _recordingTicker?.cancel();
      _recordingTicker = null;
      final recording = await _voiceRecorder.stop();
      if (!mounted) return;
      setState(() => _recordingElapsed = null);
      if (recording == null) {
        _notify('没有录到声音');
        return;
      }
      await _chatController?.submitVoice(
        path: recording.path,
        duration: recording.duration,
      );
      return;
    }
    try {
      await _voiceRecorder.start();
    } on VoiceRecorderException catch (error) {
      if (mounted) _notify(error.safeMessage);
      return;
    }
    if (!mounted) return;
    setState(() => _recordingElapsed = Duration.zero);
    _recordingTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_voiceRecorder.isRecording) return;
      setState(() => _recordingElapsed = _voiceRecorder.elapsed);
    });
  }

  void _notify(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

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
    // Submitting from the keyboard unfocuses the field, which dismisses the
    // keyboard and makes the whole page jump. Sending is not "done typing":
    // keep the keyboard up and only scroll the transcript.
    _composerFocus.requestFocus();
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
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
              onLongPress: _showMessageActions,
            ),
          if (state.status == SingleChatRunStatus.running)
            _AgentBubble(
              conversation: _conversation,
              modelLabel: _modelLabel,
              // While the run streams a live Answer preview, the same bubble
              // shows the growing markdown instead of the wave indicator.
              child: state.streamingAnswer.isEmpty
                  ? const _ProgressMessage()
                  : HaloMarkdownBody(state.streamingAnswer),
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
        focusNode: _composerFocus,
        onAttach: _showAttachmentSheet,
        onSend: _send,
        onVoice: _toggleVoiceRecording,
        recording: _recordingElapsed,
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
    this.onLongPress,
  });

  final ChatMessageProjection message;
  final SingleChatConversationProjection conversation;
  final String? modelLabel;
  final void Function(ChatMessageProjection message)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final bubble = _buildBubble(context);
    // Progress and system notices have nothing to copy, save or share.
    final actionable = switch (message.kind) {
      ChatMessageKind.systemNotice || ChatMessageKind.progress => false,
      _ => onLongPress != null,
    };
    if (!actionable) return bubble;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => onLongPress!(message),
      child: bubble,
    );
  }

  /// A voice message can come from either side; ids carry the sender, the
  /// same convention the text pipeline already uses.
  static bool _isMine(ChatMessageProjection message) =>
      message.id.endsWith(':user');

  Widget _buildBubble(BuildContext context) {
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
      ChatMessageKind.voice =>
        _isMine(message)
            ? _MineBubbleShell(
                child: VoiceMessageBubble(message: message, mine: true),
              )
            : _AgentBubble(
                conversation: conversation,
                modelLabel: modelLabel,
                child: VoiceMessageBubble(message: message, mine: false),
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
        HaloMarkdownBody(message.text ?? ''),
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

/// The outgoing bubble chrome, for content that is not plain text.
class _MineBubbleShell extends StatelessWidget {
  const _MineBubbleShell({required this.child});

  final Widget child;

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
        child: child,
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
  const _ProgressMessage({this.message});

  final ChatMessageProjection? message;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    if (message == null) {
      // An in-flight reply shows only the wave: no title, percent, or
      // controls until the run projects something concrete.
      return const SizedBox(width: 235, child: HaloWaveKeysIndicator());
    }
    final progress = message.progress;
    return SizedBox(
      width: 235,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  message.text ?? '任务进行中',
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
          if (message.secondaryText case final secondary?) ...[
            const SizedBox(height: 7),
            Text(secondary, style: HaloTextStyles.caption),
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
        // Picked attachments live in the app sandbox; only remote fixtures
        // come as http URLs.
        child: imageUrl!.startsWith('http')
            ? Image.network(
                imageUrl!,
                width: 210,
                height: 128,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              )
            : Image.file(
                File(imageUrl!),
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
    required this.focusNode,
    required this.onAttach,
    required this.onSend,
    required this.enabled,
    required this.onVoice,
    required this.recording,
  });

  final FocusNode focusNode;
  final TextEditingController controller;
  final VoidCallback onAttach;
  final VoidCallback onSend;
  final bool enabled;
  final VoidCallback onVoice;

  /// Elapsed recording time, or null when not recording.
  final Duration? recording;

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
                    prototypeIconClass: recording == null
                        ? 'ph ph-microphone'
                        : 'ph ph-stop-circle',
                    semanticLabel: recording == null ? '录音' : '结束录音并发送',
                    onPressed: enabled ? onVoice : null,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      enabled: enabled,
                      minLines: 1,
                      maxLines: 4,
                      focusNode: focusNode,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      decoration: const InputDecoration(
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
                  _AttachButton(onPressed: enabled ? onAttach : null),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The composer's attach entry: a plus icon on a circular accent-tinted disc,
/// so the remaining action reads as a button rather than a stray glyph now
/// that Enter on the keyboard is what sends.
class _AttachButton extends StatelessWidget {
  const _AttachButton({this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '添加附件',
      child: SizedBox.square(
        dimension: HaloMetrics.iconButtonSize,
        child: Material(
          color: HaloColors.accentSoft,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Icon(
              HaloIcon.requirePrototypeClass('ph ph-plus'),
              size: 18,
              color: onPressed == null ? HaloColors.muted : HaloColors.accent,
            ),
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

String _formatAttachmentBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final rendered = unit == 0 || value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$rendered ${units[unit]}';
}

void _showAttachmentSheetFor(
  BuildContext context, {
  required Future<void> Function() onTakePhoto,
  required Future<void> Function() onPickImage,
  required Future<void> Function() onPickFile,
}) {
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
  const wired = {'拍照', '图片', '文件'};
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
                      onTap: () {
                        if (!wired.contains(ability.$2)) {
                          _showUnavailable(sheetContext);
                          return;
                        }
                        Navigator.of(sheetContext).pop();
                        switch (ability.$2) {
                          case '拍照':
                            unawaited(onTakePhoto());
                          case '图片':
                            unawaited(onPickImage());
                          case '文件':
                            unawaited(onPickFile());
                        }
                      },
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
                            Text(
                              wired.contains(ability.$2) ? '本地保存' : '暂不可用',
                              style: const TextStyle(
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
    SingleChatRunStatus.malformedOutput => '模型这次没有按约定格式回复，请重试',
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
