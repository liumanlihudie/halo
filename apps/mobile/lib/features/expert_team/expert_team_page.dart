import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/domain/models/halo_fixture_models.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

class ExpertTeamPage extends StatefulWidget {
  const ExpertTeamPage({super.key});

  @override
  State<ExpertTeamPage> createState() => _ExpertTeamPageState();
}

/// Read-only catalog lookups; presence is derived, never invented.
final _teamRegistry = ExecutableExpertRegistry(
  gateway: const ExpertOutputValidationGateway(),
);

/// What is actually true of this expert right now: it either has an
/// executable profile behind it or it does not. The fixture used to claim
/// live moods ('忙碌 · 正在整理需求优先级') nobody was having.
(String, bool) expertAvailability(ExpertFixture expert) {
  final identity = _teamRegistry.installedIdentityForProfileId(expert.id);
  if (identity == null) return ('未实装 · 暂无可执行数据', false);
  final catalog = _teamRegistry.catalogById(identity.canonicalExpertId);
  final description = catalog?.description ?? '';
  return (description.isEmpty ? '可用' : '可用 · $description', true);
}

class _ExpertTeamPageState extends State<ExpertTeamPage> {
  final TextEditingController _searchController = TextEditingController();
  bool _searchVisible = false;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchController.clear();
        _query = '';
      }
    });
  }

  bool _matchesQuery(ExpertFixture expert) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    return expert.name.toLowerCase().contains(query) ||
        expertAvailability(expert).$1.toLowerCase().contains(query);
  }

  @override
  Widget build(BuildContext context) {
    final matches = HaloFixtures.installedExperts.where(_matchesQuery).toList();
    final searching = _query.trim().isNotEmpty;
    return HaloPageScaffold(
      title: '专家团',
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-magnifying-glass',
          semanticLabel: '搜索专家',
          onPressed: _toggleSearch,
        ),
        HaloIconButton(
          prototypeIconClass: 'ph ph-user-plus',
          semanticLabel: '添加专家',
          onPressed: () => context.push('/market'),
        ),
      ],
      body: ListView(
        key: const PageStorageKey('expert-team'),
        padding: const EdgeInsets.fromLTRB(15, 2, 15, 18),
        children: [
          if (_searchVisible)
            Padding(
              padding: const EdgeInsets.only(bottom: 11),
              child: _InlineSearchBar(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                onCancel: _toggleSearch,
              ),
            ),
          _MarketBanner(count: HaloFixtures.marketExperts.length),
          for (final category in const ['工作型', '资讯型', '生活型'])
            if (!searching ||
                matches.any((expert) => expert.category == category)) ...[
              HaloSectionLabel(
                '$category · ${matches.where((expert) => expert.category == category).length}',
              ),
              ColoredBox(
                color: HaloColors.paper,
                child: Column(
                  children: [
                    for (final expert in matches.where(
                      (expert) =>
                          expert.category == category &&
                          expert.id != 'contract',
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

class _InlineSearchBar extends StatefulWidget {
  const _InlineSearchBar({
    required this.controller,
    required this.onChanged,
    required this.onCancel,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onCancel;

  @override
  State<_InlineSearchBar> createState() => _InlineSearchBarState();
}

class _InlineSearchBarState extends State<_InlineSearchBar> {
  final FocusScopeNode _scopeNode = FocusScopeNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scopeNode.nextFocus();
    });
  }

  @override
  void dispose() {
    _scopeNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FocusScope(
            node: _scopeNode,
            child: HaloSearchField(
              placeholder: '搜索专家或状态',
              readOnly: false,
              controller: widget.controller,
              onChanged: widget.onChanged,
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: widget.onCancel,
          child: const Text(
            '取消',
            style: TextStyle(color: HaloColors.accent, fontSize: 13),
          ),
        ),
      ],
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
    final (status, available) = expertAvailability(expert);
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
                            color: available
                                ? HaloColors.green
                                : HaloColors.muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      status,
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
