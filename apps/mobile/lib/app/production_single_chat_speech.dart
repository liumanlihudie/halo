// ignore_for_file: prefer_initializing_formals

import 'dart:io';
import 'dart:math';

import 'package:halo_mobile/app/on_device_speech_transcriber.dart';
import 'package:halo_mobile/features/settings/service_credentials_controller.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
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

  /// Transcription runs on the device; only synthesis needs the vendor key.
  ///
  /// The vendor's recording-recognition contract was never verified against the
  /// real service and failed with nothing to debug, so speech-to-text uses
  /// Apple's on-device recogniser: no key, works offline, and the recording
  /// never leaves the phone. Synthesis still goes to 豆包, so every expert keeps
  /// its own voice.
  @override
  Future<String> transcribe(String recordingPath) =>
      _transcriber.transcribe(recordingPath);

  @override
  Future<String?> synthesize(String text, {required String messageId}) async {
    final config = await _config();
    if (config == null) return null;
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
    } catch (_) {
      // The words are already on screen; losing the audio is the lesser harm.
      return null;
    }
  }

  Future<VolcanoSpeechConfig?> _config() async {
    try {
      final records = await _persistence.loadServiceCredentials();
      for (final record in records) {
        if (record.serviceId != KeyOnlyService.doubaoSpeech.id) continue;
        if (!record.enabled) return null;
        final credential = await _secretResolver.resolve(record.secretRef);
        final key = credential?.value;
        if (key == null || key.isEmpty) return null;
        return VolcanoSpeechConfig(apiKey: key);
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
