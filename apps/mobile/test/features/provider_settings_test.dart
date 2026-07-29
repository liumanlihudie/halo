import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/local_data_page.dart';
import 'package:halo_mobile/app/app.dart';

void main() {
  testWidgets('model services show BYOK defaults and concurrent providers', (
    tester,
  ) async {
    await tester.pumpWidget(
      const HaloApp(initialLocation: '/settings/providers'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bring Your Own Key'), findsOneWidget);
    expect(find.text('默认文字模型'), findsOneWidget);
    expect(find.text('ToAPIs'), findsOneWidget);
    expect(find.text('DeepSeek'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('本地模型'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('本地模型'), findsOneWidget);
  });

  testWidgets('local data states local-first boundaries', (tester) async {
    await tester.pumpWidget(
      const HaloApp(initialLocation: '/settings/local-data'),
    );
    await tester.pumpAndSettle();

    expect(find.text('数据默认保存在本机'), findsOneWidget);
    expect(find.text('API Key 不进入导出包'), findsOneWidget);
    expect(find.text('清除本机数据'), findsOneWidget);
    // Storage figures must come from disk, never from a hardcoded literal, and
    // unimplemented destructive actions must not look armed.
    expect(find.text('2.8 GB'), findsNothing);
    expect(find.text('486 MB'), findsNothing);
    expect(find.text('尚未开放'), findsNWidgets(3));
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '清除本机数据'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('local data reports measured storage, never an invented one', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: LocalDataPage(usageLoader: _fixedUsage)),
    );
    await tester.pump();

    expect(find.text('1.5 MB'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(2));
  });
}

Future<int> _fixedUsage() async => 1572864;
