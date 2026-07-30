import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Why the device cannot offer an app lock.
enum AppLockAvailability {
  /// Face ID / Touch ID / passcode is usable right now.
  available,

  /// The device has no enrolled biometric and no passcode.
  unavailable,

  /// The platform could not be asked (simulator, plugin missing, error).
  unknown,
}

/// Wraps the platform biometric prompt.
///
/// Kept behind an interface so the lock logic is testable without the
/// `local_auth` plugin and its platform channel.
abstract interface class AppLockAuthenticator {
  Future<AppLockAvailability> availability();

  /// Returns true only on a confirmed successful authentication. Any error is
  /// a failure: the gate must fail closed.
  Future<bool> authenticate(String reason);
}

/// Durable on/off state for the lock.
abstract interface class AppLockPreferences {
  Future<bool> loadEnabled();
  Future<void> saveEnabled(bool enabled);
}

/// JSON-file preferences.
///
/// Deliberately not stored in the provider configuration database: that schema
/// carries credential bindings and every change to it needs a migration path
/// for installed apps, which a UI preference does not justify.
final class FileAppLockPreferences implements AppLockPreferences {
  FileAppLockPreferences(this._file);

  final File _file;

  @override
  Future<bool> loadEnabled() async {
    try {
      if (!_file.existsSync()) return false;
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is Map<String, Object?>) {
        return decoded['appLockEnabled'] == true;
      }
      return false;
    } catch (_) {
      // A corrupt preference file must not lock the user out of their app.
      return false;
    }
  }

  @override
  Future<void> saveEnabled(bool enabled) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({'appLockEnabled': enabled}),
      flush: true,
    );
  }
}

/// Owns whether the app is currently locked.
///
/// The lock gates *access to the UI*, not the data: on-device files stay
/// readable to anything that can already read the app sandbox, so the settings
/// copy says so rather than implying encryption.
class AppLockController extends ChangeNotifier {
  AppLockController({
    required AppLockAuthenticator authenticator,
    required AppLockPreferences preferences,
  }) : _authenticator = authenticator,
       _preferences = preferences;

  // ignore_for_file: prefer_initializing_formals

  static const String unlockReason = '解锁 Halo';
  static const String enableReason = '开启 Halo 的 Face ID 保护';

  final AppLockAuthenticator _authenticator;
  final AppLockPreferences _preferences;

  var _enabled = false;
  var _locked = false;
  var _availability = AppLockAvailability.unknown;
  var _authenticating = false;
  var _loaded = false;

  bool get enabled => _enabled;

  /// True while the lock screen must cover the app.
  bool get locked => _locked;

  AppLockAvailability get availability => _availability;
  bool get authenticating => _authenticating;
  bool get loaded => _loaded;

  /// Reads the stored preference and the device capability.
  ///
  /// Starts locked when the preference is on, so the very first frame after a
  /// cold start is already covered.
  Future<void> load() async {
    _availability = await _safeAvailability();
    _enabled = await _preferences.loadEnabled();
    _locked = _enabled;
    _loaded = true;
    notifyListeners();
  }

  /// Turning the lock **on** requires passing authentication first, so a user
  /// whose sensor is broken cannot lock themselves out of their own app.
  /// Turning it **off** also requires it, so someone holding an unlocked phone
  /// cannot silently remove the protection.
  Future<bool> setEnabled(bool enabled) async {
    if (_authenticating || enabled == _enabled) return false;
    if (enabled && _availability != AppLockAvailability.available) {
      return false;
    }
    _authenticating = true;
    notifyListeners();
    try {
      final passed = await _authenticator.authenticate(
        enabled ? enableReason : unlockReason,
      );
      if (!passed) return false;
      await _preferences.saveEnabled(enabled);
      _enabled = enabled;
      if (!enabled) _locked = false;
      return true;
    } catch (_) {
      return false;
    } finally {
      _authenticating = false;
      notifyListeners();
    }
  }

  /// Called when the app returns to the foreground.
  void lockIfEnabled() {
    if (!_enabled || _locked) return;
    _locked = true;
    notifyListeners();
  }

  Future<bool> unlock() async {
    if (!_locked || _authenticating) return false;
    _authenticating = true;
    notifyListeners();
    try {
      final passed = await _authenticator.authenticate(unlockReason);
      if (passed) _locked = false;
      return passed;
    } catch (_) {
      return false;
    } finally {
      _authenticating = false;
      notifyListeners();
    }
  }

  Future<AppLockAvailability> _safeAvailability() async {
    try {
      return await _authenticator.availability();
    } catch (_) {
      return AppLockAvailability.unknown;
    }
  }
}
