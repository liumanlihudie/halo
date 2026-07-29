import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/model_providers_page.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';

void main() {
  testWidgets(
    'renders persisted supported state and disables every unsupported provider',
    (tester) async {
      final persistence = _Persistence()
        ..values['toapis'] = ProviderSettingsSnapshot(
          config: ProviderConfig.toApis(
            secretRef: SecretRef.parse(
              'keychain://halo.provider/00000000-0000-4000-8000-000000000001',
            ),
          ),
          model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
        );
      final controller = ProviderSettingsController(
        credentials: _Credentials(),
        persistence: persistence,
        runtime: _Reloader(),
      );

      await tester.pumpWidget(
        MaterialApp(home: ModelProvidersPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.text('已配置'), findsOneWidget);
      expect(find.text('后续支持'), findsWidgets);
      expect(
        ModelProvidersPage.providers.where((provider) => !provider.$4),
        hasLength(7),
      );
      await tester.scrollUntilVisible(find.text('Anthropic Claude'), 200);
      final unsupportedInk = tester.widget<InkWell>(
        find.ancestor(
          of: find.text('Anthropic Claude'),
          matching: find.byType(InkWell),
        ),
      );
      expect(unsupportedInk.onTap, isNull);
    },
  );
}

final class _Persistence implements ProviderSettingsPersistence {
  final values = <String, ProviderSettingsSnapshot?>{};

  @override
  Future<ProviderSettingsSnapshot?> load(String providerId) async =>
      values[providerId];

  @override
  Future<void> replace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {
    values[next.config.providerId] = next;
  }

  @override
  Future<void> rollbackReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {
    values[next.config.providerId] = previous;
  }

  @override
  Future<void> finalizeReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {}

  @override
  Future<void> remove(ProviderSettingsSnapshot snapshot) async {
    values[snapshot.config.providerId] = null;
  }

  @override
  Future<void> restore(ProviderSettingsSnapshot snapshot) async {
    values[snapshot.config.providerId] = snapshot;
  }

  @override
  Future<void> finalizeRemoval(ProviderSettingsSnapshot snapshot) async {}
}

final class _Credentials implements SecureCredentialStore {
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
  }) async {}
}

final class _Reloader implements ProviderRuntimeReloader {
  @override
  Future<void> reload() async {}
}
