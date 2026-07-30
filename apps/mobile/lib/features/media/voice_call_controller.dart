// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/volcano_realtime_dialog.dart';

enum VoiceCallStatus { idle, connecting, listening, speaking, ended, failed }

/// Streams microphone audio for a live call.
abstract interface class CallMicrophone {
  /// Emits raw PCM chunks (s16le, mono) until the call stops.
  Future<Stream<Uint8List>> start();

  Future<void> stop();
}

/// Plays the reply audio arriving during a call.
abstract interface class CallSpeaker {
  Future<void> play(Uint8List audio);

  /// Stops playback immediately, so the expert can be interrupted mid-sentence.
  Future<void> stop();
}

/// Drives one audio call with an expert.
///
/// The persona travels with the session, so the caller is talking to that
/// expert rather than to the vendor's default assistant. What is said is shown
/// as live text too: a call the user cannot read back is a call they cannot
/// check.
final class VoiceCallController extends ChangeNotifier {
  VoiceCallController({
    required Future<VolcanoRealtimeDialog?> Function() openDialog,
    required CallMicrophone microphone,
    required CallSpeaker speaker,
  }) : _openDialog = openDialog,
       _microphone = microphone,
       _speaker = speaker;

  /// Opens the transport when the call starts, so the credential is read then
  /// rather than held from app launch. Null means speech is not configured.
  final Future<VolcanoRealtimeDialog?> Function() _openDialog;
  VolcanoRealtimeDialog? _dialog;
  final CallMicrophone _microphone;
  final CallSpeaker _speaker;

  StreamSubscription<RealtimeDialogEvent>? _events;
  StreamSubscription<Uint8List>? _audio;

  VoiceCallStatus _status = VoiceCallStatus.idle;
  VoiceCallStatus get status => _status;

  String _heard = '';
  String get heard => _heard;

  String _reply = '';
  String get reply => _reply;

  String? _failure;
  String? get failure => _failure;

  bool _speakerOn = true;
  bool get speakerOn => _speakerOn;

  /// Switches between the loudspeaker and the earpiece mid-call.
  Future<void> setSpeaker(bool on) async {
    _speakerOn = on;
    notifyListeners();
    await _routeAudio?.call(on);
  }

  /// Injected so the route can be exercised without a device.
  Future<void> Function(bool speaker)? routeAudio;
  Future<void> Function(bool speaker)? get _routeAudio => routeAudio;

  Future<void> start({
    required String systemRole,
    required String botName,
  }) async {
    if (_status == VoiceCallStatus.connecting ||
        _status == VoiceCallStatus.listening ||
        _status == VoiceCallStatus.speaking) {
      return;
    }
    _set(VoiceCallStatus.connecting, failure: null);
    final dialog = await _openDialog();
    if (dialog == null) {
      _set(VoiceCallStatus.failed, failure: '尚未配置语音服务');
      return;
    }
    _dialog = dialog;
    final Stream<RealtimeDialogEvent> events;
    try {
      events = await dialog.start(systemRole: systemRole, botName: botName);
    } on RealtimeDialogException catch (error) {
      _set(VoiceCallStatus.failed, failure: error.safeMessage);
      return;
    } catch (_) {
      _set(VoiceCallStatus.failed, failure: '无法接通语音通话，请重试');
      return;
    }
    _events = events.listen(_onEvent);
    await _routeAudio?.call(_speakerOn);
    try {
      final microphone = await _microphone.start();
      _audio = microphone.listen(dialog.sendAudio);
    } catch (_) {
      await hangUp();
      _set(VoiceCallStatus.failed, failure: '需要麦克风权限才能通话');
      return;
    }
    _set(VoiceCallStatus.listening);
  }

  void _onEvent(RealtimeDialogEvent event) {
    switch (event) {
      case RealtimeUserSpeaking():
        // The user cut in: go quiet at once instead of talking over them.
        unawaited(_speaker.stop());
        _set(VoiceCallStatus.listening);
      case RealtimeUserText(:final text):
        _heard = text;
        _reply = '';
        notifyListeners();
      case RealtimeReplyText(:final text):
        _reply += text;
        _set(VoiceCallStatus.speaking);
      case RealtimeReplyAudio(:final bytes):
        unawaited(_speaker.play(bytes));
      case RealtimeReplyEnded():
        _set(VoiceCallStatus.listening);
      case RealtimeDialogFailed(:final safeMessage):
        _set(VoiceCallStatus.failed, failure: safeMessage);
        unawaited(_release());
    }
  }

  Future<void> hangUp() async {
    await _release();
    if (_status != VoiceCallStatus.failed) _set(VoiceCallStatus.ended);
  }

  Future<void> _release() async {
    await _audio?.cancel();
    _audio = null;
    await _events?.cancel();
    _events = null;
    await _microphone.stop();
    await _speaker.stop();
    await _dialog?.stop();
    _dialog = null;
  }

  void _set(VoiceCallStatus status, {String? failure}) {
    _status = status;
    if (failure != null || status != VoiceCallStatus.failed) {
      _failure = failure;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_release());
    super.dispose();
  }
}
