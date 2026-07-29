import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class AppShell extends StatelessWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  static const _destinations = <(String, String)>[
    ('ph ph-chat-circle-dots', '对话'),
    ('ph ph-users-three', '专家团'),
    ('ph ph-circles-three', '圈层'),
    ('ph ph-gear-six', '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: HaloColors.paper,
          border: Border(top: BorderSide(color: HaloColors.line)),
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: 7),
          child: SizedBox(
            height: 53,
            child: Row(
              children: [
                for (var index = 0; index < _destinations.length; index++)
                  Expanded(
                    child: _TabButton(
                      iconClass: _destinations[index].$1,
                      label: _destinations[index].$2,
                      selected: index == navigationShell.currentIndex,
                      onTap: () {
                        navigationShell.goBranch(
                          index,
                          initialLocation:
                              index == navigationShell.currentIndex,
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.iconClass,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String iconClass;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? HaloColors.accentDeep : const Color(0xFF9297A1);
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              HaloIcon.requirePrototypeClass(iconClass),
              size: 21,
              color: color,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                height: 1,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
