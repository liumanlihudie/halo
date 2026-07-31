import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/circle/circle_post_store.dart';
import 'package:halo_mobile/features/circle/circle_publisher.dart';

void main() {
  late Directory root;
  late SqliteCirclePostStore store;
  late CirclePublisher publisher;

  setUp(() {
    root = Directory.systemTemp.createTempSync('halo-circle-publish');
    store = SqliteCirclePostStore.open('${root.path}/halo_circle.sqlite');
    publisher = CirclePublisher(
      store: store,
      now: () => DateTime.utc(2026, 7, 31, 12),
    );
  });

  tearDown(() async {
    await store.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<CirclePublishResult> publish({
    String messageId = 'command-1:answer',
    String body = '先把 MVP 收敛到三条。',
  }) => publisher.publishFromConversation(
    canonicalExpertId: 'product-manager',
    conversationId: 'product-manager-chat',
    messageId: messageId,
    body: body,
    sourceLabel: '来自与产品经理的对话',
  );

  test('an answer reaches the feed under the expert who wrote it', () async {
    expect(await publish(), CirclePublishResult.published);

    final post = (await store.loadFeed()).single;
    // The canonical id, matching what the chat pipeline and the ban both use.
    expect(post.authorId, 'product-manager');
    expect(post.authorType, CirclePostAuthor.expert);
    expect(post.sourceType, CirclePostSource.conversation);
    expect(post.sourceId, 'product-manager-chat');
    expect(post.body, '先把 MVP 收敛到三条。');
  });

  test('publishing the same message twice yields one post', () async {
    expect(await publish(), CirclePublishResult.published);
    // A second tap, or a retried run, lands on the same origin key.
    expect(await publish(), CirclePublishResult.duplicate);
    expect(await store.countPosts(), 1);
  });

  test('a banned expert cannot publish from a conversation either', () async {
    await store.setCanPublish(
      CirclePostAuthor.expert,
      'product-manager',
      allowed: false,
    );

    expect(await publish(), CirclePublishResult.blocked);
    expect(await store.countPosts(), 0);
    expect(await publisher.canPublish('product-manager'), isFalse);
  });

  test('an empty answer is never published', () async {
    expect(await publish(body: '   '), CirclePublishResult.blocked);
    expect(await store.countPosts(), 0);
  });

  test('different messages from one conversation are separate posts', () async {
    await publish(messageId: 'command-1:answer');
    await publish(messageId: 'command-2:answer', body: '第二条结论。');

    expect(await store.countPosts(), 2);
  });
}
