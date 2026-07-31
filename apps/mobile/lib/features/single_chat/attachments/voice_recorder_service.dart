// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// A finished recording: where it lives and how long it runs.
final class VoiceRecording {
  const VoiceRecording({required this.path, required this.duration});

  final String path;
  final Duration duration;
}

final class VoiceRecorderException implements Exception {
  const VoiceRecorderException(this.safeMessage);

  final String safeMessage;

  @override
  String toString() => 'VoiceRecorderException($safeMessage)';
}

/// The narrow slice of a recorder this service needs.
///
/// Declaring it here keeps the plugin at arm's length: tests drive the whole
/// duration cap, cancel cleanup and permission path without a microphone.
abstract interface class VoiceRecorderBackend {
  Future<bool> hasPermission();

  Future<void> start(String path);

  Future<void> stop();

  Future<void> dispose();
}

/// [VoiceRecorderBackend] backed by the `record` package.
final class PluginVoiceRecorderBackend implements VoiceRecorderBackend {
  PluginVoiceRecorderBackend({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  static const _audio = MethodChannel('halo.speech/on_device');

  @override
  Future<void> start(String path) async {
    // A finished call can leave the audio session in a state this recorder
    // cannot open; reclaiming it first is what makes the next voice message
    // work without restarting the app.
    try {
      await _audio.invokeMethod<bool>('prepareRecording');
    } catch (_) {
      // The recorder may still succeed on its own.
    }
    return _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
  }

  @override
  Future<void> stop() => _recorder.stop();

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Records a voice message into the app sandbox.
///
/// The recorder and the clock are injectable so the duration cap, cancel
/// cleanup and permission refusal are all testable without a microphone.
final class VoiceRecorderService {
  VoiceRecorderService({
    VoiceRecorderBackend? recorder,
    Future<Directory> Function()? attachmentsDirectory,
    String Function()? newRecordingId,
    Duration maximumDuration = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _recorder = recorder ?? PluginVoiceRecorderBackend(),
       _attachmentsDirectory =
           attachmentsDirectory ?? _defaultAttachmentsDirectory,
       _newRecordingId = newRecordingId ?? _defaultRecordingId,
       maximumDuration = maximumDuration,
       _now = now ?? DateTime.now;

  final VoiceRecorderBackend _recorder;
  final Future<Directory> Function() _attachmentsDirectory;
  final String Function() _newRecordingId;
  final DateTime Function() _now;

  /// WeChat-style ceiling: a voice message is a message, not a broadcast.
  final Duration maximumDuration;

  DateTime? _startedAt;
  String? _path;
  Timer? _cap;

  bool get isRecording => _startedAt != null;

  /// Elapsed time of the recording in progress, or zero when idle.
  Duration get elapsed {
    final started = _startedAt;
    return started == null ? Duration.zero : _now().difference(started);
  }

  Future<void> start() async {
    if (isRecording) return;
    final permitted = await _recorder.hasPermission();
    if (!permitted) {
      throw const VoiceRecorderException('需要麦克风权限才能发送语音');
    }
    final directory = await _attachmentsDirectory();
    await directory.create(recursive: true);
    final path = '${directory.path}/${_newRecordingId()}.m4a';
    try {
      await _recorder.start(path);
    } catch (_) {
      throw const VoiceRecorderException('无法开始录音，请重试');
    }
    _path = path;
    _startedAt = _now();
    // The cap stops the recorder itself: a run-away recording must not depend
    // on the UI still being alive to end it.
    _cap = Timer(maximumDuration, () => unawaited(_stopRecorder()));
  }

  /// Ends the recording and returns it, or null when nothing was captured.
  Future<VoiceRecording?> stop() async {
    if (!isRecording) return null;
    final started = _startedAt!;
    final duration = _now().difference(started);
    final path = await _stopRecorder();
    if (path == null) return null;
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() == 0) {
      await _delete(path);
      return null;
    }
    return VoiceRecording(
      path: path,
      duration: duration > maximumDuration ? maximumDuration : duration,
    );
  }

  /// Aborts the recording and leaves nothing behind on disk.
  Future<void> cancel() async {
    if (!isRecording) return;
    final path = await _stopRecorder();
    if (path != null) await _delete(path);
  }

  Future<String?> _stopRecorder() async {
    _cap?.cancel();
    _cap = null;
    final path = _path;
    _path = null;
    _startedAt = null;
    if (path == null) return null;
    try {
      await _recorder.stop();
    } catch (_) {
      // A recorder that fails to stop cleanly still leaves its file behind;
      // the caller decides what to do with it.
    }
    return path;
  }

  Future<void> _delete(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // Cleanup is best effort: a stranded temp file must never surface as a
      // send failure.
    }
  }

  Future<void> dispose() async {
    _cap?.cancel();
    await _recorder.dispose();
  }

  static Future<Directory> _defaultAttachmentsDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/attachments');

  static String _defaultRecordingId() =>
      'voice-${DateTime.now().microsecondsSinceEpoch}';
}
