import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
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
          for (final category in const ['工作型', '资讯型', '生活型']) ...[
            HaloSectionLabel(
              '$category · ${HaloFixtures.installedExperts.where((expert) => expert.category == category).length}',
            ),
            ColoredBox(
              color: HaloColors.paper,
              child: Column(
                children: [
                  for (final expert in HaloFixtures.installedExperts.where(
                    (expert) =>
                        expert.category == category && expert.id != 'contract',
                  ))
                    _ExpertRow(expert: expert),
                ],
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
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0xFF29334F), Color(0xFF6676D3)],
        ),
        borderRadius: BorderRadius.circular(15),
        boxShadow: const [
          BoxShadow(
            color: Color(0x405668D8),
            blurRadius: 25,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(15),
        child: InkWell(
          onTap: () => context.push('/market'),
          borderRadius: BorderRadius.circular(15),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 48,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0x20FFFFFF),
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                    ),
                    child: Icon(
                      IconData(
                        0xe43a,
                        fontFamily: 'PhosphorRegular',
                        fontPackage: 'phosphor_flutter',
                      ),
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'AI 市场',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '发现并添加新的专业能力 · $count 位专家',
                        style: const TextStyle(
                          color: Color(0xBDFFFFFF),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  HaloIcon.requirePrototypeClass('ph ph-caret-right'),
                  size: 16,
                  color: Colors.white,
                ),
              ],
            ),
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
        onTap: () => context.push('/expert/${expert.id}'),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: HaloColors.line)),
          ),
          child: Row(
            children: [
              HaloAvatar(
                imageUrl: expert.imageUrl,
                letter: expert.avatarLetter,
                size: 46,
                tone: expert.avatarTone,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          expert.name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: expert.status.startsWith('忙碌')
                                ? HaloColors.amber
                                : expert.status.startsWith('离线')
                                ? HaloColors.muted
                                : HaloColors.green,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      expert.status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF9196A0),
                        fontSize: 10,
                      ),
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
