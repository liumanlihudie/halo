import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/app/app_kernel.dart';
import 'package:halo_mobile/app/production_app_kernel.dart';
import 'package:halo_mobile/app/router.dart';
import 'package:halo_mobile/foundation/design_system/halo_theme.dart';

class HaloApp extends StatefulWidget {
  const HaloApp({
    this.initialLocation = '/conversations',
    this.kernelBootstrap,
    super.key,
  });

  final String initialLocation;
  final ApplicationKernelBootstrap? kernelBootstrap;

  @override
  State<HaloApp> createState() => _HaloAppState();
}

class _HaloAppState extends State<HaloApp> {
  late final ApplicationKernelHost _kernelHost;
  late GoRouter _router;

  @override
  void initState() {
    super.initState();
    _kernelHost = ApplicationKernelHost(
      bootstrap: widget.kernelBootstrap ?? ProductionAppKernelFactory().create,
      unavailable: UnavailableApplicationKernel(),
      swapBarrier: _waitForUiSwap,
    );
    _router = _createRouter();
    unawaited(_kernelHost.initialize().catchError((Object _) {}));
  }

  GoRouter _createRouter({String? initialLocation}) => createAppRouter(
    initialLocation: initialLocation ?? widget.initialLocation,
    dependencyResolver: () => _kernelHost.current.dependencies,
    dependencyListenable: _kernelHost,
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
      ),
    );
  }
}
