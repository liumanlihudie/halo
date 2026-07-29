import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/group_chat/group_chat_controller.dart';
import 'package:halo_mobile/features/group_chat/group_chat_history_repository.dart';
import 'package:halo_mobile/features/group_chat/group_chat_page.dart';
import 'package:halo_mobile/features/group_chat/group_members_repository.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';

void main() {
  group('GroupChatController', () {
    test('separate controllers do not reuse a command ID', () async {
      final firstPort = _FakeGroupChatRunPort();
      final secondPort = _FakeGroupChatRunPort();
      final first = _controller(port: firstPort);
      final second = _controller(port: secondPort);
      await Future.wait([first.initialize(), second.initialize()]);

      await first.submit(input: '第一个页面的问题', mode: ConversationReplyMode.auto);
      await second.submit(
        input: '重进同群后的不同问题',
        mode: ConversationReplyMode.auto,
      );

      expect(
        secondPort.lastCommand?.clientCommandId,
        isNot(firstPort.lastCommand?.clientCommandId),
      );
      first.dispose();
      second.dispose();
    });

    test('concurrent reentry of one submit starts exactly one run', () async {
      final startGate = Completer<RunHandle>();
      final port = _FakeGroupChatRunPort(startGate: startGate);
      final controller = _controller(port: port);
      await controller.initialize();

      final first = controller.submit(
        input: '同一次用户提交',
        mode: ConversationReplyMode.auto,
      );
      final reentered = controller.submit(
        input: '同一次用户提交',
        mode: ConversationReplyMode.auto,
      );
      await Future<void>.delayed(Duration.zero);

      expect(port.startCount, 1);
      startGate.complete(
        const RunHandle(runId: 'run-1', status: OrchestrationRunStatus.running),
      );
      await Future.wait([first, reentered]);
      expect(port.commands, hasLength(1));
      controller.dispose();
    });

    test('immediate dispose fences submit before startRun', () async {
      final port = _FakeGroupChatRunPort();
      final controller = _controller(port: port);
      await controller.initialize();

      final submission = controller.submit(
        input: '销毁后不得启动',
        mode: ConversationReplyMode.auto,
      );
      controller.dispose();
      await submission;

      expect(port.startCount, 0);
    });

    test(
      'dispose while watcher cancellation is blocked fences startRun',
      () async {
        final cancelGate = Completer<void>();
        final port = _FakeGroupChatRunPort(cancelGate: cancelGate);
        final controller = _controller(port: port);
        await controller.initialize();
        await controller.submit(input: '第一轮', mode: ConversationReplyMode.auto);
        port.emit(
          _event(
            seq: 1,
            type: OrchestrationEventType.runCompleted,
            stage: ConversationStage.completed,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final submission = controller.submit(
          input: '销毁期间的第二轮',
          mode: ConversationReplyMode.auto,
        );
        controller.dispose();
        cancelGate.complete();
        await submission;

        expect(port.startCount, 1);
      },
    );

    test('concurrent initialize shares one resume and one watcher', () async {
      final port = _FakeGroupChatRunPort();
      final history = _CountingHistoryRepository(
        GroupChatHistoryProjection(
          items: const [],
          activeRun: GroupChatRunProjection(
            runId: 'run-restored',
            input: '恢复中的问题',
            replyMode: ConversationReplyMode.auto,
            status: OrchestrationRunStatus.running,
            lastSeq: 1,
            events: [
              _event(
                runId: 'run-restored',
                seq: 1,
                type: OrchestrationEventType.runCreated,
                stage: ConversationStage.preparing,
              ),
            ],
          ),
        ),
      );
      final controller = _controller(port: port, history: history);

      await Future.wait([controller.initialize(), controller.initialize()]);

      expect(history.loadCount, 1);
      expect(port.resumedRunIds, const ['run-restored']);
      expect(port.watchRequests, const [(runId: 'run-restored', afterSeq: 1)]);
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(port.cancelledWatchCount, 1);
    });

    test(
      'dispose fences a pending initialize before resume and watch',
      () async {
        final port = _FakeGroupChatRunPort();
        final history = _DeferredHistoryRepository();
        final controller = _controller(port: port, history: history);

        final initialization = controller.initialize();
        controller.dispose();
        history.complete(
          GroupChatHistoryProjection(
            items: const [],
            activeRun: GroupChatRunProjection(
              runId: 'run-after-dispose',
              input: '不应恢复',
              replyMode: ConversationReplyMode.auto,
              status: OrchestrationRunStatus.running,
              lastSeq: 0,
              events: const [],
            ),
          ),
        );

        await initialization;
        expect(port.resumedRunIds, isEmpty);
        expect(port.watchRequests, isEmpty);
      },
    );

    test(
      'submit resolves canonical member IDs from the injected repository',
      () async {
        final port = _FakeGroupChatRunPort();
        final controller = _controller(port: port);

        await controller.initialize();
        await controller.submit(
          input: '判断这个 MVP 是否值得做',
          mode: ConversationReplyMode.auto,
        );

        expect(port.lastCommand?.memberAgentIds, const [
          'expert.product',
          'expert.ux',
          'expert.architecture',
          'expert.growth',
          'expert.qa',
        ]);
        expect(port.lastCommand?.hostAgentId, 'expert.product');
        controller.dispose();
      },
    );

    test(
      'initialize replays only a continuous prefix before watching a gap',
      () async {
        final port = _FakeGroupChatRunPort();
        final history = _FakeHistoryRepository(
          GroupChatHistoryProjection(
            items: const [
              GroupChatHistoryItem(
                type: GroupChatHistoryItemType.notice,
                text: '更早的持久消息',
              ),
            ],
            activeRun: GroupChatRunProjection(
              runId: 'run-restored',
              input: '恢复之前的问题',
              replyMode: ConversationReplyMode.mentioned,
              mentionedExpertIds: const ['expert.architecture'],
              status: OrchestrationRunStatus.running,
              lastSeq: 4,
              events: [
                _event(
                  runId: 'run-restored',
                  seq: 1,
                  type: OrchestrationEventType.agentsSelected,
                  stage: ConversationStage.responding,
                  selectedAgentIds: const ['expert.architecture'],
                ),
                _event(
                  runId: 'run-restored',
                  seq: 2,
                  type: OrchestrationEventType.agentMessageStarted,
                  stage: ConversationStage.responding,
                  agentId: 'expert.architecture',
                ),
                _event(
                  runId: 'run-restored',
                  seq: 4,
                  type: OrchestrationEventType.agentMessageCompleted,
                  stage: ConversationStage.responding,
                  agentId: 'expert.architecture',
                  text: '恢复出的架构回答',
                ),
              ],
            ),
          ),
        );
        final controller = _controller(port: port, history: history);

        await controller.initialize();

        expect(controller.historyItems.single.text, '更早的持久消息');
        expect(controller.runId, 'run-restored');
        expect(controller.submittedInput, '恢复之前的问题');
        expect(controller.lastSeq, 2);
        expect(
          controller.messages.single.status,
          GroupChatMessageStatus.running,
        );
        expect(port.resumedRunIds, const ['run-restored']);
        expect(port.watchRequests, const [
          (runId: 'run-restored', afterSeq: 2),
        ]);

        port.emit(
          _event(
            runId: 'run-restored',
            seq: 3,
            type: OrchestrationEventType.stageChanged,
            stage: ConversationStage.responding,
          ),
        );
        port.emit(
          _event(
            runId: 'run-restored',
            seq: 4,
            type: OrchestrationEventType.agentMessageCompleted,
            stage: ConversationStage.responding,
            agentId: 'expert.architecture',
            text: '补拉出的架构回答',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(controller.lastSeq, 4);
        expect(controller.messages.single.text, '补拉出的架构回答');

        port.emit(
          _event(
            runId: 'run-restored',
            seq: 5,
            type: OrchestrationEventType.summaryCompleted,
            stage: ConversationStage.summarizing,
            text: '恢复后的总结',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(controller.summary, '恢复后的总结');
        expect(controller.lastSeq, 5);
        controller.dispose();
      },
    );

    test('terminal event cancels the run watcher', () async {
      final port = _FakeGroupChatRunPort();
      final controller = _controller(port: port);
      await controller.initialize();
      await controller.submit(
        input: '完成后关闭监听',
        mode: ConversationReplyMode.auto,
      );

      port.emit(
        _event(
          seq: 1,
          type: OrchestrationEventType.runCompleted,
          stage: ConversationStage.completed,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.status, OrchestrationRunStatus.completed);
      expect(port.cancelledWatchCount, 1);
      controller.dispose();
    });

    test(
      'replacement run waits for the old watcher to finish cancelling',
      () async {
        final cancelGate = Completer<void>();
        final port = _FakeGroupChatRunPort(cancelGate: cancelGate);
        final controller = _controller(port: port);
        await controller.initialize();
        await controller.submit(input: '第一轮', mode: ConversationReplyMode.auto);
        port.emit(
          _event(
            seq: 1,
            type: OrchestrationEventType.runCompleted,
            stage: ConversationStage.completed,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final replacement = controller.submit(
          input: '第二轮',
          mode: ConversationReplyMode.auto,
        );
        await Future<void>.delayed(Duration.zero);

        expect(port.startCount, 1);
        cancelGate.complete();
        await replacement;
        expect(port.startCount, 2);
        expect(port.cancelledWatchCount, 1);
        controller.dispose();
      },
    );

    test(
      'watcher cancellation failure is recorded without poisoning replacement',
      () async {
        final port = _FakeGroupChatRunPort(cancelFailuresRemaining: 1);
        final controller = _controller(port: port);
        await controller.initialize();
        await controller.submit(input: '第一轮', mode: ConversationReplyMode.auto);
        port.emit(
          _event(
            seq: 1,
            type: OrchestrationEventType.runCompleted,
            stage: ConversationStage.completed,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(controller.errorCode, 'orchestration_watcher_cancel_failed');

        await controller.submit(
          input: '取消失败后的第二轮',
          mode: ConversationReplyMode.auto,
        );
        expect(port.startCount, 2);
        expect(port.watchRequests, hasLength(2));
        controller.dispose();
      },
    );

    test(
      'stream error cleanup consumes watcher cancellation failure',
      () async {
        final port = _FakeGroupChatRunPort(cancelFailuresRemaining: 1);
        final controller = _controller(port: port);
        await controller.initialize();
        await controller.submit(
          input: '等待流错误',
          mode: ConversationReplyMode.auto,
        );

        port.emitError(StateError('synthetic stream failure'));
        await Future<void>.delayed(Duration.zero);

        expect(controller.errorCode, 'orchestration_stream_failed');
        expect(
          controller.cleanupErrorCode,
          'orchestration_watcher_cancel_failed',
        );
        controller.dispose();
      },
    );

    test('dispose cleanup consumes watcher cancellation failure', () async {
      final port = _FakeGroupChatRunPort(cancelFailuresRemaining: 1);
      final controller = _controller(port: port);
      await controller.initialize();
      await controller.submit(
        input: '销毁并触发取消失败',
        mode: ConversationReplyMode.auto,
      );

      controller.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(
        controller.cleanupErrorCode,
        'orchestration_watcher_cancel_failed',
      );
    });

    test(
      'mentioned mode rejects zero, more than four, and non-members',
      () async {
        final controller = _controller(port: _FakeGroupChatRunPort());
        await controller.initialize();

        expect(
          () => controller.submit(
            input: '没有提及',
            mode: ConversationReplyMode.mentioned,
          ),
          throwsArgumentError,
        );
        expect(
          () => controller.submit(
            input: '提及太多',
            mode: ConversationReplyMode.mentioned,
            mentionedAgentIds: const [
              'expert.product',
              'expert.ux',
              'expert.architecture',
              'expert.growth',
              'expert.qa',
            ],
          ),
          throwsArgumentError,
        );
        expect(
          () => controller.submit(
            input: '提及外部成员',
            mode: ConversationReplyMode.mentioned,
            mentionedAgentIds: const ['expert.not-in-group'],
          ),
          throwsArgumentError,
        );
        controller.dispose();
      },
    );
  });

  group('GroupChatPage', () {
    testWidgets('auto input starts one run without inventing an Agent reply', (
      tester,
    ) async {
      final port = _FakeGroupChatRunPort();
      await _pumpGroupChat(tester, port);

      expect(find.text('当前：自动选择 1–2 位合适成员'), findsOneWidget);
      expect(find.text('向小组提问，系统将自动选择成员'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, '请评估这个 MVP');
      await tester.tap(find.bySemanticsLabel('发送'));
      await tester.pumpAndSettle();

      expect(port.startCount, 1);
      expect(port.lastCommand?.replyMode, ConversationReplyMode.auto);
      expect(find.text('请评估这个 MVP'), findsOneWidget);
      expect(find.text('正在思考…'), findsNothing);
    });

    testWidgets('mention picker selects multiple members and sends exact IDs', (
      tester,
    ) async {
      final port = _FakeGroupChatRunPort();
      await _pumpGroupChat(tester, port);

      await tester.tap(find.text('@指定成员'));
      await tester.pumpAndSettle();
      expect(find.text('选择 1–4 位成员'), findsOneWidget);

      await tester.tap(find.text('UX 设计师'));
      await tester.pump();
      await tester.tap(find.text('技术架构师'));
      await tester.pump();
      await tester.tap(find.text('确定（2）'));
      await tester.pumpAndSettle();

      expect(find.text('当前：仅 UX 设计师、技术架构师回答'), findsOneWidget);
      expect(find.text('向已选 2 位成员提问'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, '一起评审交互风险');
      await tester.tap(find.bySemanticsLabel('发送'));
      await tester.pumpAndSettle();

      expect(port.lastCommand?.replyMode, ConversationReplyMode.mentioned);
      expect(port.lastCommand?.mentionedAgentIds, const [
        'expert.ux',
        'expert.architecture',
      ]);
    });

    testWidgets('all mode sends every frozen member and projects run events', (
      tester,
    ) async {
      final port = _FakeGroupChatRunPort();
      await _pumpGroupChat(tester, port);

      await tester.tap(find.text('@所有成员'));
      await tester.pump();
      expect(find.text('当前：所有 5 位成员依次回答并总结'), findsOneWidget);
      expect(find.text('向全部成员提问'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, '所有人给出结论');
      await tester.tap(find.bySemanticsLabel('发送'));
      await tester.pump();

      expect(port.lastCommand?.replyMode, ConversationReplyMode.all);
      expect(port.lastCommand?.mentionedAgentIds, isEmpty);

      port.emit(
        _event(
          seq: 1,
          type: OrchestrationEventType.agentsSelected,
          stage: ConversationStage.collectingOpinions,
          selectedAgentIds: const [
            'expert.product',
            'expert.ux',
            'expert.architecture',
            'expert.growth',
            'expert.qa',
          ],
        ),
      );
      port.emit(
        _event(
          seq: 2,
          type: OrchestrationEventType.agentMessageStarted,
          stage: ConversationStage.responding,
          agentId: 'expert.product',
        ),
      );
      port.emit(
        _event(
          seq: 3,
          type: OrchestrationEventType.agentMessageCompleted,
          stage: ConversationStage.responding,
          agentId: 'expert.product',
          text: '先验证用户价值。',
        ),
      );
      port.emit(
        _event(
          seq: 4,
          type: OrchestrationEventType.stageChanged,
          stage: ConversationStage.summarizing,
        ),
      );
      port.emit(
        _event(
          seq: 5,
          type: OrchestrationEventType.summaryCompleted,
          stage: ConversationStage.summarizing,
          text: '总结：先做受控验证。',
        ),
      );
      port.emit(
        _event(
          seq: 6,
          type: OrchestrationEventType.runCompleted,
          stage: ConversationStage.completed,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('已选择 产品经理、UX 设计师、技术架构师、增长顾问、测试工程师'), findsOneWidget);
      expect(find.text('先验证用户价值。'), findsOneWidget);
      expect(find.text('总结：先做受控验证。'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);
      expect(port.cancelledWatchCount, 1);
    });
  });
}

GroupChatController _controller({
  required _FakeGroupChatRunPort port,
  GroupChatHistoryRepository? history,
}) => GroupChatController(
  runPort: port,
  conversationId: 'group-product',
  membersRepository: _FakeMembersRepository(),
  historyRepository:
      history ??
      const _FakeHistoryRepository(GroupChatHistoryProjection(items: [])),
);

Future<void> _pumpGroupChat(
  WidgetTester tester,
  _FakeGroupChatRunPort port,
) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: GroupChatPage(
          groupId: 'group-product',
          runPort: port,
          membersRepository: _FakeMembersRepository(),
          historyRepository: const _FakeHistoryRepository(
            GroupChatHistoryProjection(items: []),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

OrchestrationEvent _event({
  String runId = 'run-1',
  required int seq,
  required OrchestrationEventType type,
  required ConversationStage stage,
  String? agentId,
  String? text,
  List<String> selectedAgentIds = const [],
  String? errorCode,
}) => OrchestrationEvent(
  eventId: '$runId-event-$seq',
  runId: runId,
  seq: seq,
  type: type,
  stage: stage,
  agentId: agentId,
  text: text == null ? null : PublicEventText.trustedApplication(text),
  selectedAgentIds: selectedAgentIds,
  errorCode: errorCode,
);

class _FakeMembersRepository implements GroupMembersRepository {
  @override
  Future<List<GroupChatMember>> loadMembers(String conversationId) async =>
      _members;
}

final _members = [
  GroupChatMember(
    expertId: 'expert.product',
    displayName: '产品经理',
    role: '产品判断与需求拆解',
    avatarLetter: '产',
  ),
  GroupChatMember(
    expertId: 'expert.ux',
    displayName: 'UX 设计师',
    role: '体验与交互方案',
    avatarLetter: '设',
  ),
  GroupChatMember(
    expertId: 'expert.architecture',
    displayName: '技术架构师',
    role: '架构与工程风险',
    avatarLetter: '技',
  ),
  GroupChatMember(
    expertId: 'expert.growth',
    displayName: '增长顾问',
    role: '增长与验证策略',
    avatarLetter: '增',
  ),
  GroupChatMember(
    expertId: 'expert.qa',
    displayName: '测试工程师',
    role: '质量与验证',
    avatarLetter: '测',
  ),
];

class _FakeHistoryRepository implements GroupChatHistoryRepository {
  const _FakeHistoryRepository(this.projection);

  final GroupChatHistoryProjection projection;

  @override
  Future<GroupChatHistoryProjection> load(String conversationId) async =>
      projection;
}

class _CountingHistoryRepository implements GroupChatHistoryRepository {
  _CountingHistoryRepository(this.projection);

  final GroupChatHistoryProjection projection;
  int loadCount = 0;

  @override
  Future<GroupChatHistoryProjection> load(String conversationId) async {
    loadCount++;
    await Future<void>.delayed(Duration.zero);
    return projection;
  }
}

class _DeferredHistoryRepository implements GroupChatHistoryRepository {
  final _completer = Completer<GroupChatHistoryProjection>();

  void complete(GroupChatHistoryProjection projection) =>
      _completer.complete(projection);

  @override
  Future<GroupChatHistoryProjection> load(String conversationId) =>
      _completer.future;
}

class _FakeGroupChatRunPort implements GroupChatRunPort {
  _FakeGroupChatRunPort({
    this.startGate,
    this.cancelGate,
    this.cancelFailuresRemaining = 0,
  });

  final Completer<RunHandle>? startGate;
  final Completer<void>? cancelGate;
  int cancelFailuresRemaining;
  final _watchers =
      <
        ({
          String runId,
          int afterSeq,
          StreamController<OrchestrationEvent> controller,
        })
      >[];
  StartConversationRunCommand? lastCommand;
  final commands = <StartConversationRunCommand>[];
  int startCount = 0;
  int cancelledWatchCount = 0;
  final resumedRunIds = <String>[];
  final stoppedRunIds = <String>[];
  final watchRequests = <({String runId, int afterSeq})>[];

  void emit(OrchestrationEvent event) {
    for (final watcher in List.of(_watchers)) {
      if (watcher.runId == event.runId && event.seq > watcher.afterSeq) {
        watcher.controller.add(event);
      }
    }
  }

  void emitError(Object error) {
    for (final watcher in List.of(_watchers)) {
      watcher.controller.addError(error);
    }
  }

  @override
  Future<RunHandle> startRun(StartConversationRunCommand command) async {
    startCount++;
    lastCommand = command;
    commands.add(command);
    return startGate?.future ??
        const RunHandle(runId: 'run-1', status: OrchestrationRunStatus.running);
  }

  @override
  Stream<OrchestrationEvent> watchRun(String runId, {int afterSeq = 0}) {
    watchRequests.add((runId: runId, afterSeq: afterSeq));
    late final StreamController<OrchestrationEvent> watcher;
    watcher = StreamController<OrchestrationEvent>(
      onCancel: () async {
        try {
          await cancelGate?.future;
          if (cancelFailuresRemaining > 0) {
            cancelFailuresRemaining--;
            throw StateError('synthetic watcher cancellation failure');
          }
        } finally {
          cancelledWatchCount++;
          _watchers.removeWhere(
            (candidate) => identical(candidate.controller, watcher),
          );
        }
      },
    );
    _watchers.add((runId: runId, afterSeq: afterSeq, controller: watcher));
    return watcher.stream;
  }

  @override
  Future<void> requestStop(String runId) async {
    stoppedRunIds.add(runId);
  }

  @override
  Future<ResumeResult> resumeRun(String runId) async {
    resumedRunIds.add(runId);
    return ResumeResult(runId: runId, resumed: true);
  }
}
