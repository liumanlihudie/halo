import 'package:flutter/foundation.dart';

@immutable
class GroupChatMember {
  GroupChatMember({
    required String expertId,
    required String displayName,
    required String role,
    required String avatarLetter,
  }) : expertId = expertId.trim(),
       displayName = displayName.trim(),
       role = role.trim(),
       avatarLetter = avatarLetter.trim() {
    if (this.expertId.isEmpty ||
        this.displayName.isEmpty ||
        this.role.isEmpty ||
        this.avatarLetter.isEmpty) {
      throw ArgumentError('Group member fields must not be blank.');
    }
  }

  final String expertId;
  final String displayName;
  final String role;
  final String avatarLetter;
}

abstract interface class GroupMembersRepository {
  Future<List<GroupChatMember>> loadMembers(String conversationId);
}

class PrototypeGroupMembersRepository implements GroupMembersRepository {
  const PrototypeGroupMembersRepository();

  static final _groups = <String, List<GroupChatMember>>{
    'group-product': [
      GroupChatMember(
        expertId: 'product-manager',
        displayName: '产品经理',
        role: '产品判断与需求拆解',
        avatarLetter: '产',
      ),
      GroupChatMember(
        expertId: 'technical-architect',
        displayName: '技术架构师',
        role: '架构与工程风险',
        avatarLetter: '技',
      ),
      GroupChatMember(
        expertId: 'ux-designer',
        displayName: 'UX 设计专家',
        role: '体验与交互方案',
        avatarLetter: '设',
      ),
      GroupChatMember(
        expertId: 'project-manager',
        displayName: '项目经理',
        role: '计划、依赖与交付风险',
        avatarLetter: '项',
      ),
      GroupChatMember(
        expertId: 'qa-test-engineer',
        displayName: '测试工程师',
        role: '质量与验证策略',
        avatarLetter: '测',
      ),
    ],
  };

  @override
  Future<List<GroupChatMember>> loadMembers(String conversationId) async =>
      List<GroupChatMember>.unmodifiable(
        _groups[conversationId] ?? const <GroupChatMember>[],
      );
}
