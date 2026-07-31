// Drives the generation service directly with a prompt — no model, no chat —
// so a failure names the exact step: submit, poll, or download. The key is
// resolved by the app's own Keychain code inside the sandbox and never leaves
// it; only milestones and safe failure text are printed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/generation_tools.dart';
import 'package:halo_mobile/app/generation_transport.dart';
import 'package:halo_mobile/model_runtime/model_purpose.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/sqlite_provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/unary_http_transport.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the image pipeline generates without a chat model', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final store = SqliteProviderConfigurationStore.open(
      '${support.path}${Platform.pathSeparator}halo_providers.sqlite',
    );
    addTearDown(store.close);

    final binding = await store.loadPurposeModel(ModelPurpose.image);
    // ignore: avoid_print
    print('PROBE image binding: ${binding ?? '未设置'}');
    if (binding == null) return;

    final service = ProductionGenerationService(
      store: store,
      bindings: store,
      secretResolver: KeychainSecretResolver(
        store: const MethodChannelSecureCredentialStore(),
      ),
      transport: GenerationTransport(
        endpointPolicy: TrustedProviderEndpointPolicy(
          providerHosts: const {
            'api.deepseek.com',
            'api.moonshot.cn',
            'toapis.com',
          },
        ),
      ),
      outputDirectory: Directory(
        '${support.path}${Platform.pathSeparator}generated',
      ),
    );

    try {
      final asset = await service.generateImage(
        '一只戴帽子的橘猫，简笔画',
        onSubmitted: () {
          // ignore: avoid_print
          print('PROBE task accepted, polling…');
        },
      );
      final size = await File(asset.localPath).length();
      // ignore: avoid_print
      print('PROBE success: ${asset.localPath} ($size bytes)');
    } on GenerationUnavailable catch (error) {
      // ignore: avoid_print
      print('PROBE failed: ${error.safeMessage}');
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
