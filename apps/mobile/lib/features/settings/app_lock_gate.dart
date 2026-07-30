import 'dart:async';

import 'package:flutter/material.dart';
import 'package:halo_mobile/features/settings/app_lock.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

/// Covers the app while [AppLockController.locked] is true.
///
/// The child stays mounted underneath so navigation state, in-flight runs and
/// scroll positions survive a lock; only the pixels are withheld.
class AppLockGate extends StatefulWidget {
  const AppLockGate({required this.child, this.controller, super.key});

  final AppLockController? controller;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller?.addListener(_refresh);
  }

  @override
  void didUpdateWidget(AppLockGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_refresh);
      widget.controller?.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-arm on the way out, not on the way back: by the time the app is
    // resumed its contents have already been visible in the app switcher.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      widget.controller?.lockIfEnabled();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final locked = controller != null && controller.locked;
    return Stack(
      children: [
        widget.child,
        if (locked)
          _LockScreen(
            authenticating: controller.authenticating,
            onUnlock: () => unawaited(controller.unlock()),
          ),
      ],
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.authenticating, required this.onUnlock});

  final bool authenticating;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Material(
        color: HaloColors.navy,
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  HaloIcon.requirePrototypeClass('ph ph-scan'),
                  size: 46,
                  color: Colors.white,
                ),
                const SizedBox(height: 14),
                const Text(
                  'Halo 已锁定',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '使用 Face ID 或设备密码解锁',
                  style: TextStyle(color: Color(0xFFC5CADB), fontSize: 12),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: authenticating ? null : onUnlock,
                  child: Text(authenticating ? '正在验证…' : '解锁'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
