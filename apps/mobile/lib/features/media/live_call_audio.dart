import 'package:flutter/services.dart';
import 'package:halo_mobile/features/media/voice_call_controller.dart';

/// The device microphone, streaming the PCM shape the dialogue service wants.
/// The call microphone, captured on the same engine that plays the call.
///
/// A separate recorder cannot hold the input hardware while playback runs
/// voice processing on it: capture died as soon as the expert first spoke and
/// the call went one-sided after a single exchange.
final class DeviceCallMicrophone implements CallMicrophone {
  const DeviceCallMicrophone();

  static const _mic = EventChannel('halo.speech/mic');

  @override
  Future<Stream<Uint8List>> start() async =>
      _mic.receiveBroadcastStream().map((event) => event as Uint8List);

  @override
  Future<void> stop() async {
    // Cancelling the stream subscription tears the tap down natively.
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
