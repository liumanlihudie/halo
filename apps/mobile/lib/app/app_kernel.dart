import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/features/group_chat/group_chat_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/features/circle/circle_controller.dart';
import 'package:halo_mobile/features/circle/circle_publisher.dart';
import 'package:halo_mobile/features/settings/local_data_maintenance.dart';
import 'package:halo_mobile/features/settings/service_credentials_controller.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';

@immutable
class AppDependencies {
  const AppDependencies({
    required this.singleChatPort,
    required this.chatRepository,
    this.providerSettings,
    this.modelRouting,
    this.groupChatPort,
    this.localData,
    this.serviceCredentials,
    this.speech,
    this.circle,
    this.circlePublisher,
    this.allowEphemeralChatRepositoryForTesting = false,
  });

  final SingleChatPort singleChatPort;
  final ChatMessageRepository chatRepository;
  final ProviderSettingsController? providerSettings;
  final ModelRoutingController? modelRouting;

  /// Absent until the orchestration kernel is available; the group composer
  /// stays disabled rather than inventing replies.
  final GroupChatRunPort? groupChatPort;

  /// Absent until durable storage is available; the local data page then keeps
  /// every action disabled instead of failing mid-write.
  final LocalDataMaintenancePort? localData;

  /// Keys for services that have no model catalogue (Doubao speech, Doubao
  /// realtime audio, Vidu). Absent when storage failed to boot.
  final ServiceCredentialsController? serviceCredentials;

  /// Absent when no speech credential is configured; voice messages then stay
  /// unavailable while text chat is unaffected.
  final SingleChatSpeech? speech;

  /// The circle feed. Absent when its storage failed to open, in which case
  /// the page says so instead of showing fixtures.
  final CircleController? circle;

  /// Publishes an answer from a conversation into the feed.
  final CirclePublisher? circlePublisher;
  final bool allowEphemeralChatRepositoryForTesting;
}

abstract interface class ApplicationKernel {
  String get name;

  AppDependencies get dependencies;

  Future<void> close();
}

typedef ApplicationKernelBootstrap = Future<ApplicationKernel> Function();
typedef ApplicationKernelSwapBarrier = Future<void> Function();

final class UnavailableApplicationKernel implements ApplicationKernel {
  UnavailableApplicationKernel()
    : dependencies = AppDependencies(
        singleChatPort: const _UnavailableSingleChatPort(),
        chatRepository: InMemoryChatMessageRepository(),
      );

  @override
  String get name => 'unavailable';

  @override
  final AppDependencies dependencies;

  @override
  Future<void> close() async {}
}

final class _UnavailableSingleChatPort implements SingleChatPort {
  const _UnavailableSingleChatPort();

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) async => SingleAgentRunHandle(
    runId: 'unavailable',
    outcome: Future.value(
      const SingleAgentRunOutcome.failed(
        failure: SingleAgentRunFailure.retryable,
      ),
    ),
  );

  @override
  Future<void> stopSingleAgentRun(String runId) async {}
}

/// Owns the generation fence between asynchronous bootstrap and UI routing.
///
/// A replacement is published first, then the UI swap barrier is acknowledged
/// before the previous kernel is drained and closed.
final class ApplicationKernelHost extends ChangeNotifier {
  ApplicationKernelHost({
    required ApplicationKernelBootstrap bootstrap,
    required ApplicationKernel unavailable,
    ApplicationKernelSwapBarrier? swapBarrier,
  }) : _bootstrap = bootstrap,
       _unavailable = unavailable,
       _swapBarrier = swapBarrier ?? _immediateSwapBarrier,
       _current = unavailable;

  final ApplicationKernelBootstrap _bootstrap;
  final ApplicationKernel _unavailable;
  final ApplicationKernelSwapBarrier _swapBarrier;
  ApplicationKernel _current;
  ApplicationKernel get current => _current;

  int _generation = 0;
  bool _closed = false;

  Object? _bootstrapFailure;

  /// Why the last bootstrap attempt failed, if it did.
  ///
  /// Without this the app silently degrades to [UnavailableApplicationKernel]
  /// and every screen has to guess at the cause.
  Object? get bootstrapFailure => _bootstrapFailure;
  final Set<Future<void>> _pending = {};
  Future<void>? _closeFuture;

  Future<void> initialize() {
    if (_closed) {
      return Future.error(StateError('Application kernel host is closed'));
    }
    final generation = ++_generation;
    late final Future<void> operation;
    operation = _initializeGeneration(
      generation,
    ).whenComplete(() => _pending.remove(operation));
    _pending.add(operation);
    return operation;
  }

  Future<void> _initializeGeneration(int generation) async {
    late final ApplicationKernel candidate;
    try {
      candidate = await _bootstrap();
    } catch (error) {
      _bootstrapFailure = error;
      notifyListeners();
      rethrow;
    }
    if (_closed || generation != _generation) {
      await candidate.close();
      return;
    }
    final previous = _current;
    _current = candidate;
    _bootstrapFailure = null;
    notifyListeners();
    if (!identical(previous, _unavailable)) {
      await _swapBarrier();
      await previous.close();
    }
  }

  void _publishUnavailable() {
    if (identical(_current, _unavailable)) return;
    _current = _unavailable;
    notifyListeners();
  }

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closed = true;
    _generation++;
    final current = _current;
    _publishUnavailable();
    final future = _close(current);
    _closeFuture = future;
    return future;
  }

  Future<void> _close(ApplicationKernel current) async {
    Object? firstError;
    StackTrace? firstStack;
    try {
      if (!identical(current, _unavailable)) {
        await current.close();
      }
    } catch (error, stackTrace) {
      firstError = error;
      firstStack = stackTrace;
    }
    try {
      await Future.wait(_pending.toList(growable: false), eagerError: false);
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStack ??= stackTrace;
    } finally {
      super.dispose();
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }
}

Future<void> _immediateSwapBarrier() async {}
