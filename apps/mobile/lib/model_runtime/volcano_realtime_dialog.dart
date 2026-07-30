// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What the caller hears and sees during a live audio call.
sealed class RealtimeDialogEvent {
  const RealtimeDialogEvent();
}

/// The user started speaking; whatever is playing must stop immediately so the
/// expert can be interrupted the way a person can.
final class RealtimeUserSpeaking extends RealtimeDialogEvent {
  const RealtimeUserSpeaking();
}

/// Recognised speech, including interim results.
final class RealtimeUserText extends RealtimeDialogEvent {
  const RealtimeUserText(this.text);

  final String text;
}

/// A fragment of the expert's reply text.
final class RealtimeReplyText extends RealtimeDialogEvent {
  const RealtimeReplyText(this.text);

  final String text;
}

/// A chunk of the expert's reply audio, ready to play.
final class RealtimeReplyAudio extends RealtimeDialogEvent {
  const RealtimeReplyAudio(this.bytes);

  final Uint8List bytes;
}

/// The expert finished its turn.
final class RealtimeReplyEnded extends RealtimeDialogEvent {
  const RealtimeReplyEnded();
}

final class RealtimeDialogFailed extends RealtimeDialogEvent {
  const RealtimeDialogFailed(this.safeMessage);

  final String safeMessage;
}

/// Volcano Engine end-to-end realtime dialogue (豆包 duplex voice).
///
/// One WebSocket carries the whole call: microphone PCM goes up, and
/// recognition text, reply text and reply audio come back down, with barge-in
/// decided by the service.
///
/// The expert's own persona is injected into `system_role` at session start.
/// Without that every expert would answer as the vendor's default assistant —
/// one voice and one personality for all of them.
///
/// Frame layout and event numbers are taken from the owner's working project,
/// not from documentation guesses.
final class VolcanoRealtimeDialog {
  VolcanoRealtimeDialog({
    required String apiKey,
    required String Function() newId,
    Future<WebSocket> Function(Uri, {Map<String, dynamic>? headers})? connect,
    int sampleRate = 24000,
  }) : _apiKey = apiKey,
       _newId = newId,
       _connect = connect ?? _defaultConnect,
       _sampleRate = sampleRate;

  final String _apiKey;
  final String Function() _newId;
  final Future<WebSocket> Function(Uri, {Map<String, dynamic>? headers})
  _connect;
  final int _sampleRate;

  static final Uri endpoint = Uri.parse(
    'wss://openspeech.bytedance.com/api/v3/realtime/dialogue',
  );

  /// Fixed app key the dialogue resource requires.
  static const appKey = 'PlgvMymc7f3tQnJ6';

  WebSocket? _socket;
  String? _sessionId;
  StreamController<RealtimeDialogEvent>? _events;

  bool get isActive => _socket != null && _sessionId != null;

  /// Opens a call. The returned stream carries everything the UI needs.
  Future<Stream<RealtimeDialogEvent>> start({
    required String systemRole,
    required String botName,
    String speakingStyle = '语气自然，回答简短，像正常对话一样。',
  }) async {
    if (isActive) throw StateError('A call is already running');
    final events = StreamController<RealtimeDialogEvent>.broadcast();
    final sessionId = _newId();
    final WebSocket socket;
    try {
      socket = await _connect(
        endpoint,
        headers: {
          'X-Api-Key': _apiKey,
          'X-Api-Resource-Id': 'volc.speech.dialog',
          'X-Api-App-Key': appKey,
          'X-Api-Connect-Id': _newId(),
        },
      );
    } on WebSocketException catch (_) {
      await events.close();
      // The handshake reached the service and was refused: the credential or
      // the resource is wrong, and retrying changes nothing.
      throw const RealtimeDialogException('语音通话被拒绝，请检查语音 Key');
    } on SocketException catch (_) {
      await events.close();
      throw const RealtimeDialogException('网络不可用，无法接通通话');
    } catch (_) {
      await events.close();
      throw const RealtimeDialogException('无法接通语音通话，请重试');
    }
    _socket = socket;
    _sessionId = sessionId;
    _events = events;

    final connected = Completer<void>();
    socket.listen(
      (frame) => _onFrame(
        frame,
        sessionId: sessionId,
        systemRole: systemRole,
        botName: botName,
        speakingStyle: speakingStyle,
        connected: connected,
      ),
      onError: (Object _) => _fail(connected, '语音通话出错，请重试'),
      onDone: () => _fail(connected, '语音通话已断开'),
      cancelOnError: true,
    );
    socket.add(_jsonFrame(event: 1, sessionId: null, payload: const {}));
    await connected.future;
    return events.stream;
  }

  /// Pushes one chunk of microphone audio (PCM s16le, mono).
  void sendAudio(Uint8List pcm) {
    final socket = _socket;
    final sessionId = _sessionId;
    if (socket == null || sessionId == null) return;
    socket.add(_audioFrame(sessionId, pcm));
  }

  Future<void> stop() async {
    final socket = _socket;
    final sessionId = _sessionId;
    _socket = null;
    _sessionId = null;
    if (socket != null && sessionId != null) {
      try {
        socket.add(_jsonFrame(event: 102, sessionId: sessionId, payload: {}));
      } catch (_) {
        // Best effort: the connection is torn down either way so the call goes
        // quiet immediately.
      }
      await socket.close();
    }
    await _events?.close();
    _events = null;
  }

  void _fail(Completer<void> connected, String message) {
    _events?.add(RealtimeDialogFailed(message));
    if (!connected.isCompleted) {
      connected.completeError(RealtimeDialogException(message));
    }
    unawaited(stop());
  }

  void _onFrame(
    Object frame, {
    required String sessionId,
    required String systemRole,
    required String botName,
    required String speakingStyle,
    required Completer<void> connected,
  }) {
    if (frame is! List<int>) return;
    final parsed = _parseFrame(Uint8List.fromList(frame));
    if (parsed == null) return;
    switch (parsed.event) {
      case 50:
        // Connection accepted: start the session carrying this expert's own
        // persona, so the caller is talking to that expert and not to the
        // vendor's default assistant.
        _socket?.add(
          _jsonFrame(
            event: 100,
            sessionId: sessionId,
            payload: {
              'dialog': {
                'bot_name': botName,
                'system_role': systemRole,
                'speaking_style': speakingStyle,
              },
              'asr': <String, Object?>{},
              'tts': {
                'audio_config': {
                  'channel': 1,
                  'format': 'mp3',
                  'sample_rate': _sampleRate,
                },
              },
            },
          ),
        );
      case 150:
        if (!connected.isCompleted) connected.complete();
      case 450:
        _events?.add(const RealtimeUserSpeaking());
      case 451:
        final text = _textOf(parsed.payload, ['text', 'result']);
        if (text != null) _events?.add(RealtimeUserText(text));
      case 550:
        final text = _textOf(parsed.payload, ['content', 'text']);
        if (text != null) _events?.add(RealtimeReplyText(text));
      case 352:
        if (parsed.payload.isNotEmpty) {
          _events?.add(RealtimeReplyAudio(parsed.payload));
        }
      case 359:
        _events?.add(const RealtimeReplyEnded());
      case 152 || 153:
        unawaited(stop());
    }
  }

  static String? _textOf(Uint8List payload, List<String> keys) {
    if (payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is! Map) return null;
      for (final key in keys) {
        final value = decoded[key];
        if (value is String && value.isNotEmpty) return value;
        if (value is List && value.isNotEmpty) {
          final first = value.first;
          if (first is Map && first['text'] is String) {
            return first['text'] as String;
          }
        }
      }
    } catch (_) {
      // A frame we cannot read is skipped rather than ending the call.
    }
    return null;
  }

  Uint8List _jsonFrame({
    required int event,
    required String? sessionId,
    required Map<String, Object?> payload,
  }) {
    final body = utf8.encode(jsonEncode(payload));
    final builder = BytesBuilder(copy: false)
      ..add(const [0x11, 0x14, 0x10, 0x00])
      ..add(_int32(event));
    if (sessionId != null) {
      final id = utf8.encode(sessionId);
      builder
        ..add(_uint32(id.length))
        ..add(id);
    }
    builder
      ..add(_uint32(body.length))
      ..add(body);
    return builder.takeBytes();
  }

  Uint8List _audioFrame(String sessionId, Uint8List pcm) {
    final id = utf8.encode(sessionId);
    return (BytesBuilder(copy: false)
          ..add(const [0x11, 0x24, 0x00, 0x00])
          ..add(_int32(200))
          ..add(_uint32(id.length))
          ..add(id)
          ..add(_uint32(pcm.length))
          ..add(pcm))
        .takeBytes();
  }

  static Uint8List _int32(int value) =>
      Uint8List(4)..buffer.asByteData().setInt32(0, value);

  static Uint8List _uint32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value);

  static _Frame? _parseFrame(Uint8List buffer) {
    if (buffer.length < 4) return null;
    final data = buffer.buffer.asByteData(buffer.offsetInBytes);
    final headerSize = (buffer[0] & 0x0f) * 4;
    final flags = buffer[1] & 0x0f;
    var offset = headerSize;
    int? event;
    if (flags & 0x04 != 0) {
      if (offset + 4 > buffer.length) return null;
      event = data.getInt32(offset);
      offset += 4;
    }
    if (event != null && event >= 50) {
      if (offset + 4 > buffer.length) return null;
      final idLength = data.getUint32(offset);
      offset += 4 + idLength;
    }
    if (offset + 4 > buffer.length) return null;
    final payloadLength = data.getUint32(offset);
    offset += 4;
    final end = offset + payloadLength;
    if (end > buffer.length) return null;
    return _Frame(event, Uint8List.sublistView(buffer, offset, end));
  }

  static Future<WebSocket> _defaultConnect(
    Uri uri, {
    Map<String, dynamic>? headers,
  }) => WebSocket.connect(uri.toString(), headers: headers);
}

final class _Frame {
  const _Frame(this.event, this.payload);

  final int? event;
  final Uint8List payload;
}

final class RealtimeDialogException implements Exception {
  const RealtimeDialogException(this.safeMessage);

  final String safeMessage;

  @override
  String toString() => 'RealtimeDialogException($safeMessage)';
}
