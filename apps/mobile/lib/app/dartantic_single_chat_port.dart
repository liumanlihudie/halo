// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:developer' as developer;

import 'package:dartantic_ai/dartantic_ai.dart' as dartantic;
import 'package:dartantic_interface/dartantic_interface.dart' as llm;
import 'package:halo_mobile/experts/expert_output_prompt.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/app/generation_tools.dart';
import 'package:halo_mobile/app/production_vision_describer.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';

/// Builds a ready-to-use agent for an expert.
///
/// Implemented where credentials already live, so the API key is resolved and
/// handed to the client library without ever passing through the chat layer.
abstract interface class SingleChatAgentFactory {
  /// Throws [StateError] when no usable model binding exists yet.
  ///
  /// [tools] are the capabilities this turn may use. Passed per run rather
  /// than baked into the agent because each one closes over where its result
  /// should land.
  Future<dartantic.Agent> agentFor(
    String expertId, {
    List<dartantic.Tool> tools = const [],
  });
}

/// Builds an agent for an already-resolved model binding.
///
/// Group chat resolves the model itself (override ?? global) before dispatch,
/// so it needs this shape rather than the per-expert one.
abstract interface class ModelAgentFactory {
  /// Throws [StateError] when the provider is disabled or has no credential.
  Future<dartantic.Agent> agentForModel(
    ModelRef model, {
    List<dartantic.Tool> tools = const [],
  });
}

/// Single chat on top of dartantic_ai.
///
/// Deliberately thin, matching what every mainstream open-source client does
/// (ChatMCP, flutter_ai_toolkit, dartantic_chat): send the system prompt, the
/// conversation so far and the new message; accumulate the streamed text;
/// render it as markdown. There is no envelope to decode, no schema to
/// satisfy and no repair retry, so a reply the user has already read can never
/// be thrown away. Only a reply with no text at all is a failure.
final class DartanticSingleChatPort implements SingleChatPort {
  DartanticSingleChatPort({
    required SingleChatAgentFactory agents,
    required ExecutableExpertRegistry experts,
    VisionDescriber? vision,
    GenerationService? generation,
  }) : _agents = agents,
       _experts = experts,
       _vision = vision,
       _generation = generation;

  final SingleChatAgentFactory _agents;
  final ExecutableExpertRegistry _experts;

  /// Reads attached images. Absent in prototype wiring, where an attachment is
  /// reported as unsupported rather than quietly dropped.
  final VisionDescriber? _vision;

  /// Image and video generation, offered to every expert as an ordinary
  /// capability. Absent in prototype wiring, where the tools are simply not
  /// declared and the model never offers what it cannot do.
  final GenerationService? _generation;
  final Map<String, _ActiveRun> _active = {};
  bool _closed = false;

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) async {
    if (_closed) {
      throw StateError('Production single chat is unavailable');
    }
    final expert = _experts.singleChatById(request.expertId);
    if (expert == null) {
      throw StateError('Expert is not authorized for single chat');
    }
    final runId = 'single-${request.clientCommandId}';
    if (_active.containsKey(runId)) {
      throw StateError('A run with this command identity is already active');
    }
    final partials = StreamController<String>.broadcast();
    final cancelled = Completer<void>();
    final outcome = _run(
      expert: expert,
      request: request,
      partials: partials,
      cancelled: cancelled,
    );
    _active[runId] = _ActiveRun(cancelled, outcome);
    unawaited(
      outcome.whenComplete(() {
        _active.remove(runId);
        unawaited(partials.close());
      }),
    );
    return SingleAgentRunHandle(
      runId: runId,
      outcome: outcome,
      partialAnswers: partials.stream,
    );
  }

  /// Turns every attached image into quoted description text, or throws
  /// [VisionUnavailable].
  Future<String?> _describeImages(StartSingleAgentRunRequest request) async {
    if (request.imagePaths.isEmpty) return null;
    final vision = _vision;
    if (vision == null) {
      throw const VisionUnavailable('本机未接入图片识别');
    }
    final described = <String>[];
    for (final path in request.imagePaths) {
      described.add(await vision.describe(path));
    }
    return buildVisionContext(described.join('\n\n'));
  }

  Future<SingleAgentRunOutcome> _run({
    required ExecutableExpert expert,
    required StartSingleAgentRunRequest request,
    required StreamController<String> partials,
    required Completer<void> cancelled,
  }) async {
    final answer = StringBuffer();
    final generated = <String>[];
    try {
      // An expert answering about an image it never received is the failure
      // the owner hit: the model says it can see, the relay drops the image,
      // the reply reads as if nothing was attached. So a turn carrying images
      // either gets a real description or fails loudly.
      final visionContext = await _describeImages(request);
      final generation = _generation;
      final agent = await _agents.agentFor(
        request.expertId,
        tools: generation == null
            ? const []
            : buildGenerationTools(
                service: generation,
                // The most recent attachment doubles as the reference image,
                // so "把这张改成赛博朋克风" works without a second picker.
                referencePath: request.imagePaths.isEmpty
                    ? null
                    : request.imagePaths.last,
                onGenerated: (asset) => generated.add(asset.localPath),
              ),
      );
      final history = <llm.ChatMessage>[
        llm.ChatMessage.system(_systemPrompt(expert)),
        for (final turn in request.history)
          if (turn.fromUser)
            llm.ChatMessage.user(turn.text)
          else
            llm.ChatMessage.model(turn.text),
      ];
      final prompt = visionContext == null
          ? request.text
          : '$visionContext\n\n${request.text}';
      final stream = agent.sendStream(prompt, history: history);
      await for (final chunk in stream) {
        if (cancelled.isCompleted) break;
        final text = chunk.output;
        if (text.isEmpty) continue;
        answer.write(text);
        if (!partials.isClosed) partials.add(answer.toString());
      }
    } on VisionUnavailable {
      // The image could not be read. Answering anyway would produce a reply
      // about nothing, which is exactly what looks like the app ignoring the
      // picture.
      return const SingleAgentRunOutcome.failed(
        failure: SingleAgentRunFailure.notConfigured,
      );
    } on StateError {
      // No usable model binding: retrying cannot help, so say so plainly.
      return const SingleAgentRunOutcome.failed(
        failure: SingleAgentRunFailure.notConfigured,
      );
    } catch (error) {
      // Diagnostic only: the exception *type*, never provider text, headers or
      // model output. Without it a failed send is indistinguishable from any
      // other, and the only way to find the cause is to guess.
      developer.log(
        'single-chat run failed: ${error.runtimeType}',
        name: 'halo.chat',
      );
      // Transport or provider error. Whatever text already arrived is still
      // the model's reply and is kept; only an empty run fails.
      final partial = expert.sanitizePlainAnswer(answer.toString());
      if (partial != null) {
        return SingleAgentRunOutcome.completed(
          answer: partial,
          uncertainty: '回答在传输中断开，内容可能不完整',
          generatedAssetPaths: List.unmodifiable(generated),
        );
      }
      return const SingleAgentRunOutcome.failed(
        failure: SingleAgentRunFailure.retryable,
      );
    }
    if (cancelled.isCompleted) {
      return const SingleAgentRunOutcome.failed(
        failure: SingleAgentRunFailure.retryable,
      );
    }
    final projected = expert.sanitizePlainAnswer(answer.toString());
    if (projected == null) {
      return const SingleAgentRunOutcome.failed(
        failure: SingleAgentRunFailure.retryable,
      );
    }
    return SingleAgentRunOutcome.completed(
      answer: projected,
      generatedAssetPaths: List.unmodifiable(generated),
    );
  }

  @override
  Future<void> stopSingleAgentRun(String runId) async {
    final run = _active[runId];
    if (run == null) return;
    if (!run.cancelled.isCompleted) run.cancelled.complete();
    await run.outcome;
  }

  Future<void> close() async {
    _closed = true;
    final running = _active.values.toList(growable: false);
    for (final run in running) {
      if (!run.cancelled.isCompleted) run.cancelled.complete();
    }
    await Future.wait([for (final run in running) run.outcome.then((_) {})]);
  }

  static String _systemPrompt(ExecutableExpert expert) => [
    expert.profile.promptPackage.render(),
    renderExpertOutputPrompt(expert),
  ].join('\n');
}

final class _ActiveRun {
  const _ActiveRun(this.cancelled, this.outcome);

  final Completer<void> cancelled;
  final Future<SingleAgentRunOutcome> outcome;
}
