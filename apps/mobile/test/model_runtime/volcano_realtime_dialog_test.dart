@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/volcano_realtime_dialog.dart';

/// Contract test against the frame layout proven in the owner's own project.
void main() {
  late HttpServer server;
  late List<Uint8List> received;
  late WebSocket serverSocket;
  late Completer<void> connected;

  Uint8List frame({
    required int event,
    String? sessionId,
    Object? payload,
    List<int>? rawPayload,
  }) {
    final body =
        rawPayload ?? utf8.encode(jsonEncode(payload ?? <String, Object?>{}));
    final builder = BytesBuilder()
      ..add([0x11, 0x14, 0x10, 0x00])
      ..add(Uint8List(4)..buffer.asByteData().setInt32(0, event));
    if (sessionId != null) {
      final id = utf8.encode(sessionId);
      builder
        ..add(Uint8List(4)..buffer.asByteData().setUint32(0, id.length))
        ..add(id);
    }
    builder
      ..add(Uint8List(4)..buffer.asByteData().setUint32(0, body.length))
      ..add(body);
    return builder.takeBytes();
  }

  setUp(() async {
    received = [];
    connected = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in server) {
        serverSocket = await WebSocketTransformer.upgrade(request);
        connected.complete();
        // Counted separately from `received`, which tests are free to clear.
        var handshake = 0;
        serverSocket.listen((data) {
          received.add(Uint8List.fromList(data as List<int>));
          handshake += 1;
          if (handshake == 1) {
            serverSocket.add(frame(event: 50, sessionId: 'server'));
          } else if (handshake == 2) {
            serverSocket.add(frame(event: 150, sessionId: 'server'));
          }
        });
      }
    }());
  });

  tearDown(() => server.close(force: true));

  VolcanoRealtimeDialog dialog() {
    var ids = 0;
    return VolcanoRealtimeDialog(
      apiKey: 'test-key-never-real',
      newId: () => 'id-${++ids}',
      connect: (_, {headers}) =>
          WebSocket.connect('ws://127.0.0.1:${server.port}', headers: headers),
    );
  }

  test('the expert persona is what starts the session', () async {
    final call = dialog();
    addTearDown(call.stop);

    await call.start(systemRole: '你是产品经理，只谈范围、优先级和风险。', botName: '产品经理');

    // Frame 2 is StartSession: it must carry this expert's persona, or every
    // expert would answer as the vendor's default assistant.
    final start = jsonDecode(utf8.decode(_payloadOf(received[1]))) as Map;
    final config = start['dialog']! as Map;
    expect(config['system_role'], '你是产品经理，只谈范围、优先级和风险。');
    expect(config['bot_name'], '产品经理');
    expect(((start['tts']! as Map)['audio_config']! as Map)['format'], 'mp3');
  });

  test('speech, reply text and reply audio all reach the caller', () async {
    final call = dialog();
    addTearDown(call.stop);
    final events = await call.start(systemRole: '你是助理。', botName: '助理');
    final seen = <RealtimeDialogEvent>[];
    final sub = events.listen(seen.add);
    addTearDown(sub.cancel);

    serverSocket
      ..add(frame(event: 450, sessionId: 's'))
      ..add(frame(event: 451, sessionId: 's', payload: {'text': '你好'}))
      ..add(frame(event: 550, sessionId: 's', payload: {'content': '在的'}))
      ..add(frame(event: 352, sessionId: 's', rawPayload: [1, 2, 3]))
      ..add(frame(event: 359, sessionId: 's'));
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(seen.whereType<RealtimeUserSpeaking>(), hasLength(1));
    expect(seen.whereType<RealtimeUserText>().single.text, '你好');
    expect(seen.whereType<RealtimeReplyText>().single.text, '在的');
    expect(seen.whereType<RealtimeReplyAudio>().single.bytes, [1, 2, 3]);
    expect(seen.whereType<RealtimeReplyEnded>(), hasLength(1));
  });

  test('microphone audio goes up as an audio frame', () async {
    final call = dialog();
    addTearDown(call.stop);
    await call.start(systemRole: '你是助理。', botName: '助理');
    received.clear();

    call.sendAudio(Uint8List.fromList([7, 8, 9]));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(received, isNotEmpty);
    final sent = received.last;
    // Audio-only request framing, event 200, raw payload.
    expect(sent[1], 0x24);
    expect(sent.buffer.asByteData(sent.offsetInBytes).getInt32(4), 200);
    expect(_payloadOf(sent), [7, 8, 9]);
  });

  test('a refused connection reports a safe message', () async {
    final call = VolcanoRealtimeDialog(
      apiKey: 'test-key-never-real',
      newId: () => 'id',
      connect: (_, {headers}) async => throw const SocketException('refused'),
    );

    await expectLater(
      call.start(systemRole: '你是助理。', botName: '助理'),
      throwsA(
        isA<RealtimeDialogException>().having(
          (error) => error.safeMessage,
          'safeMessage',
          '网络不可用，无法接通通话',
        ),
      ),
    );
  });
}

/// Reads the payload out of a frame, skipping header, event and session id.
Uint8List _payloadOf(Uint8List buffer) {
  final data = buffer.buffer.asByteData(buffer.offsetInBytes);
  var offset = (buffer[0] & 0x0f) * 4;
  final event = data.getInt32(offset);
  offset += 4;
  if (event >= 50) {
    offset += 4 + data.getUint32(offset);
  }
  final length = data.getUint32(offset);
  offset += 4;
  return Uint8List.sublistView(buffer, offset, offset + length);
}
