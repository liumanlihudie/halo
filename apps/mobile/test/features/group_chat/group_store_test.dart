import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/group_chat/group_members_repository.dart';
import 'package:halo_mobile/features/group_chat/group_store.dart';

void main() {
  late Directory root;
  late SqliteGroupStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('halo-groups');
    store = SqliteGroupStore.open('${root.path}/halo_circle.sqlite');
  });

  tearDown(() async {
    await store.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a created group keeps its name and members in order', () async {
    final group = await store.createGroup(
      name: '新项目评审组',
      memberExpertIds: const [
        'product-manager',
        'technical-architect',
        'data-analyst',
      ],
    );

    expect(group.name, '新项目评审组');
    // Order is the order the user picked, which is also speaking order.
    expect(group.memberExpertIds, [
      'product-manager',
      'technical-architect',
      'data-analyst',
    ]);
    expect((await store.loadGroup(group.groupId))!.name, '新项目评审组');
  });

  test('each group gets its own id, even created back to back', () async {
    final first = await store.createGroup(
      name: 'A',
      memberExpertIds: const ['product-manager', 'data-analyst'],
    );
    final second = await store.createGroup(
      name: 'B',
      memberExpertIds: const ['product-manager', 'data-analyst'],
    );

    expect(first.groupId, isNot(second.groupId));
    expect((await store.loadGroups()).length, 2);
  });

  test('a duplicated pick does not double that expert', () async {
    final group = await store.createGroup(
      name: '重复选择',
      memberExpertIds: const [
        'product-manager',
        'product-manager',
        'data-analyst',
      ],
    );

    // A member listed twice would take two turns in every discussion.
    expect(group.memberExpertIds, ['product-manager', 'data-analyst']);
  });

  test('a group needs a name and at least two members', () async {
    await expectLater(
      store.createGroup(
        name: '   ',
        memberExpertIds: const ['product-manager', 'data-analyst'],
      ),
      throwsArgumentError,
    );
    await expectLater(
      store.createGroup(
        name: '只有一个',
        memberExpertIds: const ['product-manager'],
      ),
      throwsArgumentError,
    );
    expect(await store.loadGroups(), isEmpty);
  });

  test('groups survive a reopen', () async {
    final group = await store.createGroup(
      name: '持久化',
      memberExpertIds: const ['product-manager', 'data-analyst'],
    );
    await store.close();

    final reopened = SqliteGroupStore.open('${root.path}/halo_circle.sqlite');
    addTearDown(reopened.close);

    expect((await reopened.loadGroup(group.groupId))!.name, '持久化');
    store = reopened;
  });

  test('deleting a group takes its membership with it', () async {
    final group = await store.createGroup(
      name: '待删除',
      memberExpertIds: const ['product-manager', 'data-analyst'],
    );

    await store.deleteGroup(group.groupId);

    expect(await store.loadGroup(group.groupId), isNull);
    expect(await store.loadGroups(), isEmpty);
  });

  test('the composite repository serves created and shipped groups', () async {
    final group = await store.createGroup(
      name: '自建组',
      memberExpertIds: const ['product-manager', 'data-analyst'],
    );
    const repository = PrototypeGroupMembersRepository();
    final composite = CompositeGroupMembersRepository(
      store: store,
      expertDisplayNames: const {
        'product-manager': '产品经理',
        'data-analyst': '数据分析师',
      },
      fallback: repository,
    );

    final created = await composite.loadMembers(group.groupId);
    expect(created.map((member) => member.expertId), [
      'product-manager',
      'data-analyst',
    ]);
    expect(created.first.displayName, '产品经理');

    // A shipped group still resolves through the fallback, untouched.
    final shipped = await composite.loadMembers('group-product');
    expect(shipped, isNotEmpty);
    expect(
      shipped.map((member) => member.expertId),
      (await repository.loadMembers('group-product')).map((m) => m.expertId),
    );
  });
}
