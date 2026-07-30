import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/production_app_kernel.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/drift_chat_message_repository.dart';

void main() {
  const oldSeed = {
    'general-assistant': SingleChatConversationProjection(
      conversationId: 'general-assistant',
      expertId: 'product-manager',
      title: '产品经理',
      agentName: '产品经理',
      modelLabel: '已配置文字模型',
      avatarLetter: '产',
    ),
  };
  const newSeed = {
    'general-assistant': SingleChatConversationProjection(
      conversationId: 'general-assistant',
      expertId: 'project-manager',
      title: '通用助理',
      agentName: '通用助理',
      modelLabel: '已配置文字模型',
      avatarLetter: '助',
    ),
  };

  Future<(String, String)> newStorage(String prefix) async {
    final directory = await Directory.systemTemp.createTemp(prefix);
    addTearDown(() => directory.deleteSync(recursive: true));
    return ('${directory.path}/history.sqlite', '${directory.path}/cmd.json');
  }

  test('an upgraded install repoints a repurposed conversation', () async {
    final (databasePath, outboxPath) = await newStorage('chat-rebind-');

    final before = await DriftChatMessageRepository.open(
      databasePath: databasePath,
      commandOutbox: FileSingleChatCommandOutbox(outboxPath),
      conversations: oldSeed,
    );
    await before.append(
      'general-assistant',
      const ChatMessageProjection(
        id: 'old:answer',
        kind: ChatMessageKind.agentText,
        text: '产品经理的历史回答',
      ),
    );
    await before.close();

    final after = await DriftChatMessageRepository.open(
      databasePath: databasePath,
      commandOutbox: FileSingleChatCommandOutbox(outboxPath),
      conversations: newSeed,
      supersededExpertBindings: const {'general-assistant': 'product-manager'},
    );

    expect(after.describe('general-assistant').expertId, 'project-manager');
    // The stored answer belonged to the previous expert, so it must not be
    // re-attributed to the new one.
    expect(await after.load('general-assistant'), isEmpty);
    await after.close();
  });

  test('an unexpected rebinding still fails closed', () async {
    final (databasePath, outboxPath) = await newStorage('chat-rebind-closed-');

    final before = await DriftChatMessageRepository.open(
      databasePath: databasePath,
      commandOutbox: FileSingleChatCommandOutbox(outboxPath),
      conversations: oldSeed,
    );
    await before.close();

    await expectLater(
      DriftChatMessageRepository.open(
        databasePath: databasePath,
        commandOutbox: FileSingleChatCommandOutbox(outboxPath),
        conversations: newSeed,
      ),
      throwsStateError,
    );

    // A migration entry for a different previous expert must not unlock it.
    await expectLater(
      DriftChatMessageRepository.open(
        databasePath: databasePath,
        commandOutbox: FileSingleChatCommandOutbox(outboxPath),
        conversations: newSeed,
        supersededExpertBindings: const {'general-assistant': 'ux-designer'},
      ),
      throwsStateError,
    );
  });

  test('production declares a migration for every changed seed binding', () {
    // Bindings shipped before installed contacts each got their own
    // conversation. Any future seed change must extend this list or existing
    // installs can never build a kernel again.
    const previouslyShipped = <String, String>{
      'general-assistant': 'product-manager',
      'data-analyst-chat': 'technical-architect',
    };

    for (final entry in previouslyShipped.entries) {
      final current = productionSingleChatConversations[entry.key];
      expect(current, isNotNull, reason: 'seed ${entry.key}');
      if (current!.expertId == entry.value) continue;
      expect(
        supersededSingleChatExpertBindings[entry.key],
        entry.value,
        reason: 'missing migration for ${entry.key}',
      );
    }
    expect(
      supersededSingleChatExpertBindings.keys,
      everyElement(isIn(productionSingleChatConversations.keys)),
    );
  });
}
