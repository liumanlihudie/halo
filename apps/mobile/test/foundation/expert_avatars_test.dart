import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/foundation/design_system/expert_avatars.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';
import 'package:halo_mobile/mock/fixtures/halo_fixtures.dart';

void main() {
  test('every expert identity resolves to a bundled badge file', () {
    // Alias table completeness: profile, conversation and canonical ids must
    // all land on the same designed badge, and the file must really exist —
    // a broken mapping would silently fall back to a letter.
    for (final identity in ExecutableExpertRegistry.installedExpertIdentities) {
      for (final id in [
        identity.profileId,
        identity.conversationId,
        identity.canonicalExpertId,
      ]) {
        final asset = ExpertAvatars.assetFor(id);
        expect(asset, isNotNull, reason: '$id 没有徽章映射');
        expect(
          File(asset!).existsSync(),
          isTrue,
          reason: '$id 的徽章文件缺失: $asset',
        );
      }
    }
  });

  test('every fixture expert and market entry has its badge file', () {
    for (final expert in HaloFixtures.installedExperts) {
      final asset = ExpertAvatars.assetFor(expert.id);
      expect(asset, isNotNull, reason: '${expert.id} 没有徽章映射');
      expect(File(asset!).existsSync(), isTrue, reason: asset);
    }
    for (final expert in HaloFixtures.marketExperts) {
      final asset = ExpertAvatars.assetFor(expert.id);
      expect(asset, isNotNull, reason: '${expert.id} 没有徽章映射');
      expect(File(asset!).existsSync(), isTrue, reason: asset);
    }
  });

  test('unknown ids fall back to null instead of a broken asset', () {
    expect(ExpertAvatars.assetFor('nobody'), isNull);
    expect(ExpertAvatars.assetFor(''), isNull);
    expect(ExpertAvatars.assetFor(null), isNull);
  });

  testWidgets('the avatar renders the svg badge when one resolves', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HaloAvatar(
          svgAsset: ExpertAvatars.assetFor('product'),
          letter: '产',
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SvgPicture), findsOneWidget);
  });
}
