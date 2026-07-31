import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/circle/circle_news_store.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

/// Turns each expert's news job on or off.
///
/// Everything starts off. Nine experts left on by default would be nine
/// searches and nine model calls a day that nobody asked for.
class CircleNewsPage extends StatefulWidget {
  const CircleNewsPage({this.store, super.key});

  final CircleNewsStore? store;

  @override
  State<CircleNewsPage> createState() => _CircleNewsPageState();
}

class _CircleNewsPageState extends State<CircleNewsPage> {
  static final _registry = ExecutableExpertRegistry(
    gateway: const ExpertOutputValidationGateway(),
  );

  Map<String, NewsJob> _jobs = const {};
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = widget.store;
    if (store == null) {
      if (mounted) setState(() => _loaded = true);
      return;
    }
    try {
      final jobs = await store.loadJobs();
      if (!mounted) return;
      setState(() {
        _jobs = {for (final job in jobs) job.expertId: job};
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _toggle(String expertId, String topic, bool enabled) async {
    final store = widget.store;
    if (store == null) return;
    final existing = _jobs[expertId];
    await store.saveJob(
      NewsJob(
        expertId: expertId,
        topic: existing?.topic ?? topic,
        cadence: existing?.cadence ?? NewsCadence.daily,
        enabled: enabled,
        // Turning it on stamps the clock, so the first run happens one period
        // from now rather than the instant the switch is flipped.
        lastRunAt: enabled
            ? (existing?.lastRunAt ?? DateTime.now().toUtc())
            : existing?.lastRunAt,
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final identities = ExecutableExpertRegistry.installedExpertIdentities;
    return HaloPageScaffold(
      title: '资讯中心',
      compactTitle: true,
      backgroundColor: HaloColors.soft,
      leading: HaloIconButton(
        prototypeIconClass: 'ph ph-caret-left',
        semanticLabel: '返回',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(15, 10, 15, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: HaloColors.accentSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              '开启后，专家会在你打开 App 时检索自己领域的新内容，挑几条发到圈层。'
              '每位专家每天最多一次；没搜到新内容就不发、也不调用模型。'
              '搜索和模型调用都会产生费用。',
              style: TextStyle(
                fontSize: 10,
                height: 1.5,
                color: HaloColors.accentDeep,
              ),
            ),
          ),
          if (widget.store == null)
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: Text(
                '本机存储当前不可用。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: HaloColors.muted),
              ),
            )
          else if (!_loaded)
            const SizedBox.shrink()
          else
            HaloSettingsGroup(
              children: [
                for (final identity in identities)
                  _NewsRow(
                    key: ValueKey('news-${identity.canonicalExpertId}'),
                    name:
                        _registry
                            .catalogById(identity.canonicalExpertId)
                            ?.displayName ??
                        identity.canonicalExpertId,
                    job: _jobs[identity.canonicalExpertId],
                    onChanged: (enabled) => _toggle(
                      identity.canonicalExpertId,
                      _topicFor(identity.canonicalExpertId),
                      enabled,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// What this expert goes looking for, taken from its own profile so the
  /// query matches the job it was written for.
  String _topicFor(String canonicalExpertId) {
    final profile = _registry.catalogById(canonicalExpertId);
    if (profile == null) return canonicalExpertId;
    return '${profile.displayName} 领域 最新进展';
  }
}

class _NewsRow extends StatelessWidget {
  const _NewsRow({
    required this.name,
    required this.job,
    required this.onChanged,
    super.key,
  });

  final String name;
  final NewsJob? job;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = job?.enabled ?? false;
    final lastRun = job?.lastRunAt;
    return HaloSettingsRow(
      label: name,
      // Says when it last ran, not when it is "scheduled" for: the schedule is
      // a hope, the last run is a fact.
      detail: !enabled
          ? '关闭'
          : lastRun == null
          ? '已开启 · 还没有跑过'
          : '上次 ${lastRun.toLocal().month}-${lastRun.toLocal().day}',
      trailing: Switch.adaptive(value: enabled, onChanged: onChanged),
    );
  }
}
