import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/services.dart';
import 'package:halo_mobile/features/media/voice_call_controller.dart';
import 'package:record/record.dart';

/// Restarts a capture whose opening chunks are pure digital silence.
///
/// The first capture after app launch can bind to an input unit that the
/// voice-processing setup is still rebuilding; that capture delivers zeros
/// forever, the service never hears the caller, and the first call of every
/// launch is mute while the second works. A real microphone always carries a
/// noise floor, so a run of exactly-zero chunks at the head of the stream
/// means the capture is dead, not that the room is quiet — reopening it once
/// the session has settled brings the audio back.
Stream<Uint8List> restartSilentCapture({
  required Future<Stream<Uint8List>> Function() open,
  required Future<void> Function() close,
  int silentLeadLimit = 10,
  int maxRestarts = 2,
}) {
  final out = StreamController<Uint8List>();
  StreamSubscription<Uint8List>? sub;
  var restarts = 0;
  var closed = false;
  // Chunks still in flight from a capture that was already given up on must
  // not count against the fresh one, or a dead stream's tail could burn
  // through the restart budget before the new capture says a word.
  var generation = 0;

  bool isSilent(Uint8List bytes) {
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      var sample = bytes[i] | (bytes[i + 1] << 8);
      if (sample > 32767) sample -= 65536;
      // Allow converter dither; anything louder is a live microphone.
      if (sample.abs() > 8) return false;
    }
    return true;
  }

  Future<void> attach() async {
    final gen = ++generation;
    final source = await open();
    if (closed || gen != generation) return;
    var silentLead = 0;
    var heard = false;
    sub = source.listen(
      (bytes) {
        if (gen != generation) return; // a replaced capture's leftovers
        if (!heard) {
          if (isSilent(bytes)) {
            silentLead += 1;
            if (silentLead >= silentLeadLimit && restarts < maxRestarts) {
              restarts += 1;
              developer.log(
                'mic delivered only silence, restarting capture ($restarts)',
                name: 'halo.call',
              );
              generation += 1;
              final dead = sub;
              sub = null;
              unawaited(() async {
                await dead?.cancel();
                try {
                  await close();
                } catch (_) {
                  // The point is the reopen; a failed stop must not block it.
                }
                if (!closed) await attach();
              }());
              return;
            }
          } else {
            heard = true;
          }
        }
        // Silent chunks still go out: the uplink cadence must not gap.
        if (!out.isClosed) out.add(bytes);
      },
      onError: (Object error, StackTrace stack) {
        if (!out.isClosed) out.addError(error, stack);
      },
      onDone: () {
        // A capture that ends on its own ends the stream; a replaced one
        // merely hands over to its successor.
        if (gen == generation && !out.isClosed) unawaited(out.close());
      },
    );
  }

  out.onListen = () => unawaited(attach());
  out.onCancel = () async {
    closed = true;
    await sub?.cancel();
  };
  return out.stream;
}

/// The device microphone, streaming the PCM shape the dialogue service wants.
/// The call microphone, captured on the same engine that plays the call.
///
/// A separate recorder cannot hold the input hardware while playback runs
/// voice processing on it: capture died as soon as the expert first spoke and
/// the call went one-sided after a single exchange.
/// The call microphone.
///
/// Capture belongs on the engine that plays the call: a separate recorder
/// cannot hold the input hardware while playback runs voice processing on it,
/// which is what made the line go dead after the expert first spoke. But if
/// that tap delivers nothing — an audio session the system will not hand over,
/// a format it will not report — a call with no uplink is worse than one
/// without echo cancellation, so the recorder takes over.
/// The call microphone, streamed by the recorder that is proven on device.
///
/// The native tap on the playback engine never delivered a byte on hardware,
/// which silenced the uplink entirely. This recorder carried yesterday's
/// working calls; what actually killed them was barge-in deactivating the
/// audio session — fixed separately — not the recorder.
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
    // Guarded against the dead first capture of a fresh launch, which binds
    // before voice processing settles and would leave the whole call mute.
    return restartSilentCapture(
      open: () => _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      ),
      close: () => _recorder.stop(),
    );
  }

  @override
  Future<void> stop() async {
    try {
      await _recorder.stop();
    } catch (_) {
      // Hanging up must succeed even if the recorder is already gone.
    }
    // Hand the engine and session back so the next recorder can start.
    try {
      await DeviceCallSpeaker._audio.invokeMethod<bool>('teardownCallAudio');
    } catch (_) {
      // Already gone.
    }
  }
}

/// Plays reply audio through the native call audio engine.
///
/// Each chunk is scheduled onto one engine that stays running for the whole
/// call. Writing a file every few hundred milliseconds and starting a player
/// for it meant each new chunk interrupted the last, which is what made a call
/// stutter even on the earpiece while the same service is steady on desktop.
final class DeviceCallSpeaker implements CallSpeaker {
  const DeviceCallSpeaker();

  static const _audio = MethodChannel('halo.speech/on_device');

  @override
  Future<void> play(Uint8List audio) async {
    try {
      await _audio.invokeMethod<bool>('playPcm', {'pcm': audio});
    } catch (_) {
      // Audio that will not play is dropped rather than ending the call.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _audio.invokeMethod<bool>('stopPcm');
    } catch (_) {
      // Already stopped.
    }
  }

  /// Plays or stops the dialling tone.
  static Future<void> ringback(bool ringing) async {
    try {
      await _audio.invokeMethod<bool>(
        ringing ? 'startRingback' : 'stopRingback',
      );
    } catch (_) {
      // A silent dial is worse than no call, but not worth failing over.
    }
  }

  /// Routes call audio to the loudspeaker or the earpiece.
  static Future<void> useSpeaker(bool speaker) async {
    try {
      await _audio.invokeMethod<bool>('setAudioRoute', {'speaker': speaker});
    } catch (_) {
      // Routing is a comfort setting; a call still works on the default route.
    }
  }

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
}
