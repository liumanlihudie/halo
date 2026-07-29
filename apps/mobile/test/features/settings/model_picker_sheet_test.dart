import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/model_picker_sheet.dart';
import 'package:halo_mobile/features/settings/model_providers_page.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';

void main() {
  final deepSeekChat = ModelRef(
    providerId: 'deepseek',
    modelId: 'deepseek-chat',
  );
  final deepSeekReasoner = ModelRef(
    providerId: 'deepseek',
    modelId: 'deepseek-reasoner',
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
      ref: deepSeekReasoner,
      providerName: 'DeepSeek',
      modelName: 'Reasoning Model',
    ),
    AvailableModelOption(
      ref: toApisSelected,
      providerName: 'ToAPIs',
      modelName: 'Fast Selected Model',
    ),
  ];

  testWidgets(
    'picker groups every saved model by Provider and marks the selection',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelPickerSheet(
              options: options,
              selectedModel: deepSeekReasoner,
            ),
          ),
        ),
      );

      expect(find.text('DeepSeek'), findsOneWidget);
      expect(find.text('ToAPIs'), findsOneWidget);
      expect(find.text('DeepSeek Chat'), findsOneWidget);
      expect(find.text('deepseek-chat'), findsOneWidget);
      expect(find.text('Reasoning Model'), findsOneWidget);
      expect(find.text('deepseek-reasoner'), findsOneWidget);
      expect(find.text('Fast Selected Model'), findsOneWidget);
      expect(find.text('selected-model-id'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('selected-model-deepseek-deepseek-reasoner')),
        findsOneWidget,
      );
    },
  );

  testWidgets('search filters by display name and exact model ID', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ModelPickerSheet(options: options)),
      ),
    );

    await tester.enterText(find.byType(TextField), 'reasoning');
    await tester.pump();
    expect(find.text('Reasoning Model'), findsOneWidget);
    expect(find.text('DeepSeek Chat'), findsNothing);
    expect(find.text('Fast Selected Model'), findsNothing);

    await tester.enterText(find.byType(TextField), 'selected-model-id');
    await tester.pump();
    expect(find.text('Fast Selected Model'), findsOneWidget);
    expect(find.text('Reasoning Model'), findsNothing);
  });

  testWidgets('providers with the same display name remain separate groups', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelPickerSheet(
            options: [
              AvailableModelOption(
                ref: ModelRef(providerId: 'provider-a', modelId: 'model-a'),
                providerName: 'Custom',
                modelName: 'Model A',
              ),
              AvailableModelOption(
                ref: ModelRef(providerId: 'provider-b', modelId: 'model-b'),
                providerName: 'Custom',
                modelName: 'Model B',
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Custom'), findsNWidgets(2));
    expect(find.text('Model A'), findsOneWidget);
    expect(find.text('Model B'), findsOneWidget);
  });

  testWidgets('choosing a model updates the default text model row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final persistence = _Persistence(
      options: options,
      globalDefault: deepSeekChat,
    );
    final controller = ModelRoutingController(
      persistence: persistence,
      runtime: _Reloader(),
    );

    await tester.pumpWidget(
      MaterialApp(home: ModelProvidersPage(routingController: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('DeepSeek / deepseek-chat'), findsOneWidget);

    await tester.tap(find.text('默认文字模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fast Selected Model'));
    await tester.pumpAndSettle();

    expect(find.text('ToAPIs / selected-model-id'), findsOneWidget);
    expect(persistence.globalWrites, [toApisSelected]);
  });
}

final class _Persistence
    implements ModelRoutingPersistence, ModelRoutingRollbackPersistence {
  _Persistence({required this.options, required this.globalDefault});

  final List<AvailableModelOption> options;
  ModelRef? globalDefault;
  final List<ModelRef> globalWrites = [];

  @override
  Future<List<AvailableModelOption>> loadAvailableModels() async => options;

  @override
  Future<ModelRef?> loadGlobalDefault() async => globalDefault;

  @override
  Future<void> setGlobalDefault(ModelRef model) async {
    globalDefault = model;
    globalWrites.add(model);
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
