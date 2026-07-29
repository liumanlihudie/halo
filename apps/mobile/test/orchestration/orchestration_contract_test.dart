import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';

void main() {
  test('conversation command survives a JSON round trip', () {
    const command = StartConversationRunCommand(
      clientCommandId: 'command-1',
      conversationId: 'group-product',
      hostAgentId: 'product-manager',
      input: '请从产品和技术角度评估',
      replyMode: ConversationReplyMode.mentioned,
      memberAgentIds: ['product-manager', 'technical-architect'],
      mentionedAgentIds: ['technical-architect'],
    );

    final restored = StartConversationRunCommand.fromJson(command.toJson());

    expect(restored, command);
  });

  test('orchestration event survives a JSON round trip', () {
    final event = OrchestrationEvent(
      eventId: 'event-3',
      runId: 'run-1',
      seq: 3,
      type: OrchestrationEventType.agentMessageCompleted,
      stage: ConversationStage.responding,
      agentId: 'technical-architect',
      text: PublicEventText.trustedApplication('工程上可行。'),
      selectedAgentIds: ['technical-architect'],
    );

    final restored = OrchestrationEvent.fromJson(event.toJson());

    expect(restored, event);
  });
}
