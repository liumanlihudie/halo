@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/volcano_speech.dart';

/// Contract test against the response shape the owner's working project
/// produces: chunked JSON lines whose `data` fields are base64 audio.
void main() {
  late HttpServer server;
  late List<Map<String, Object?>> bodies;
  late List<HttpHeaders> headers;
  late List<String> frames;
  late int status;
  late Directory directory;

  setUp(() async {
    bodies = [];
    headers = [];
    status = 200;
    frames = [
      jsonEncode({
        'data': base64Encode([1, 2, 3]),
      }),
      jsonEncode({
        'data': base64Encode([4, 5]),
      }),
    ];
    directory = await Directory.systemTemp.createTemp('halo-tts-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in server) {
        headers.add(request.headers);
        bodies.add(
          jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>,
        );
        request.response.statusCode = status;
        if (status == 200) {
          for (final frame in frames) {
            request.response.add(utf8.encode('$frame\n'));
          }
        }
        await request.response.close();
      }
    }());
  });

  tearDown(() async {
    await server.close(force: true);
    directory.deleteSync(recursive: true);
  });

  VolcanoSpeechSynthesizer synthesizer() => VolcanoSpeechSynthesizer(
    config: const VolcanoSpeechConfig(apiKey: 'test-key-never-real'),
    newRequestId: () => 'request-1',
    endpointOverride: Uri.parse('http://127.0.0.1:${server.port}/tts'),
  );

  test('concatenates base64 fragments into one audio file', () async {
    final path = '${directory.path}/reply.mp3';

    await synthesizer().synthesize(text: '你好', targetPath: path);

    expect(File(path).readAsBytesSync(), [1, 2, 3, 4, 5]);
    final sent = bodies.single['req_params']! as Map<String, Object?>;
    expect(sent['text'], '你好');
    expect(sent['speaker'], 'zh_female_vv_uranus_bigtts');
    expect((sent['audio_params']! as Map)['format'], 'mp3');
    expect((sent['audio_params']! as Map)['sample_rate'], 24000);
    expect((sent['additions']! as Map)['silence_duration'], 800);
    expect(headers.single.value('X-Api-Key'), 'test-key-never-real');
    expect(headers.single.value('X-Api-Resource-Id'), 'seed-tts-2.0');
    expect(headers.single.value('X-Api-Request-Id'), 'request-1');
  });

  test('markdown is spoken as words, not as syntax', () async {
    await synthesizer().synthesize(
      text: '## 结论\n\n- **第一点**\n- `代码`\n[链接](https://example.com)',
      targetPath: '${directory.path}/markdown.mp3',
    );

    final text = (bodies.single['req_params']! as Map)['text']! as String;
    expect(text, isNot(contains('#')));
    expect(text, isNot(contains('**')));
    expect(text, isNot(contains('](')));
    expect(text, contains('结论'));
    expect(text, contains('第一点'));
    expect(text, contains('链接'));
  });

  test('a long reply is split on sentence boundaries and rejoined', () async {
    final long = '${'这是一句话。' * 200}结束。';

    await synthesizer().synthesize(
      text: long,
      targetPath: '${directory.path}/long.mp3',
    );

    expect(bodies.length, greaterThan(1));
    for (final body in bodies) {
      final text = (body['req_params']! as Map)['text']! as String;
      expect(text.length, lessThanOrEqualTo(1000));
    }
    // Every character survives the split.
    final rejoined = bodies
        .map((body) => (body['req_params']! as Map)['text']! as String)
        .join();
    expect(rejoined, long);
  });

  test('an upstream failure never leaks its body', () async {
    status = 500;

    await expectLater(
      synthesizer().synthesize(
        text: '你好',
        targetPath: '${directory.path}/failed.mp3',
      ),
      throwsA(
        isA<SpeechException>().having(
          (error) => error.safeMessage,
          'safeMessage',
          '语音合成失败，请重试',
        ),
      ),
    );
  });

  test('one broken frame does not destroy the audio around it', () async {
    frames = [
      jsonEncode({
        'data': base64Encode([1, 2]),
      }),
      '{not json',
      jsonEncode({
        'data': base64Encode([3]),
      }),
    ];
    final path = '${directory.path}/partial.mp3';

    await synthesizer().synthesize(text: '你好', targetPath: path);

    expect(File(path).readAsBytesSync(), [1, 2, 3]);
  });

  group('transcription', () {
    late HttpServer asrServer;
    late String statusHeader;
    late Map<String, Object?> reply;
    late List<Map<String, Object?>> asrBodies;
    late List<HttpHeaders> asrHeaders;

    setUp(() async {
      statusHeader = '20000000';
      asrBodies = [];
      asrHeaders = [];
      reply = {
        'result': {'text': '这是我说的话'},
      };
      asrServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(() async {
        await for (final request in asrServer) {
          asrHeaders.add(request.headers);
          asrBodies.add(
            jsonDecode(await utf8.decodeStream(request))
                as Map<String, Object?>,
          );
          request.response.headers.set('x-api-status-code', statusHeader);
          request.response.add(utf8.encode(jsonEncode(reply)));
          await request.response.close();
        }
      }());
    });

    tearDown(() => asrServer.close(force: true));

    VolcanoSpeechTranscriber transcriber() => VolcanoSpeechTranscriber(
      config: const VolcanoSpeechConfig(apiKey: 'test-key-never-real'),
      newRequestId: () => 'asr-1',
      endpointOverride: Uri.parse(
        'http://127.0.0.1:${asrServer.port}/recognize/flash',
      ),
    );

    test('sends the recording and returns the transcript', () async {
      final recording = File('${directory.path}/note.m4a')
        ..writeAsBytesSync([9, 9, 9]);

      final text = await transcriber().transcribe(recording.path);

      expect(text, '这是我说的话');
      final sent = asrBodies.single;
      expect((sent['audio']! as Map)['data'], base64Encode([9, 9, 9]));
      expect((sent['request']! as Map)['model_name'], 'bigmodel');
      expect((sent['request']! as Map)['enable_punc'], isTrue);
      expect(
        asrHeaders.single.value('X-Api-Resource-Id'),
        'volc.bigasr.auc_turbo',
      );
      // The flash endpoint refuses a request without the terminal marker.
      expect(asrHeaders.single.value('X-Api-Sequence'), '-1');
    });

    test('a rejected request is a failure even when HTTP says 200', () async {
      statusHeader = '45000001';
      final recording = File('${directory.path}/bad.m4a')
        ..writeAsBytesSync([1]);

      await expectLater(
        transcriber().transcribe(recording.path),
        throwsA(
          isA<SpeechException>().having(
            (error) => error.safeMessage,
            'safeMessage',
            '转写失败，请重试',
          ),
        ),
      );
    });

    test('silence is reported as not heard, not as a failure', () async {
      reply = {
        'result': {'text': '   '},
      };
      final recording = File('${directory.path}/quiet.m4a')
        ..writeAsBytesSync([1]);

      await expectLater(
        transcriber().transcribe(recording.path),
        throwsA(
          isA<SpeechException>().having(
            (error) => error.safeMessage,
            'safeMessage',
            '没有听清，请再说一次',
          ),
        ),
      );
    });

    test('a missing recording is reported, not silently empty', () async {
      await expectLater(
        transcriber().transcribe('${directory.path}/gone.m4a'),
        throwsA(
          isA<SpeechException>().having(
            (error) => error.safeMessage,
            'safeMessage',
            '录音文件不存在',
          ),
        ),
      );
    });
  });
}
