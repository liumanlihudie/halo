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
      // `isDeviceSupported` is true when either biometry is enrolled or a
      // device passcode is set, which is exactly the set of devices that can
      // satisfy the prompt. Checking `canCheckBiometrics` on top of it would
      // wrongly reject a passcode-only device that can still authenticate.
      final supported = await _auth.isDeviceSupported();
      return supported
          ? AppLockAvailability.available
          : AppLockAvailability.unavailable;
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
