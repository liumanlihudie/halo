import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class SelfHostedGatewayPage extends StatelessWidget {
  const SelfHostedGatewayPage({super.key});

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '自托管 Gateway',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/settings'),
      ),
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-question',
          semanticLabel: '帮助',
          onPressed: () {},
        ),
      ],
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
                  HaloIcon.requirePrototypeClass('ph ph-hard-drives'),
                  color: Colors.white,
                  size: 34,
                ),
                const SizedBox(height: 8),
                const Text(
                  '可选，不影响本地使用',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                const Text(
                  '在你自己的电脑或服务器运行开源 Gateway，为豆包端到端语音、Vidu 等服务签发临时凭证并隐藏长期密钥。',
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
          const SizedBox(height: 14),
          const _GatewayField(
            label: 'Gateway 地址',
            hint: 'https://halo.example.com',
            icon: 'ph ph-globe',
          ),
          const _GatewayField(
            label: '访问令牌（可选）',
            hint: '仅供你自己的 Gateway 校验',
            icon: 'ph ph-lock-key',
            obscure: true,
          ),
          const Text(
            '令牌同样保存在 iOS Keychain',
            style: TextStyle(fontSize: 9, color: HaloColors.green),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: () {}, child: const Text('测试 Gateway')),
          FilledButton(onPressed: () {}, child: const Text('保存配置')),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      HaloIcon.requirePrototypeClass('ph ph-terminal-window'),
                      size: 18,
                    ),
                    const SizedBox(width: 7),
                    const Text('Docker 快速部署', style: HaloTextStyles.rowTitle),
                  ],
                ),
                const SizedBox(height: 9),
                const SelectableText(
                  'docker compose up -d',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                TextButton(onPressed: () {}, child: const Text('复制命令')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GatewayField extends StatelessWidget {
  const _GatewayField({
    required this.label,
    required this.hint,
    required this.icon,
    this.obscure = false,
  });
  final String label;
  final String hint;
  final String icon;
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
