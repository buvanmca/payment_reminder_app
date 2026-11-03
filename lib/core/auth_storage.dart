import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthStorage {
  static const _storage = FlutterSecureStorage();
  static const _kToken = 'jwt_token';
  static const _kEmail = 'user_email';
  static const _kName = 'user_name';
  static const _kOrgId = 'org_id';

  Future<void> save(String token, String email, String orgId, {String? name}) async {
    await _storage.write(key: _kToken, value: token);
    await _storage.write(key: _kEmail, value: email);
    await _storage.write(key: _kOrgId, value: orgId);
    if (name != null && name.isNotEmpty) {
      await _storage.write(key: _kName, value: name);
    } else {
      await _storage.delete(key: _kName);
    }
  }

  Future<String?> readToken() => _storage.read(key: _kToken);
  Future<String?> readEmail() => _storage.read(key: _kEmail);
  Future<String?> readName() => _storage.read(key: _kName);
  Future<String?> readOrgId() => _storage.read(key: _kOrgId);

  Future<void> clear() async {
    await _storage.delete(key: _kToken);
    await _storage.delete(key: _kEmail);
    await _storage.delete(key: _kName);
    await _storage.delete(key: _kOrgId);
  }
}
