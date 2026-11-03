import 'package:sqflite_sqlcipher/sqflite.dart';

import 'local_db.dart';
import 'subscription_date_calc.dart';

class LocalSubscription {
  LocalSubscription({
    required this.id,
    required this.customerId,
    this.planId,
    required this.planName,
    required this.amount,
    required this.frequency,
    required this.startDate,
    required this.nextDueDate,
    required this.status,
    required this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String customerId;

  /// Soft reference to the catalog [LocalPlan] this subscription was created
  /// from. Nullable for legacy rows; the subscription always keeps its own
  /// planName/amount/frequency snapshot, so a null plan_id is harmless.
  final String? planId;
  final String planName;
  final double amount;
  final int frequency;
  final DateTime startDate;
  final DateTime nextDueDate;
  final int status;
  final DateTime createdAt;
  final DateTime? updatedAt;

  Map<String, Object?> toRow() => {
        'id': id,
        'customer_id': customerId,
        'plan_id': planId,
        'plan_name': planName,
        'amount': amount,
        'frequency': frequency,
        'start_date': startDate.toIso8601String(),
        'next_due_date': nextDueDate.toIso8601String(),
        'status': status,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      };

  static LocalSubscription fromRow(Map<String, Object?> r) => LocalSubscription(
        id: r['id'] as String,
        customerId: r['customer_id'] as String,
        planId: r['plan_id'] as String?,
        planName: r['plan_name'] as String,
        amount: (r['amount'] as num).toDouble(),
        frequency: r['frequency'] as int,
        startDate: DateTime.parse(r['start_date'] as String),
        nextDueDate: DateTime.parse(r['next_due_date'] as String),
        status: r['status'] as int,
        createdAt: DateTime.parse(r['created_at'] as String),
        updatedAt: (r['updated_at'] as String?) == null
            ? null
            : DateTime.parse(r['updated_at'] as String),
      );
}

/// One overdue subscription's name + current-cycle outstanding amount, used to
/// itemize a customer reminder. See [SubscriptionsDao.overdueBreakdownForCustomer].
class OverdueLine {
  OverdueLine(this.planName, this.outstanding, this.dueDate);
  final String planName;
  final double outstanding;
  final DateTime dueDate;
}

class SubscriptionsDao {
  Future<Database> _db() => LocalDb.instance.open();

  Future<List<LocalSubscription>> list({String? customerId}) async {
    final db = await _db();
    final rows = customerId == null
        ? await db.query('subscriptions', orderBy: 'next_due_date ASC')
        : await db.query('subscriptions',
            where: 'customer_id = ?', whereArgs: [customerId], orderBy: 'next_due_date ASC');
    return rows.map(LocalSubscription.fromRow).toList();
  }

  Future<List<LocalSubscription>> dueOnOrBefore(DateTime cutoff) async {
    final db = await _db();
    final rows = await db.query(
      'subscriptions',
      where: 'next_due_date <= ? AND status = 1',
      whereArgs: [cutoff.toIso8601String()],
    );
    return rows.map(LocalSubscription.fromRow).toList();
  }

  /// Outstanding amount for a customer's active overdue/due-today plans.
  /// Per plan, returns plan_amount minus payments toward the current cycle
  /// — so a 1500-rs plan with 1000 rs paid contributes 500, not 1500.
  /// Replaces the previous "sum of plan.amount" which was misleading after
  /// partial payments.
  Future<double> totalDueForCustomer(String customerId, {DateTime? asOf}) async {
    final db = await _db();
    final cutoff = (asOf ?? DateTime.now()).toIso8601String();
    // Compute outstanding balance per overdue plan via JOIN to a per-sub
    // payment total. The key formula:
    //   cyclesPaid     = floor(totalPaid / amount)
    //   paidThisCycle  = totalPaid - cyclesPaid * amount
    //   outstanding    = amount - paidThisCycle  (clamped to 0)
    // SQLite doesn't have a clamp/floor for floats, so we cast to integer
    // for the floor and rely on real arithmetic for the rest.
    final rows = await db.rawQuery('''
      SELECT COALESCE(SUM(
        MAX(0,
          s.amount -
          (COALESCE(p.total, 0) - CAST(COALESCE(p.total, 0) / s.amount AS INTEGER) * s.amount)
        )
      ), 0) AS total
      FROM subscriptions s
      LEFT JOIN (
        SELECT subscription_id, SUM(amount) AS total
        FROM payments GROUP BY subscription_id
      ) p ON p.subscription_id = s.id
      WHERE s.customer_id = ? AND s.status = 1 AND s.next_due_date <= ?
    ''', [customerId, cutoff]);
    return ((rows.first['total'] as num?) ?? 0).toDouble();
  }

  /// Outstanding for the current cycle of a single plan, accounting for
  /// advance payments. A 1000-rs plan with 1500 paid returns 500 (June fully
  /// paid, 500 advance toward July leaves July's remaining at 500). With 2000
  /// paid: returns 1000 (two full cycles paid, the cycle next_due points at
  /// has zero advance carry). Mirrors the formula used by totalDueForCustomer
  /// and the dashboard's pendingDuesTotal so reminder amounts stay in sync.
  Future<double> outstandingForSubscription(String subscriptionId) async {
    final db = await _db();
    final rows = await db.rawQuery('''
      SELECT MAX(0,
        s.amount -
        (COALESCE(p.total, 0) - CAST(COALESCE(p.total, 0) / s.amount AS INTEGER) * s.amount)
      ) AS outstanding
      FROM subscriptions s
      LEFT JOIN (
        SELECT subscription_id, SUM(amount) AS total
        FROM payments WHERE subscription_id = ?
      ) p ON p.subscription_id = s.id
      WHERE s.id = ?
    ''', [subscriptionId, subscriptionId]);
    if (rows.isEmpty) return 0;
    return ((rows.first['outstanding'] as num?) ?? 0).toDouble();
  }

  /// Outstanding owed *as of now* for a single plan — the current cycle's
  /// remaining, but only counted once the cycle has actually become due
  /// (next_due_date <= [asOf]) and only for active plans. A plan that's paid
  /// up for its current cycle has its next_due_date advanced into the future
  /// by [PaymentsDao]/_recomputeNextDue, so this returns 0 until that cycle
  /// arrives.
  ///
  /// This differs from [outstandingForSubscription], which always reports the
  /// pointed-at cycle's remaining regardless of date — that flavor is used by
  /// the scheduler to size *pre-due* reminder amounts. Reports must instead
  /// show what is genuinely owed today: without the date gate, recording a
  /// full payment makes `amount - (paid % amount)` wrap back to the full plan
  /// amount, so the Activity report showed the plan as fully outstanding again
  /// the instant the customer paid. Mirrors [totalDueForCustomer]'s predicate
  /// so per-plan rows reconcile with the customer-level total.
  Future<double> outstandingDueForSubscription(
    String subscriptionId, {
    DateTime? asOf,
  }) async {
    final db = await _db();
    final cutoff = (asOf ?? DateTime.now()).toIso8601String();
    final rows = await db.rawQuery('''
      SELECT MAX(0,
        s.amount -
        (COALESCE(p.total, 0) - CAST(COALESCE(p.total, 0) / s.amount AS INTEGER) * s.amount)
      ) AS outstanding
      FROM subscriptions s
      LEFT JOIN (
        SELECT subscription_id, SUM(amount) AS total
        FROM payments WHERE subscription_id = ?
      ) p ON p.subscription_id = s.id
      WHERE s.id = ? AND s.status = 1 AND s.next_due_date <= ?
    ''', [subscriptionId, subscriptionId, cutoff]);
    if (rows.isEmpty) return 0;
    return ((rows.first['outstanding'] as num?) ?? 0).toDouble();
  }

  /// Total advance balance for a customer — money already paid above what
  /// has accrued by [asOf]. For a 1200/month plan that started today with
  /// 15000 paid, only one cycle (1200) has accrued, so advance is 13800. As
  /// time passes the accrued portion grows and advance shrinks. Computed in
  /// Dart per row because SQLite has no calendar-aware month arithmetic.
  Future<double> totalAdvanceForCustomer(String customerId, {DateTime? asOf}) async {
    final db = await _db();
    final rows = await db.rawQuery('''
      SELECT s.start_date, s.frequency, s.amount, COALESCE(p.total, 0) AS total_paid
      FROM subscriptions s
      LEFT JOIN (
        SELECT subscription_id, SUM(amount) AS total
        FROM payments GROUP BY subscription_id
      ) p ON p.subscription_id = s.id
      WHERE s.customer_id = ? AND s.status = 1
    ''', [customerId]);

    var total = 0.0;
    for (final r in rows) {
      total += computeAdvanceFor(
        startDate: DateTime.parse(r['start_date'] as String),
        frequency: (r['frequency'] as num).toInt(),
        amountPerCycle: (r['amount'] as num).toDouble(),
        totalPaid: ((r['total_paid'] as num?) ?? 0).toDouble(),
        asOf: asOf,
      );
    }
    return total;
  }

  /// Per-subscription overdue breakdown for a customer: one [OverdueLine] for
  /// each active subscription due on/before [asOf] that still has an
  /// outstanding balance. Uses the SAME predicate and per-cycle outstanding
  /// formula as [totalDueForCustomer], so the line amounts sum to that total.
  /// Ordered by due date (most overdue first). Drives the itemized reminder.
  Future<List<OverdueLine>> overdueBreakdownForCustomer(
    String customerId, {
    DateTime? asOf,
  }) async {
    final db = await _db();
    final cutoff = (asOf ?? DateTime.now()).toIso8601String();
    final rows = await db.rawQuery('''
      SELECT s.plan_name AS plan_name, s.next_due_date AS next_due_date,
        MAX(0,
          s.amount -
          (COALESCE(p.total, 0) - CAST(COALESCE(p.total, 0) / s.amount AS INTEGER) * s.amount)
        ) AS outstanding
      FROM subscriptions s
      LEFT JOIN (
        SELECT subscription_id, SUM(amount) AS total
        FROM payments GROUP BY subscription_id
      ) p ON p.subscription_id = s.id
      WHERE s.customer_id = ? AND s.status = 1 AND s.next_due_date <= ?
      ORDER BY s.next_due_date ASC
    ''', [customerId, cutoff]);
    final out = <OverdueLine>[];
    for (final r in rows) {
      final outstanding = ((r['outstanding'] as num?) ?? 0).toDouble();
      if (outstanding <= 0) continue;
      out.add(OverdueLine(
        r['plan_name'] as String,
        outstanding,
        DateTime.parse(r['next_due_date'] as String),
      ));
    }
    return out;
  }

  Future<LocalSubscription?> get(String id) async {
    final db = await _db();
    final rows = await db.query('subscriptions', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : LocalSubscription.fromRow(rows.first);
  }

  Future<void> upsert(LocalSubscription s) async {
    final db = await _db();
    // UPDATE-then-INSERT to avoid ON DELETE CASCADE wiping payments under
    // this subscription when the row already exists.
    final updated = await db.update(
      'subscriptions',
      s.toRow(),
      where: 'id = ?',
      whereArgs: [s.id],
    );
    if (updated == 0) {
      await db.insert('subscriptions', s.toRow());
    }
  }

  Future<void> delete(String id) async {
    final db = await _db();
    await db.delete('subscriptions', where: 'id = ?', whereArgs: [id]);
  }

  /// Returns an existing plan for [customerId] whose plan_name matches
  /// [planName] case-insensitively, or null if none. Used by the plan
  /// create/edit dialog to block duplicates per customer. Pass [excludeId]
  /// when editing so the plan's own row isn't reported as a clash.
  Future<LocalSubscription?> findByCustomerAndPlanName(
    String customerId,
    String planName, {
    String? excludeId,
  }) async {
    final db = await _db();
    final trimmed = planName.trim();
    if (customerId.isEmpty || trimmed.isEmpty) return null;
    final where = excludeId == null
        ? 'customer_id = ? AND LOWER(plan_name) = LOWER(?)'
        : 'customer_id = ? AND LOWER(plan_name) = LOWER(?) AND id <> ?';
    final args = excludeId == null
        ? <Object?>[customerId, trimmed]
        : <Object?>[customerId, trimmed, excludeId];
    final rows = await db.query(
      'subscriptions',
      where: where,
      whereArgs: args,
      limit: 1,
    );
    return rows.isEmpty ? null : LocalSubscription.fromRow(rows.first);
  }
}