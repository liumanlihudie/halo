import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';

/// Field evidence (2026-07-30, iPhone + simulator): a complete, well-formed
/// Chinese answer was discarded as "发送失败" because the model's *other*
/// envelope fields missed the strict contract (controlled verbs, kebab-case
/// targets, exact key sets). The advice envelope is a constant the app pins
/// anyway, so requiring the model to echo it buys no safety and loses answers.
void main() {
  final registry = ExecutableExpertRegistry(
    gateway: const ExpertOutputValidationGateway(),
  );
  final expert = registry.singleChatById('product-manager')!;

  test('a valid answer projects even when the rest of the envelope is off', () {
    final projected = expert.projectAdviceAnswer('先把需求澄清清楚，再决定优先级。');

    expect(projected, '先把需求澄清清楚，再决定优先级。');
  });

  test('answer text rules still apply', () {
    expect(expert.projectAdviceAnswer('   '), isNull);
    expect(expert.projectAdviceAnswer(''), isNull);
    expect(expert.projectAdviceAnswer(42), isNull);
    expect(expert.projectAdviceAnswer(null), isNull);
    // Bidi override: a display-layer spoofing tool, never content.
    expect(expert.projectAdviceAnswer('正常\u202E倒转'), isNull);
    expect(expert.projectAdviceAnswer('超长' * 700), isNull);
  });

  test('newlines survive so markdown answers keep their structure', () {
    const markdown = '## 结论\n\n- 第一点\n- 第二点\n\n```dart\nvoid main() {}\n```';

    expect(expert.projectAdviceAnswer(markdown), markdown);
  });

  test('sanitizing repairs a reply instead of discarding it', () {
    // Every one of these used to destroy a finished answer.
    expect(expert.sanitizePlainAnswer('第一行\t缩进'), '第一行  缩进');
    expect(expert.sanitizePlainAnswer('正常\u202E倒转'), '正常倒转');
    expect(expert.sanitizePlainAnswer('  前后空白  '), '前后空白');
    // A long answer is delivered whole: mainstream clients (ChatMCP,
    // flutter_ai_toolkit, dartantic) never cap or cut reply text.
    final long = expert.sanitizePlainAnswer('超长' * 700)!;
    expect(long.length, 1400);
    // Markdown structure survives untouched.
    const markdown = '## 结论\n\n- 第一点\n- 第二点';
    expect(expert.sanitizePlainAnswer(markdown), markdown);
    // Only a genuinely empty reply has nothing to show.
    expect(expert.sanitizePlainAnswer('   \u200B '), isNull);
  });
}
