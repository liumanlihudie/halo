import 'package:flutter/foundation.dart';

enum GroupChatHistoryItemType { notice, userMessage, agentMessage, summary }

@immutable
class GroupChatHistoryItem {
  const GroupChatHistoryItem({
    required this.type,
    required this.text,
    this.agentId,
    this.title,
  });

  final GroupChatHistoryItemType type;
  final String text;
  final String? agentId;
  final String? title;
}

abstract interface class GroupChatHistoryRepository {
  List<GroupChatHistoryItem> load(String conversationId);
}

class PrototypeGroupChatHistoryRepository
    implements GroupChatHistoryRepository {
  const PrototypeGroupChatHistoryRepository();

  @override
  List<GroupChatHistoryItem> load(String conversationId) {
    if (conversationId != 'group-product') return const [];
    return const [
      GroupChatHistoryItem(
        type: GroupChatHistoryItemType.notice,
        text: '今天 10:12',
      ),
      GroupChatHistoryItem(
        type: GroupChatHistoryItemType.userMessage,
        text: '先从用户价值、实现难度和商业化三个角度判断一下。',
      ),
      GroupChatHistoryItem(
        type: GroupChatHistoryItemType.notice,
        text: '自动选择了 产品经理、技术架构师',
      ),
      GroupChatHistoryItem(
        type: GroupChatHistoryItemType.agentMessage,
        agentId: 'product-manager',
        text: '用户价值是成立的，但首版必须把“联系人就是能力”做透。',
      ),
      GroupChatHistoryItem(
        type: GroupChatHistoryItemType.agentMessage,
        agentId: 'technical-architect',
        text: '工程上可行。最大的风险不是 UI，而是消息可靠性、模型编排和长期记忆边界。',
      ),
      GroupChatHistoryItem(
        type: GroupChatHistoryItemType.summary,
        title: '群聊阶段总结',
        text: '首版聚焦文字对话、可控群聊、Agent 市场和结果沉淀。',
      ),
    ];
  }
}
