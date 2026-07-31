import 'dart:convert';
import 'dart:io';

/// One generation the provider accepted but this app has not yet delivered.
///
/// Carries no secrets and no URLs — a task id, where its result belongs, and
/// enough to rebuild the poll from the current provider configuration.
class PendingGenerationRecord {
  const PendingGenerationRecord({
    required this.taskId,
    required this.isVideo,
    required this.prompt,
    required this.conversationId,
    required this.providerId,
    required this.acceptedAtEpochMs,
  });

  final String taskId;
  final bool isVideo;
  final String prompt;
  final String conversationId;
  final String providerId;
  final int acceptedAtEpochMs;

  Map<String, Object?> toJson() => {
    'taskId': taskId,
    'isVideo': isVideo,
    'prompt': prompt,
    'conversationId': conversationId,
    'providerId': providerId,
    'acceptedAtEpochMs': acceptedAtEpochMs,
  };

  static PendingGenerationRecord? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final taskId = raw['taskId'];
    final isVideo = raw['isVideo'];
    final prompt = raw['prompt'];
    final conversationId = raw['conversationId'];
    final providerId = raw['providerId'];
    final acceptedAtEpochMs = raw['acceptedAtEpochMs'];
    if (taskId is! String ||
        taskId.isEmpty ||
        isVideo is! bool ||
        prompt is! String ||
        conversationId is! String ||
        conversationId.isEmpty ||
        providerId is! String ||
        providerId.isEmpty ||
        acceptedAtEpochMs is! int) {
      return null;
    }
    return PendingGenerationRecord(
      taskId: taskId,
      isVideo: isVideo,
      prompt: prompt,
      conversationId: conversationId,
      providerId: providerId,
      acceptedAtEpochMs: acceptedAtEpochMs,
    );
  }
}

/// Accepted-but-undelivered generations, durable across process death.
///
/// The provider keeps generating whether or not this process survives; what
/// was lost — three times in one day — was the client's memory that it had
/// asked. Records are written the moment a task is accepted and removed when
/// its result (or failure) has been delivered.
class PendingGenerationStore {
  PendingGenerationStore(this._file);

  final File _file;

  Future<List<PendingGenerationRecord>> list() async {
    try {
      if (!await _file.exists()) return const [];
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! List) return const [];
      return [
        for (final raw in decoded) ?PendingGenerationRecord.fromJson(raw),
      ];
    } catch (_) {
      // An unreadable ledger is an empty ledger: resuming nothing is safe,
      // failing app startup over it would not be.
      return const [];
    }
  }

  Future<void> add(PendingGenerationRecord record) async {
    final records = await list();
    await _write([
      for (final existing in records)
        if (existing.taskId != record.taskId) existing,
      record,
    ]);
  }

  Future<void> remove(String taskId) async {
    final records = await list();
    await _write([
      for (final existing in records)
        if (existing.taskId != taskId) existing,
    ]);
  }

  Future<void> _write(List<PendingGenerationRecord> records) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode([for (final record in records) record.toJson()]),
      flush: true,
    );
  }
}
