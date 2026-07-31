import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/single_chat/chat_details_page.dart';
import 'package:halo_mobile/features/single_chat/chat_history_page.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';
import 'package:halo_mobile/features/single_chat/message_actions_service.dart';
import 'package:halo_mobile/features/single_chat/single_chat_page.dart';
import 'package:halo_mobile/foundation/design_system/halo_markdown_body.dart';
import 'package:halo_mobile/foundation/design_system/halo_theme.dart';
import 'package:halo_mobile/foundation/design_system/halo_wave_keys_indicator.dart';

void main() {
  testWidgets('long-pressing an agent reply offers copy and share', (
    tester,
  ) async {
    final copied = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: SingleChatPage(
          conversationId: 'general-assistant',
          repository: FixtureChatMessageRepository(
            commandOutbox: InMemorySingleChatCommandOutbox(),
            includeRichHistory: true,
          ),
          messageActions: MessageActionsService(
            copyToClipboard: (text) async => copied.add(text),
            shareText: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final agentText = find.textContaining('竞品分析').first;
    await tester.longPress(agentText);
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);

    // Copy is the quiet action: it confirms with a snackbar.
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copied, hasLength(1));
    expect(copied.single, contains('竞品分析'));
    expect(find.text('复制成功'), findsOneWidget);
  });

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

      expect(find.text('Halo 助理'), findsOneWidget);
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
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();

      expect(find.text('分析本周漏斗'), findsOneWidget);
      expect(find.byType(HaloWaveKeysIndicator), findsOneWidget);
      expect(find.text('任务进行中'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '停止'), findsNothing);
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
      expect(find.byType(HaloWaveKeysIndicator), findsNothing);
    },
  );

  testWidgets(
    'running bubble swaps the wave for a markdown preview while streaming',
    (tester) async {
      final service = _StreamingFakeSingleChatPort();
      await tester.pumpWidget(
        _testApp(
          service: service,
          conversationId: 'data-analyst-chat',
          expertId: 'data-analyst',
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '分析本周漏斗');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();

      // No partials yet: the running bubble shows only the wave.
      expect(find.byType(HaloWaveKeysIndicator), findsOneWidget);
      expect(find.byType(HaloMarkdownBody), findsNothing);

      service.partials.add('本周移动端转化率');
      await tester.pump();
      await tester.pump();

      // Same bubble, wave replaced by the growing Answer preview.
      expect(find.byType(HaloWaveKeysIndicator), findsNothing);
      expect(find.byType(HaloMarkdownBody), findsOneWidget);
      expect(find.textContaining('本周移动端转化率', findRichText: true), findsWidgets);

      service.complete(
        const SingleAgentRunOutcome.completed(answer: '本周移动端转化率提升 3%。'),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byType(HaloWaveKeysIndicator), findsNothing);
      expect(
        find.textContaining('本周移动端转化率提升 3%。', findRichText: true),
        findsWidgets,
      );
      await service.partials.close();
      await tester.pump();
    },
  );

  // The running bubble intentionally exposes no stop control, so stop
  // cancellation is exercised at the controller level.
  testWidgets('controller stop projects stopped and cancels the active run', (
    tester,
  ) async {
    final service = _FakeSingleChatPort();
    final controller = SingleChatController(
      conversationId: 'conversation-research',
      expertId: 'researcher',
      service: service,
      repository: InMemoryChatMessageRepository(
        conversations: const {
          'conversation-research': SingleChatConversationProjection(
            conversationId: 'conversation-research',
            expertId: 'researcher',
            title: '测试专家',
            agentName: '测试专家',
            modelLabel: 'Test / model',
            avatarLetter: '测',
          ),
        },
      ),
      commandIdFactory: () => 'command-stop',
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    unawaited(controller.submit('停止任务'));
    await tester.pump();
    expect(controller.state.status, SingleChatRunStatus.running);

    await controller.stop();
    await tester.pump();

    expect(controller.state.status, SingleChatRunStatus.stopped);
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
      await tester.testTextInput.receiveAction(TextInputAction.send);
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
      // The composer still renders; sending happens via the keyboard action,
      // so the attach affordance is what proves the composer is present.
      expect(find.bySemanticsLabel('发送'), findsNothing);
      expect(find.bySemanticsLabel('添加附件'), findsOneWidget);
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
      await tester.testTextInput.receiveAction(TextInputAction.send);
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

  testWidgets('chat detail keeps only controls that really work', (
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
    expect(find.text('导出聊天记录'), findsOneWidget);
    // The do-nothing switches described a product that was not running.
    expect(find.text('重要消息提醒'), findsNothing);
    expect(find.text('消息免打扰'), findsNothing);
    expect(find.text('设置当前聊天背景'), findsNothing);
  });

  testWidgets('export shares the real transcript as markdown', (tester) async {
    final repository = InMemoryChatMessageRepository(
      conversations: const {
        'general-assistant': SingleChatConversationProjection(
          conversationId: 'general-assistant',
          expertId: 'general-assistant',
          title: 'Halo 助理',
          agentName: 'Halo 助理',
          modelLabel: '已配置文字模型',
          avatarLetter: '助',
        ),
      },
    );
    await repository.append(
      'general-assistant',
      const ChatMessageProjection(
        id: 'cmd:user',
        kind: ChatMessageKind.userText,
        text: '生图测试',
      ),
    );
    await repository.append(
      'general-assistant',
      const ChatMessageProjection(
        id: 'cmd:answer',
        kind: ChatMessageKind.agentText,
        text: '画好了',
      ),
    );
    String? shared;
    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: ChatDetailsPage(
          conversationId: 'general-assistant',
          repository: repository,
          shareText: (text) async => shared = text,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出聊天记录'));
    await tester.pumpAndSettle();

    expect(shared, isNotNull);
    expect(shared, contains('# 与Halo 助理的对话'));
    expect(shared, contains('**我**：生图测试'));
    expect(shared, contains('**Halo 助理**：画好了'));
  });

  testWidgets('history page lists real messages and filters honestly', (
    tester,
  ) async {
    final repository = InMemoryChatMessageRepository(
      conversations: const {
        'general-assistant': SingleChatConversationProjection(
          conversationId: 'general-assistant',
          expertId: 'general-assistant',
          title: 'Halo 助理',
          agentName: 'Halo 助理',
          modelLabel: '已配置文字模型',
          avatarLetter: '助',
        ),
      },
    );
    await repository.append(
      'general-assistant',
      const ChatMessageProjection(
        id: 'cmd:user',
        kind: ChatMessageKind.userText,
        text: '帮我查一下 https://example.com/report 的内容',
      ),
    );
    await repository.append(
      'general-assistant',
      const ChatMessageProjection(
        id: 'cmd:asset:0',
        kind: ChatMessageKind.agentImage,
        imageUrl: '/tmp/gen-1.png',
        text: '',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: HaloTheme.light(),
        home: ChatHistoryPage(
          conversationId: 'general-assistant',
          repository: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 全部: both entries, nothing invented.
    expect(find.textContaining('example.com/report'), findsOneWidget);
    expect(find.text('专家生成的图片'), findsOneWidget);

    // AI 成果 keeps only what the expert made.
    await tester.tap(find.text('AI 成果'));
    await tester.pumpAndSettle();
    expect(find.text('专家生成的图片'), findsOneWidget);
    expect(find.textContaining('example.com/report'), findsNothing);

    // 文件 is honestly empty: no file messages exist.
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('这个对话里还没有文件'), findsOneWidget);
  });
}

Widget _testApp({
  required SingleChatPort service,
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

class _StreamingFakeSingleChatPort implements SingleChatPort {
  final partials = StreamController<String>.broadcast();
  final _outcome = Completer<SingleAgentRunOutcome>();

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) async {
    return SingleAgentRunHandle(
      runId: 'run-streaming',
      outcome: _outcome.future,
      partialAnswers: partials.stream,
    );
  }

  void complete(SingleAgentRunOutcome outcome) => _outcome.complete(outcome);

  @override
  Future<void> stopSingleAgentRun(String runId) async {}
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
