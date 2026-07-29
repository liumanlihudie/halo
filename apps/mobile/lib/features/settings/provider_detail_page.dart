import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class ProviderDetailPage extends StatelessWidget {
  const ProviderDetailPage({required this.providerId, super.key});
  final String providerId;

  @override
  Widget build(BuildContext context) {
    final provider = ModelProviderInfo.fromId(providerId);
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
                const HaloTag('已配置', tone: HaloTagTone.green),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _Field(label: '服务地址', icon: 'ph ph-link', hint: provider.baseUrl),
          const _Field(
            label: 'API Key',
            icon: 'ph ph-key',
            hint: '输入服务商 API Key',
            obscure: true,
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 11),
            child: Text(
              '  Key 只保存在本机 Keychain，不会写入聊天数据库',
              style: TextStyle(fontSize: 9, color: HaloColors.green),
            ),
          ),
          _Field(label: '默认模型 ID', icon: 'ph ph-cube', hint: provider.model),
          const _StateCard(icon: 'ph ph-info', text: '保存前可以先测试连接，不会发送对话内容。'),
          const SizedBox(height: 9),
          OutlinedButton.icon(
            onPressed: () {},
            icon: Icon(HaloIcon.requirePrototypeClass('ph ph-plugs-connected')),
            label: const Text('测试连接'),
          ),
          OutlinedButton.icon(
            onPressed: () {},
            icon: Icon(
              HaloIcon.requirePrototypeClass('ph ph-arrows-clockwise'),
            ),
            label: const Text('刷新模型目录'),
          ),
          OutlinedButton.icon(
            onPressed: () {},
            icon: Icon(HaloIcon.requirePrototypeClass('ph ph-power')),
            label: const Text('启用或禁用 Provider'),
          ),
          const SizedBox(height: 7),
          FilledButton(onPressed: () {}, child: const Text('保存到本机')),
          TextButton(
            onPressed: () {},
            child: const Text('移除此配置', style: TextStyle(color: HaloColors.red)),
          ),
        ],
      ),
    );
  }
}

class ModelProviderInfo {
  const ModelProviderInfo(this.name, this.kind, this.baseUrl, this.model);
  final String name;
  final String kind;
  final String baseUrl;
  final String model;

  static ModelProviderInfo fromId(String id) => switch (id) {
    'toapis' => const ModelProviderInfo(
      'ToAPIs',
      '推荐聚合 · OpenAI-compatible',
      'https://api.toapis.com/v1',
      'gpt-5-mini',
    ),
    'deepseek' => const ModelProviderInfo(
      'DeepSeek',
      '官方 API',
      'https://api.deepseek.com/v1',
      'deepseek-chat',
    ),
    'anthropic' => const ModelProviderInfo(
      'Anthropic Claude',
      '官方 API',
      'https://api.anthropic.com',
      'claude-sonnet-4',
    ),
    _ => const ModelProviderInfo(
      'OpenAI-compatible',
      '文字与多模态模型',
      'https://api.example.com/v1',
      'gpt-5.4',
    ),
  };
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.icon,
    required this.hint,
    this.obscure = false,
  });
  final String label;
  final String icon;
  final String hint;
  final bool obscure;

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
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: Icon(HaloIcon.requirePrototypeClass(icon), size: 18),
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
