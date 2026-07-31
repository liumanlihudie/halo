import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Whatever saves a credential must be what reads it back.
///
/// A merge once restored an older line here: keys were saved through the
/// fallback store and read straight from the Keychain, so a key that saved
/// fine was invisible to calls and voice messages. Nothing in the app can
/// catch that, because both halves are individually correct.
void main() {
  test('the kernel resolves secrets through the store it writes with', () {
    final source = File(
      'lib/app/production_app_kernel.dart',
    ).readAsStringSync();

    final resolvers = RegExp(
      r'KeychainSecretResolver\(store: (\w+)\)',
    ).allMatches(source).map((match) => match.group(1)).toList();

    expect(resolvers, isNotEmpty);
    // Speech is the one that consumes service credentials; it must not reach
    // past the fallback store to the raw platform store.
    final speechSection = source.substring(
      source.indexOf('ProductionSingleChatSpeech('),
    );
    expect(
      speechSection.substring(0, 400),
      contains('KeychainSecretResolver(store: credentialStore)'),
      reason: 'speech must resolve through the same store keys are saved with',
    );
  });
}
