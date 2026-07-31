import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/circle/circle_controller.dart';
import 'package:halo_mobile/features/circle/circle_post_store.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class CirclePage extends StatefulWidget {
  const CirclePage({this.controller, super.key});

  /// Absent when storage failed to boot; the feed then says so rather than
  /// showing invented content.
  final CircleController? controller;

  @override
  State<CirclePage> createState() => _CirclePageState();
}

class _CirclePageState extends State<CirclePage> {
  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_refresh);
    widget.controller?.load();
  }

  @override
  void didUpdateWidget(CirclePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_refresh);
      widget.controller?.addListener(_refresh);
      widget.controller?.load();
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return HaloPageScaffold(
      title: '圈层',
      body: ListView(
        key: const PageStorageKey('circle'),
        padding: const EdgeInsets.fromLTRB(13, 5, 13, 18),
        children: [
          const Text(
            '专家动态',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: HaloColors.ink,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            '你的专家最近在想什么、做什么。这里不分类，只按发布时间排列。',
            style: HaloTextStyles.secondary,
          ),
          const SizedBox(height: 13),
          if (controller == null)
            const _CircleNotice('本机存储当前不可用，暂时看不到动态。')
          else if (!controller.loaded)
            const SizedBox.shrink()
          else if (controller.failed)
            const _CircleNotice('动态读取失败，稍后再试。')
          else if (controller.isEmpty)
            const _CircleNotice('还没有动态。专家在对话里产出结论后会发布到这里。')
          else
            for (final post in controller.posts)
              _PostCard(
                key: ValueKey('circle-post-${post.id}'),
                post: post,
                controller: controller,
              ),
        ],
      ),
    );
  }
}

class _CircleNotice extends StatelessWidget {
  const _CircleNotice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: HaloTextStyles.caption,
    ),
  );
}

class _PostCard extends StatelessWidget {
  const _PostCard({required this.post, required this.controller, super.key});

  final CirclePost post;
  final CircleController controller;

  static final _registry = ExecutableExpertRegistry(
    gateway: const ExpertOutputValidationGateway(),
  );

  /// The feed stores canonical ids; the profile route takes a profile id. A
  /// member with no installed identity has no profile page, so its avatar
  /// stays untappable rather than opening a blank one.
  static String? _profileIdFor(String canonicalExpertId) =>
      _registry.installedIdentityForCanonicalId(canonicalExpertId)?.profileId;

  String get _authorName {
    if (post.authorType == CirclePostAuthor.group) return post.sourceLabel;
    final profileId = _profileIdFor(post.authorId);
    if (profileId == null) return post.authorId;
    return _registry.catalogById(post.authorId)?.displayName ?? post.authorId;
  }

  void _openAuthor(BuildContext context) {
    if (post.authorType == CirclePostAuthor.group) {
      context.push('/group/${post.authorId}');
      return;
    }
    final profileId = _profileIdFor(post.authorId);
    if (profileId != null) context.push('/expert/$profileId');
  }

  Future<void> _openMenu(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (post.sourceId != null)
              ListTile(
                leading: Icon(
                  HaloIcon.requirePrototypeClass('ph ph-arrow-square-out'),
                ),
                title: const Text('查看来源'),
                onTap: () => Navigator.of(context).pop('source'),
              ),
            ListTile(
              leading: Icon(
                HaloIcon.requirePrototypeClass('ph ph-chat-circle-text'),
              ),
              title: const Text('继续对话'),
              onTap: () => Navigator.of(context).pop('chat'),
            ),
            ListTile(
              leading: Icon(HaloIcon.requirePrototypeClass('ph ph-prohibit')),
              title: Text(
                post.authorType == CirclePostAuthor.group
                    ? '不让该群发圈层'
                    : '不让该专家发圈层',
              ),
              onTap: () => Navigator.of(context).pop('ban'),
            ),
            ListTile(
              leading: Icon(HaloIcon.requirePrototypeClass('ph ph-trash')),
              title: const Text(
                '删除这条动态',
                style: TextStyle(color: HaloColors.red),
              ),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'source':
        final sourceId = post.sourceId;
        if (sourceId != null) context.push('/chat/$sourceId');
      case 'chat':
        _openConversation(context);
      case 'ban':
        await _confirmBan(context);
      case 'delete':
        await _confirmDelete(context);
    }
  }

  void _openConversation(BuildContext context) {
    if (post.authorType == CirclePostAuthor.group) {
      context.push('/group/${post.authorId}');
      return;
    }
    final identity = _registry.installedIdentityForCanonicalId(post.authorId);
    if (identity != null) context.push('/chat/${identity.conversationId}');
  }

  Future<void> _confirmBan(BuildContext context) async {
    final name = _authorName;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('不让「$name」发圈层'),
        // Says what it does not do, because that is the part users worry
        // about: silencing the feed must not look like stopping the work.
        content: const Text('之后不再有新动态。已发布的保留，对话和任务不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: HaloColors.red),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final banned = await controller.banAuthor(post.authorType, post.authorId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(banned ? '已禁止该发布者发布到圈层' : '设置失败')));
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条动态'),
        content: const Text('只从圈层移除这一条，不影响原对话。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: HaloColors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.delete(post.id);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: HaloColors.paper,
          borderRadius: BorderRadius.circular(17),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0E252C40),
              blurRadius: 15,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  GestureDetector(
                    onTap: () => _openAuthor(context),
                    behavior: HitTestBehavior.opaque,
                    child: HaloAvatar(
                      letter: _authorName.characters.first,
                      size: 42,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: GestureDetector(
                                onTap: () => _openAuthor(context),
                                child: Text(
                                  _authorName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            // The model wrote this; the badge stays whatever
                            // the source was.
                            const HaloTag('未核验', tone: HaloTagTone.gray),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(post.sourceLabel, style: HaloTextStyles.caption),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '更多',
                    onPressed: () => _openMenu(context),
                    icon: Icon(
                      HaloIcon.requirePrototypeClass('ph ph-dots-three'),
                      size: 20,
                      color: HaloColors.muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 11),
              if (post.title case final title?) ...[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                post.body,
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
              if (post.memberAgentIds.isNotEmpty) ...[
                const SizedBox(height: 11),
                _MemberRow(
                  memberIds: post.memberAgentIds,
                  onOpenMember: (canonicalId) {
                    final profileId = _profileIdFor(canonicalId);
                    if (profileId != null) context.push('/expert/$profileId');
                  },
                  onOpenGroup: () => context.push('/group/${post.authorId}'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The participants of a group post, as avatars.
///
/// Information about who took part, not a like bar: tapping one opens that
/// expert, and the row never accumulates counts or reactions.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.memberIds,
    required this.onOpenMember,
    required this.onOpenGroup,
  });

  static const maximumAvatars = 5;

  final List<String> memberIds;
  final void Function(String canonicalId) onOpenMember;
  final VoidCallback onOpenGroup;

  static final _registry = ExecutableExpertRegistry(
    gateway: const ExpertOutputValidationGateway(),
  );

  @override
  Widget build(BuildContext context) {
    final shown = memberIds.take(maximumAvatars).toList();
    final overflow = memberIds.length - shown.length;
    return Row(
      children: [
        for (final id in shown)
          Padding(
            padding: const EdgeInsets.only(right: 5),
            child: GestureDetector(
              key: ValueKey('circle-member-$id'),
              onTap: () => onOpenMember(id),
              behavior: HitTestBehavior.opaque,
              child: HaloAvatar(
                letter: (_registry.catalogById(id)?.displayName ?? id)
                    .characters
                    .first,
                size: 26,
                backgroundColor: HaloColors.accent,
              ),
            ),
          ),
        if (overflow > 0) Text('+$overflow', style: HaloTextStyles.caption),
        const Spacer(),
        TextButton(onPressed: onOpenGroup, child: const Text('进入群聊 ›')),
      ],
    );
  }
}
