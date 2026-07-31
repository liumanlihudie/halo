import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/experts/market_catalog.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

/// Read-only catalog lookups only; execution stays with the app kernel.
final _catalogRegistry = ExecutableExpertRegistry(
  gateway: const ExpertOutputValidationGateway(),
);

/// The expert's real executable data: prompt package, routing card, tool
/// policy, output contract and memory policy, resolved from the catalog.
///
/// Everything shown here is read from the [ExpertProfile]; the page never
/// invents counts or settings that the catalog does not define.
class ExpertDataPage extends StatelessWidget {
  const ExpertDataPage({required this.expertId, super.key});
  final String expertId;

  @override
  Widget build(BuildContext context) {
    final canonicalId =
        _catalogRegistry
            .installedIdentityForProfileId(expertId)
            ?.canonicalExpertId ??
        _catalogRegistry.canonicalIdForMarketId(expertId);
    final catalog = canonicalId == null
        ? null
        : _catalogRegistry.catalogById(canonicalId);

    return HaloPageScaffold(
      title: '专家数据',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/expert/$expertId'),
      ),
      body: catalog == null
          ? _UnavailableBody(expertId: expertId)
          : _CatalogBody(catalog: catalog),
    );
  }
}

/// A fixture-only expert has no executable profile; say so instead of
/// inventing one.
class _UnavailableBody extends StatelessWidget {
  const _UnavailableBody({required this.expertId});

  final String expertId;

  @override
  Widget build(BuildContext context) {
    final normalized = expertId == 'general-assistant' ? 'general' : expertId;
    final name =
        HaloFixtures.installedExperts
            .where((expert) => expert.id == normalized)
            .firstOrNull
            ?.name ??
        marketExperts
            .where((expert) => expert.id == expertId)
            .firstOrNull
            ?.name;
    return ListView(
      padding: const EdgeInsets.fromLTRB(15, 10, 15, 24),
      children: [
        _SectionCard(
          children: [
            if (name != null) ...[
              Text(name, style: HaloTextStyles.rowTitle),
              const SizedBox(height: 6),
            ],
            Text('该专家暂无可执行数据', style: HaloTextStyles.body),
          ],
        ),
      ],
    );
  }
}

class _CatalogBody extends StatelessWidget {
  const _CatalogBody({required this.catalog});

  final ExpertProfile catalog;

  @override
  Widget build(BuildContext context) {
    final prompt = catalog.promptPackage;
    final routing = catalog.routingCard;
    return ListView(
      padding: const EdgeInsets.fromLTRB(15, 10, 15, 24),
      children: [
        DecoratedBox(
          decoration: const BoxDecoration(
            color: HaloColors.navy,
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  catalog.displayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${catalog.description}\n目录 ${catalog.id} · 版本 v${catalog.version}',
                  style: const TextStyle(
                    color: Color(0xFFC5CADB),
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
        const HaloSectionLabel('提示词'),
        _SectionCard(
          children: [
            SelectableText(
              prompt.system,
              style: HaloTextStyles.body.copyWith(height: 1.6),
            ),
            const SizedBox(height: 10),
            _FieldLine(label: '性格', value: prompt.personality),
            const SizedBox(height: 8),
            const Text('约束', style: HaloTextStyles.secondary),
            const SizedBox(height: 4),
            for (final constraint in prompt.constraints)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('· $constraint', style: HaloTextStyles.body),
              ),
          ],
        ),
        const HaloSectionLabel('技能与路由'),
        _SectionCard(
          children: [
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final capability in routing.capabilities)
                  _SkillChip(capability),
              ],
            ),
            const SizedBox(height: 10),
            _FieldLine(label: '响应意图', value: routing.intents.join('、')),
            const SizedBox(height: 6),
            _FieldLine(
              label: '拒绝触发',
              value: routing.negativeTriggers.join('、'),
            ),
          ],
        ),
        const HaloSectionLabel('工具权限'),
        _SectionCard(
          children: [
            _FieldLine(
              label: '可用',
              value: catalog.toolPolicy.allowedTools
                  .where(
                    (tool) => !catalog.toolPolicy.approvalRequiredTools
                        .contains(tool),
                  )
                  .join('、'),
            ),
            const SizedBox(height: 6),
            _FieldLine(
              label: '需授权',
              value: catalog.toolPolicy.approvalRequiredTools.join('、'),
            ),
            const SizedBox(height: 6),
            _FieldLine(
              label: '已禁用',
              value: catalog.toolPolicy.deniedTools.join('、'),
            ),
          ],
        ),
        const HaloSectionLabel('输出合同'),
        _SectionCard(
          children: [
            _FieldLine(label: 'Schema', value: catalog.outputSchema.schemaId),
            const SizedBox(height: 6),
            _FieldLine(
              label: '字段',
              value: catalog.outputSchema.fields.keys.join('、'),
            ),
            const SizedBox(height: 6),
            _FieldLine(
              label: '校验',
              value: switch (catalog.validationPolicy) {
                ExpertValidationPolicy.structural => '结构化校验 · 建议式回答（未核验）',
                ExpertValidationPolicy.trustedEvidence => '可信证据校验（暂未开放对话）',
              },
            ),
          ],
        ),
        const HaloSectionLabel('记忆策略'),
        _SectionCard(
          children: [
            _FieldLine(
              label: '可读范围',
              value: catalog.memoryPolicy.readableScopes
                  .map(_memoryScopeLabel)
                  .join('、'),
            ),
            const SizedBox(height: 6),
            _FieldLine(
              label: '保留期',
              value: switch (catalog.memoryPolicy.retention) {
                MemoryRetention.none => '不保留',
                MemoryRetention.session => '仅本次会话',
              },
            ),
          ],
        ),
      ],
    );
  }

  static String _memoryScopeLabel(MemoryScope scope) => switch (scope) {
    MemoryScope.conversationContext => '会话上下文',
    MemoryScope.userProvidedReferences => '用户提供的资料',
    MemoryScope.verifiedFacts => '已验证事实',
    MemoryScope.sessionScratchpad => '会话草稿',
  };
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: HaloColors.paper,
        borderRadius: BorderRadius.circular(HaloRadii.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

/// A short muted label above wrapping body text, so long identifier lists
/// stay fully readable instead of being ellipsized.
class _FieldLine extends StatelessWidget {
  const _FieldLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: HaloTextStyles.secondary),
        const SizedBox(height: 2),
        Text(value, style: HaloTextStyles.body),
      ],
    );
  }
}

class _SkillChip extends StatelessWidget {
  const _SkillChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: HaloColors.accentSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: HaloTextStyles.caption.copyWith(color: HaloColors.accentDeep),
      ),
    );
  }
}
