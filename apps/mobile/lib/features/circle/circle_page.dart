import 'package:flutter/material.dart';
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
        padding: const EdgeInsets.fromLTRB(15, 3, 15, 18),
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
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: HaloColors.paper,
          borderRadius: BorderRadius.circular(HaloRadii.card),
          border: Border.all(color: HaloColors.line),
        ),
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  HaloAvatar(letter: post.avatarLetter, size: 36),
                  const SizedBox(width: 9),
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
              const SizedBox(height: 12),
              Text(
                post.title,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                  color: HaloColors.ink,
                ),
              ),
              const SizedBox(height: 7),
              Text(post.body, style: HaloTextStyles.body),
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
                  const Text('继续对话', style: HaloTextStyles.caption),
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
