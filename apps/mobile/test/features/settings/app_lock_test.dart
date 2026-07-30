import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/app_lock.dart';
import 'package:halo_mobile/features/settings/app_lock_gate.dart';

void main() {
  AppLockController build({
    bool storedEnabled = false,
    bool authPasses = true,
    AppLockAvailability availability = AppLockAvailability.available,
    _FakeAuthenticator? authenticator,
    _FakePreferences? preferences,
  }) {
    return AppLockController(
      authenticator:
          authenticator ??
          _FakeAuthenticator(
            passes: authPasses,
            stubAvailability: availability,
          ),
      preferences: preferences ?? _FakePreferences(enabled: storedEnabled),
    );
  }

  test('a cold start with the lock on is already locked', () async {
    final controller = build(storedEnabled: true);

    await controller.load();

    expect(controller.enabled, isTrue);
    // The very first frame must be covered; unlocking only after a prompt
    // would flash the conversation list.
    expect(controller.locked, isTrue);
  });

  test('a cold start with the lock off is never locked', () async {
    final controller = build();

    await controller.load();

    expect(controller.enabled, isFalse);
    expect(controller.locked, isFalse);
  });

  test('turning the lock on requires passing authentication', () async {
    final preferences = _FakePreferences();
    final controller = build(authPasses: false, preferences: preferences);
    await controller.load();

    final changed = await controller.setEnabled(true);

    expect(changed, isFalse);
    expect(controller.enabled, isFalse);
    // A failed attempt must not persist anything.
    expect(preferences.writes, isEmpty);
  });

  test('turning the lock off also requires authentication', () async {
    final authenticator = _FakeAuthenticator(passes: true);
    final preferences = _FakePreferences(enabled: true);
    final controller = build(
      authenticator: authenticator,
      preferences: preferences,
    );
    await controller.load();

    authenticator.passes = false;
    expect(await controller.setEnabled(false), isFalse);
    expect(controller.enabled, isTrue);

    authenticator.passes = true;
    expect(await controller.setEnabled(false), isTrue);
    expect(controller.enabled, isFalse);
    expect(controller.locked, isFalse);
    expect(preferences.writes, [false]);
  });

  test(
    'an unavailable sensor cannot arm a lock the user cannot open',
    () async {
      final controller = build(availability: AppLockAvailability.unavailable);
      await controller.load();

      expect(await controller.setEnabled(true), isFalse);
      expect(controller.enabled, isFalse);
    },
  );

  test('a thrown availability check degrades to unknown', () async {
    final controller = build(
      authenticator: _FakeAuthenticator(throwOnAvailability: true),
    );

    await controller.load();

    expect(controller.availability, AppLockAvailability.unknown);
    expect(await controller.setEnabled(true), isFalse);
  });

  test('a thrown prompt is a failure, never an unlock', () async {
    final controller = build(
      storedEnabled: true,
      authenticator: _FakeAuthenticator(throwOnAuthenticate: true),
    );
    await controller.load();

    expect(await controller.unlock(), isFalse);
    expect(controller.locked, isTrue);
  });

  test('unlocking clears the lock only on success', () async {
    final authenticator = _FakeAuthenticator(passes: false);
    final controller = build(storedEnabled: true, authenticator: authenticator);
    await controller.load();

    expect(await controller.unlock(), isFalse);
    expect(controller.locked, isTrue);

    authenticator.passes = true;
    expect(await controller.unlock(), isTrue);
    expect(controller.locked, isFalse);
  });

  test('backgrounding re-arms the lock only while enabled', () async {
    final off = build();
    await off.load();
    off.lockIfEnabled();
    expect(off.locked, isFalse);

    final on = build(storedEnabled: true);
    await on.load();
    await on.unlock();
    expect(on.locked, isFalse);
    on.lockIfEnabled();
    expect(on.locked, isTrue);
  });

  test('a corrupt preference file never locks the user out', () async {
    final directory = Directory.systemTemp.createTempSync('halo-app-lock');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/app-lock.json')
      ..writeAsStringSync('{not json');

    expect(await FileAppLockPreferences(file).loadEnabled(), isFalse);
  });

  test('the preference round-trips through the file', () async {
    final directory = Directory.systemTemp.createTempSync('halo-app-lock');
    addTearDown(() => directory.deleteSync(recursive: true));
    final preferences = FileAppLockPreferences(
      File('${directory.path}/nested/app-lock.json'),
    );

    expect(await preferences.loadEnabled(), isFalse);
    await preferences.saveEnabled(true);
    expect(await preferences.loadEnabled(), isTrue);
    await preferences.saveEnabled(false);
    expect(await preferences.loadEnabled(), isFalse);
  });

  testWidgets('the gate covers the app while locked', (tester) async {
    final controller = build(storedEnabled: true);
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        home: AppLockGate(controller: controller, child: const Text('会话列表')),
      ),
    );
    await tester.pump();

    expect(find.text('Halo 已锁定'), findsOneWidget);
    expect(find.text('解锁'), findsOneWidget);

    await tester.tap(find.text('解锁'));
    await tester.pumpAndSettle();

    expect(find.text('Halo 已锁定'), findsNothing);
    // The child stayed mounted underneath, so navigation state survives.
    expect(find.text('会话列表'), findsOneWidget);
  });

  testWidgets('no controller means the gate never covers anything', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: AppLockGate(child: Text('会话列表'))),
    );
    await tester.pump();

    expect(find.text('Halo 已锁定'), findsNothing);
    expect(find.text('会话列表'), findsOneWidget);
  });
}

class _FakeAuthenticator implements AppLockAuthenticator {
  _FakeAuthenticator({
    this.passes = true,
    this.stubAvailability = AppLockAvailability.available,
    this.throwOnAvailability = false,
    this.throwOnAuthenticate = false,
  });

  bool passes;
  final AppLockAvailability stubAvailability;
  final bool throwOnAvailability;
  final bool throwOnAuthenticate;
  final reasons = <String>[];

  @override
  Future<AppLockAvailability> availability() async {
    if (throwOnAvailability) throw StateError('platform failure');
    return stubAvailability;
  }

  @override
  Future<bool> authenticate(String reason) async {
    if (throwOnAuthenticate) throw StateError('platform failure');
    reasons.add(reason);
    return passes;
  }
}

class _FakePreferences implements AppLockPreferences {
  _FakePreferences({this.enabled = false});

  bool enabled;
  final writes = <bool>[];

  @override
  Future<bool> loadEnabled() async => enabled;

  @override
  Future<void> saveEnabled(bool value) async {
    enabled = value;
    writes.add(value);
  }
}
