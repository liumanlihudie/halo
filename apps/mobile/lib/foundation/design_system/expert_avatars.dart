/// One designed SVG badge per expert, resolved from any of the identifiers
/// the app uses for that expert — profile id, canonical expert id,
/// conversation id or market id. Null means the caller falls back to its
/// letter avatar; nothing is ever invented here.
abstract final class ExpertAvatars {
  static const _installedProfiles = {
    'general',
    'product',
    'data',
    'writing',
    'contract',
    'watcher',
    'researcher',
    'calendar',
    'fitness',
  };

  /// Conversation ids and canonical expert ids, folded onto their profile.
  /// Mirrors [ExecutableExpertRegistry.installedExpertIdentities]; the
  /// completeness test keeps the two from drifting apart.
  static const _aliases = {
    'general-assistant': 'general',
    'halo-assistant': 'general',
    'product-manager-chat': 'product',
    'product-manager': 'product',
    'data-analyst-chat': 'data',
    'data-analyst': 'data',
    'writing-advisor-chat': 'writing',
    'content-strategist': 'writing',
    'calendar-assistant': 'calendar',
    'operations-manager': 'calendar',
    'contract-review-chat': 'contract',
    'legal-risk-advisor': 'contract',
    'monitoring-chat': 'watcher',
    'fact-checker': 'watcher',
    'deep-research-task': 'researcher',
    'industry-researcher': 'researcher',
    'fitness-planner-chat': 'fitness',
    'fitness-planner': 'fitness',
  };

  static final _marketId = RegExp(r'^market-\d+$');

  static String? assetFor(String? id) {
    if (id == null || id.isEmpty) return null;
    final profile = _aliases[id] ?? id;
    if (_installedProfiles.contains(profile)) {
      return 'assets/experts/$profile.svg';
    }
    if (_marketId.hasMatch(profile)) {
      return 'assets/experts/$profile.svg';
    }
    return null;
  }
}
