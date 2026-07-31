import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'chat_message_repository.dart';

enum SingleAgentRunMode { mentioned }

/// Speech services a voice conversation needs, kept narrow so the chat layer
/// never depends on which vendor answers.
abstract interface class SingleChatSpeech {
  Future<String> transcribe(String recordingPath);

  /// Renders [text] to audio and returns the file path, or null when speech
  /// synthesis is unavailable — a reply must never be lost to it.
  Future<String?> synthesize(String text, {required String messageId});
}

/// The recording waiting to be attached to the user's own bubble.
class _PendingVoice {
  const _PendingVoice({required this.path, required this.duration});

  final String path;
  final Duration duration;
}

/// One earlier turn of the conversation, as the model should see it.
class SingleChatHistoryTurn {
  const SingleChatHistoryTurn({required this.fromUser, required this.text});

  final bool fromUser;
  final String text;
}

class StartSingleAgentRunRequest {
  const StartSingleAgentRunRequest({
    required this.conversationId,
    required this.expertId,
    required this.text,
    required this.clientCommandId,
    this.history = const [],
    this.imagePaths = const [],
  });

  final String conversationId;
  final String expertId;
  final String text;
  final String clientCommandId;

  /// Earlier turns, oldest first, so the expert can actually follow the
  /// conversation. Without it every message is answered in isolation.
  final List<SingleChatHistoryTurn> history;

  /// Images attached to this message, as sandbox paths. Empty for a plain
  /// text turn.
  final List<String> imagePaths;
  SingleAgentRunMode get mode => SingleAgentRunMode.mentioned;
  List<String> get memberExpertIds => [expertId];
}

class SingleAgentRunHandle {
  const SingleAgentRunHandle({
    required this.runId,
    required this.outcome,
    this.partialAnswers,
  });

  final String runId;
  final Future<SingleAgentRunOutcome> outcome;

  /// Growing snapshots of the user-visible Answer while the run streams.
  /// Null when the backing port has no streaming transport; existing ports
  /// and fakes are unaffected.
  final Stream<String>? partialAnswers;
}

enum SingleAgentRunFailure {
  none,
  retryable,
  quotaLimited,
  authentication,
  contentFiltered,

  /// No usable model binding exists yet. Retrying can never succeed, so this
  /// must never be reported as a transient send failure.
  notConfigured,

  /// The model replied, but not in the agreed JSON contract (for example the
  /// payload was wrapped in prose or was not valid JSON at all). This is an
  /// ordinary formatting miss, never a safety rejection, and a retry can
  /// genuinely succeed.
  malformedOutput,
}

@immutable
class SingleChatVerificationClaim {
  const SingleChatVerificationClaim({
    required this.conversationId,
    required this.expertId,
    required this.runId,
    required this.commandId,
    required this.answer,
    required this.canonicalEvidenceReferences,
    required this.uncertainty,
  });

  final String conversationId;
  final String expertId;
  final String runId;
  final String commandId;
  final String answer;
  final List<String> canonicalEvidenceReferences;
  final String uncertainty;
}

@immutable
class SingleChatVerifierToken {
  const SingleChatVerifierToken._(this._receiptId, this._secret);

  final String _receiptId;
  final String _secret;

  @override
  String toString() => 'SingleChatVerifierToken(redacted)';
}

abstract interface class TrustedVerifierReceiptRegistry {
  String? verifyAndConsume(
    SingleChatVerificationClaim claim,
    SingleChatVerifierToken token,
  );

  bool validateConsumed(SingleChatVerificationClaim claim, String receiptId);
}

class RejectingVerifierReceiptRegistry
    implements TrustedVerifierReceiptRegistry {
  const RejectingVerifierReceiptRegistry();

  @override
  String? verifyAndConsume(
    SingleChatVerificationClaim claim,
    SingleChatVerifierToken token,
  ) => null;

  @override
  bool validateConsumed(SingleChatVerificationClaim claim, String receiptId) =>
      false;
}

class InMemoryTrustedVerifierReceiptRegistry
    implements TrustedVerifierReceiptRegistry {
  InMemoryTrustedVerifierReceiptRegistry({
    DateTime Function()? now,
    List<int> Function(int)? randomBytes,
  }) : _now = now ?? DateTime.now,
       _randomBytes = randomBytes ?? _secureVerificationRandomBytes;

  final DateTime Function() _now;
  final List<int> Function(int) _randomBytes;
  final Map<String, _VerifierReceiptRecord> _records = {};
  int _nextReceipt = 0;

  SingleChatVerifierToken issue(
    SingleChatVerificationClaim claim, {
    required Duration validFor,
  }) {
    if (validFor <= Duration.zero ||
        !isSafeSingleChatUncertaintyDisclosure(claim.uncertainty) ||
        claim.canonicalEvidenceReferences.isEmpty) {
      throw ArgumentError('Verifier receipt claim is incomplete.');
    }
    final canonical = _canonicalizeEvidenceReferences(
      claim.canonicalEvidenceReferences,
    );
    if (!canonical.isValid ||
        !listEquals(canonical.references, claim.canonicalEvidenceReferences)) {
      throw ArgumentError('Verifier receipt evidence is not canonical.');
    }
    final issuedAt = _now().toUtc();
    final receiptId = 'receipt-${++_nextReceipt}';
    final secret = _randomBytes(
      32,
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    _records[receiptId] = _VerifierReceiptRecord(
      secretDigest: sha256.convert(utf8.encode(secret)).bytes,
      bindingDigest: _verificationClaimDigest(claim),
      issuedAt: issuedAt,
      expiresAt: issuedAt.add(validFor),
    );
    return SingleChatVerifierToken._(receiptId, secret);
  }

  @override
  String? verifyAndConsume(
    SingleChatVerificationClaim claim,
    SingleChatVerifierToken token,
  ) {
    final record = _records[token._receiptId];
    if (record == null || record.consumed) {
      return null;
    }
    final now = _now().toUtc();
    final suppliedSecret = sha256.convert(utf8.encode(token._secret)).bytes;
    if (now.isBefore(record.issuedAt) ||
        !now.isBefore(record.expiresAt) ||
        !_constantTimeEquals(suppliedSecret, record.secretDigest) ||
        !_constantTimeEquals(
          _verificationClaimDigest(claim),
          record.bindingDigest,
        )) {
      return null;
    }
    record.consumed = true;
    return token._receiptId;
  }

  @override
  bool validateConsumed(SingleChatVerificationClaim claim, String receiptId) {
    final record = _records[receiptId];
    final now = _now().toUtc();
    return record != null &&
        record.consumed &&
        !now.isBefore(record.issuedAt) &&
        now.isBefore(record.expiresAt) &&
        _constantTimeEquals(
          _verificationClaimDigest(claim),
          record.bindingDigest,
        );
  }
}

class _VerifierReceiptRecord {
  _VerifierReceiptRecord({
    required this.secretDigest,
    required this.bindingDigest,
    required this.issuedAt,
    required this.expiresAt,
  });

  final List<int> secretDigest;
  final List<int> bindingDigest;
  final DateTime issuedAt;
  final DateTime expiresAt;
  bool consumed = false;
}

class SingleAgentRunOutcome {
  const SingleAgentRunOutcome.completed({
    required this.answer,
    this.sourceType = ChatMessageSourceType.modelOutput,
    this.uncertainty = '未提供不确定性说明',
    this.evidenceReferences = const [],
    this.verifierToken,
    this.generatedAssetPaths = const [],
  }) : failure = SingleAgentRunFailure.none;

  const SingleAgentRunOutcome.failed({required this.failure})
    : answer = '',
      sourceType = ChatMessageSourceType.modelOutput,
      uncertainty = '',
      evidenceReferences = const [],
      verifierToken = null,
      generatedAssetPaths = const [];

  final String answer;
  final SingleAgentRunFailure failure;
  final ChatMessageSourceType sourceType;
  final String uncertainty;
  final List<String> evidenceReferences;
  final SingleChatVerifierToken? verifierToken;

  /// Sandbox paths of anything the expert generated this turn. Rendered as
  /// their own messages so the picture is visible, not described.
  final List<String> generatedAssetPaths;
  bool get isCompleted => failure == SingleAgentRunFailure.none;
}

abstract interface class SingleChatPort {
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  );

  Future<void> stopSingleAgentRun(String runId);
}

abstract interface class ConversationApplicationService
    implements SingleChatPort {}

enum SingleChatRunStatus {
  idle,
  running,
  completed,
  stopped,
  failed,
  quotaLimited,
  authentication,
  filtered,
  notConfigured,
  malformedOutput,
}

class SingleChatState {
  SingleChatState({
    List<ChatMessageProjection> messages = const [],
    this.status = SingleChatRunStatus.idle,
    this.canRetry = false,
    this.historyLoadFailed = false,
    this.streamingAnswer = '',
  }) : messages = List<ChatMessageProjection>.unmodifiable(messages);

  final List<ChatMessageProjection> messages;
  final SingleChatRunStatus status;
  final bool canRetry;
  final bool historyLoadFailed;

  /// Live Answer preview while a run streams; empty outside a streaming run.
  final String streamingAnswer;

  SingleChatState copyWith({
    List<ChatMessageProjection>? messages,
    SingleChatRunStatus? status,
    bool? canRetry,
    bool? historyLoadFailed,
    String? streamingAnswer,
  }) {
    return SingleChatState(
      messages: messages ?? this.messages,
      status: status ?? this.status,
      canRetry: canRetry ?? this.canRetry,
      historyLoadFailed: historyLoadFailed ?? this.historyLoadFailed,
      streamingAnswer: streamingAnswer ?? this.streamingAnswer,
    );
  }
}

int _controllerEpochMilliseconds() =>
    DateTime.now().toUtc().millisecondsSinceEpoch;

class SingleChatController extends ChangeNotifier {
  static const _dispatchClaimLease = Duration(minutes: 5);
  static const _dispatchClaimRenewalInterval = Duration(minutes: 1);
  static const _quarantinedClaimExpiryEpochMs = 253402300799000;
  static const _streamingNotifyIntervalMs = 100;

  SingleChatController({
    required this.conversationId,
    required this.expertId,
    required this.service,
    required this.repository,
    required this.commandIdFactory,
    this.verifier = const RejectingVerifierReceiptRegistry(),
    this.speech,
    SingleChatEpochClock? nowEpochMs,
  }) : _nowEpochMs = nowEpochMs ?? _controllerEpochMilliseconds,
       assert(expertId != '');

  final String conversationId;
  final String expertId;
  final SingleChatPort service;
  final ChatMessageRepository repository;

  /// Speech services for voice messages. Absent until the owner configures
  /// 豆包语音, in which case the voice button reports that honestly instead of
  /// pretending to record into nothing.
  final SingleChatSpeech? speech;
  final String Function() commandIdFactory;
  final TrustedVerifierReceiptRegistry verifier;
  final SingleChatEpochClock _nowEpochMs;

  SingleChatState _state = SingleChatState();
  SingleChatState get state => _state;

  Future<void>? _activeSubmission;
  Future<SingleAgentRunHandle>? _activeHandle;
  String? _lastText;
  String? _lastCommandId;
  ChatMessageProjection? _lastUserMessage;
  bool _lastUserPersisted = false;
  int _attempt = 0;
  _PendingVoice? _pendingVoice;
  bool _disposed = false;
  bool _outboxReconciliationBlocked = false;
  final Map<String, Future<bool>> _stopOperations = {};
  StreamSubscription<String>? _partialAnswersSub;
  final String _dispatchOwnerId = _newDispatchOwnerId();
  SingleChatDispatchClaim? _activeDispatchClaim;
  Timer? _dispatchLeaseTimer;
  ChatMessageCommitToken? _activeCommitToken;

  String? get activeText => _lastText;

  Future<void> initialize() async {
    try {
      final loadedMessages = await repository.load(conversationId);
      if (_disposed) {
        return;
      }
      final reconciliation = await _reconcilePersistedCompletions(
        loadedMessages,
      );
      final messages = [
        for (final message in loadedMessages)
          if (!reconciliation.quarantinedMessageIds.contains(message.id))
            _validateLoadedMessage(message),
      ];
      final loadedIds = messages.map((message) => message.id).toSet();
      _state = _state.copyWith(
        messages: [
          ...messages,
          for (final current in _state.messages)
            if (!loadedIds.contains(current.id)) current,
        ],
        historyLoadFailed: reconciliation.failed,
      );
      notifyListeners();
    } catch (_) {
      if (!_disposed) {
        _state = _state.copyWith(historyLoadFailed: true);
        notifyListeners();
      }
    }
  }

  Future<({bool failed, Set<String> quarantinedMessageIds})>
  _reconcilePersistedCompletions(
    List<ChatMessageProjection> loadedMessages,
  ) async {
    _outboxReconciliationBlocked = false;
    final quarantinedMessageIds = <String>{};
    var failed = false;
    try {
      final messagesById = {
        for (final message in loadedMessages) message.id: message,
      };
      final nowEpochMs = _nowEpochMs();
      for (final command in repository.commandOutbox.pendingForConversation(
        conversationId,
      )) {
        final answer = messagesById['${command.commandId}:answer'];
        if (answer == null) {
          continue;
        }
        if (!command.hasDispatchClaim) {
          quarantinedMessageIds.add(answer.id);
          _outboxReconciliationBlocked = true;
          failed = true;
          continue;
        }
        final dispatchClaim = SingleChatDispatchClaim(
          conversationId: command.conversationId,
          commandId: command.commandId,
          ownerId: command.dispatchClaimOwner!,
          generation: command.dispatchClaimGeneration!,
        );
        if (answer.dispatchClaimOwner != command.dispatchClaimOwner ||
            answer.dispatchClaimGeneration != command.dispatchClaimGeneration) {
          quarantinedMessageIds.add(answer.id);
          failed = true;
          final staleDisposition = await repository.discardStaleClaimedAnswer(
            conversationId,
            answer,
            dispatchClaim,
          );
          if (staleDisposition ==
              ChatMessageStaleAnswerDisposition.ownershipMismatch) {
            _outboxReconciliationBlocked = true;
          }
          continue;
        }
        if (command.dispatchClaimExpiresAtEpochMs! > nowEpochMs) {
          continue;
        }
        try {
          repository.commandOutbox.recoverPersistedCompletion(dispatchClaim);
        } catch (_) {
          final persisted = repository.commandOutbox.read(
            conversationId,
            command.commandId,
          );
          if (persisted?.status != SingleChatCommandStatus.completed) {
            _outboxReconciliationBlocked = true;
            quarantinedMessageIds.add(answer.id);
            failed = true;
          }
        }
      }
      return (failed: failed, quarantinedMessageIds: quarantinedMessageIds);
    } catch (_) {
      _outboxReconciliationBlocked = true;
      return (failed: true, quarantinedMessageIds: {...quarantinedMessageIds});
    }
  }

  ChatMessageProjection _validateLoadedMessage(ChatMessageProjection message) {
    if (message.sourceType != ChatMessageSourceType.verifiedEvidence) {
      return message;
    }
    final attestation = message.verificationAttestation;
    final canonicalEvidence = _canonicalizeEvidenceReferences(
      message.evidenceReferences,
    );
    if (message.kind != ChatMessageKind.agentText ||
        attestation == null ||
        attestation.expertId != expertId ||
        message.id != '${attestation.commandId}:answer' ||
        message.text == null ||
        !isSafeSingleChatUncertaintyDisclosure(message.uncertainty) ||
        !canonicalEvidence.isValid ||
        canonicalEvidence.references.isEmpty ||
        !listEquals(canonicalEvidence.references, message.evidenceReferences)) {
      return message.withVerification(
        sourceType: ChatMessageSourceType.modelOutput,
        attestation: null,
      );
    }
    final claim = SingleChatVerificationClaim(
      conversationId: conversationId,
      expertId: expertId,
      runId: attestation.runId,
      commandId: attestation.commandId,
      answer: message.text!,
      canonicalEvidenceReferences: canonicalEvidence.references,
      uncertainty: message.uncertainty!,
    );
    try {
      if (verifier.validateConsumed(claim, attestation.receiptId)) {
        return message.withVerification(
          sourceType: ChatMessageSourceType.verifiedEvidence,
          attestation: attestation,
          canonicalEvidenceReferences: canonicalEvidence.references,
        );
      }
    } catch (_) {
      // Persisted provenance is fail-closed when the trust store is degraded.
    }
    return message.withVerification(
      sourceType: ChatMessageSourceType.modelOutput,
      attestation: null,
    );
  }

  /// Sends a recorded voice message.
  ///
  /// The recording is transcribed, and the transcript travels through the same
  /// text pipeline as a typed message — routing, history and disclosure are
  /// unchanged, only the medium differs. The user's own bubble keeps the audio
  /// so it can be replayed, with the transcript behind 转文字.
  Future<void> submitVoice({
    required String path,
    required Duration duration,
  }) async {
    final speech = this.speech;
    if (speech == null) {
      _state = _state.copyWith(status: SingleChatRunStatus.notConfigured);
      notifyListeners();
      return;
    }
    final String transcript;
    try {
      transcript = await speech.transcribe(path);
    } catch (_) {
      // The recording is kept: a failed transcription must not delete what the
      // user just said.
      _state = _state.copyWith(
        status: SingleChatRunStatus.failed,
        canRetry: false,
      );
      notifyListeners();
      return;
    }
    if (_disposed || transcript.trim().isEmpty) return;
    _pendingVoice = _PendingVoice(path: path, duration: duration);
    try {
      await submit(transcript);
    } finally {
      _pendingVoice = null;
    }
  }

  static String formatVoiceDuration(Duration duration) {
    final seconds = duration.inSeconds;
    return "${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}";
  }

  final List<String> _pendingImagePaths = [];
  List<String> _activeImagePaths = const [];

  /// Attaches [path] to the next message the user sends.
  ///
  /// Riding along with the next send rather than firing its own run: the user
  /// almost always has something to ask about the picture, and a run per
  /// attachment would spend money before they have said anything.
  void attachPendingImage(String path) {
    if (_disposed || path.isEmpty) return;
    _pendingImagePaths.add(path);
  }

  Future<void> submit(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty || _disposed || _outboxReconciliationBlocked) {
      return Future<void>.value();
    }
    final active = _activeSubmission;
    if (active != null) {
      return active;
    }
    _lastText = null;
    _lastCommandId = null;
    _lastUserMessage = null;
    _lastUserPersisted = false;
    final attempt = ++_attempt;
    final submission = _reserveAndDispatch(
      attempt: attempt,
      normalized: normalized,
    );
    _activeSubmission = submission;
    submission.whenComplete(() {
      if (_attempt == attempt) {
        _activeSubmission = null;
        _activeHandle = null;
      }
    });
    return submission;
  }

  Future<void> retry() {
    if (!_state.canRetry || _disposed) {
      return Future<void>.value();
    }
    final commandId = _lastCommandId;
    if (commandId == null || !_isCommandPending(commandId)) {
      _state = _state.copyWith(
        status: SingleChatRunStatus.failed,
        canRetry: false,
      );
      notifyListeners();
      return Future<void>.value();
    }
    return _beginDispatch(
      text: _lastText!,
      commandId: commandId,
      appendUser: !_lastUserPersisted,
    );
  }

  Future<void> _reserveAndDispatch({
    required int attempt,
    required String normalized,
  }) async {
    // Moved to the turn here, so a retry of the same command re-sends the same
    // images and an attachment made later cannot join a run already in flight.
    _activeImagePaths = List.unmodifiable(_pendingImagePaths);
    _pendingImagePaths.clear();
    try {
      final command = repository.commandOutbox.reserve(
        conversationId: conversationId,
        normalizedIntent: normalized,
        createCommandId: commandIdFactory,
      );
      if (_disposed || attempt != _attempt) {
        return;
      }
      _lastText = normalized;
      _lastCommandId = command.commandId;
      _lastUserMessage = null;
      _lastUserPersisted = false;
      await _dispatch(
        attempt: attempt,
        text: normalized,
        commandId: command.commandId,
        appendUser: true,
      );
    } catch (_) {
      if (!_disposed && attempt == _attempt) {
        _state = _state.copyWith(
          status: SingleChatRunStatus.failed,
          canRetry: false,
        );
        notifyListeners();
      }
    }
  }

  Future<void> _beginDispatch({
    required String text,
    required String commandId,
    required bool appendUser,
  }) {
    final attempt = ++_attempt;
    return _startDispatchTracked(
      attempt: attempt,
      text: text,
      commandId: commandId,
      appendUser: appendUser,
    );
  }

  Future<void> _startDispatchTracked({
    required int attempt,
    required String text,
    required String commandId,
    required bool appendUser,
  }) {
    final submission = _dispatch(
      attempt: attempt,
      text: text,
      commandId: commandId,
      appendUser: appendUser,
    );
    _activeSubmission = submission;
    submission.whenComplete(() {
      if (_attempt == attempt) {
        _activeSubmission = null;
        _activeHandle = null;
      }
    });
    return submission;
  }

  Future<void> _dispatch({
    required int attempt,
    required String text,
    required String commandId,
    required bool appendUser,
  }) async {
    SingleChatDispatchClaim? dispatchClaim;
    try {
      if (appendUser) {
        final existingUserMessage = _lastUserMessage;
        final userMessage =
            existingUserMessage ??
            (_pendingVoice == null
                ? ChatMessageProjection(
                    id: '$commandId:user',
                    kind: ChatMessageKind.userText,
                    text: text,
                  )
                // Voice keeps the audio and shows the transcript behind 转文字.
                : ChatMessageProjection(
                    id: '$commandId:user',
                    kind: ChatMessageKind.voice,
                    text: text,
                    secondaryText: formatVoiceDuration(_pendingVoice!.duration),
                    imageUrl: _pendingVoice!.path,
                  ));
        _lastUserMessage = userMessage;
        _state = _state.copyWith(
          messages: existingUserMessage == null
              ? [..._state.messages, userMessage]
              : _state.messages,
          status: SingleChatRunStatus.running,
          canRetry: false,
        );
        notifyListeners();
        await repository.append(conversationId, userMessage);
        if (_disposed ||
            attempt != _attempt ||
            _state.status != SingleChatRunStatus.running) {
          return;
        }
        _lastUserPersisted = true;
      } else {
        _state = _state.copyWith(
          status: SingleChatRunStatus.running,
          canRetry: false,
        );
        notifyListeners();
      }

      final nowEpochMs = _nowEpochMs();
      dispatchClaim = repository.commandOutbox.claimForDispatch(
        conversationId: conversationId,
        commandId: commandId,
        ownerId: _dispatchOwnerId,
        nowEpochMs: nowEpochMs,
        leaseExpiresAtEpochMs: nowEpochMs + _dispatchClaimLease.inMilliseconds,
      );
      if (dispatchClaim == null) {
        if (!_disposed &&
            attempt == _attempt &&
            _state.status == SingleChatRunStatus.running) {
          _state = _state.copyWith(
            status: SingleChatRunStatus.failed,
            canRetry: false,
          );
          notifyListeners();
        }
        return;
      }
      _activeDispatchClaim = dispatchClaim;
      _startDispatchLeaseRenewal(dispatchClaim);
      final handleFuture = service.startSingleAgentRun(
        StartSingleAgentRunRequest(
          conversationId: conversationId,
          expertId: expertId,
          text: text,
          clientCommandId: commandId,
          history: _historyForModel(excludingCommandId: commandId),
          imagePaths: _activeImagePaths,
        ),
      );
      _activeHandle = handleFuture;

      final handle = await handleFuture;
      if (_disposed ||
          attempt != _attempt ||
          _state.status != SingleChatRunStatus.running) {
        if (_disposed) {
          return;
        }
        await _stopHandleOnce(handle);
        if (!_mustRetainStoppedClaim(dispatchClaim)) {
          _releaseDispatchClaim(dispatchClaim);
        }
        return;
      }

      final partialSubscription = _subscribeToPartialAnswers(handle, attempt);

      final outcome = await handle.outcome;
      _cancelPartialAnswers(partialSubscription);
      // The run is terminal from here on: the live preview never outlives it.
      _state = _state.copyWith(streamingAnswer: '');
      if (_disposed ||
          attempt != _attempt ||
          _state.status == SingleChatRunStatus.stopped) {
        if (!_disposed && !_mustRetainStoppedClaim(dispatchClaim)) {
          _releaseDispatchClaim(dispatchClaim);
        }
        return;
      }
      if (outcome.isCompleted) {
        final canonicalEvidence = _canonicalizeEvidenceReferences(
          outcome.evidenceReferences,
        );
        final source = _validatedSourceType(
          conversationId: conversationId,
          expertId: expertId,
          runId: handle.runId,
          commandId: commandId,
          outcome: outcome,
          canonicalEvidence: canonicalEvidence,
          verifier: verifier,
        );
        final answer = ChatMessageProjection(
          id: '$commandId:answer',
          kind: ChatMessageKind.agentText,
          text: outcome.answer,
          sourceType: source.sourceType,
          uncertainty: outcome.uncertainty,
          evidenceReferences: canonicalEvidence.isValid
              ? canonicalEvidence.references
              : const [],
          verificationAttestation: source.attestation,
          dispatchClaimOwner: dispatchClaim.ownerId,
          dispatchClaimGeneration: dispatchClaim.generation,
        );
        final commitToken = ChatMessageCommitToken(
          '$commandId:$attempt:${handle.runId}',
          generation: attempt,
        );
        _activeCommitToken = commitToken;
        final commit = await repository.appendIf(
          conversationId,
          answer,
          commitToken,
          () =>
              !_disposed &&
              attempt == _attempt &&
              _state.status == SingleChatRunStatus.running,
        );
        final stale =
            !commitToken.isValid ||
            _disposed ||
            attempt != _attempt ||
            _state.status != SingleChatRunStatus.running;
        if (stale) {
          if (commit.committed) {
            await repository.rollbackOwned(conversationId, commit);
          }
          _releaseDispatchClaim(dispatchClaim);
          return;
        }
        _activeCommitToken = null;
        if (!commit.committed) {
          _releaseDispatchClaim(dispatchClaim);
          var canRetry = false;
          try {
            final command = repository.commandOutbox.read(
              conversationId,
              commandId,
            );
            canRetry =
                command?.status == SingleChatCommandStatus.pending &&
                !(command?.hasDispatchClaim ?? true);
          } catch (_) {
            canRetry = false;
          }
          _state = _state.copyWith(
            status: SingleChatRunStatus.failed,
            canRetry: canRetry,
          );
          notifyListeners();
          return;
        }
        final terminalCommitted = await _commitCompletedTerminal(
          commandId: commandId,
          dispatchClaim: dispatchClaim,
          commitToken: commitToken,
          commit: commit,
        );
        if (!terminalCommitted ||
            _disposed ||
            attempt != _attempt ||
            _state.status != SingleChatRunStatus.running) {
          return;
        }
        // Generated pictures land as their own messages: an expert that drew
        // something should show it, not describe it.
        final assets = <ChatMessageProjection>[];
        for (final (index, path) in outcome.generatedAssetPaths.indexed) {
          final asset = ChatMessageProjection(
            id: '$commandId:asset:$index',
            kind: ChatMessageKind.agentImage,
            imageUrl: path,
            text: '',
          );
          try {
            await repository.append(conversationId, asset);
            assets.add(asset);
          } catch (_) {
            // The answer is already committed; a missing picture is better
            // than losing the reply it came with.
          }
        }
        _state = _state.copyWith(
          messages: commit.inserted
              ? [
                  ..._state.messages.where(
                    (message) => message.id != answer.id,
                  ),
                  answer,
                  ...assets,
                ]
              : [..._state.messages, ...assets],
          status: SingleChatRunStatus.completed,
          canRetry: false,
        );
      } else {
        _releaseDispatchClaim(dispatchClaim);
        _state = _state.copyWith(
          status: _statusFor(outcome.failure),
          canRetry:
              outcome.failure == SingleAgentRunFailure.retryable ||
              outcome.failure == SingleAgentRunFailure.malformedOutput,
        );
      }
      notifyListeners();
    } catch (_) {
      _activeCommitToken?.invalidate();
      _activeCommitToken = null;
      if (attempt == _attempt) {
        _cancelPartialAnswers(_partialAnswersSub);
      }
      if (!_disposed && !_mustRetainStoppedClaim(dispatchClaim)) {
        _releaseDispatchClaim(dispatchClaim);
      }
      if (!_disposed &&
          attempt == _attempt &&
          _state.status != SingleChatRunStatus.stopped) {
        _state = _state.copyWith(
          status: SingleChatRunStatus.failed,
          canRetry: _lastText != null && _lastCommandId != null,
          streamingAnswer: '',
        );
        notifyListeners();
      }
    }
  }

  /// Mirrors streamed Answer snapshots into [SingleChatState.streamingAnswer].
  ///
  /// Notifications are throttled to one per [_streamingNotifyIntervalMs] via a
  /// plain timestamp check (no timers), so a fast token stream cannot flood
  /// the widget tree; the state itself always holds the latest snapshot.
  StreamSubscription<String>? _subscribeToPartialAnswers(
    SingleAgentRunHandle handle,
    int attempt,
  ) {
    final partials = handle.partialAnswers;
    if (partials == null) {
      return null;
    }
    var lastNotifyEpochMs = 0;
    final subscription = partials.listen(
      (answer) {
        if (_disposed ||
            attempt != _attempt ||
            _state.status != SingleChatRunStatus.running) {
          return;
        }
        _state = _state.copyWith(streamingAnswer: answer);
        final nowEpochMs = _nowEpochMs();
        if (nowEpochMs - lastNotifyEpochMs >= _streamingNotifyIntervalMs) {
          lastNotifyEpochMs = nowEpochMs;
          notifyListeners();
        }
      },
      onError: (Object _) {
        // Preview delivery is best-effort; the run outcome carries the result.
      },
    );
    _partialAnswersSub = subscription;
    return subscription;
  }

  void _cancelPartialAnswers(StreamSubscription<String>? subscription) {
    if (subscription == null) {
      return;
    }
    unawaited(subscription.cancel());
    if (identical(_partialAnswersSub, subscription)) {
      _partialAnswersSub = null;
    }
  }

  Future<bool> _commitCompletedTerminal({
    required String commandId,
    required SingleChatDispatchClaim dispatchClaim,
    required ChatMessageCommitToken commitToken,
    required ChatMessageCommitResult commit,
  }) async {
    try {
      repository.commandOutbox.markTerminal(
        conversationId,
        commandId,
        SingleChatCommandStatus.completed,
        dispatchClaim: dispatchClaim,
      );
      _clearActiveDispatchClaim(dispatchClaim);
      return true;
    } catch (_) {
      try {
        final persisted = repository.commandOutbox.read(
          conversationId,
          commandId,
        );
        if (persisted?.status == SingleChatCommandStatus.completed &&
            persisted!.wasTerminatedBy(dispatchClaim)) {
          _clearActiveDispatchClaim(dispatchClaim);
          return true;
        }
      } catch (_) {
        // An unreadable terminal journal is handled as an unsafe completion.
      }
      commitToken.invalidate();
      var compensated = false;
      try {
        final rollback = await repository.rollbackOwned(conversationId, commit);
        if (rollback.confirmsNoCommittedAnswer) {
          _releaseDispatchClaim(dispatchClaim);
        }
        final command = repository.commandOutbox.read(
          conversationId,
          commandId,
        );
        compensated =
            rollback.confirmsNoCommittedAnswer &&
            command?.status == SingleChatCommandStatus.pending &&
            !(command?.hasDispatchClaim ?? true);
      } catch (_) {
        // The ownership token already requested durable removal. If an
        // implementation cannot confirm rollback, retry remains disabled.
      }
      if (!_disposed) {
        _state = _state.copyWith(
          status: SingleChatRunStatus.failed,
          canRetry: compensated,
        );
        notifyListeners();
      }
      return false;
    }
  }

  /// The earlier turns this run should be answered in the context of.
  ///
  /// Without this the expert answers every message in isolation and cannot
  /// follow a conversation at all. Only user text and delivered expert replies
  /// count: notices, progress rows and the turn being dispatched are not part
  /// of the dialogue. The window is bounded by turns and by characters so a
  /// long history cannot grow the request without limit.
  List<SingleChatHistoryTurn> _historyForModel({
    required String excludingCommandId,
    int maxTurns = 20,
    int maxCharacters = 12000,
  }) {
    final selected = <SingleChatHistoryTurn>[];
    var budget = maxCharacters;
    for (final message in _state.messages.reversed) {
      if (selected.length >= maxTurns) break;
      final text = message.text;
      if (text == null || text.trim().isEmpty) continue;
      if (message.id.startsWith('$excludingCommandId:')) continue;
      final fromUser = switch (message.kind) {
        ChatMessageKind.userText => true,
        ChatMessageKind.agentText => false,
        _ => null,
      };
      if (fromUser == null) continue;
      if (text.length > budget) break;
      budget -= text.length;
      selected.add(SingleChatHistoryTurn(fromUser: fromUser, text: text));
    }
    return List.unmodifiable(selected.reversed);
  }

  Future<void> stop() async {
    if (_state.status != SingleChatRunStatus.running || _disposed) {
      return;
    }
    _state = _state.copyWith(
      status: SingleChatRunStatus.stopped,
      canRetry: false,
      streamingAnswer: '',
    );
    _cancelPartialAnswers(_partialAnswersSub);
    final handleFuture = _activeHandle;
    final dispatchClaim = _activeDispatchClaim;
    _dispatchLeaseTimer?.cancel();
    _dispatchLeaseTimer = null;
    _activeCommitToken?.invalidate();
    _activeCommitToken = null;
    _attempt += 1;
    _activeSubmission = null;
    _activeHandle = null;
    notifyListeners();
    final commandId = _lastCommandId;
    if (commandId != null) {
      try {
        repository.commandOutbox.markTerminal(
          conversationId,
          commandId,
          SingleChatCommandStatus.stopped,
          dispatchClaim: dispatchClaim,
        );
        if (dispatchClaim != null) {
          _clearActiveDispatchClaim(dispatchClaim);
        }
      } catch (_) {
        // Stop remains terminal even if durable outbox persistence is degraded.
        _outboxReconciliationBlocked = true;
        if (dispatchClaim != null) {
          try {
            final nowEpochMs = _nowEpochMs();
            repository.commandOutbox.renewDispatchClaim(
              claim: dispatchClaim,
              nowEpochMs: nowEpochMs,
              leaseExpiresAtEpochMs: _quarantinedClaimExpiryEpochMs,
            );
          } catch (_) {
            // The existing lease is retained when durable quarantine also fails.
          }
        }
      }
    }
    if (handleFuture != null) {
      unawaited(
        handleFuture.then(
          _stopHandleOnce,
          onError: (_) {
            // A failed start has no run to stop and remains a bounded stopped state.
          },
        ),
      );
    }
  }

  Future<void> _stopHandleOnce(SingleAgentRunHandle handle) async {
    await _stopHandleConfirmed(handle);
  }

  Future<bool> _stopHandleConfirmed(SingleAgentRunHandle handle) {
    return _stopOperations.putIfAbsent(handle.runId, () async {
      try {
        await service.stopSingleAgentRun(handle.runId);
        return true;
      } catch (_) {
        // Cancellation is best-effort and never exposes transport details.
        return false;
      }
    });
  }

  Future<void> _settleDisposedDispatch({
    required Future<SingleAgentRunHandle> handleFuture,
    required SingleChatDispatchClaim dispatchClaim,
  }) async {
    SingleAgentRunHandle handle;
    try {
      handle = await handleFuture;
    } catch (_) {
      _releaseDispatchClaim(dispatchClaim);
      return;
    }
    final stopped = await _stopHandleConfirmed(handle);
    if (!stopped) {
      // Keep the durable lease until expiry when cancellation is unconfirmed.
      return;
    }
    _releaseDispatchClaim(dispatchClaim);
  }

  bool _isCommandPending(String commandId) {
    try {
      return repository.commandOutbox.read(conversationId, commandId)?.status ==
          SingleChatCommandStatus.pending;
    } catch (_) {
      return false;
    }
  }

  bool _mustRetainStoppedClaim(SingleChatDispatchClaim? claim) {
    return claim != null &&
        _outboxReconciliationBlocked &&
        _state.status == SingleChatRunStatus.stopped &&
        identical(_activeDispatchClaim, claim);
  }

  void _releaseDispatchClaim(SingleChatDispatchClaim? claim) {
    if (claim == null) {
      return;
    }
    try {
      repository.commandOutbox.releaseDispatchClaim(claim);
    } catch (_) {
      // A failed release remains bounded by the persisted claim lease.
    }
    if (identical(_activeDispatchClaim, claim)) {
      _dispatchLeaseTimer?.cancel();
      _dispatchLeaseTimer = null;
      _activeDispatchClaim = null;
    }
  }

  void _clearActiveDispatchClaim(SingleChatDispatchClaim claim) {
    if (!identical(_activeDispatchClaim, claim)) {
      return;
    }
    _dispatchLeaseTimer?.cancel();
    _dispatchLeaseTimer = null;
    _activeDispatchClaim = null;
  }

  void _startDispatchLeaseRenewal(SingleChatDispatchClaim claim) {
    _dispatchLeaseTimer?.cancel();
    _dispatchLeaseTimer = Timer.periodic(_dispatchClaimRenewalInterval, (
      timer,
    ) {
      if (_disposed || !identical(_activeDispatchClaim, claim)) {
        timer.cancel();
        return;
      }
      final nowEpochMs = _nowEpochMs();
      var renewed = false;
      try {
        renewed = repository.commandOutbox.renewDispatchClaim(
          claim: claim,
          nowEpochMs: nowEpochMs,
          leaseExpiresAtEpochMs:
              nowEpochMs + _dispatchClaimLease.inMilliseconds,
        );
      } catch (_) {
        renewed = false;
      }
      if (renewed) {
        return;
      }
      timer.cancel();
      _dispatchLeaseTimer = null;
      _outboxReconciliationBlocked = true;
      if (_state.status == SingleChatRunStatus.running) {
        unawaited(stop());
      } else {
        _releaseDispatchClaim(claim);
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelPartialAnswers(_partialAnswersSub);
    _activeCommitToken?.invalidate();
    _activeCommitToken = null;
    final dispatchClaim = _activeDispatchClaim;
    _dispatchLeaseTimer?.cancel();
    _dispatchLeaseTimer = null;
    _attempt += 1;
    final handleFuture = _activeHandle;
    if (handleFuture != null) {
      if (dispatchClaim != null) {
        unawaited(
          _settleDisposedDispatch(
            handleFuture: handleFuture,
            dispatchClaim: dispatchClaim,
          ),
        );
      } else {
        unawaited(handleFuture.then(_stopHandleOnce, onError: (_) {}));
      }
    }
    super.dispose();
  }
}

class _ValidatedMessageSource {
  const _ValidatedMessageSource(this.sourceType, [this.attestation]);

  final ChatMessageSourceType sourceType;
  final ChatMessageVerificationAttestation? attestation;
}

_ValidatedMessageSource _validatedSourceType({
  required String conversationId,
  required String expertId,
  required String runId,
  required String commandId,
  required SingleAgentRunOutcome outcome,
  required _CanonicalEvidenceSet canonicalEvidence,
  required TrustedVerifierReceiptRegistry verifier,
}) {
  final token = outcome.verifierToken;
  final uncertainty = outcome.uncertainty;
  if (token == null ||
      !canonicalEvidence.isValid ||
      canonicalEvidence.references.isEmpty ||
      !isSafeSingleChatUncertaintyDisclosure(uncertainty)) {
    return _ValidatedMessageSource(_unverifiedSourceType(outcome.sourceType));
  }
  try {
    final receiptId = verifier.verifyAndConsume(
      SingleChatVerificationClaim(
        conversationId: conversationId,
        expertId: expertId,
        runId: runId,
        commandId: commandId,
        answer: outcome.answer,
        canonicalEvidenceReferences: canonicalEvidence.references,
        uncertainty: uncertainty,
      ),
      token,
    );
    if (receiptId != null) {
      return _ValidatedMessageSource(
        ChatMessageSourceType.verifiedEvidence,
        ChatMessageVerificationAttestation(
          receiptId: receiptId,
          expertId: expertId,
          runId: runId,
          commandId: commandId,
        ),
      );
    }
    return _ValidatedMessageSource(_unverifiedSourceType(outcome.sourceType));
  } catch (_) {
    return const _ValidatedMessageSource(ChatMessageSourceType.modelOutput);
  }
}

ChatMessageSourceType _unverifiedSourceType(
  ChatMessageSourceType reportedSource,
) {
  return reportedSource == ChatMessageSourceType.userVisibleSummary
      ? ChatMessageSourceType.userVisibleSummary
      : ChatMessageSourceType.modelOutput;
}

class _CanonicalEvidenceSet {
  const _CanonicalEvidenceSet({
    required this.isValid,
    required this.references,
  });

  final bool isValid;
  final List<String> references;
}

_CanonicalEvidenceSet _canonicalizeEvidenceReferences(List<String> references) {
  if (references.isEmpty) {
    return const _CanonicalEvidenceSet(isValid: true, references: []);
  }
  final canonical = <String>{};
  for (final reference in references) {
    final trimmed = reference.trim();
    final uri = Uri.tryParse(trimmed);
    final schemeSeparator = trimmed.indexOf('://');
    final authorityEnd = schemeSeparator < 0
        ? -1
        : trimmed.indexOf('/', schemeSeparator + 3);
    final authority = schemeSeparator < 0
        ? ''
        : trimmed.substring(
            schemeSeparator + 3,
            authorityEnd < 0 ? trimmed.length : authorityEnd,
          );
    if (uri == null ||
        !uri.isAbsolute ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        trimmed.contains('?') ||
        trimmed.contains('#') ||
        authority.contains(':') ||
        authority.contains('%') ||
        authority.toLowerCase() != uri.host.toLowerCase() ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.hasPort ||
        !_isCanonicalEvidenceHost(uri.host)) {
      return const _CanonicalEvidenceSet(isValid: false, references: []);
    }
    final path = uri.normalizePath().path;
    canonical.add(
      Uri(scheme: 'https', host: uri.host.toLowerCase(), path: path).toString(),
    );
  }
  final sorted = canonical.toList()..sort();
  return _CanonicalEvidenceSet(
    isValid: true,
    references: List<String>.unmodifiable(sorted),
  );
}

bool _isCanonicalEvidenceHost(String host) {
  if (host.runes.any((rune) => rune > 0x7f) ||
      host == 'localhost' ||
      !host.contains('.') ||
      InternetAddress.tryParse(host) != null) {
    return false;
  }
  final labels = host.toLowerCase().split('.');
  for (final label in labels) {
    if (label.isEmpty ||
        label.startsWith('xn--') ||
        label.startsWith('-') ||
        label.endsWith('-') ||
        !RegExp(r'^[a-z0-9-]+$').hasMatch(label)) {
      return false;
    }
  }
  return true;
}

List<int> _verificationClaimDigest(SingleChatVerificationClaim claim) {
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            claim.conversationId,
            claim.expertId,
            claim.runId,
            claim.commandId,
            claim.answer,
            claim.canonicalEvidenceReferences,
            claim.uncertainty,
          ]),
        ),
      )
      .bytes;
}

bool _constantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

const int _maxUncertaintyDisclosureLength = 280;

/// Accepts one canonical, short, single-line disclosure for both receipt
/// binding and rendering. Silently normalizing would let the signed value
/// differ from the exact value shown to the user, so unsafe input is rejected.
bool isSafeSingleChatUncertaintyDisclosure(String? value) {
  if (value == null ||
      value.isEmpty ||
      value.length > _maxUncertaintyDisclosureLength ||
      value != value.trim()) {
    return false;
  }
  var hasVisibleRune = false;
  var previousWasSpace = false;
  for (final rune in value.runes) {
    if (_isForbiddenDisclosureRune(rune)) {
      return false;
    }
    if (String.fromCharCode(rune).trim().isEmpty) {
      if (rune != 0x0020 || previousWasSpace) {
        return false;
      }
      previousWasSpace = true;
      continue;
    }
    previousWasSpace = false;
    hasVisibleRune = true;
  }
  return hasVisibleRune;
}

bool _isForbiddenDisclosureRune(int rune) {
  return rune <= 0x001f ||
      (rune >= 0x007f && rune <= 0x009f) ||
      rune == 0x00ad ||
      rune == 0x034f ||
      (rune >= 0x0600 && rune <= 0x0605) ||
      rune == 0x061c ||
      rune == 0x06dd ||
      rune == 0x070f ||
      (rune >= 0x0890 && rune <= 0x0891) ||
      rune == 0x08e2 ||
      (rune >= 0x115f && rune <= 0x1160) ||
      (rune >= 0x17b4 && rune <= 0x17b5) ||
      (rune >= 0x180b && rune <= 0x180f) ||
      (rune >= 0x200b && rune <= 0x200f) ||
      (rune >= 0x2028 && rune <= 0x2029) ||
      (rune >= 0x202a && rune <= 0x202e) ||
      (rune >= 0x2060 && rune <= 0x206f) ||
      rune == 0x2800 ||
      rune == 0x3164 ||
      rune == 0xffa0 ||
      (rune >= 0xfe00 && rune <= 0xfe0f) ||
      rune == 0xfeff ||
      (rune >= 0xfff0 && rune <= 0xfff8) ||
      (rune >= 0xfff9 && rune <= 0xfffb) ||
      rune == 0x110bd ||
      rune == 0x110cd ||
      (rune >= 0x13430 && rune <= 0x13455) ||
      (rune >= 0x1bca0 && rune <= 0x1bca3) ||
      (rune >= 0x1d173 && rune <= 0x1d17a) ||
      (rune >= 0xe0000 && rune <= 0xe0fff);
}

List<int> _secureVerificationRandomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

String _newDispatchOwnerId() {
  return _secureVerificationRandomBytes(
    16,
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

SingleChatRunStatus _statusFor(SingleAgentRunFailure failure) {
  return switch (failure) {
    SingleAgentRunFailure.none => SingleChatRunStatus.completed,
    SingleAgentRunFailure.retryable => SingleChatRunStatus.failed,
    SingleAgentRunFailure.quotaLimited => SingleChatRunStatus.quotaLimited,
    SingleAgentRunFailure.authentication => SingleChatRunStatus.authentication,
    SingleAgentRunFailure.contentFiltered => SingleChatRunStatus.filtered,
    SingleAgentRunFailure.notConfigured => SingleChatRunStatus.notConfigured,
    SingleAgentRunFailure.malformedOutput =>
      SingleChatRunStatus.malformedOutput,
  };
}
