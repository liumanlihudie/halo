import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/single_chat/chat_details_page.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';
import 'package:halo_mobile/features/single_chat/single_chat_page.dart';
import 'package:halo_mobile/foundation/design_system/halo_theme.dart';

void main() {
  testWidgets(
    'single chat projects rich repository history and marks media unavailable',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: HaloTheme.light(),
          home: SingleChatPage(
            conversationId: 'general-assistant',
            repository: FixtureChatMessageRepository(
              commandOutbox: InMemorySingleChatCommandOutbox(),
              includeRichHistory: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('通用助理'), findsOneWidget);
      expect(find.text('个人 AI 通讯竞品分析.pdf'), findsOneWidget);
      expect(find.text('任务进行中'), findsOneWidget);
      expect(find.bySemanticsLabel('语音通话'), findsNothing);
      expect(find.bySemanticsLabel('视频通话'), findsNothing);

      await tester.tap(find.bySemanticsLabel('添加附件'));
      await tester.pumpAndSettle();
      expect(find.text('端到端语音通话'), findsOneWidget);
      expect(find.text('Vidu 视频通话'), findsOneWidget);
      expect(find.text('拍照'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);
      expect(find.text('暂不可用'), findsWidgets);
    },
  );

  testWidgets(
    'send binds the canonical expert and projects running then answer',
    (tester) async {
      final service = _FakeSingleChatPort();
      await tester.pumpWidget(
        _testApp(
          service: service,
          conversationId: 'data-analyst-chat',
          expertId: 'data-analyst',
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '分析本周漏斗');
      await tester.tap(find.bySemanticsLabel('发送'));
      await tester.pump();

      expect(find.text('分析本周漏斗'), findsOneWidget);
      expect(find.text('任务进行中'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '停止'), findsOneWidget);
      expect(service.requests.single.expertId, 'data-analyst');
      expect(service.requests.single.memberExpertIds, ['data-analyst']);

      service.completeNext(
        const SingleAgentRunOutcome.completed(
          answer: '本周移动端转化率提升 3%。',
          uncertainty: '仅覆盖 iOS 渠道样本',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('本周移动端转化率提升 3%。'), findsOneWidget);
      expect(find.text('未核验'), findsOneWidget);
      expect(find.text('不确定性：仅覆盖 iOS 渠道样本'), findsOneWidget);
      expect(find.text('任务进行中'), findsNothing);
    },
  );

  testWidgets('stop action projects stopped and cancels the active run', (
    tester,
  ) async {
    final service = _FakeSingleChatPort();
    await tester.pumpWidget(
      _testApp(
        service: service,
        conversationId: 'conversation-research',
        expertId: 'researcher',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '停止任务');
    await tester.tap(find.bySemanticsLabel('发送'));
    await tester.pump();
    final stopButton = find.widgetWithText(OutlinedButton, '停止');
    await tester.ensureVisible(stopButton);
    await tester.tap(stopButton);
    await tester.pumpAndSettle();

    expect(find.text('任务已停止'), findsOneWidget);
    expect(service.stoppedRunIds, ['run-1']);
  });

  for (final scenario in <(SingleAgentRunFailure, String, bool)>[
    (SingleAgentRunFailure.retryable, '发送失败，请重试', true),
    (SingleAgentRunFailure.quotaLimited, '模型额度不足，请检查 Provider 配额', false),
    (SingleAgentRunFailure.authentication, '模型认证失败，请检查 Provider 配置', false),
    (SingleAgentRunFailure.contentFiltered, '内容未通过安全检查', false),
  ]) {
    testWidgets('${scenario.$1.name} renders a safe run state', (tester) async {
      final service = _FakeSingleChatPort();
      await tester.pumpWidget(
        _testApp(
          service: service,
          conversationId: 'conversation-contract',
          expertId: 'contract',
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '审阅条款');
      await tester.tap(find.bySemanticsLabel('发送'));
      await tester.pump();
      service.completeNext(SingleAgentRunOutcome.failed(failure: scenario.$1));
      await tester.pumpAndSettle();

      expect(find.text(scenario.$2), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, '重试'),
        scenario.$3 ? findsOneWidget : findsNothing,
      );
    });
  }

  testWidgets('repository canonical expert mismatch is a bounded page state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: SingleChatPage(
          conversationId: 'data-analyst-chat',
          expertId: 'general',
          service: _FakeSingleChatPort(),
          repository: FixtureChatMessageRepository(),
          allowEphemeralRepositoryForTesting: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('聊天存储暂不可用，请稍后重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sync and async repository construction failures stay bounded', (
    tester,
  ) async {
    for (final loader in <FutureOr<ChatMessageRepository> Function()>[
      () => throw StateError('sensitive sync storage error'),
      () => Future<ChatMessageRepository>.error(
        StateError('sensitive async storage error'),
      ),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: HaloTheme.light(),
          home: SingleChatPage(
            conversationId: 'general-assistant',
            repositoryLoader: loader,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('聊天存储暂不可用，请稍后重试'), findsOneWidget);
      expect(find.bySemanticsLabel('发送'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('real service without durable repository fails closed', (
    tester,
  ) async {
    final service = _FakeSingleChatPort();
    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: SingleChatPage(
          conversationId: 'data-analyst-chat',
          service: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('聊天存储暂不可用，请稍后重试'), findsOneWidget);
    expect(service.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale repository loader cannot overwrite an updated page', (
    tester,
  ) async {
    final firstLoader = Completer<ChatMessageRepository>();
    final secondRepository = InMemoryChatMessageRepository(
      conversations: const {
        'conversation-b': SingleChatConversationProjection(
          conversationId: 'conversation-b',
          expertId: 'expert-b',
          title: '会话 B',
          agentName: '专家 B',
          modelLabel: 'Test / B',
          avatarLetter: 'B',
        ),
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: SingleChatPage(
          key: const ValueKey('same-single-chat-page'),
          conversationId: 'conversation-a',
          repositoryLoader: () => firstLoader.future,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: SingleChatPage(
          key: const ValueKey('same-single-chat-page'),
          conversationId: 'conversation-b',
          repository: secondRepository,
        ),
      ),
    );
    await tester.pumpAndSettle();
    firstLoader.complete(
      InMemoryChatMessageRepository(
        conversations: const {
          'conversation-a': SingleChatConversationProjection(
            conversationId: 'conversation-a',
            expertId: 'expert-a',
            title: '会话 A',
            agentName: '专家 A',
            modelLabel: 'Test / A',
            avatarLetter: 'A',
          ),
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('会话 B'), findsOneWidget);
    expect(find.text('会话 A'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('conversation update clears the prior conversation draft', (
    tester,
  ) async {
    final repository = InMemoryChatMessageRepository(
      conversations: const {
        'conversation-a': SingleChatConversationProjection(
          conversationId: 'conversation-a',
          expertId: 'expert-a',
          title: '会话 A',
          agentName: '专家 A',
          modelLabel: 'Test / A',
          avatarLetter: 'A',
        ),
        'conversation-b': SingleChatConversationProjection(
          conversationId: 'conversation-b',
          expertId: 'expert-b',
          title: '会话 B',
          agentName: '专家 B',
          modelLabel: 'Test / B',
          avatarLetter: 'B',
        ),
      },
    );
    const pageKey = ValueKey('draft-isolated-single-chat-page');
    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: SingleChatPage(
          key: pageKey,
          conversationId: 'conversation-a',
          repository: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '仅属于会话 A 的草稿');

    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: SingleChatPage(
          key: pageKey,
          conversationId: 'conversation-b',
          repository: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('会话 B'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
  });

  testWidgets('default single chat never seeds fake agent output or progress', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: const SingleChatPage(conversationId: 'general-assistant'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('收到。我先让研究员核验关键数据，再整理成市场格局、差异化和风险三部分。'), findsNothing);
    expect(find.text('任务进行中'), findsNothing);
    expect(find.text('个人 AI 通讯竞品分析.pdf'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('forged verified history is downgraded without attestation', (
    tester,
  ) async {
    final repository = InMemoryChatMessageRepository(
      conversations: const {
        'verified-history': SingleChatConversationProjection(
          conversationId: 'verified-history',
          expertId: 'fact-checker',
          title: '核验记录',
          agentName: '核验员',
          modelLabel: 'Verifier / test',
          avatarLetter: '核',
        ),
      },
      seed: const {
        'verified-history': [
          ChatMessageProjection(
            id: 'missing-uncertainty',
            kind: ChatMessageKind.agentText,
            text: '已核验但缺少不确定性',
            sourceType: ChatMessageSourceType.verifiedEvidence,
          ),
          ChatMessageProjection(
            id: 'blank-uncertainty',
            kind: ChatMessageKind.agentText,
            text: '已核验但不确定性为空白',
            sourceType: ChatMessageSourceType.verifiedEvidence,
            uncertainty: '   ',
          ),
        ],
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: SingleChatPage(
          conversationId: 'verified-history',
          expertId: 'fact-checker',
          repository: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已核验'), findsNothing);
    expect(find.text('未核验'), findsNWidgets(2));
  });

  testWidgets('trusted history revalidates receipt and binds uncertainty', (
    tester,
  ) async {
    final verifier = InMemoryTrustedVerifierReceiptRegistry(
      randomBytes: (length) => List<int>.filled(length, 3),
    );
    const claim = SingleChatVerificationClaim(
      conversationId: 'verified-history',
      expertId: 'fact-checker',
      runId: 'run-history',
      commandId: 'command-history',
      answer: '可信历史结论',
      canonicalEvidenceReferences: ['https://example.com/history'],
      uncertainty: '历史样本有限',
    );
    final token = verifier.issue(claim, validFor: const Duration(minutes: 5));
    final receiptId = verifier.verifyAndConsume(claim, token)!;
    final attestation = ChatMessageVerificationAttestation(
      receiptId: receiptId,
      expertId: 'fact-checker',
      runId: 'run-history',
      commandId: 'command-history',
    );
    final repository = InMemoryChatMessageRepository(
      conversations: const {
        'verified-history': SingleChatConversationProjection(
          conversationId: 'verified-history',
          expertId: 'fact-checker',
          title: '核验记录',
          agentName: '核验员',
          modelLabel: 'Verifier / test',
          avatarLetter: '核',
        ),
      },
      seed: {
        'verified-history': [
          ChatMessageProjection(
            id: 'command-history:answer',
            kind: ChatMessageKind.agentText,
            text: '可信历史结论',
            sourceType: ChatMessageSourceType.verifiedEvidence,
            uncertainty: '历史样本有限',
            evidenceReferences: const ['https://example.com/history'],
            verificationAttestation: attestation,
          ),
          ChatMessageProjection(
            id: 'tampered-history',
            kind: ChatMessageKind.agentText,
            text: '可信历史结论',
            sourceType: ChatMessageSourceType.verifiedEvidence,
            uncertainty: '被替换的不确定性',
            evidenceReferences: const ['https://example.com/history'],
            verificationAttestation: attestation,
          ),
        ],
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: SingleChatPage(
          conversationId: 'verified-history',
          expertId: 'fact-checker',
          repository: repository,
          verifier: verifier,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已核验'), findsOneWidget);
    expect(find.text('模型输出 · 附来源'), findsOneWidget);
    expect(find.text('不确定性：历史样本有限'), findsOneWidget);
  });

  testWidgets(
    'unsafe multiline and filler uncertainty cannot hide disclosure',
    (tester) async {
      const conversationId = 'unsafe-uncertainty-history';
      const commandId = 'unsafe-uncertainty-command';
      final repository = InMemoryChatMessageRepository(
        conversations: const {
          conversationId: SingleChatConversationProjection(
            conversationId: conversationId,
            expertId: 'fact-checker',
            title: '核验记录',
            agentName: '核验员',
            modelLabel: 'Verifier / test',
            avatarLetter: '核',
          ),
        },
        seed: const {
          conversationId: [
            ChatMessageProjection(
              id: '$commandId:answer',
              kind: ChatMessageKind.agentText,
              text: '不可把披露推离屏幕',
              sourceType: ChatMessageSourceType.verifiedEvidence,
              uncertainty: '\n\n\t\u2028样本有限',
              evidenceReferences: ['https://example.com/history'],
              verificationAttestation: ChatMessageVerificationAttestation(
                receiptId: 'trusted-receipt',
                expertId: 'fact-checker',
                runId: 'trusted-run',
                commandId: commandId,
              ),
            ),
            ChatMessageProjection(
              id: 'unsafe-filler-command:answer',
              kind: ChatMessageKind.agentText,
              text: '不可用填充字符伪装披露',
              sourceType: ChatMessageSourceType.verifiedEvidence,
              uncertainty: '\uffa0',
              evidenceReferences: ['https://example.com/history'],
              verificationAttestation: ChatMessageVerificationAttestation(
                receiptId: 'trusted-filler-receipt',
                expertId: 'fact-checker',
                runId: 'trusted-filler-run',
                commandId: 'unsafe-filler-command',
              ),
            ),
          ],
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: HaloTheme.light(),
          home: SingleChatPage(
            conversationId: conversationId,
            expertId: 'fact-checker',
            repository: repository,
            verifier: const _TrustAllPersistedReceipts(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('已核验'), findsNothing);
      expect(find.text('模型输出 · 附来源'), findsNWidgets(2));
      expect(find.textContaining('\n\n\t\u2028样本有限'), findsNothing);
      expect(find.textContaining('\uffa0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reserve failure keeps composer text and never escapes callback',
    (tester) async {
      final service = _FakeSingleChatPort();
      const conversationId = 'reserve-failure';
      await tester.pumpWidget(
        MaterialApp(
          theme: HaloTheme.light(),
          home: SingleChatPage(
            conversationId: conversationId,
            expertId: 'data-analyst',
            service: service,
            allowEphemeralRepositoryForTesting: true,
            repository: InMemoryChatMessageRepository(
              commandOutbox: _WidgetThrowingReserveOutbox(),
              conversations: const {
                conversationId: SingleChatConversationProjection(
                  conversationId: conversationId,
                  expertId: 'data-analyst',
                  title: '测试专家',
                  agentName: '测试专家',
                  modelLabel: 'Test / model',
                  avatarLetter: '测',
                ),
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '保留这段输入');
      await tester.tap(find.bySemanticsLabel('发送'));
      await tester.pumpAndSettle();

      expect(service.requests, isEmpty);
      expect(find.text('发送失败，请重试'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '保留这段输入',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('chat detail contains history categories and local controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: const ChatDetailsPage(conversationId: 'general-assistant'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('聊天详情'), findsOneWidget);
    expect(find.text('添加到群聊'), findsOneWidget);
    expect(find.text('图片与视频'), findsOneWidget);
    expect(find.text('AI 成果'), findsOneWidget);
    expect(find.text('重要消息提醒'), findsOneWidget);
  });
}

Widget _testApp({
  required _FakeSingleChatPort service,
  required String conversationId,
  required String expertId,
}) {
  return MaterialApp(
    theme: HaloTheme.light(),
    home: SingleChatPage(
      conversationId: conversationId,
      expertId: expertId,
      service: service,
      allowEphemeralRepositoryForTesting: true,
      repository: InMemoryChatMessageRepository(
        conversations: {
          conversationId: SingleChatConversationProjection(
            conversationId: conversationId,
            expertId: expertId,
            title: '测试专家',
            agentName: '测试专家',
            modelLabel: 'Test / model',
            avatarLetter: '测',
          ),
        },
      ),
    ),
  );
}

class _FakeSingleChatPort implements SingleChatPort {
  final requests = <StartSingleAgentRunRequest>[];
  final stoppedRunIds = <String>[];
  final _outcomes = <Completer<SingleAgentRunOutcome>>[];

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) async {
    requests.add(request);
    final outcome = Completer<SingleAgentRunOutcome>();
    _outcomes.add(outcome);
    return SingleAgentRunHandle(
      runId: 'run-${requests.length}',
      outcome: outcome.future,
    );
  }

  void completeNext(SingleAgentRunOutcome outcome) {
    _outcomes.firstWhere((item) => !item.isCompleted).complete(outcome);
  }

  @override
  Future<void> stopSingleAgentRun(String runId) async {
    stoppedRunIds.add(runId);
  }
}

class _WidgetThrowingReserveOutbox extends InMemorySingleChatCommandOutbox {
  @override
  SingleChatCommandRecord reserve({
    required String conversationId,
    required String normalizedIntent,
    required String Function() createCommandId,
  }) {
    throw StateError('sensitive reserve failure');
  }
}

class _TrustAllPersistedReceipts implements TrustedVerifierReceiptRegistry {
  const _TrustAllPersistedReceipts();

  @override
  bool validateConsumed(SingleChatVerificationClaim claim, String receiptId) =>
      true;

  @override
  String? verifyAndConsume(
    SingleChatVerificationClaim claim,
    SingleChatVerifierToken token,
  ) => null;
}
