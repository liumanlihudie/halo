@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/media/voice_call_controller.dart';
import 'package:halo_mobile/model_runtime/volcano_realtime_dialog.dart';

/// A call has to keep the expert's identity, stay readable, and go quiet the
/// moment the user cuts in.
void main() {
  late HttpServer server;
  late WebSocket serverSocket;
  late List<Uint8List> received;
  late _FakeMicrophone microphone;
  late _FakeSpeaker speaker;

  Uint8List frame({
    required int event,
    Object? payload,
    List<int>? rawPayload,
  }) {
    final body =
        rawPayload ?? utf8.encode(jsonEncode(payload ?? <String, Object?>{}));
    final id = utf8.encode('server');
    return (BytesBuilder()
          ..add([0x11, 0x14, 0x10, 0x00])
          ..add(Uint8List(4)..buffer.asByteData().setInt32(0, event))
          ..add(Uint8List(4)..buffer.asByteData().setUint32(0, id.length))
          ..add(id)
          ..add(Uint8List(4)..buffer.asByteData().setUint32(0, body.length))
          ..add(body))
        .takeBytes();
  }

  setUp(() async {
    received = [];
    microphone = _FakeMicrophone();
    speaker = _FakeSpeaker();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in server) {
        serverSocket = await WebSocketTransformer.upgrade(request);
        var handshake = 0;
        serverSocket.listen((data) {
          received.add(Uint8List.fromList(data as List<int>));
          handshake += 1;
          if (handshake == 1) {
            serverSocket.add(frame(event: 50));
          } else if (handshake == 2) {
            serverSocket.add(frame(event: 150));
          }
        });
      }
    }());
  });

  tearDown(() => server.close(force: true));

  VoiceCallController controller() {
    var ids = 0;
    return VoiceCallController(
      openDialog: () async => VolcanoRealtimeDialog(
        apiKey: 'test-key-never-real',
        newId: () => 'id-${++ids}',
        connect: (_, {headers}) => WebSocket.connect(
          'ws://127.0.0.1:${server.port}',
          headers: headers,
        ),
      ),
      microphone: microphone,
      speaker: speaker,
    );
  }

  test('a connected call carries the persona and streams the mic', () async {
    final call = controller();
    addTearDown(call.dispose);

    await call.start(systemRole: '你是产品经理。', botName: '产品经理');

    expect(call.status, VoiceCallStatus.listening);
    microphone.emit(Uint8List.fromList([1, 2]));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    // Handshake, StartSession, then the microphone chunk.
    expect(received, hasLength(3));
  });

  test('the user cutting in silences the expert at once', () async {
    final call = controller();
    addTearDown(call.dispose);
    await call.start(systemRole: '你是助理。', botName: '助理');

    serverSocket
      ..add(frame(event: 550, payload: {'content': '我正在说'}))
      ..add(frame(event: 352, rawPayload: [9]));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(call.status, VoiceCallStatus.speaking);
    expect(speaker.played, hasLength(1));

    serverSocket.add(frame(event: 450));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(speaker.stops, greaterThan(0));
    expect(call.status, VoiceCallStatus.listening);
  });

  test('both sides of the call are readable as text', () async {
    final call = controller();
    addTearDown(call.dispose);
    await call.start(systemRole: '你是助理。', botName: '助理');

    serverSocket
      ..add(frame(event: 451, payload: {'text': '你好'}))
      ..add(frame(event: 550, payload: {'content': '在'}))
      ..add(frame(event: 550, payload: {'content': '的'}));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(call.heard, '你好');
    expect(call.reply, '在的');
  });

  test('a refused call reports why and leaves nothing running', () async {
    final call = VoiceCallController(
      openDialog: () async => VolcanoRealtimeDialog(
        apiKey: 'test-key-never-real',
        newId: () => 'id',
        connect: (_, {headers}) async => throw const SocketException('refused'),
      ),
      microphone: microphone,
      speaker: speaker,
    );
    addTearDown(call.dispose);

    await call.start(systemRole: '你是助理。', botName: '助理');

    expect(call.status, VoiceCallStatus.failed);
    expect(call.failure, '网络不可用，无法接通通话');
    expect(microphone.started, isFalse);
  });

  test('an unconfigured key says so instead of dialling nothing', () async {
    final call = VoiceCallController(
      openDialog: () async => null,
      microphone: microphone,
      speaker: speaker,
    );
    addTearDown(call.dispose);

    await call.start(systemRole: '你是助理。', botName: '助理');

    expect(call.status, VoiceCallStatus.failed);
    expect(call.failure, '尚未配置语音服务');
  });
}

final class _FakeMicrophone implements CallMicrophone {
  final _controller = StreamController<Uint8List>.broadcast();
  bool started = false;

  void emit(Uint8List chunk) => _controller.add(chunk);

  @override
  Future<Stream<Uint8List>> start() async {
    started = true;
    return _controller.stream;
  }

  @override
  Future<void> stop() async {}
}

final class _FakeSpeaker implements CallSpeaker {
  final played = <Uint8List>[];
  int stops = 0;

  @override
  Future<void> play(Uint8List audio) async => played.add(audio);

  @override
  Future<void> stop() async => stops += 1;
}
