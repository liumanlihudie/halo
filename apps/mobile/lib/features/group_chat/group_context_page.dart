import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class GroupContextPage extends StatelessWidget {
  const GroupContextPage({required this.groupId, super.key});
  final String groupId;

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '共享上下文',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () => context.canPop()
            ? context.pop()
            : context.go('/group/$groupId/info'),
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(30),
          child: Text(
            '群共享上下文还未实装。\n实装后，这里会列出群内 Agent 共同可读的资料来源。',
            textAlign: TextAlign.center,
            style: HaloTextStyles.caption,
          ),
        ),
      ),
    );
  }
}
