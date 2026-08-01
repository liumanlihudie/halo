import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';

class ProviderDetailPage extends StatefulWidget {
  const ProviderDetailPage({
    required this.providerId,
    this.controller,
    super.key,
  });
  final String providerId;
  final ProviderSettingsController? controller;

  @override
  State<ProviderDetailPage> createState() => _ProviderDetailPageState();
}

class _ProviderDetailPageState extends State<ProviderDetailPage> {
  final _apiKeyController = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final controller = widget.controller;
    if (controller != null) {
      controller.addListener(_refresh);
      controller.load(widget.providerId).catchError((Object _) => null);
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_refresh);
    _apiKeyController.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final provider = ModelProviderInfo.fromId(widget.providerId);
    final controller = widget.controller;
    final supported = ProviderSettingsController.supportedProviderIds.contains(
      widget.providerId,
    );
    final configured =
        controller?.hasConfigurationFor(widget.providerId) ?? false;
    final snapshot = controller?.snapshotFor(widget.providerId);
    final catalog = snapshot?.catalog;
    final enabled = snapshot?.config.enabled ?? false;
    return HaloPageScaffold(
      title: '模型服务',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () => context.canPop()
            ? context.pop()
            : context.go('/settings/providers'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(15, 10, 15, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: HaloColors.accentSoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    HaloIcon.requirePrototypeClass('ph ph-cpu'),
                    color: HaloColors.accentDeep,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        provider.name,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(provider.kind, style: HaloTextStyles.caption),
                    ],
                  ),
                ),
                HaloTag(
                  configured ? (enabled ? '已启用' : '已停用') : '未配置',
                  tone: configured && enabled
                      ? HaloTagTone.green
                      : HaloTagTone.gray,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _Field(label: '服务地址', icon: 'ph ph-link', hint: provider.baseUrl),
          _Field(
            label: 'API Key',
            icon: 'ph ph-key',
            hint: '输入服务商 API Key',
            obscure: true,
            controller: _apiKeyController,
            onChanged: (_) => setState(() {}),
            suffixIcon: IconButton(
              tooltip: '粘贴 API Key',
              onPressed: _pasteApiKey,
              icon: Icon(HaloIcon.requirePrototypeClass('ph ph-copy')),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 11),
            child: Text(
              '  Key 只保存在本机 Keychain，不会写入聊天数据库',
              style: TextStyle(fontSize: 9, color: HaloColors.green),
            ),
          ),
          if (catalog != null)
            _CatalogCard(
              modelCount: catalog.models.length,
              discoveredAt: catalog.discoveredAt,
            ),
          _StateCard(
            icon: 'ph ph-info',
            text: _safeStatus(controller?.stateFor(widget.providerId)),
          ),
          const SizedBox(height: 9),
          OutlinedButton.icon(
            onPressed: controller == null || !configured || _busy
                ? null
                : _testConnection,
            icon: Icon(HaloIcon.requirePrototypeClass('ph ph-plugs-connected')),
            label: Text(
              _connectionLabel(
                controller?.connectionResultFor(widget.providerId),
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: controller == null || !configured || _busy
                ? null
                : _refreshCatalog,
            icon: Icon(
              HaloIcon.requirePrototypeClass('ph ph-arrows-clockwise'),
            ),
            label: const Text('刷新模型目录'),
          ),
          OutlinedButton.icon(
            onPressed: controller == null || !configured || _busy
                ? null
                : () => _setEnabled(!enabled),
            icon: Icon(HaloIcon.requirePrototypeClass('ph ph-power')),
            label: Text(enabled ? '停用此服务' : '启用此服务'),
          ),
          const SizedBox(height: 7),
          FilledButton(
            onPressed:
                controller == null ||
                    !supported ||
                    _busy ||
                    _apiKeyController.text.isEmpty
                ? null
                : _save,
            child: Text(_busy ? '正在验证并获取模型…' : '保存到本机'),
          ),
          TextButton(
            onPressed: controller == null || !configured || _busy
                ? null
                : _remove,
            child: const Text('移除此配置', style: TextStyle(color: HaloColors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.controller!.save(
        ProviderSettingsDraft(
          providerId: widget.providerId,
          apiKey: _apiKeyController.text,
          enabled: true,
        ),
      );
      _apiKeyController.clear();
    } on ProviderSettingsException {
      // The controller exposes only fixed safe state; secret/error details are
      // intentionally never reflected into the UI.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _busy = true);
    try {
      await widget.controller!.setEnabled(widget.providerId, enabled);
    } on ProviderSettingsException {
      // Only fixed safe controller state is reflected into the page.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshCatalog() async {
    setState(() => _busy = true);
    try {
      await widget.controller!.refreshCatalog(widget.providerId);
    } on ProviderSettingsException {
      // Only fixed safe controller state is reflected into the page.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    setState(() => _busy = true);
    try {
      await widget.controller!.testConnection(widget.providerId);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _connectionLabel(ProviderConnectionResult? result) => switch (result) {
    null || ProviderConnectionResult.untested => '测试连接',
    ProviderConnectionResult.testing => '正在测试连接…',
    ProviderConnectionResult.reachable => '连接正常',
    ProviderConnectionResult.notConfigured => '请先保存 Key',
    ProviderConnectionResult.authFailed => 'Key 无效，请检查',
    ProviderConnectionResult.quotaExceeded => '额度不足或受限',
    ProviderConnectionResult.unreachable => '连接失败，请重试',
  };

  Future<void> _pasteApiKey() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (!mounted) return;
      if (text == null || text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('剪贴板没有可粘贴文字；请开启模拟器“Automatically Sync Pasteboard”'),
          ),
        );
        return;
      }
      _apiKeyController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      setState(() {});
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('系统未允许读取剪贴板，请在系统设置中允许粘贴')));
    }
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      await widget.controller!.remove(widget.providerId);
    } on ProviderSettingsException {
      // Fixed state is rendered by the controller listener.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _safeStatus(ProviderSettingsState? state) => switch (state) {
    ProviderSettingsState.saving => '正在验证凭证并获取完整模型目录。',
    ProviderSettingsState.ready => '模型目录已保存在本机，可随时刷新。',
    ProviderSettingsState.idle => '保存 API Key 后将验证凭证并获取完整模型目录。',
    ProviderSettingsState.cleanupPending => '配置已生效；旧凭证正在等待安全清理。',
    ProviderSettingsState.recoveryPending => '配置恢复中，请稍后重试。',
    ProviderSettingsState.saveFailed => '保存失败；原配置仍然有效。',
    ProviderSettingsState.deleteFailed => '移除失败；原配置已恢复。',
    ProviderSettingsState.orphanedCredential => '安全存储需要清理；请稍后重试。',
    _ => '连接测试暂不可用。',
  };
}

class ModelProviderInfo {
  const ModelProviderInfo(this.name, this.kind, this.baseUrl);
  final String name;
  final String kind;
  final String baseUrl;

  static ModelProviderInfo fromId(String id) => switch (id) {
    'toapis' => const ModelProviderInfo(
      'ToAPIs',
      '推荐聚合 · OpenAI-compatible',
      'https://toapis.com/v1',
    ),
    'deepseek' => const ModelProviderInfo(
      'DeepSeek',
      '官方 API',
      'https://api.deepseek.com/v1',
    ),
    'anthropic' => const ModelProviderInfo(
      'Anthropic Claude',
      '官方 API',
      'https://api.anthropic.com',
    ),
    _ => const ModelProviderInfo(
      'OpenAI-compatible',
      '文字与多模态模型',
      'https://api.example.com/v1',
    ),
  };
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.icon,
    required this.hint,
    this.obscure = false,
    this.onChanged,
    this.controller,
    this.suffixIcon,
  });
  final String label;
  final String icon;
  final String hint;
  final bool obscure;
  final ValueChanged<String>? onChanged;
  final TextEditingController? controller;
  final Widget? suffixIcon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          TextField(
            obscureText: obscure,
            onChanged: onChanged,
            controller: controller,
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: Icon(HaloIcon.requirePrototypeClass(icon), size: 18),
              suffixIcon: suffixIcon,
              filled: true,
              fillColor: Colors.white,
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(11)),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({required this.icon, required this.text});
  final String icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          Icon(
            HaloIcon.requirePrototypeClass(icon),
            size: 17,
            color: HaloColors.muted,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: HaloTextStyles.caption)),
        ],
      ),
    );
  }
}

class _CatalogCard extends StatelessWidget {
  const _CatalogCard({required this.modelCount, required this.discoveredAt});

  final int modelCount;
  final DateTime discoveredAt;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          Icon(
            HaloIcon.requirePrototypeClass('ph ph-cube'),
            size: 17,
            color: HaloColors.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已获取 $modelCount 个模型',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '更新于 ${_formatCatalogTimestamp(discoveredAt)} UTC',
                  style: HaloTextStyles.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatCatalogTimestamp(DateTime value) {
  final utc = value.toUtc();
  String twoDigits(int part) => part.toString().padLeft(2, '0');
  return '${utc.year}-${twoDigits(utc.month)}-${twoDigits(utc.day)} '
      '${twoDigits(utc.hour)}:${twoDigits(utc.minute)}';
}
