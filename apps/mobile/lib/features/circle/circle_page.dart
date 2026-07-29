import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/domain/models/halo_fixture_models.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

class CirclePage extends StatelessWidget {
  const CirclePage({super.key});

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '圈层',
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-magnifying-glass',
          semanticLabel: '搜索动态',
          onPressed: () {},
        ),
        HaloIconButton(
          prototypeIconClass: 'ph ph-sliders-horizontal',
          semanticLabel: '动态设置',
          onPressed: () {},
        ),
      ],
      body: ListView(
        key: const PageStorageKey('circle'),
        padding: const EdgeInsets.fromLTRB(13, 5, 13, 18),
        children: [
          const Text(
            '专家动态',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: HaloColors.ink,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            '你的专家最近在想什么、做什么。这里不分类，只按发布时间排列。',
            style: HaloTextStyles.secondary,
          ),
          const SizedBox(height: 13),
          for (final post in HaloFixtures.circlePosts) _PostCard(post: post),
        ],
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({required this.post});
  final CirclePostFixture post;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: HaloColors.paper,
          borderRadius: BorderRadius.circular(17),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0E252C40),
              blurRadius: 15,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  HaloAvatar(
                    imageUrl: post.imageUrl,
                    letter: post.avatarLetter,
                    size: 42,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              post.author,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 6),
                            HaloTag(post.source, tone: post.tone),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(post.meta, style: HaloTextStyles.caption),
                      ],
                    ),
                  ),
                  Icon(
                    HaloIcon.requirePrototypeClass('ph ph-dots-three'),
                    size: 20,
                    color: HaloColors.muted,
                  ),
                ],
              ),
              const SizedBox(height: 11),
              Text(
                post.title,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  fontWeight: FontWeight.w700,
                  color: HaloColors.ink,
                ),
              ),
              const SizedBox(height: 7),
              Text(post.body, style: HaloTextStyles.body),
              if (post.author == '通用助理') ...[
                const SizedBox(height: 10),
                const _CircleGallery(),
                const SizedBox(height: 9),
                _CircleResultCard(onTap: () => context.push('/media/file')),
              ] else if (post.author == '日程管家') ...[
                const SizedBox(height: 10),
                const _CircleStatusCard(),
              ] else if (post.source == '监控变化') ...[
                const SizedBox(height: 10),
                const _CircleLinkCard(),
              ] else if (post.source == '任务失败') ...[
                const SizedBox(height: 10),
                const _CircleFailureCard(),
              ],
              const SizedBox(height: 11),
              const Divider(height: 1, color: HaloColors.line),
              const SizedBox(height: 9),
              Row(
                children: [
                  Icon(
                    HaloIcon.requirePrototypeClass('ph ph-chat-circle-dots'),
                    size: 16,
                    color: HaloColors.muted,
                  ),
                  const SizedBox(width: 5),
                  TextButton(
                    onPressed: () => context.push('/circle/post-1'),
                    child: const Text('查看详情'),
                  ),
                  const Spacer(),
                  Icon(
                    HaloIcon.requirePrototypeClass('ph ph-export'),
                    size: 16,
                    color: HaloColors.muted,
                  ),
                  const SizedBox(width: 5),
                  const Text('分享成果', style: HaloTextStyles.caption),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleGallery extends StatelessWidget {
  const _CircleGallery();

  @override
  Widget build(BuildContext context) {
    const urls = [
      'https://images.unsplash.com/photo-1454165804606-c3d57bc86b40?auto=format&fit=crop&w=500&q=74',
      'https://images.unsplash.com/photo-1551288049-bebda4e38f71?auto=format&fit=crop&w=320&q=74',
      'https://images.unsplash.com/photo-1521737711867-e3b97375f902?auto=format&fit=crop&w=320&q=74',
    ];
    return SizedBox(
      height: 145,
      child: Row(
        children: [
          Expanded(flex: 135, child: _GalleryImage(url: urls[0])),
          const SizedBox(width: 4),
          Expanded(
            flex: 100,
            child: Column(
              children: [
                Expanded(child: _GalleryImage(url: urls[1])),
                const SizedBox(height: 4),
                Expanded(child: _GalleryImage(url: urls[2])),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryImage extends StatelessWidget {
  const _GalleryImage({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: Image.network(
        url,
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const ColoredBox(color: HaloColors.line),
      ),
    );
  }
}

class _CircleResultCard extends StatelessWidget {
  const _CircleResultCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF1F2F4),
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Row(
            children: [
              HaloAvatar(letter: 'PDF', size: 42),
              SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('竞品分析 v1', style: HaloTextStyles.rowTitle),
                    SizedBox(height: 2),
                    Text('12 页 · 8 个来源 · 点击查看', style: HaloTextStyles.caption),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleStatusCard extends StatelessWidget {
  const _CircleStatusCard();

  @override
  Widget build(BuildContext context) {
    return _CircleInfoCard(
      icon: 'ph ph-calendar-check',
      title: '每日 08:30 日程检查',
      detail: '下次运行：明天 08:30 · 本机执行',
      trailing: const HaloTag('已完成', tone: HaloTagTone.green),
    );
  }
}

class _CircleLinkCard extends StatelessWidget {
  const _CircleLinkCard();

  @override
  Widget build(BuildContext context) {
    return const _CircleInfoCard(
      icon: 'ph ph-trend-up',
      title: '查看前后版本差异',
      detail: '公开网页快照 · 已保存变化证据',
    );
  }
}

class _CircleFailureCard extends StatelessWidget {
  const _CircleFailureCard();

  @override
  Widget build(BuildContext context) {
    return const _CircleInfoCard(
      icon: 'ph ph-warning-circle',
      title: '读取失败',
      detail: '未生成结论 · 点击重试或更换数据源',
      failure: true,
    );
  }
}

class _CircleInfoCard extends StatelessWidget {
  const _CircleInfoCard({
    required this.icon,
    required this.title,
    required this.detail,
    this.trailing,
    this.failure = false,
  });
  final String icon;
  final String title;
  final String detail;
  final Widget? trailing;
  final bool failure;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: failure ? const Color(0xFFFFEDEF) : const Color(0xFFF2F3F7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              HaloIcon.requirePrototypeClass(icon),
              size: 18,
              color: failure ? HaloColors.red : HaloColors.accentDeep,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(detail, style: HaloTextStyles.caption),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
