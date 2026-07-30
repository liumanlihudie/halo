import 'package:halo_mobile/model_runtime/secret_ref.dart';

class FakeSecretResolver implements SecretResolver {
  final Map<SecretRef, EphemeralCredential> _credentials = {};

  void put(SecretRef ref, EphemeralCredential credential) {
    _credentials[ref] = credential;
  }

  @override
  Future<EphemeralCredential?> resolve(SecretRef ref) async =>
      _credentials[ref];
}
