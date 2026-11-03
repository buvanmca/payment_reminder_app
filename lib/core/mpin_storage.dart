import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the device-local MPIN bits in flutter_secure_storage (Keystore /
/// Keychain). The MPIN never leaves the device; the backend has no concept of
/// it. Brute-force resistance for a 4-digit PIN comes from the OS-encrypted
/// storage layer plus the attempt-lockout policy enforced in MpinController,
/// not from the hash function — so a salted SHA-256 is sufficient and avoids
/// pulling in a heavier KDF dependency.
class MpinStorage {
  static const _storage = FlutterSecureStorage();
  static const _kHash = 'mpin_hash';
  static const _kSalt = 'mpin_salt';
  static const _kOrgId = 'mpin_org_id';
  static const _kAttempts = 'mpin_attempts';
  static const _kLockUntil = 'mpin_lock_until';

  Future<bool> isSet() async {
    final h = await _storage.read(key: _kHash);
    return h != null && h.isNotEmpty;
  }

  Future<String?> readOrgId() => _storage.read(key: _kOrgId);

  Future<int> readAttempts() async {
    final v = await _storage.read(key: _kAttempts);
    return int.tryParse(v ?? '') ?? 0;
  }

  Future<void> writeAttempts(int n) =>
      _storage.write(key: _kAttempts, value: n.toString());

  Future<DateTime?> readLockUntil() async {
    final v = await _storage.read(key: _kLockUntil);
    if (v == null || v.isEmpty) return null;
    return DateTime.tryParse(v);
  }

  Future<void> writeLockUntil(DateTime? until) async {
    if (until == null) {
      await _storage.delete(key: _kLockUntil);
    } else {
      await _storage.write(key: _kLockUntil, value: until.toIso8601String());
    }
  }

  /// Stores the salted hash and binds it to [orgId] so a different user
  /// logging in on the same device is forced through MPIN setup again.
  Future<void> save(String pin, {required String orgId}) async {
    final salt = _generateSalt();
    final hash = _hash(pin, salt);
    await _storage.write(key: _kSalt, value: salt);
    await _storage.write(key: _kHash, value: hash);
    await _storage.write(key: _kOrgId, value: orgId);
    await _storage.delete(key: _kAttempts);
    await _storage.delete(key: _kLockUntil);
  }

  /// Constant-time(-ish) comparison of the candidate hash against the stored
  /// one. The pin is hashed under the same salt before compare.
  Future<bool> verify(String pin) async {
    final salt = await _storage.read(key: _kSalt);
    final stored = await _storage.read(key: _kHash);
    if (salt == null || stored == null) return false;
    final candidate = _hash(pin, salt);
    if (candidate.length != stored.length) return false;
    var diff = 0;
    for (var i = 0; i < candidate.length; i++) {
      diff |= candidate.codeUnitAt(i) ^ stored.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> clear() async {
    await _storage.delete(key: _kHash);
    await _storage.delete(key: _kSalt);
    await _storage.delete(key: _kOrgId);
    await _storage.delete(key: _kAttempts);
    await _storage.delete(key: _kLockUntil);
  }

  String _generateSalt() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return base64Url.encode(bytes);
  }

  String _hash(String pin, String salt) {
    final bytes = utf8.encode('$salt:$pin');
    return sha256.convert(bytes).toString();
  }
}
