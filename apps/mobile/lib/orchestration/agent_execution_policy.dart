import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';

/// P0 execution limits for provider-backed group-chat turns.
///
/// This policy deliberately has no tool or private-memory configuration: the
/// unary model boundary receives neither capability.
final class AgentExecutionPolicy {
  AgentExecutionPolicy({
    required this.defaultModel,
    required this.summarizerModel,
    Map<String, ModelRef> expertModelOverrides = const {},
    PromptPackage? summarizerPrompt,
    this.requestTimeout = const Duration(seconds: 30),
    this.maxSharedContextCharacters = 4096,
    this.maxPublicAnswerCharacters = 2048,
  }) : expertModelOverrides = Map.unmodifiable(expertModelOverrides),
       summarizerPrompt = summarizerPrompt ?? _defaultSummarizerPrompt {
    if (requestTimeout <= Duration.zero ||
        maxSharedContextCharacters <= 0 ||
        maxPublicAnswerCharacters <= 0) {
      throw ArgumentError('Execution limits must be positive.');
    }
  }

  final ModelRef defaultModel;
  final ModelRef summarizerModel;
  final Map<String, ModelRef> expertModelOverrides;
  final PromptPackage summarizerPrompt;
  final Duration requestTimeout;
  final int maxSharedContextCharacters;
  final int maxPublicAnswerCharacters;

  ModelRef modelForExpert(String expertId) =>
      expertModelOverrides[expertId] ?? defaultModel;

  static final PromptPackage _defaultSummarizerPrompt = PromptPackage(
    system: '你是独立总结器，不是任何参与讨论的专家。只总结公开讨论内容。',
    personality: '谨慎、简洁、明确区分事实与未验证判断。',
    constraints: const [
      '不得采用参与者身份、工具权限或私人记忆。',
      '只返回 JSON：answer、uncertainty、evidenceReferences。',
      '没有可信证据时 uncertainty 必须为 unverified。',
    ],
    guards: const {
      PromptGuard.roleIntegrity,
      PromptGuard.evidenceBoundaries,
      PromptGuard.noFabrication,
    },
  );
}
