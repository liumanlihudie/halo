import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/expert_avatars.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/experts/market_catalog.dart';

/// Read-only catalog lookups; the row states executability, never a model.
final _marketRegistry = ExecutableExpertRegistry(
  gateway: const ExpertOutputValidationGateway(),
);

class ExpertMarketPage extends StatefulWidget {
  const ExpertMarketPage({super.key});

  @override
  State<ExpertMarketPage> createState() => _ExpertMarketPageState();
}

class _ExpertMarketPageState extends State<ExpertMarketPage> {
  final TextEditingController _searchController = TextEditingController();
  String category = '推荐';
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final experts = marketExperts
        .where(
          (expert) =>
              (category == '推荐' || expert.category == category) &&
              (query.isEmpty ||
                  expert.name.toLowerCase().contains(query) ||
                  expert.description.contains(query)),
        )
        .toList();
    return HaloPageScaffold(
      title: 'AI 市场',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/experts'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(15, 0, 15, 24),
              itemCount: experts.length + 4,
              itemBuilder: (context, index) {
                if (index == 0) return const _MarketHero();
                if (index == 1) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 11),
                    child: HaloSearchField(
                      placeholder: '搜索 Agent、技能或工作场景',
                      readOnly: false,
                      controller: _searchController,
                      onChanged: (value) => setState(() => _query = value),
                    ),
                  );
                }
                if (index == 2) {
                  return _CategoryChips(
                    selected: category,
                    onSelected: (value) => setState(() => category = value),
                  );
                }
                if (index == 3) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    child: Row(
                      children: [
                        Text(
                          category == '推荐' ? '全部专家' : category,
                          style: HaloTextStyles.rowTitle,
                        ),
                        const Spacer(),
                        Text(
                          '已显示 ${experts.length} / ${marketExperts.length}',
                          style: HaloTextStyles.caption,
                        ),
                      ],
                    ),
                  );
                }
                final expert = experts[index - 4];
                // Every entry is a real prompt; what varies is whether an
                // executable profile already stands behind it. No entry
                // claims a model — the user's binding decides that.
                final installed = expert.installedProfileId;
                final executable =
                    installed != null ||
                    _marketRegistry.canonicalIdForMarketId(expert.id) != null;
                return _MarketExpertRow(
                  id: expert.id,
                  name: expert.name,
                  category: expert.category,
                  model: installed != null
                      ? '已入驻 · 可直接对话'
                      : executable
                      ? '可执行 · 使用你配置的模型'
                      : '提示词专家 · 查看提示词',
                  description: installed != null
                      ? '已在你的专家团中'
                      : expert.description,
                  onTap: () => installed != null
                      ? context.push('/expert/$installed')
                      : context.push('/market/${expert.id}'),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MarketHero extends StatelessWidget {
  const _MarketHero();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: const BoxDecoration(
        color: HaloColors.navy,
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CURATED AGENT MARKET',
            style: TextStyle(
              color: Color(0xFFB8C0E8),
              fontSize: 8,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 8),
          Text(
            '给自己增加\n新的专业能力',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              height: 1.18,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 9),
          Text(
            '先看能力、模型与权限，再使用你的 API Key',
            style: TextStyle(color: Color(0xFFC5CADB), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _CategoryChips extends StatelessWidget {
  const _CategoryChips({required this.selected, required this.onSelected});
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final categories = ['推荐', ...marketCategories()];
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          for (final category in categories)
            ChoiceChip(
              label: Text(category),
              selected: selected == category,
              onSelected: (_) => onSelected(category),
              showCheckmark: false,
              selectedColor: HaloColors.accent,
              backgroundColor: Colors.white,
              side: BorderSide.none,
              labelStyle: TextStyle(
                color: selected == category ? Colors.white : HaloColors.muted,
                fontSize: 11,
              ),
            ),
        ],
      ),
    );
  }
}

class _MarketExpertRow extends StatelessWidget {
  const _MarketExpertRow({
    required this.id,
    required this.name,
    required this.category,
    required this.model,
    required this.description,
    required this.onTap,
  });
  final String id;
  final String name;
  final String category;
  final String model;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              HaloAvatar(
                svgAsset: ExpertAvatars.assetFor(id),
                letter: name.characters.first,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(name, style: HaloTextStyles.rowTitle),
                        ),
                        const SizedBox(width: 6),
                        HaloTag(category),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HaloTextStyles.secondary,
                    ),
                    const SizedBox(height: 3),
                    Text(model, style: HaloTextStyles.caption),
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
