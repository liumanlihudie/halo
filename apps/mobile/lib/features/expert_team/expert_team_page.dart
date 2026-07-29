import 'package:flutter/material.dart';
import 'package:halo_mobile/domain/models/halo_fixture_models.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

class ExpertTeamPage extends StatelessWidget {
  const ExpertTeamPage({super.key});

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '专家团',
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-magnifying-glass',
          semanticLabel: '搜索专家',
          onPressed: () {},
        ),
        HaloIconButton(
          prototypeIconClass: 'ph ph-user-plus',
          semanticLabel: '添加专家',
          onPressed: () {},
        ),
      ],
      body: ListView(
        key: const PageStorageKey('expert-team'),
        padding: const EdgeInsets.fromLTRB(15, 2, 15, 18),
        children: [
          _MarketBanner(count: HaloFixtures.marketExperts.length),
          const HaloSectionLabel('我的专家'),
          for (final category in const ['工作型', '资讯型', '生活型']) ...[
            HaloSectionLabel(
              '$category · ${HaloFixtures.installedExperts.where((expert) => expert.category == category).length}',
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(HaloRadii.card),
              child: ColoredBox(
                color: HaloColors.paper,
                child: Column(
                  children: [
                    for (final expert in HaloFixtures.installedExperts.where(
                      (expert) => expert.category == category,
                    ))
                      _ExpertRow(expert: expert),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MarketBanner extends StatelessWidget {
  const _MarketBanner({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: HaloColors.accentSoft,
      borderRadius: BorderRadius.circular(HaloRadii.card),
      child: InkWell(
        onTap: () {},
        borderRadius: BorderRadius.circular(HaloRadii.card),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const SizedBox.square(
                dimension: 40,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: HaloColors.accent,
                    borderRadius: BorderRadius.all(Radius.circular(11)),
                  ),
                  child: Icon(
                    IconData(
                      0xe43a,
                      fontFamily: 'PhosphorRegular',
                      fontPackage: 'phosphor_flutter',
                    ),
                    color: Colors.white,
                    size: 21,
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('AI 市场', style: HaloTextStyles.rowTitle),
                    const SizedBox(height: 3),
                    Text(
                      '发现并添加新的专业能力 · $count 位专家',
                      style: HaloTextStyles.secondary,
                    ),
                  ],
                ),
              ),
              Icon(
                HaloIcon.requirePrototypeClass('ph ph-caret-right'),
                size: 16,
                color: HaloColors.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExpertRow extends StatelessWidget {
  const _ExpertRow({required this.expert});
  final ExpertFixture expert;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {},
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              HaloAvatar(
                imageUrl: expert.imageUrl,
                letter: expert.avatarLetter,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(expert.name, style: HaloTextStyles.rowTitle),
                    const SizedBox(height: 4),
                    Text(
                      expert.status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HaloTextStyles.secondary,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      expert.model,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HaloTextStyles.caption,
                    ),
                  ],
                ),
              ),
              Icon(
                HaloIcon.requirePrototypeClass('ph ph-caret-right'),
                size: 15,
                color: HaloColors.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
