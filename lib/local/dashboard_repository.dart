import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../core/tab_controller.dart';
import '../models/dashboard.dart';
import 'local_db.dart';

/// Computes a [DashboardSnapshot] entirely from the encrypted local DB. Mirrors
/// the cloud DashboardService output so the existing dashboard widgets work
/// unchanged. All percentages are computed against the previous calendar month.
class LocalDashboardRepository {
  Future<Database> _db() => LocalDb.instance.open();

  Future<DashboardSnapshot> snapshot() async {
    final db = await _db();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final monthStart = DateTime(now.year, now.month, 1);
    final nextMonthStart = DateTime(now.year, now.month + 1, 1);
    final lastMonthStart = DateTime(now.year, now.month - 1, 1);
    // A plan whose start_date is in the future has not begun yet, so it must
    // not count toward the current book (Active Plans / Total Receivable).
    // Compare against the start of tomorrow so a plan starting today is
    // included regardless of any time-of-day component in start_date.
    final startCutoff = today.add(const Duration(days: 1));

    final totalCustomers = await _scalarInt(db, 'SELECT COUNT(*) FROM customers');
    final activeCustomers = await _scalarInt(db, 'SELECT COUNT(*) FROM customers WHERE is_active = 1');
    final activeSubs = await _scalarInt(
      db,
      'SELECT COUNT(*) FROM subscriptions WHERE status = 1 AND start_date < ?',
      [startCutoff.toIso8601String()],
    );
    final overdueSubs = await _scalarInt(
      db,
      'SELECT COUNT(*) FROM subscriptions WHERE status = 1 AND next_due_date < ?',
      [today.toIso8601String()],
    );

    final dueToday = await _scalarInt(
      db,
      'SELECT COUNT(*) FROM subscriptions WHERE status = 1 AND next_due_date >= ? AND next_due_date < ?',
      [today.toIso8601String(), today.add(const Duration(days: 1)).toIso8601String()],
    );
    final endOfWeek = today.add(const Duration(days: 7));
    final dueThisWeek = await _scalarInt(
      db,
      'SELECT COUNT(*) FROM subscriptions WHERE status = 1 AND next_due_date >= ? AND next_due_date < ?',
      [today.toIso8601String(), endOfWeek.toIso8601String()],
    );
    final upcoming = await _scalarInt(
      db,
      'SELECT COUNT(*) FROM subscriptions WHERE status = 1 AND next_due_date >= ?',
      [endOfWeek.toIso8601String()],
    );

    final totalReceivable = await _scalarDouble(
      db,
      'SELECT COALESCE(SUM(amount), 0) FROM subscriptions WHERE status = 1 AND start_date < ?',
      [startCutoff.toIso8601String()],
    );
    // pendingDuesTotal = sum of OUTSTANDING balance per active overdue plan
    // (plan amount minus payments toward the current cycle), not the full
    // plan amount. A 1500-rs plan with 1000 paid contributes 500.
    final pendingDuesTotal = await _scalarDouble(
      db,
      '''
      SELECT COALESCE(SUM(
        MAX(0,
          s.amount -
          (COALESCE(p.total, 0) - CAST(COALESCE(p.total, 0) / s.amount AS INTEGER) * s.amount)
        )
      ), 0)
      FROM subscriptions s
      LEFT JOIN (SELECT subscription_id, SUM(amount) AS total FROM payments GROUP BY subscription_id) p
        ON p.subscription_id = s.id
      WHERE s.status = 1 AND s.next_due_date <= ?
      ''',
      [today.toIso8601String()],
    );
    final pendingLastMonth = await _scalarDouble(
      db,
      '''
      SELECT COALESCE(SUM(
        MAX(0,
          s.amount -
          (COALESCE(p.total, 0) - CAST(COALESCE(p.total, 0) / s.amount AS INTEGER) * s.amount)
        )
      ), 0)
      FROM subscriptions s
      LEFT JOIN (SELECT subscription_id, SUM(amount) AS total FROM payments GROUP BY subscription_id) p
        ON p.subscription_id = s.id
      WHERE s.status = 1 AND s.next_due_date < ?
      ''',
      [monthStart.toIso8601String()],
    );

    final collectedThisMonth = await _scalarDouble(
      db,
      'SELECT COALESCE(SUM(amount), 0) FROM payments WHERE payment_date >= ? AND payment_date < ?',
      [monthStart.toIso8601String(), nextMonthStart.toIso8601String()],
    );
    final collectedLastMonth = await _scalarDouble(
      db,
      'SELECT COALESCE(SUM(amount), 0) FROM payments WHERE payment_date >= ? AND payment_date < ?',
      [lastMonthStart.toIso8601String(), monthStart.toIso8601String()],
    );

    // Each overdue row carries the OUTSTANDING balance for the plan, not the
    // full plan amount. JOIN to per-sub payment totals and clamp via MAX(0,…)
    // so a fully-paid plan that's still flagged due-today shows 0.
    final overdueRows = await db.rawQuery('''
      SELECT s.id AS sub_id, s.customer_id, s.plan_name, s.next_due_date,
             c.name AS customer_name, c.mobile, c.email,
             MAX(0,
               s.amount -
               (COALESCE(p.total, 0) - CAST(COALESCE(p.total, 0) / s.amount AS INTEGER) * s.amount)
             ) AS outstanding,
             s.amount AS plan_amount
      FROM subscriptions s
      LEFT JOIN customers c ON c.id = s.customer_id
      LEFT JOIN (SELECT subscription_id, SUM(amount) AS total FROM payments GROUP BY subscription_id) p
        ON p.subscription_id = s.id
      -- Reminders are only offered for active customers, so the overdue list
      -- that drives the dashboard's quick-send buttons excludes inactive ones.
      WHERE s.status = 1 AND c.is_active = 1 AND s.next_due_date < ?
      ORDER BY s.next_due_date ASC
      LIMIT 5
    ''', [today.toIso8601String()]);
    final recentOverdue = overdueRows.map((r) {
      final due = DateTime.parse(r['next_due_date'] as String);
      final daysOver = today.difference(DateTime(due.year, due.month, due.day)).inDays;
      return OverdueItem(
        subscriptionId: r['sub_id'] as String,
        customerId: (r['customer_id'] as String?) ?? '',
        customerName: (r['customer_name'] as String?) ?? '(unknown)',
        planName: r['plan_name'] as String,
        daysOverdue: daysOver,
        amount: (r['outstanding'] as num).toDouble(),
        dueDate: due,
        phone: r['mobile'] as String?,
        email: r['email'] as String?,
      );
    }).toList();

    final trend = await _collectionTrend(db, now);

    final waSent = await _scalarInt(
      db,
      "SELECT COUNT(*) FROM reminder_history WHERE channel = 1 AND status = 'sent' AND sent_at >= ?",
      [monthStart.toIso8601String()],
    );
    final emSent = await _scalarInt(
      db,
      "SELECT COUNT(*) FROM reminder_history WHERE channel = 2 AND status = 'sent' AND sent_at >= ?",
      [monthStart.toIso8601String()],
    );
    // channel = 3 is SMS (see ReminderChannel). WhatsApp is disabled app-wide,
    // so SMS + Email are the live channels surfaced on the dashboard.
    final smsSent = await _scalarInt(
      db,
      "SELECT COUNT(*) FROM reminder_history WHERE channel = 3 AND status = 'sent' AND sent_at >= ?",
      [monthStart.toIso8601String()],
    );
    final pending = await _scalarInt(
      db,
      "SELECT COUNT(*) FROM reminder_history WHERE status = 'pending' AND sent_at >= ?",
      [monthStart.toIso8601String()],
    );
    final delivered = await _scalarInt(
      db,
      "SELECT COUNT(*) FROM reminder_history WHERE status IN ('delivered','sent') AND sent_at >= ?",
      [monthStart.toIso8601String()],
    );
    final failed = await _scalarInt(
      db,
      "SELECT COUNT(*) FROM reminder_history WHERE status = 'failed' AND sent_at >= ?",
      [monthStart.toIso8601String()],
    );
    // Pie total covers the live channels (SMS + Email) plus pending/failed, so
    // the segments add up to it. WhatsApp is excluded — it's disabled app-wide.
    final remTotal = smsSent + emSent + pending + failed;
    final sentToday = await _scalarInt(
      db,
      "SELECT COUNT(*) FROM reminder_history WHERE status = 'sent' AND sent_at >= ? AND sent_at < ?",
      [today.toIso8601String(), today.add(const Duration(days: 1)).toIso8601String()],
    );
    final waAttempted = await _scalarInt(
      db,
      'SELECT COUNT(*) FROM reminder_history WHERE channel = 1 AND sent_at >= ?',
      [monthStart.toIso8601String()],
    );
    final waSuccessPct =
        waAttempted == 0 ? 0.0 : (waSent / waAttempted) * 100.0;
    final smsAttempted = await _scalarInt(
      db,
      'SELECT COUNT(*) FROM reminder_history WHERE channel = 3 AND sent_at >= ?',
      [monthStart.toIso8601String()],
    );
    final smsSuccessPct =
        smsAttempted == 0 ? 0.0 : (smsSent / smsAttempted) * 100.0;

    return DashboardSnapshot(
      totalCustomers: totalCustomers,
      activeSubscriptions: activeSubs,
      collectedThisMonth: collectedThisMonth,
      pendingDuesTotal: pendingDuesTotal,
      overdueSubscriptions: overdueSubs,
      remindersSentThisMonth: smsSent + emSent,
      remindersFailedThisMonth: failed,
      totalReceivable: totalReceivable,
      collectedLastMonth: collectedLastMonth,
      pendingLastMonth: pendingLastMonth,
      collectionAmountChangePct: _pctChange(collectedLastMonth, collectedThisMonth),
      pendingAmountChangePct: _pctChange(pendingLastMonth, pendingDuesTotal),
      dueTodayCount: dueToday,
      dueThisWeekCount: dueThisWeek,
      upcomingCount: upcoming,
      recentOverdue: recentOverdue,
      collectionTrend: trend,
      remindersWhatsAppSent: waSent,
      remindersSmsSent: smsSent,
      remindersEmailSent: emSent,
      remindersPending: pending,
      remindersDelivered: delivered,
      remindersTotal: remTotal,
      activeCustomers: activeCustomers,
      remindersSentToday: sentToday,
      whatsAppSuccessRatePct: waSuccessPct,
      smsSuccessRatePct: smsSuccessPct,
      lastUpdatedUtc: DateTime.now().toUtc(),
    );
  }

  Future<List<MonthAmount>> _collectionTrend(Database db, DateTime now) async {
    const monthLabels = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final out = <MonthAmount>[];
    for (var i = 5; i >= 0; i--) {
      final start = DateTime(now.year, now.month - i, 1);
      final end = DateTime(now.year, now.month - i + 1, 1);
      final amt = await _scalarDouble(
        db,
        'SELECT COALESCE(SUM(amount), 0) FROM payments WHERE payment_date >= ? AND payment_date < ?',
        [start.toIso8601String(), end.toIso8601String()],
      );
      out.add(MonthAmount(
        year: start.year,
        month: start.month,
        label: monthLabels[start.month - 1],
        amount: amt,
      ));
    }
    return out;
  }

  static double _pctChange(double previous, double current) {
    if (previous <= 0.0001) return current <= 0.0001 ? 0.0 : 100.0;
    return ((current - previous) / previous) * 100.0;
  }

  Future<int> _scalarInt(Database db, String sql, [List<Object?>? args]) async {
    final r = await db.rawQuery(sql, args);
    final v = r.first.values.first;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  Future<double> _scalarDouble(Database db, String sql, [List<Object?>? args]) async {
    final r = await db.rawQuery(sql, args);
    final v = r.first.values.first;
    if (v is num) return v.toDouble();
    return 0.0;
  }
}

final localDashboardRepoProvider =
    Provider<LocalDashboardRepository>((_) => LocalDashboardRepository());

final localDashboardProvider =
    FutureProvider.autoDispose<DashboardSnapshot>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.read(localDashboardRepoProvider).snapshot();
});