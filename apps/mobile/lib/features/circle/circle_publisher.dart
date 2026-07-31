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

  Future<bool> canPublish(String canonicalExpertId) =>
      _store.canPublish(CirclePostAuthor.expert, canonicalExpertId);
}
