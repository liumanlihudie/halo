import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
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
  final _played = <File>[];
  Timer? _flush;
  bool _draining = false;
  static const _audio = MethodChannel('halo.speech/on_device');

  /// Routes call audio to the loudspeaker or the earpiece.
  ///
  /// The recording session defaults to the receiver, so without this a call
  /// is barely audible and sounds like nothing is happening.
  /// Follows the proximity sensor: at the ear the earpiece, away from it the
  /// loudspeaker — the behaviour every phone call has.
  static Future<void> followProximity(bool enabled) async {
    try {
      await _audio.invokeMethod<bool>('setProximityRouting', {
        'enabled': enabled,
      });
    } catch (_) {
      // Routing stays wherever it is; a call still works.
    }
  }

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

  /// Buffers a reply, then plays it as one file.
  ///
  /// Chunks arrive every few tens of milliseconds. Starting and finishing a
  /// player that often left gaps and, on device, silence. Audio is collected
  /// and flushed shortly after it stops arriving instead.
  @override
  Future<void> play(Uint8List audio) async {
    _queue.add(audio);
    _flush?.cancel();
    _flush = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_drain()),
    );
  }

  Future<void> _drain() async {
    if (_queue.isEmpty || _draining) return;
    _draining = true;
    final pcm = BytesBuilder(copy: false);
    for (final chunk in _queue) {
      pcm.add(chunk);
    }
    _queue.clear();
    try {
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}/halo-call-'
        '${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      await file.writeAsBytes(_wav(pcm.takeBytes()), flush: true);
      await _player.play(DeviceFileSource(file.path));
      _played.add(file);
      // A long call must not fill the sandbox with spent audio.
      while (_played.length > 8) {
        final stale = _played.removeAt(0);
        if (stale.existsSync()) await stale.delete();
      }
    } catch (_) {
      // Audio that will not play is dropped rather than ending the call.
    } finally {
      _draining = false;
      if (_queue.isNotEmpty) unawaited(_drain());
    }
  }

  @override
  Future<void> stop() async {
    _flush?.cancel();
    _queue.clear();
    try {
      await _player.stop();
    } catch (_) {
      // Already stopped.
    }
  }
}
