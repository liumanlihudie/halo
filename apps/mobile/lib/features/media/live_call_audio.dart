import 'dart:async';
import 'package:flutter/services.dart';
import 'package:halo_mobile/features/media/voice_call_controller.dart';
import 'package:record/record.dart';

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
