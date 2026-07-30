import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/provider_detail_page.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

void main() {
  testWidgets('does not expose a manually editable default model ID', (
    tester,
  ) async {
    await _pumpPage(tester);

    expect(find.text('默认模型 ID'), findsNothing);
  });

  testWidgets('saving explains that the Key is being validated by discovery', (
    tester,
  ) async {
    final fetcher = _CatalogFetcher()..gate = Completer<void>();
    final controller = _controller(fetcher: fetcher);
    await _pumpPage(tester, controller: controller);
    await tester.enterText(_apiKeyFinder(), 'transient-secret');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, '保存到本机'));
    await tester.pump();

    try {
      expect(find.text('正在验证并获取模型…'), findsOneWidget);
    } finally {
      fetcher.gate!.complete();
      await tester.pump();
      await tester.pump();
    }
  });

  testWidgets(
    'configured page displays persisted catalog count and timestamp',
    (tester) async {
      final persistence = _Persistence()
        ..current = _snapshot(_ref(1), DateTime.utc(2026, 7, 29, 12, 34));
      final controller = _controller(persistence: persistence);

      await _pumpPage(tester, controller: controller);

      expect(find.text('已获取 2 个模型'), findsOneWidget);
      expect(find.textContaining('2026-07-29 12:34'), findsOneWidget);
      expect(find.textContaining('模型目录暂不可用'), findsNothing);
    },
  );

  testWidgets('catalog refresh is enabled only after configuration', (
    tester,
  ) async {
    final persistence = _Persistence();
    final controller = _controller(persistence: persistence);
    await _pumpPage(tester, controller: controller);

    expect(_refreshButton(tester).onPressed, isNull);

    persistence.current = _snapshot(_ref(2), DateTime.utc(2026, 7, 29, 12));
    await controller.load('toapis');
    await tester.pump();

    expect(_refreshButton(tester).onPressed, isNotNull);
  });

  testWidgets('power button toggles the provider without touching the key', (
    tester,
  ) async {
    final persistence = _Persistence()
      ..current = _snapshot(_ref(3), DateTime.utc(2026, 7, 29, 12));
    final controller = _controller(persistence: persistence);
    await _pumpPage(tester, controller: controller);

    expect(find.widgetWithText(OutlinedButton, '停用此服务'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '停用此服务'));
    await tester.pumpAndSettle();

    expect(persistence.current!.config.enabled, isFalse);
    expect(persistence.current!.config.secretRef, _ref(3));
    expect(find.widgetWithText(OutlinedButton, '启用此服务'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '启用此服务'));
    await tester.pumpAndSettle();

    expect(persistence.current!.config.enabled, isTrue);
    expect(find.text('已启用'), findsOneWidget);
  });

  testWidgets('power button stays disabled before configuration', (
    tester,
  ) async {
    final controller = _controller(persistence: _Persistence());
    await _pumpPage(tester, controller: controller);

    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '启用此服务'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'successful save clears the API Key and never renders its value',
    (tester) async {
      final credentials = _Credentials();
      final controller = _controller(credentials: credentials);
      await _pumpPage(tester, controller: controller);
      const secret = 'must-never-render';
      await tester.enterText(_apiKeyFinder(), secret);
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, '保存到本机'));
      await tester.pump();
      await tester.pump();

      expect(credentials.values, [secret]);
      expect(
        tester.widget<TextField>(_apiKeyFinder()).controller?.text,
        isEmpty,
      );
      expect(find.text(secret), findsNothing);
    },
  );
}

Future<void> _pumpPage(
  WidgetTester tester, {
  ProviderSettingsController? controller,
}) async {
  tester.view.physicalSize = const Size(430, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: ProviderDetailPage(providerId: 'toapis', controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _apiKeyFinder() => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.obscureText,
);

OutlinedButton _refreshButton(WidgetTester tester) =>
    tester.widget(find.widgetWithText(OutlinedButton, '刷新模型目录'));

ProviderSettingsController _controller({
  _CatalogFetcher? fetcher,
  _Credentials? credentials,
  _Persistence? persistence,
}) => ProviderSettingsController(
  credentials: credentials ?? _Credentials(),
  catalogFetcher: fetcher ?? _CatalogFetcher(),
  persistence: persistence ?? _Persistence(),
  runtime: _Reloader(),
  secretRefs: _FixedRef(_ref(99)),
);

ProviderSettingsSnapshot _snapshot(SecretRef ref, DateTime discoveredAt) =>
    ProviderSettingsSnapshot(
      config: ProviderConfig.toApis(secretRef: ref),
      catalog: _catalog(discoveredAt),
    );

PersistedProviderModelCatalog _catalog([DateTime? discoveredAt]) =>
    PersistedProviderModelCatalog(
      providerId: 'toapis',
      models: [
        ModelDescriptor(
          ref: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
          displayName: 'GPT-5 mini',
          capabilities: const ModelCapabilities.text(),
        ),
        ModelDescriptor(
          ref: ModelRef(providerId: 'toapis', modelId: 'gpt-5'),
          displayName: 'GPT-5',
          capabilities: const ModelCapabilities.text(),
        ),
      ],
      discoveredAt: discoveredAt ?? DateTime.utc(2026, 7, 29, 12),
    );

SecretRef _ref(int value) => SecretRef.parse(
  'keychain://halo.provider/00000000-0000-4000-8000-'
  '${value.toString().padLeft(12, '0')}',
);

final class _FixedRef implements ProviderSecretRefFactory {
  const _FixedRef(this.ref);

  final SecretRef ref;

  @override
  SecretRef next() => ref;
}

final class _CatalogFetcher implements ProviderModelCatalogFetcher {
  Completer<void>? gate;

  @override
  Future<PersistedProviderModelCatalog> fetch(ProviderConfig config) async {
    await gate?.future;
    return _catalog();
  }
}

final class _Credentials implements SecureCredentialStore {
  final values = <String>[];

  @override
  Future<bool> delete(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async => true;

  @override
  Future<String?> get(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async => null;

  @override
  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  }) async => const [];

  @override
  Future<void> set(
    SecretRef ref,
    String secret, {
    CancellationToken? cancellationToken,
  }) async {
    values.add(secret);
  }
}

final class _Persistence implements ProviderSettingsPersistence {
  ProviderSettingsSnapshot? current;

  @override
  Future<ProviderSettingsSnapshot?> load(String providerId) async => current;

  @override
  Future<void> replace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {
    current = next;
  }

  @override
  Future<void> rollbackReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {
    current = previous;
  }

  @override
  Future<void> finalizeReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {}

  @override
  Future<void> markReplaceRuntimePublished(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {}

  @override
  Future<void> remove(ProviderSettingsSnapshot snapshot) async {
    current = null;
  }

  @override
  Future<void> restore(ProviderSettingsSnapshot snapshot) async {
    current = snapshot;
  }

  @override
  Future<void> markRemovalRuntimePublished(
    ProviderSettingsSnapshot snapshot,
  ) async {}

  @override
  Future<void> finalizeRemoval(ProviderSettingsSnapshot snapshot) async {}
}

final class _Reloader implements ProviderRuntimeReloader {
  @override
  Future<void> reload() async {}
}
