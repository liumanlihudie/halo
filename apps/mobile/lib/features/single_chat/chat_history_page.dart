import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

import 'chat_message_repository.dart';
import 'media_preview.dart';

/// Searches what was actually said and made in this conversation.
///
/// Every row comes from the repository; the page invents neither entries nor
/// timestamps (messages carry none). A category with nothing in it says so.
class ChatHistoryPage extends StatefulWidget {
  const ChatHistoryPage({
    required this.conversationId,
    this.repository,
    this.initialCategory,
    super.key,
  });

  final String conversationId;

  /// Absent when storage failed to boot; the page then says it cannot search
  /// instead of showing an inventory it does not have.
  final ChatMessageRepository? repository;

  /// Pre-selects a category when opened from the details page shortcuts.
  final String? initialCategory;

  @override
  State<ChatHistoryPage> createState() => _ChatHistoryPageState();
}

class _ChatHistoryPageState extends State<ChatHistoryPage> {
  static const categories = [
    ('全部', 'ph ph-magnifying-glass'),
    ('图片与视频', 'ph ph-images'),
    ('文件', 'ph ph-files'),
    ('链接', 'ph ph-link'),
    ('AI 成果', 'ph ph-sparkle'),
  ];

  late String category = switch (widget.initialCategory) {
    final selected? when categories.any((entry) => entry.$1 == selected) =>
      selected,
    _ => '全部',
  };
  String _query = '';
  List<ChatMessageProjection>? _messages;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final repository = widget.repository;
    if (repository == null) {
      setState(() => _loadFailed = true);
      return;
    }
    try {
      final messages = await repository.load(widget.conversationId);
      if (mounted) setState(() => _messages = messages);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  static final _linkPattern = RegExp(r'https?://\S+');

  List<_HistoryEntry> _entries() {
    final messages = _messages;
    if (messages == null) return const [];
    final entries = <_HistoryEntry>[];
    for (final message in messages) {
      final text = message.text?.trim() ?? '';
      final media = message.imageUrl;
      final isMedia =
          media != null &&
          media.isNotEmpty &&
          (message.kind == ChatMessageKind.agentImage ||
              message.kind == ChatMessageKind.userImage);
      if (isMedia) {
        final isVideo = media.toLowerCase().endsWith('.mp4');
        final generated = message.kind == ChatMessageKind.agentImage;
        entries.add(
          _HistoryEntry(
            icon: isVideo ? 'ph ph-video-camera' : 'ph ph-image',
            title: text.isNotEmpty
                ? text
                : (generated
                      ? '专家生成的${isVideo ? '视频' : '图片'}'
                      : '发送的${isVideo ? '视频' : '图片'}'),
            label: isVideo ? '视频' : '图片',
            isAiResult: generated,
            mediaPath: media,
            isVideo: isVideo,
          ),
        );
        continue;
      }
      if (text.isEmpty) continue;
      final link = _linkPattern.firstMatch(text)?.group(0);
      entries.add(
        _HistoryEntry(
          icon: link != null
              ? 'ph ph-link'
              : (message.kind == ChatMessageKind.voice
                    ? 'ph ph-microphone'
                    : 'ph ph-chat-circle-text'),
          title: text,
          label: switch (message.kind) {
            ChatMessageKind.voice => '语音',
            ChatMessageKind.systemNotice => '系统通知',
            ChatMessageKind.userText => '我发送的',
            _ => '专家回复',
          },
          link: link,
        ),
      );
    }
    // Newest first: what was just made is what gets looked for.
    return entries.reversed.toList();
  }

  List<_HistoryEntry> _visible() {
    var entries = _entries();
    entries = switch (category) {
      '图片与视频' => [
        for (final entry in entries)
          if (entry.mediaPath != null) entry,
      ],
      '文件' => const [],
      '链接' => [
        for (final entry in entries)
          if (entry.link != null) entry,
      ],
      'AI 成果' => [
        for (final entry in entries)
          if (entry.isAiResult) entry,
      ],
      _ => entries,
    };
    final query = _query.trim();
    if (query.isEmpty) return entries;
    return [
      for (final entry in entries)
        if (entry.title.contains(query)) entry,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible();
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
          HaloSearchField(
            placeholder: '搜索聊天记录',
            readOnly: false,
            onChanged: (value) => setState(() => _query = value),
          ),
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
          const HaloSectionLabel('记录'),
          if (_loadFailed)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('聊天存储不可用，无法查找', style: HaloTextStyles.caption),
            )
          else if (_messages == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                _query.trim().isNotEmpty
                    ? '没有匹配「${_query.trim()}」的记录'
                    : (category == '文件' ? '这个对话里还没有文件' : '这个分类下还没有记录'),
                style: HaloTextStyles.caption,
              ),
            )
          else
            for (final entry in visible) _HistoryResult(entry: entry),
        ],
      ),
    );
  }
}

class _HistoryEntry {
  const _HistoryEntry({
    required this.icon,
    required this.title,
    required this.label,
    this.isAiResult = false,
    this.mediaPath,
    this.isVideo = false,
    this.link,
  });

  final String icon;
  final String title;
  final String label;
  final bool isAiResult;
  final String? mediaPath;
  final bool isVideo;
  final String? link;
}

class _HistoryResult extends StatelessWidget {
  const _HistoryResult({required this.entry});

  final _HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final media = entry.mediaPath;
    return InkWell(
      onTap: media == null
          ? null
          : () => entry.isVideo
                ? openVideoPlayer(context, media)
                : openImagePreview(context, media),
      child: Container(
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
                HaloIcon.requirePrototypeClass(entry.icon),
                color: HaloColors.accentDeep,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HaloTextStyles.rowTitle,
                  ),
                  const SizedBox(height: 4),
                  Text(entry.label, style: HaloTextStyles.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
