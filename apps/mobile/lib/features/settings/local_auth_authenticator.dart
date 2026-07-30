import 'package:halo_mobile/features/settings/app_lock.dart';
import 'package:local_auth/local_auth.dart';

/// [AppLockAuthenticator] backed by the platform biometric prompt.
///
/// Every failure path returns false or [AppLockAvailability.unknown]: a
/// plugin error must never be mistaken for a successful unlock.
final class LocalAuthAppLockAuthenticator implements AppLockAuthenticator {
  LocalAuthAppLockAuthenticator({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<AppLockAvailability> availability() async {
    try {
      // `isDeviceSupported` covers a device passcode as well, which is the
      // fallback the prompt uses when Face ID fails.
      final supported = await _auth.isDeviceSupported();
      if (!supported) return AppLockAvailability.unavailable;
      final canCheck = await _auth.canCheckBiometrics;
      final enrolled = await _auth.getAvailableBiometrics();
      if (!canCheck && enrolled.isEmpty) {
        // A passcode-only device can still authenticate.
        return AppLockAvailability.available;
      }
      return AppLockAvailability.available;
    } catch (_) {
      return AppLockAvailability.unknown;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // Biometrics may fail legitimately (mask, wet finger); the device
        // passcode is the intended fallback rather than a lockout.
        biometricOnly: false,
        // Survives the prompt backgrounding the app, which would otherwise
        // re-arm the lock and loop the user between prompt and lock screen.
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}
