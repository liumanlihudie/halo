import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/local_data_maintenance.dart';
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

  testWidgets('local data disables every action without storage', (
    tester,
  ) async {
    await tester.pumpWidget(
      const HaloApp(initialLocation: '/settings/local-data'),
    );
    await tester.pumpAndSettle();

    expect(find.text('数据默认保存在本机'), findsOneWidget);
    expect(find.text('API Key 不进入导出包'), findsOneWidget);
    // Storage figures must come from disk, never from a hardcoded literal.
    expect(find.text('2.8 GB'), findsNothing);
    expect(find.text('486 MB'), findsNothing);
    // No maintenance port means no armed destructive button.
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '清除本机数据'))
          .onPressed,
      isNull,
    );
    expect(find.text('不可用'), findsWidgets);
  });

  testWidgets('local data reports measured storage and counts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LocalDataPage(maintenance: _FakeMaintenance())),
    );
    await tester.pump();

    expect(find.text('1.5 MB'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('erasing local data requires confirmation', (tester) async {
    final maintenance = _FakeMaintenance();
    await tester.pumpWidget(
      MaterialApp(home: LocalDataPage(maintenance: maintenance)),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(OutlinedButton, '清除本机数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(maintenance.erased, 0);

    await tester.tap(find.widgetWithText(OutlinedButton, '清除本机数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '清除'));
    await tester.pumpAndSettle();
    expect(maintenance.erased, 1);
    expect(find.text('本机对话数据已清除'), findsOneWidget);
  });

  testWidgets('export shares the written bundle', (tester) async {
    final maintenance = _FakeMaintenance();
    final shared = <LocalDataExportBundle>[];
    await tester.pumpWidget(
      MaterialApp(
        home: LocalDataPage(
          maintenance: maintenance,
          shareExport: (bundle) async => shared.add(bundle),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('导出数据包'));
    await tester.pumpAndSettle();

    expect(shared, hasLength(1));
    expect(shared.single.byteCount, 2048);
  });
}

class _FakeMaintenance implements LocalDataMaintenancePort {
  int erased = 0;

  @override
  Future<LocalDataSnapshot> loadSnapshot() async => const LocalDataSnapshot(
    storageBytes: 1572864,
    cacheBytes: 1024,
    conversationCount: 7,
    messageCount: 42,
  );

  @override
  Future<int> clearCache() async => 1024;

  @override
  Future<LocalDataExportBundle> exportBundle() async =>
      LocalDataExportBundle(file: File('halo-export.json'), byteCount: 2048);

  @override
  Future<void> eraseLocalData() async => erased += 1;
}
