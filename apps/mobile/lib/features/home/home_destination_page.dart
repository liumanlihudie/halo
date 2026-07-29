import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class ConversationsPage extends StatelessWidget {
  const ConversationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _DestinationPage(
      title: '对话',
      subtitle: '最近协作',
      rows: [
        _RowData('通用助理', '已整理今天的 3 项重点', '刚刚', CupertinoIcons.sparkles),
        _RowData(
          'iOS 产品小组',
          '技术架构师：本地编排边界已确认',
          '10:12',
          CupertinoIcons.person_3_fill,
        ),
        _RowData(
          '本周信息研判',
          '2 条结论等待事实核查',
          '09:40',
          CupertinoIcons.doc_text_search,
        ),
        _RowData('内容发布团队', '圈层短帖已生成草稿', '昨天', CupertinoIcons.pencil_outline),
      ],
    );
  }
}

class ExpertTeamPage extends StatelessWidget {
  const ExpertTeamPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _DestinationPage(
      title: '专家团',
      subtitle: '我的专家',
      rows: [
        _RowData(
          '产品经理',
          '需求拆解 · 路线图 · 指标',
          '可用',
          CupertinoIcons.chart_bar_alt_fill,
        ),
        _RowData(
          '技术架构师',
          '系统设计 · 风险评审',
          '可用',
          CupertinoIcons.square_stack_3d_up_fill,
        ),
        _RowData(
          '事实核查员',
          '证据核验 · 冲突识别',
          '可用',
          CupertinoIcons.checkmark_shield_fill,
        ),
        _RowData(
          '浏览 AI 市场',
          '从 50 位专家中添加',
          '',
          CupertinoIcons.add_circled_solid,
        ),
      ],
    );
  }
}

class CirclePage extends StatelessWidget {
  const CirclePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _DestinationPage(
      title: '圈层',
      subtitle: '专家动态',
      rows: [
        _RowData(
          '产品经理',
          '发布了《iOS MVP 范围总结》',
          '8 分钟前',
          CupertinoIcons.doc_plaintext,
        ),
        _RowData(
          '信息观察员',
          '发现 2 条值得跟进的行业变化',
          '1 小时前',
          CupertinoIcons.antenna_radiowaves_left_right,
        ),
        _RowData(
          '数据分析师',
          '本周成本趋势已更新',
          '昨天',
          CupertinoIcons.chart_bar_square_fill,
        ),
      ],
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _DestinationPage(
      title: '设置',
      subtitle: '模型服务',
      rows: [
        _RowData('模型服务', 'ToAPIs、官方 API 与本地模型', '3 个可用', CupertinoIcons.cloud),
        _RowData(
          '本地数据',
          '对话、记忆与文件均保存在本机',
          '12.8 MB',
          CupertinoIcons.archivebox_fill,
        ),
        _RowData('记忆与隐私', '按专家管理共享范围', '', CupertinoIcons.lock_shield_fill),
        _RowData('自托管 Gateway', '可选扩展，当前未连接', '未连接', CupertinoIcons.link),
      ],
    );
  }
}

class _DestinationPage extends StatelessWidget {
  const _DestinationPage({
    required this.title,
    required this.subtitle,
    required this.rows,
  });

  final String title;
  final String subtitle;
  final List<_RowData> rows;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      key: PageStorageKey(title),
      slivers: [
        SliverAppBar.large(title: Text(title)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Text(
              subtitle,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF555E70),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverList.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 66),
            itemBuilder: (context, index) {
              final row = rows[index];
              return ColoredBox(
                color: Colors.white,
                child: ListTile(
                  minTileHeight: 72,
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    foregroundColor: Theme.of(context).colorScheme.primary,
                    child: Icon(row.icon, size: 21),
                  ),
                  title: Text(
                    row.title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    row.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: row.meta.isEmpty
                      ? const Icon(CupertinoIcons.chevron_forward, size: 16)
                      : Text(
                          row.meta,
                          style: const TextStyle(
                            color: Color(0xFF8B919D),
                            fontSize: 12,
                          ),
                        ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RowData {
  const _RowData(this.title, this.detail, this.meta, this.icon);

  final String title;
  final String detail;
  final String meta;
  final IconData icon;
}
