import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/domain/models/halo_fixture_models.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

class ConversationsPage extends StatelessWidget {
  const ConversationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '对话',
      actions: [
        HaloIconButton(
          prototypeIconClass: 'ph ph-magnifying-glass',
          semanticLabel: '搜索对话',
          onPressed: () {},
        ),
        HaloIconButton(
          prototypeIconClass: 'ph ph-plus',
          semanticLabel: '新建对话',
          onPressed: () {},
        ),
      ],
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(15, 2, 15, 6),
            child: HaloSearchField(placeholder: '搜索联系人、群聊、文件和来源'),
          ),
          Expanded(
            child: ListView.separated(
              key: const PageStorageKey('conversations'),
              padding: const EdgeInsets.fromLTRB(15, 0, 15, 14),
              itemCount: HaloFixtures.conversations.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 61, color: HaloColors.line),
              itemBuilder: (context, index) => _ConversationRow(
                conversation: HaloFixtures.conversations[index],
              ),
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
          if (!conversation.id.startsWith('group-')) {
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
                  HaloAvatar(
                    imageUrl: conversation.imageUrl,
                    letter: conversation.avatarLetter,
                  ),
                  if (conversation.unread > 0)
                    Positioned(
                      right: -5,
                      top: -5,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: HaloColors.red,
                          shape: BoxShape.circle,
                        ),
                        child: SizedBox.square(
                          dimension: 17,
                          child: Center(
                            child: Text(
                              '${conversation.unread}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
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
                        const Spacer(),
                        Text(conversation.time, style: HaloTextStyles.caption),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text.rich(
                      TextSpan(
                        children: [
                          if (conversation.sender case final sender?)
                            TextSpan(
                              text: sender,
                              style: const TextStyle(
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
