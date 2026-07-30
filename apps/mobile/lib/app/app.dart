import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/app/app_kernel.dart';
import 'package:halo_mobile/app/production_app_kernel.dart';
import 'package:halo_mobile/app/router.dart';
import 'package:halo_mobile/features/settings/app_lock.dart';
import 'package:halo_mobile/features/settings/app_lock_gate.dart';
import 'package:halo_mobile/features/settings/local_auth_authenticator.dart';
import 'package:halo_mobile/foundation/design_system/halo_theme.dart';
import 'package:path_provider/path_provider.dart';

class HaloApp extends StatefulWidget {
  const HaloApp({
    this.initialLocation = '/conversations',
    this.kernelBootstrap,
    this.appLock,
    super.key,
  });

  final String initialLocation;
  final ApplicationKernelBootstrap? kernelBootstrap;

  /// Injectable so widget tests never reach the biometric platform channel.
  /// When null the production controller is built lazily at startup.
  final AppLockController? appLock;

  @override
  State<HaloApp> createState() => _HaloAppState();
}

class _HaloAppState extends State<HaloApp> {
  late final ApplicationKernelHost _kernelHost;
  late GoRouter _router;
  AppLockController? _appLock;

  @override
  void initState() {
    super.initState();
    _appLock = widget.appLock;
    if (_appLock == null) {
      unawaited(_createProductionAppLock());
    } else {
      unawaited(_appLock!.load().catchError((Object _) {}));
    }
    _kernelHost = ApplicationKernelHost(
      bootstrap: widget.kernelBootstrap ?? ProductionAppKernelFactory().create,
      unavailable: UnavailableApplicationKernel(),
      swapBarrier: _waitForUiSwap,
    );
    _router = _createRouter();
    unawaited(_kernelHost.initialize().catchError((Object _) {}));
  }

  /// Built off the widget tree so a missing plugin or unwritable support
  /// directory degrades to "no lock" instead of failing app startup.
  Future<void> _createProductionAppLock() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final controller = AppLockController(
        authenticator: LocalAuthAppLockAuthenticator(),
        preferences: FileAppLockPreferences(
          File('${directory.path}${Platform.pathSeparator}app-lock.json'),
        ),
      );
      await controller.load();
      if (mounted) setState(() => _appLock = controller);
    } catch (_) {
      // Leaves _appLock null; the gate then never covers the app.
    }
  }

  GoRouter _createRouter({String? initialLocation}) => createAppRouter(
    initialLocation: initialLocation ?? widget.initialLocation,
    dependencyResolver: () => _kernelHost.current.dependencies,
    dependencyListenable: _kernelHost,
    appLock: () => _appLock,
  );

  Future<void> _waitForUiSwap() {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => completer.complete());
    return completer.future;
  }

  @override
  void dispose() {
    unawaited(_kernelHost.close());
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp.router(
        title: 'Halo',
        debugShowCheckedModeBanner: false,
        theme: HaloTheme.light(),
        routerConfig: _router,
        builder: (context, child) =>
            AppLockGate(controller: _appLock, child: child ?? const SizedBox()),
      ),
    );
  }
}
