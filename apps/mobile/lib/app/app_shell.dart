import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppShell extends StatelessWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  static const _destinations = [
    NavigationDestination(
      icon: Icon(CupertinoIcons.chat_bubble_2),
      selectedIcon: Icon(CupertinoIcons.chat_bubble_2_fill),
      label: '对话',
    ),
    NavigationDestination(
      icon: Icon(CupertinoIcons.person_2),
      selectedIcon: Icon(CupertinoIcons.person_2_fill),
      label: '专家团',
    ),
    NavigationDestination(
      icon: Icon(CupertinoIcons.square_grid_2x2),
      selectedIcon: Icon(CupertinoIcons.square_grid_2x2_fill),
      label: '圈层',
    ),
    NavigationDestination(
      icon: Icon(CupertinoIcons.gear),
      selectedIcon: Icon(CupertinoIcons.gear_solid),
      label: '设置',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        destinations: _destinations,
        onDestinationSelected: (index) {
          navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          );
        },
      ),
    );
  }
}
