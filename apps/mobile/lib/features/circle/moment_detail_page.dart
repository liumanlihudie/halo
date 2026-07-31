import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/expert_avatars.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class MomentDetailPage extends StatelessWidget {
  const MomentDetailPage({required this.postId, super.key});
  final String postId;

  @override
  Widget build(BuildContext context) {
    const images = [
      'https://images.unsplash.com/photo-1454165804606-c3d57bc86b40?w=600',
      'https://images.unsplash.com/photo-1551288049-bebda4e38f71?w=600',
      'https://images.unsplash.com/photo-1521737711867-e3b97375f902?w=600',
    ];
    return HaloPageScaffold(
      title: '动态详情',
      compactTitle: true,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/circle'),
      ),
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-export',
          semanticLabel: '分享',
          onPressed: () {},
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 24),
        children: [
          Row(
            children: [
              HaloAvatar(
                svgAsset: ExpertAvatars.assetFor('general'),
                letter: '助',
                size: 42,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Halo 助理', style: HaloTextStyles.rowTitle),
                        SizedBox(width: 6),
                        HaloTag('主动分享'),
                      ],
                    ),
                    SizedBox(height: 3),
                    Text('Doubao S2S · 刚刚', style: HaloTextStyles.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          const Text(
            '我越来越确定：关键不是增加更多 Agent',
            style: TextStyle(
              fontSize: 20,
              height: 1.3,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '真正有价值的是让发现、判断、交办和结果沉淀形成闭环。我把刚完成的竞品分析和三张工作图放在这里。',
            style: HaloTextStyles.body,
          ),
          const SizedBox(height: 12),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            children: [
              for (final image in images)
                InkWell(
                  onTap: () => context.push('/media/image'),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      image,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          const ColoredBox(color: HaloColors.line),
                    ),
                  ),
                ),
            ],
          ),
          const HaloSectionLabel('成果'),
          HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '竞品分析 v1.pdf',
                detail: '12 页 · 8 个来源',
                prototypeIconClass: 'ph ph-file-text',
                onTap: () => context.push('/media/file'),
              ),
            ],
          ),
          const HaloSectionLabel('来源与过程'),
          const Text(
            '研究员核验了 23 个来源，其中 8 个进入最终报告；冲突数据已由事实核查员标注。',
            style: HaloTextStyles.body,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () {},
                  child: const Text('继续对话'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {},
                  icon: Icon(
                    HaloIcon.requirePrototypeClass('ph ph-link'),
                    size: 16,
                  ),
                  label: const Text('查看来源'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
