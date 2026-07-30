@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/single_chat/attachments/voice_recorder_service.dart';

void main() {
  late Directory directory;
  late _FakeRecorder recorder;
  late DateTime clock;

  VoiceRecorderService service({
    Duration maximumDuration = const Duration(seconds: 60),
  }) => VoiceRecorderService(
    recorder: recorder,
    attachmentsDirectory: () async => directory,
    newRecordingId: () => 'voice-1',
    maximumDuration: maximumDuration,
    now: () => clock,
  );

  setUp(() async {
    clock = DateTime.utc(2026, 7, 30, 12);
    directory = await Directory.systemTemp.createTemp('halo-voice-');
    recorder = _FakeRecorder();
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('a finished recording reports its file and duration', () async {
    final subject = service();

    await subject.start();
    expect(subject.isRecording, isTrue);
    clock = clock.add(const Duration(seconds: 7));

    final recording = await subject.stop();

    expect(recording, isNotNull);
    expect(recording!.duration, const Duration(seconds: 7));
    expect(File(recording.path).existsSync(), isTrue);
    expect(recording.path, endsWith('.m4a'));
    expect(subject.isRecording, isFalse);
  });

  test('cancelling leaves nothing on disk', () async {
    final subject = service();
    await subject.start();
    final path = recorder.startedPath!;

    await subject.cancel();

    expect(File(path).existsSync(), isFalse);
    expect(subject.isRecording, isFalse);
  });

  test('a recording longer than the cap is reported at the cap', () async {
    final subject = service(maximumDuration: const Duration(seconds: 5));
    await subject.start();
    clock = clock.add(const Duration(seconds: 9));

    final recording = await subject.stop();

    expect(recording!.duration, const Duration(seconds: 5));
  });

  test('an empty capture is not passed off as a message', () async {
    recorder.writeBytes = false;
    final subject = service();
    await subject.start();

    expect(await subject.stop(), isNull);
  });

  test('a refused microphone says so instead of failing silently', () async {
    recorder.permitted = false;
    final subject = service();

    await expectLater(
      subject.start(),
      throwsA(
        isA<VoiceRecorderException>().having(
          (error) => error.safeMessage,
          'safeMessage',
          '需要麦克风权限才能发送语音',
        ),
      ),
    );
    expect(subject.isRecording, isFalse);
  });
}

final class _FakeRecorder implements VoiceRecorderBackend {
  bool permitted = true;
  bool writeBytes = true;
  String? startedPath;

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<void> start(String path) async {
    startedPath = path;
    if (writeBytes) File(path).writeAsBytesSync([1, 2, 3]);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
