import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/app.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

void main() {
  test('prototype fixtures keep the complete primary-screen data contract', () {
    expect(HaloFixtures.conversations, hasLength(12));
    expect(HaloFixtures.marketExperts, hasLength(50));
    expect(HaloFixtures.circlePosts.length, greaterThanOrEqualTo(5));
    expect(HaloFixtures.installedExperts.length, greaterThanOrEqualTo(9));
  });

  testWidgets('the four primary prototype screens are reachable', (
    tester,
  ) async {
    await tester.pumpWidget(const HaloApp());
    await tester.pumpAndSettle();

    expect(find.text('iOS 产品小组'), findsOneWidget);
    expect(find.text('通用助理'), findsOneWidget);

    await tester.tap(find.text('专家团'));
    await tester.pumpAndSettle();
    expect(find.text('AI 市场'), findsOneWidget);
    expect(find.text('工作型 · 5'), findsOneWidget);

    await tester.tap(find.text('圈层'));
    await tester.pumpAndSettle();
    expect(find.text('专家动态'), findsOneWidget);
    expect(find.text('我越来越确定：关键不是增加更多 Agent'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('Halo 本地空间'), findsOneWidget);
    expect(find.text('模型服务'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('自托管 Gateway'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('自托管 Gateway'), findsOneWidget);
  });
}
