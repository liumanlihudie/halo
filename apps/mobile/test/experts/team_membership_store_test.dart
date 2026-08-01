import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/experts/team_membership_store.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('team-membership-');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  File file() => File('${directory.path}/removed-experts.json');

  test('removal survives a restart and restore undoes it', () async {
    final store = TeamMembershipStore(file: file());
    await store.ensureLoaded();
    expect(store.isRemoved('product'), isFalse);

    await store.remove('product');
    expect(store.isRemoved('product'), isTrue);

    final reopened = TeamMembershipStore(file: file());
    await reopened.ensureLoaded();
    expect(reopened.isRemoved('product'), isTrue);

    await reopened.restore('product');
    expect(reopened.isRemoved('product'), isFalse);

    final again = TeamMembershipStore(file: file());
    await again.ensureLoaded();
    expect(again.isRemoved('product'), isFalse);
  });

  test('a corrupt choice file hides nobody', () async {
    await file().writeAsString('{broken');
    final store = TeamMembershipStore(file: file());
    await store.ensureLoaded();
    expect(store.isRemoved('product'), isFalse);
  });
}
