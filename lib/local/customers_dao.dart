import 'package:sqflite_sqlcipher/sqflite.dart';

import 'local_db.dart';

class LocalCustomer {
  LocalCustomer({
    required this.id,
    required this.name,
    required this.mobile,
    this.email,
    this.address,
    required this.isActive,
    this.notes,
    required this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String mobile;
  final String? email;
  final String? address;
  final bool isActive;
  final String? notes;
  final DateTime createdAt;
  final DateTime? updatedAt;

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'mobile': mobile,
        'email': email,
        'address': address,
        'is_active': isActive ? 1 : 0,
        'notes': notes,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      };

  static LocalCustomer fromRow(Map<String, Object?> r) => LocalCustomer(
        id: r['id'] as String,
        name: r['name'] as String,
        mobile: r['mobile'] as String,
        email: r['email'] as String?,
        address: r['address'] as String?,
        isActive: ((r['is_active'] as int?) ?? 1) == 1,
        notes: r['notes'] as String?,
        createdAt: DateTime.parse(r['created_at'] as String),
        updatedAt: (r['updated_at'] as String?) == null
            ? null
            : DateTime.parse(r['updated_at'] as String),
      );
}

class CustomersDao {
  Future<Database> _db() => LocalDb.instance.open();

  Future<List<LocalCustomer>> list({String? search}) async {
    final db = await _db();
    final List<Map<String, Object?>> rows;
    if (search != null && search.trim().isNotEmpty) {
      final s = '%${search.trim().toLowerCase()}%';
      rows = await db.query(
        'customers',
        where: 'LOWER(name) LIKE ? OR mobile LIKE ?',
        whereArgs: [s, s],
        orderBy: 'name COLLATE NOCASE',
      );
    } else {
      rows = await db.query('customers', orderBy: 'name COLLATE NOCASE');
    }
    return rows.map(LocalCustomer.fromRow).toList();
  }

  Future<LocalCustomer?> get(String id) async {
    final db = await _db();
    final rows = await db.query('customers', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : LocalCustomer.fromRow(rows.first);
  }

  Future<void> upsert(LocalCustomer c) async {
    final db = await _db();
    // ConflictAlgorithm.replace would DELETE-then-INSERT on conflict, which
    // with FK enforcement on triggers ON DELETE CASCADE and wipes the
    // customer's subscriptions and payments. UPDATE-then-INSERT mutates the
    // existing row in place instead.
    final updated = await db.update(
      'customers',
      c.toRow(),
      where: 'id = ?',
      whereArgs: [c.id],
    );
    if (updated == 0) {
      await db.insert('customers', c.toRow());
    }
  }

  Future<void> delete(String id) async {
    final db = await _db();
    await db.delete('customers', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> count() async {
    final db = await _db();
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM customers');
    return (rows.first['c'] as int?) ?? 0;
  }

  /// Returns an existing customer with a case-insensitive name match and an
  /// exact mobile match, or null if none. Used by the customer create/edit
  /// dialog to block duplicate records before they hit the DB. When editing
  /// an existing customer, pass [excludeId] so the customer's own row isn't
  /// reported as a duplicate of itself.
  Future<LocalCustomer?> findByNameAndMobile(
    String name,
    String mobile, {
    String? excludeId,
  }) async {
    final db = await _db();
    final trimmedName = name.trim();
    final trimmedMobile = mobile.trim();
    if (trimmedName.isEmpty || trimmedMobile.isEmpty) return null;
    final where = excludeId == null
        ? 'LOWER(name) = LOWER(?) AND mobile = ?'
        : 'LOWER(name) = LOWER(?) AND mobile = ? AND id <> ?';
    final args = excludeId == null
        ? <Object?>[trimmedName, trimmedMobile]
        : <Object?>[trimmedName, trimmedMobile, excludeId];
    final rows = await db.query(
      'customers',
      where: where,
      whereArgs: args,
      limit: 1,
    );
    return rows.isEmpty ? null : LocalCustomer.fromRow(rows.first);
  }
}