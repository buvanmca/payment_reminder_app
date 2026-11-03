import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local/customers_dao.dart';
import '../local/subscriptions_dao.dart';
import '../screens/customers_tab.dart' show customersDaoProvider, subscriptionsDaoProvider;
import 'feature_flags.dart';
import 'reminder_config.dart';
import 'reminder_dispatcher.dart';
import 'sms_sender.dart';
import 'sms_template.dart';

/// Local reminder scheduler — replaces the deleted backend Hangfire cron.
///
/// Behavior matches the previous server-side ReminderJob, configured by the
/// user via Settings -> Reminder Configuration:
///   - At each tick (every 60s while in foreground, plus on app resume), if
///     "now" is at or after the configured send time today AND today is not
///     filtered out by `weekdaysOnly`, scan all active subscriptions.
///   - For each subscription, decide if today is a reminder day:
///       * pre-due: daysUntilDue is in cfg.daysBeforeDue
///       * on due:  daysUntilDue == 0 and cfg.sendOnDueDate
///       * overdue: daysOverdue % cfg.overdueRepeatEveryDays == 0
///                  AND followUpsSent < cfg.overdueMaxFollowUps
///   - Dedupe: skip if reminder_history already has a send for this sub
///     today, or pending_reminders has one queued.
///   - Dispatch via ReminderDispatcher (auto-queues on offline).
///
/// Foreground-only: this runs while the app is open. If the app is closed
/// at the configured send hour, the scheduler catches up the moment it's
/// next opened (since the "send time" check is `now >= sendTimeToday` and
/// dedupe is on `today >= midnight`).
class ReminderScheduler {
  ReminderScheduler(this._ref);

  final Ref _ref;
  Timer? _timer;
  bool _ticking = false;

  static const _interval = Duration(seconds: 60);

  void start() {
    _timer ??= Timer.periodic(_interval, (_) => unawaited(tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final cfg = _ref.read(reminderConfigProvider.notifier).current;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final scheduledTimeToday =
          DateTime(today.year, today.month, today.day, cfg.sendHour, cfg.sendMinute);

      // Wait until the configured send time has passed today.
      if (now.isBefore(scheduledTimeToday)) return;

      if (cfg.weekdaysOnly &&
          (today.weekday == DateTime.saturday || today.weekday == DateTime.sunday)) {
        return;
      }

      final subsDao = _ref.read(subscriptionsDaoProvider);
      final customersDao = _ref.read(customersDaoProvider);
      final history = _ref.read(reminderHistoryDaoProvider);
      final pending = _ref.read(pendingRemindersDaoProvider);
      final dispatcher = _ref.read(reminderDispatcherProvider);
      final smsSender = _ref.read(smsSenderProvider);

      final subs = await subsDao.list();
      for (final sub in subs) {
        // status: 1 = Active. Cancelled (3) / Paused (2) skip.
        if (sub.status != 1) continue;

        // Don't sweep up plans created in TODAY's send window. The
        // "catch-up after configured time" branch above is meant to handle
        // plans the scheduler already knew about when the app was closed —
        // not to retroactively fire on a plan that was just created
        // moments ago. Without this guard a plan saved at 9:30am (with a
        // 9:00am send time) would trigger a WhatsApp/email reminder on
        // the very next 60s tick, which users perceive as "the app sent a
        // reminder the instant I created the plan". Manual sends from the
        // customer/dashboard tabs go through the dispatcher directly and
        // are unaffected.
        if (sub.createdAt.isAfter(scheduledTimeToday)) continue;

        final due = DateTime(
            sub.nextDueDate.year, sub.nextDueDate.month, sub.nextDueDate.day);
        final daysUntilDue = due.difference(today).inDays;

        var trigger = false;
        if (daysUntilDue > 0 && cfg.daysBeforeDue.contains(daysUntilDue)) {
          trigger = true;
        } else if (daysUntilDue == 0 && cfg.sendOnDueDate) {
          trigger = true;
        } else if (daysUntilDue < 0) {
          final daysOverdue = -daysUntilDue;
          if (cfg.overdueRepeatEveryDays > 0 &&
              daysOverdue % cfg.overdueRepeatEveryDays == 0) {
            final followUps = await history.countSentForSubscriptionAfter(sub.id, due);
            if (followUps < cfg.overdueMaxFollowUps) trigger = true;
          }
        }
        if (!trigger) continue;

        // Already sent or queued today? skip.
        if (await history.hasSendForSubscriptionAfter(sub.id, today)) continue;
        if (await pending.hasPendingForSubscription(sub.id)) continue;

        final customer = await customersDao.get(sub.customerId);
        if (customer == null || !customer.isActive) continue;

        // Reminder amount must reflect advance / partial payments, not the
        // raw plan price. A 1000-rs plan with 1500 paid in June leaves 500
        // outstanding for July; the reminder should ask for 500, not 1000.
        // Defensive: skip when nothing is owed (e.g., full advance covers the
        // upcoming cycle exactly).
        final outstanding = await subsDao.outstandingForSubscription(sub.id);
        if (outstanding <= 0) continue;

        await _dispatchForChannel(
          dispatcher: dispatcher,
          channel: cfg.channel,
          smsMode: cfg.smsMode,
          smsTemplate: cfg.smsTemplate,
          emailSubject: cfg.emailSubject,
          emailTemplate: cfg.emailTemplate,
          smsSender: smsSender,
          sub: sub,
          customer: customer,
          amount: outstanding,
        );
      }
    } catch (_) {
      // Swallow tick errors so the next tick still runs. Individual send
      // failures already get recorded by the dispatcher.
    } finally {
      _ticking = false;
    }
  }

  Future<void> _dispatchForChannel({
    required ReminderDispatcher dispatcher,
    required ReminderChannel channel,
    required SmsMode smsMode,
    required String smsTemplate,
    required String emailSubject,
    required String emailTemplate,
    required SmsSender smsSender,
    required LocalSubscription sub,
    required LocalCustomer customer,
    required double amount,
  }) async {
    final hasPhone = customer.mobile.isNotEmpty;
    final hasEmail = (customer.email ?? '').isNotEmpty;
    // This is a per-subscription reminder, so {details} is a single line for
    // this plan (keeps shared templates that use {details} rendering cleanly).
    final details =
        formatOverdueDetails([(name: sub.planName, amount: amount)]);

    Future<void> sendWa() => dispatcher
        .sendWhatsApp(
          phone: customer.mobile,
          customerName: customer.name,
          amount: amount,
          dueDate: sub.nextDueDate,
          customerId: customer.id,
          subscriptionId: sub.id,
        )
        .then((_) {});
    Future<void> sendEm() => dispatcher
        .sendEmail(
          email: customer.email!,
          customerName: customer.name,
          amount: amount,
          dueDate: sub.nextDueDate,
          customerId: customer.id,
          subscriptionId: sub.id,
          // Render the user's custom email template on-device, same as SMS.
          subject: renderMessageTemplate(emailSubject,
              name: customer.name,
              amount: amount,
              dueDate: sub.nextDueDate,
              plan: sub.planName,
              details: details),
          body: renderMessageTemplate(emailTemplate,
              name: customer.name,
              amount: amount,
              dueDate: sub.nextDueDate,
              plan: sub.planName,
              details: details),
        )
        .then((_) {});

    // WhatsApp is disabled app-wide (feature_flags.kWhatsAppEnabled). When off,
    // a config still persisted as whatsapp/both must never auto-send WhatsApp —
    // fall back to email only so the scheduler stays consistent with the UI.
    switch (channel) {
      case ReminderChannel.whatsapp:
        if (kWhatsAppEnabled && hasPhone) {
          await sendWa();
        } else if (!kWhatsAppEnabled && hasEmail) {
          await sendEm();
        }
        break;
      case ReminderChannel.email:
        if (hasEmail) await sendEm();
        break;
      case ReminderChannel.both:
        if (kWhatsAppEnabled && hasPhone) await sendWa();
        if (hasEmail) await sendEm();
        break;
    }

    // Layered SMS dispatch — independent of `channel`. Only the `automatic`
    // mode fires from the scheduler; `instant` is purely user-triggered.
    // We deliberately do NOT call requestPermission here — runtime prompts
    // must originate from a user gesture; missing permission is a no-op
    // here and surfaces in the UI via the SMS section in Reminder
    // Configuration.
    if (smsMode == SmsMode.automatic && hasPhone) {
      final granted = await smsSender.hasPermission();
      if (!granted) return;
      final body = renderMessageTemplate(
        smsTemplate,
        name: customer.name,
        amount: amount,
        dueDate: sub.nextDueDate,
        plan: sub.planName,
        details: details,
      );
      await dispatcher.sendSms(
        phone: customer.mobile,
        body: body,
        customerName: customer.name,
        amount: amount,
        dueDate: sub.nextDueDate,
        customerId: customer.id,
        subscriptionId: sub.id,
      );
    }
  }
}

final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  final s = ReminderScheduler(ref);
  ref.onDispose(s.stop);
  return s;
});

/// Lifecycle observer that ticks the scheduler when the app comes back to
/// the foreground (in addition to the regular 60s timer). Pair with the
/// [OfflineQueueLifecycleObserver] in main.dart.
class ReminderSchedulerLifecycleObserver extends WidgetsBindingObserver {
  ReminderSchedulerLifecycleObserver(this._scheduler);
  final ReminderScheduler _scheduler;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_scheduler.tick());
    }
  }
}