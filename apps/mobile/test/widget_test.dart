import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';

void main() {
  testWidgets('cold start opens the four-tab local-first shell', (
    tester,
  ) async {
    await tester.pumpWidget(const HaloApp());
    await tester.pumpAndSettle();

    expect(find.text('对话'), findsWidgets);
    expect(find.text('专家团'), findsOneWidget);
    expect(find.text('圈层'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('登录'), findsNothing);
    expect(find.text('注册'), findsNothing);
  });

  testWidgets('each primary destination is reachable', (tester) async {
    await tester.pumpWidget(const HaloApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('专家团'));
    await tester.pumpAndSettle();
    expect(find.text('我的专家'), findsOneWidget);

    await tester.tap(find.text('圈层'));
    await tester.pumpAndSettle();
    expect(find.text('专家动态'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('自托管 Gateway'), findsOneWidget);
  });
}
