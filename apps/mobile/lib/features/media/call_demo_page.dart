import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';

class CallDemoPage extends StatelessWidget {
  const CallDemoPage({required this.expertId, required this.video, super.key});
  final String expertId;
  final bool video;

  @override
  Widget build(BuildContext context) {
    final title = video ? 'Vidu 视频通话' : '端到端语音通话';
    return Scaffold(
      backgroundColor: const Color(0xFF111522),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (video)
            Image.network(
              'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=1000',
              fit: BoxFit.cover,
              color: Colors.black45,
              colorBlendMode: BlendMode.darken,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => context.canPop()
                            ? context.pop()
                            : context.go('/expert/general'),
                        icon: Icon(
                          HaloIcon.requirePrototypeClass('ph ph-caret-left'),
                          color: Colors.white,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                const Spacer(),
                if (!video)
                  Container(
                    width: 110,
                    height: 110,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF5668D8),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      '助',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 42,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                const Text(
                  '通用助理',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  video ? '正在生成实时视频形象…' : '正在连接豆包端到端双工语音…',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CallButton(
                      icon: video
                          ? 'ph ph-camera-rotate'
                          : 'ph ph-speaker-high',
                      label: video ? '翻转' : '扬声器',
                      onTap: () {},
                    ),
                    _CallButton(
                      icon: 'ph ph-microphone-slash',
                      label: '静音',
                      onTap: () {},
                    ),
                    _CallButton(
                      icon: 'ph ph-phone',
                      label: '挂断',
                      danger: true,
                      onTap: () => context.canPop()
                          ? context.pop()
                          : context.go('/expert/general'),
                    ),
                  ],
                ),
                const SizedBox(height: 38),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });
  final String icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        IconButton.filled(
          onPressed: onTap,
          style: IconButton.styleFrom(
            backgroundColor: danger ? const Color(0xFFE75B62) : Colors.white24,
            fixedSize: const Size(58, 58),
          ),
          icon: Icon(
            HaloIcon.requirePrototypeClass(icon),
            color: Colors.white,
            size: 25,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 10),
        ),
      ],
    );
  }
}
