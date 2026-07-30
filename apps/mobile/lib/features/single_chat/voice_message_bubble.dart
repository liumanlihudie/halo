import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

/// Plays one voice message, WeChat style: tap to play, tap 转文字 to read it.
///
/// The transcript is already stored with the message, so revealing it costs
/// nothing and works offline. Expert replies keep their 未核验 disclosure —
/// audio cannot carry a badge, so the transcript has to.
class VoiceMessageBubble extends StatefulWidget {
  const VoiceMessageBubble({
    required this.message,
    required this.mine,
    this.player,
    super.key,
  });

  final ChatMessageProjection message;
  final bool mine;
  final AudioPlayer? player;

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  AudioPlayer? _player;
  bool _playing = false;
  bool _showTranscript = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // An expert reply is disclosed as unverified, so its words must be
    // readable without playing anything.
    _showTranscript = !widget.mine;
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final path = widget.message.imageUrl;
    if (path == null || !File(path).existsSync()) {
      setState(() => _error = '音频文件不在本机');
      return;
    }
    final player = _player ??= widget.player ?? AudioPlayer();
    try {
      if (_playing) {
        await player.stop();
        if (mounted) setState(() => _playing = false);
        return;
      }
      setState(() {
        _playing = true;
        _error = null;
      });
      player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _playing = false);
      });
      await player.play(DeviceFileSource(path));
    } catch (_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _error = '播放失败，请重试';
        });
      }
    }
  }

  String get _duration => widget.message.secondaryText ?? '';

  @override
  Widget build(BuildContext context) {
    final transcript = widget.message.text ?? '';
    final foreground = widget.mine ? Colors.white : HaloColors.ink;
    return Column(
      crossAxisAlignment: widget.mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                HaloIcon.requirePrototypeClass(
                  _playing ? 'ph ph-pause' : 'ph ph-play',
                ),
                size: 16,
                color: foreground,
              ),
              const SizedBox(width: 8),
              _WaveBars(color: foreground, animated: _playing),
              const SizedBox(width: 8),
              Text(
                _duration,
                style: TextStyle(fontSize: 12, color: foreground),
              ),
            ],
          ),
        ),
        if (_error case final error?) ...[
          const SizedBox(height: 6),
          Text(error, style: TextStyle(fontSize: 11, color: foreground)),
        ],
        if (transcript.isNotEmpty) ...[
          const SizedBox(height: 6),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showTranscript = !_showTranscript),
            child: Text(
              _showTranscript ? '收起文字' : '转文字',
              style: TextStyle(
                fontSize: 11,
                color: foreground.withValues(alpha: 0.75),
              ),
            ),
          ),
          if (_showTranscript) ...[
            const SizedBox(height: 5),
            Text(
              transcript,
              style: TextStyle(fontSize: 14, height: 1.45, color: foreground),
            ),
          ],
        ],
      ],
    );
  }
}

class _WaveBars extends StatelessWidget {
  const _WaveBars({required this.color, required this.animated});

  final Color color;
  final bool animated;

  @override
  Widget build(BuildContext context) {
    const heights = [8.0, 14.0, 10.0, 16.0, 9.0];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final height in heights) ...[
          Container(
            width: 3,
            height: animated ? height : height * 0.6,
            decoration: BoxDecoration(
              color: color.withValues(alpha: animated ? 0.95 : 0.55),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 3),
        ],
      ],
    );
  }
}
