import 'package:flutter/material.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';

@immutable
class ModelPickerSelection {
  const ModelPickerSelection.model(this.model) : followsGlobal = false;

  const ModelPickerSelection.followGlobal()
    : model = null,
      followsGlobal = true;

  final ModelRef? model;
  final bool followsGlobal;
}

Future<ModelPickerSelection?> showModelPickerSheet(
  BuildContext context, {
  required List<AvailableModelOption> options,
  ModelRef? selectedModel,
  bool allowFollowGlobal = false,
  bool followingGlobal = false,
}) => showModalBottomSheet<ModelPickerSelection>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (context) => FractionallySizedBox(
    heightFactor: 0.78,
    child: Material(
      color: HaloColors.soft,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ModelPickerSheet(
        options: options,
        selectedModel: selectedModel,
        allowFollowGlobal: allowFollowGlobal,
        followingGlobal: followingGlobal,
      ),
    ),
  ),
);

class ModelPickerSheet extends StatefulWidget {
  ModelPickerSheet({
    required List<AvailableModelOption> options,
    this.selectedModel,
    this.allowFollowGlobal = false,
    this.followingGlobal = false,
    super.key,
  }) : options = List.unmodifiable(options);

  final List<AvailableModelOption> options;
  final ModelRef? selectedModel;
  final bool allowFollowGlobal;
  final bool followingGlobal;

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final groups = _filteredGroups();
    return Column(
      children: [
        const SizedBox(height: 9),
        Container(
          width: 38,
          height: 4,
          decoration: BoxDecoration(
            color: HaloColors.line,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 13, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('选择模型', style: HaloTextStyles.compactTitle),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          child: HaloSearchField(
            placeholder: '搜索模型名称或 ID',
            readOnly: false,
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(15, 0, 15, 24),
            children: [
              if (widget.allowFollowGlobal && _query.isEmpty) ...[
                HaloSettingsGroup(
                  children: [
                    _FollowGlobalRow(
                      selected: widget.followingGlobal,
                      onTap: () => Navigator.of(
                        context,
                      ).pop(const ModelPickerSelection.followGlobal()),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              for (final group in groups.entries) ...[
                HaloSectionLabel(group.key.$2),
                HaloSettingsGroup(
                  children: [
                    for (final option in group.value)
                      _ModelOptionRow(
                        option: option,
                        selected: option.ref == widget.selectedModel,
                        onTap: () => Navigator.of(
                          context,
                        ).pop(ModelPickerSelection.model(option.ref)),
                      ),
                  ],
                ),
              ],
              if (groups.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 48),
                  child: Center(
                    child: Text('没有匹配的模型', style: HaloTextStyles.secondary),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Map<(String, String), List<AvailableModelOption>> _filteredGroups() {
    final query = _query.toLowerCase();
    final groups = <(String, String), List<AvailableModelOption>>{};
    for (final option in widget.options) {
      final matches =
          query.isEmpty ||
          option.modelName.toLowerCase().contains(query) ||
          option.ref.modelId.toLowerCase().contains(query) ||
          option.providerName.toLowerCase().contains(query);
      if (!matches) continue;
      groups
          .putIfAbsent((option.ref.providerId, option.providerName), () => [])
          .add(option);
    }
    return groups;
  }
}

class _FollowGlobalRow extends StatelessWidget {
  const _FollowGlobalRow({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ListTile(
        onTap: onTap,
        title: const Text('跟随全局默认', style: HaloTextStyles.body),
        trailing: selected
            ? const Icon(
                Icons.check_rounded,
                key: ValueKey('selected-follow-global'),
                color: HaloColors.accent,
              )
            : null,
      ),
    );
  }
}

class _ModelOptionRow extends StatelessWidget {
  const _ModelOptionRow({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final AvailableModelOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ListTile(
        onTap: onTap,
        title: Text(option.modelName, style: HaloTextStyles.body),
        subtitle: Text(option.ref.modelId, style: HaloTextStyles.caption),
        trailing: selected
            ? Icon(
                Icons.check_rounded,
                key: ValueKey(
                  'selected-model-${option.ref.providerId}-'
                  '${option.ref.modelId}',
                ),
                color: HaloColors.accent,
              )
            : null,
      ),
    );
  }
}
