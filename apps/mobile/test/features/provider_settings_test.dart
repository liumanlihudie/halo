import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
    expect(find.text('2.8 GB'), findsOneWidget);
    expect(find.text('API Key 不进入导出包'), findsOneWidget);
    expect(find.text('清除本机数据'), findsOneWidget);
  });
}
