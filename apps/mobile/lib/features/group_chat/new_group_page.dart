import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

class NewGroupPage extends StatefulWidget {
  const NewGroupPage({super.key});

  @override
  State<NewGroupPage> createState() => _NewGroupPageState();
}

class _NewGroupPageState extends State<NewGroupPage> {
  final selected = <String>{'product', 'data'};

  @override
  Widget build(BuildContext context) {
    return HaloPageScaffold(
      title: '创建 AI 群聊',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/conversations'),
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(15, 9, 15, 8),
            child: HaloSearchField(placeholder: '搜索已添加的 Agent'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '已选择 ${selected.length} 位专家',
                style: HaloTextStyles.secondary,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(15, 8, 15, 16),
              children: [
                for (final expert in HaloFixtures.installedExperts)
                  CheckboxListTile(
                    value: selected.contains(expert.id),
                    onChanged: (value) => setState(
                      () => value == true
                          ? selected.add(expert.id)
                          : selected.remove(expert.id),
                    ),
                    contentPadding: EdgeInsets.zero,
                    secondary: HaloAvatar(
                      imageUrl: expert.imageUrl,
                      letter: expert.avatarLetter,
                      size: 42,
                    ),
                    title: Text(expert.name, style: HaloTextStyles.rowTitle),
                    subtitle: Text(
                      '${expert.model}\n${expert.status}',
                      maxLines: 2,
                      style: HaloTextStyles.caption,
                    ),
                    controlAffinity: ListTileControlAffinity.trailing,
                    activeColor: HaloColors.accent,
                  ),
              ],
            ),
          ),
        ],
      ),
      bottom: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: selected.length >= 2
                  ? () => context.go('/group/group-product')
                  : null,
              child: Text('创建群聊（${selected.length}）'),
            ),
          ),
        ),
      ),
    );
  }
}
