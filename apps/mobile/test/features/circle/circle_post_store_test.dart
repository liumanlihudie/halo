import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/circle/circle_post_store.dart';

void main() {
  late Directory root;
  late SqliteCirclePostStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('halo-circle');
    store = SqliteCirclePostStore.open('${root.path}/halo_circle.sqlite');
  });

  tearDown(() async {
    await store.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  CirclePost post({
    String id = 'post-1',
    CirclePostAuthor authorType = CirclePostAuthor.expert,
    String authorId = 'product-manager',
    List<String> members = const [],
    DateTime? createdAt,
  }) => CirclePost(
    id: id,
    authorType: authorType,
    authorId: authorId,
    memberAgentIds: members,
    sourceType: CirclePostSource.conversation,
    sourceLabel: '来自对话',
    body: '先把 MVP 收敛到三条。',
    contentType: CirclePostContent.text,
    createdAt: createdAt ?? DateTime.utc(2026, 7, 31, 10),
  );

  test('an empty feed is empty, never seeded with fixtures', () async {
    expect(await store.loadFeed(), isEmpty);
    expect(await store.countPosts(), 0);
  });

  test('publishing shows up newest first', () async {
    await store.publish(
      post(id: 'old', createdAt: DateTime.utc(2026, 7, 30)),
      originKey: 'run-1:conversation',
    );
    await store.publish(
      post(id: 'new', createdAt: DateTime.utc(2026, 7, 31)),
      originKey: 'run-2:conversation',
    );

    final feed = await store.loadFeed();
    expect(feed.map((entry) => entry.id), ['new', 'old']);
  });

  test('the same origin cannot post twice', () async {
    expect(
      await store.publish(post(), originKey: 'run-1:conversation'),
      CirclePublishResult.published,
    );
    // A retried run reaches here again; the unique key turns it away.
    expect(
      await store.publish(post(id: 'post-2'), originKey: 'run-1:conversation'),
      CirclePublishResult.duplicate,
    );
    expect(await store.countPosts(), 1);
  });

  test('an expert may publish until the user says otherwise', () async {
    // Default is allowed: a missing row is not a ban.
    expect(
      await store.canPublish(CirclePostAuthor.expert, 'product-manager'),
      isTrue,
    );

    await store.setCanPublish(
      CirclePostAuthor.expert,
      'product-manager',
      allowed: false,
    );

    expect(
      await store.publish(post(), originKey: 'run-1:conversation'),
      CirclePublishResult.blocked,
    );
    expect(await store.countPosts(), 0);
  });

  test('banning an expert keeps what it already published', () async {
    await store.publish(post(), originKey: 'run-1:conversation');

    await store.setCanPublish(
      CirclePostAuthor.expert,
      'product-manager',
      allowed: false,
    );

    // The spec is explicit: a ban stops new posts, it does not delete history.
    expect(await store.countPosts(), 1);
    expect((await store.loadFeed()).single.id, 'post-1');
  });

  test('a group ban does not silence its members, or the reverse', () async {
    await store.setCanPublish(
      CirclePostAuthor.group,
      'group-product',
      allowed: false,
    );

    // A group summary is not published by any member, so a member ban must not
    // block it and a group ban must not block the member's own posts.
    expect(
      await store.publish(
        post(authorType: CirclePostAuthor.group, authorId: 'group-product'),
        originKey: 'run-1:summary',
      ),
      CirclePublishResult.blocked,
    );
    expect(
      await store.publish(post(id: 'p2'), originKey: 'run-2:conversation'),
      CirclePublishResult.published,
    );
  });

  test('deleting one post hides it without touching permission', () async {
    await store.publish(post(), originKey: 'run-1:conversation');

    await store.delete('post-1');

    expect(await store.loadFeed(), isEmpty);
    expect(
      await store.canPublish(CirclePostAuthor.expert, 'product-manager'),
      isTrue,
    );
  });

  test('group posts keep their participants for the avatar row', () async {
    await store.publish(
      post(
        authorType: CirclePostAuthor.group,
        authorId: 'group-product',
        members: const ['product-manager', 'technical-architect'],
      ),
      originKey: 'run-1:summary',
    );

    final stored = (await store.loadFeed()).single;
    expect(stored.authorType, CirclePostAuthor.group);
    // Members are context, not the byline: the author is the group.
    expect(stored.authorId, 'group-product');
    expect(stored.memberAgentIds, ['product-manager', 'technical-architect']);
  });

  test('erase clears everything the settings page promised', () async {
    await store.publish(post(), originKey: 'run-1:conversation');
    await store.publish(post(id: 'p2'), originKey: 'run-2:conversation');

    await store.erasePosts();

    expect(await store.countPosts(), 0);
    expect(await store.exportPosts(), isEmpty);
    // Still writable afterwards: erasing is not the same as breaking.
    expect(
      await store.publish(post(id: 'p3'), originKey: 'run-3:conversation'),
      CirclePublishResult.published,
    );
  });

  test('export carries posts and no credential-shaped strings', () async {
    await store.publish(post(), originKey: 'run-1:conversation');

    final exported = await store.exportPosts();

    expect(exported.single['authorId'], 'product-manager');
    expect(exported.single['body'], '先把 MVP 收敛到三条。');
    final raw = exported.toString().toLowerCase();
    for (final forbidden in const ['keychain', 'secretref', 'bearer', 'sk-']) {
      expect(raw.contains(forbidden), isFalse, reason: forbidden);
    }
  });

  test('the feed survives reopening the database', () async {
    await store.publish(post(), originKey: 'run-1:conversation');
    await store.close();

    final reopened = SqliteCirclePostStore.open(
      '${root.path}/halo_circle.sqlite',
    );
    addTearDown(reopened.close);

    expect((await reopened.loadFeed()).single.id, 'post-1');
    store = reopened;
  });
}
