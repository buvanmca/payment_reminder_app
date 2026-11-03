import 'package:sqflite_sqlcipher/sqflite.dart';

import 'local_db.dart';

class CachedLicense {
  CachedLicense({
    required this.licenseKey,
    required this.deviceId,
    required this.status,
    required this.validUntil,
    required this.lastValidatedAt,
  });

  final String licenseKey;
  final String deviceId;
  final String status;
  final DateTime validUntil;
  final DateTime lastValidatedAt;

  bool get isActive =>
      status.toLowerCase() == 'active' && validUntil.isAfter(DateTime.now());

  Map<String, Object?> toRow() => {
        'id': 1,
        'license_key': licenseKey,
        'device_id': deviceId,
        'status': status,
        'valid_until': validUntil.toIso8601String(),
        'last_validated_at': lastValidatedAt.toIso8601String(),
      };

  static CachedLicense fromRow(Map<String, Object?> r) => CachedLicense(
        licenseKey: r['license_key'] as String,
        deviceId: r['device_id'] as String,
        status: r['status'] as String,
        validUntil: DateTime.parse(r['valid_until'] as String),
        lastValidatedAt: DateTime.parse(r['last_validated_at'] as String),
      );
}

class LicenseCacheDao {
  Future<Database> _db() => LocalDb.instance.open();

  Future<CachedLicense?> read() async {
    final db = await _db();
    final rows = await db.query('license_cache', where: 'id = 1', limit: 1);
    return rows.isEmpty ? null : CachedLicense.fromRow(rows.first);
  }

  Future<void> save(CachedLicense lic) async {
    final db = await _db();
    await db.insert('license_cache', lic.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clear() async {
    final db = await _db();
    await db.delete('license_cache');
  }
}