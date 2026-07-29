import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/command_validation.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';
import 'package:halo_mobile/orchestration/wiring/run_input_repository.dart';

void main() {
  final validInputs = <String>['a' * 4096, '😀' * 4096, 'e\u0301' * 2048];
  final invalidInputs = <String>['😀' * 4097, 'e\u0301' * 2049];

  for (final input in validInputs) {
    test(
      'runner and repositories accept scalar/UTF-8 input boundary',
      () async {
        final command = _command(input: input);
        StartConversationCommandValidator.validate(command);
        final runner = BasicDurableRunner(
          store: InMemoryRunEventStore(),
          selector: const _Selector(),
          runtime: const _Runtime(),
        );
        expect((await runner.startRun(command)).runId, isNotEmpty);
        final memory = MemoryRunInputRepository();
        await memory.prepare(command);
        final directory = Directory.systemTemp.createTempSync('validator-');
        final sqlite = SqliteRunInputRepository.open(
          '${directory.path}/input.db',
        );
        await sqlite.prepare(command);
        await sqlite.close();
        await memory.close();
        directory.deleteSync(recursive: true);
      },
    );
  }

  for (final input in invalidInputs) {
    test('runner and repositories reject the same oversized input', () async {
      final command = _command(input: input);
      expect(
        () => StartConversationCommandValidator.validate(command),
        throwsArgumentError,
      );
      final runner = BasicDurableRunner(
        store: InMemoryRunEventStore(),
        selector: const _Selector(),
        runtime: const _Runtime(),
      );
      await expectLater(runner.startRun(command), throwsArgumentError);
      final memory = MemoryRunInputRepository();
      await expectLater(memory.prepare(command), throwsArgumentError);
    });
  }

  test('ID limits use Unicode scalars and UTF-8 bytes', () {
    StartConversationCommandValidator.validate(
      _command(clientCommandId: '😀' * 64),
    );
    for (final invalid in ['😀' * 65, 'e\u0301' * 128, ' ']) {
      expect(
        () => StartConversationCommandValidator.validate(
          _command(clientCommandId: invalid),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            contains('UTF-8 bytes'),
          ),
        ),
      );
    }
  });

  for (final surrogate in [
    String.fromCharCode(0xD800),
    String.fromCharCode(0xDFFF),
  ]) {
    for (final field in const [
      'input',
      'clientCommandId',
      'conversationId',
      'hostAgentId',
      'memberAgentIds',
      'mentionedAgentIds',
      'inputRef',
      'contextRef',
    ]) {
      test(
        '$field rejects an unpaired UTF-16 surrogate at every entry',
        () async {
          final command = _withInvalidField(field, surrogate);
          expect(
            () => StartConversationCommandValidator.validate(command),
            throwsA(
              isA<ArgumentError>().having(
                (error) => error.message.toString(),
                'message',
                contains('surrogate'),
              ),
            ),
          );
          final runner = BasicDurableRunner(
            store: InMemoryRunEventStore(),
            selector: const _Selector(),
            runtime: const _Runtime(),
          );
          await expectLater(runner.startRun(command), throwsArgumentError);
          final memory = MemoryRunInputRepository();
          await expectLater(memory.prepare(command), throwsArgumentError);
          final directory = Directory.systemTemp.createTempSync('surrogate-');
          final sqlite = SqliteRunInputRepository.open(
            '${directory.path}/input.db',
          );
          await expectLater(sqlite.prepare(command), throwsArgumentError);
          await sqlite.close();
          await memory.close();
          directory.deleteSync(recursive: true);
        },
      );
    }
  }

  test(
    'valid emoji pair and real replacement scalar remain distinct',
    () async {
      const emoji = '😀';
      const replacement = '\uFFFD';
      StartConversationCommandValidator.validate(_command(input: emoji));
      StartConversationCommandValidator.validate(_command(input: replacement));
      final invalid = _command(input: String.fromCharCode(0xD800));
      final memory = MemoryRunInputRepository();
      await expectLater(memory.prepare(invalid), throwsArgumentError);
      final memoryReservation = await memory.prepare(
        _command(input: replacement),
      );
      expect(memoryReservation.inputRef, isNotEmpty);
      final directory = Directory.systemTemp.createTempSync(
        'surrogate-collision-',
      );
      final sqlite = SqliteRunInputRepository.open(
        '${directory.path}/input.db',
      );
      await expectLater(sqlite.prepare(invalid), throwsArgumentError);
      final sqliteReservation = await sqlite.prepare(
        _command(input: replacement),
      );
      expect(sqliteReservation.inputRef, memoryReservation.inputRef);
      await sqlite.close();
      await memory.close();
      directory.deleteSync(recursive: true);
    },
  );
}

StartConversationRunCommand _command({
  String clientCommandId = 'validator-command',
  String input = 'safe',
}) => StartConversationRunCommand(
  clientCommandId: clientCommandId,
  conversationId: 'conversation',
  hostAgentId: 'host',
  input: input,
  replyMode: ConversationReplyMode.auto,
  memberAgentIds: const ['host'],
);

StartConversationRunCommand _withInvalidField(String field, String value) {
  final base = _command();
  return StartConversationRunCommand(
    clientCommandId: field == 'clientCommandId' ? value : base.clientCommandId,
    conversationId: field == 'conversationId' ? value : base.conversationId,
    hostAgentId: field == 'hostAgentId' ? value : base.hostAgentId,
    input: field == 'input' ? value : base.input,
    inputRef: field == 'inputRef' ? value : null,
    contextRef: field == 'contextRef' ? value : null,
    replyMode: base.replyMode,
    memberAgentIds: field == 'memberAgentIds'
        ? ['host', value]
        : base.memberAgentIds,
    mentionedAgentIds: field == 'mentionedAgentIds' ? [value] : const [],
  );
}

class _Selector implements AgentSelector {
  const _Selector();
  @override
  Future<List<String>> select(AgentSelectionRequest request) async => ['host'];
}

class _Runtime implements AgentRuntime, IdempotentAgentRuntimeCapability {
  const _Runtime();
  @override
  bool get supportsIdempotency => true;
  @override
  Future<String> respond(AgentTurnRequest request) async => 'ok';
  @override
  Future<String> summarize(DiscussionSummaryRequest request) async => 'ok';
}
