import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/features/media/voice_call_controller.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';

/// A live audio call with one expert.
///
/// Everything said is shown as text while it happens: a call the user cannot
/// read back is a call they cannot check, and the expert's replies carry the
/// same unverified standing they do in chat.
class VoiceCallPage extends StatefulWidget {
  const VoiceCallPage({
    required this.expertName,
    required this.systemRole,
    this.controller,
    this.onCallEnded,
    super.key,
  });

  final String expertName;

  /// The expert's own persona, sent when the session opens. Without it the
  /// caller would be talking to the vendor's default assistant instead.
  final String systemRole;

  /// Absent when speech is not configured; the page then says so plainly.
  final VoiceCallController? controller;

  /// Records the finished call in the conversation, the way a phone call
  /// leaves a row in a messenger thread.
  final Future<void> Function(String summary)? onCallEnded;

  @override
  State<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends State<VoiceCallPage> {
  @override
  void initState() {
    super.initState();
    final controller = widget.controller;
    if (controller == null) return;
    controller.addListener(_refresh);
    unawaited(
      controller.start(
        systemRole: widget.systemRole,
        botName: widget.expertName,
      ),
    );
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_refresh);
    unawaited(widget.controller?.hangUp());
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String get _statusLabel {
    final controller = widget.controller;
    if (controller == null) return '尚未配置语音服务';
    return switch (controller.status) {
      VoiceCallStatus.idle => '正在拨号…',
      VoiceCallStatus.connecting => '正在接通…',
      VoiceCallStatus.listening => '在听你说',
      VoiceCallStatus.speaking => '正在回答',
      VoiceCallStatus.ended => '通话已结束',
      VoiceCallStatus.failed => controller.failure ?? '通话中断',
    };
  }

  Future<void> _hangUp() async {
    final duration = widget.controller?.duration;
    await widget.controller?.hangUp();
    final summary = duration == null
        ? '语音通话已取消'
        : '语音通话  ${duration.inMinutes}:'
              '${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
    await widget.onCallEnded?.call(summary);
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final speakerOn = controller?.speakerOn ?? true;
    return Scaffold(
      backgroundColor: const Color(0xFF111522),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: Column(
            children: [
              Container(
                width: 92,
                height: 92,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF3B4BDB),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  widget.expertName.characters.first,
                  style: const TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.expertName,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _statusLabel,
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 28),
              Expanded(
                child: SingleChildScrollView(
                  reverse: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (controller?.heard.isNotEmpty ?? false)
                        _Line(
                          label: '你说',
                          text: controller!.heard,
                          color: Colors.white,
                        ),
                      if (controller?.reply.isNotEmpty ?? false) ...[
                        const SizedBox(height: 14),
                        _Line(
                          label: widget.expertName,
                          text: controller!.reply,
                          color: const Color(0xFF9FB4FF),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '未核验',
                          style: TextStyle(fontSize: 11, color: Colors.white38),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _CallAction(
                    icon: speakerOn ? 'ph ph-speaker-high' : 'ph ph-phone',
                    label: speakerOn ? '扬声器' : '听筒',
                    active: speakerOn,
                    onTap: controller == null
                        ? null
                        : () => unawaited(controller.setSpeaker(!speakerOn)),
                  ),
                  _CallAction(
                    icon: 'ph ph-phone-disconnect',
                    label: '挂断',
                    danger: true,
                    onTap: _hangUp,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One round control, the way a phone call presents its options.
class _CallAction extends StatelessWidget {
  const _CallAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.danger = false,
  });

  final String icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: danger
                    ? const Color(0xFFE5484D)
                    : (active ? Colors.white : Colors.white24),
                shape: BoxShape.circle,
              ),
              child: Icon(
                HaloIcon.requirePrototypeClass(icon),
                color: danger
                    ? Colors.white
                    : (active ? const Color(0xFF111522) : Colors.white),
                size: 26,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.text, required this.color});

  final String label;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.white38),
        ),
        const SizedBox(height: 4),
        Text(text, style: TextStyle(fontSize: 16, height: 1.5, color: color)),
      ],
    );
  }
}
