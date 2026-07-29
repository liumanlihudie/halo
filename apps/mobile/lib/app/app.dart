import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/app/router.dart';
import 'package:halo_mobile/foundation/design_system/halo_theme.dart';

class HaloApp extends StatefulWidget {
  const HaloApp({super.key});

  @override
  State<HaloApp> createState() => _HaloAppState();
}

class _HaloAppState extends State<HaloApp> {
  late final GoRouter _router = createAppRouter();

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Halo',
      debugShowCheckedModeBanner: false,
      theme: HaloTheme.light(),
      routerConfig: _router,
    );
  }
}
