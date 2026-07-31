import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/generation_resumer.dart';
import 'package:halo_mobile/app/generation_tools.dart';
import 'package:halo_mobile/app/pending_generation_store.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';

void main() {
  late Directory directory;
  late PendingGenerationStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('pending-generation-');
    store = PendingGenerationStore(File('${directory.path}/pending.json'));
  });

  tearDown(() => directory.deleteSync(recursive: true));

  PendingGenerationRecord record(String taskId) => PendingGenerationRecord(
    taskId: taskId,
    isVideo: false,
    prompt: '一只猫',
    conversationId: 'conversation-data',
    providerId: 'toapis',
    acceptedAtEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
  );

  test('records survive a round trip and removal', () async {
    await store.add(record('task-1'));
    await store.add(record('task-2'));

    final reopened = PendingGenerationStore(
      File('${directory.path}/pending.json'),
    );
    expect((await reopened.list()).map((entry) => entry.taskId), [
      'task-1',
      'task-2',
    ]);

    await reopened.remove('task-1');
    expect((await reopened.list()).map((entry) => entry.taskId), ['task-2']);
  });

  test('a corrupt ledger reads as empty instead of throwing', () async {
    final file = File('${directory.path}/pending.json');
    await file.writeAsString('{not json');
    expect(await store.list(), isEmpty);
  });

  test('a resumed failure lands as a notice in the conversation', () async {
    // The stale path needs no network: a record past the cutoff must turn
    // into an honest notice in the conversation it belonged to, and leave
    // the board clean.
    await store.add(
      PendingGenerationRecord(
        taskId: 'task-stale',
        isVideo: true,
        prompt: '一段海边视频',
        conversationId: 'conversation-data',
        providerId: 'toapis',
        acceptedAtEpochMs: DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 3))
            .millisecondsSinceEpoch,
      ),
    );
    final repository = InMemoryChatMessageRepository();
    final registry = ActiveGenerationRegistry();

    await resumePendingGenerations(
      store: store,
      resume: (record) async {
        await store.remove(record.taskId);
        throw const GenerationUnavailable('任务已过期，无法继续等待');
      },
      repository: repository,
      registry: registry,
    );
    // The per-conversation deliveries are fired without being awaited by the
    // entry point, and they interleave real file IO; give them a beat.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final messages = await repository.load('conversation-data');
    expect(
      messages.map((message) => message.text),
      contains('重启前的视频生成没有完成：任务已过期，无法继续等待'),
    );
    expect(registry.pendingFor('conversation-data'), isEmpty);
    expect(await store.list(), isEmpty);
  });
}
