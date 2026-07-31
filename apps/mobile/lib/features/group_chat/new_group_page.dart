import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/group_chat/group_store.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class NewGroupPage extends StatefulWidget {
  const NewGroupPage({this.store, super.key});

  /// Absent when storage failed to open; the page then says creation is
  /// unavailable rather than pretending to make a group.
  final GroupStore? store;

  @override
  State<NewGroupPage> createState() => _NewGroupPageState();
}

class _NewGroupPageState extends State<NewGroupPage> {
  final _selected = <String>{};
  final _nameController = TextEditingController();
  var _busy = false;

  /// Only installed, chat-capable experts: offering one that cannot answer
  /// would build a group with a silent member.
  static final _candidates = [
    for (final identity in ExecutableExpertRegistry.installedExpertIdentities)
      (
        identity.canonicalExpertId,
        _registry.catalogById(identity.canonicalExpertId)?.displayName ??
            identity.canonicalExpertId,
        _registry.catalogById(identity.canonicalExpertId)?.description ?? '',
      ),
  ];

  static final _registry = ExecutableExpertRegistry(
    gateway: const ExpertOutputValidationGateway(),
  );

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final store = widget.store;
    if (store == null || _busy) return;
    setState(() => _busy = true);
    try {
      final group = await store.createGroup(
        name: _nameController.text,
        memberExpertIds: _selected.toList(),
      );
      if (!mounted) return;
      // Straight into the group that was just made, not a seeded one.
      context.go('/group/${group.groupId}');
    } on ArgumentError catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${error.message ?? '无法创建群聊'}')));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('创建失败，请重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCreate =
        widget.store != null &&
        !_busy &&
        _selected.length >= 2 &&
        _nameController.text.trim().isNotEmpty;
    return HaloPageScaffold(
      title: '创建 AI 群聊',
      compactTitle: true,
      backgroundColor: HaloColors.paper,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-x',
        semanticLabel: '取消',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/conversations'),
      ),
      actions: [
        TextButton(
          onPressed: canCreate ? _create : null,
          child: Text(
            _busy ? '创建中…' : '完成',
            style: TextStyle(
              color: canCreate ? HaloColors.accentDeep : HaloColors.muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(15, 9, 15, 24),
        children: [
          if (widget.store == null)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                '本机存储当前不可用，暂时无法创建群聊。',
                style: TextStyle(fontSize: 10, color: HaloColors.muted),
              ),
            ),
          const HaloSectionLabel('群名称'),
          TextField(
            controller: _nameController,
            enabled: widget.store != null && !_busy,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '给这个群起个名字',
              filled: true,
              fillColor: HaloColors.soft,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(11)),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          HaloSectionLabel(
            _selected.length < 2
                ? '选择成员 · 至少 2 位'
                : '选择成员 · 已选 ${_selected.length} 个',
          ),
          for (final candidate in _candidates)
            _MemberChoice(
              key: ValueKey('group-candidate-${candidate.$1}'),
              name: candidate.$2,
              description: candidate.$3,
              selected: _selected.contains(candidate.$1),
              onTap: widget.store == null || _busy
                  ? null
                  : () => setState(
                      () => _selected.contains(candidate.$1)
                          ? _selected.remove(candidate.$1)
                          : _selected.add(candidate.$1),
                    ),
            ),
        ],
      ),
    );
  }
}

class _MemberChoice extends StatelessWidget {
  const _MemberChoice({
    required this.name,
    required this.description,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String name;
  final String description;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      leading: HaloAvatar(
        letter: name.isEmpty ? '专' : String.fromCharCode(name.runes.first),
        size: 42,
        backgroundColor: HaloColors.accent,
      ),
      title: Text(
        name,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        description,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: HaloTextStyles.caption,
      ),
      trailing: selected
          ? const HaloTag('已选', tone: HaloTagTone.green)
          : Icon(
              HaloIcon.requirePrototypeClass('ph ph-plus'),
              size: 18,
              color: HaloColors.muted,
            ),
    );
  }
}
