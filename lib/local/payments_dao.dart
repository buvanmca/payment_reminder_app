import 'package:sqflite_sqlcipher/sqflite.dart';

import 'local_db.dart';

class LocalPayment {
  LocalPayment({
    required this.id,
    required this.subscriptionId,
    required this.amount,
    required this.paymentDate,
    required this.paymentMode,
    this.transactionRef,
    this.notes,
    required this.createdAt,
  });

  final String id;
  final String subscriptionId;
  final double amount;
  final DateTime paymentDate;
  final int paymentMode;
  final String? transactionRef;
  final String? notes;
  final DateTime createdAt;

  Map<String, Object?> toRow() => {
        'id': id,
        'subscription_id': subscriptionId,
        'amount': amount,
        'payment_date': paymentDate.toIso8601String(),
        'payment_mode': paymentMode,
        'transaction_ref': transactionRef,
        'notes': notes,
        'created_at': createdAt.toIso8601String(),
      };

  static LocalPayment fromRow(Map<String, Object?> r) => LocalPayment(
        id: r['id'] as String,
        subscriptionId: r['subscription_id'] as String,
        amount: (r['amount'] as num).toDouble(),
        paymentDate: DateTime.parse(r['payment_date'] as String),
        paymentMode: r['payment_mode'] as int,
        transactionRef: r['transaction_ref'] as String?,
        notes: r['notes'] as String?,
        createdAt: DateTime.parse(r['created_at'] as String),
      );
}

class PaymentsDao {
  Future<Database> _db() => LocalDb.instance.open();

  Future<List<LocalPayment>> list({String? subscriptionId, int limit = 200}) async {
    final db = await _db();
    final rows = subscriptionId == null
        ? await db.query('payments', orderBy: 'payment_date DESC', limit: limit)
        : await db.query('payments',
            where: 'subscription_id = ?',
            whereArgs: [subscriptionId],
            orderBy: 'payment_date DESC',
            limit: limit);
    return rows.map(LocalPayment.fromRow).toList();
  }

  Future<double> totalCollectedBetween(DateTime fromInclusive, DateTime toExclusive) async {
    final db = await _db();
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(amount), 0) AS total FROM payments WHERE payment_date >= ? AND payment_date < ?',
      [fromInclusive.toIso8601String(), toExclusive.toIso8601String()],
    );
    return ((rows.first['total'] as num?) ?? 0).toDouble();
  }

  /// Sum of all payments recorded for a single subscription. Used to drive
  /// the cumulative-paid model that decides when a plan's next_due_date
  /// should advance.
  Future<double> totalForSubscription(String subscriptionId) async {
    final db = await _db();
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(amount), 0) AS total FROM payments WHERE subscription_id = ?',
      [subscriptionId],
    );
    return ((rows.first['total'] as num?) ?? 0).toDouble();
  }

  Future<void> upsert(LocalPayment p) async {
    final db = await _db();
    final updated = await db.update(
      'payments',
      p.toRow(),
      where: 'id = ?',
      whereArgs: [p.id],
    );
    if (updated == 0) {
      await db.insert('payments', p.toRow());
    }
  }

  Future<void> delete(String id) async {
    final db = await _db();
    await db.delete('payments', where: 'id = ?', whereArgs: [id]);
  }
}