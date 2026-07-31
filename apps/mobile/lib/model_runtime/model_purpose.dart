import 'package:halo_mobile/model_runtime/model_runtime_models.dart';

/// A job a model can be bound to, beyond answering in chat.
///
/// Chat keeps its own binding (`override ?? globalDefault`); these are global
/// only, because "which model draws" is not a per-expert decision.
enum ModelPurpose {
  /// Generates images.
  image('image', '默认图片模型'),

  /// Generates video.
  video('video', '默认视频模型'),

  /// Reads an image and describes it, so an expert that cannot see images can
  /// still answer about one.
  vision('vision', '图片识别模型');

  const ModelPurpose(this.storageId, this.displayName);

  /// Persisted, so renaming one would orphan a user's choice.
  final String storageId;
  final String displayName;
}

abstract interface class PurposeModelBindingStore {
  Future<ModelRef?> loadPurposeModel(ModelPurpose purpose);
  Future<void> setPurposeModel(ModelPurpose purpose, ModelRef? model);
  Future<Map<String, Set<String>>> loadProviderModelModalities(
    String providerId,
  );
}

/// Decides which models may be offered for a purpose.
///
/// **Never asks the model.** A model's own answer about what it can do is
/// unreliable — an aggregated chat model will happily say it reads images and
/// then ignore one — so the only inputs here are what the provider declared in
/// its catalogue and, for vision, the user's explicit choice.
abstract final class ModelPurposeSuitability {
  static const _imageTypes = <String>{
    'image',
    'images',
    'image_generations',
    'images/generations',
    'image_generation',
  };

  static const _videoTypes = <String>{
    'video',
    'videos',
    'video_generations',
    'videos/generations',
    'video_generation',
  };

  /// True when [model] may be offered for [purpose].
  static bool allows(ModelPurpose purpose, ModelDescriptor model) {
    final declared = model.declaredModalities;
    return switch (purpose) {
      ModelPurpose.image => declared.any(_imageTypes.contains),
      ModelPurpose.video => declared.any(_videoTypes.contains),
      // Vision is a chat model that accepts image input. Relays do not declare
      // that anywhere, and asking the model is exactly what produces the
      // "sure I can read images" answer followed by silence. So every text
      // model is offered and the user names the one that actually works.
      ModelPurpose.vision => model.capabilities.textGeneration,
    };
  }

  /// What to tell the user when nothing qualifies.
  static String emptyReason(ModelPurpose purpose) => switch (purpose) {
    ModelPurpose.image => '已配置的服务里没有声明图片生成能力的模型',
    ModelPurpose.video => '已配置的服务里没有声明视频生成能力的模型',
    ModelPurpose.vision => '还没有可用的文字模型',
  };
}
