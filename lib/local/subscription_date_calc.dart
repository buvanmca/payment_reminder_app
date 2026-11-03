/// Period frequencies as encoded in the local DB (matches the cloud enum):
/// 1 = Monthly, 2 = Quarterly, 3 = Half Yearly, 4 = Yearly.
class SubscriptionDateCalc {
  static DateTime advance(DateTime from, int frequency) =>
      advanceN(from, frequency, 1);

  /// Advance [from] by [n] periods. n=0 returns [from] unchanged; negative n
  /// is treated as 0 (we never roll a plan backwards via this helper).
  static DateTime advanceN(DateTime from, int frequency, int n) {
    if (n <= 0) return from;
    final months = switch (frequency) {
      1 => 1,
      2 => 3,
      3 => 6,
      4 => 12,
      _ => 1,
    };
    return _addMonths(from, months * n);
  }

  static DateTime _addMonths(DateTime d, int months) {
    var y = d.year;
    var m = d.month + months;
    while (m > 12) {
      m -= 12;
      y += 1;
    }
    while (m < 1) {
      m += 12;
      y -= 1;
    }
    final lastDayOfTarget = DateTime(y, m + 1, 0).day;
    final day = d.day > lastDayOfTarget ? lastDayOfTarget : d.day;
    return DateTime(y, m, day, d.hour, d.minute, d.second, d.millisecond, d.microsecond);
  }
}

/// Number of full cycles that have been paid based on cumulative payments
/// against a plan with [amountPerCycle] price tag. A 1500-rs plan with 1000
/// rs paid returns 0 (one cycle still partially owed); 1500 paid returns 1;
/// 3500 paid returns 2 (two cycles done, 500 toward the third).
int cyclesFullyPaid({required double amountPerCycle, required double totalPaid}) {
  if (amountPerCycle <= 0) return 0;
  if (totalPaid <= 0) return 0;
  return (totalPaid / amountPerCycle).floor();
}

/// The next due date a plan should advertise given the user's cumulative
/// payments. If only partial payments exist for the current cycle, this
/// returns the cycle's existing start (no advance), so the dashboard keeps
/// showing the plan as overdue / due.
DateTime computeNextDueFor({
  required DateTime startDate,
  required int frequency,
  required double amountPerCycle,
  required double totalPaid,
}) {
  final cycles = cyclesFullyPaid(amountPerCycle: amountPerCycle, totalPaid: totalPaid);
  return SubscriptionDateCalc.advanceN(startDate, frequency, cycles);
}

/// Outstanding amount for the cycle the plan is currently in. For 1500/month
/// plan with 1000 paid: returns 500. With 1500 paid: returns 0 (cycle paid in
/// full; the next cycle will be due at the next next_due_date). With 2000
/// paid: returns 1000 — one full cycle paid, 500 carry-over toward the next.
double computeRemainingForCurrentCycle({
  required double amountPerCycle,
  required double totalPaid,
}) {
  if (amountPerCycle <= 0) return 0;
  if (totalPaid <= 0) return amountPerCycle;
  final cycles = cyclesFullyPaid(amountPerCycle: amountPerCycle, totalPaid: totalPaid);
  final paidThisCycle = totalPaid - cycles * amountPerCycle;
  final remaining = amountPerCycle - paidThisCycle;
  return remaining < 0 ? 0 : remaining;
}

/// Number of cycles that have started (i.e., become due) on or before [asOf].
/// A plan whose start_date is today returns 1 — the current cycle is in
/// progress and counts as "due now". A plan that started two months ago on a
/// monthly frequency returns 3 (months 1, 2, and the in-progress month 3).
int cyclesElapsedAsOf({
  required DateTime startDate,
  required int frequency,
  DateTime? asOf,
}) {
  final now = asOf ?? DateTime.now();
  if (now.isBefore(startDate)) return 0;
  var cycles = 0;
  var cursor = startDate;
  while (!cursor.isAfter(now)) {
    cycles++;
    cursor = SubscriptionDateCalc.advance(cursor, frequency);
  }
  return cycles;
}

/// Advance balance: how much the customer has overpaid relative to what has
/// actually accrued by [asOf]. For a 1200/month plan that started today with
/// 15000 paid, only one cycle (1200) is due so far, so advance = 13800. After
/// six months elapsed (7200 accrued), advance shrinks to 7800. Once accrued
/// catches up to paid, advance is 0 (and the customer may owe — that's the
/// outstanding-side concern, not this one).
double computeAdvanceFor({
  required DateTime startDate,
  required int frequency,
  required double amountPerCycle,
  required double totalPaid,
  DateTime? asOf,
}) {
  if (amountPerCycle <= 0 || totalPaid <= 0) return 0;
  final cycles = cyclesElapsedAsOf(startDate: startDate, frequency: frequency, asOf: asOf);
  final accrued = cycles * amountPerCycle;
  final advance = totalPaid - accrued;
  return advance < 0 ? 0 : advance;
}