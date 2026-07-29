import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/orchestration_kernel.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';

final orchestrationKernelProvider = Provider<OrchestrationKernel>((ref) {
  return BasicDurableRunner(
    store: InMemoryRunEventStore(),
    selector: const KeywordAgentSelector(),
    runtime: const LocalPrototypeAgentRuntime(),
  );
});

class KeywordAgentSelector implements AgentSelector {
  const KeywordAgentSelector();

  static const _keywordsByAgent = <String, List<String>>{
    'product-manager': ['产品', '需求', '用户', 'MVP', '优先级'],
    'interaction-designer': ['交互', '界面', '体验', '流程', '设计'],
    'technical-architect': ['iOS', '技术', '架构', '工程', '性能', '风险'],
    'growth-advisor': ['增长', '市场', '商业化', '留存', '分发'],
  };

  @override
  Future<List<String>> select(AgentSelectionRequest request) async {
    final normalizedInput = request.input.toLowerCase();
    final scored =
        request.candidateAgentIds.map((agentId) {
          final score =
              _keywordsByAgent[agentId]
                  ?.where(
                    (keyword) =>
                        normalizedInput.contains(keyword.toLowerCase()),
                  )
                  .length ??
              0;
          return (agentId: agentId, score: score);
        }).toList()..sort((left, right) {
          final scoreOrder = right.score.compareTo(left.score);
          if (scoreOrder != 0) {
            return scoreOrder;
          }
          return request.candidateAgentIds
              .indexOf(left.agentId)
              .compareTo(request.candidateAgentIds.indexOf(right.agentId));
        });

    final relevant = scored
        .where((candidate) => candidate.score > 0)
        .take(2)
        .map((candidate) => candidate.agentId)
        .toList();
    return relevant.isEmpty
        ? request.candidateAgentIds.take(1).toList()
        : relevant;
  }
}

class LocalPrototypeAgentRuntime implements AgentRuntime {
  const LocalPrototypeAgentRuntime();

  static const _prefixByAgent = <String, String>{
    'product-manager': '产品判断',
    'interaction-designer': '交互判断',
    'technical-architect': '技术判断',
    'growth-advisor': '增长判断',
  };

  @override
  Future<String> respond(AgentTurnRequest request) async {
    final prefix = _prefixByAgent[request.agentId] ?? '专家判断';
    return switch (request.agentId) {
      'product-manager' => '$prefix：先验证高频工作信息到行动的闭环，再扩大 Agent 数量。',
      'interaction-designer' => '$prefix：模式、当前发言者和运行阶段必须持续可见，避免用户猜测。',
      'technical-architect' => '$prefix：先冻结成员和预算，以事件序列驱动消息，避免重复回复。',
      'growth-advisor' => '$prefix：用真实工作任务验证留存，不把陪聊时长当成核心指标。',
      _ => '$prefix：已收到“${request.input}”，建议先完成一个可验证的小闭环。',
    };
  }

  @override
  Future<String> summarize(DiscussionSummaryRequest request) async {
    final details = request.outcomes
        .map((outcome) {
          final text = outcome.text;
          return text == null
              ? '${outcome.agentId}：本轮回答失败'
              : '${outcome.agentId}：$text';
        })
        .join('；');
    return '群聊总结：$details';
  }
}
