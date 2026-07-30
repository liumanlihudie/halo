import 'dart:async';
import 'dart:io';

import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/orchestration_kernel.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/persistence/sqlite_run_event_store.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';
import 'package:halo_mobile/orchestration/wiring/run_input_repository.dart';

abstract interface class AppSupportDirectoryProvider {
  Future<String> getDirectoryPath();
}

typedef TestRunEventStoreFactory = RunEventStore Function();

abstract interface class ProductionStoreBundleOpener {
  RunEventStore openEventStore(String databasePath);

  DurableRunInputRepository openInputRepository(String databasePath);
}

final class SqliteProductionStoreBundleOpener
    implements ProductionStoreBundleOpener {
  const SqliteProductionStoreBundleOpener();

  @override
  RunEventStore openEventStore(String databasePath) {
    return SqliteRunEventStore.open(databasePath);
  }

  @override
  DurableRunInputRepository openInputRepository(String databasePath) {
    return SqliteRunInputRepository.open(databasePath);
  }
}

final class OrchestrationKernelFactory {
  factory OrchestrationKernelFactory.production({
    required AppSupportDirectoryProvider appSupportDirectory,
    required AgentSelector selector,
    required AgentRuntime runtime,
    DateTime Function() clock = DateTime.now,
    Duration orphanGracePeriod = const Duration(days: 1),
    ProductionStoreBundleOpener bundleOpener =
        const SqliteProductionStoreBundleOpener(),
  }) {
    return OrchestrationKernelFactory._(
      _FactoryMode.production,
      appSupportDirectory,
      null,
      selector,
      runtime,
      clock,
      orphanGracePeriod,
      bundleOpener,
      null,
    );
  }

  factory OrchestrationKernelFactory.testing({
    required RunInputRepository inputRepository,
    required AgentSelector selector,
    required AgentRuntime runtime,
    TestRunEventStoreFactory createStore = _createInMemoryStore,
  }) {
    return OrchestrationKernelFactory._(
      _FactoryMode.testing,
      null,
      inputRepository,
      selector,
      runtime,
      DateTime.now,
      Duration.zero,
      null,
      createStore,
    );
  }

  OrchestrationKernelFactory._(
    this._mode,
    this._appSupportDirectory,
    this._configuredInputRepository,
    this._selector,
    this._runtime,
    this._clock,
    this._orphanGracePeriod,
    this._bundleOpener,
    this._createStore,
  );

  final _FactoryMode _mode;
  final AppSupportDirectoryProvider? _appSupportDirectory;
  final RunInputRepository? _configuredInputRepository;
  final AgentSelector _selector;
  final AgentRuntime _runtime;
  final DateTime Function() _clock;
  final Duration _orphanGracePeriod;
  final ProductionStoreBundleOpener? _bundleOpener;
  final TestRunEventStoreFactory? _createStore;
  RunInputRepository? _ownedInputRepository;
  _ProductionDirectoryLease? _directoryLease;
  Future<ManagedOrchestrationKernel>? _initialization;
  Future<void>? _closeFuture;
  var _closed = false;
  var _repositoryClosed = false;

  Future<ManagedOrchestrationKernel> create() {
    if (_closed) {
      return Future.error(StateError('OrchestrationKernelFactory is closed'));
    }
    return _initialization ??= _initialize();
  }

  Future<ManagedOrchestrationKernel> _initialize() async {
    RunEventStore? store;
    RunInputRepository? inputRepository;
    try {
      if (_mode == _FactoryMode.production) {
        final directory = await _resolveProductionDirectory();
        _directoryLease = await _ProductionDirectoryLease.acquire(directory);
        final canonicalDirectory = _directoryLease!.canonicalPath;
        store = _bundleOpener!.openEventStore(
          '$canonicalDirectory${Platform.pathSeparator}'
          'halo_orchestration.sqlite',
        );
        inputRepository = _bundleOpener.openInputRepository(
          '$canonicalDirectory${Platform.pathSeparator}'
          'halo_run_inputs.sqlite',
        );
      } else {
        store = _createStore!();
        inputRepository = _configuredInputRepository!;
      }
      _ownedInputRepository = inputRepository;
      if (_closed) {
        throw StateError('OrchestrationKernelFactory is closed');
      }
      if (_mode == _FactoryMode.production) {
        await (inputRepository as DurableRunInputRepository).collectOrphans(
          olderThan: _clock().subtract(_orphanGracePeriod),
          isReferenced: (inputRef, contextRef) async =>
              store!.hasRunInputReference(inputRef, contextRef),
        );
      }
      final runner = BasicDurableRunner(
        store: store,
        selector: _selector,
        runtime: _runtime,
        inputResolver: inputRepository,
      );
      return ManagedOrchestrationKernel._(
        runner,
        store,
        inputRepository,
        () => _closed = true,
        () => _repositoryClosed = true,
        _releaseDirectoryLease,
      );
    } on Object catch (initializationError, initializationStackTrace) {
      if (store != null) {
        try {
          await store.close();
        } on Object {
          // Cleanup failures must not replace the initialization failure.
        }
      }
      if (inputRepository != null) {
        try {
          await _closeRepository();
        } on Object {
          // Cleanup failures must not replace the initialization failure.
        }
      }
      try {
        await _releaseDirectoryLease();
      } on Object {
        // Lease cleanup must not replace the initialization failure.
      }
      Error.throwWithStackTrace(initializationError, initializationStackTrace);
    }
  }

  Future<Directory> _resolveProductionDirectory() async {
    final path = (await _appSupportDirectory!.getDirectoryPath()).trim();
    if (path.isEmpty) {
      throw StateError('App support directory path is empty');
    }
    return Directory(path).create(recursive: true);
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final initialization = _initialization;
    if (initialization == null) {
      await _closeRepository();
      await _releaseDirectoryLease();
      return;
    }
    try {
      final kernel = await initialization;
      await kernel.close();
    } on Object {
      await _closeRepository();
      await _releaseDirectoryLease();
    }
  }

  Future<void> _closeRepository() async {
    if (_repositoryClosed) return;
    _repositoryClosed = true;
    await (_ownedInputRepository ?? _configuredInputRepository)?.close();
  }

  Future<void> _releaseDirectoryLease() async {
    final lease = _directoryLease;
    _directoryLease = null;
    await lease?.close();
  }
}

final class ManagedOrchestrationKernel implements OrchestrationKernel {
  ManagedOrchestrationKernel._(
    this._delegate,
    this._store,
    this._inputRepository,
    this._onClosing,
    this._onRepositoryClosed,
    this._releaseDirectoryLease,
  );

  final BasicDurableRunner _delegate;
  final RunEventStore _store;
  final RunInputRepository _inputRepository;
  final void Function() _onClosing;
  final void Function() _onRepositoryClosed;
  final Future<void> Function() _releaseDirectoryLease;
  Future<void>? _closeFuture;
  var _closed = false;
  var _inFlightOperations = 0;
  Completer<void>? _operationsDrained;

  @override
  Future<RunHandle> startRun(StartConversationRunCommand command) {
    return _runOperation(() => _startRun(command));
  }

  Future<RunHandle> _startRun(StartConversationRunCommand command) async {
    final reservation = await _inputRepository.prepare(command);
    final referencedCommand = StartConversationRunCommand(
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
    try {
      await _inputRepository.commit(reservation);
    } on Object catch (error, stackTrace) {
      try {
        await _inputRepository.rollback(reservation);
      } on Object {
        // Compensation errors must not replace the commit error.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    late final RunHandle handle;
    try {
      handle = await _delegate.startRun(referencedCommand);
    } on Object catch (error, stackTrace) {
      bool isReferenced;
      try {
        isReferenced = _store.hasRunInputReference(
          reservation.inputRef,
          reservation.contextRef,
        );
      } on Object {
        Error.throwWithStackTrace(error, stackTrace);
      }
      try {
        if (isReferenced) {
          await _inputRepository.markReferenced(reservation);
        } else {
          await _inputRepository.rollback(reservation);
        }
      } on Object {
        // Recovery errors must not replace the delegate error.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    await _inputRepository.markReferenced(reservation);
    return handle;
  }

  @override
  Future<RunSnapshot> getRun(String runId) {
    return _runOperation(() => _delegate.getRun(runId));
  }

  @override
  Future<void> requestStop(String runId) {
    return _runOperation(() => _delegate.requestStop(runId));
  }

  @override
  Future<ResumeResult> resumeRun(String runId) {
    return _runOperation(() => _delegate.resumeRun(runId));
  }

  @override
  Stream<OrchestrationEvent> watchRun(String runId, {int afterSeq = 0}) {
    _beginOperation();
    try {
      final source = _delegate.watchRun(runId, afterSeq: afterSeq);
      // Only stream creation is a public operation. Once subscribed, the
      // watcher is owned and terminated by RunEventStore.close; counting the
      // whole subscription would make close wait on the resource that close
      // itself must terminate.
      return Stream<OrchestrationEvent>.multi((sink) {
        if (_closed) {
          sink.addError(StateError('Orchestration kernel is closed'));
          sink.close();
          return;
        }
        final subscription = source.listen(
          sink.add,
          onError: sink.addError,
          onDone: sink.close,
        );
        sink.onCancel = subscription.cancel;
      });
    } finally {
      _endOperation();
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _onClosing();
    await _waitForOperationsToDrain();
    await _delegate.shutdown();
    Object? closeError;
    StackTrace? closeStackTrace;
    try {
      await _store.close();
    } on Object catch (error, stackTrace) {
      closeError = error;
      closeStackTrace = stackTrace;
    }
    try {
      await _inputRepository.close();
    } on Object catch (error, stackTrace) {
      closeError ??= error;
      closeStackTrace ??= stackTrace;
    } finally {
      _onRepositoryClosed();
    }
    try {
      await _releaseDirectoryLease();
    } on Object catch (error, stackTrace) {
      closeError ??= error;
      closeStackTrace ??= stackTrace;
    }
    if (closeError != null) {
      Error.throwWithStackTrace(closeError, closeStackTrace!);
    }
  }

  Future<T> _runOperation<T>(Future<T> Function() operation) async {
    _beginOperation();
    try {
      return await operation();
    } finally {
      _endOperation();
    }
  }

  void _beginOperation() {
    if (_closed) throw StateError('Orchestration kernel is closed');
    _inFlightOperations++;
  }

  void _endOperation() {
    _inFlightOperations--;
    if (_closed && _inFlightOperations == 0) {
      _operationsDrained?.complete();
    }
  }

  Future<void> _waitForOperationsToDrain() {
    if (_inFlightOperations == 0) return Future<void>.value();
    return (_operationsDrained ??= Completer<void>()).future;
  }
}

enum _FactoryMode { production, testing }

RunEventStore _createInMemoryStore() => InMemoryRunEventStore();

final class _ProductionDirectoryLease {
  _ProductionDirectoryLease._(this._canonicalPath, this._handle);

  static final Set<String> _heldCanonicalPaths = <String>{};

  static Future<_ProductionDirectoryLease> acquire(Directory directory) async {
    final canonicalPath = await directory.resolveSymbolicLinks();
    if (!_heldCanonicalPaths.add(canonicalPath)) {
      throw StateError(
        'Another orchestration kernel owns this app-support directory',
      );
    }
    RandomAccessFile? handle;
    try {
      handle = File(
        '$canonicalPath${Platform.pathSeparator}.halo_orchestration.lock',
      ).openSync(mode: FileMode.append);
      handle.lockSync(FileLock.exclusive);
      return _ProductionDirectoryLease._(canonicalPath, handle);
    } catch (_) {
      try {
        handle?.closeSync();
      } finally {
        _heldCanonicalPaths.remove(canonicalPath);
      }
      rethrow;
    }
  }

  final String _canonicalPath;
  final RandomAccessFile _handle;
  var _closed = false;

  String get canonicalPath => _canonicalPath;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    Object? releaseError;
    StackTrace? releaseStack;
    try {
      _handle.unlockSync();
    } on Object catch (error, stackTrace) {
      releaseError = error;
      releaseStack = stackTrace;
    }
    try {
      _handle.closeSync();
    } on Object catch (error, stackTrace) {
      releaseError ??= error;
      releaseStack ??= stackTrace;
    } finally {
      _heldCanonicalPaths.remove(_canonicalPath);
    }
    if (releaseError != null) {
      Error.throwWithStackTrace(releaseError, releaseStack!);
    }
  }
}
