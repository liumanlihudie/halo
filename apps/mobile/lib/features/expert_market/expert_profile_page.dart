import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/foundation/design_system/expert_avatars.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/features/settings/model_picker_sheet.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

/// Read-only catalog lookups only; execution stays with the app kernel.
final _catalogRegistry = ExecutableExpertRegistry(
  gateway: const ExpertOutputValidationGateway(),
);

class ExpertProfilePage extends StatelessWidget {
  const ExpertProfilePage({
    required this.expertId,
    this.marketMode = false,
    this.installedIdentity,
    this.routingController,
    super.key,
  });
  final String expertId;
  final bool marketMode;
  final InstalledExpertIdentity? installedIdentity;
  final ModelRoutingController? routingController;

  @override
  Widget build(BuildContext context) {
    final normalizedExpertId = expertId == 'general-assistant'
        ? 'general'
        : expertId;
    final installed = HaloFixtures.installedExperts
        .where((expert) => expert.id == normalizedExpertId)
        .firstOrNull;
    final market = HaloFixtures.marketExperts
        .where((expert) => expert.id == expertId)
        .firstOrNull;
    final name = installed?.name ?? market?.name ?? '合同审阅助手';
    // An installed expert's real binding is rendered by the 模型 row below,
    // which resolves it from the routing controller. Repeating a fixture model
    // string here would contradict it — 通用助理 claimed
    // `ToAPIs / doubao-s2s · 可用` while the row correctly read 尚未配置.
    // Availability is a fact about the catalog, not a mood: either an
    // executable profile stands behind this expert or it does not.
    final profileModel = installedIdentity != null ? '可用' : '未实装';
    // Resolve the executable catalog profile so the page can show real
    // skills and tool permissions instead of prototype placeholders. Pure
    // fixture market experts stay on their short description.
    final canonicalId = marketMode
        ? _catalogRegistry.canonicalIdForMarketId(expertId)
        : installedIdentity?.canonicalExpertId;
    final catalog = canonicalId == null
        ? null
        : _catalogRegistry.catalogById(canonicalId);
    final description =
        market?.description ??
        catalog?.description ??
        '你的个人工作协调者。理解需求，安排最合适的 Agent，并把过程整理成最终结果。';
    final avatarUrl =
        installed?.imageUrl ??
        'https://images.unsplash.com/photo-1568602471122-7832951cc4c5'
            '?auto=format&fit=crop&w=180&q=75';

    return HaloPageScaffold(
      title: marketMode ? 'Agent 详情' : 'Agent 资料',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () => context.canPop()
            ? context.pop()
            : context.go(marketMode ? '/market' : '/experts'),
      ),
      actions: [
        HaloIconButton(
          prototypeIconClass: marketMode
              ? 'ph ph-share-network'
              : 'ph ph-dots-three',
          semanticLabel: marketMode ? '分享' : '更多',
          onPressed: () {},
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: 94),
        children: [
          _ProfileHero(
            name: name,
            model: marketMode
                ? (catalog != null ? '可执行 · 使用你配置的模型' : '上架准备中')
                : profileModel,
            avatarUrl: avatarUrl,
            svgAsset: ExpertAvatars.assetFor(
              marketMode ? expertId : normalizedExpertId,
            ),
          ),
          ColoredBox(
            color: HaloColors.paper,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
              child: Text(description, style: HaloTextStyles.body),
            ),
          ),
          if (catalog != null)
            _CatalogDetailSections(
              catalog: catalog,
              // The market lead paragraph comes from the fixture, so the
              // catalog's own description is still worth showing there.
              showDescription: catalog.description != description,
            ),
          if (marketMode) ...[
            if (catalog == null) const _AbilityGrid(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 15),
              child: HaloSectionLabel('模型与用量'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Text(
                // No model is claimed here: the expert runs on whatever the
                // user binds, and the bill is the provider's own.
                'BYOK · 使用你配置的模型与 Key · 按服务商账单结算',
                style: HaloTextStyles.body,
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 15),
              child: HaloSectionLabel('权限'),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 15),
              child: Text('仅访问你主动发送的文件；敏感工具按次授权。', style: HaloTextStyles.body),
            ),
          ] else ...[
            _ExpertActionBar(
              actions: [
                _ExpertAction(
                  label: '发消息',
                  detail: installedIdentity == null ? '尚未安装' : '文字对话',
                  prototypeIconClass: 'ph ph-chat-circle-text',
                  onTap: installedIdentity == null
                      ? null
                      : () => context.push(
                          '/chat/${installedIdentity!.conversationId}',
                        ),
                ),
                _ExpertAction(
                  label: '语音通话',
                  detail: '端到端双工',
                  prototypeIconClass: 'ph ph-phone',
                  onTap: () => context.push('/call/voice/$expertId'),
                ),
                _ExpertAction(
                  label: '视频通话',
                  detail: 'Vidu',
                  prototypeIconClass: 'ph ph-video-camera',
                  onTap: () => context.push('/call/video/$expertId'),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 15),
              child: HaloSectionLabel('专家与动态'),
            ),
            HaloSettingsGroup(
              children: [
                if (installedIdentity != null && routingController != null)
                  _ExpertModelRoutingRow(
                    canonicalExpertId: installedIdentity!.canonicalExpertId,
                    controller: routingController!,
                  ),
                HaloSettingsRow(
                  label: '专家数据',
                  detail: '提示词、模型、工具与权限',
                  onTap: () => context.push('/expert/$expertId/data'),
                ),
                HaloSettingsRow(
                  label: '当前状态',
                  detail: '可用 · 最近活动',
                  onTap: () {},
                ),
                HaloSettingsRow(
                  label: '最近圈层动态',
                  detail: '3 条 · 刚刚',
                  onTap: () {},
                ),
              ],
            ),
            const _PreferenceSettings(),
          ],
        ],
      ),
      bottom: marketMode ? _MarketBottomBar(name: name) : null,
    );
  }
}

@immutable
class _ExpertAction {
  const _ExpertAction({
    required this.label,
    required this.detail,
    required this.prototypeIconClass,
    required this.onTap,
  });

  final String label;
  final String detail;
  final String prototypeIconClass;
  final VoidCallback? onTap;
}

/// The three primary ways to reach an expert, side by side.
///
/// A disabled action stays visible with its reason so an uninstalled expert
/// does not silently look identical to an installed one.
class _ExpertActionBar extends StatelessWidget {
  const _ExpertActionBar({required this.actions});

  final List<_ExpertAction> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 10, 13, 4),
      child: Row(
        children: [
          for (final action in actions) ...[
            if (action != actions.first) const SizedBox(width: 9),
            Expanded(child: _ExpertActionButton(action: action)),
          ],
        ],
      ),
    );
  }
}

class _ExpertActionButton extends StatelessWidget {
  const _ExpertActionButton({required this.action});

  final _ExpertAction action;

  @override
  Widget build(BuildContext context) {
    final enabled = action.onTap != null;
    final foreground = enabled ? HaloColors.accentDeep : HaloColors.muted;
    return Semantics(
      button: true,
      enabled: enabled,
      label: action.label,
      child: ExcludeSemantics(
        child: Material(
          color: HaloColors.paper,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: action.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    HaloIcon.requirePrototypeClass(action.prototypeIconClass),
                    size: 22,
                    color: foreground,
                  ),
                  const SizedBox(height: 7),
                  Text(
                    action.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HaloTextStyles.rowTitle.copyWith(
                      color: enabled ? null : HaloColors.muted,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    action.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HaloTextStyles.caption,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpertModelRoutingRow extends StatefulWidget {
  const _ExpertModelRoutingRow({
    required this.canonicalExpertId,
    required this.controller,
  });

  final String canonicalExpertId;
  final ModelRoutingController controller;

  @override
  State<_ExpertModelRoutingRow> createState() => _ExpertModelRoutingRowState();
}

class _ExpertModelRoutingRowState extends State<_ExpertModelRoutingRow> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ExpertModelRoutingRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.canonicalExpertId != widget.canonicalExpertId) {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      await widget.controller.load();
      await widget.controller.loadExpertOverride(widget.canonicalExpertId);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) =>
          HaloSettingsRow(label: '模型', detail: _detail(), onTap: _chooseModel),
    );
  }

  String _detail() {
    final override = widget.controller.expertOverrideFor(
      widget.canonicalExpertId,
    );
    final effective = override ?? widget.controller.globalDefault;
    final option = widget.controller.optionFor(effective);
    final prefix = override == null ? '跟随默认' : '独立';
    if (option == null) return '$prefix · 尚未配置';
    return '$prefix · ${option.providerName} / ${option.ref.modelId}';
  }

  Future<void> _chooseModel() async {
    try {
      await widget.controller.load();
      await widget.controller.loadExpertOverride(widget.canonicalExpertId);
      if (!mounted) return;
      final override = widget.controller.expertOverrideFor(
        widget.canonicalExpertId,
      );
      final selection = await showModelPickerSheet(
        context,
        options: widget.controller.availableModels,
        selectedModel: override,
        allowFollowGlobal: true,
        followingGlobal: override == null,
      );
      if (selection == null || !mounted) return;
      await widget.controller.setExpertOverride(
        widget.canonicalExpertId,
        selection.followsGlobal ? null : selection.model,
      );
    } on ModelRoutingException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.safeMessage)));
    } on StateError {
      // The kernel swapped this controller out mid-interaction; the replacement
      // page rebuilds from the new controller.
      return;
    }
  }
}

class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    this.svgAsset,
    required this.name,
    required this.model,
    required this.avatarUrl,
  });
  final String name;
  final String model;
  final String? svgAsset;
  final String avatarUrl;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 205,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            'https://images.unsplash.com/photo-1556761175-b413da4baf72'
            '?auto=format&fit=crop&w=900&q=80',
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const ColoredBox(color: HaloColors.navy),
          ),
          DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0x99000000)],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white, width: 3),
                        borderRadius: BorderRadius.circular(19),
                      ),
                      child: HaloAvatar(
                        svgAsset: svgAsset,
                        letter: name.characters.first,
                        imageUrl: avatarUrl,
                        size: 76,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              model,
                              style: const TextStyle(
                                color: Color(0xCCFFFFFF),
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreferenceSettings extends StatefulWidget {
  const _PreferenceSettings();

  @override
  State<_PreferenceSettings> createState() => _PreferenceSettingsState();
}

class _PreferenceSettingsState extends State<_PreferenceSettings> {
  var proactiveMessaging = true;
  var circlePublishing = true;

  @override
  Widget build(BuildContext context) {
    return HaloSettingsGroup(
      children: [
        HaloSettingsRow(
          label: '主动消息',
          trailing: HaloSwitch(
            value: proactiveMessaging,
            semanticLabel: '主动消息',
            onChanged: (value) => setState(() => proactiveMessaging = value),
          ),
        ),
        HaloSettingsRow(
          label: '允许发布到圈层',
          trailing: HaloSwitch(
            value: circlePublishing,
            semanticLabel: '允许发布到圈层',
            onChanged: (value) => setState(() => circlePublishing = value),
          ),
        ),
        HaloSettingsRow(label: '添加到群聊', onTap: () {}),
      ],
    );
  }
}

/// Real catalog facts for an executable expert: description, skill tags and
/// the tool policy. The model row is intentionally absent — the 模型 settings
/// row resolves the true binding, and inventing one here would contradict it.
class _CatalogDetailSections extends StatelessWidget {
  const _CatalogDetailSections({
    required this.catalog,
    required this.showDescription,
  });

  final ExpertProfile catalog;
  final bool showDescription;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showDescription) ...[
            const HaloSectionLabel('专家简介'),
            Text(catalog.description, style: HaloTextStyles.body),
          ],
          const HaloSectionLabel('技能'),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final capability in catalog.routingCard.capabilities)
                _SkillChip(capability),
            ],
          ),
          const HaloSectionLabel('工具权限'),
          Text(
            _toolPolicySummary(catalog.toolPolicy),
            style: HaloTextStyles.body,
          ),
        ],
      ),
    );
  }

  static String _toolPolicySummary(ToolPolicy policy) {
    final approvalRequired = policy.approvalRequiredTools.toSet();
    final allowed = policy.allowedTools
        .map((tool) => approvalRequired.contains(tool) ? '$tool「需授权」' : tool)
        .join('、');
    final deniedNote = policy.deniedTools.isEmpty
        ? ''
        : '；另有 ${policy.deniedTools.length} 项敏感工具已禁用';
    return '可用工具：$allowed$deniedNote。';
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

class _AbilityGrid extends StatelessWidget {
  const _AbilityGrid();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 15),
      child: Row(
        children: [
          Expanded(child: _Ability('合同', '专业处理')),
          SizedBox(width: 8),
          Expanded(child: _Ability('风险', '证据标注')),
          SizedBox(width: 8),
          Expanded(child: _Ability('修订', '逐条建议')),
        ],
      ),
    );
  }
}

class _Ability extends StatelessWidget {
  const _Ability(this.title, this.detail);
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(title, style: HaloTextStyles.rowTitle),
          const SizedBox(height: 4),
          Text(detail, style: HaloTextStyles.caption),
        ],
      ),
    );
  }
}

class _MarketBottomBar extends StatelessWidget {
  const _MarketBottomBar({required this.name});
  final String name;

  /// Tight horizontal padding plus a slightly smaller label keeps all three
  /// actions on a single line on narrow phones.
  static final _buttonStyle = ButtonStyle(
    padding: WidgetStateProperty.all(
      const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
    ),
    textStyle: WidgetStateProperty.all(
      const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: HaloColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {},
                  style: _buttonStyle,
                  child: const _BarButtonLabel('先聊聊'),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {},
                  style: _buttonStyle,
                  child: const _BarButtonLabel('添加到群聊'),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: FilledButton(
                  onPressed: () {},
                  style: _buttonStyle,
                  child: const _BarButtonLabel('添加到专家团'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single-line, scale-down label so no bottom-bar action ever wraps.
class _BarButtonLabel extends StatelessWidget {
  const _BarButtonLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(label, maxLines: 1, softWrap: false),
    );
  }
}
