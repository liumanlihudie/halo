import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
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
  static const _audio = MethodChannel('halo.speech/on_device');

  /// Routes call audio to the loudspeaker or the earpiece.
  ///
  /// The recording session defaults to the receiver, so without this a call
  /// is barely audible and sounds like nothing is happening.
  static Future<void> useSpeaker(bool speaker) async {
    try {
      await _audio.invokeMethod<bool>('setAudioRoute', {'speaker': speaker});
    } catch (_) {
      // Routing is a comfort setting; a call still works on the default route.
    }
  }

  /// Reply audio arrives as raw 16-bit PCM, which no player accepts on its
  /// own, so each chunk is given a WAV header before playback.
  static Uint8List _wav(Uint8List pcm, {int sampleRate = 24000}) {
    final header = ByteData(44);
    void ascii(int offset, String value) {
      for (var i = 0; i < value.length; i += 1) {
        header.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + pcm.length, Endian.little);
    ascii(8, 'WAVEfmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, pcm.length, Endian.little);
    return Uint8List.fromList([...header.buffer.asUint8List(), ...pcm]);
  }

  @override
  Future<void> play(Uint8List audio) async {
    _queue.add(_wav(audio));
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
