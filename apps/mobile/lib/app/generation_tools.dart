// ignore_for_file: prefer_initializing_formals

import 'dart:io';

import 'package:dartantic_interface/dartantic_interface.dart' as llm;
import 'package:halo_mobile/model_runtime/model_purpose.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/app/generation_transport.dart';

/// What a finished generation produced.
class GeneratedAsset {
  const GeneratedAsset({required this.localPath, required this.prompt});

  final String localPath;
  final String prompt;
}

/// Produces images and video for whichever expert asks.
///
/// Deliberately not a permission: every expert has this, the way every expert
/// can write a paragraph. A per-expert switch would only create a setting
/// nobody wants to find before they can get a picture.
abstract interface class GenerationService {
  Future<GeneratedAsset> generateImage(String prompt, {String? referencePath});
  Future<GeneratedAsset> generateVideo(String prompt, {String? referencePath});
}

/// Raised when generation cannot run. Carries text safe to show.
final class GenerationUnavailable implements Exception {
  const GenerationUnavailable(this.safeMessage);

  final String safeMessage;

  @override
  String toString() => 'GenerationUnavailable($safeMessage)';
}

/// Calls the model bound to [ModelPurpose.image] / [ModelPurpose.video].
///
/// Bindings are read per call so a change in settings applies to the next
/// request without a restart.
final class ProductionGenerationService implements GenerationService {
  ProductionGenerationService({
    required ProviderConfigurationStore store,
    required PurposeModelBindingStore bindings,
    required SecretResolver secretResolver,
    required GenerationTransport transport,
    required Directory outputDirectory,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  }) : _store = store,
       _bindings = bindings,
       _secretResolver = secretResolver,
       _transport = transport,
       _outputDirectory = outputDirectory,
       _now = now ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed;

  /// Polling is the only option here: the provider prefers a webhook, and a
  /// phone has no public callback URL to give it.
  static const pollInterval = Duration(seconds: 2);
  static const imageDeadline = Duration(minutes: 4);
  static const videoDeadline = Duration(minutes: 15);

  final ProviderConfigurationStore _store;
  final PurposeModelBindingStore _bindings;
  final SecretResolver _secretResolver;
  final GenerationTransport _transport;
  final Directory _outputDirectory;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;

  @override
  Future<GeneratedAsset> generateImage(
    String prompt, {
    String? referencePath,
  }) => _generate(ModelPurpose.image, prompt, referencePath);

  @override
  Future<GeneratedAsset> generateVideo(
    String prompt, {
    String? referencePath,
  }) => _generate(ModelPurpose.video, prompt, referencePath);

  Future<GeneratedAsset> _generate(
    ModelPurpose purpose,
    String prompt,
    String? referencePath,
  ) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) {
      throw const GenerationUnavailable('没有可用于生成的描述');
    }
    final model = await _bindings.loadPurposeModel(purpose);
    if (model == null) {
      throw GenerationUnavailable('未设置${purpose.displayName}，去「设置 - 模型服务」选一个');
    }
    final config = await _configFor(model.providerId);
    if (config == null) {
      throw GenerationUnavailable('${purpose.displayName}所属的服务不可用');
    }
    final headers = <String, String>{};
    final ref = config.secretRef;
    final credential = ref == null ? null : await _secretResolver.resolve(ref);
    if (credential != null) {
      headers['authorization'] = 'Bearer ${credential.value}';
    }
    try {
      // A reference image has to become a URL first: the provider stopped
      // accepting inline base64 in the generation call.
      final referenceUrl = referencePath == null
          ? null
          : await _uploadReference(config.baseUri, headers, referencePath);
      final submitted = await _transport.postJson(
        endpoint: _endpoint(config.baseUri, purpose),
        headers: headers,
        body: {
          'model': model.modelId,
          'prompt': trimmed,
          if (referenceUrl != null) 'image_urls': [referenceUrl],
        },
      );
      final taskId = submitted['id'];
      if (taskId is! String || taskId.isEmpty) {
        throw const GenerationUnavailable('模型服务没有返回任务号');
      }
      final resultUrl = await _awaitResult(
        baseUri: config.baseUri,
        purpose: purpose,
        headers: headers,
        taskId: taskId,
      );
      final stem = 'gen-${_now().toUtc().microsecondsSinceEpoch}';
      final path = await _transport.download(
        Uri.parse(resultUrl),
        _outputDirectory,
        stem,
      );
      return GeneratedAsset(localPath: path, prompt: trimmed);
    } on GenerationTransportException catch (error) {
      throw GenerationUnavailable(error.safeMessage);
    }
  }

  Future<String> _uploadReference(
    Uri baseUri,
    Map<String, String> headers,
    String referencePath,
  ) async {
    final response = await _transport.uploadImage(
      endpoint: _path(baseUri, '/uploads/images'),
      headers: headers,
      file: File(referencePath),
    );
    final data = response['data'];
    final url = data is Map<String, Object?> ? data['url'] : null;
    if (url is! String || url.isEmpty) {
      throw const GenerationUnavailable('参考图上传失败');
    }
    return url;
  }

  /// Polls until the task finishes, fails, or runs out of time.
  Future<String> _awaitResult({
    required Uri baseUri,
    required ModelPurpose purpose,
    required Map<String, String> headers,
    required String taskId,
  }) async {
    final deadline = _now().add(
      purpose == ModelPurpose.video ? videoDeadline : imageDeadline,
    );
    var wait = pollInterval;
    while (true) {
      if (_now().isAfter(deadline)) {
        // Says it timed out rather than leaving a spinner forever. The task may
        // still finish upstream; nothing here pretends it did.
        throw const GenerationUnavailable('生成超时，没有等到结果');
      }
      await _sleep(wait);
      final Map<String, Object?> task;
      try {
        task = await _transport.getJson(
          endpoint: _path(baseUri, '${_suffix(purpose)}/$taskId'),
          headers: headers,
        );
      } on GenerationRateLimited catch (limited) {
        // Backs off by exactly what the provider asked for.
        wait = limited.retryAfter ?? (wait * 2);
        continue;
      }
      wait = pollInterval;
      final status = task['status'];
      if (status == 'failed') {
        final error = task['error'];
        final message = error is Map<String, Object?> ? error['message'] : null;
        throw GenerationUnavailable(
          message is String && message.isNotEmpty ? message : '生成失败',
        );
      }
      if (status != 'completed') continue;
      final result = task['result'];
      final data = result is Map<String, Object?> ? result['data'] : null;
      if (data is! List || data.isEmpty) {
        throw const GenerationUnavailable('任务完成但没有结果');
      }
      final first = data.first;
      final url = first is Map<String, Object?> ? first['url'] : null;
      if (url is! String || !url.startsWith('https://')) {
        throw const GenerationUnavailable('任务完成但结果地址不可用');
      }
      return url;
    }
  }

  Future<ProviderConfig?> _configFor(String providerId) async {
    for (final config in await _store.loadEnabled()) {
      if (config.providerId == providerId) return config;
    }
    return null;
  }

  static String _suffix(ModelPurpose purpose) => purpose == ModelPurpose.video
      ? '/videos/generations'
      : '/images/generations';

  static Uri _endpoint(Uri baseUri, ModelPurpose purpose) =>
      _path(baseUri, _suffix(purpose));

  static Uri _path(Uri baseUri, String suffix) {
    final basePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(path: '$basePath$suffix');
  }
}

/// The tools handed to every expert.
///
/// Returning a description of what happened, not the bytes: the model needs to
/// know it succeeded and where the asset went so it can refer to it, and
/// putting the file itself in the transcript would blow the context window.
List<llm.Tool> buildGenerationTools({
  required GenerationService service,
  required void Function(GeneratedAsset asset) onGenerated,
  String? referencePath,
}) => [
  llm.Tool<Map<String, dynamic>>(
    name: 'generate_image',
    description:
        '根据文字描述生成一张图片。当用户想要图、封面、示意图、配图时使用。'
        '生成的图片会直接显示给用户，不需要你再描述它的样子。',
    inputSchema: llm.S.object(
      properties: {
        'prompt': llm.S.string(description: '对要生成的图片的完整描述，用中文或英文，越具体越好'),
      },
      required: ['prompt'],
    ),
    onCall: (input) async {
      final prompt = input['prompt'];
      if (prompt is! String) return {'ok': false, 'error': '缺少描述'};
      try {
        final asset = await service.generateImage(
          prompt,
          referencePath: referencePath,
        );
        onGenerated(asset);
        return {'ok': true, 'note': '图片已生成并展示给用户'};
      } on GenerationUnavailable catch (error) {
        // Handed back to the model so it can tell the user in its own words
        // instead of the turn dying with a bare failure.
        return {'ok': false, 'error': error.safeMessage};
      } catch (_) {
        return {'ok': false, 'error': '生成失败'};
      }
    },
  ),
  llm.Tool<Map<String, dynamic>>(
    name: 'generate_video',
    description: '根据文字描述生成一段视频。耗时较长，只在用户明确要视频时使用。',
    inputSchema: llm.S.object(
      properties: {'prompt': llm.S.string(description: '对要生成的视频的完整描述')},
      required: ['prompt'],
    ),
    onCall: (input) async {
      final prompt = input['prompt'];
      if (prompt is! String) return {'ok': false, 'error': '缺少描述'};
      try {
        final asset = await service.generateVideo(
          prompt,
          referencePath: referencePath,
        );
        onGenerated(asset);
        return {'ok': true, 'note': '视频已生成并展示给用户'};
      } on GenerationUnavailable catch (error) {
        return {'ok': false, 'error': error.safeMessage};
      } catch (_) {
        return {'ok': false, 'error': '生成失败'};
      }
    },
  ),
];
