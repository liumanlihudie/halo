import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/app/router.dart';
import 'package:halo_mobile/foundation/design_system/halo_theme.dart';

class HaloApp extends StatefulWidget {
  const HaloApp({this.initialLocation = '/conversations', super.key});

  final String initialLocation;

  @override
  State<HaloApp> createState() => _HaloAppState();
}

class _HaloAppState extends State<HaloApp> {
  late final GoRouter _router = createAppRouter(
    initialLocation: widget.initialLocation,
  );

  @override
  void dispose() {
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
