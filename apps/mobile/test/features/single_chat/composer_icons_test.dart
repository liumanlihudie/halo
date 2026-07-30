import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';

/// Every prototype icon class named in the app must exist.
///
/// A missing one is not a cosmetic bug: `requirePrototypeClass` throws, and
/// Flutter renders the whole surrounding bubble as a full-screen grey error
/// box. That is exactly how the first voice message shipped.
void main() {
  test('every icon class used in lib resolves', () {
    final pattern = RegExp(r"'ph ph-[a-z0-9-]+'");
    final missing = <String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.contains('halo_icons.dart')) continue;
      for (final match in pattern.allMatches(entity.readAsStringSync())) {
        final iconClass = match.group(0)!.replaceAll("'", '');
        try {
          HaloIcon.requirePrototypeClass(iconClass);
        } catch (_) {
          missing.add('$iconClass (${entity.path})');
        }
      }
    }
    expect(missing, isEmpty, reason: missing.join('\n'));
  });
}
