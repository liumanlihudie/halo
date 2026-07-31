// ignore_for_file: prefer_initializing_formals

import 'dart:io';
import 'dart:math';

import 'package:halo_mobile/app/on_device_speech_transcriber.dart';
import 'package:halo_mobile/features/settings/service_credentials_controller.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/volcano_realtime_dialog.dart';
import 'package:halo_mobile/model_runtime/volcano_speech.dart';

/// Turns the stored 豆包语音 credential into the speech capability single chat
/// consumes.
///
/// The key is resolved **per call**, never cached: a key saved or removed in
/// settings takes effect on the next voice message without restarting the app,
/// and no long-lived copy of the secret sits in memory between uses.
///
/// Every failure path is silent from the caller's point of view — [synthesize]
/// returns null and [transcribe] throws a fixed safe message — because a reply
/// must never be lost to speech, and upstream error text must never reach the
/// UI or the logs.
final class ProductionSingleChatSpeech implements SingleChatSpeech {
  ProductionSingleChatSpeech({
    required ServiceCredentialPersistence persistence,
    required SecretResolver secretResolver,
    required Directory audioDirectory,
    Random? random,
    SpeechTranscriber transcriber = const OnDeviceSpeechTranscriber(),
  }) : _transcriber = transcriber,
       _persistence = persistence,
       _secretResolver = secretResolver,
       _audioDirectory = audioDirectory,
       _random = random ?? Random.secure();

  final SpeechTranscriber _transcriber;
  final ServiceCredentialPersistence _persistence;
  final SecretResolver _secretResolver;
  final Directory _audioDirectory;
  final Random _random;

  /// 豆包 flash recognition, falling back to the device when it cannot run.
  ///
  /// The vendor path uses the contract proven in the owner's own project. If no
  /// key is configured — or the service refuses — Apple's on-device recogniser
  /// answers instead, so a voice message is never lost to a missing key.
  @override
  Future<String> transcribe(String recordingPath) async {
    final config = await _config();
    if (config != null) {
      try {
        return await VolcanoSpeechTranscriber(
          config: config,
          newRequestId: _newRequestId,
        ).transcribe(recordingPath);
      } on SpeechException catch (error) {
        // "没有听清" is a real answer about the audio, not a service problem:
        // falling back would only ask a second engine the same question.
        if (error.safeMessage.contains('没有听清')) rethrow;
      }
    }
    return _transcriber.transcribe(recordingPath);
  }

  String? _lastSynthesisFailure;

  @override
  String? get lastSynthesisFailure => _lastSynthesisFailure;

  @override
  Future<String?> synthesize(String text, {required String messageId}) async {
    _lastSynthesisFailure = null;
    final config = await _config();
    if (config == null) {
      _lastSynthesisFailure = '未配置豆包语音 Key';
      return null;
    }
    try {
      await _audioDirectory.create(recursive: true);
      // Message-scoped filename so replaying a reply reuses one file instead of
      // filling the sandbox with a copy per playback.
      final target =
          '${_audioDirectory.path}${Platform.pathSeparator}'
          '${_safeFileStem(messageId)}.mp3';
      return await VolcanoSpeechSynthesizer(
        config: config,
        newRequestId: _newRequestId,
      ).synthesize(text: text, targetPath: target);
    } on SpeechException catch (error) {
      // The words are already on screen; losing the audio is the lesser harm,
      // but the reason is worth saying out loud.
      _lastSynthesisFailure = error.safeMessage;
      return null;
    } catch (_) {
      _lastSynthesisFailure = '语音合成失败，请重试';
      return null;
    }
  }

  /// Opens a live call with the same stored credential.
  ///
  /// Returns null when no key is configured, so the call surface can say so
  /// instead of dialling into nothing.
  /// Opens a live call.
  ///
  /// The dialogue handshake needs both the console App ID and the Access
  /// Token, while settings stores one secret per service, so the credential is
  /// written as `appId:accessToken`. Returns null when it is absent or not in
  /// that form, and the call surface then says so rather than dialling into
  /// nothing.
  Future<VolcanoRealtimeDialog?> openCall() async {
    final config = await _config(KeyOnlyService.doubaoRealtimeAudio);
    if (config == null) return null;
    // Settings keeps the dialogue fields as one secret joined by colons:
    // App ID, App Key, Access Token. Two parts means the documented fixed app
    // key is in use.
    final parts = config.apiKey.split(':');
    if (parts.length == 3 && parts.every((part) => part.isNotEmpty)) {
      return VolcanoRealtimeDialog(
        appId: parts[0],
        appKey: parts[1],
        accessToken: parts[2],
        newId: _newRequestId,
        sampleRate: config.sampleRate,
      );
    }
    if (parts.length == 2 && parts.every((part) => part.isNotEmpty)) {
      return VolcanoRealtimeDialog(
        appId: parts[0],
        accessToken: parts[1],
        newId: _newRequestId,
        sampleRate: config.sampleRate,
      );
    }
    // A secret is stored, it just is not what this API needs. Saying "not
    // configured" would send the user hunting for a key that is already there.
    throw const RealtimeDialogException('通话凭证需填 App ID、App Key 与 Access Token');
  }

  Future<VolcanoSpeechConfig?> _config([
    KeyOnlyService service = KeyOnlyService.doubaoSpeech,
  ]) async {
    return await _configFor(service) ??
        await _configFor(
          service == KeyOnlyService.doubaoSpeech
              ? KeyOnlyService.doubaoRealtimeAudio
              : KeyOnlyService.doubaoSpeech,
        );
  }

  Future<VolcanoSpeechConfig?> _configFor(KeyOnlyService service) async {
    try {
      final records = await _persistence.loadServiceCredentials();
      for (final record in records) {
        if (record.serviceId != service.id) continue;
        if (!record.enabled) return null;
        final credential = await _secretResolver.resolve(record.secretRef);
        final key = credential?.value;
        if (key == null || key.isEmpty) return null;
        // The dialogue entry stores three joined values; synthesis and
        // transcription authenticate with the access token alone, so a joined
        // secret would be rejected outright and the reply would silently come
        // back without audio.
        final token = key.contains(':') ? key.split(':').last : key;
        return token.isEmpty ? null : VolcanoSpeechConfig(apiKey: token);
      }
      return null;
    } catch (_) {
      // A missing or unreadable credential is "speech unavailable", never a
      // surfaced error naming the locator.
      return null;
    }
  }

  /// Volcano requires a request id per call; it is a correlation value only and
  /// carries nothing about the user.
  String _newRequestId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _safeFileStem(String messageId) =>
      messageId.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
}
