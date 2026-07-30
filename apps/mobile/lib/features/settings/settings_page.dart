import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/settings/app_lock.dart';
import 'package:halo_mobile/features/settings/local_data_maintenance.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Reads the running build's version so the row cannot drift from the binary.
typedef AppVersionLoader = Future<PackageInfo> Function();

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    this.modelRouting,
    this.appLock,
    this.localData,
    this.versionLoader,
    super.key,
  });

  final ModelRoutingController? modelRouting;

  /// Absent when the platform biometric prompt is unavailable.
  final AppLockController? appLock;

  /// Absent when storage failed to boot; the counters then show `—`.
  final LocalDataMaintenancePort? localData;

  /// Injectable so tests do not need the platform channel.
  final AppVersionLoader? versionLoader;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  LocalDataSnapshot? _snapshot;
  String? _version;

  @override
  void initState() {
    super.initState();
    final routing = widget.modelRouting;
    if (routing != null) {
      routing.addListener(_refresh);
      routing.load().catchError((Object _) {});
    }
    widget.appLock?.addListener(_refresh);
    unawaited(_loadSnapshot());
    unawaited(_loadVersion());
  }

  Future<void> _loadSnapshot() async {
    final localData = widget.localData;
    if (localData == null) return;
    try {
      final snapshot = await localData.loadSnapshot();
      if (mounted) setState(() => _snapshot = snapshot);
    } catch (_) {
      // Leaves the counters at `—` rather than inventing one.
    }
  }

  Future<void> _loadVersion() async {
    try {
      final info = await (widget.versionLoader ?? PackageInfo.fromPlatform)();
      if (mounted) {
        setState(() => _version = '${info.version} (${info.buildNumber})');
      }
    } catch (_) {
      // Falls back to the honest placeholder below.
    }
  }

  @override
  void dispose() {
    widget.appLock?.removeListener(_refresh);
    widget.modelRouting?.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  /// The copy never implies encryption: the lock gates the UI, not the files.
  String get _appLockDetail {
    final lock = widget.appLock;
    if (lock == null) return '本机不可用';
    if (lock.authenticating) return '正在验证…';
    return switch (lock.availability) {
      AppLockAvailability.unavailable => '请先在系统设置里启用 Face ID 或密码',
      AppLockAvailability.unknown => '本机无法验证 Face ID',
      AppLockAvailability.available =>
        lock.enabled ? '打开 App 时需要验证 · 不加密本机数据' : '关闭 · 打开 App 时不验证',
    };
  }

  bool get _appLockSwitchEnabled {
    final lock = widget.appLock;
    if (lock == null || lock.authenticating) return false;
    // A user who already turned it on must always be able to turn it off, even
    // if the device later reports the sensor as unavailable.
    return lock.enabled || lock.availability == AppLockAvailability.available;
  }

  Future<void> _toggleAppLock(bool value) async {
    final lock = widget.appLock;
    if (lock == null) return;
    final changed = await lock.setEnabled(value);
    if (!changed && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('验证未通过，设置未更改')));
    }
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
            agentCount:
                ExecutableExpertRegistry.installedExpertIdentities.length,
            modelCount: modelCount,
            conversationCount: _snapshot?.conversationCount,
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
          const HaloSectionLabel('语音与通话'),
          HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '语音与通话 Key',
                detail: '豆包语音 · 端到端音频 · Vidu',
                prototypeIconClass: 'ph ph-key',
                onTap: () => context.push('/settings/service-keys'),
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
                detail: '导出、清理与清除',
                prototypeIconClass: 'ph ph-database',
                onTap: () => context.push('/settings/local-data'),
                trailing: const _Chevron(),
              ),
            ],
          ),
          const HaloSectionLabel('隐私保护'),
          HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: 'Face ID 保护',
                detail: _appLockDetail,
                prototypeIconClass: 'ph ph-scan',
                trailing: Switch.adaptive(
                  value: widget.appLock?.enabled ?? false,
                  onChanged: _appLockSwitchEnabled ? _toggleAppLock : null,
                ),
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
            ],
          ),
          const HaloSectionLabel('开源项目'),
          HaloSettingsGroup(
            children: [
              const HaloSettingsRow(
                label: 'GitHub 项目',
                detail: '开源准备中，尚未发布',
                prototypeIconClass: 'ph ph-github-logo',
              ),
              HaloSettingsRow(
                label: '版本',
                detail: _version ?? '读取中',
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
  final int? conversationCount;

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
                  child: _Stat(
                    value: conversationCount == null
                        ? '—'
                        : '$conversationCount',
                    label: '会话',
                  ),
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
