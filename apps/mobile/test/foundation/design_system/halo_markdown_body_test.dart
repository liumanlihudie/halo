import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:halo_mobile/foundation/design_system/halo_markdown_body.dart';

Widget _wrap(Widget child, {double width = 375}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('renders plain text', (tester) async {
    await tester.pumpWidget(_wrap(const HaloMarkdownBody('你好，这是一条普通消息。')));
    await tester.pump();

    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(find.textContaining('你好，这是一条普通消息。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders bold and inline code without exceptions', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const HaloMarkdownBody('前面 **重点内容** 然后 `inline_code` 收尾')),
    );
    await tester.pump();

    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(find.textContaining('重点内容'), findsWidgets);
    expect(find.textContaining('inline_code'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fenced code block renders without overflow in 300px parent', (
    tester,
  ) async {
    const markdown =
        '代码如下：\n'
        '```dart\n'
        'final aVeryVeryVeryLongVariableName = '
        'someFunctionWithAnExtremelyLongName(argumentOne, argumentTwo);\n'
        '```\n'
        '结束。';
    await tester.pumpWidget(
      _wrap(const HaloMarkdownBody(markdown), width: 300),
    );
    await tester.pump();

    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(
      find.textContaining('aVeryVeryVeryLongVariableName'),
      findsOneWidget,
    );
    // No RenderFlex/RenderBox overflow or any other exception thrown.
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty string renders nothing', (tester) async {
    await tester.pumpWidget(_wrap(const HaloMarkdownBody('')));
    await tester.pump();

    expect(find.byType(GptMarkdown), findsNothing);
    expect(find.byType(SizedBox), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
