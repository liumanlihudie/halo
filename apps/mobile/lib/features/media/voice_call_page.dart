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
    super.key,
  });

  final String expertName;

  /// The expert's own persona, sent when the session opens. Without it the
  /// caller would be talking to the vendor's default assistant instead.
  final String systemRole;

  /// Absent when speech is not configured; the page then says so plainly.
  final VoiceCallController? controller;

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
      VoiceCallStatus.idle || VoiceCallStatus.connecting => '正在接通…',
      VoiceCallStatus.listening => '在听你说',
      VoiceCallStatus.speaking => '正在回答',
      VoiceCallStatus.ended => '通话已结束',
      VoiceCallStatus.failed => controller.failure ?? '通话中断',
    };
  }

  Future<void> _hangUp() async {
    await widget.controller?.hangUp();
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      backgroundColor: const Color(0xFF111522),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: Column(
            children: [
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
              Semantics(
                button: true,
                label: '挂断',
                child: GestureDetector(
                  onTap: _hangUp,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE5484D),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      HaloIcon.requirePrototypeClass('ph ph-phone-disconnect'),
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                ),
              ),
            ],
          ),
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
