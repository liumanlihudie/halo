import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class LocalDataPage extends StatelessWidget {
  const LocalDataPage({super.key});

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '本地数据与备份',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(15, 10, 15, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: HaloColors.navy,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Column(
              children: [
                Icon(
                  HaloIcon.requirePrototypeClass('ph ph-device-mobile'),
                  color: Colors.white,
                  size: 34,
                ),
                const SizedBox(height: 8),
                const Text(
                  '数据默认保存在本机',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                const Text(
                  'SQLite 保存对话、Agent、记忆与索引；图片和文件保存在 App 沙盒。没有 Halo 账号，也没有强制云同步。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFFC5CADB),
                    fontSize: 10,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Row(
            children: [
              Expanded(child: _Metric('2.8 GB', '本地文件')),
              Expanded(child: _Metric('12,460', '消息')),
              Expanded(child: _Metric('128', '记忆')),
            ],
          ),
          const HaloSectionLabel('迁移与备份'),
          HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '导出数据包',
                detail: 'JSON + 文件',
                prototypeIconClass: 'ph ph-export',
                onTap: () {},
              ),
              HaloSettingsRow(
                label: '导入数据包',
                detail: '从其他设备恢复',
                prototypeIconClass: 'ph ph-download-simple',
                onTap: () {},
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: HaloColors.accentSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  HaloIcon.requirePrototypeClass('ph ph-key'),
                  color: HaloColors.accentDeep,
                  size: 21,
                ),
                const SizedBox(width: 9),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'API Key 不进入导出包',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: HaloColors.accentDeep,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '密钥需在新设备上重新配置，避免备份文件泄露长期凭证。',
                        style: TextStyle(
                          fontSize: 9,
                          height: 1.45,
                          color: HaloColors.accentDeep,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const HaloSectionLabel('存储管理'),
          HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '清理缓存',
                detail: '486 MB',
                prototypeIconClass: 'ph ph-broom',
                onTap: () {},
              ),
            ],
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: () {},
            style: OutlinedButton.styleFrom(foregroundColor: HaloColors.red),
            child: const Text('清除本机数据'),
          ),
          const SizedBox(height: 5),
          const Text(
            '该操作会删除本机对话、Agent、记忆和附件，但不会删除 Keychain 中的模型密钥。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 9,
              color: HaloColors.muted,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.value, this.label);
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          Text(label, style: HaloTextStyles.caption),
        ],
      ),
    );
  }
}
