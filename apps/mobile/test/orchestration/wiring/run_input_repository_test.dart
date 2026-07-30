import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/wiring/run_input_repository.dart';

void main() {
  test(
    'stable references hash structured identity and never expose input',
    () async {
      final repository = MemoryRunInputRepository();
      addTearDown(repository.close);
      const secretInput = 'PRIVATE_PROMPT_SENTINEL_do_not_persist';
      final first = await repository.prepare(
        _command(clientCommandId: '../unsafe:命令', input: secretInput),
      );
      final duplicate = await repository.prepare(
        _command(clientCommandId: '../unsafe:命令', input: secretInput),
      );
      final distinct = await repository.prepare(
        _command(clientCommandId: '../unsafe:命令x', input: secretInput),
      );

      expect(
        first.inputRef,
        matches(RegExp(r'^halo-run-input://sha256/[0-9a-f]{64}$')),
      );
      expect(
        first.contextRef,
        matches(RegExp(r'^halo-run-context://sha256/[0-9a-f]{64}$')),
      );
      expect(first.inputRef, duplicate.inputRef);
      expect(first.contextRef, duplicate.contextRef);
      expect(distinct.inputRef, isNot(first.inputRef));
      expect(first.inputRef, isNot(contains('unsafe')));
      expect(first.inputRef, isNot(contains(secretInput)));
      expect(first.contextRef, isNot(contains(secretInput)));
    },
  );

  test(
    'prepare reservations rollback without deleting another holder',
    () async {
      final repository = MemoryRunInputRepository();
      addTearDown(repository.close);
      final first = await repository.prepare(_command());
      final second = await repository.prepare(_command());

      await repository.rollback(first);
      await repository.commit(second);
      expect(
        await repository.resolve(
          inputRef: second.inputRef,
          contextRef: second.contextRef,
        ),
        '分析风险',
      );

      await repository.rollback(second);
      await repository.rollback(second);
      expect(
        await repository.resolve(
          inputRef: second.inputRef,
          contextRef: second.contextRef,
        ),
        '分析风险',
      );
    },
  );

  test('rollback removes an uncommitted record and is idempotent', () async {
    final repository = MemoryRunInputRepository();
    addTearDown(repository.close);
    final reservation = await repository.prepare(_command());

    await repository.rollback(reservation);
    await repository.rollback(reservation);

    await expectLater(
      repository.resolve(
        inputRef: reservation.inputRef,
        contextRef: reservation.contextRef,
      ),
      throwsA(isA<RunInputUnavailable>()),
    );
  });

  test('commit makes a new input a resolvable orphan', () async {
    final repository = MemoryRunInputRepository();
    addTearDown(repository.close);
    final reservation = await repository.prepare(_command());

    expect(await repository.lifecycleOf(reservation), RunInputLifecycle.staged);
    await repository.commit(reservation);

    expect(
      await repository.resolve(
        inputRef: reservation.inputRef,
        contextRef: reservation.contextRef,
      ),
      '分析风险',
    );
    expect(
      await repository.lifecycleOf(reservation),
      RunInputLifecycle.resolvableOrphan,
    );
  });

  test(
    'rollback compensates only a newly-created unreferenced input',
    () async {
      final repository = MemoryRunInputRepository();
      addTearDown(repository.close);
      final created = await repository.prepare(_command());
      await repository.commit(created);

      await repository.rollback(created);
      await repository.rollback(created);

      await expectLater(
        repository.resolve(
          inputRef: created.inputRef,
          contextRef: created.contextRef,
        ),
        throwsA(isA<RunInputUnavailable>()),
      );

      final existing = await repository.prepare(_command());
      await repository.commit(existing);
      final duplicate = await repository.prepare(_command());
      await repository.commit(duplicate);
      await repository.rollback(duplicate);

      expect(
        await repository.resolve(
          inputRef: existing.inputRef,
          contextRef: existing.contextRef,
        ),
        '分析风险',
      );
    },
  );

  test('referenced input cannot be removed by compensation', () async {
    final repository = MemoryRunInputRepository();
    addTearDown(repository.close);
    final reservation = await repository.prepare(_command());
    await repository.commit(reservation);
    await repository.markReferenced(reservation);

    await repository.rollback(reservation);

    expect(
      await repository.resolve(
        inputRef: reservation.inputRef,
        contextRef: reservation.contextRef,
      ),
      '分析风险',
    );
    expect(
      await repository.lifecycleOf(reservation),
      RunInputLifecycle.referenced,
    );
  });

  test('orphan GC removes abandoned staged and resolvable inputs', () async {
    final repository = MemoryRunInputRepository(
      clock: () => DateTime.utc(2026, 1, 1),
    );
    addTearDown(repository.close);
    final staged = await repository.prepare(
      _command(clientCommandId: 'staged'),
    );
    final orphan = await repository.prepare(
      _command(clientCommandId: 'orphan'),
    );
    await repository.commit(orphan);

    final removed = await repository.collectOrphans(
      olderThan: DateTime.utc(2026, 1, 2),
      isReferenced: (_, _) async => false,
    );

    expect(removed, 2);
    for (final reservation in [staged, orphan]) {
      await expectLater(
        repository.resolve(
          inputRef: reservation.inputRef,
          contextRef: reservation.contextRef,
        ),
        throwsA(isA<RunInputUnavailable>()),
      );
    }
  });

  test('orphan GC preserves an input referenced by a durable run', () async {
    final repository = MemoryRunInputRepository(
      clock: () => DateTime.utc(2026, 1, 1),
    );
    addTearDown(repository.close);
    final orphan = await repository.prepare(_command());
    await repository.commit(orphan);

    final removed = await repository.collectOrphans(
      olderThan: DateTime.utc(2026, 1, 2),
      isReferenced: (inputRef, contextRef) async =>
          inputRef == orphan.inputRef && contextRef == orphan.contextRef,
    );

    expect(removed, 0);
    expect(await repository.lifecycleOf(orphan), RunInputLifecycle.referenced);
    expect(
      await repository.resolve(
        inputRef: orphan.inputRef,
        contextRef: orphan.contextRef,
      ),
      '分析风险',
    );
  });

  test('orphan GC does not delete a record created at the cutoff', () async {
    final cutoff = DateTime.utc(2026, 7, 29, 12);
    final repository = MemoryRunInputRepository(clock: () => cutoff);
    addTearDown(repository.close);
    final reservation = await repository.prepare(_command());
    await repository.commit(reservation);

    final removed = await repository.collectOrphans(
      olderThan: cutoff,
      isReferenced: (_, _) async => false,
    );

    expect(removed, 0);
    expect(
      await repository.resolve(
        inputRef: reservation.inputRef,
        contextRef: reservation.contextRef,
      ),
      '分析风险',
    );
  });

  test('reservation tokens use at least 128 random bits', () async {
    final repository = MemoryRunInputRepository();
    addTearDown(repository.close);
    final tokens = <String>{};

    for (var index = 0; index < 32; index++) {
      final reservation = await repository.prepare(
        _command(clientCommandId: 'command-$index'),
      );
      final bytes = base64Url.decode(base64Url.normalize(reservation.token));
      expect(bytes.length, greaterThanOrEqualTo(16));
      tokens.add(reservation.token);
    }

    expect(tokens, hasLength(32));
    expect(tokens, isNot(contains('reservation-1')));
  });

  test('reservation ownership and full tuple are enforced', () async {
    final first = MemoryRunInputRepository();
    final second = MemoryRunInputRepository();
    addTearDown(first.close);
    addTearDown(second.close);
    final reservation = await first.prepare(_command());

    await expectLater(
      second.commit(reservation),
      throwsA(isA<RunInputIdentityConflict>()),
    );
    await expectLater(
      second.rollback(reservation),
      throwsA(isA<RunInputIdentityConflict>()),
    );

    await first.commit(reservation);
    await first.commit(reservation);
    await first.markReferenced(reservation);
    await first.markReferenced(reservation);
  });

  test('resolve fails closed for missing or mismatched references', () async {
    final repository = MemoryRunInputRepository();
    addTearDown(repository.close);
    final reservation = await repository.prepare(_command());
    await repository.commit(reservation);

    await expectLater(
      repository.resolve(
        inputRef: 'halo-run-input://sha256/${'0' * 64}',
        contextRef: reservation.contextRef,
      ),
      throwsA(isA<RunInputUnavailable>()),
    );
    await expectLater(
      repository.resolve(
        inputRef: reservation.inputRef,
        contextRef: 'halo-run-context://sha256/${'f' * 64}',
      ),
      throwsA(isA<RunInputUnavailable>()),
    );
  });

  test(
    'same client command with different input is an identity conflict',
    () async {
      final repository = MemoryRunInputRepository();
      addTearDown(repository.close);
      await repository.prepare(_command());

      await expectLater(
        repository.prepare(_command(input: '不同正文')),
        throwsA(isA<RunInputIdentityConflict>()),
      );
    },
  );

  test('structured identity cannot collide across list boundaries', () async {
    final repository = MemoryRunInputRepository();
    addTearDown(repository.close);
    await repository.prepare(
      _command(
        memberAgentIds: const ['product-manager', 'technical-architect'],
        mentionedAgentIds: const ['technical-architect'],
      ),
    );

    await expectLater(
      repository.prepare(
        _command(
          memberAgentIds: const [
            'product-manager',
            'technical-architect',
            'security-reviewer',
          ],
          mentionedAgentIds: const ['technical-architect', 'security-reviewer'],
        ),
      ),
      throwsA(isA<RunInputIdentityConflict>()),
    );
  });

  test('close is idempotent and rejects later operations', () async {
    final repository = MemoryRunInputRepository();
    await repository.close();
    await repository.close();

    await expectLater(repository.prepare(_command()), throwsStateError);
    await expectLater(
      repository.resolve(inputRef: 'missing'),
      throwsStateError,
    );
  });
}

StartConversationRunCommand _command({
  String clientCommandId = 'wiring-command',
  String input = '分析风险',
  List<String> memberAgentIds = const ['product-manager'],
  List<String> mentionedAgentIds = const [],
}) {
  return StartConversationRunCommand(
    clientCommandId: clientCommandId,
    conversationId: 'group-product',
    hostAgentId: 'product-manager',
    input: input,
    replyMode: ConversationReplyMode.auto,
    memberAgentIds: memberAgentIds,
    mentionedAgentIds: mentionedAgentIds,
  );
}
