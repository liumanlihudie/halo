// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Speech services for chat: text to audio, and audio to text.
///
/// Both sides are declared here so a voice message never depends on which
/// vendor answers. Failures carry a fixed, safe message: upstream error text
/// never reaches the UI or the logs.
abstract interface class SpeechSynthesizer {
  /// Renders [text] to an audio file at [targetPath] and returns that path.
  Future<String> synthesize({required String text, required String targetPath});
}

abstract interface class SpeechTranscriber {
  /// Returns the spoken text of the recording at [sourcePath].
  Future<String> transcribe(String sourcePath);
}

final class SpeechException implements Exception {
  const SpeechException(this.safeMessage);

  final String safeMessage;

  @override
  String toString() => 'SpeechException($safeMessage)';
}

/// Credentials and voice selection for Volcano Engine (豆包) speech.
///
/// The v3 family authenticates with a single API key, so this fits the
/// existing SecretRef/Keychain model with no special handling.
final class VolcanoSpeechConfig {
  const VolcanoSpeechConfig({
    required this.apiKey,
    this.speaker = 'zh_female_vv_uranus_bigtts',
    this.ttsResourceId = 'seed-tts-2.0',
    this.asrResourceId = 'volc.bigasr.auc_turbo',
    this.sampleRate = 24000,
  });

  final String apiKey;
  final String speaker;
  final String ttsResourceId;
  final String asrResourceId;
  final int sampleRate;

  static final Uri ttsEndpoint = Uri.parse(
    'https://openspeech.bytedance.com/api/v3/tts/unidirectional',
  );
  static final Uri asrFlashEndpoint = Uri.parse(
    'https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash',
  );
}

/// Volcano Engine text-to-speech over the unidirectional HTTP endpoint.
///
/// Shape taken from the owner's working Electron project rather than from
/// documentation guesses: the response is chunked JSON lines whose `data`
/// fields are base64 audio fragments, concatenated in arrival order.
final class VolcanoSpeechSynthesizer implements SpeechSynthesizer {
  VolcanoSpeechSynthesizer({
    required VolcanoSpeechConfig config,
    required String Function() newRequestId,
    HttpClient? httpClient,
    Uri? endpointOverride,
    int maximumAudioBytes = 8 * 1024 * 1024,
  }) : _config = config,
       _newRequestId = newRequestId,
       _client = httpClient ?? HttpClient(),
       _endpoint = endpointOverride ?? VolcanoSpeechConfig.ttsEndpoint,
       _maximumAudioBytes = maximumAudioBytes;

  final VolcanoSpeechConfig _config;
  final String Function() _newRequestId;
  final HttpClient _client;
  final Uri _endpoint;
  final int _maximumAudioBytes;

  /// Roughly one minute of mp3 at 24 kHz is ~180 KB, so the default ceiling
  /// leaves ample room while keeping the response bounded.
  @override
  Future<String> synthesize({
    required String text,
    required String targetPath,
  }) async {
    final spoken = _stripMarkdown(text);
    if (spoken.isEmpty) {
      throw const SpeechException('没有可朗读的内容');
    }
    final audio = BytesBuilder(copy: false);
    for (final segment in _segments(spoken)) {
      audio.add(await _synthesizeSegment(segment));
      if (audio.length > _maximumAudioBytes) {
        throw const SpeechException('语音合成失败，请重试');
      }
    }
    final file = File(targetPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(audio.takeBytes(), flush: true);
    return targetPath;
  }

  Future<Uint8List> _synthesizeSegment(String text) async {
    try {
      final request = await _client.postUrl(_endpoint);
      request.headers
        ..set('Content-Type', 'application/json')
        ..set('X-Api-Key', _config.apiKey)
        ..set('X-Api-Resource-Id', _config.ttsResourceId)
        ..set('X-Api-Request-Id', _newRequestId());
      request.add(
        utf8.encode(
          jsonEncode({
            'req_params': {
              'text': text,
              'speaker': _config.speaker,
              'audio_params': {
                'format': 'mp3',
                'sample_rate': _config.sampleRate,
              },
              // Trailing silence stops the tail of a sentence being clipped by
              // players that trust an under-reported mp3 duration.
              'additions': {
                'silence_duration': 800,
                'disable_markdown_filter': true,
              },
            },
          }),
        ),
      );
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw const SpeechException('语音合成失败，请重试');
      }
      final audio = BytesBuilder(copy: false);
      await for (final line
          in utf8.decoder.bind(response).transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final Object? decoded;
        try {
          decoded = jsonDecode(trimmed);
        } catch (_) {
          // A single unparseable frame must not destroy the audio already
          // received; the caller still gets what the service delivered.
          continue;
        }
        if (decoded is! Map) continue;
        final data = decoded['data'];
        if (data is! String || data.isEmpty) continue;
        audio.add(base64Decode(data));
      }
      final bytes = audio.takeBytes();
      if (bytes.isEmpty) {
        throw const SpeechException('语音合成失败，请重试');
      }
      return bytes;
    } on SpeechException {
      rethrow;
    } catch (_) {
      throw const SpeechException('语音合成失败，请重试');
    }
  }

  /// The endpoint accepts up to 1000 characters per call, so a long reply is
  /// split on sentence boundaries and the audio concatenated.
  static List<String> _segments(String text, {int limit = 900}) {
    if (text.length <= limit) return [text];
    final segments = <String>[];
    final buffer = StringBuffer();
    for (final sentence in text.split(RegExp(r'(?<=[。！？!?\n])'))) {
      if (buffer.length + sentence.length > limit && buffer.isNotEmpty) {
        segments.add(buffer.toString());
        buffer.clear();
      }
      if (sentence.length > limit) {
        for (var start = 0; start < sentence.length; start += limit) {
          final end = start + limit;
          segments.add(
            sentence.substring(
              start,
              end > sentence.length ? sentence.length : end,
            ),
          );
        }
        continue;
      }
      buffer.write(sentence);
    }
    if (buffer.isNotEmpty) segments.add(buffer.toString());
    return segments;
  }

  /// Markdown is for the eye. Read aloud, `**` and `##` become noise, so the
  /// syntax is removed before synthesis while the words are kept.
  static String _stripMarkdown(String text) {
    var spoken = text;
    spoken = spoken.replaceAll(RegExp(r'```[\s\S]*?```'), ' 代码块 ');
    spoken = spoken.replaceAll(RegExp(r'`([^`]*)`'), r'$1');
    spoken = spoken.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    spoken = spoken.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\([^)]*\)'),
      (match) => match.group(1) ?? '',
    );
    spoken = spoken.replaceAll(
      RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true),
      '',
    );
    spoken = spoken.replaceAll(RegExp(r'^\s{0,3}>\s?', multiLine: true), '');
    spoken = spoken.replaceAll(
      RegExp(r'^\s{0,3}[-*+]\s+', multiLine: true),
      '',
    );
    spoken = spoken.replaceAll(RegExp(r'\*\*|__|~~|\*|_'), '');
    spoken = spoken.replaceAll(RegExp(r'\n{2,}'), '\n');
    return spoken.trim();
  }
}

/// Volcano Engine speech-to-text for recorded voice messages.
///
/// Shape taken from the owner's working project, not from documentation
/// guesses: the flash endpoint answers in one shot, success is declared by the
/// `x-api-status-code` response header rather than the HTTP status, and the
/// audio travels as base64 in the body.
final class VolcanoSpeechTranscriber implements SpeechTranscriber {
  VolcanoSpeechTranscriber({
    required VolcanoSpeechConfig config,
    required String Function() newRequestId,
    HttpClient? httpClient,
    Uri? endpointOverride,
  }) : _config = config,
       _newRequestId = newRequestId,
       _client = httpClient ?? HttpClient(),
       _endpoint = endpointOverride ?? VolcanoSpeechConfig.asrFlashEndpoint;

  final VolcanoSpeechConfig _config;
  final String Function() _newRequestId;
  final HttpClient _client;
  final Uri _endpoint;

  static const _successStatus = '20000000';

  @override
  Future<String> transcribe(String sourcePath) async {
    final file = File(sourcePath);
    if (!file.existsSync()) {
      throw const SpeechException('录音文件不存在');
    }
    try {
      final request = await _client.postUrl(_endpoint);
      request.headers
        ..set('Content-Type', 'application/json')
        ..set('X-Api-Key', _config.apiKey)
        ..set('X-Api-Resource-Id', _config.asrResourceId)
        ..set('X-Api-Request-Id', _newRequestId())
        // The flash endpoint requires the terminal sequence marker.
        ..set('X-Api-Sequence', '-1');
      request.add(
        utf8.encode(
          jsonEncode({
            'user': {'uid': 'halo'},
            'audio': {'data': base64Encode(await file.readAsBytes())},
            'request': {
              'model_name': 'bigmodel',
              'enable_punc': true,
              'enable_itn': true,
            },
          }),
        ),
      );
      final response = await request.close();
      // Success is declared in this header, not the HTTP status: the service
      // answers 200 for rejected requests too.
      final status = response.headers.value('x-api-status-code');
      final body = await utf8.decodeStream(response);
      if (status != _successStatus) {
        throw const SpeechException('转写失败，请重试');
      }
      final decoded = jsonDecode(body);
      final text = decoded is Map && decoded['result'] is Map
          ? (decoded['result'] as Map)['text']
          : null;
      final transcript = text is String ? text.trim() : '';
      if (transcript.isEmpty) {
        throw const SpeechException('没有听清，请再说一次');
      }
      return transcript;
    } on SpeechException {
      rethrow;
    } catch (_) {
      throw const SpeechException('转写失败，请重试');
    }
  }
}
