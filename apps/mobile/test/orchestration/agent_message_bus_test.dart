import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/agent_message_bus.dart';

void main() {
  test('message bus rejects recipients outside the executable set', () {
    final bus = AgentMessageBus();

    expect(
      () => bus.publish(
        runId: 'run-1',
        conversationId: 'group-product',
        fromAgentId: 'product-manager',
        toAgentIds: const ['market-outsider'],
        type: AgentCollaborationMessageType.question,
        payloadRefs: const ['message-1'],
        executableAgentIds: const ['product-manager', 'technical-architect'],
        dedupeKey: 'question-1',
      ),
      throwsArgumentError,
    );
  });

  test('message bus reuses the message for a duplicate dedupe key', () {
    final bus = AgentMessageBus();

    AgentCollaborationMessage publish() => bus.publish(
      runId: 'run-1',
      conversationId: 'group-product',
      fromAgentId: 'product-manager',
      toAgentIds: const ['technical-architect'],
      type: AgentCollaborationMessageType.question,
      payloadRefs: const ['message-1'],
      executableAgentIds: const ['product-manager', 'technical-architect'],
      dedupeKey: 'question-1',
    );

    final first = publish();
    final duplicate = publish();

    expect(duplicate.messageId, first.messageId);
  });

  test('duplicate key cannot bypass participant validation', () {
    final bus = AgentMessageBus();
    bus.publish(
      runId: 'run-1',
      conversationId: 'group-product',
      fromAgentId: 'product-manager',
      toAgentIds: const ['technical-architect'],
      type: AgentCollaborationMessageType.question,
      payloadRefs: const ['message-1'],
      executableAgentIds: const ['product-manager', 'technical-architect'],
      dedupeKey: 'question-1',
    );

    expect(
      () => bus.publish(
        runId: 'run-1',
        conversationId: 'group-product',
        fromAgentId: 'outsider',
        toAgentIds: const ['technical-architect'],
        type: AgentCollaborationMessageType.question,
        payloadRefs: const ['message-1'],
        executableAgentIds: const ['product-manager', 'technical-architect'],
        dedupeKey: 'question-1',
      ),
      throwsArgumentError,
    );
  });

  test('duplicate key rejects a different message identity', () {
    final bus = AgentMessageBus();
    bus.publish(
      runId: 'run-1',
      conversationId: 'group-product',
      fromAgentId: 'product-manager',
      toAgentIds: const ['technical-architect'],
      type: AgentCollaborationMessageType.question,
      payloadRefs: const ['message-1'],
      executableAgentIds: const ['product-manager', 'technical-architect'],
      dedupeKey: 'question-1',
    );

    expect(
      () => bus.publish(
        runId: 'run-1',
        conversationId: 'group-product',
        fromAgentId: 'product-manager',
        toAgentIds: const ['technical-architect'],
        type: AgentCollaborationMessageType.critique,
        payloadRefs: const ['message-2'],
        executableAgentIds: const ['product-manager', 'technical-architect'],
        dedupeKey: 'question-1',
      ),
      throwsStateError,
    );
  });

  test('content identity deduplicates different caller keys and recipient order', () {
    final bus = AgentMessageBus();
    final first = bus.publish(
      runId: 'run-identity',
      conversationId: 'group-product',
      fromAgentId: 'product-manager',
      toAgentIds: const ['growth-advisor', 'technical-architect'],
      type: AgentCollaborationMessageType.question,
      payloadRefs: const ['message-1'],
      executableAgentIds: const [
        'product-manager',
        'technical-architect',
        'growth-advisor',
      ],
      dedupeKey: 'caller-key-1',
    );
    final duplicate = bus.publish(
      runId: 'run-identity',
      conversationId: 'group-product',
      fromAgentId: 'product-manager',
      toAgentIds: const ['technical-architect', 'growth-advisor'],
      type: AgentCollaborationMessageType.question,
      payloadRefs: const ['message-1'],
      executableAgentIds: const [
        'product-manager',
        'technical-architect',
        'growth-advisor',
      ],
      dedupeKey: 'caller-key-2',
    );

    expect(duplicate.messageId, first.messageId);
    expect(duplicate.toAgentIds, ['growth-advisor', 'technical-architect']);
  });

  test('message bus enforces the twenty-message run budget', () {
    final bus = AgentMessageBus();
    const executable = [
      'product-manager',
      'agent-0',
      'agent-1',
      'agent-2',
      'agent-3',
      'agent-4',
      'agent-5',
    ];
    for (var index = 0; index < 20; index++) {
      bus.publish(
        runId: 'run-budget',
        conversationId: 'group-product',
        fromAgentId: 'product-manager',
        toAgentIds: ['agent-${index ~/ 4}'],
        type: AgentCollaborationMessageType.question,
        payloadRefs: ['message-$index'],
        executableAgentIds: executable,
        dedupeKey: 'question-$index',
      );
    }

    expect(
      () => bus.publish(
        runId: 'run-budget',
        conversationId: 'group-product',
        fromAgentId: 'product-manager',
        toAgentIds: const ['agent-5'],
        type: AgentCollaborationMessageType.question,
        payloadRefs: const ['message-21'],
        executableAgentIds: executable,
        dedupeKey: 'question-21',
      ),
      throwsStateError,
    );
  });

  test('message bus limits one agent pair to two round trips', () {
    final bus = AgentMessageBus();
    for (var index = 0; index < 4; index++) {
      final fromProduct = index.isEven;
      bus.publish(
        runId: 'run-pair-budget',
        conversationId: 'group-product',
        fromAgentId: fromProduct ? 'product-manager' : 'technical-architect',
        toAgentIds: [fromProduct ? 'technical-architect' : 'product-manager'],
        type: AgentCollaborationMessageType.question,
        payloadRefs: ['message-$index'],
        executableAgentIds: const ['product-manager', 'technical-architect'],
        dedupeKey: 'pair-$index',
      );
    }

    expect(
      () => bus.publish(
        runId: 'run-pair-budget',
        conversationId: 'group-product',
        fromAgentId: 'product-manager',
        toAgentIds: const ['technical-architect'],
        type: AgentCollaborationMessageType.question,
        payloadRefs: const ['message-5'],
        executableAgentIds: const ['product-manager', 'technical-architect'],
        dedupeKey: 'pair-5',
      ),
      throwsStateError,
    );
  });
}
