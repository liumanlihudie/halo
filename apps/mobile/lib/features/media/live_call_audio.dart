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
final class DeviceCallMicrophone implements CallMicrophone {
  DeviceCallMicrophone({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  static const _mic = EventChannel('halo.speech/mic');
  static const _nativeGrace = Duration(seconds: 2);

  final AudioRecorder _recorder;
  bool _usingRecorder = false;

  @override
  Future<Stream<Uint8List>> start() async {
    final out = StreamController<Uint8List>.broadcast();
    StreamSubscription<dynamic>? native;
    var heard = false;

    native = _mic.receiveBroadcastStream().listen((event) {
      heard = true;
      if (event is Uint8List && !out.isClosed) out.add(event);
    }, onError: (Object _) {});

    Timer(_nativeGrace, () async {
      if (heard || out.isClosed) return;
      await native?.cancel();
      native = null;
      try {
        if (!await _recorder.hasPermission()) return;
        final stream = await _recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
          ),
        );
        _usingRecorder = true;
        stream.listen((chunk) {
          if (!out.isClosed) out.add(chunk);
        });
      } catch (_) {
        // Nothing left to try; the call stays one-sided rather than crashing.
      }
    });

    out.onCancel = () async {
      await native?.cancel();
      if (_usingRecorder) await stop();
    };
    return out.stream;
  }

  @override
  Future<void> stop() async {
    if (!_usingRecorder) return;
    _usingRecorder = false;
    try {
      await _recorder.stop();
    } catch (_) {
      // Hanging up must succeed even if the recorder is already gone.
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
