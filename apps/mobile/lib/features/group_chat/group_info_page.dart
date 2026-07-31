import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/group_chat/group_members_repository.dart';
import 'package:halo_mobile/features/group_chat/group_store.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class GroupInfoPage extends StatefulWidget {
  const GroupInfoPage({
    required this.groupId,
    this.membersRepository = const PrototypeGroupMembersRepository(),
    this.groupStore,
    super.key,
  });

  final String groupId;

  /// Where a user-created group's real name lives. Absent for shipped
  /// prototype groups, which keep their seeded title.
  final GroupStore? groupStore;

  /// Same source the group chat uses, so the strip cannot drift from who is
  /// actually in the group.
  final GroupMembersRepository membersRepository;

  @override
  State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
  List<GroupChatMember> _members = const [];
  String? _groupName;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMembers());
    unawaited(_loadGroupName());
  }

  Future<void> _loadGroupName() async {
    final store = widget.groupStore;
    if (store == null) return;
    try {
      final groups = await store.loadGroups();
      final match = groups
          .where((group) => group.groupId == widget.groupId)
          .firstOrNull;
      if (match != null && mounted) setState(() => _groupName = match.name);
    } catch (_) {
      // No name is better than an invented one.
    }
  }

  Future<void> _loadMembers() async {
    try {
      final members = await widget.membersRepository.loadMembers(
        widget.groupId,
      );
      if (mounted) setState(() => _members = members);
    } catch (_) {
      // An unreadable roster shows no members rather than fixture ones.
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupId = widget.groupId;
    return HaloPageScaffold(
      title: '群资料',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/group/$groupId'),
      ),

      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _MemberStrip(members: _members),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: HaloSectionLabel('群聊信息'),
          ),
          _InsetGroup(
            children: [
              // Facts only: the seeded '群目标' and '主持 Agent' rows described
              // a group nobody configured.
              HaloSettingsRow(label: '群名称', detail: _groupName ?? '群聊'),
              HaloSettingsRow(label: '成员', detail: '${_members.length} 位专家'),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: HaloSectionLabel('发言与上下文'),
          ),
          const _InsetGroup(
            children: [
              HaloSettingsRow(label: '默认发言规则', detail: '自动选择'),
              HaloSettingsRow(
                label: '每次讨论自动总结',
                trailing: HaloSwitch(value: true, onChanged: null),
              ),
              HaloSettingsRow(
                label: '讨论总结发布到圈层',
                trailing: HaloSwitch(value: true, onChanged: null),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MemberStrip extends StatelessWidget {
  const _MemberStrip({required this.members});

  final List<GroupChatMember> members;

  @override
  Widget build(BuildContext context) {
    final registry = ExecutableExpertRegistry(
      gateway: const ExpertOutputValidationGateway(),
    );
    return SizedBox(
      height: 94,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        scrollDirection: Axis.horizontal,
        itemCount: members.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          if (index == members.length) {
            return const _MemberTile(
              letter: '+',
              label: '添加',
              background: HaloColors.muted,
            );
          }
          final member = members[index];
          // Membership stores the canonical id; the profile route takes the
          // profile id. An expert that is not installed has no profile page, so
          // its avatar stays untappable rather than opening a blank one.
          final identity = registry.installedIdentityForCanonicalId(
            member.expertId,
          );
          return _MemberTile(
            key: ValueKey('group-member-${member.expertId}'),
            letter: member.avatarLetter,
            label: member.displayName,
            background: HaloColors.accent,
            onTap: identity == null
                ? null
                : () => context.push('/expert/${identity.profileId}'),
          );
        },
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.letter,
    required this.label,
    required this.background,
    this.onTap,
    super.key,
  });

  final String letter;
  final String label;
  final Color background;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            HaloAvatar(letter: letter, size: 48, backgroundColor: background),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HaloTextStyles.caption,
            ),
          ],
        ),
      ),
    );
  }
}

class _InsetGroup extends StatelessWidget {
  const _InsetGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13),
      child: HaloSettingsGroup(children: children),
    );
  }
}
