import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/local_data_maintenance.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/features/settings/settings_page.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  final deepSeekChat = ModelRef(
    providerId: 'deepseek',
    modelId: 'deepseek-chat',
  );
  final options = [
    AvailableModelOption(
      ref: deepSeekChat,
      providerName: 'DeepSeek',
      modelName: 'DeepSeek Chat',
    ),
    AvailableModelOption(
      ref: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      providerName: 'ToAPIs',
      modelName: 'GPT-5 mini',
    ),
  ];

  Future<void> pumpPage(
    WidgetTester tester, {
    ModelRoutingController? routing,
    LocalDataMaintenancePort? localData,
    AppVersionLoader? versionLoader,
  }) async {
    tester.view.physicalSize = const Size(430, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          modelRouting: routing,
          localData: localData,
          versionLoader: versionLoader,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows real model counts and the default model name', (
    tester,
  ) async {
    final controller = ModelRoutingController(
      persistence: _Persistence(options: options, globalDefault: deepSeekChat),
      runtime: _Reloader(),
    );

    await pumpPage(tester, routing: controller);

    expect(find.text('2 个可用模型'), findsOneWidget);
    expect(find.text('DeepSeek Chat'), findsOneWidget);
    expect(find.text('可用模型'), findsOneWidget);
  });

  testWidgets('without runtime dependencies it degrades honestly', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('配置与启停'), findsOneWidget);
    expect(find.text('暂不可用'), findsOneWidget);
    // Both the model count and the conversation count come from runtime
    // dependencies, so without them the card shows two honest dashes rather
    // than fixture numbers.
    expect(find.text('—'), findsNWidgets(2));
  });

  testWidgets('the version row reports the running build', (tester) async {
    await pumpPage(
      tester,
      versionLoader: () async => PackageInfo(
        appName: 'Halo Mobile',
        packageName: 'com.cofe.haloMobile',
        version: '1.4.2',
        buildNumber: '37',
      ),
    );

    // Never a literal: a hardcoded version silently goes stale on every bump.
    expect(find.text('1.4.2 (37)'), findsOneWidget);
  });

  testWidgets('a failing version read stays honest', (tester) async {
    await pumpPage(tester, versionLoader: () async => throw StateError('no'));

    expect(find.text('读取中'), findsOneWidget);
  });

  testWidgets('the conversation counter comes from storage', (tester) async {
    await pumpPage(tester, localData: _StubLocalData());

    expect(find.text('12'), findsOneWidget);
  });

  testWidgets('unset default model is labeled 未设置', (tester) async {
    final controller = ModelRoutingController(
      persistence: _Persistence(options: options, globalDefault: null),
      runtime: _Reloader(),
    );

    await pumpPage(tester, routing: controller);

    expect(find.text('未设置'), findsOneWidget);
  });

  testWidgets('fabricated claims are gone and planned work is labeled', (
    tester,
  ) async {
    await pumpPage(tester);

    // Old fixture rows fabricated state that never existed.
    expect(find.textContaining('共享记忆'), findsNothing);
    expect(find.textContaining('已配置', findRichText: true), findsNothing);
    expect(find.textContaining('Vidu'), findsNothing);
    expect(find.textContaining('Apache-2.0'), findsNothing);
    expect(find.text('规划中'), findsWidgets);
    expect(find.text('开源准备中，尚未发布'), findsOneWidget);
  });
}

final class _Persistence
    implements ModelRoutingPersistence, ModelRoutingRollbackPersistence {
  _Persistence({required this.options, required this.globalDefault});

  final List<AvailableModelOption> options;
  ModelRef? globalDefault;

  @override
  Future<List<AvailableModelOption>> loadAvailableModels() async => options;

  @override
  Future<ModelRef?> loadGlobalDefault() async => globalDefault;

  @override
  Future<void> setGlobalDefault(ModelRef model) async {
    globalDefault = model;
  }

  @override
  Future<void> restoreGlobalDefault(ModelRef? model) async {
    globalDefault = model;
  }

  @override
  Future<ModelRef?> loadExpertOverride(String expertId) async => null;

  @override
  Future<void> setExpertOverride(String expertId, ModelRef? model) async {}
}

final class _Reloader implements ProviderRuntimeReloader {
  @override
  Future<void> reload() async {}
}

class _StubLocalData implements LocalDataMaintenancePort {
  @override
  Future<LocalDataSnapshot> loadSnapshot() async =>
      const LocalDataSnapshot(conversationCount: 12, messageCount: 60);

  @override
  Future<int> clearCache() async => 0;

  @override
  Future<LocalDataExportBundle> exportBundle() =>
      throw UnimplementedError('settings page never exports');

  @override
  Future<void> eraseLocalData() =>
      throw UnimplementedError('settings page never erases');
}
