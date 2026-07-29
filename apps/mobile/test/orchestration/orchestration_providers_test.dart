import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/orchestration_providers.dart';

void main() {
  test('application provider exposes an executable local kernel', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final kernel = container.read(orchestrationKernelProvider);

    final handle = await kernel.startRun(
      const StartConversationRunCommand(
        clientCommandId: 'provider-command',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '检查 iOS 技术风险',
        replyMode: ConversationReplyMode.auto,
        memberAgentIds: [
          'product-manager',
          'interaction-designer',
          'technical-architect',
          'growth-advisor',
        ],
      ),
    );
    final events = <OrchestrationEvent>[];
    await for (final event
        in kernel.watchRun(handle.runId).timeout(const Duration(seconds: 2))) {
      events.add(event);
      if (event.type == OrchestrationEventType.runCompleted) {
        break;
      }
    }

    expect(
      events
          .singleWhere(
            (event) => event.type == OrchestrationEventType.agentsSelected,
          )
          .selectedAgentIds,
      contains('technical-architect'),
    );
    expect(
      events.where(
        (event) => event.type == OrchestrationEventType.agentMessageCompleted,
      ),
      isNotEmpty,
    );
  });
}
