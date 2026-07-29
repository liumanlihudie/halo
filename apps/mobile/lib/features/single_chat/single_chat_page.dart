import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

class SingleChatPage extends StatefulWidget {
  const SingleChatPage({required this.conversationId, super.key});
  final String conversationId;

  @override
  State<SingleChatPage> createState() => _SingleChatPageState();
}

class _SingleChatPageState extends State<SingleChatPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conversation = HaloFixtures.conversations.firstWhere(
      (item) => item.id == widget.conversationId,
      orElse: () => HaloFixtures.conversations[1],
    );
    return HaloPageScaffold(
      title: conversation.title,
      compactTitle: true,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/conversations'),
      ),
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-dots-three',
          semanticLabel: '聊天详情',
          onPressed: () =>
              context.push('/chat/${widget.conversationId}/details'),
        ),
      ],
      backgroundColor: HaloColors.soft,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        children: const [
          _SystemNotice('今天 10:02 · 已启用共享事实记忆'),
          _MineBubble('结合我刚发的材料，整理一版面向投资人的竞品分析。'),
          _AgentBubble(
            child: Text(
              '收到。我先让研究员核验关键数据，再整理成市场格局、差异化和风险三部分。',
              style: HaloTextStyles.body,
            ),
          ),
          _AgentBubble(child: _ProgressMessage()),
          _AgentBubble(child: _FileMessage()),
          _MineImageMessage(),
          _AgentBubble(child: _QuoteMessage()),
        ],
      ),
      bottom: _Composer(
        controller: _controller,
        onAttach: () => _showAttachmentSheet(context),
      ),
    );
  }
}

class _SystemNotice extends StatelessWidget {
  const _SystemNotice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFE5E7EB),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: HaloTextStyles.caption),
      ),
    );
  }
}

class _MineBubble extends StatelessWidget {
  const _MineBubble(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 286),
        margin: const EdgeInsets.only(left: 55, bottom: 13),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: const BoxDecoration(
          color: HaloColors.accent,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(13),
            topRight: Radius.circular(4),
            bottomLeft: Radius.circular(13),
            bottomRight: Radius.circular(13),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

class _AgentBubble extends StatelessWidget {
  const _AgentBubble({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HaloAvatar(
            imageUrl:
                'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=120',
            letter: '助',
            size: 36,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '通用助理 · Doubao / doubao-s2s-realtime',
                  style: HaloTextStyles.caption,
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: HaloColors.paper,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: child,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressMessage extends StatelessWidget {
  const _ProgressMessage();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 235,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Expanded(
                child: Text(
                  '任务进行中',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
              Text(
                '68%',
                style: TextStyle(
                  color: HaloColors.accentDeep,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: const LinearProgressIndicator(
              value: .68,
              minHeight: 5,
              backgroundColor: HaloColors.line,
              color: HaloColors.accent,
            ),
          ),
          const SizedBox(height: 7),
          const Text('已核验 16 / 23 个来源', style: HaloTextStyles.caption),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: null,
            icon: Icon(
              HaloIcon.requirePrototypeClass('ph ph-stop-circle'),
              size: 15,
            ),
            label: const Text('停止'),
          ),
        ],
      ),
    );
  }
}

class _FileMessage extends StatelessWidget {
  const _FileMessage();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 235,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 43,
                height: 50,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFE95A61),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'PDF',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '个人 AI 通讯竞品分析.pdf',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text('12 页 · 2.4 MB · 已完成', style: HaloTextStyles.caption),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 18),
          const Text('8 个来源 · 已沉淀至圈层', style: HaloTextStyles.caption),
        ],
      ),
    );
  }
}

class _MineImageMessage extends StatelessWidget {
  const _MineImageMessage();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Image.network(
          'https://images.unsplash.com/photo-1551288049-bebda4e38f71?w=520',
          width: 210,
          height: 128,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _QuoteMessage extends StatelessWidget {
  const _QuoteMessage();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 235,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: HaloColors.accent, width: 3),
              ),
            ),
            child: Padding(
              padding: EdgeInsets.only(left: 8),
              child: Text('你发来的数据看板', style: HaloTextStyles.caption),
            ),
          ),
          SizedBox(height: 7),
          Text(
            '我补充核对了漏斗口径：注册到首次有效对话的转化率应为 42.8%，原图少算了跨端登录。',
            style: HaloTextStyles.body,
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.onAttach});
  final TextEditingController controller;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFFF8F9FB),
        border: Border(top: BorderSide(color: HaloColors.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  _QuickAction('导出成果'),
                  SizedBox(width: 7),
                  _QuickAction('查看来源'),
                ],
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  HaloIconButton(
                    prototypeIconClass: 'ph ph-microphone',
                    semanticLabel: '语音输入',
                    onPressed: () {},
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: '输入消息，或继续追问成果',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  HaloIconButton(
                    prototypeIconClass: 'ph ph-plus',
                    semanticLabel: '添加附件',
                    onPressed: onAttach,
                  ),
                  HaloIconButton(
                    prototypeIconClass: 'ph ph-arrow-up',
                    semanticLabel: '发送',
                    primary: true,
                    onPressed: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: HaloColors.line),
      ),
      child: Text(label, style: HaloTextStyles.caption),
    );
  }
}

void _showAttachmentSheet(BuildContext context) {
  const abilities = <(String, String, String)>[
    ('ph ph-phone', '端到端语音通话', '与当前 Agent 实时对话'),
    ('ph ph-video-camera', 'Vidu 视频通话', '使用当前 Agent 形象'),
    ('ph ph-camera', '拍照', '现场拍摄'),
    ('ph ph-image', '图片', '从相册选择'),
    ('ph ph-file', '文件', 'PDF、Office'),
    ('ph ph-scan', '扫描', '识别纸质材料'),
    ('ph ph-link', '网页', '粘贴链接'),
    ('ph ph-microphone', '录音', '总结音频'),
  ];
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => Container(
      padding: const EdgeInsets.fromLTRB(15, 9, 15, 24),
      decoration: const BoxDecoration(
        color: HaloColors.soft,
        borderRadius: BorderRadius.vertical(top: Radius.circular(23)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 13),
              decoration: BoxDecoration(
                color: const Color(0xFFC9CCD2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Text(
              '发送与通话',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 13),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: .82,
              children: [
                for (final ability in abilities)
                  Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(13),
                    child: InkWell(
                      onTap: () {},
                      borderRadius: BorderRadius.circular(13),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              HaloIcon.requirePrototypeClass(ability.$1),
                              size: 23,
                              color: HaloColors.ink,
                            ),
                            const SizedBox(height: 7),
                            Text(
                              ability.$2,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              ability.$3,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 7,
                                color: HaloColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
