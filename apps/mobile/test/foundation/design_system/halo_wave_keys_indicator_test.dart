import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/foundation/design_system/halo_wave_keys_indicator.dart';

void main() {
  Future<void> pumpIndicator(
    WidgetTester tester, {
    int keyCount = 5,
    double maxKeyHeight = 18,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: HaloWaveKeysIndicator(
            keyCount: keyCount,
            maxKeyHeight: maxKeyHeight,
          ),
        ),
      ),
    ),
  );

  List<double> keyHeights(WidgetTester tester) => tester
      .widgetList<Container>(find.byType(Container))
      .map((container) => container.constraints!.maxHeight)
      .toList();

  testWidgets('renders one key per requested slot within the height bounds', (
    tester,
  ) async {
    await pumpIndicator(tester, keyCount: 6);
    await tester.pump(const Duration(milliseconds: 120));

    final heights = keyHeights(tester);
    expect(heights, hasLength(6));
    for (final height in heights) {
      expect(height, greaterThanOrEqualTo(6));
      expect(height, lessThanOrEqualTo(18));
    }
    expect(find.bySemanticsLabel('正在生成回复'), findsOneWidget);
  });

  testWidgets('keys travel out of phase so the row reads as a wave', (
    tester,
  ) async {
    await pumpIndicator(tester);
    await tester.pump(const Duration(milliseconds: 150));

    final heights = keyHeights(tester);
    expect(heights.toSet(), hasLength(greaterThan(1)));
  });

  testWidgets('the wave keeps animating rather than settling', (tester) async {
    await pumpIndicator(tester);
    await tester.pump(const Duration(milliseconds: 100));
    final first = keyHeights(tester);

    await tester.pump(const Duration(milliseconds: 275));
    final second = keyHeights(tester);

    expect(second, isNot(first));
  });

  testWidgets('disposal leaves no pending ticker', (tester) async {
    await pumpIndicator(tester);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(find.byType(HaloWaveKeysIndicator), findsNothing);
  });
}
