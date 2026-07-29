import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class MediaPreviewPage extends StatelessWidget {
  const MediaPreviewPage({required this.kind, super.key});
  final String kind;

  @override
  Widget build(BuildContext context) {
    final isFile = kind == 'file';
    return Scaffold(
      backgroundColor: const Color(0xFF090A0D),
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 53,
              child: Row(
                children: [
                  HaloIconButton(
                    prototypeIconClass: 'ph ph-caret-left',
                    semanticLabel: '返回',
                    onPressed: () => context.canPop()
                        ? context.pop()
                        : context.go('/conversations'),
                  ),
                  Expanded(
                    child: Text(
                      isFile ? '文件预览' : '图片预览',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  HaloIconButton(
                    prototypeIconClass: 'ph ph-export',
                    semanticLabel: '分享',
                    onPressed: () {},
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: isFile
                    ? Container(
                        width: 260,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'PDF',
                              style: TextStyle(
                                color: HaloColors.red,
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 14),
                            Text('竞品分析 v1.pdf', style: HaloTextStyles.rowTitle),
                            SizedBox(height: 6),
                            Text(
                              '12 页 · 8 个来源 · 2.4 MB',
                              style: HaloTextStyles.caption,
                            ),
                          ],
                        ),
                      )
                    : InteractiveViewer(
                        child: Image.network(
                          'https://images.unsplash.com/photo-1551288049-bebda4e38f71?w=1200',
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => Icon(
                            HaloIcon.requirePrototypeClass('ph ph-image'),
                            size: 80,
                            color: Colors.white54,
                          ),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _PreviewAction(
                    icon: 'ph ph-download-simple',
                    label: '保存',
                    onTap: () {},
                  ),
                  _PreviewAction(
                    icon: 'ph ph-export',
                    label: '分享',
                    onTap: () {},
                  ),
                  _PreviewAction(
                    icon: 'ph ph-chat-circle-dots',
                    label: '继续对话',
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewAction extends StatelessWidget {
  const _PreviewAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final String icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Icon(
            HaloIcon.requirePrototypeClass(icon),
            color: Colors.white,
            size: 22,
          ),
          const SizedBox(height: 5),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
