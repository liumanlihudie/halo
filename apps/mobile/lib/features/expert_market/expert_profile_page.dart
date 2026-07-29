import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

class ExpertProfilePage extends StatelessWidget {
  const ExpertProfilePage({
    required this.expertId,
    this.marketMode = false,
    super.key,
  });
  final String expertId;
  final bool marketMode;

  @override
  Widget build(BuildContext context) {
    final installed = HaloFixtures.installedExperts
        .where((expert) => expert.id == expertId)
        .firstOrNull;
    final market = HaloFixtures.marketExperts
        .where((expert) => expert.id == expertId)
        .firstOrNull;
    final name = installed?.name ?? market?.name ?? '合同审阅助手';
    final model =
        installed?.model ?? market?.model ?? 'Anthropic / claude-sonnet-4';
    final description =
        market?.description ?? '你的个人工作协调者。理解需求，安排最合适的 Agent，并把过程整理成最终结果。';

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
          _ProfileHero(name: name, model: model),
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 12, 15, 13),
            child: Text(description, style: HaloTextStyles.body),
          ),
          if (marketMode) ...[
            const _AbilityGrid(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 15),
              child: HaloSectionLabel('模型与用量'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Text(
                '$model · BYOK · 按服务商账单结算',
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
            HaloSettingsGroup(
              children: [
                HaloSettingsRow(
                  label: '发消息',
                  prototypeIconClass: 'ph ph-chat-circle-dots',
                  onTap: () => context.push('/chat/general-assistant'),
                ),
                HaloSettingsRow(
                  label: '语音通话',
                  detail: '端到端双工',
                  prototypeIconClass: 'ph ph-phone',
                  onTap: () {},
                ),
                HaloSettingsRow(
                  label: '视频通话',
                  detail: 'Vidu',
                  prototypeIconClass: 'ph ph-video-camera',
                  onTap: () {},
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 15),
              child: HaloSectionLabel('专家与动态'),
            ),
            HaloSettingsGroup(
              children: [
                HaloSettingsRow(
                  label: '专家数据',
                  detail: '提示词、模型、工具与权限',
                  prototypeIconClass: 'ph ph-database',
                  onTap: () => context.push('/expert/$expertId/data'),
                ),
                HaloSettingsRow(
                  label: '当前状态',
                  detail: '可用 · 最近活动',
                  prototypeIconClass: 'ph ph-pulse',
                  onTap: () {},
                ),
                HaloSettingsRow(
                  label: '最近圈层动态',
                  detail: '3 条 · 刚刚',
                  prototypeIconClass: 'ph ph-circles-three',
                  onTap: () {},
                ),
              ],
            ),
          ],
        ],
      ),
      bottom: marketMode ? _MarketBottomBar(name: name) : null,
    );
  }
}

class _ProfileHero extends StatelessWidget {
  const _ProfileHero({required this.name, required this.model});
  final String name;
  final String model;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      color: HaloColors.navy,
      child: Row(
        children: [
          HaloAvatar(letter: name.characters.first, size: 72),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  model,
                  style: const TextStyle(
                    color: Color(0xFFC5CADB),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
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
                  child: const Text('先聊聊'),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {},
                  child: const Text('添加到群聊'),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: FilledButton(
                  onPressed: () {},
                  child: const Text('添加到专家团'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
