import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/features/settings/service_credentials_controller.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

/// Keys for the services that are a key and nothing else.
///
/// There is no model picker here on purpose: none of these services publishes a
/// catalogue, so offering to choose a model would be inventing one.
class ServiceCredentialsPage extends StatefulWidget {
  const ServiceCredentialsPage({this.controller, super.key});

  /// Absent when the storage kernel failed to boot; every field then stays
  /// disabled rather than accepting a key it cannot store.
  final ServiceCredentialsController? controller;

  @override
  State<ServiceCredentialsPage> createState() => _ServiceCredentialsPageState();
}

class _ServiceCredentialsPageState extends State<ServiceCredentialsPage> {
  final _fields = {
    for (final service in KeyOnlyService.values)
      service: TextEditingController(),
  };

  /// The realtime dialogue needs three values, not one: App ID, App Key and
  /// Access Token. They are stored as a single joined secret so the schema
  /// stays as it is, but the user should see the three fields the console
  /// gives them.
  final _appId = TextEditingController();
  final _appKey = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_refresh);
    widget.controller?.load();
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_refresh);
    for (final field in _fields.values) {
      field.dispose();
    }
    _appId.dispose();
    _appKey.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  /// Joins the dialogue fields, leaving the App Key out when it is blank so
  /// the documented fixed value is used.
  String _joinDialogCredential() {
    final appId = _appId.text.trim();
    final appKey = _appKey.text.trim();
    final token = _fields[KeyOnlyService.doubaoRealtimeAudio]!.text.trim();
    if (appId.isEmpty || token.isEmpty) return '';
    return appKey.isEmpty ? '$appId:$token' : '$appId:$appKey:$token';
  }

  Future<void> _paste(KeyOnlyService service) async {
    try {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboard?.text;
      if (text == null || text.trim().isEmpty || !mounted) return;
      // The value goes straight into the field; nothing logs or inspects it.
      _fields[service]!.text = text.trim();
      setState(() {});
    } catch (_) {
      // A clipboard read can fail; the user can still type the key.
    }
  }

  Future<void> _save(KeyOnlyService service) async {
    final controller = widget.controller;
    if (controller == null) return;
    final value = service == KeyOnlyService.doubaoRealtimeAudio
        ? _joinDialogCredential()
        : _fields[service]!.text;
    final saved = await controller.save(service, value);
    if (!mounted) return;
    if (saved) {
      // Cleared on success so the key does not linger in a widget the user can
      // reveal, and so the row reflects storage rather than the text field.
      _fields[service]!.clear();
    }
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(saved ? '${service.displayName} 已保存' : '保存失败')),
    );
  }

  Future<void> _remove(KeyOnlyService service) async {
    final controller = widget.controller;
    if (controller == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('移除 ${service.displayName} 的 Key'),
        content: Text('将从本机 Keychain 删除这把 Key，${service.purpose}将不可用。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: HaloColors.red),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final removed = await controller.remove(service);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(removed ? '已移除' : '移除失败')));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return HaloPageScaffold(
      title: '语音与通话 Key',
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
                  child: Text(
                    '这些服务只需要一把 Key，没有模型目录可选。'
                    'Key 只保存在本机 Keychain，不写入聊天数据库，也不进导出包。',
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.5,
                      color: HaloColors.accentDeep,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (controller == null)
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: Text(
                '本机存储当前不可用，无法保存 Key。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: HaloColors.muted),
              ),
            ),
          for (final service in KeyOnlyService.values)
            _ServiceCard(
              service: service,
              status:
                  controller?.statusFor(service) ??
                  ServiceCredentialStatus.absent,
              field: _fields[service]!,
              appId: service == KeyOnlyService.doubaoRealtimeAudio
                  ? _appId
                  : null,
              appKey: service == KeyOnlyService.doubaoRealtimeAudio
                  ? _appKey
                  : null,
              busy: controller?.busy ?? false,
              enabled: controller != null,
              onPaste: () => _paste(service),
              onSave: () => _save(service),
              onRemove: () => _remove(service),
              onChanged: (_) => setState(() {}),
            ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.service,
    required this.status,
    required this.field,
    required this.busy,
    this.appId,
    this.appKey,
    required this.enabled,
    required this.onPaste,
    required this.onSave,
    required this.onRemove,
    required this.onChanged,
  });

  final KeyOnlyService service;
  final ServiceCredentialStatus status;
  final TextEditingController field;

  /// Present only for the realtime dialogue, which authenticates with three
  /// values instead of one.
  final TextEditingController? appId;
  final TextEditingController? appKey;
  final bool busy;
  final bool enabled;
  final VoidCallback onPaste;
  final VoidCallback onSave;
  final VoidCallback onRemove;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final canSave = enabled && !busy && field.text.trim().isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: HaloColors.paper,
        borderRadius: BorderRadius.circular(HaloRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  service.displayName,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              HaloTag(
                // A key that cannot be read back is worse than none: the page
                // used to say 已配置 while every feature reported 尚未配置.
                status.unreadable
                    ? '需重新填写'
                    : (status.configured ? '已配置' : '未配置'),
                tone: status.unreadable
                    ? HaloTagTone.red
                    : (status.configured
                          ? HaloTagTone.green
                          : HaloTagTone.gray),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(service.purpose, style: HaloTextStyles.caption),
          const SizedBox(height: 10),
          if (appId case final appIdField?) ...[
            TextField(
              controller: appIdField,
              enabled: enabled && !busy,
              onChanged: onChanged,
              decoration: const InputDecoration(
                hintText: 'App ID（控制台应用管理）',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: appKey!,
              enabled: enabled && !busy,
              onChanged: onChanged,
              decoration: const InputDecoration(
                hintText: 'App Key（留空则用官方固定值）',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: field,
            obscureText: true,
            enabled: enabled && !busy,
            onChanged: onChanged,
            decoration: InputDecoration(
              // Never the stored key: it is not readable back by design, and a
              // masked placeholder would only imply it could be.
              hintText: appId != null
                  ? (status.configured
                        ? '输入新的 Access Token 以替换'
                        : 'Access Token')
                  : (status.configured ? '输入新的 Key 以替换' : '输入 API Key'),
              prefixIcon: Icon(
                HaloIcon.requirePrototypeClass('ph ph-key'),
                size: 18,
              ),
              suffixIcon: IconButton(
                tooltip: '粘贴',
                onPressed: enabled && !busy ? onPaste : null,
                icon: Icon(HaloIcon.requirePrototypeClass('ph ph-copy')),
              ),
              filled: true,
              fillColor: Colors.white,
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(11)),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: canSave ? onSave : null,
                  child: Text(busy ? '正在保存…' : '保存到本机'),
                ),
              ),
              if (status.configured) ...[
                const SizedBox(width: 9),
                TextButton(
                  onPressed: enabled && !busy ? onRemove : null,
                  style: TextButton.styleFrom(foregroundColor: HaloColors.red),
                  child: const Text('移除'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
