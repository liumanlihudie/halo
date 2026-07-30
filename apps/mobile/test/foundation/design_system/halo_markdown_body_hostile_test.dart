import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/foundation/design_system/halo_markdown_body.dart';

/// Probes with the kinds of content a real model reply actually contains,
/// hunting the render error seen on device.
void main() {
  Future<void> pumpBody(WidgetTester tester, String text) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 320, child: HaloMarkdownBody(text)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  final cases = <String, String>{
    'latex dollars': r'预算是 $100，翻倍后是 $200。公式 $x^2 + y^2 = z^2$ 也常见。',
    'table': '| 项目 | 结果 |\n|---|---|\n| 可靠性 | 高 |\n| 成本 | 低 |',
    'nested list': '1. 第一\n   - 子项 A\n   - 子项 B\n2. 第二\n   1. 又一层',
    'html-ish': '这里有 <b>标签</b> 和 <div>块</div> 以及 <script>x</script>',
    'unclosed fence': '代码如下：\n```dart\nvoid main() {',
    'mixed heavy':
        '# 计划\n**目标**：`发布`\n\n> 引用一段\n\n---\n\n[链接](https://example.com) 和 ![图](x.png)',
    'long cjk paragraph': '这是一段很长的中文，没有任何标点分隔的超长词组测试折行行为' * 12,
  };

  for (final entry in cases.entries) {
    testWidgets('renders without exception: ${entry.key}', (tester) async {
      await pumpBody(tester, entry.value);
      expect(tester.takeException(), isNull, reason: entry.key);
    });
  }
}
