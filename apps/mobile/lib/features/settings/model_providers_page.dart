import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/features/settings/model_picker_sheet.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';

class ModelProvidersPage extends StatefulWidget {
  const ModelProvidersPage({
    this.controller,
    this.routingController,
    super.key,
  });

  final ProviderSettingsController? controller;
  final ModelRoutingController? routingController;

  static const providers = <(String, String, String, bool)>[
    ('toapis', 'ToAPIs', '推荐聚合 · OpenAI-compatible · 多模态', true),
    ('deepseek', 'DeepSeek', '官方 API · 推理与通用文字', true),
    ('openai', 'OpenAI', '官方 API · 文字与多模态', false),
    ('anthropic', 'Anthropic Claude', '官方 API · Claude 系列', false),
    ('gemini', 'Google Gemini', '官方 API · 文字与多模态', false),
    ('custom', '自定义 OpenAI-compatible', '任意兼容服务地址', false),
    ('local', '本地模型', 'Ollama / LM Studio / vLLM', false),
    ('doubao', '豆包端到端语音', '独立实时协议 · 一对一全双工', false),
    ('vidu', 'Vidu', '视频生成与视频形象', false),
  ];

  @override
  State<ModelProvidersPage> createState() => _ModelProvidersPageState();
}

class _ModelProvidersPageState extends State<ModelProvidersPage> {
  @override
  void initState() {
    super.initState();
    _loadSupported();
    _loadRouting();
  }

  @override
  void didUpdateWidget(ModelProvidersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) _loadSupported();
    if (oldWidget.routingController != widget.routingController) {
      _loadRouting();
    }
  }

  void _loadSupported() {
    final controller = widget.controller;
    if (controller == null) return;
    for (final providerId in const ['toapis', 'deepseek']) {
      controller.load(providerId).catchError((Object _) => null);
    }
  }

  void _loadRouting() {
    widget.routingController?.load().catchError((Object _) => null);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final routingController = widget.routingController;
    if (routingController != null) {
      return AnimatedBuilder(
        animation: routingController,
        builder: (context, _) => _buildWithProviderController(controller),
      );
    }
    return _buildWithProviderController(controller);
  }

  Widget _buildWithProviderController(ProviderSettingsController? controller) {
    if (controller != null) {
      return AnimatedBuilder(
        animation: controller,
        builder: (context, _) => _buildPage(context, controller),
      );
    }
    return _buildPage(context, null);
  }

  Widget _buildPage(
    BuildContext context,
    ProviderSettingsController? controller,
  ) {
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
                detail: _globalModelDetail(),
                prototypeIconClass: 'ph ph-chat-circle-text',
                onTap: widget.routingController == null
                    ? null
                    : _chooseGlobalModel,
              ),
              HaloSettingsRow(
                label: '默认图片模型',
                detail: '尚未配置',
                prototypeIconClass: 'ph ph-image',
                onTap: () {},
              ),
              HaloSettingsRow(
                label: '默认视频模型',
                detail: '尚未配置',
                prototypeIconClass: 'ph ph-video-camera',
                onTap: () {},
              ),
              // A "Router 模型" row used to sit here. No document ever defined
              // its behaviour, and model choice is already resolved by
              // `override ?? globalDefault` per expert — predictably and with
              // no extra model call. A second routing layer would only
              // contradict that, so the empty row is gone rather than left
              // looking configurable.
            ],
          ),
          const HaloSectionLabel('多个 Provider 可同时启用'),
          for (final provider in ModelProvidersPage.providers)
            _ProviderRow(
              id: provider.$1,
              name: provider.$2,
              kind: provider.$3,
              state: _providerState(controller, provider.$1, provider.$4),
              tone:
                  provider.$4 &&
                      (controller?.hasConfigurationFor(provider.$1) ?? false)
                  ? HaloTagTone.green
                  : HaloTagTone.gray,
              enabled: provider.$4,
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

  String _globalModelDetail() {
    final routing = widget.routingController;
    final option = routing?.optionFor(routing.globalDefault);
    if (option == null) return '尚未配置';
    return '${option.providerName} / ${option.ref.modelId}';
  }

  Future<void> _chooseGlobalModel() async {
    final routing = widget.routingController;
    if (routing == null) return;
    try {
      await routing.load();
      if (!mounted) return;
      final selection = await showModelPickerSheet(
        context,
        options: routing.availableModels,
        selectedModel: routing.globalDefault,
      );
      final model = selection?.model;
      if (model == null || !mounted) return;
      await routing.setGlobalDefault(model);
    } on ModelRoutingException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.safeMessage)));
    } on StateError {
      // The kernel swapped this controller out mid-interaction; the replacement
      // page rebuilds from the new controller.
      return;
    }
  }

  String _providerState(
    ProviderSettingsController? controller,
    String providerId,
    bool supported,
  ) {
    if (!supported) return '后续支持';
    final state = controller?.stateFor(providerId);
    if (state == ProviderSettingsState.recoveryPending ||
        state == ProviderSettingsState.cleanupPending) {
      return '恢复中';
    }
    return (controller?.hasConfigurationFor(providerId) ?? false)
        ? '已配置'
        : '未配置';
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
    required this.enabled,
  });
  final String id;
  final String name;
  final String kind;
  final String state;
  final HaloTagTone tone;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          onTap: enabled ? () => context.push('/settings/providers/$id') : null,
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
