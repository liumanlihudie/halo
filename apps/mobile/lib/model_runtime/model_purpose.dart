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

/// What to say when there is nothing at all to choose from.
///
/// The picker deliberately does **not** filter by declared kind. Aggregators
/// label models inconsistently or not at all, and every filter written against
/// those labels ended up hiding models the user could see in their own console.
/// The user knows which of their models draws; this code only ever knew the
/// labels.
abstract final class ModelPurposeSuitability {
  static String emptyReason(ModelPurpose purpose) => switch (purpose) {
    ModelPurpose.image => '还没有可选的模型，先在服务详情里刷新模型目录',
    ModelPurpose.video => '还没有可选的模型，先在服务详情里刷新模型目录',
    ModelPurpose.vision => '还没有可选的模型，先在服务详情里刷新模型目录',
  };
}
