import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/expert_market/expert_profile_page.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';

void main() {
  final deepSeekChat = ModelRef(
    providerId: 'deepseek',
    modelId: 'deepseek-chat',
  );
  final toApisSelected = ModelRef(
    providerId: 'toapis',
    modelId: 'selected-model-id',
  );
  final options = [
    AvailableModelOption(
      ref: deepSeekChat,
      providerName: 'DeepSeek',
      modelName: 'DeepSeek Chat',
    ),
    AvailableModelOption(
      ref: toApisSelected,
      providerName: 'ToAPIs',
      modelName: 'Selected Model',
    ),
  ];

  testWidgets('installed expert displays the effective global model', (
    tester,
  ) async {
    final persistence = _Persistence(
      options: options,
      globalDefault: deepSeekChat,
    );
    await _pumpProfile(
      tester,
      controller: _controller(persistence),
      canonicalExpertId: 'product-manager',
    );

    expect(find.text('模型'), findsOneWidget);
    expect(find.text('跟随默认 · DeepSeek / deepseek-chat'), findsOneWidget);
  });

  testWidgets('installed expert can choose an independent persisted model', (
    tester,
  ) async {
    final persistence = _Persistence(
      options: options,
      globalDefault: deepSeekChat,
    );
    await _pumpProfile(
      tester,
      controller: _controller(persistence),
      canonicalExpertId: 'product-manager',
    );

    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selected Model'));
    await tester.pumpAndSettle();

    expect(find.text('独立 · ToAPIs / selected-model-id'), findsOneWidget);
    expect(persistence.expertWrites, [('product-manager', toApisSelected)]);
  });

  testWidgets('follow global deletes the canonical expert override', (
    tester,
  ) async {
    final persistence = _Persistence(
      options: options,
      globalDefault: deepSeekChat,
      expertOverrides: {'product-manager': toApisSelected},
    );
    await _pumpProfile(
      tester,
      controller: _controller(persistence),
      canonicalExpertId: 'product-manager',
    );
    expect(find.text('独立 · ToAPIs / selected-model-id'), findsOneWidget);

    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随全局默认'));
    await tester.pumpAndSettle();

    expect(find.text('跟随默认 · DeepSeek / deepseek-chat'), findsOneWidget);
    expect(persistence.expertWrites, [('product-manager', null)]);
    expect(persistence.expertOverrides['product-manager'], isNull);
  });

  testWidgets('market profile never exposes an editable model routing row', (
    tester,
  ) async {
    final persistence = _Persistence(
      options: options,
      globalDefault: deepSeekChat,
    );
    await _pumpProfile(
      tester,
      controller: _controller(persistence),
      canonicalExpertId: 'project-manager',
      expertId: 'market-5',
      marketMode: true,
    );

    expect(find.widgetWithText(HaloSettingsRow, '模型'), findsNothing);
    expect(persistence.loadedExpertIds, isEmpty);
    expect(persistence.expertWrites, isEmpty);
  });
}

ModelRoutingController _controller(_Persistence persistence) =>
    ModelRoutingController(persistence: persistence, runtime: _Reloader());

Future<void> _pumpProfile(
  WidgetTester tester, {
  required ModelRoutingController controller,
  required String canonicalExpertId,
  String expertId = 'product',
  bool marketMode = false,
}) async {
  tester.view.physicalSize = const Size(430, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: ExpertProfilePage(
        expertId: expertId,
        installedIdentity: InstalledExpertIdentity(
          profileId: expertId,
          conversationId: '$expertId-chat',
          canonicalExpertId: canonicalExpertId,
        ),
        marketMode: marketMode,
        routingController: controller,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _Persistence
    implements ModelRoutingPersistence, ModelRoutingRollbackPersistence {
  _Persistence({
    required this.options,
    required this.globalDefault,
    Map<String, ModelRef> expertOverrides = const {},
  }) : expertOverrides = Map.of(expertOverrides);

  final List<AvailableModelOption> options;
  ModelRef? globalDefault;
  final Map<String, ModelRef> expertOverrides;
  final List<String> loadedExpertIds = [];
  final List<(String, ModelRef?)> expertWrites = [];

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
  Future<ModelRef?> loadExpertOverride(String expertId) async {
    loadedExpertIds.add(expertId);
    return expertOverrides[expertId];
  }

  @override
  Future<void> setExpertOverride(String expertId, ModelRef? model) async {
    if (model == null) {
      expertOverrides.remove(expertId);
    } else {
      expertOverrides[expertId] = model;
    }
    expertWrites.add((expertId, model));
  }
}

final class _Reloader implements ProviderRuntimeReloader {
  @override
  Future<void> reload() async {}
}
