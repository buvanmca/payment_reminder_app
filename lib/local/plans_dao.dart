import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'local_db.dart';

/// A reusable plan template in the catalog. Subscriptions are created against a
/// Plan; selecting one auto-fills the subscription's amount and frequency.
class LocalPlan {
  LocalPlan({
    required this.id,
    required this.name,
    required this.amount,
    required this.frequency,
    this.isActive = true,
    required this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final double amount;

  /// 1=Monthly, 2=Quarterly, 3=Half Yearly, 4=Yearly. Mirrors the frequency
  /// codes used by [LocalSubscription].
  final int frequency;
  final bool isActive;
  final DateTime createdAt;
  final DateTime? updatedAt;

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'amount': amount,
        'frequency': frequency,
        'is_active': isActive ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      };

  static LocalPlan fromRow(Map<String, Object?> r) => LocalPlan(
        id: r['id'] as String,
        name: r['name'] as String,
        amount: (r['amount'] as num).toDouble(),
        frequency: (r['frequency'] as num).toInt(),
        isActive: ((r['is_active'] as num?)?.toInt() ?? 1) == 1,
        createdAt: DateTime.parse(r['created_at'] as String),
        updatedAt: (r['updated_at'] as String?) == null
            ? null
            : DateTime.parse(r['updated_at'] as String),
      );
}

class PlansDao {
  Future<Database> _db() => LocalDb.instance.open();

  Future<List<LocalPlan>> list({bool activeOnly = false}) async {
    final db = await _db();
    final rows = activeOnly
        ? await db.query('plans',
            where: 'is_active = 1', orderBy: 'name COLLATE NOCASE ASC')
        : await db.query('plans', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(LocalPlan.fromRow).toList();
  }

  Future<LocalPlan?> get(String id) async {
    final db = await _db();
    final rows = await db.query('plans', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : LocalPlan.fromRow(rows.first);
  }

  Future<void> upsert(LocalPlan plan) async {
    final db = await _db();
    final updated = await db.update(
      'plans',
      plan.toRow(),
      where: 'id = ?',
      whereArgs: [plan.id],
    );
    if (updated == 0) {
      await db.insert('plans', plan.toRow());
    }
  }

  Future<void> delete(String id) async {
    final db = await _db();
    await db.delete('plans', where: 'id = ?', whereArgs: [id]);
  }

  /// Returns a plan whose name matches [name] case-insensitively, or null.
  /// Used by the catalog dialog to block duplicate plan names. Pass [excludeId]
  /// when editing so the plan's own row isn't reported as a clash.
  Future<LocalPlan?> findByName(String name, {String? excludeId}) async {
    final db = await _db();
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final where = excludeId == null
        ? 'name = ? COLLATE NOCASE'
        : 'name = ? COLLATE NOCASE AND id <> ?';
    final args = excludeId == null
        ? <Object?>[trimmed]
        : <Object?>[trimmed, excludeId];
    final rows = await db.query('plans', where: where, whereArgs: args, limit: 1);
    return rows.isEmpty ? null : LocalPlan.fromRow(rows.first);
  }
}

final plansDaoProvider = Provider<PlansDao>((_) => PlansDao());
