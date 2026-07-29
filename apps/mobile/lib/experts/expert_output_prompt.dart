import 'dart:convert';

import 'package:halo_mobile/experts/expert_prompt_package.dart';

/// Renders the output contract an executable expert must satisfy.
///
/// Shared by single chat and group chat on purpose: an expert whose prompt omits
/// the template or the controlled verb list will return JSON that fails
/// `validateAndProject`, and the turn is then dropped with nothing to show the
/// user. Both paths must state the same contract.
String renderExpertOutputPrompt(ExecutableExpert expert) {
  const proposedAction = {
    'verb': 'review',
    'target': 'replace-with-target',
    'conditions': ['replace-with-condition'],
  };
  final template = <String, Object?>{};
  for (final entry in expert.profile.outputSchema.fields.entries) {
    template[entry.key] = switch (entry.value) {
      OutputValueType.string => 'replace-with-answer',
      OutputValueType.stringList => ['replace-with-item'],
      OutputValueType.evidenceList => <Object?>[],
      OutputValueType.integer => 0,
      OutputValueType.boolean => false,
      OutputValueType.proposedActionList => [proposedAction],
      OutputValueType.verificationEnvelope => {
        'claimType': 'advice',
        'tense': 'proposed',
        'verified': false,
        'source': 'none',
        'proposedActions': [proposedAction],
        'executedFacts': <String>[],
      },
    };
  }
  return [
    'Output format:',
    'Return exactly one valid JSON object and no Markdown or surrounding text.',
    'Use exactly the keys and value shapes in this template. Replace every '
        'placeholder with a concise answer. Do not add or remove keys.',
    'Verification.proposedActions MUST contain at least one action. Its verb '
        'MUST be one of: analyze, compare, document, implement, measure, plan, '
        'query, review, test, train, verify. target and every condition MUST '
        'be lowercase ASCII kebab-case identifiers. executedFacts MUST be [].',
    jsonEncode(template),
  ].join('\n');
}
