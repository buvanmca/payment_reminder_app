import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/tab_controller.dart';
import '../local/customers_dao.dart';
import '../local/payments_dao.dart';
import '../local/reminder_history_dao.dart';
import '../local/subscriptions_dao.dart';
import 'customers_tab.dart' show customersDaoProvider, subscriptionsDaoProvider;
import 'payments_tab.dart' show paymentsDaoProvider;
import 'reports_filter_state.dart';

final reminderHistoryDaoProvider =
    Provider<ReminderHistoryDao>((_) => ReminderHistoryDao());

class CustomerReportRow {
  CustomerReportRow({
    required this.customer,
    required this.planCount,
    required this.paidInRange,
    required this.outstanding,
  });
  final LocalCustomer customer;
  final int planCount;
  final double paidInRange;
  final double outstanding;
}

class PlanReportRow {
  PlanReportRow({
    required this.plan,
    required this.customerName,
    required this.collectedInRange,
    required this.outstanding,
  });
  final LocalSubscription plan;
  final String customerName;
  final double collectedInRange;
  final double outstanding;
}

class PaymentReportRow {
  PaymentReportRow(this.payment, this.planName, this.customerName);
  final LocalPayment payment;
  final String planName;
  final String customerName;
}

class ReminderReportRow {
  ReminderReportRow(this.reminder, this.customerName);
  final LocalReminder reminder;
  final String customerName;
}

/// One flat row joining a customer, one of their plans, and the payment
/// activity for that plan within the selected date range. Drives the single
/// "Activity" grid that replaces the old Customers / Plans / Payments tabs.
class CombinedReportRow {
  CombinedReportRow({
    required this.customer,
    required this.plan,
    required this.paidInRange,
    required this.paymentsInRange,
    required this.outstanding,
    required this.lastPaymentDate,
    required this.lastPaymentMode,
  });
  final LocalCustomer customer;
  final LocalSubscription plan;
  final double paidInRange;
  final int paymentsInRange;
  final double outstanding;
  final DateTime? lastPaymentDate;
  final int? lastPaymentMode;
}

class ReportSummary {
  ReportSummary({
    required this.totalCollected,
    required this.outstanding,
    required this.activePlans,
    required this.totalCustomers,
    required this.remindersSent,
    required this.remindersFailed,
  });
  final double totalCollected;
  final double outstanding;
  final int activePlans;
  final int totalCustomers;
  final int remindersSent;
  final int remindersFailed;
}

// Pre-computed snapshot of every customer + plan, used by all providers.
// Computed once per dataRevision so the five providers don't each re-query
// the same tables on every filter tweak.
class _ReportContext {
  _ReportContext({
    required this.customersById,
    required this.plansById,
  });
  final Map<String, LocalCustomer> customersById;
  final Map<String, LocalSubscription> plansById;

  String customerNameOf(String? id) => id == null
      ? '(unknown)'
      : (customersById[id]?.name ?? '(unknown)');

  String? customerIdForPlan(String? planId) =>
      planId == null ? null : plansById[planId]?.customerId;
}

final _reportContextProvider =
    FutureProvider.autoDispose<_ReportContext>((ref) async {
  ref.watch(dataRevisionProvider);
  final customers = await ref.read(customersDaoProvider).list();
  final plans = await ref.read(subscriptionsDaoProvider).list();
  return _ReportContext(
    customersById: {for (final c in customers) c.id: c},
    plansById: {for (final p in plans) p.id: p},
  );
});

DateTime _endOfDay(DateTime d) =>
    DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

bool _inRange(DateTime when, DateTimeRange? range) {
  if (range == null) return true;
  if (when.isBefore(range.start)) return false;
  if (when.isAfter(_endOfDay(range.end))) return false;
  return true;
}

bool _matchesSearch(String haystack, String needle) {
  if (needle.isEmpty) return true;
  return haystack.toLowerCase().contains(needle.toLowerCase());
}

final reportPaymentsProvider =
    FutureProvider.autoDispose<List<PaymentReportRow>>((ref) async {
  ref.watch(dataRevisionProvider);
  final filters = ref.watch(reportFiltersProvider);
  final ctx = await ref.watch(_reportContextProvider.future);
  final payments = await ref.read(paymentsDaoProvider).list(limit: 100000);

  final out = <PaymentReportRow>[];
  for (final p in payments) {
    if (!_inRange(p.paymentDate, filters.dateRange)) continue;
    if (filters.paymentMode != null && p.paymentMode != filters.paymentMode) {
      continue;
    }
    final plan = ctx.plansById[p.subscriptionId];
    final customerId = plan?.customerId;
    if (filters.customerId != null && customerId != filters.customerId) continue;
    if (filters.planStatus != null &&
        (plan == null || plan.status != filters.planStatus)) continue;
    final customerName = ctx.customerNameOf(customerId);
    final planName = plan?.planName ?? '(plan removed)';
    final searchHaystack = '$customerName $planName ${p.transactionRef ?? ''}';
    if (!_matchesSearch(searchHaystack, filters.search)) continue;
    out.add(PaymentReportRow(p, planName, customerName));
  }
  return out;
});

final reportRemindersProvider =
    FutureProvider.autoDispose<List<ReminderReportRow>>((ref) async {
  ref.watch(dataRevisionProvider);
  final filters = ref.watch(reportFiltersProvider);
  final ctx = await ref.watch(_reportContextProvider.future);
  // DAO defaults to limit:100 — pull a generous slice so report filtering
  // can dig into older history.
  final reminders =
      await ref.read(reminderHistoryDaoProvider).list(limit: 100000);

  final out = <ReminderReportRow>[];
  for (final r in reminders) {
    if (!_inRange(r.sentAt, filters.dateRange)) continue;
    if (filters.channel != null && r.channel != filters.channel) continue;
    if (filters.reminderStatus != null && r.status != filters.reminderStatus) {
      continue;
    }
    final customerId = r.customerId ?? ctx.customerIdForPlan(r.subscriptionId);
    if (filters.customerId != null && customerId != filters.customerId) continue;
    final customerName = ctx.customerNameOf(customerId);
    final searchHaystack = '$customerName ${r.recipient} ${r.error ?? ''}';
    if (!_matchesSearch(searchHaystack, filters.search)) continue;
    out.add(ReminderReportRow(r, customerName));
  }
  return out;
});

final reportPlansProvider =
    FutureProvider.autoDispose<List<PlanReportRow>>((ref) async {
  ref.watch(dataRevisionProvider);
  final filters = ref.watch(reportFiltersProvider);
  final ctx = await ref.watch(_reportContextProvider.future);
  final subsDao = ref.read(subscriptionsDaoProvider);
  // Reuse date-filtered payments to compute per-plan collected-in-range.
  final payments = await ref.watch(reportPaymentsProvider.future);
  final collectedByPlan = <String, double>{};
  for (final p in payments) {
    collectedByPlan[p.payment.subscriptionId] =
        (collectedByPlan[p.payment.subscriptionId] ?? 0) + p.payment.amount;
  }

  final out = <PlanReportRow>[];
  for (final plan in ctx.plansById.values) {
    if (filters.customerId != null && plan.customerId != filters.customerId) {
      continue;
    }
    if (filters.planStatus != null && plan.status != filters.planStatus) continue;
    final customerName = ctx.customerNameOf(plan.customerId);
    if (!_matchesSearch('$customerName ${plan.planName}', filters.search)) {
      continue;
    }
    final outstanding = await subsDao.outstandingDueForSubscription(plan.id);
    out.add(PlanReportRow(
      plan: plan,
      customerName: customerName,
      collectedInRange: collectedByPlan[plan.id] ?? 0,
      outstanding: outstanding,
    ));
  }
  out.sort((a, b) => a.plan.nextDueDate.compareTo(b.plan.nextDueDate));
  return out;
});

final reportCustomersProvider =
    FutureProvider.autoDispose<List<CustomerReportRow>>((ref) async {
  ref.watch(dataRevisionProvider);
  final filters = ref.watch(reportFiltersProvider);
  final ctx = await ref.watch(_reportContextProvider.future);
  final subsDao = ref.read(subscriptionsDaoProvider);
  final payments = await ref.watch(reportPaymentsProvider.future);

  final paidByCustomer = <String, double>{};
  for (final p in payments) {
    final cid = ctx.customerIdForPlan(p.payment.subscriptionId);
    if (cid == null) continue;
    paidByCustomer[cid] = (paidByCustomer[cid] ?? 0) + p.payment.amount;
  }
  final planCountByCustomer = <String, int>{};
  for (final plan in ctx.plansById.values) {
    if (filters.planStatus != null && plan.status != filters.planStatus) continue;
    planCountByCustomer[plan.customerId] =
        (planCountByCustomer[plan.customerId] ?? 0) + 1;
  }

  final out = <CustomerReportRow>[];
  for (final c in ctx.customersById.values) {
    if (filters.customerId != null && c.id != filters.customerId) continue;
    if (!_matchesSearch('${c.name} ${c.mobile}', filters.search)) continue;
    final outstanding = await subsDao.totalDueForCustomer(c.id);
    out.add(CustomerReportRow(
      customer: c,
      planCount: planCountByCustomer[c.id] ?? 0,
      paidInRange: paidByCustomer[c.id] ?? 0,
      outstanding: outstanding,
    ));
  }
  out.sort((a, b) =>
      a.customer.name.toLowerCase().compareTo(b.customer.name.toLowerCase()));
  return out;
});

final reportSummaryProvider =
    FutureProvider.autoDispose<ReportSummary>((ref) async {
  ref.watch(dataRevisionProvider);
  final payments = await ref.watch(reportPaymentsProvider.future);
  final reminders = await ref.watch(reportRemindersProvider.future);
  final customers = await ref.watch(reportCustomersProvider.future);
  final plans = await ref.watch(reportPlansProvider.future);

  var totalCollected = 0.0;
  for (final p in payments) {
    totalCollected += p.payment.amount;
  }
  var outstanding = 0.0;
  for (final c in customers) {
    outstanding += c.outstanding;
  }
  final activePlans =
      plans.where((p) => p.plan.status == PlanStatus.active).length;
  var sent = 0;
  var failed = 0;
  for (final r in reminders) {
    if (r.reminder.status == 'sent') {
      sent++;
    } else {
      failed++;
    }
  }
  return ReportSummary(
    totalCollected: totalCollected,
    outstanding: outstanding,
    activePlans: activePlans,
    totalCustomers: customers.length,
    remindersSent: sent,
    remindersFailed: failed,
  );
});

/// One row per plan, joined with its customer and the payments that fall
/// inside the selected date range. Filters apply as expected: customer,
/// planStatus, paymentMode (only plans with at least one matching-mode
/// payment in range), and search (matches customer name / mobile / plan
/// name).
final reportCombinedProvider =
    FutureProvider.autoDispose<List<CombinedReportRow>>((ref) async {
  ref.watch(dataRevisionProvider);
  final filters = ref.watch(reportFiltersProvider);
  final ctx = await ref.watch(_reportContextProvider.future);
  final subsDao = ref.read(subscriptionsDaoProvider);
  final paymentsDao = ref.read(paymentsDaoProvider);
  final allPayments = await paymentsDao.list(limit: 100000);

  // Group payments by subscription, applying date-range and mode filters as
  // we go so the per-plan aggregates already reflect the active filters.
  final paymentsByPlan = <String, List<LocalPayment>>{};
  for (final p in allPayments) {
    if (!_inRange(p.paymentDate, filters.dateRange)) continue;
    if (filters.paymentMode != null && p.paymentMode != filters.paymentMode) {
      continue;
    }
    paymentsByPlan.putIfAbsent(p.subscriptionId, () => []).add(p);
  }

  final out = <CombinedReportRow>[];
  for (final plan in ctx.plansById.values) {
    if (filters.customerId != null && plan.customerId != filters.customerId) {
      continue;
    }
    if (filters.planStatus != null && plan.status != filters.planStatus) {
      continue;
    }
    final customer = ctx.customersById[plan.customerId];
    if (customer == null) continue; // orphaned plan; skip
    final searchHaystack = '${customer.name} ${customer.mobile} ${plan.planName}';
    if (!_matchesSearch(searchHaystack, filters.search)) continue;

    final planPayments = paymentsByPlan[plan.id] ?? const <LocalPayment>[];
    // If a payment-mode filter is active, drop plans with no matching
    // payment in the selected period — the user is asking about that mode
    // specifically.
    if (filters.paymentMode != null && planPayments.isEmpty) continue;

    var paid = 0.0;
    DateTime? lastDate;
    int? lastMode;
    for (final p in planPayments) {
      paid += p.amount;
      if (lastDate == null || p.paymentDate.isAfter(lastDate)) {
        lastDate = p.paymentDate;
        lastMode = p.paymentMode;
      }
    }
    // Outstanding owed *as of now* — a plan paid up for the current cycle
    // (next_due advanced into the future) reads 0, instead of wrapping back to
    // the full plan amount the moment a full payment lands.
    final outstanding = await subsDao.outstandingDueForSubscription(plan.id);
    out.add(CombinedReportRow(
      customer: customer,
      plan: plan,
      paidInRange: paid,
      paymentsInRange: planPayments.length,
      outstanding: outstanding,
      lastPaymentDate: lastDate,
      lastPaymentMode: lastMode,
    ));
  }
  out.sort((a, b) {
    final byCust =
        a.customer.name.toLowerCase().compareTo(b.customer.name.toLowerCase());
    if (byCust != 0) return byCust;
    return a.plan.planName.toLowerCase().compareTo(b.plan.planName.toLowerCase());
  });
  return out;
});
