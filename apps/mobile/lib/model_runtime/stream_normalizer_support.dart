import 'dart:async';

import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/chat_stream_models.dart';
import 'package:halo_mobile/model_runtime/chat_stream_normalizer.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/structured_sse_frame.dart';

abstract base class SafeStructuredSseNormalizer
    implements ChatStreamNormalizer {
  @override
  Stream<ChatStreamEvent> normalize(
    Stream<StructuredSseFrame> frames, {
    required CancellationToken cancellationToken,
  }) async* {
    final state = StreamNormalizationState();
    final iterator = StreamIterator<StructuredSseFrame>(frames);
    try {
      while (true) {
        final next = await _nextOrCancellation(iterator, cancellationToken);
        if (next.cancelled || cancellationToken.isCancelled) {
          return;
        }
        if (!next.hasFrame) {
          break;
        }

        final frame = iterator.current;
        if (frame.kind == StructuredSseFrameKind.error) {
          if (cancellationToken.isCancelled) {
            return;
          }
          yield state.fail(_safeFrameError(frame.statusCode));
          return;
        }

        try {
          final events = switch (frame.kind) {
            StructuredSseFrameKind.data => handleData(frame.data!, state),
            StructuredSseFrameKind.done => handleDone(state),
            StructuredSseFrameKind.error => const <ChatStreamEvent>[],
          };
          for (final event in events) {
            if (cancellationToken.isCancelled) {
              return;
            }
            yield event;
          }
          if (cancellationToken.isCancelled) {
            return;
          }
          if (state.hasEndMarker) {
            if (cancellationToken.isCancelled) {
              return;
            }
            yield state.finish();
            return;
          }
        } on SafeStreamFailure catch (failure) {
          if (cancellationToken.isCancelled) {
            return;
          }
          yield state.fail(failure.exception);
          return;
        } catch (_) {
          if (cancellationToken.isCancelled) {
            return;
          }
          yield state.fail(_malformedStream());
          return;
        }
      }

      if (cancellationToken.isCancelled) {
        return;
      }
      try {
        completeAtSourceEnd(state);
        if (cancellationToken.isCancelled) {
          return;
        }
        yield state.finish();
      } on SafeStreamFailure catch (failure) {
        if (!cancellationToken.isCancelled) {
          yield state.fail(failure.exception);
        }
      } catch (_) {
        if (!cancellationToken.isCancelled) {
          yield state.fail(_malformedStream());
        }
      }
    } catch (_) {
      if (!cancellationToken.isCancelled) {
        yield state.fail(_interruptedStream());
      }
    } finally {
      try {
        await iterator.cancel();
      } catch (_) {
        // A transport may fail while its subscription is being cancelled.
        // Terminal output already emitted must never be replaced by that body.
      }
    }
  }

  Iterable<ChatStreamEvent> handleData(
    Map<String, Object?> data,
    StreamNormalizationState state,
  );

  Iterable<ChatStreamEvent> handleDone(StreamNormalizationState state) {
    state.markEnd();
    return const [];
  }

  void completeAtSourceEnd(StreamNormalizationState state) {
    if (!state.hasEndMarker) {
      throw const SafeStreamFailure.malformed();
    }
  }

  Future<_NextFrame> _nextOrCancellation(
    StreamIterator<StructuredSseFrame> iterator,
    CancellationToken token,
  ) async {
    if (token.isCancelled) {
      return const _NextFrame.cancelled();
    }
    return Future.any([
      iterator.moveNext().then(_NextFrame.frame),
      token.whenCancelled.then((_) => const _NextFrame.cancelled()),
    ]);
  }

  ModelRuntimeException _safeFrameError(int? statusCode) {
    if (statusCode != null) {
      return ModelRuntimeErrorMapper.fromHttpStatus(statusCode);
    }
    return const ModelRuntimeException(
      code: ModelRuntimeErrorCode.transportFailure,
      safeMessage: '模型流连接失败',
      retryable: true,
    );
  }

  ModelRuntimeException _malformedStream() => const ModelRuntimeException(
    code: ModelRuntimeErrorCode.malformedResponse,
    safeMessage: '模型流返回了无法识别的数据',
    retryable: false,
  );

  ModelRuntimeException _interruptedStream() => const ModelRuntimeException(
    code: ModelRuntimeErrorCode.streamInterrupted,
    safeMessage: '模型流已中断',
    retryable: true,
  );
}

class StreamNormalizationState {
  int _seq = 0;
  bool _started = false;
  bool _hasEndMarker = false;
  bool _failed = false;
  bool _forceContentFiltered = false;
  ChatFinishReason? _pendingFinish;
  ChatUsage _usage = const ChatUsage(inputTokens: 0, outputTokens: 0);
  final Set<int> _openContentBlocks = {};

  bool get hasStarted => _started;
  bool get hasEndMarker => _hasEndMarker;
  bool get hasPendingFinish => _pendingFinish != null;
  ChatUsage get currentUsage => _usage;
  final Map<String, int> _protocolCounters = {};

  void start() {
    if (_started || _hasEndMarker || _failed) {
      throw const SafeStreamFailure.malformed();
    }
    _started = true;
  }

  void startIfNeeded() {
    if (!_started) {
      start();
    }
  }

  void ensureContentBlockBoundaryAllowed() {
    if (!_started || _pendingFinish != null || _hasEndMarker || _failed) {
      throw const SafeStreamFailure.malformed();
    }
  }

  void startContentBlock(int index) {
    ensureContentBlockBoundaryAllowed();
    if (index < 0 || !_openContentBlocks.add(index)) {
      throw const SafeStreamFailure.malformed();
    }
  }

  void ensureContentBlockActive(int index) {
    ensureContentBlockBoundaryAllowed();
    if (!_openContentBlocks.contains(index)) {
      throw const SafeStreamFailure.malformed();
    }
  }

  void stopContentBlock(int index) {
    ensureContentBlockBoundaryAllowed();
    if (!_openContentBlocks.remove(index)) {
      throw const SafeStreamFailure.malformed();
    }
  }

  void ensureNoOpenContentBlocks() {
    if (_openContentBlocks.isNotEmpty) {
      throw const SafeStreamFailure.malformed();
    }
  }

  int protocolCounter(String key) => _protocolCounters[key] ?? 0;

  void setProtocolCounter(String key, int value) {
    if (!_started || _hasEndMarker || _failed || value < 0) {
      throw const SafeStreamFailure.malformed();
    }
    _protocolCounters[key] = value;
  }

  ChatStreamEvent delta(String text) {
    if (!_started ||
        _pendingFinish != null ||
        _hasEndMarker ||
        _failed ||
        text.isEmpty) {
      throw const SafeStreamFailure.malformed();
    }
    return ChatStreamEvent.delta(seq: _nextSeq(), text: text);
  }

  ChatStreamEvent? cumulativeUsage(ChatUsage usage) {
    if (!_started || _hasEndMarker || _failed) {
      throw const SafeStreamFailure.malformed();
    }
    if (usage.inputTokens < _usage.inputTokens ||
        usage.outputTokens < _usage.outputTokens) {
      throw const SafeStreamFailure.malformed();
    }
    if (usage == _usage) {
      return null;
    }
    _usage = usage;
    return ChatStreamEvent.usage(seq: _nextSeq(), usage: usage);
  }

  void markContentFiltered() {
    if (_hasEndMarker || _failed) {
      throw const SafeStreamFailure.malformed();
    }
    _forceContentFiltered = true;
  }

  void markFinish(ChatFinishReason reason) {
    if (!_started || _pendingFinish != null || _hasEndMarker || _failed) {
      throw const SafeStreamFailure.malformed();
    }
    _pendingFinish = _forceContentFiltered
        ? ChatFinishReason.contentFiltered
        : reason;
  }

  void markEnd() {
    if (!_started || _pendingFinish == null || _hasEndMarker || _failed) {
      throw const SafeStreamFailure.malformed();
    }
    _hasEndMarker = true;
  }

  ChatStreamEvent finish() {
    if (!_hasEndMarker || _pendingFinish == null || _failed) {
      throw const SafeStreamFailure.malformed();
    }
    return ChatStreamEvent.finish(
      seq: _nextSeq(),
      finishReason: _pendingFinish!,
    );
  }

  ChatStreamEvent fail(ModelRuntimeException exception) {
    if (_failed) {
      throw const SafeStreamFailure.malformed();
    }
    _failed = true;
    return ChatStreamEvent.error(
      seq: _nextSeq(),
      code: exception.code,
      safeMessage: exception.safeMessage,
      retryable: exception.retryable,
    );
  }

  int _nextSeq() => ++_seq;
}

class SafeStreamFailure implements Exception {
  const SafeStreamFailure(this.exception);

  const SafeStreamFailure.malformed()
    : exception = const ModelRuntimeException(
        code: ModelRuntimeErrorCode.malformedResponse,
        safeMessage: '模型流返回了无法识别的数据',
        retryable: false,
      );

  final ModelRuntimeException exception;
}

class _NextFrame {
  const _NextFrame.frame(this.hasFrame) : cancelled = false;

  const _NextFrame.cancelled() : hasFrame = false, cancelled = true;

  final bool hasFrame;
  final bool cancelled;
}
