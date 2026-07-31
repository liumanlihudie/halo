import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/domain/models/halo_fixture_models.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'dart:async';

import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';

class ConversationsPage extends StatefulWidget {
  const ConversationsPage({this.repository, super.key});

  /// Absent when storage failed to boot; the list then says so rather than
  /// showing invented conversations.
  final ChatMessageRepository? repository;

  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage> {
  String _query = '';
  List<ConversationFixture>? _rows;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Builds the list from the conversations that actually exist, with each
  /// row's preview taken from its last stored message. The fixtures this page
  /// used to render — unread badges, progress percentages, upload failures —
  /// described a product that was not running.
  Future<void> _load() async {
    final repository = widget.repository;
    if (repository == null) return;
    final rows = <ConversationFixture>[];
    for (final identity in ExecutableExpertRegistry.installedExpertIdentities) {
      final SingleChatConversationProjection conversation;
      try {
        conversation = repository.describe(identity.conversationId);
      } catch (_) {
        continue;
      }
      String preview = '还没有消息';
      try {
        final messages = await repository.load(identity.conversationId);
        final last = messages.lastWhere(
          (message) => (message.text ?? '').trim().isNotEmpty,
          orElse: () => messages.isEmpty
              ? const ChatMessageProjection(
                  id: '',
                  kind: ChatMessageKind.systemNotice,
                )
              : messages.last,
        );
        final text = last.text?.trim();
        if (text != null && text.isNotEmpty) {
          preview = text.replaceAll('\n', ' ');
        }
      } catch (_) {
        preview = '消息读取失败';
      }
      rows.add(
        ConversationFixture(
          id: identity.conversationId,
          title: conversation.title,
          preview: preview,
          time: '',
          avatarLetter: conversation.avatarLetter,
        ),
      );
    }
    if (mounted) setState(() => _rows = rows);
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim();
    final all = _rows ?? const <ConversationFixture>[];
    final conversations = query.isEmpty
        ? all
        : all
              .where(
                (conversation) =>
                    conversation.title.contains(query) ||
                    conversation.preview.contains(query),
              )
              .toList();
    return HaloPageScaffold(
      title: '对话',
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-plus',
          semanticLabel: '新建对话',
          onPressed: () => context.push('/group/new'),
        ),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 2, 15, 6),
            child: HaloSearchField(
              placeholder: '搜索联系人、群聊、文件和来源',
              readOnly: false,
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          if (_rows == null)
            const Expanded(
              child: Center(
                child: Text('正在读取会话…', style: HaloTextStyles.caption),
              ),
            )
          else if (conversations.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  query.isEmpty ? '还没有会话' : '没有匹配的会话',
                  style: HaloTextStyles.caption,
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                key: const PageStorageKey('conversations'),
                padding: const EdgeInsets.fromLTRB(15, 0, 15, 14),
                itemCount: conversations.length,
                separatorBuilder: (_, _) => const Divider(
                  height: 1,
                  indent: 61,
                  color: HaloColors.line,
                ),
                itemBuilder: (context, index) =>
                    _ConversationRow(conversation: conversations[index]),
              ),
            ),
        ],
      ),
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({required this.conversation});
  final ConversationFixture conversation;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('conversation-${conversation.id}'),
        onTap: () {
          if (conversation.id.startsWith('group-')) {
            context.push('/group/${conversation.id}');
          } else {
            context.push('/chat/${conversation.id}');
          }
        },
        child: SizedBox(
          height: 72,
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  if (conversation.groupAvatarTiles case final tiles?)
                    HaloGroupAvatar(tiles: tiles)
                  else
                    HaloAvatar(
                      imageUrl: conversation.imageUrl,
                      letter: conversation.avatarLetter,
                      tone: conversation.avatarTone,
                    ),
                  if (conversation.unread > 0)
                    Positioned(
                      top: -5,
                      right: -6,
                      child: _UnreadBadge(count: conversation.unread),
                    ),
                ],
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // The title row must never squeeze the timestamp: it
                        // stays flush right while the title ellipsizes.
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  conversation.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: HaloTextStyles.rowTitle,
                                ),
                              ),
                              if (conversation.tag case final tag?) ...[
                                const SizedBox(width: 6),
                                HaloTag(tag, tone: conversation.tagTone),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          conversation.time,
                          textAlign: TextAlign.right,
                          style: HaloTextStyles.caption,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                if (conversation.sender case final sender?)
                                  TextSpan(
                                    text: sender,
                                    style: const TextStyle(
                                      color: Color(0xFF626A79),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                TextSpan(text: conversation.preview),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HaloTextStyles.secondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Semantics(
      label: '未读 $label',
      child: Container(
        constraints: const BoxConstraints(minWidth: 18),
        height: 18,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        decoration: BoxDecoration(
          color: HaloColors.accent,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: HaloColors.paper, width: 1.5),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 9,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
      ),
    );
  }
}
