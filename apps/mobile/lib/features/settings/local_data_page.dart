import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/features/settings/local_data_maintenance.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

/// Hands a finished export bundle to the platform share sheet.
typedef LocalDataExportSharer =
    Future<void> Function(LocalDataExportBundle bundle);

class LocalDataPage extends StatefulWidget {
  const LocalDataPage({this.maintenance, this.shareExport, super.key});

  /// Absent when the storage kernel failed to boot; every action then stays
  /// disabled rather than pretending to work.
  final LocalDataMaintenancePort? maintenance;

  /// Injectable so tests never open a real share sheet.
  final LocalDataExportSharer? shareExport;

  @override
  State<LocalDataPage> createState() => _LocalDataPageState();
}

class _LocalDataPageState extends State<LocalDataPage> {
  LocalDataSnapshot? _snapshot;
  var _snapshotFailed = false;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSnapshot());
  }

  Future<void> _loadSnapshot() async {
    final maintenance = widget.maintenance;
    if (maintenance == null) {
      if (mounted) setState(() => _snapshotFailed = true);
      return;
    }
    try {
      final snapshot = await maintenance.loadSnapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _snapshotFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _snapshotFailed = true);
    }
  }

  /// Serializes the three destructive-ish actions so a second tap during an
  /// in-flight export or erase cannot interleave two writers on the same
  /// storage.
  Future<void> _runExclusive(Future<String> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    String message;
    try {
      message = await action();
    } catch (_) {
      message = '操作失败，请稍后再试';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    await _loadSnapshot();
  }

  Future<void> _clearCache() {
    final maintenance = widget.maintenance;
    if (maintenance == null) return Future<void>.value();
    return _runExclusive(() async {
      final freed = await maintenance.clearCache();
      return freed == 0 ? '没有可清理的缓存' : '已清理 ${formatLocalDataBytes(freed)} 缓存';
    });
  }

  Future<void> _export() {
    final maintenance = widget.maintenance;
    final share = widget.shareExport;
    if (maintenance == null || share == null) return Future<void>.value();
    return _runExclusive(() async {
      final bundle = await maintenance.exportBundle();
      await share(bundle);
      return '已导出 ${formatLocalDataBytes(bundle.byteCount)} 数据包';
    });
  }

  Future<void> _erase() async {
    final maintenance = widget.maintenance;
    if (maintenance == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除本机对话数据'),
        content: const Text(
          '将删除本机保存的全部对话消息，且无法撤销。\n\n'
          '模型密钥与服务配置不受影响，联系人列表也会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: HaloColors.red),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runExclusive(() async {
      await maintenance.eraseLocalData();
      return '本机对话数据已清除';
    });
  }

  String _metric(int? value) {
    if (widget.maintenance == null) return '不可用';
    if (_snapshotFailed) return '无法读取';
    if (_snapshot == null) return '统计中';
    return value == null ? '—' : '$value';
  }

  String _bytesMetric(int? value) {
    if (widget.maintenance == null) return '不可用';
    if (_snapshotFailed) return '无法读取';
    if (_snapshot == null) return '统计中';
    return value == null ? '—' : formatLocalDataBytes(value);
  }

  @override
  Widget build(BuildContext context) {
    final maintenance = widget.maintenance;
    final snapshot = _snapshot;
    final canAct = maintenance != null && !_busy;
    final cacheBytes = snapshot?.cacheBytes;
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
              Expanded(
                child: _Metric(_bytesMetric(snapshot?.storageBytes), '本地文件'),
              ),
              Expanded(child: _Metric(_metric(snapshot?.messageCount), '消息')),
              Expanded(
                child: _Metric(_metric(snapshot?.conversationCount), '会话'),
              ),
            ],
          ),
          const HaloSectionLabel('迁移与备份'),
          HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '导出数据包',
                detail: canAct && widget.shareExport != null
                    ? '导出对话记录 JSON 并分享'
                    : '不可用',
                prototypeIconClass: 'ph ph-export',
                onTap: canAct && widget.shareExport != null ? _export : null,
              ),
              // Import needs a merge strategy for conversations that already
              // exist locally; shipping a button before that decision exists
              // would risk silently overwriting history.
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
                        '导出包只含对话记录；密钥与服务配置需在新设备上重新配置，避免备份文件泄露长期凭证。',
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
                detail: cacheBytes == null
                    ? _bytesMetric(cacheBytes)
                    : '可释放 ${formatLocalDataBytes(cacheBytes)}',
                prototypeIconClass: 'ph ph-broom',
                onTap: canAct ? _clearCache : null,
              ),
            ],
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: canAct ? _erase : null,
            style: OutlinedButton.styleFrom(foregroundColor: HaloColors.red),
            child: const Text('清除本机数据'),
          ),
          const SizedBox(height: 5),
          Text(
            maintenance == null
                ? '本机存储当前不可用，导出、清理与清除均已停用。'
                : '清除只删除本机对话消息，不会删除 Keychain 中的模型密钥，也不会删除联系人。',
            textAlign: TextAlign.center,
            style: const TextStyle(
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
