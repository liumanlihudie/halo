import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({this.modelRouting, super.key});

  final ModelRoutingController? modelRouting;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  void initState() {
    super.initState();
    final routing = widget.modelRouting;
    if (routing != null) {
      routing.addListener(_refresh);
      routing.load().catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    widget.modelRouting?.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String get _defaultModelDetail {
    final routing = widget.modelRouting;
    if (routing == null) return '暂不可用';
    final ref = routing.globalDefault;
    if (ref == null) return '未设置';
    for (final option in routing.availableModels) {
      if (option.ref == ref) return option.modelName;
    }
    return ref.modelId;
  }

  @override
  Widget build(BuildContext context) {
    final routing = widget.modelRouting;
    final modelCount = routing?.availableModels.length;
    return HaloPageScaffold(
      title: '设置',
      backgroundColor: HaloColors.soft,
      body: ListView(
        key: const PageStorageKey('settings'),
        padding: const EdgeInsets.fromLTRB(15, 2, 15, 24),
        children: [
          _LocalProfileCard(
            agentCount: HaloFixtures.installedExperts.length,
            modelCount: modelCount,
            conversationCount: HaloFixtures.conversations.length,
          ),
          const HaloSectionLabel('模型服务'),
          HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '模型服务',
                detail: modelCount == null ? '配置与启停' : '$modelCount 个可用模型',
                prototypeIconClass: 'ph ph-cpu',
                onTap: () => context.push('/settings/providers'),
                trailing: const _Chevron(),
              ),
              HaloSettingsRow(
                label: '默认文字模型',
                detail: _defaultModelDetail,
                prototypeIconClass: 'ph ph-path',
                onTap: () => context.push('/settings/providers'),
                trailing: const _Chevron(),
              ),
            ],
          ),
          const HaloSectionLabel('自托管与本地数据'),
          HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '自托管 Gateway',
                detail: '可选 · 未配置',
                prototypeIconClass: 'ph ph-hard-drives',
                onTap: () => context.push('/settings/gateway'),
                trailing: const _Chevron(),
              ),
              HaloSettingsRow(
                label: '本地数据与备份',
                detail: '导出与清理尚未开放',
                prototypeIconClass: 'ph ph-database',
                onTap: () => context.push('/settings/local-data'),
                trailing: const _Chevron(),
              ),
            ],
          ),
          const HaloSectionLabel('规划中'),
          const HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '语音消息',
                detail: '设计已定稿 · 按计划最后实现',
                prototypeIconClass: 'ph ph-waveform',
              ),
              HaloSettingsRow(
                label: '记忆与个性化',
                detail: '规划中',
                prototypeIconClass: 'ph ph-brain',
              ),
              HaloSettingsRow(
                label: 'Face ID 保护',
                detail: '规划中',
                prototypeIconClass: 'ph ph-scan',
              ),
            ],
          ),
          const HaloSectionLabel('开源项目'),
          const HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: 'GitHub 项目',
                detail: '开源准备中，尚未发布',
                prototypeIconClass: 'ph ph-github-logo',
              ),
              HaloSettingsRow(
                label: '版本',
                detail: '1.0.0 (1)',
                prototypeIconClass: 'ph ph-info',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) {
    return Icon(
      HaloIcon.requirePrototypeClass('ph ph-caret-right'),
      size: 14,
      color: HaloColors.muted,
    );
  }
}

class _LocalProfileCard extends StatelessWidget {
  const _LocalProfileCard({
    required this.agentCount,
    required this.modelCount,
    required this.conversationCount,
  });

  final int agentCount;
  final int? modelCount;
  final int conversationCount;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: HaloColors.paper,
        borderRadius: BorderRadius.circular(HaloRadii.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          children: [
            const Row(
              children: [
                HaloAvatar(
                  letter: 'H',
                  size: 58,
                  backgroundColor: HaloColors.navy,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Halo 本地空间',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text('无账号 · 数据由你掌控', style: HaloTextStyles.secondary),
                      SizedBox(height: 3),
                      Text(
                        '对话、Agent 与记忆默认保存在这台设备',
                        style: HaloTextStyles.caption,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 13),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: HaloColors.accentSoft,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Text(
                '数据仅保存在本机  ·  可随时导出',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: HaloColors.accentDeep,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 13),
            Row(
              children: [
                Expanded(
                  child: _Stat(value: '$agentCount', label: '已添加 Agent'),
                ),
                Expanded(
                  child: _Stat(
                    value: modelCount == null ? '—' : '$modelCount',
                    label: '可用模型',
                  ),
                ),
                Expanded(
                  child: _Stat(value: '$conversationCount', label: '会话'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: HaloColors.ink,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: HaloTextStyles.caption),
      ],
    );
  }
}
