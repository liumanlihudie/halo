import 'dart:convert';

import 'package:halo_mobile/experts/expert_prompt_package.dart';

/// The contract for advice-only experts: just answer.
///
/// These experts used to wrap every reply in a JSON envelope whose advice
/// fields were constants the application pins anyway. The wrapper bought no
/// safety and routinely destroyed finished answers when the model's JSON was
/// off by a character, so it is gone: the reply is the answer.
String _renderPlainAnswerPrompt() => [
  '输出格式：',
  '直接用自然中文回答用户，像正常对话一样。不要输出 JSON、不要写字段名、'
      '不要用任何包装结构，你写的全部内容就是用户看到的回答。',
  '支持 Markdown：内容较长或分点时用标题、无序/有序列表、**加粗**、'
      '`行内代码` 与代码块（```）来组织；简短回答保持纯文本即可。',
].join('\n');

/// Renders the output contract an executable expert must satisfy.
///
/// Shared by single chat and group chat on purpose: an expert whose prompt omits
/// the template or the controlled verb list will return JSON that fails
/// `validateAndProject`, and the turn is then dropped with nothing to show the
/// user. Both paths must state the same contract.
String renderExpertOutputPrompt(ExecutableExpert expert) {
  if (expert.usesPlainAnswer) return _renderPlainAnswerPrompt();
  const proposedAction = {
    'verb': 'review',
    'target': 'replace-with-target',
    'conditions': ['replace-with-condition'],
  };
  final template = <String, Object?>{};
  for (final entry in expert.profile.outputSchema.fields.entries) {
    template[entry.key] = switch (entry.value) {
      OutputValueType.string => 'replace-with-answer',
      OutputValueType.answerText => 'replace-with-chinese-answer',
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
    if (expert.profile.outputSchema.fields.containsKey(expertAnswerField))
      'Answer 是唯一会展示给用户的字段：用自然中文直接回答用户，像正常对话一样，'
          '不要写 JSON、不要写字段名、不要罗列其他字段的内容。其余字段是内部结构，用户看不到。'
          'Answer 不得超过 1200 字，且只能包含换行以外的可见字符。',
    if (expert.profile.outputSchema.fields.containsKey(expertAnswerField))
      // The chat bubble renders Answer as Markdown, so structure is welcome —
      // without this the model returns one unbroken wall of text.
      'Answer 支持 Markdown：内容较长或分点时请用标题、无序/有序列表、**加粗**、'
          '`行内代码` 与代码块（```）来组织，换行写成 JSON 字符串里的 \\n。'
          '简短回答保持纯文本即可，不要为了格式而格式。',
    'Verification.proposedActions MUST contain at least one action. Its verb '
        'MUST be one of: analyze, compare, document, implement, measure, plan, '
        'query, review, test, train, verify. target and every condition MUST '
        'be lowercase ASCII kebab-case identifiers. executedFacts MUST be [].',
    jsonEncode(template),
  ].join('\n');
}
