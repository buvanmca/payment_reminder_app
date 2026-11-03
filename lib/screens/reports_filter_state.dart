import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local/reminder_history_dao.dart';

/// Plan status codes used by `subscriptions.status`:
/// 1 = active, 2 = paused/inactive, 3 = closed.
class PlanStatus {
  static const int active = 1;
  static const int inactive = 2;
  static const int closed = 3;
}

/// Payment mode codes mirror the dropdown in payments_tab.dart.
class PaymentMode {
  static const int cash = 1;
  static const int upi = 2;
  static const int bank = 3;
  static const int card = 4;
  static const int cheque = 5;
  static const int other = 99;
}

/// Immutable snapshot of all filter selections in the Reports screen. Held by
/// [reportFiltersProvider]; row providers `ref.watch` it and re-derive on
/// every change.
@immutable
class ReportFilters {
  const ReportFilters({
    this.dateRange,
    this.customerId,
    this.planStatus,
    this.paymentMode,
    this.channel,
    this.reminderStatus,
    this.search = '',
  });

  /// Inclusive [start, end]. `end` is treated as end-of-day in the providers.
  final DateTimeRange? dateRange;
  final String? customerId;
  final int? planStatus;
  final int? paymentMode;
  final ReminderChannel? channel;
  final String? reminderStatus;
  final String search;

  ReportFilters copyWith({
    Object? dateRange = _unset,
    Object? customerId = _unset,
    Object? planStatus = _unset,
    Object? paymentMode = _unset,
    Object? channel = _unset,
    Object? reminderStatus = _unset,
    String? search,
  }) {
    return ReportFilters(
      dateRange: identical(dateRange, _unset) ? this.dateRange : dateRange as DateTimeRange?,
      customerId: identical(customerId, _unset) ? this.customerId : customerId as String?,
      planStatus: identical(planStatus, _unset) ? this.planStatus : planStatus as int?,
      paymentMode: identical(paymentMode, _unset) ? this.paymentMode : paymentMode as int?,
      channel: identical(channel, _unset) ? this.channel : channel as ReminderChannel?,
      reminderStatus:
          identical(reminderStatus, _unset) ? this.reminderStatus : reminderStatus as String?,
      search: search ?? this.search,
    );
  }

  bool get hasAnyFilter =>
      dateRange != null ||
      customerId != null ||
      planStatus != null ||
      paymentMode != null ||
      channel != null ||
      reminderStatus != null ||
      search.isNotEmpty;
}

const Object _unset = Object();

/// Default range: first day of the current month through today (inclusive).
DateTimeRange currentMonthRange({DateTime? now}) {
  final n = now ?? DateTime.now();
  final start = DateTime(n.year, n.month, 1);
  final end = DateTime(n.year, n.month, n.day);
  return DateTimeRange(start: start, end: end);
}

final reportFiltersProvider = StateProvider<ReportFilters>(
  (_) => ReportFilters(dateRange: currentMonthRange()),
);
