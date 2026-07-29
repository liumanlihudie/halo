import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '设置',
      backgroundColor: HaloColors.soft,
      body: ListView(
        key: const PageStorageKey('settings'),
        padding: const EdgeInsets.fromLTRB(15, 2, 15, 24),
        children: [
          const _LocalProfileCard(),
          for (final section in HaloFixtures.settings.entries) ...[
            HaloSectionLabel(section.key),
            HaloSettingsGroup(
              children: [
                for (final item in section.value)
                  HaloSettingsRow(
                    label: item.title,
                    detail: item.detail.isEmpty ? null : item.detail,
                    prototypeIconClass: item.iconClass,
                    onTap: () {
                      switch (item.title) {
                        case '模型服务':
                          context.push('/settings/providers');
                        case '自托管 Gateway':
                          context.push('/settings/gateway');
                        case '本地数据与备份':
                          context.push('/settings/local-data');
                      }
                    },
                    trailing: item.toggle == null
                        ? Icon(
                            HaloIcon.requirePrototypeClass('ph ph-caret-right'),
                            size: 14,
                            color: HaloColors.muted,
                          )
                        : Switch.adaptive(
                            value: item.toggle!,
                            onChanged: (_) {},
                            activeTrackColor: HaloColors.accent,
                          ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LocalProfileCard extends StatelessWidget {
  const _LocalProfileCard();

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
            Row(
              children: [
                const HaloAvatar(
                  letter: 'H',
                  size: 58,
                  backgroundColor: HaloColors.navy,
                ),
                const SizedBox(width: 12),
                const Expanded(
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
                Icon(
                  HaloIcon.requirePrototypeClass('ph ph-caret-right'),
                  size: 16,
                  color: HaloColors.muted,
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
            const Row(
              children: [
                Expanded(
                  child: _Stat(value: '9', label: '已添加 Agent'),
                ),
                Expanded(
                  child: _Stat(value: '5', label: '已配置模型'),
                ),
                Expanded(
                  child: _Stat(value: '128', label: '共享记忆'),
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
