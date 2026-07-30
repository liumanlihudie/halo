import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:halo_mobile/features/media/voice_call_controller.dart';
import 'package:record/record.dart';

/// The device microphone, streaming the PCM shape the dialogue service wants.
final class DeviceCallMicrophone implements CallMicrophone {
  DeviceCallMicrophone({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<Stream<Uint8List>> start() async {
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission was refused');
    }
    // s16le mono at 16 kHz: the uplink format the realtime dialogue expects.
    return _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
  }

  @override
  Future<void> stop() async {
    try {
      await _recorder.stop();
    } catch (_) {
      // Hanging up must succeed even if the recorder is already gone.
    }
  }
}

/// Plays reply audio during a call.
///
/// Chunks are queued and played in order; [stop] drops the queue so the expert
/// falls silent the instant the user interrupts.
final class DeviceCallSpeaker implements CallSpeaker {
  DeviceCallSpeaker({AudioPlayer? player})
    : _player = player ?? AudioPlayer(playerId: 'halo-call');

  final AudioPlayer _player;
  final _queue = <Uint8List>[];
  bool _draining = false;

  @override
  Future<void> play(Uint8List audio) async {
    _queue.add(audio);
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final next = _queue.removeAt(0);
        await _player.play(BytesSource(next));
        await _player.onPlayerComplete.first;
      }
    } catch (_) {
      // A chunk that will not play is dropped rather than ending the call.
    } finally {
      _draining = false;
    }
  }

  @override
  Future<void> stop() async {
    _queue.clear();
    try {
      await _player.stop();
    } catch (_) {
      // Already stopped.
    }
  }
}
