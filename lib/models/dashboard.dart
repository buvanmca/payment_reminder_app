class DashboardSnapshot {
  DashboardSnapshot({
    required this.totalCustomers,
    required this.activeSubscriptions,
    required this.collectedThisMonth,
    required this.pendingDuesTotal,
    required this.overdueSubscriptions,
    required this.remindersSentThisMonth,
    required this.remindersFailedThisMonth,
    required this.totalReceivable,
    required this.collectedLastMonth,
    required this.pendingLastMonth,
    required this.collectionAmountChangePct,
    required this.pendingAmountChangePct,
    required this.dueTodayCount,
    required this.dueThisWeekCount,
    required this.upcomingCount,
    required this.recentOverdue,
    required this.collectionTrend,
    required this.remindersWhatsAppSent,
    required this.remindersSmsSent,
    required this.remindersEmailSent,
    required this.remindersPending,
    required this.remindersDelivered,
    required this.remindersTotal,
    required this.activeCustomers,
    required this.remindersSentToday,
    required this.whatsAppSuccessRatePct,
    required this.smsSuccessRatePct,
    required this.lastUpdatedUtc,
  });

  factory DashboardSnapshot.fromJson(Map<String, dynamic> json) => DashboardSnapshot(
        totalCustomers: (json['totalCustomers'] as int?) ?? 0,
        activeSubscriptions: (json['activeSubscriptions'] as int?) ?? 0,
        collectedThisMonth: ((json['collectedThisMonth'] as num?) ?? 0).toDouble(),
        pendingDuesTotal: ((json['pendingDuesTotal'] as num?) ?? 0).toDouble(),
        overdueSubscriptions: (json['overdueSubscriptions'] as int?) ?? 0,
        remindersSentThisMonth: (json['remindersSentThisMonth'] as int?) ?? 0,
        remindersFailedThisMonth: (json['remindersFailedThisMonth'] as int?) ?? 0,
        totalReceivable: ((json['totalReceivable'] as num?) ?? 0).toDouble(),
        collectedLastMonth: ((json['collectedLastMonth'] as num?) ?? 0).toDouble(),
        pendingLastMonth: ((json['pendingLastMonth'] as num?) ?? 0).toDouble(),
        collectionAmountChangePct: ((json['collectionAmountChangePct'] as num?) ?? 0).toDouble(),
        pendingAmountChangePct: ((json['pendingAmountChangePct'] as num?) ?? 0).toDouble(),
        dueTodayCount: (json['dueTodayCount'] as int?) ?? 0,
        dueThisWeekCount: (json['dueThisWeekCount'] as int?) ?? 0,
        upcomingCount: (json['upcomingCount'] as int?) ?? 0,
        recentOverdue: ((json['recentOverdue'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(OverdueItem.fromJson)
            .toList(),
        collectionTrend: ((json['collectionTrend'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(MonthAmount.fromJson)
            .toList(),
        remindersWhatsAppSent: (json['remindersWhatsAppSent'] as int?) ?? 0,
        remindersSmsSent: (json['remindersSmsSent'] as int?) ?? 0,
        remindersEmailSent: (json['remindersEmailSent'] as int?) ?? 0,
        remindersPending: (json['remindersPending'] as int?) ?? 0,
        remindersDelivered: (json['remindersDelivered'] as int?) ?? 0,
        remindersTotal: (json['remindersTotal'] as int?) ?? 0,
        activeCustomers: (json['activeCustomers'] as int?) ?? 0,
        remindersSentToday: (json['remindersSentToday'] as int?) ?? 0,
        whatsAppSuccessRatePct: ((json['whatsAppSuccessRatePct'] as num?) ?? 0).toDouble(),
        smsSuccessRatePct: ((json['smsSuccessRatePct'] as num?) ?? 0).toDouble(),
        lastUpdatedUtc: DateTime.tryParse((json['lastUpdatedUtc'] as String?) ?? '') ??
            DateTime.now().toUtc(),
      );

  final int totalCustomers;
  final int activeSubscriptions;
  final double collectedThisMonth;
  final double pendingDuesTotal;
  final int overdueSubscriptions;
  final int remindersSentThisMonth;
  final int remindersFailedThisMonth;

  final double totalReceivable;
  final double collectedLastMonth;
  final double pendingLastMonth;
  final double collectionAmountChangePct;
  final double pendingAmountChangePct;

  final int dueTodayCount;
  final int dueThisWeekCount;
  final int upcomingCount;

  final List<OverdueItem> recentOverdue;
  final List<MonthAmount> collectionTrend;

  final int remindersWhatsAppSent;
  final int remindersSmsSent;
  final int remindersEmailSent;
  final int remindersPending;
  final int remindersDelivered;
  final int remindersTotal;

  final int activeCustomers;
  final int remindersSentToday;
  final double whatsAppSuccessRatePct;
  final double smsSuccessRatePct;
  final DateTime lastUpdatedUtc;
}

class OverdueItem {
  OverdueItem({
    required this.subscriptionId,
    required this.customerId,
    required this.customerName,
    required this.planName,
    required this.daysOverdue,
    required this.amount,
    required this.dueDate,
    this.phone,
    this.email,
  });

  factory OverdueItem.fromJson(Map<String, dynamic> json) => OverdueItem(
        subscriptionId: (json['subscriptionId'] as String?) ?? '',
        customerId: (json['customerId'] as String?) ?? '',
        customerName: (json['customerName'] as String?) ?? '',
        planName: (json['planName'] as String?) ?? '',
        daysOverdue: (json['daysOverdue'] as int?) ?? 0,
        amount: ((json['amount'] as num?) ?? 0).toDouble(),
        dueDate: DateTime.tryParse((json['dueDate'] as String?) ?? '') ??
            DateTime.now(),
        phone: json['phone'] as String?,
        email: json['email'] as String?,
      );

  final String subscriptionId;
  final String customerId;
  final String customerName;
  final String planName;
  final int daysOverdue;
  final double amount;
  final DateTime dueDate;
  final String? phone;
  final String? email;
}

class MonthAmount {
  MonthAmount({
    required this.year,
    required this.month,
    required this.label,
    required this.amount,
  });

  factory MonthAmount.fromJson(Map<String, dynamic> json) => MonthAmount(
        year: (json['year'] as int?) ?? 0,
        month: (json['month'] as int?) ?? 0,
        label: (json['label'] as String?) ?? '',
        amount: ((json['amount'] as num?) ?? 0).toDouble(),
      );

  final int year;
  final int month;
  final String label;
  final double amount;
}
