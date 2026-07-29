import 'package:flutter/foundation.dart';

enum AgentCollaborationMessageType {
  question,
  answer,
  taskRequest,
  taskResult,
  critique,
  evidenceRequest,
  verificationResult,
  handoff,
  skip,
}

@immutable
class AgentCollaborationMessage {
  const AgentCollaborationMessage({
    required this.messageId,
    required this.runId,
    required this.conversationId,
    required this.fromAgentId,
    required this.toAgentIds,
    required this.type,
    required this.payloadRefs,
    required this.dedupeKey,
  });

  final String messageId;
  final String runId;
  final String conversationId;
  final String fromAgentId;
  final List<String> toAgentIds;
  final AgentCollaborationMessageType type;
  final List<String> payloadRefs;
  final String dedupeKey;
}

class AgentMessageBus {
  final _messagesByRun = <String, List<AgentCollaborationMessage>>{};
  final _messagesByDedupeKey = <String, AgentCollaborationMessage>{};
  final _messagesByIdentity = <String, AgentCollaborationMessage>{};
  final _messageCountByAgentPair = <String, int>{};
  var _nextMessageNumber = 1;

  AgentCollaborationMessage publish({
    required String runId,
    required String conversationId,
    required String fromAgentId,
    required List<String> toAgentIds,
    required AgentCollaborationMessageType type,
    required List<String> payloadRefs,
    required List<String> executableAgentIds,
    required String dedupeKey,
  }) {
    final executable = executableAgentIds.toSet();
    if (!executable.contains(fromAgentId) ||
        toAgentIds.isEmpty ||
        !toAgentIds.every(executable.contains)) {
      throw ArgumentError(
        'Message participants must belong to executableAgentIds',
      );
    }
    final normalizedRecipients = toAgentIds.toSet().toList()..sort();
    final scopedDedupeKey = '$runId:$dedupeKey';
    final duplicate = _messagesByDedupeKey[scopedDedupeKey];
    final identity = _messageIdentity(
      runId: runId,
      conversationId: conversationId,
      fromAgentId: fromAgentId,
      toAgentIds: normalizedRecipients,
      type: type,
      payloadRefs: payloadRefs,
    );
    final identityDuplicate = _messagesByIdentity[identity];
    if (duplicate != null) {
      if (!identical(duplicate, identityDuplicate)) {
        throw StateError('Dedupe key collision for $scopedDedupeKey');
      }
      return duplicate;
    }
    if (identityDuplicate != null) {
      _messagesByDedupeKey[scopedDedupeKey] = identityDuplicate;
      return identityDuplicate;
    }
    if ((_messagesByRun[runId]?.length ?? 0) >= 20) {
      throw StateError('Agent message budget exhausted for $runId');
    }
    final pairKeys = normalizedRecipients
        .map((recipient) => _pairKey(runId, fromAgentId, recipient))
        .toList(growable: false);
    if (pairKeys.any((key) => (_messageCountByAgentPair[key] ?? 0) >= 4)) {
      throw StateError('Agent pair round-trip budget exhausted for $runId');
    }
    final message = AgentCollaborationMessage(
      messageId: 'agent-message-${_nextMessageNumber++}',
      runId: runId,
      conversationId: conversationId,
      fromAgentId: fromAgentId,
      toAgentIds: List.unmodifiable(normalizedRecipients),
      type: type,
      payloadRefs: List.unmodifiable(payloadRefs),
      dedupeKey: dedupeKey,
    );
    _messagesByRun.putIfAbsent(runId, () => []).add(message);
    _messagesByDedupeKey[scopedDedupeKey] = message;
    _messagesByIdentity[identity] = message;
    for (final pairKey in pairKeys) {
      _messageCountByAgentPair.update(
        pairKey,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    return message;
  }

  String _pairKey(String runId, String firstAgentId, String secondAgentId) {
    final pair = [firstAgentId, secondAgentId]..sort();
    return '$runId:${pair[0]}:${pair[1]}';
  }

  String _messageIdentity({
    required String runId,
    required String conversationId,
    required String fromAgentId,
    required List<String> toAgentIds,
    required AgentCollaborationMessageType type,
    required List<String> payloadRefs,
  }) {
    String encode(String value) => '${value.length}:$value';
    return [
      runId,
      conversationId,
      fromAgentId,
      type.name,
      ...toAgentIds,
      '|',
      ...payloadRefs,
    ].map(encode).join();
  }
}
