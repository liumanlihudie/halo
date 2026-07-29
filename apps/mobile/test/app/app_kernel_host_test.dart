import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app_kernel.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';

void main() {
  test('unavailable kernel exposes no fixture chat history', () async {
    final kernel = UnavailableApplicationKernel();

    expect(
      await kernel.dependencies.chatRepository.load('general-assistant'),
      isEmpty,
    );
    expect(
      () => kernel.dependencies.chatRepository.describe('general-assistant'),
      throwsStateError,
    );
  });

  test('publishes no half-initialized kernel', () async {
    final completer = Completer<ApplicationKernel>();
    final host = ApplicationKernelHost(
      bootstrap: () => completer.future,
      unavailable: _kernel('unavailable'),
    );

    final initializing = host.initialize();
    expect(host.current.name, 'unavailable');
    completer.complete(_kernel('ready'));
    await initializing;

    expect(host.current.name, 'ready');
  });

  test('generation fence disposes late initialization result', () async {
    final first = Completer<ApplicationKernel>();
    final second = Completer<ApplicationKernel>();
    var call = 0;
    final host = ApplicationKernelHost(
      bootstrap: () => (++call == 1 ? first : second).future,
      unavailable: _kernel('unavailable'),
    );

    final firstInit = host.initialize();
    final secondInit = host.initialize();
    final late = _kernel('late');
    final current = _kernel('current');
    second.complete(current);
    await secondInit;
    first.complete(late);
    await firstInit;

    expect(host.current, same(current));
    expect(late.closeCount, 1);
  });

  test(
    'close drains current kernel, is idempotent, and rejects later init',
    () async {
      final closeGate = Completer<void>();
      final ready = _kernel('ready', closeGate: closeGate);
      final host = ApplicationKernelHost(
        bootstrap: () async => ready,
        unavailable: _kernel('unavailable'),
      );
      await host.initialize();

      final firstClose = host.close();
      final secondClose = host.close();
      expect(ready.closeStarted, isTrue);
      expect(host.current.name, 'unavailable');
      closeGate.complete();
      await Future.wait([firstClose, secondClose]);

      expect(ready.closeCount, 1);
      await expectLater(host.initialize(), throwsStateError);
    },
  );

  test(
    'failed replacement keeps the existing kernel open and referenced',
    () async {
      final existing = _kernel('existing');
      var attempt = 0;
      final host = ApplicationKernelHost(
        bootstrap: () async {
          if (attempt++ == 0) return existing;
          throw StateError('replacement failed');
        },
        unavailable: _kernel('unavailable'),
      );
      await host.initialize();

      await expectLater(host.initialize(), throwsStateError);

      expect(host.current, same(existing));
      expect(existing.closeCount, 0);
      await host.close();
    },
  );

  test('a failed bootstrap keeps its reason instead of losing it', () async {
    final failure = StateError('provider store is corrupt');
    final host = ApplicationKernelHost(
      bootstrap: () async => throw failure,
      unavailable: _kernel('unavailable'),
    );
    var notifications = 0;
    host.addListener(() => notifications++);

    expect(host.bootstrapFailure, isNull);
    await expectLater(host.initialize(), throwsStateError);

    // Losing this is what leaves the app silently degraded with no diagnosis.
    expect(host.bootstrapFailure, same(failure));
    expect(notifications, greaterThan(0));
    await host.close();
  });

  test('a later successful bootstrap clears the recorded failure', () async {
    var attempt = 0;
    final replacement = _kernel('replacement');
    final host = ApplicationKernelHost(
      bootstrap: () async {
        if (attempt++ == 0) throw StateError('transient');
        return replacement;
      },
      unavailable: _kernel('unavailable'),
    );

    await expectLater(host.initialize(), throwsStateError);
    expect(host.bootstrapFailure, isNotNull);

    await host.initialize();

    expect(host.bootstrapFailure, isNull);
    expect(host.current, same(replacement));
    await host.close();
  });

  test('close disposes host even when a pending bootstrap fails', () async {
    final pending = Completer<ApplicationKernel>();
    final host = ApplicationKernelHost(
      bootstrap: () => pending.future,
      unavailable: _kernel('unavailable'),
    );
    final initialization = host.initialize();
    final closing = host.close();
    final initializationExpectation = expectLater(
      initialization,
      throwsStateError,
    );
    final closingExpectation = expectLater(closing, throwsStateError);
    pending.completeError(StateError('bootstrap failed'));

    await initializationExpectation;
    await closingExpectation;
    expect(
      () => ChangeNotifier.debugAssertNotDisposed(host),
      throwsFlutterError,
    );
  });

  test(
    'replacement waits for UI swap acknowledgement before closing old kernel',
    () async {
      final barrier = Completer<void>();
      final existing = _kernel('existing');
      final replacement = _kernel('replacement');
      var call = 0;
      final host = ApplicationKernelHost(
        bootstrap: () async => call++ == 0 ? existing : replacement,
        unavailable: _kernel('unavailable'),
        swapBarrier: () => barrier.future,
      );
      await host.initialize();

      final replacing = host.initialize();
      await Future<void>.delayed(Duration.zero);

      expect(host.current, same(replacement));
      expect(existing.closeCount, 0);
      barrier.complete();
      await replacing;
      expect(existing.closeCount, 1);
      await host.close();
    },
  );
}

_FakeKernel _kernel(String name, {Completer<void>? closeGate}) =>
    _FakeKernel(name, closeGate);

final class _FakeKernel implements ApplicationKernel {
  _FakeKernel(this.name, this.closeGate)
    : dependencies = AppDependencies(
        singleChatPort: _UnavailablePort(),
        chatRepository: InMemoryChatMessageRepository(),
      );

  @override
  final String name;
  @override
  final AppDependencies dependencies;
  final Completer<void>? closeGate;
  int closeCount = 0;
  bool closeStarted = false;

  @override
  Future<void> close() async {
    closeStarted = true;
    closeCount++;
    await closeGate?.future;
  }
}

final class _UnavailablePort implements SingleChatPort {
  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) => throw StateError('unavailable');

  @override
  Future<void> stopSingleAgentRun(String runId) async {}
}
