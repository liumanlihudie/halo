// ignore_for_file: prefer_initializing_formals

import 'package:flutter/services.dart';
import 'package:halo_mobile/model_runtime/volcano_speech.dart';

/// Transcribes a recording with Apple's on-device recogniser.
///
/// Chosen over the vendor recording-recognition API because that contract was
/// never verified against the real service and failed with nothing to debug.
/// This one needs no key, works offline, and the audio never leaves the phone.
/// Synthesis still goes to 豆包, so each expert keeps its own voice.
final class OnDeviceSpeechTranscriber implements SpeechTranscriber {
  const OnDeviceSpeechTranscriber({
    MethodChannel channel = const MethodChannel('halo.speech/on_device'),
    String locale = 'zh-CN',
  }) : _channel = channel,
       _locale = locale;

  final MethodChannel _channel;
  final String _locale;

  @override
  Future<String> transcribe(String sourcePath) async {
    final String? text;
    try {
      text = await _channel.invokeMethod<String>('transcribe', {
        'path': sourcePath,
        'locale': _locale,
      });
    } on PlatformException catch (error) {
      // Fixed messages by category: the platform's own text never surfaces.
      throw SpeechException(switch (error.code) {
        'not_authorized' => '需要语音识别权限才能转文字',
        'unavailable' => '本机语音识别不可用',
        _ => '转写失败，请重试',
      });
    } catch (_) {
      throw const SpeechException('转写失败，请重试');
    }
    final transcript = text?.trim() ?? '';
    if (transcript.isEmpty) {
      throw const SpeechException('没有听清，请再说一次');
    }
    return transcript;
  }
}
