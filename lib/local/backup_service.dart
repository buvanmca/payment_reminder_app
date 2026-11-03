import 'dart:convert';

import 'package:sqflite_sqlcipher/sqflite.dart';

import 'local_db.dart';

/// Exports and restores the user-owned tables of the local DB to a portable
/// JSON document. Designed for the Settings screen "Backup" / "Restore"
/// flows: a user who suspects data loss can re-import their last backup and
/// land back in the state they were in.
///
/// What's included:
///   - plans, customers, subscriptions, payments, reminder_history
///
/// What's deliberately excluded:
///   - pending_reminders — transient queue, restoring would re-fire sends
///   - license_cache — device-specific, validated against the server
///   - app_meta — per-install bookkeeping (org owner, etc.)
class BackupService {
  BackupService();

  /// Schema marker so future format changes can be detected on import.
  static const String schema = 'paybell-backup-v1';

  /// Tables that get exported and restored, in FK-safe insert order
  /// (parents first). Same list is used for both directions.
  static const List<String> _tables = [
    'plans',
    'customers',
    'subscriptions',
    'payments',
    'reminder_history',
  ];

  Future<Database> _db() => LocalDb.instance.open();

  /// Reads every row from the user-owned tables and returns a JSON document
  /// suitable for writing to disk and sharing.
  Future<String> exportToJson() async {
    final db = await _db();
    final data = <String, List<Map<String, Object?>>>{};
    for (final t in _tables) {
      final rows = await db.query(t);
      data[t] = rows.map((r) => Map<String, Object?>.from(r)).toList();
    }
    final payload = <String, Object?>{
      'schema': schema,
      'dbVersion': 6,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'data': data,
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Counts the rows in a parsed backup payload without touching the DB.
  /// Drives the restore confirmation dialog so the user sees what they're
  /// about to overwrite.
  static Map<String, int> countsFromPayload(Map<String, Object?> payload) {
    final out = <String, int>{};
    final data = payload['data'];
    if (data is Map<String, Object?>) {
      for (final t in _tables) {
        final rows = data[t];
        out[t] = rows is List ? rows.length : 0;
      }
    }
    return out;
  }

  /// Validates a parsed backup payload, throwing on anything we can't safely
  /// import. Run this BEFORE wiping the existing data so a bad file never
  /// destroys the user's current state.
  static Map<String, Object?> parseAndValidate(String jsonText) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      throw BackupException('Backup file is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const BackupException('Backup root must be a JSON object');
    }
    final foundSchema = decoded['schema'];
    if (foundSchema != schema) {
      throw BackupException(
        'Unsupported backup format "$foundSchema" — expected "$schema"',
      );
    }
    final data = decoded['data'];
    if (data is! Map<String, Object?>) {
      throw const BackupException('Backup is missing the "data" section');
    }
    for (final t in _tables) {
      final rows = data[t];
      if (rows != null && rows is! List) {
        throw BackupException('Section "$t" must be a list');
      }
    }
    return decoded;
  }

  /// Wipes the user-owned tables (in child → parent order to satisfy FK) and
  /// bulk-inserts the rows from [payload]. Wraps everything in a single
  /// transaction so a partial failure leaves the DB unchanged.
  ///
  /// The caller is responsible for warning the user that this is destructive
  /// — by the time we reach here, consent is assumed.
  Future<RestoreResult> restoreFromPayload(Map<String, Object?> payload) async {
    final data = payload['data'] as Map<String, Object?>;
    final db = await _db();
    final inserted = <String, int>{for (final t in _tables) t: 0};

    await db.transaction((txn) async {
      // Delete children before parents to keep FK happy regardless of
      // PRAGMA foreign_keys state.
      await txn.delete('payments');
      await txn.delete('reminder_history');
      await txn.delete('subscriptions');
      await txn.delete('customers');
      // plan_id on subscriptions is a soft reference (no FK), so plans can be
      // cleared in any order relative to the rows above.
      await txn.delete('plans');

      for (final t in _tables) {
        final rows = (data[t] as List?) ?? const [];
        for (final raw in rows) {
          if (raw is! Map<String, Object?>) {
            throw BackupException('Section "$t" contains a non-object row');
          }
          await txn.insert(
            t,
            Map<String, Object?>.from(raw),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          inserted[t] = (inserted[t] ?? 0) + 1;
        }
      }
    });

    return RestoreResult(inserted: inserted);
  }
}

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => 'BackupException: $message';
}

class RestoreResult {
  RestoreResult({required this.inserted});
  final Map<String, int> inserted;
  int get total => inserted.values.fold(0, (a, b) => a + b);
}
