import 'dart:async';

import 'package:halo_mobile/app/generation_tools.dart';
import 'package:halo_mobile/app/pending_generation_store.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';

/// Collects generations an earlier process left unfinished.
///
/// The provider kept working after the app died; each ledger record is polled
/// again, its result delivered into the conversation it belongs to, and the
/// shared board shows a placeholder meanwhile so an open page sees the wait.
Future<void> resumePendingGenerations({
  required PendingGenerationStore store,

  /// Typically [ProductionGenerationService.resumePending].
  required Future<GeneratedAsset> Function(PendingGenerationRecord) resume,
  required ChatMessageRepository repository,
  ActiveGenerationRegistry? registry,
}) async {
  final List<PendingGenerationRecord> records;
  try {
    records = await store.list();
  } catch (_) {
    return;
  }
  if (records.isEmpty) return;
  // ignore: avoid_print
  print('halo.tools resuming ${records.length} pending generation(s)');

  final byConversation = <String, List<PendingGenerationRecord>>{};
  for (final record in records) {
    byConversation.putIfAbsent(record.conversationId, () => []).add(record);
  }
  for (final entry in byConversation.entries) {
    unawaited(
      _resumeConversation(
        entry.key,
        entry.value,
        resume: resume,
        repository: repository,
        registry: registry,
      ),
    );
  }
}

Future<void> _resumeConversation(
  String conversationId,
  List<PendingGenerationRecord> records, {
  required Future<GeneratedAsset> Function(PendingGenerationRecord) resume,
  required ChatMessageRepository repository,
  ActiveGenerationRegistry? registry,
}) async {
  var pending = [
    for (final record in records)
      GenerationProgress.submitted(
        id: 'resume-${record.taskId}',
        prompt: record.prompt,
        isVideo: record.isVideo,
      ),
  ];
  registry?.update(conversationId, pending);

  void settle(String taskId) {
    pending = [
      for (final step in pending)
        if (step.id != 'resume-$taskId') step,
    ];
    if (pending.isEmpty) {
      registry?.finishRun(conversationId);
    } else {
      registry?.update(conversationId, pending);
    }
  }

  await Future.wait([
    for (final record in records)
      () async {
        try {
          final asset = await resume(record);
          try {
            await repository.append(
              conversationId,
              ChatMessageProjection(
                id: 'resumed:${record.taskId}',
                kind: ChatMessageKind.agentImage,
                imageUrl: asset.localPath,
                text: '',
              ),
            );
          } catch (_) {
            // Already delivered by an earlier resume of the same record.
          }
          // ignore: avoid_print
          print('halo.tools resumed delivery ok');
        } on GenerationUnavailable catch (error) {
          try {
            await repository.append(
              conversationId,
              ChatMessageProjection(
                id: 'resumed:${record.taskId}:failed',
                kind: ChatMessageKind.systemNotice,
                text:
                    '重启前的${record.isVideo ? '视频' : '图片'}生成没有完成：${error.safeMessage}',
              ),
            );
          } catch (_) {}
        } catch (_) {
          // A crashed resume keeps its record for the next boot.
        } finally {
          settle(record.taskId);
        }
      }(),
  ]);
}
