// ignore_for_file: prefer_initializing_formals

import 'package:halo_mobile/features/circle/circle_post_store.dart';

/// Publishes a conversation result to the circle.
///
/// The chat surface talks to this rather than to storage, so the identity
/// rules — canonical id, idempotency key, permission — live in one place and
/// cannot drift between the callers.
final class CirclePublisher {
  CirclePublisher({required CirclePostStore store, DateTime Function()? now})
    : _store = store,
      _now = now ?? DateTime.now;

  final CirclePostStore _store;
  final DateTime Function() _now;

  /// Publishes [body] as [canonicalExpertId]'s own post.
  ///
  /// [originKey] identifies what produced this, so the same message published
  /// twice — by a retry, or by an impatient second tap — yields one post.
  Future<CirclePublishResult> publishFromConversation({
    required String canonicalExpertId,
    required String conversationId,
    required String messageId,
    required String body,
    required String sourceLabel,
  }) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return CirclePublishResult.blocked;
    final createdAt = _now().toUtc();
    return _store.publish(
      CirclePost(
        // Derived from the message, not from a clock or a counter: the same
        // message always produces the same post id.
        id: 'post:$conversationId:$messageId',
        authorType: CirclePostAuthor.expert,
        authorId: canonicalExpertId,
        sourceType: CirclePostSource.conversation,
        sourceId: conversationId,
        sourceLabel: sourceLabel,
        body: trimmed,
        contentType: CirclePostContent.text,
        createdAt: createdAt,
      ),
      originKey: '$conversationId:$messageId:conversation',
    );
  }

  /// Publishes a group's discussion summary under the group itself.
  ///
  /// The summary is produced by the summariser identity, which has its own
  /// model binding and is not any member, so filing it under a participant
  /// would be a forged byline. Members ride along for the avatar row.
  Future<CirclePublishResult> publishGroupSummary({
    required String groupId,
    required String groupName,
    required String runId,
    required List<String> memberExpertIds,
    required String summary,
  }) async {
    final trimmed = summary.trim();
    if (trimmed.isEmpty) return CirclePublishResult.blocked;
    return _store.publish(
      CirclePost(
        id: 'post:$groupId:$runId:summary',
        authorType: CirclePostAuthor.group,
        authorId: groupId,
        memberAgentIds: memberExpertIds,
        sourceType: CirclePostSource.conversation,
        sourceId: groupId,
        sourceLabel: '$groupName · 群聊总结',
        body: trimmed,
        contentType: CirclePostContent.text,
        createdAt: _now().toUtc(),
      ),
      // The orchestration event already carries a stable dedupe identity; a
      // replayed run reaches here with the same one.
      originKey: '$groupId:$runId:summary',
    );
  }

  Future<bool> canPublishGroup(String groupId) =>
      _store.canPublish(CirclePostAuthor.group, groupId);

  /// Records a visible failure so it is not lost when the user looks away.
  ///
  /// Only failures the user would otherwise have to catch in the moment: an
  /// internal retry that succeeds on its own has nothing to report, and a feed
  /// full of transient noise is worse than no feed.
  Future<CirclePublishResult> publishFailure({
    required String canonicalExpertId,
    required String conversationId,
    required String commandId,
    required String reason,
    required String sourceLabel,
  }) => _store.publish(
    CirclePost(
      id: 'post:$conversationId:$commandId:failure',
      authorType: CirclePostAuthor.expert,
      authorId: canonicalExpertId,
      sourceType: CirclePostSource.conversation,
      sourceId: conversationId,
      sourceLabel: sourceLabel,
      body: reason,
      contentType: CirclePostContent.status,
      createdAt: _now().toUtc(),
    ),
    // Retrying the same command must not stack up identical failure posts.
    originKey: '$conversationId:$commandId:failure',
  );

  Future<bool> canPublish(String canonicalExpertId) =>
      _store.canPublish(CirclePostAuthor.expert, canonicalExpertId);
}
