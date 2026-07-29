import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class ChatHistoryPage extends StatefulWidget {
  const ChatHistoryPage({required this.conversationId, super.key});
  final String conversationId;

  @override
  State<ChatHistoryPage> createState() => _ChatHistoryPageState();
}

class _ChatHistoryPageState extends State<ChatHistoryPage> {
  String category = '全部';

  @override
  Widget build(BuildContext context) {
    const categories = [
      ('全部', 'ph ph-magnifying-glass'),
      ('图片与视频', 'ph ph-images'),
      ('文件', 'ph ph-files'),
      ('链接', 'ph ph-link'),
      ('AI 成果', 'ph ph-sparkle'),
    ];
    return HaloPageScaffold(
      title: '查找聊天记录',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () => context.canPop()
            ? context.pop()
            : context.go('/chat/${widget.conversationId}/details'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(15, 10, 15, 24),
        children: [
          const HaloSearchField(placeholder: '搜索聊天记录', readOnly: false),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final item in categories)
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => category = item.$1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        children: [
                          Icon(
                            HaloIcon.requirePrototypeClass(item.$2),
                            size: 20,
                            color: category == item.$1
                                ? HaloColors.accentDeep
                                : HaloColors.muted,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.$1,
                            style: TextStyle(
                              fontSize: 8,
                              color: category == item.$1
                                  ? HaloColors.accentDeep
                                  : HaloColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const HaloSectionLabel('最近记录'),
          const _HistoryResult(
            icon: 'ph ph-file-text',
            title: '个人 AI 通讯竞品分析.pdf',
            detail: '今天 10:18 · 12 页 · AI 成果',
          ),
          const _HistoryResult(
            icon: 'ph ph-image',
            title: '数据看板图片',
            detail: '今天 10:15 · 图片与视频',
          ),
          const _HistoryResult(
            icon: 'ph ph-link',
            title: 'AI companion apps shift toward utility',
            detail: '今天 10:09 · 公开网页',
          ),
          const _HistoryResult(
            icon: 'ph ph-chat-circle-text',
            title: '整理一版面向投资人的竞品分析',
            detail: '今天 10:02 · 文字消息',
          ),
        ],
      ),
    );
  }
}

class _HistoryResult extends StatelessWidget {
  const _HistoryResult({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final String icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: HaloColors.line)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              HaloIcon.requirePrototypeClass(icon),
              color: HaloColors.accentDeep,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: HaloTextStyles.rowTitle),
                const SizedBox(height: 4),
                Text(detail, style: HaloTextStyles.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
