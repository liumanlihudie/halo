import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/group_chat/group_chat_controller.dart';
import 'package:halo_mobile/features/group_chat/group_chat_page.dart';
import 'package:halo_mobile/orchestration/orchestration_kernel.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';

void main() {
  testWidgets('auto mode renders selected agents and streamed replies', (
    tester,
  ) async {
    final kernel = _FakeOrchestrationKernel();
    await _pumpGroupChat(tester, kernel);

    await tester.enterText(find.byType(TextField).last, '判断这个 MVP 是否值得做');
    await tester.tap(find.bySemanticsLabel('发送'));
    await tester.pumpAndSettle();

    expect(kernel.lastCommand?.conversationId, 'group-product');
    expect(kernel.lastCommand?.input, '判断这个 MVP 是否值得做');
    expect(kernel.lastCommand?.replyMode, ConversationReplyMode.auto);
    expect(kernel.lastCommand?.memberAgentIds, const [
      'product-manager',
      'interaction-designer',
      'technical-architect',
      'growth-advisor',
    ]);
    expect(kernel.lastCommand?.mentionedAgentIds, isEmpty);

    kernel.emit(
      _event(
        1,
        OrchestrationEventType.agentsSelected,
        ConversationStage.responding,
        selectedAgentIds: const ['product-manager', 'technical-architect'],
      ),
    );
    kernel.emit(
      _event(
        2,
        OrchestrationEventType.agentMessageStarted,
        ConversationStage.responding,
        agentId: 'product-manager',
      ),
    );
    kernel.emit(
      _event(
        3,
        OrchestrationEventType.agentMessageCompleted,
        ConversationStage.responding,
        agentId: 'product-manager',
        text: '建议先验证高频工作场景。',
      ),
    );
    kernel.emit(
      _event(
        4,
        OrchestrationEventType.agentMessageCompleted,
        ConversationStage.responding,
        agentId: 'technical-architect',
        text: '工程可行，先控制长期记忆边界。',
      ),
    );
    kernel.emit(
      _event(
        5,
        OrchestrationEventType.runCompleted,
        ConversationStage.completed,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已选择 产品经理、技术架构师'), findsOneWidget);
    expect(find.text('建议先验证高频工作场景。'), findsOneWidget);
    expect(find.text('工程可行，先控制长期记忆边界。'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
  });

  testWidgets('mention mode sends only the selected agent id', (tester) async {
    final kernel = _FakeOrchestrationKernel();
    await _pumpGroupChat(tester, kernel);

    await tester.tap(find.text('@某个 Agent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('技术架构师').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '只分析技术风险');
    await tester.tap(find.bySemanticsLabel('发送'));
    await tester.pumpAndSettle();

    expect(kernel.lastCommand?.replyMode, ConversationReplyMode.mentioned);
    expect(kernel.lastCommand?.mentionedAgentIds, const [
      'technical-architect',
    ]);
    expect(find.text('当前：仅技术架构师回答'), findsOneWidget);
  });

  testWidgets('discussion mode follows all-mode stages and summary events', (
    tester,
  ) async {
    final kernel = _FakeOrchestrationKernel();
    await _pumpGroupChat(tester, kernel);

    await tester.tap(find.text('让大家讨论'));
    await tester.enterText(find.byType(TextField).last, '大家讨论后给出结论');
    await tester.tap(find.bySemanticsLabel('发送'));
    await tester.pumpAndSettle();

    expect(kernel.lastCommand?.replyMode, ConversationReplyMode.all);
    expect(kernel.lastCommand?.mentionedAgentIds, isEmpty);

    kernel.emit(
      _event(
        1,
        OrchestrationEventType.stageChanged,
        ConversationStage.collectingOpinions,
      ),
    );
    await tester.pump();
    expect(find.text('观点收集'), findsOneWidget);

    kernel.emit(
      _event(
        2,
        OrchestrationEventType.stageChanged,
        ConversationStage.crossDiscussion,
      ),
    );
    kernel.emit(
      _event(
        3,
        OrchestrationEventType.stageChanged,
        ConversationStage.summarizing,
      ),
    );
    kernel.emit(
      _event(
        4,
        OrchestrationEventType.summaryCompleted,
        ConversationStage.summarizing,
        text: '结论：先做文字群聊编排闭环。',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('交叉讨论'), findsOneWidget);
    expect(find.text('群聊总结'), findsWidgets);
    expect(find.text('结论：先做文字群聊编排闭环。'), findsOneWidget);
  });

  testWidgets('running conversation can request stop and renders stop event', (
    tester,
  ) async {
    final kernel = _FakeOrchestrationKernel();
    await _pumpGroupChat(tester, kernel);

    await tester.enterText(find.byType(TextField).last, '开始分析');
    await tester.tap(find.bySemanticsLabel('发送'));
    await tester.pump();

    kernel.emit(
      _event(1, OrchestrationEventType.runCreated, ConversationStage.preparing),
    );
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('停止生成'));
    await tester.pump();
    expect(kernel.stoppedRunIds, const ['run-1']);

    kernel.emit(
      _event(2, OrchestrationEventType.runStopped, ConversationStage.stopped),
    );
    await tester.pumpAndSettle();
    expect(find.text('已停止'), findsOneWidget);
  });

  testWidgets('failed agent reply and failed run remain visible', (
    tester,
  ) async {
    final kernel = _FakeOrchestrationKernel();
    await _pumpGroupChat(tester, kernel);

    await tester.enterText(find.byType(TextField).last, '分析风险');
    await tester.tap(find.bySemanticsLabel('发送'));
    await tester.pump();

    kernel.emit(
      _event(
        1,
        OrchestrationEventType.agentMessageFailed,
        ConversationStage.responding,
        agentId: 'growth-advisor',
        errorCode: 'provider_timeout',
      ),
    );
    kernel.emit(
      _event(
        2,
        OrchestrationEventType.runFailed,
        ConversationStage.failed,
        errorCode: 'run_incomplete',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('provider_timeout'), findsOneWidget);
    expect(find.text('运行失败 · run_incomplete'), findsOneWidget);
  });

  testWidgets('run failure closes any still-running agent message', (
    tester,
  ) async {
    final kernel = _FakeOrchestrationKernel();
    await _pumpGroupChat(tester, kernel);

    await tester.enterText(find.byType(TextField).last, '分析风险');
    await tester.tap(find.bySemanticsLabel('发送'));
    await tester.pump();

    kernel.emit(
      _event(
        1,
        OrchestrationEventType.agentMessageStarted,
        ConversationStage.responding,
        agentId: 'technical-architect',
      ),
    );
    kernel.emit(
      _event(
        2,
        OrchestrationEventType.runFailed,
        ConversationStage.failed,
        errorCode: 'orchestration_failed',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('正在思考…'), findsNothing);
    expect(find.text('回答中断'), findsOneWidget);
  });

  testWidgets('@所有人 uses the same all reply mode', (tester) async {
    final kernel = _FakeOrchestrationKernel();
    await _pumpGroupChat(tester, kernel);

    await tester.tap(find.text('@所有人'));
    await tester.enterText(find.byType(TextField).last, '每个人都回答');
    await tester.tap(find.bySemanticsLabel('发送'));
    await tester.pump();

    expect(kernel.lastCommand?.replyMode, ConversationReplyMode.all);
  });

  test('a new submission preserves the completed turn', () async {
    final kernel = _FakeOrchestrationKernel();
    final controller = GroupChatController(
      kernel: kernel,
      conversationId: 'group-product',
    );
    await controller.submit(input: '第一轮问题', mode: ConversationReplyMode.auto);
    kernel.emit(
      _event(
        1,
        OrchestrationEventType.agentMessageCompleted,
        ConversationStage.responding,
        agentId: 'product-manager',
        text: '第一轮回答',
      ),
    );
    kernel.emit(
      _event(
        2,
        OrchestrationEventType.runCompleted,
        ConversationStage.completed,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    await controller.submit(input: '第二轮问题', mode: ConversationReplyMode.auto);

    expect(kernel.lastCommand?.input, '第二轮问题');
    expect(controller.pastTurns.single.input, '第一轮问题');
    expect(controller.pastTurns.single.messages.single.text, '第一轮回答');
    expect(controller.submittedInput, '第二轮问题');
    controller.dispose();
  });
}

Future<void> _pumpGroupChat(
  WidgetTester tester,
  _FakeOrchestrationKernel kernel,
) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: GroupChatPage(
          groupId: 'group-product',
          orchestrationKernel: kernel,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

OrchestrationEvent _event(
  int seq,
  OrchestrationEventType type,
  ConversationStage stage, {
  String? agentId,
  String? text,
  List<String> selectedAgentIds = const [],
  String? errorCode,
}) {
  return OrchestrationEvent(
    eventId: 'event-$seq',
    runId: 'run-1',
    seq: seq,
    type: type,
    stage: stage,
    agentId: agentId,
    text: text == null ? null : PublicEventText.trustedApplication(text),
    selectedAgentIds: selectedAgentIds,
    errorCode: errorCode,
  );
}

class _FakeOrchestrationKernel implements OrchestrationKernel {
  final _events = StreamController<OrchestrationEvent>.broadcast();
  StartConversationRunCommand? lastCommand;
  final stoppedRunIds = <String>[];

  void emit(OrchestrationEvent event) => _events.add(event);

  @override
  Future<RunHandle> startRun(StartConversationRunCommand command) async {
    lastCommand = command;
    return const RunHandle(
      runId: 'run-1',
      status: OrchestrationRunStatus.running,
    );
  }

  @override
  Stream<OrchestrationEvent> watchRun(String runId, {int afterSeq = 0}) =>
      _events.stream.where(
        (event) => event.runId == runId && event.seq > afterSeq,
      );

  @override
  Future<void> requestStop(String runId) async {
    stoppedRunIds.add(runId);
  }

  @override
  Future<ResumeResult> resumeRun(String runId) async =>
      ResumeResult(runId: runId, resumed: false);

  @override
  Future<RunSnapshot> getRun(String runId) async => RunSnapshot(
    runId: runId,
    status: OrchestrationRunStatus.running,
    lastSeq: 0,
    executableAgentIds: const [],
  );
}
