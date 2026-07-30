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
    this.asrResourceId = 'volc.bigasr.auc',
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
  static final Uri asrSubmitEndpoint = Uri.parse(
    'https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit',
  );
  static final Uri asrQueryEndpoint = Uri.parse(
    'https://openspeech.bytedance.com/api/v3/auc/bigmodel/query',
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
/// The recording-file API is submit-then-poll: one request hands over the
/// audio, and the transcript is collected by querying the same request id.
final class VolcanoSpeechTranscriber implements SpeechTranscriber {
  VolcanoSpeechTranscriber({
    required VolcanoSpeechConfig config,
    required String Function() newRequestId,
    HttpClient? httpClient,
    Uri? submitEndpointOverride,
    Uri? queryEndpointOverride,
    Duration pollInterval = const Duration(milliseconds: 700),
    int maximumPolls = 40,
  }) : _config = config,
       _newRequestId = newRequestId,
       _client = httpClient ?? HttpClient(),
       _submitEndpoint =
           submitEndpointOverride ?? VolcanoSpeechConfig.asrSubmitEndpoint,
       _queryEndpoint =
           queryEndpointOverride ?? VolcanoSpeechConfig.asrQueryEndpoint,
       _pollInterval = pollInterval,
       _maximumPolls = maximumPolls;

  final VolcanoSpeechConfig _config;
  final String Function() _newRequestId;
  final HttpClient _client;
  final Uri _submitEndpoint;
  final Uri _queryEndpoint;
  final Duration _pollInterval;
  final int _maximumPolls;

  @override
  Future<String> transcribe(String sourcePath) async {
    final file = File(sourcePath);
    if (!file.existsSync()) {
      throw const SpeechException('录音文件不存在');
    }
    final requestId = _newRequestId();
    try {
      await _submit(requestId, await file.readAsBytes());
      for (var attempt = 0; attempt < _maximumPolls; attempt += 1) {
        await Future<void>.delayed(_pollInterval);
        final transcript = await _query(requestId);
        if (transcript != null) return transcript;
      }
      throw const SpeechException('转写超时，请重试');
    } on SpeechException {
      rethrow;
    } catch (_) {
      throw const SpeechException('转写失败，请重试');
    }
  }

  Future<void> _submit(String requestId, List<int> audio) async {
    final request = await _client.postUrl(_submitEndpoint);
    request.headers
      ..set('Content-Type', 'application/json')
      ..set('X-Api-Key', _config.apiKey)
      ..set('X-Api-Resource-Id', _config.asrResourceId)
      ..set('X-Api-Request-Id', requestId);
    request.add(
      utf8.encode(
        jsonEncode({
          'audio': {'format': 'm4a', 'data': base64Encode(audio)},
          'request': {'model_name': 'bigmodel'},
        }),
      ),
    );
    final response = await request.close();
    final ok = response.statusCode == HttpStatus.ok;
    await response.drain<void>();
    if (!ok) throw const SpeechException('转写失败，请重试');
  }

  /// Returns the transcript once the job is done, or null while it is still
  /// running. A failed job is reported rather than polled forever.
  Future<String?> _query(String requestId) async {
    final request = await _client.postUrl(_queryEndpoint);
    request.headers
      ..set('Content-Type', 'application/json')
      ..set('X-Api-Key', _config.apiKey)
      ..set('X-Api-Resource-Id', _config.asrResourceId)
      ..set('X-Api-Request-Id', requestId);
    request.add(utf8.encode('{}'));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw const SpeechException('转写失败，请重试');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await utf8.decodeStream(response));
    } catch (_) {
      throw const SpeechException('转写失败，请重试');
    }
    if (decoded is! Map) throw const SpeechException('转写失败，请重试');
    final result = decoded['result'];
    if (result is Map) {
      final text = result['text'];
      if (text is String && text.trim().isNotEmpty) return text.trim();
    }
    final error = decoded['error'];
    if (error != null) throw const SpeechException('转写失败，请重试');
    return null;
  }
}
