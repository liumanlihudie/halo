import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/local_data_maintenance.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/drift_chat_message_repository.dart';

/// Real SQLite, because the counts and the erase are the only thing standing
/// between the settings page and a claim about the user's data.
void main() {
  const seed = {
    'conversation-product': SingleChatConversationProjection(
      conversationId: 'conversation-product',
      expertId: 'product-manager',
      title: '产品经理',
      agentName: '产品经理',
      modelLabel: '已配置文字模型',
      avatarLetter: '产',
    ),
    'conversation-data': SingleChatConversationProjection(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      title: '数据分析师',
      agentName: '数据分析师',
      modelLabel: '已配置文字模型',
      avatarLetter: '数',
    ),
  };

  Future<DriftChatMessageRepository> openRepository() async {
    final directory = await Directory.systemTemp.createTemp('halo-history-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final repository = await DriftChatMessageRepository.open(
      databasePath: '${directory.path}/history.sqlite',
      commandOutbox: FileSingleChatCommandOutbox('${directory.path}/cmd.json'),
      conversations: seed,
    );
    addTearDown(repository.close);
    return repository;
  }

  Future<void> seedMessages(DriftChatMessageRepository repository) async {
    await repository.append(
      'conversation-product',
      const ChatMessageProjection(
        id: 'p1',
        kind: ChatMessageKind.userText,
        text: '这周要交付什么？',
      ),
    );
    await repository.append(
      'conversation-product',
      const ChatMessageProjection(
        id: 'p2',
        kind: ChatMessageKind.agentText,
        text: '先把需求澄清清楚。',
      ),
    );
    await repository.append(
      'conversation-data',
      const ChatMessageProjection(
        id: 'd1',
        kind: ChatMessageKind.userText,
        text: '转化率怎么看？',
      ),
    );
  }

  test('counts report what is actually stored', () async {
    final repository = await openRepository();

    var counts = await repository.countStoredHistory();
    expect(counts.conversations, 2);
    expect(counts.messages, 0);

    await seedMessages(repository);

    counts = await repository.countStoredHistory();
    expect(counts.conversations, 2);
    expect(counts.messages, 3);
  });

  test(
    'export carries every conversation with its messages in order',
    () async {
      final repository = await openRepository();
      await seedMessages(repository);

      final exported = await repository.exportStoredHistory();

      expect(exported, hasLength(2));
      final data = exported.firstWhere(
        (bundle) => bundle['conversationId'] == 'conversation-data',
      );
      expect(data['expertId'], 'data-analyst');
      final product = exported.firstWhere(
        (bundle) => bundle['conversationId'] == 'conversation-product',
      );
      final messages = product['messages']! as List;
      expect(messages, hasLength(2));
      expect((messages.first as Map)['messageId'], 'p1');
      expect(
        ((messages.first as Map)['projection'] as Map)['text'],
        '这周要交付什么？',
      );
      expect((messages.last as Map)['messageId'], 'p2');
    },
  );

  test('erasing drops messages but keeps the shipped conversations', () async {
    final repository = await openRepository();
    await seedMessages(repository);

    await repository.eraseStoredMessages();

    final counts = await repository.countStoredHistory();
    expect(counts.messages, 0);
    // Contacts must still open after an erase; dropping the bindings would
    // trip the fail-closed rebinding guard on the next launch.
    expect(counts.conversations, 2);
    expect(await repository.load('conversation-product'), isEmpty);
    expect(
      repository.describe('conversation-product').expertId,
      'product-manager',
    );
  });

  test('the erased database still accepts new messages', () async {
    final repository = await openRepository();
    await seedMessages(repository);
    await repository.eraseStoredMessages();

    await repository.append(
      'conversation-product',
      const ChatMessageProjection(
        id: 'p1',
        kind: ChatMessageKind.userText,
        text: '清除后重新提问',
      ),
    );

    final messages = await repository.load('conversation-product');
    expect(messages.single.text, '清除后重新提问');
  });

  test('the repository satisfies the settings maintenance port', () async {
    final repository = await openRepository();
    expect(repository, isA<SingleChatHistoryMaintenance>());
  });
}
