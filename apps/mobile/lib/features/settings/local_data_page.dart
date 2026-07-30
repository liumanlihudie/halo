import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:path_provider/path_provider.dart';

/// Bytes actually occupied by the app's own storage directory.
typedef LocalDataUsageLoader = Future<int> Function();

class LocalDataPage extends StatefulWidget {
  const LocalDataPage({this.usageLoader, super.key});

  /// Injectable so tests do not touch the real application support directory.
  final LocalDataUsageLoader? usageLoader;

  @override
  State<LocalDataPage> createState() => _LocalDataPageState();
}

class _LocalDataPageState extends State<LocalDataPage> {
  int? _usedBytes;
  var _usageFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadUsage());
  }

  Future<void> _loadUsage() async {
    try {
      final bytes = await (widget.usageLoader ?? _measureSupportDirectory)();
      if (!mounted) return;
      setState(() => _usedBytes = bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() => _usageFailed = true);
    }
  }

  String get _usageLabel {
    if (_usageFailed) return '无法读取';
    final bytes = _usedBytes;
    if (bytes == null) return '统计中';
    return _formatBytes(bytes);
  }

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
          Row(
            children: [
              Expanded(child: _Metric(_usageLabel, '本地文件')),
              // Message and memory counters are not implemented yet; showing a
              // number here would be inventing one.
              const Expanded(child: _Metric('—', '消息')),
              const Expanded(child: _Metric('—', '记忆')),
            ],
          ),
          const HaloSectionLabel('迁移与备份'),
          HaloSettingsGroup(
            children: [
              const HaloSettingsRow(
                label: '导出数据包',
                detail: '尚未开放',
                prototypeIconClass: 'ph ph-export',
              ),
              const HaloSettingsRow(
                label: '导入数据包',
                detail: '尚未开放',
                prototypeIconClass: 'ph ph-download-simple',
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
              const HaloSettingsRow(
                label: '清理缓存',
                detail: '尚未开放',
                prototypeIconClass: 'ph ph-broom',
              ),
            ],
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            // Destructive and irreversible: it must do nothing visible rather
            // than look armed while being a no-op.
            onPressed: null,
            style: OutlinedButton.styleFrom(foregroundColor: HaloColors.red),
            child: const Text('清除本机数据'),
          ),
          const SizedBox(height: 5),
          const Text(
            '导出、导入、清理缓存与清除数据尚未实现，因此这些操作当前不可用。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 9, color: HaloColors.muted),
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

Future<int> _measureSupportDirectory() async {
  final directory = await getApplicationSupportDirectory();
  if (!directory.existsSync()) return 0;
  var total = 0;
  await for (final entity in directory.list(recursive: true)) {
    if (entity is File) total += await entity.length();
  }
  return total;
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final rendered = unit == 0 || value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$rendered ${units[unit]}';
}
