import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class ModelProvidersPage extends StatelessWidget {
  const ModelProvidersPage({super.key});

  static const providers = <(String, String, String, String, HaloTagTone)>[
    (
      'toapis',
      'ToAPIs',
      '推荐聚合 · OpenAI-compatible · 多模态',
      '已连接 · 42 个模型',
      HaloTagTone.green,
    ),
    (
      'deepseek',
      'DeepSeek',
      '官方 API · 推理与通用文字',
      '已连接 · 4 个模型',
      HaloTagTone.green,
    ),
    ('openai', 'OpenAI', '官方 API · 文字与多模态', '未配置', HaloTagTone.gray),
    (
      'anthropic',
      'Anthropic Claude',
      '官方 API · Claude 系列',
      '已连接 · 6 个模型',
      HaloTagTone.green,
    ),
    ('gemini', 'Google Gemini', '官方 API · 文字与多模态', '连接异常', HaloTagTone.red),
    ('custom', '自定义 OpenAI-compatible', '任意兼容服务地址', '未配置', HaloTagTone.gray),
    (
      'local',
      '本地模型',
      'Ollama / LM Studio / vLLM',
      '服务离线 · 6 个模型',
      HaloTagTone.amber,
    ),
    ('doubao', '豆包端到端语音', '独立实时协议 · 一对一全双工', '已配置', HaloTagTone.green),
    ('vidu', 'Vidu', '视频生成与视频形象', '未配置', HaloTagTone.gray),
  ];

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '模型服务',
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
          const _PrivacyBanner(),
          const HaloSectionLabel('全局默认模型'),
          HaloSettingsGroup(
            children: [
              HaloSettingsRow(
                label: '默认文字模型',
                detail: 'Anthropic / claude-sonnet-4',
                prototypeIconClass: 'ph ph-chat-circle-text',
                onTap: () {},
              ),
              HaloSettingsRow(
                label: '默认图片模型',
                detail: 'ToAPIs / seedream-4',
                prototypeIconClass: 'ph ph-image',
                onTap: () {},
              ),
              HaloSettingsRow(
                label: '默认视频模型',
                detail: 'ToAPIs / vidu-q2',
                prototypeIconClass: 'ph ph-video-camera',
                onTap: () {},
              ),
              HaloSettingsRow(
                label: 'Router 模型',
                detail: 'DeepSeek / deepseek-chat',
                prototypeIconClass: 'ph ph-path',
                onTap: () {},
              ),
            ],
          ),
          const HaloSectionLabel('多个 Provider 可同时启用'),
          for (final provider in providers)
            _ProviderRow(
              id: provider.$1,
              name: provider.$2,
              kind: provider.$3,
              state: provider.$4,
              tone: provider.$5,
            ),
          const HaloSectionLabel('需要服务端能力？'),
          Material(
            color: HaloColors.navy,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: () => context.push('/settings/gateway'),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(
                      HaloIcon.requirePrototypeClass('ph ph-hard-drives'),
                      color: Colors.white,
                      size: 25,
                    ),
                    const SizedBox(width: 11),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '连接自托管 Gateway',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '处理临时凭证、签名和不适合直连的服务',
                            style: TextStyle(
                              color: Color(0xFFC5CADB),
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      HaloIcon.requirePrototypeClass('ph ph-caret-right'),
                      color: Colors.white,
                      size: 15,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacyBanner extends StatelessWidget {
  const _PrivacyBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: HaloColors.accentSoft,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Icon(
            HaloIcon.requirePrototypeClass('ph ph-key'),
            color: HaloColors.accentDeep,
            size: 24,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bring Your Own Key',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: HaloColors.accentDeep,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'API Key 只保存在本机 iOS Keychain，Halo 不设中转后台。',
                  style: TextStyle(
                    fontSize: 10,
                    color: HaloColors.accentDeep,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    required this.id,
    required this.name,
    required this.kind,
    required this.state,
    required this.tone,
  });
  final String id;
  final String name;
  final String kind;
  final String state;
  final HaloTagTone tone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          onTap: () => context.push('/settings/providers/$id'),
          borderRadius: BorderRadius.circular(13),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: HaloColors.accentSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    HaloIcon.requirePrototypeClass('ph ph-cpu'),
                    color: HaloColors.accentDeep,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: HaloTextStyles.rowTitle),
                      const SizedBox(height: 3),
                      Text(
                        kind,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HaloTextStyles.caption,
                      ),
                    ],
                  ),
                ),
                HaloTag(state, tone: tone),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
