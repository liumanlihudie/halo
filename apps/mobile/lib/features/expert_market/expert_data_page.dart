import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class ExpertDataPage extends StatelessWidget {
  const ExpertDataPage({required this.expertId, super.key});
  final String expertId;

  @override
  Widget build(BuildContext context) {
    const sections = <String, List<(String, String, String)>>{
      '身份与表达': [
        ('昵称与备注', '通用助理', 'ph ph-user-circle'),
        ('系统提示词', '已设置 · 1,248 字', 'ph ph-brackets-curly'),
        ('性格与回答风格', '直接、务实、先结论', 'ph ph-chat-circle-text'),
      ],
      '模型策略': [
        ('主模型', 'Anthropic / claude-sonnet-4', 'ph ph-cpu'),
        ('候补模型', 'DeepSeek / deepseek-chat', 'ph ph-arrows-clockwise'),
        ('任务模型覆盖', '研究、图像、总结', 'ph ph-path'),
      ],
      '形象与能力': [
        ('语音角色', '豆包端到端语音', 'ph ph-waveform'),
        ('视频形象', 'Vidu · 产品顾问', 'ph ph-video-camera'),
        ('工具列表', '网页、文件、日历', 'ph ph-wrench'),
        ('数据权限', '按次授权', 'ph ph-shield-check'),
      ],
      '记忆与主动工作': [
        ('共享事实访问范围', '128 条', 'ph ph-brain'),
        ('私有关系记忆', '18 条', 'ph ph-lock-key'),
        ('主动消息规则', '重要变化优先', 'ph ph-bell'),
      ],
    };
    return HaloPageScaffold(
      title: '专家数据',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/expert/$expertId'),
      ),
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-export',
          semanticLabel: '导出专家配置',
          onPressed: () {},
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(15, 10, 15, 24),
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              color: HaloColors.navy,
              borderRadius: BorderRadius.all(Radius.circular(14)),
            ),
            child: Padding(
              padding: EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '通用助理',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    '身份、提示词、模型和权限均保存在本机。API Key 由 Provider 单独保存在 Keychain。',
                    style: TextStyle(
                      color: Color(0xFFC5CADB),
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          for (final section in sections.entries) ...[
            HaloSectionLabel(section.key),
            HaloSettingsGroup(
              children: [
                for (final item in section.value)
                  HaloSettingsRow(
                    label: item.$1,
                    detail: item.$2,
                    prototypeIconClass: item.$3,
                    onTap: () {},
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
