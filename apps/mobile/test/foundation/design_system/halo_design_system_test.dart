import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

void main() {
  test('Halo tokens reproduce the prototype CSS contract', () {
    expect(HaloColors.ink, const Color(0xFF171923));
    expect(HaloColors.muted, const Color(0xFF8B909A));
    expect(HaloColors.line, const Color(0xFFE9EBEF));
    expect(HaloColors.soft, const Color(0xFFF4F5F7));
    expect(HaloColors.accent, const Color(0xFF5668D8));
    expect(HaloColors.accentDeep, const Color(0xFF3F50B7));
    expect(HaloColors.accentSoft, const Color(0xFFEEF0FF));
    expect(HaloMetrics.navigationBarHeight, 53);
    expect(HaloMetrics.searchHeight, 38);
    expect(HaloMetrics.tabBarHeight, 80);
    expect(HaloMetrics.avatarSize, 50);
    expect(HaloRadii.card, 14);
  });

  test('prototype icon classes have real Phosphor mappings', () {
    expect(HaloIcon.fromPrototypeClass('ph ph-chat-circle-dots'), isNotNull);
    expect(HaloIcon.fromPrototypeClass('ph ph-users-three'), isNotNull);
    expect(HaloIcon.fromPrototypeClass('ph ph-circles-three'), isNotNull);
    expect(HaloIcon.fromPrototypeClass('ph ph-gear-six'), isNotNull);
    expect(HaloIcon.fromPrototypeClass('ph ph-does-not-exist'), isNull);
  });

  testWidgets('shared page and search components expose prototype dimensions', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HaloPageScaffold(
          title: '对话',
          body: Column(children: [HaloSearchField(placeholder: '搜索')]),
        ),
      ),
    );

    expect(find.text('对话'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
    expect(
      tester.getSize(find.byType(HaloSearchField)).height,
      HaloMetrics.searchHeight,
    );
  });

  testWidgets('group avatar reproduces the prototype 2 by 2 tile', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: HaloGroupAvatar(
            tiles: ['letter:产', 'letter:交', 'letter:技', 'letter:增'],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(HaloGroupAvatar)), const Size(50, 50));
    expect(
      find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('group-avatar-tile-');
      }, description: 'four uniquely keyed group avatar tiles'),
      findsNWidgets(4),
    );
  });
}
