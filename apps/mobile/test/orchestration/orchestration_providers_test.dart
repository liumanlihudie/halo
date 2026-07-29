import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/orchestration_providers.dart';

void main() {
  test('application provider exposes an executable local kernel', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final kernel = container.read(orchestrationKernelProvider);

    const command = StartConversationRunCommand(
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
    );
    final handle = await kernel.startRun(command);
    final duplicateHandle = await kernel.startRun(command);
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
    expect(duplicateHandle.runId, handle.runId);
    expect(
      events.where((event) => event.type == OrchestrationEventType.runCreated),
      hasLength(1),
    );

    final replay = await kernel
        .watchRun(handle.runId, afterSeq: 3)
        .take(events.length - 3)
        .toList();
    expect(replay.map((event) => event.seq), events.skip(3).map((e) => e.seq));
  });
}
