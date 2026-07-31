// Answers one question after the container wipe: did the pasted keys survive
// in the device keychain? Reads METADATA ONLY — counts and timestamps. No key
// material, and no locators either: locators stay out of logs by policy.
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('count surviving provider credentials', (tester) async {
    const store = MethodChannelSecureCredentialStore();
    final rows = await store.listMetadata(service: 'halo.provider');
    // ignore: avoid_print
    print('PROBE surviving credentials: ${rows.length}');
    for (final row in rows) {
      // ignore: avoid_print
      print('PROBE   created=${row.createdAt} updated=${row.updatedAt}');
    }
  });
}
