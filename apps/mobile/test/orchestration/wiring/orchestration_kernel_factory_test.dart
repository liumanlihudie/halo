import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/persistence/sqlite_run_event_store.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';
import 'package:halo_mobile/orchestration/wiring/orchestration_kernel_factory.dart';
import 'package:halo_mobile/orchestration/wiring/run_input_repository.dart';

void main() {
  test(
    'production opens lock and both databases through one canonical path',
    () async {
      final parent = Directory.systemTemp.createTempSync('halo-wiring-');
      final target = Directory('${parent.path}/target')..createSync();
      final alias = Link('${parent.path}/alias')..createSync(target.path);
      final openedPaths = <String>[];
      final factory = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(alias.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
        bundleOpener: _TestBundleOpener(
          openEvent: (path) {
            openedPaths.add(path);
            return InMemoryRunEventStore();
          },
          openInput: (path) {
            openedPaths.add(path);
            return _FakeDurableRepository();
          },
        ),
      );

      await factory.create();
      final canonicalTarget = target.resolveSymbolicLinksSync();
      expect(openedPaths, [
        '$canonicalTarget${Platform.pathSeparator}halo_orchestration.sqlite',
        '$canonicalTarget${Platform.pathSeparator}halo_run_inputs.sqlite',
      ]);
      await factory.close();
      parent.deleteSync(recursive: true);
    },
  );

  test(
    'production allows only one kernel owner for a canonical app-support path',
    () async {
      final directory = Directory.systemTemp.createTempSync('halo-wiring-');
      final alias = Directory(
        '${directory.path}${Platform.pathSeparator}nested'
        '${Platform.pathSeparator}..',
      );
      final first = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
      );
      final second = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(alias.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
      );

      final firstKernel = await first.create();
      await expectLater(second.create(), throwsStateError);
      await second.close();
      await firstKernel.close();

      final replacement = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
      );
      final replacementKernel = await replacement.create();
      await replacementKernel.close();
      await replacement.close();
      await first.close();
      directory.deleteSync(recursive: true);
    },
  );

  test(
    'close drains blocked selector before releasing production directory lease',
    () async {
      final directory = Directory.systemTemp.createTempSync('halo-wiring-');
      final selector = _CloseBlockingSelector();
      final first = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: selector,
        runtime: const _Runtime(),
      );
      final firstKernel = await first.create();
      await firstKernel.startRun(_command());
      await selector.started.future.timeout(const Duration(seconds: 2));

      var closed = false;
      final close = firstKernel.close().then((_) => closed = true);
      expect(identical(firstKernel.close(), firstKernel.close()), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);

      final blockedReplacement = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
      );
      await expectLater(blockedReplacement.create(), throwsStateError);
      await blockedReplacement.close();

      selector.complete(['product-manager']);
      await close.timeout(const Duration(seconds: 2));
      expect(closed, isTrue);

      final replacement = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
      );
      final replacementKernel = await replacement.create();
      await replacementKernel.close();
      await replacement.close();
      await first.close();
      directory.deleteSync(recursive: true);
    },
  );

  test(
    'close drains blocked runtime before closing stores without async errors',
    () async {
      final runtime = _CloseBlockingRuntime();
      final repository = MemoryRunInputRepository();
      final factory = OrchestrationKernelFactory.testing(
        inputRepository: repository,
        selector: const _Selector(),
        runtime: runtime,
      );
      final kernel = await factory.create();
      await kernel.startRun(_command());
      await runtime.started.future.timeout(const Duration(seconds: 2));

      var closed = false;
      final close = kernel.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);

      runtime.complete('late reply');
      await close.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(closed, isTrue);
      await factory.close();
    },
  );

  test(
    'close drains a blocked resume resolver before releasing its lease',
    () async {
      final directory = Directory.systemTemp.createTempSync('halo-wiring-');
      final store = InMemoryRunEventStore();
      final repository = _BlockingResolveDurableRepository();
      final command = StartConversationRunCommand(
        clientCommandId: 'resume-during-close',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '分析风险',
        inputRef: 'input-ref',
        contextRef: 'context-ref',
        replyMode: ConversationReplyMode.auto,
        memberAgentIds: const ['product-manager'],
      );
      final runId = store.createRun(command).snapshot.runId;
      final first = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
        bundleOpener: _TestBundleOpener(
          openEvent: (_) => store,
          openInput: (_) => repository,
        ),
      );
      final kernel = await first.create();
      final resume = kernel.resumeRun(runId);
      await repository.started.future.timeout(const Duration(seconds: 2));

      var closed = false;
      final close = kernel.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);

      final blockedReplacement = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
      );
      await expectLater(blockedReplacement.create(), throwsStateError);
      await blockedReplacement.close();

      repository.complete('分析风险');
      expect(
        (await resume.timeout(const Duration(seconds: 2))).resumed,
        isTrue,
      );
      await close.timeout(const Duration(seconds: 2));

      final replacement = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
      );
      await replacement.create();
      await replacement.close();
      await first.close();
      directory.deleteSync(recursive: true);
    },
  );

  test('close drains startRun while repository prepare is blocked', () async {
    final repository = _BlockingPrepareRepository();
    final factory = OrchestrationKernelFactory.testing(
      inputRepository: repository,
      selector: const _Selector(),
      runtime: const _Runtime(),
    );
    final kernel = await factory.create();
    final start = kernel.startRun(_command());
    await repository.started.future.timeout(const Duration(seconds: 2));

    var closed = false;
    final close = kernel.close().then((_) => closed = true);
    expect(identical(kernel.close(), kernel.close()), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    await expectLater(kernel.startRun(_command()), throwsStateError);

    repository.complete();
    await start.timeout(const Duration(seconds: 2));
    await close.timeout(const Duration(seconds: 2));
    expect(closed, isTrue);
    await factory.close();
  });

  test('close drains startRun while repository commit is blocked', () async {
    final repository = _BlockingCommitRepository();
    final factory = OrchestrationKernelFactory.testing(
      inputRepository: repository,
      selector: const _Selector(),
      runtime: const _Runtime(),
    );
    final kernel = await factory.create();
    final start = kernel.startRun(_command());
    await repository.started.future.timeout(const Duration(seconds: 2));

    var closed = false;
    final close = kernel.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);

    repository.complete();
    await start.timeout(const Duration(seconds: 2));
    await close.timeout(const Duration(seconds: 2));
    expect(closed, isTrue);
    await factory.close();
  });

  test('failed public operation decrements the close drain count', () async {
    final operationError = StateError('prepare failed');
    final repository = _BlockingPrepareRepository();
    final factory = OrchestrationKernelFactory.testing(
      inputRepository: repository,
      selector: const _Selector(),
      runtime: const _Runtime(),
    );
    final kernel = await factory.create();
    final start = kernel.startRun(_command());
    await repository.started.future.timeout(const Duration(seconds: 2));
    final close = kernel.close();

    repository.fail(operationError);
    await expectLater(start, throwsA(same(operationError)));
    await close.timeout(const Duration(seconds: 2));
    await factory.close();
  });

  test('production honors an exclusive lock held by another process', () async {
    final directory = Directory.systemTemp.createTempSync('halo-wiring-');
    final lockFile = File(
      '${directory.path}${Platform.pathSeparator}.halo_orchestration.lock',
    );
    final lockHolderScript = File(
      '${directory.path}${Platform.pathSeparator}lock_holder.dart',
    );
    lockHolderScript.writeAsStringSync('''
import 'dart:io';

Future<void> main(List<String> args) async {
  final handle = File(args.single).openSync(mode: FileMode.append);
  handle.lockSync(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.first;
  handle.unlockSync();
  handle.closeSync();
}
''');
    final lockHolder = await Process.start('dart', [
      lockHolderScript.path,
      lockFile.path,
    ]);
    addTearDown(() {
      lockHolder.kill();
    });
    expect(
      await lockHolder.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((line) => line == 'locked')
          .first
          .timeout(const Duration(seconds: 2)),
      'locked',
    );
    final blocked = OrchestrationKernelFactory.production(
      appSupportDirectory: _DirectoryProvider(directory.path),
      selector: const _Selector(),
      runtime: const _Runtime(),
    );

    await expectLater(blocked.create(), throwsA(isA<FileSystemException>()));
    await blocked.close();
    lockHolder.stdin.writeln('release');
    await lockHolder.stdin.flush();
    expect(await lockHolder.exitCode.timeout(const Duration(seconds: 2)), 0);

    final replacement = OrchestrationKernelFactory.production(
      appSupportDirectory: _DirectoryProvider(directory.path),
      selector: const _Selector(),
      runtime: const _Runtime(),
    );
    await replacement.create();
    await replacement.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'production initialization failure releases its directory lease',
    () async {
      final directory = Directory.systemTemp.createTempSync('halo-wiring-');
      final failing = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
        bundleOpener: _TestBundleOpener(
          openEvent: (_) => InMemoryRunEventStore(),
          openInput: (_) => throw StateError('input open failed'),
        ),
      );

      await expectLater(failing.create(), throwsStateError);
      await failing.close();

      final replacement = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
      );
      await replacement.create();
      await replacement.close();
      directory.deleteSync(recursive: true);
    },
  );

  test('production opens the injected app-support SQLite path', () async {
    final directory = Directory.systemTemp.createTempSync('halo-wiring-');
    final factory = OrchestrationKernelFactory.production(
      appSupportDirectory: _DirectoryProvider(directory.path),
      selector: const _Selector(),
      runtime: const _Runtime(),
    );
    addTearDown(() async {
      await factory.close();
      directory.deleteSync(recursive: true);
    });

    final kernel = await factory.create();
    const privateInput = 'PRIVATE_PROMPT_FACTORY_SENTINEL';
    final handle = await kernel.startRun(_command(input: privateInput));
    await _waitForTerminal(kernel, handle.runId);

    final database = File(
      '${directory.path}${Platform.pathSeparator}halo_orchestration.sqlite',
    );
    final inputDatabase = File(
      '${directory.path}${Platform.pathSeparator}halo_run_inputs.sqlite',
    );
    expect(database.existsSync(), isTrue);
    expect(inputDatabase.existsSync(), isTrue);
  });

  test('production reopens both databases and resumes a real run', () async {
    final directory = Directory.systemTemp.createTempSync('halo-wiring-');
    final eventPath =
        '${directory.path}${Platform.pathSeparator}halo_orchestration.sqlite';
    final inputPath =
        '${directory.path}${Platform.pathSeparator}halo_run_inputs.sqlite';
    final command = _command();
    final inputRepository = SqliteRunInputRepository.open(inputPath);
    final reservation = await inputRepository.prepare(command);
    await inputRepository.commit(reservation);
    final eventStore = SqliteRunEventStore.open(eventPath);
    final runId = eventStore
        .createRun(_withReferences(command, reservation))
        .snapshot
        .runId;
    await eventStore.close();
    await inputRepository.close();

    final factory = OrchestrationKernelFactory.production(
      appSupportDirectory: _DirectoryProvider(directory.path),
      selector: const _Selector(),
      runtime: const _Runtime(),
    );
    addTearDown(() async {
      await factory.close();
      directory.deleteSync(recursive: true);
    });
    final kernel = await factory.create();

    final result = await kernel.resumeRun(runId);
    expect(result.resumed, isTrue);
    final events = await _waitForTerminal(kernel, runId);
    expect(events.last.type, OrchestrationEventType.runCompleted);
  });

  test(
    'testing factory is explicitly in-memory and never asks for a path',
    () async {
      final factory = OrchestrationKernelFactory.testing(
        inputRepository: MemoryRunInputRepository(),
        selector: const _Selector(),
        runtime: const _Runtime(),
      );
      addTearDown(factory.close);

      final first = await factory.create();
      final second = await factory.create();
      final handle = await first.startRun(_command());
      final events = await _waitForTerminal(first, handle.runId);

      expect(identical(first, second), isTrue);
      expect(events.last.type, OrchestrationEventType.runCompleted);
    },
  );

  test(
    'input is committed before createRun and a new orphan is compensated',
    () async {
      final operations = <String>[];
      final repository = _FakeDurableRepository(operations: operations);
      final factory = OrchestrationKernelFactory.testing(
        inputRepository: repository,
        selector: const _Selector(),
        runtime: const _Runtime(),
        createStore: () => _FailingCreateStore(
          beforeFailure: () {
            expect(repository.lastCommitted, isTrue);
            operations.add('createRun');
          },
        ),
      );
      addTearDown(factory.close);
      final kernel = await factory.create();

      await expectLater(kernel.startRun(_command()), throwsStateError);
      expect(operations, ['prepare', 'commit', 'createRun', 'rollback']);

      final replacement = await repository.prepare(_command(input: '新正文'));
      await repository.rollback(replacement);
    },
  );

  test(
    'createRun failure does not delete an existing idempotent input',
    () async {
      final repository = _FakeDurableRepository();
      final existing = await repository.prepare(_command());
      await repository.commit(existing);
      final factory = OrchestrationKernelFactory.testing(
        inputRepository: repository,
        selector: const _Selector(),
        runtime: const _Runtime(),
        createStore: () => _FailingCreateStore(),
      );
      addTearDown(factory.close);
      final kernel = await factory.create();

      await expectLater(kernel.startRun(_command()), throwsStateError);

      expect(
        await repository.resolve(
          inputRef: existing.inputRef,
          contextRef: existing.contextRef,
        ),
        '分析风险',
      );
    },
  );

  test(
    'failure after createRun leaves resolvable input and retry confirms it',
    () async {
      final repository = _FakeDurableRepository(failFirstMarkReferenced: true);
      final factory = OrchestrationKernelFactory.testing(
        inputRepository: repository,
        selector: const _Selector(),
        runtime: const _Runtime(),
      );
      addTearDown(factory.close);
      final kernel = await factory.create();

      await expectLater(kernel.startRun(_command()), throwsStateError);
      final reservation = await repository.prepare(_command());
      expect(
        await repository.resolve(
          inputRef: reservation.inputRef,
          contextRef: reservation.contextRef,
        ),
        '分析风险',
      );
      expect(
        await repository.lifecycleOf(reservation),
        RunInputLifecycle.resolvableOrphan,
      );

      final handle = await kernel.startRun(_command());
      expect(handle.runId, isNotEmpty);
      await _waitForTerminal(kernel, handle.runId);
      expect(
        await repository.lifecycleOf(reservation),
        RunInputLifecycle.referenced,
      );
    },
  );

  test(
    'missing repository reference makes restart recovery fail closed',
    () async {
      final directory = Directory.systemTemp.createTempSync('halo-wiring-');
      final path =
          '${directory.path}${Platform.pathSeparator}halo_orchestration.sqlite';
      final command = _command();
      final setupRepository = _FakeDurableRepository();
      final reservation = await setupRepository.prepare(command);
      await setupRepository.commit(reservation);
      final setupStore = SqliteRunEventStore.open(path);
      final runId = setupStore
          .createRun(_withReferences(command, reservation))
          .snapshot
          .runId;
      await setupStore.close();
      await setupRepository.close();

      final factory = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
      );
      addTearDown(() async {
        await factory.close();
        directory.deleteSync(recursive: true);
      });
      final kernel = await factory.create();

      await expectLater(
        kernel.resumeRun(runId),
        throwsA(isA<RunInputUnavailable>()),
      );
    },
  );

  test(
    'createRun persisted then threw keeps and confirms the referenced input',
    () async {
      final directory = Directory.systemTemp.createTempSync('halo-wiring-');
      final repository = _FakeDurableRepository();
      final store = _PersistThenThrowStore();
      final original = StateError('createRun persisted then failed');
      store.error = original;
      final factory = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
        bundleOpener: _TestBundleOpener(
          openEvent: (_) => store,
          openInput: (_) => repository,
        ),
      );
      addTearDown(() async {
        await factory.close();
        directory.deleteSync(recursive: true);
      });
      final kernel = await factory.create();

      await expectLater(kernel.startRun(_command()), throwsA(same(original)));

      final reservation = await repository.prepare(_command());
      expect(
        await repository.lifecycleOf(reservation),
        RunInputLifecycle.referenced,
      );
      expect(repository.operations, isNot(contains('rollback')));
    },
  );

  test(
    'probe failure preserves the input and rethrows the delegate error',
    () async {
      final original = StateError('delegate failed');
      final repository = _FakeDurableRepository();
      final factory = OrchestrationKernelFactory.testing(
        inputRepository: repository,
        selector: const _Selector(),
        runtime: const _Runtime(),
        createStore: () => _ProbeThrowingFailingStore(original),
      );
      addTearDown(factory.close);
      final kernel = await factory.create();

      Object? caught;
      StackTrace? caughtStack;
      try {
        await kernel.startRun(_command());
      } on Object catch (error, stackTrace) {
        caught = error;
        caughtStack = stackTrace;
      }
      expect(caught, same(original));
      expect(caughtStack.toString(), contains('_FailingCreateStore.createRun'));

      final reservation = await repository.prepare(_command());
      expect(
        await repository.lifecycleOf(reservation),
        RunInputLifecycle.resolvableOrphan,
      );
      expect(repository.operations, isNot(contains('rollback')));
    },
  );

  test(
    'rollback and mark failures never replace commit or delegate errors',
    () async {
      final commitError = StateError('commit failed');
      final commitRepository = _FakeDurableRepository(
        commitError: commitError,
        rollbackError: StateError('rollback failed'),
      );
      final commitFactory = OrchestrationKernelFactory.testing(
        inputRepository: commitRepository,
        selector: const _Selector(),
        runtime: const _Runtime(),
      );
      addTearDown(commitFactory.close);
      final commitKernel = await commitFactory.create();
      await expectLater(
        commitKernel.startRun(_command()),
        throwsA(same(commitError)),
      );

      final delegateError = StateError('delegate failed');
      final markRepository = _FakeDurableRepository(
        markReferencedError: StateError('mark failed'),
      );
      final markFactory = OrchestrationKernelFactory.testing(
        inputRepository: markRepository,
        selector: const _Selector(),
        runtime: const _Runtime(),
        createStore: () => _ReferenceReportingFailingStore(delegateError),
      );
      addTearDown(markFactory.close);
      final markKernel = await markFactory.create();
      await expectLater(
        markKernel.startRun(_command()),
        throwsA(same(delegateError)),
      );
    },
  );

  test(
    'production startup collects old orphans with the injected probe',
    () async {
      final directory = Directory.systemTemp.createTempSync('halo-wiring-');
      DateTime? observedOlderThan;
      RunInputReferenceProbe? observedProbe;
      final repository = _FakeDurableRepository(
        onCollect: (olderThan, probe) {
          observedOlderThan = olderThan;
          observedProbe = probe;
        },
      );
      final eventStore = InMemoryRunEventStore();
      eventStore.createRun(
        _withReferences(_command(), await repository.prepare(_command())),
      );
      final factory = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        clock: () => DateTime.utc(2026, 7, 29, 12),
        orphanGracePeriod: const Duration(hours: 6),
        selector: const _Selector(),
        runtime: const _Runtime(),
        bundleOpener: _TestBundleOpener(
          openEvent: (_) => eventStore,
          openInput: (_) => repository,
        ),
      );
      addTearDown(() async {
        await factory.close();
        directory.deleteSync(recursive: true);
      });

      final first = await factory.create();
      final second = await factory.create();

      expect(identical(first, second), isTrue);
      expect(observedOlderThan, DateTime.utc(2026, 7, 29, 6));
      expect(
        await observedProbe!(
          eventStore.getWorkItem('run-1').inputRef!,
          eventStore.getWorkItem('run-1').contextRef!,
        ),
        isTrue,
      );
      expect(
        repository.operations.where((item) => item == 'collectOrphans'),
        hasLength(1),
      );
    },
  );

  test(
    'GC failure fails initialization closed and cleans all owners',
    () async {
      final closeOrder = <String>[];
      final directory = Directory.systemTemp.createTempSync('halo-wiring-');
      final repository = _FakeDurableRepository(
        closeOrder: closeOrder,
        collectError: StateError('GC failed'),
      );
      final factory = OrchestrationKernelFactory.production(
        appSupportDirectory: _DirectoryProvider(directory.path),
        selector: const _Selector(),
        runtime: const _Runtime(),
        bundleOpener: _TestBundleOpener(
          openEvent: (_) => _TrackingStore(closeOrder),
          openInput: (_) => repository,
        ),
      );

      await expectLater(
        factory.create(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'GC failed',
          ),
        ),
      );
      await factory.close();

      expect(closeOrder, ['store', 'repository']);
      directory.deleteSync(recursive: true);
    },
  );

  test('close is ordered, bounded, and idempotent', () async {
    final closeOrder = <String>[];
    final repository = _TrackingDurableRepository(closeOrder);
    final factory = OrchestrationKernelFactory.testing(
      inputRepository: repository,
      selector: const _Selector(),
      runtime: const _Runtime(),
      createStore: () => _TrackingStore(closeOrder),
    );
    final kernel = await factory.create();

    await kernel.close().timeout(const Duration(seconds: 1));
    await kernel.close().timeout(const Duration(seconds: 1));
    await factory.close().timeout(const Duration(seconds: 1));

    expect(closeOrder, ['store', 'repository']);
    await expectLater(kernel.startRun(_command()), throwsStateError);
  });

  test('repository still closes when store close fails', () async {
    final closeOrder = <String>[];
    final factory = OrchestrationKernelFactory.testing(
      inputRepository: _TrackingRepository(closeOrder),
      selector: const _Selector(),
      runtime: const _Runtime(),
      createStore: () => _ThrowingCloseStore(closeOrder),
    );
    final kernel = await factory.create();

    await expectLater(kernel.close(), throwsStateError);
    expect(closeOrder, ['store', 'repository']);
    await factory.close();
  });

  test('initialization failure closes the owned repository once', () async {
    final closeOrder = <String>[];
    final directory = Directory.systemTemp.createTempSync('halo-wiring-');
    final factory = OrchestrationKernelFactory.production(
      appSupportDirectory: _DirectoryProvider(directory.path),
      selector: const _Selector(),
      runtime: const _Runtime(),
      bundleOpener: _TestBundleOpener(
        openEvent: (_) => _TrackingStore(closeOrder),
        openInput: (_) => throw StateError('input open failed'),
      ),
    );

    await expectLater(factory.create(), throwsStateError);
    await factory.close();
    await factory.close();
    directory.deleteSync(recursive: true);

    expect(closeOrder, ['store']);
  });

  test(
    'initialization preserves its error when both cleanup steps fail',
    () async {
      final closeOrder = <String>[];
      final path = Completer<String>();
      final repository = _ThrowingDurableRepository(closeOrder);
      final factory = OrchestrationKernelFactory.production(
        appSupportDirectory: _CompletingDirectoryProvider(path.future),
        selector: const _Selector(),
        runtime: const _Runtime(),
        bundleOpener: _TestBundleOpener(
          openEvent: (_) => _ThrowingCloseStore(closeOrder),
          openInput: (_) => repository,
        ),
      );

      final initializing = factory.create();
      final closing = factory.close();
      final directory = Directory.systemTemp.createTempSync('halo-wiring-');
      path.complete(directory.path);

      await expectLater(
        initializing,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'OrchestrationKernelFactory is closed',
          ),
        ),
      );
      await closing;
      expect(closeOrder, ['store', 'repository']);
      directory.deleteSync(recursive: true);
    },
  );
}

StartConversationRunCommand _command({String input = '分析风险'}) {
  return StartConversationRunCommand(
    clientCommandId: 'factory-command',
    conversationId: 'group-product',
    hostAgentId: 'product-manager',
    input: input,
    replyMode: ConversationReplyMode.auto,
    memberAgentIds: const ['product-manager'],
  );
}

StartConversationRunCommand _withReferences(
  StartConversationRunCommand command,
  RunInputReservation reservation,
) {
  return StartConversationRunCommand(
    clientCommandId: command.clientCommandId,
    conversationId: command.conversationId,
    hostAgentId: command.hostAgentId,
    input: command.input,
    inputRef: reservation.inputRef,
    contextRef: reservation.contextRef,
    replyMode: command.replyMode,
    memberAgentIds: command.memberAgentIds,
    mentionedAgentIds: command.mentionedAgentIds,
  );
}

Future<List<OrchestrationEvent>> _waitForTerminal(
  ManagedOrchestrationKernel kernel,
  String runId,
) async {
  final events = <OrchestrationEvent>[];
  await for (final event
      in kernel.watchRun(runId).timeout(const Duration(seconds: 2))) {
    events.add(event);
    if (event.type == OrchestrationEventType.runCompleted ||
        event.type == OrchestrationEventType.runFailed ||
        event.type == OrchestrationEventType.runStopped) {
      break;
    }
  }
  return events;
}

class _DirectoryProvider implements AppSupportDirectoryProvider {
  const _DirectoryProvider(this.path);

  final String path;

  @override
  Future<String> getDirectoryPath() async => path;
}

class _Selector implements AgentSelector {
  const _Selector();

  @override
  Future<List<String>> select(AgentSelectionRequest request) async {
    return [request.candidateAgentIds.first];
  }
}

class _Runtime implements AgentRuntime, IdempotentAgentRuntimeCapability {
  const _Runtime();

  @override
  bool get supportsIdempotency => true;

  @override
  Future<String> respond(AgentTurnRequest request) async => 'reply';

  @override
  Future<String> summarize(DiscussionSummaryRequest request) async => 'summary';
}

class _CloseBlockingSelector implements AgentSelector {
  final started = Completer<void>();
  final _selection = Completer<List<String>>();

  void complete(List<String> selected) => _selection.complete(selected);

  @override
  Future<List<String>> select(AgentSelectionRequest request) {
    if (!started.isCompleted) started.complete();
    return _selection.future;
  }
}

class _CloseBlockingRuntime extends _Runtime {
  final started = Completer<void>();
  final _response = Completer<String>();

  void complete(String response) => _response.complete(response);

  @override
  Future<String> respond(AgentTurnRequest request) {
    if (!started.isCompleted) started.complete();
    return _response.future;
  }
}

class _BlockingPrepareRepository extends _FakeDurableRepository {
  final started = Completer<void>();
  final _release = Completer<void>();

  void complete() => _release.complete();

  void fail(Object error) => _release.completeError(error);

  @override
  Future<RunInputReservation> prepare(
    StartConversationRunCommand command,
  ) async {
    if (!started.isCompleted) started.complete();
    await _release.future;
    return super.prepare(command);
  }
}

class _BlockingCommitRepository extends _FakeDurableRepository {
  final started = Completer<void>();
  final _release = Completer<void>();

  void complete() => _release.complete();

  @override
  Future<void> commit(RunInputReservation reservation) async {
    if (!started.isCompleted) started.complete();
    await _release.future;
    await super.commit(reservation);
  }
}

class _BlockingResolveDurableRepository extends _FakeDurableRepository {
  final started = Completer<void>();
  final _resolved = Completer<String>();

  void complete(String input) => _resolved.complete(input);

  @override
  Future<String> resolve({required String inputRef, String? contextRef}) {
    if (!started.isCompleted) started.complete();
    return _resolved.future;
  }
}

class _FailingCreateStore extends InMemoryRunEventStore {
  _FailingCreateStore({this.beforeFailure, StateError? error})
    : error = error ?? StateError('create failed');

  final void Function()? beforeFailure;
  final StateError error;

  @override
  ({RunSnapshot snapshot, bool created}) createRun(
    StartConversationRunCommand command,
  ) {
    beforeFailure?.call();
    throw error;
  }
}

class _ProbeThrowingFailingStore extends _FailingCreateStore {
  _ProbeThrowingFailingStore(StateError error) : super(error: error);

  @override
  bool hasRunInputReference(String inputRef, String contextRef) {
    throw StateError('probe failed');
  }
}

class _ReferenceReportingFailingStore extends _FailingCreateStore {
  _ReferenceReportingFailingStore(StateError error) : super(error: error);

  @override
  bool hasRunInputReference(String inputRef, String contextRef) => true;
}

class _PersistThenThrowStore extends InMemoryRunEventStore {
  final _references = <(String, String)>{};
  late StateError error;

  @override
  ({RunSnapshot snapshot, bool created}) createRun(
    StartConversationRunCommand command,
  ) {
    super.createRun(command);
    _references.add((command.inputRef!, command.contextRef!));
    throw error;
  }

  @override
  bool hasRunInputReference(String inputRef, String contextRef) {
    return _references.contains((inputRef, contextRef));
  }
}

class _TrackingStore extends InMemoryRunEventStore {
  _TrackingStore(this.closeOrder);

  final List<String> closeOrder;
  var _closedOnce = false;

  @override
  Future<void> close() async {
    if (!_closedOnce) {
      _closedOnce = true;
      closeOrder.add('store');
    }
    await super.close();
  }
}

class _ThrowingCloseStore extends InMemoryRunEventStore {
  _ThrowingCloseStore(this.closeOrder);

  final List<String> closeOrder;
  var _closed = false;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closeOrder.add('store');
    throw StateError('store close failed');
  }
}

class _TrackingRepository implements RunInputRepository {
  _TrackingRepository(this.closeOrder);

  final List<String> closeOrder;
  final MemoryRunInputRepository _delegate = MemoryRunInputRepository();
  var _closed = false;

  @override
  Future<RunInputReservation> prepare(StartConversationRunCommand command) {
    return _delegate.prepare(command);
  }

  @override
  Future<void> commit(RunInputReservation reservation) {
    return _delegate.commit(reservation);
  }

  @override
  Future<void> rollback(RunInputReservation reservation) {
    return _delegate.rollback(reservation);
  }

  @override
  Future<void> markReferenced(RunInputReservation reservation) {
    return _delegate.markReferenced(reservation);
  }

  @override
  Future<RunInputLifecycle> lifecycleOf(RunInputReservation reservation) {
    return _delegate.lifecycleOf(reservation);
  }

  @override
  Future<String> resolve({required String inputRef, String? contextRef}) {
    return _delegate.resolve(inputRef: inputRef, contextRef: contextRef);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closeOrder.add('repository');
    await _delegate.close();
  }
}

class _TrackingDurableRepository extends _TrackingRepository
    implements DurableRunInputRepository {
  _TrackingDurableRepository(super.closeOrder);

  @override
  Future<int> collectOrphans({
    required DateTime olderThan,
    required RunInputReferenceProbe isReferenced,
  }) {
    return _delegate.collectOrphans(
      olderThan: olderThan,
      isReferenced: isReferenced,
    );
  }
}

class _ThrowingDurableRepository extends _TrackingDurableRepository {
  _ThrowingDurableRepository(super.closeOrder);

  @override
  Future<void> close() async {
    await super.close();
    throw StateError('repository close failed');
  }
}

class _FakeDurableRepository implements DurableRunInputRepository {
  _FakeDurableRepository({
    List<String>? operations,
    this.failFirstMarkReferenced = false,
    this.commitError,
    this.rollbackError,
    this.markReferencedError,
    this.collectError,
    this.onCollect,
    this.closeOrder,
  }) : operations = operations ?? <String>[];

  final List<String> operations;
  final MemoryRunInputRepository _delegate = MemoryRunInputRepository();
  bool failFirstMarkReferenced;
  final Object? commitError;
  final Object? rollbackError;
  final Object? markReferencedError;
  final Object? collectError;
  final void Function(DateTime, RunInputReferenceProbe)? onCollect;
  final List<String>? closeOrder;
  bool lastCommitted = false;

  @override
  Future<RunInputReservation> prepare(
    StartConversationRunCommand command,
  ) async {
    operations.add('prepare');
    return _delegate.prepare(command);
  }

  @override
  Future<void> commit(RunInputReservation reservation) async {
    operations.add('commit');
    if (commitError case final error?) throw error;
    await _delegate.commit(reservation);
    lastCommitted = true;
  }

  @override
  Future<void> rollback(RunInputReservation reservation) async {
    operations.add('rollback');
    if (rollbackError case final error?) throw error;
    await _delegate.rollback(reservation);
  }

  @override
  Future<void> markReferenced(RunInputReservation reservation) async {
    operations.add('markReferenced');
    if (markReferencedError case final error?) throw error;
    if (failFirstMarkReferenced) {
      failFirstMarkReferenced = false;
      throw StateError('crash after createRun');
    }
    await _delegate.markReferenced(reservation);
  }

  @override
  Future<RunInputLifecycle> lifecycleOf(RunInputReservation reservation) {
    return _delegate.lifecycleOf(reservation);
  }

  @override
  Future<int> collectOrphans({
    required DateTime olderThan,
    required RunInputReferenceProbe isReferenced,
  }) {
    operations.add('collectOrphans');
    onCollect?.call(olderThan, isReferenced);
    if (collectError case final error?) {
      return Future<int>.error(error);
    }
    return _delegate.collectOrphans(
      olderThan: olderThan,
      isReferenced: isReferenced,
    );
  }

  @override
  Future<String> resolve({required String inputRef, String? contextRef}) {
    return _delegate.resolve(inputRef: inputRef, contextRef: contextRef);
  }

  @override
  Future<void> close() async {
    closeOrder?.add('repository');
    await _delegate.close();
  }
}

class _CompletingDirectoryProvider implements AppSupportDirectoryProvider {
  const _CompletingDirectoryProvider(this.path);

  final Future<String> path;

  @override
  Future<String> getDirectoryPath() => path;
}

class _TestBundleOpener implements ProductionStoreBundleOpener {
  const _TestBundleOpener({required this.openEvent, required this.openInput});

  final RunEventStore Function(String path) openEvent;
  final DurableRunInputRepository Function(String path) openInput;

  @override
  RunEventStore openEventStore(String databasePath) {
    return openEvent(databasePath);
  }

  @override
  DurableRunInputRepository openInputRepository(String databasePath) {
    return openInput(databasePath);
  }
}
