import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/features/group_chat/group_chat_history_repository.dart';
import 'package:halo_mobile/features/group_chat/group_members_repository.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';

abstract interface class GroupChatRunPort {
  Future<RunHandle> startRun(StartConversationRunCommand command);

  Stream<OrchestrationEvent> watchRun(String runId, {int afterSeq = 0});

  Future<void> requestStop(String runId);

  Future<ResumeResult> resumeRun(String runId);
}

abstract interface class GroupChatCommandIdGenerator {
  String next(String conversationId);
}

class SecureGroupChatCommandIdGenerator implements GroupChatCommandIdGenerator {
  const SecureGroupChatCommandIdGenerator();

  @override
  String next(String conversationId) {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    final uuid =
        '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
    return '$conversationId-ui-$uuid';
  }
}

enum GroupChatMessageStatus { running, completed, failed }

@immutable
class GroupChatAgentMessage {
  const GroupChatAgentMessage({
    required this.agentId,
    required this.text,
    required this.status,
  });

  final String agentId;
  final String text;
  final GroupChatMessageStatus status;

  GroupChatAgentMessage copyWith({
    String? text,
    GroupChatMessageStatus? status,
  }) => GroupChatAgentMessage(
    agentId: agentId,
    text: text ?? this.text,
    status: status ?? this.status,
  );
}

@immutable
class GroupChatTurn {
  const GroupChatTurn({
    required this.input,
    required this.messages,
    required this.status,
    required this.stage,
    this.summary,
    this.errorCode,
  });

  final String input;
  final List<GroupChatAgentMessage> messages;
  final OrchestrationRunStatus status;
  final ConversationStage? stage;
  final String? summary;
  final String? errorCode;
}

class GroupChatController extends ChangeNotifier {
  GroupChatController({
    required this.runPort,
    required this.conversationId,
    required this.membersRepository,
    required this.historyRepository,
    this.commandIdGenerator = const SecureGroupChatCommandIdGenerator(),
  });

  final GroupChatRunPort? runPort;
  final String conversationId;
  final GroupMembersRepository membersRepository;
  final GroupChatHistoryRepository historyRepository;
  final GroupChatCommandIdGenerator commandIdGenerator;

  StreamSubscription<OrchestrationEvent>? _subscription;
  Future<void> _watcherCancellation = Future<void>.value();
  final List<GroupChatMember> _members = [];
  final List<GroupChatHistoryItem> _historyItems = [];
  final List<GroupChatAgentMessage> _messages = [];
  final List<GroupChatTurn> _pastTurns = [];
  final Map<String, int> _activeMessageByAgent = {};
  bool _initialized = false;
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _initializationFuture;
  Future<void>? _submitFuture;

  String? runId;
  String? submittedInput;
  ConversationReplyMode? replyMode;
  ConversationStage? stage;
  OrchestrationRunStatus? status;
  List<String> selectedAgentIds = const [];
  String? summary;
  String? errorCode;
  String? cleanupErrorCode;
  bool stopRequested = false;
  int _lastSeq = 0;

  List<GroupChatMember> get members => List.unmodifiable(_members);
  List<GroupChatHistoryItem> get historyItems =>
      List.unmodifiable(_historyItems);
  List<GroupChatAgentMessage> get messages => List.unmodifiable(_messages);
  List<GroupChatTurn> get pastTurns => List.unmodifiable(_pastTurns);
  bool get isRunning => status == OrchestrationRunStatus.running;
  bool get canSubmit =>
      !_disposed &&
      _initialized &&
      runPort != null &&
      _members.isNotEmpty &&
      !isRunning;
  int get lastSeq => _lastSeq;

  GroupChatMember? memberById(String expertId) {
    for (final member in _members) {
      if (member.expertId == expertId) return member;
    }
    return null;
  }

  Future<void> initialize() {
    if (_disposed) return Future<void>.value();
    return _initializationFuture ??= _initialize(_generation);
  }

  Future<void> _initialize(int generation) async {
    try {
      final loaded = await Future.wait<Object>([
        membersRepository.loadMembers(conversationId),
        historyRepository.load(conversationId),
      ]);
      if (!_isCurrent(generation)) return;
      _members
        ..clear()
        ..addAll(loaded[0] as List<GroupChatMember>);
      _validateMembers();
      final projection = loaded[1] as GroupChatHistoryProjection;
      _historyItems
        ..clear()
        ..addAll(projection.items);
      _initialized = true;
      final restoredRun = projection.activeRun;
      if (restoredRun != null) {
        await _restoreRun(restoredRun, generation);
      }
    } on Object {
      if (!_isCurrent(generation)) return;
      _initialized = true;
      status = OrchestrationRunStatus.failed;
      stage = ConversationStage.failed;
      errorCode = 'group_chat_initialize_failed';
    }
    _notifyIfCurrent(generation);
  }

  Future<void> submit({
    required String input,
    required ConversationReplyMode mode,
    List<String> mentionedAgentIds = const [],
  }) {
    if (_disposed) return Future<void>.value();
    final activeSubmit = _submitFuture;
    if (activeSubmit != null) return activeSubmit;
    late final Future<void> operation;
    operation =
        _submitOnce(
          input: input,
          mode: mode,
          mentionedAgentIds: mentionedAgentIds,
        ).whenComplete(() {
          if (identical(_submitFuture, operation)) {
            _submitFuture = null;
          }
        });
    _submitFuture = operation;
    return operation;
  }

  Future<void> _submitOnce({
    required String input,
    required ConversationReplyMode mode,
    required List<String> mentionedAgentIds,
  }) async {
    final generation = _generation;
    final normalizedInput = input.trim();
    if (normalizedInput.isEmpty || isRunning) return;
    if (!_initialized) {
      throw StateError('GroupChatController must be initialized first.');
    }
    final port = runPort;
    if (port == null || _members.isEmpty) return;
    _validateMentions(mode, mentionedAgentIds);

    await _cancelWatcher();
    if (!_isCurrent(generation)) return;
    final previousInput = submittedInput;
    final previousStatus = status;
    if (previousInput != null && previousStatus != null) {
      _pastTurns.add(
        GroupChatTurn(
          input: previousInput,
          messages: List.unmodifiable(List.of(_messages)),
          status: previousStatus,
          stage: stage,
          summary: summary,
          errorCode: errorCode,
        ),
      );
    }
    _messages.clear();
    _activeMessageByAgent.clear();
    runId = null;
    submittedInput = normalizedInput;
    replyMode = mode;
    stage = ConversationStage.preparing;
    status = OrchestrationRunStatus.running;
    selectedAgentIds = const [];
    summary = null;
    errorCode = null;
    cleanupErrorCode = null;
    stopRequested = false;
    _lastSeq = 0;
    _notifyIfCurrent(generation);

    try {
      final handle = await port.startRun(
        StartConversationRunCommand(
          clientCommandId: commandIdGenerator.next(conversationId),
          conversationId: conversationId,
          hostAgentId: _members.first.expertId,
          input: normalizedInput,
          replyMode: mode,
          memberAgentIds: List.unmodifiable(
            _members.map((member) => member.expertId),
          ),
          mentionedAgentIds: List.unmodifiable(mentionedAgentIds),
        ),
      );
      if (!_isCurrent(generation)) return;
      runId = handle.runId;
      status = handle.status;
      _notifyIfCurrent(generation);
      if (handle.status == OrchestrationRunStatus.running) {
        await _replaceWatcher(
          handle.runId,
          afterSeq: 0,
          generation: generation,
        );
      }
    } on Object {
      if (!_isCurrent(generation)) return;
      status = OrchestrationRunStatus.failed;
      stage = ConversationStage.failed;
      errorCode = 'orchestration_start_failed';
      _notifyIfCurrent(generation);
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    final generation = _generation;
    final activeRunId = runId;
    final port = runPort;
    if (!isRunning || activeRunId == null || port == null || stopRequested) {
      return;
    }
    stopRequested = true;
    _notifyIfCurrent(generation);
    try {
      await port.requestStop(activeRunId);
    } on Object {
      if (!_isCurrent(generation)) return;
      stopRequested = false;
      errorCode = 'orchestration_stop_failed';
      _notifyIfCurrent(generation);
    }
  }

  Future<void> _restoreRun(
    GroupChatRunProjection projection,
    int generation,
  ) async {
    if (!_isCurrent(generation)) return;
    runId = projection.runId;
    submittedInput = projection.input;
    replyMode = projection.replyMode;
    status = projection.status;
    stage = ConversationStage.preparing;
    selectedAgentIds = const [];
    summary = null;
    errorCode = null;
    cleanupErrorCode = null;
    stopRequested = false;
    _lastSeq = 0;
    _messages.clear();
    _activeMessageByAgent.clear();

    final orderedEvents = List<OrchestrationEvent>.of(projection.events)
      ..sort((left, right) => left.seq.compareTo(right.seq));
    var expectedSeq = 1;
    for (final event in orderedEvents) {
      if (event.seq < expectedSeq) continue;
      if (event.seq != expectedSeq) break;
      _applyEvent(event, notify: false, cancelTerminalWatcher: false);
      expectedSeq++;
    }
    status = projection.status;

    final port = runPort;
    if (projection.status == OrchestrationRunStatus.running && port != null) {
      await port.resumeRun(projection.runId);
      if (!_isCurrent(generation)) return;
      await _replaceWatcher(
        projection.runId,
        afterSeq: _lastSeq,
        generation: generation,
      );
    }
  }

  Future<void> _replaceWatcher(
    String watchedRunId, {
    required int afterSeq,
    required int generation,
  }) async {
    await _cancelWatcher();
    if (!_isCurrent(generation)) return;
    final port = runPort;
    if (port == null) return;
    _subscription = port
        .watchRun(watchedRunId, afterSeq: afterSeq)
        .listen(
          _applyEvent,
          onError: _applyStreamError,
          onDone: _applyStreamDone,
        );
  }

  void _applyEvent(
    OrchestrationEvent event, {
    bool notify = true,
    bool cancelTerminalWatcher = true,
  }) {
    if (_disposed) return;
    if (event.runId != runId || event.seq <= _lastSeq) return;
    _lastSeq = event.seq;
    stage = event.stage;
    var terminal = false;

    switch (event.type) {
      case OrchestrationEventType.runCreated:
        status = OrchestrationRunStatus.running;
      case OrchestrationEventType.agentsSelected:
        selectedAgentIds = List.unmodifiable(event.selectedAgentIds);
      case OrchestrationEventType.stageChanged:
        break;
      case OrchestrationEventType.agentMessageStarted:
        final agentId = event.agentId;
        if (agentId != null) {
          _messages.add(
            GroupChatAgentMessage(
              agentId: agentId,
              text: event.text ?? '',
              status: GroupChatMessageStatus.running,
            ),
          );
          _activeMessageByAgent[agentId] = _messages.length - 1;
        }
      case OrchestrationEventType.agentMessageCompleted:
        _finishAgentMessage(event, GroupChatMessageStatus.completed);
      case OrchestrationEventType.agentMessageFailed:
        _finishAgentMessage(event, GroupChatMessageStatus.failed);
      case OrchestrationEventType.summaryCompleted:
        summary = event.text;
      case OrchestrationEventType.runCompleted:
        status = OrchestrationRunStatus.completed;
        stage = ConversationStage.completed;
        terminal = true;
      case OrchestrationEventType.runFailed:
        _failActiveMessages();
        status = OrchestrationRunStatus.failed;
        stage = ConversationStage.failed;
        errorCode = event.errorCode;
        terminal = true;
      case OrchestrationEventType.runStopped:
        status = OrchestrationRunStatus.stopped;
        stage = ConversationStage.stopped;
        stopRequested = false;
        terminal = true;
    }
    if (terminal && cancelTerminalWatcher) {
      _cancelWatcherUnawaited(_generation);
    }
    if (notify) _notifyIfCurrent(_generation);
  }

  void _finishAgentMessage(
    OrchestrationEvent event,
    GroupChatMessageStatus messageStatus,
  ) {
    final agentId = event.agentId;
    if (agentId == null) return;
    final index = _activeMessageByAgent.remove(agentId);
    final text = event.text ?? event.errorCode ?? '';
    if (index == null) {
      _messages.add(
        GroupChatAgentMessage(
          agentId: agentId,
          text: text,
          status: messageStatus,
        ),
      );
      return;
    }
    _messages[index] = _messages[index].copyWith(
      text: text,
      status: messageStatus,
    );
  }

  void _applyStreamError(Object error) {
    if (_disposed) return;
    _failActiveMessages();
    status = OrchestrationRunStatus.failed;
    stage = ConversationStage.failed;
    errorCode = 'orchestration_stream_failed';
    _cancelWatcherUnawaited(_generation);
    _notifyIfCurrent(_generation);
  }

  void _applyStreamDone() {
    if (_disposed || !isRunning) return;
    _failActiveMessages();
    status = OrchestrationRunStatus.failed;
    stage = ConversationStage.failed;
    errorCode = 'orchestration_stream_closed';
    _notifyIfCurrent(_generation);
  }

  void _failActiveMessages() {
    for (final index in _activeMessageByAgent.values) {
      _messages[index] = _messages[index].copyWith(
        text: '回答中断',
        status: GroupChatMessageStatus.failed,
      );
    }
    _activeMessageByAgent.clear();
  }

  void _validateMembers() {
    final ids = <String>{};
    for (final member in _members) {
      if (!ids.add(member.expertId)) {
        throw StateError('Duplicate canonical expert ID: ${member.expertId}');
      }
    }
  }

  void _validateMentions(
    ConversationReplyMode mode,
    List<String> mentionedAgentIds,
  ) {
    if (mode != ConversationReplyMode.mentioned &&
        mentionedAgentIds.isNotEmpty) {
      throw ArgumentError(
        'Explicit mentions are only valid in mentioned mode.',
      );
    }
    if (mode != ConversationReplyMode.mentioned) return;
    final uniqueIds = mentionedAgentIds.toSet();
    if (uniqueIds.length != mentionedAgentIds.length ||
        uniqueIds.isEmpty ||
        uniqueIds.length > 4) {
      throw ArgumentError('Mentioned mode requires 1–4 unique members.');
    }
    final memberIds = _members.map((member) => member.expertId).toSet();
    if (!uniqueIds.every(memberIds.contains)) {
      throw ArgumentError('Mentioned experts must be current group members.');
    }
  }

  Future<void> _cancelWatcher() {
    final subscription = _subscription;
    _subscription = null;
    final previousCancellation = _watcherCancellation;
    final cancellation = () async {
      try {
        await previousCancellation;
      } on Object {
        _recordWatcherCancellationFailure(_generation);
      }
      if (subscription == null) return;
      try {
        await subscription.cancel();
      } on Object {
        _recordWatcherCancellationFailure(_generation);
      }
    }();
    _watcherCancellation = cancellation;
    return cancellation;
  }

  void _cancelWatcherUnawaited(int generation) {
    unawaited(() async {
      try {
        await _cancelWatcher();
      } on Object {
        _recordWatcherCancellationFailure(generation);
      }
    }());
  }

  void _recordWatcherCancellationFailure(int generation) {
    cleanupErrorCode = 'orchestration_watcher_cancel_failed';
    if (!_isCurrent(generation)) return;
    errorCode ??= cleanupErrorCode;
    _notifyIfCurrent(generation);
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _notifyIfCurrent(int generation) {
    if (_isCurrent(generation)) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cancelWatcherUnawaited(_generation);
    super.dispose();
  }
}
