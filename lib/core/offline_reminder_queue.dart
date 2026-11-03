import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/reminder_dispatch_api.dart';
import '../local/reminder_history_dao.dart';
import 'license_state.dart';
import 'reminder_dispatcher.dart'
    show pendingRemindersDaoProvider, reminderHistoryDaoProvider, pendingReminderCountProvider;
import 'sms_sender.dart';

/// Worker that drains the pending_reminders queue. Runs:
///   - once at startup (after license bootstrap),
///   - every 30s while the app is in foreground,
///   - on app resume (foreground from background),
///   - on demand (user-tap "Retry" or after a successful manual send).
/// The drain is idempotent and skips itself if a previous tick is still
/// in flight.
class OfflineReminderQueue {
  OfflineReminderQueue(this._ref);

  final Ref _ref;
  Timer? _timer;
  bool _draining = false;

  static const _tickInterval = Duration(seconds: 30);
  static const _maxRetries = 10;

  void start() {
    _timer ??= Timer.periodic(_tickInterval, (_) => unawaited(drain()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<int> drain() async {
    if (_draining) return 0;
    _draining = true;
    var sent = 0;
    try {
      final dao = _ref.read(pendingRemindersDaoProvider);
      final history = _ref.read(reminderHistoryDaoProvider);
      final api = _ref.read(reminderDispatchApiProvider);
      final smsSender = _ref.read(smsSenderProvider);
      final licenseKey = _ref.read(licenseControllerProvider).licenseKey;

      final batch = await dao.dueForSend();
      if (batch.isEmpty) {
        _ref.read(pendingReminderCountProvider.notifier).state = 0;
        return 0;
      }
      for (final p in batch) {
        if (p.retryCount >= _maxRetries) {
          // Give up. Move to history as failed so the user has a record.
          await history.add(LocalReminder(
            id: 'expired-${p.id}',
            customerId: p.customerId,
            subscriptionId: p.subscriptionId,
            channel: p.channel,
            recipient: p.recipient,
            messageBody: p.messageBody,
            status: 'failed',
            providerMessageId: null,
            error: 'Gave up after $_maxRetries attempts: ${p.lastError ?? "network error"}',
            sentAt: DateTime.now(),
          ));
          await dao.delete(p.id);
          continue;
        }

        // SMS goes via the device SIM — no API, no license required. We
        // dispatch SMS first so a missing license key doesn't block the SMS
        // queue (license still gates UI write actions, but a queued SMS
        // already passed that gate when the user enqueued it).
        if (p.channel == ReminderChannel.sms) {
          final body = p.messageBody;
          if (body == null || body.isEmpty) {
            // Defensive: a v1 row that somehow ended up tagged sms but
            // missing body. Drop with a permanent failure so we don't loop.
            await history.add(LocalReminder(
              id: 'fail-${p.id}',
              customerId: p.customerId,
              subscriptionId: p.subscriptionId,
              channel: p.channel,
              recipient: p.recipient,
              messageBody: null,
              status: 'failed',
              providerMessageId: null,
              error: 'Queued SMS missing message body',
              sentAt: DateTime.now(),
            ));
            await dao.delete(p.id);
            continue;
          }
          final smsResult = await smsSender.send(phone: p.recipient, body: body);
          if (smsResult.sent) {
            await history.add(LocalReminder(
              id: 'sent-${p.id}',
              customerId: p.customerId,
              subscriptionId: p.subscriptionId,
              channel: p.channel,
              recipient: p.recipient,
              messageBody: body,
              status: 'sent',
              providerMessageId: null,
              error: null,
              sentAt: DateTime.now(),
            ));
            await dao.delete(p.id);
            sent++;
          } else if (smsResult.status == SmsSendStatus.deviceError) {
            // Still no SIM / airplane mode. Bump retry, leave queued.
            await dao.recordRetry(p.id, smsResult.error);
          } else {
            // permissionDenied / platformUnsupported — won't fix itself.
            await history.add(LocalReminder(
              id: 'fail-${p.id}',
              customerId: p.customerId,
              subscriptionId: p.subscriptionId,
              channel: p.channel,
              recipient: p.recipient,
              messageBody: body,
              status: 'failed',
              providerMessageId: null,
              error: smsResult.error,
              sentAt: DateTime.now(),
            ));
            await dao.delete(p.id);
          }
          continue;
        }

        // WhatsApp / email path: requires the backend + a valid license.
        if (licenseKey == null || licenseKey.isEmpty) continue;
        final result = p.channel == ReminderChannel.whatsApp
            ? await api.sendWhatsApp(
                licenseKey: licenseKey,
                phone: p.recipient,
                customerName: p.customerName,
                amount: p.amount,
                dueDate: p.dueDate,
              )
            : await api.sendEmail(
                licenseKey: licenseKey,
                email: p.recipient,
                customerName: p.customerName,
                amount: p.amount,
                dueDate: p.dueDate,
                // Replay the snapshotted custom subject/body (null on legacy
                // rows → backend falls back to its own template).
                subject: p.emailSubject,
                body: p.messageBody,
              );

        if (result.sent) {
          await history.add(LocalReminder(
            id: 'sent-${p.id}',
            customerId: p.customerId,
            subscriptionId: p.subscriptionId,
            channel: p.channel,
            recipient: p.recipient,
            messageBody: null,
            status: 'sent',
            providerMessageId: result.messageId,
            error: null,
            sentAt: DateTime.now(),
          ));
          await dao.delete(p.id);
          sent++;
        } else if (result.networkError) {
          // Still offline — leave it queued, bump retry counter, surface
          // the latest error for the UI.
          await dao.recordRetry(p.id, result.error);
          // Stop iterating — the rest of the batch will fail the same way.
          break;
        } else {
          // Server-side rejection (bad license, invalid phone, etc.). No
          // amount of retrying will help — record as failed and drop.
          await history.add(LocalReminder(
            id: 'fail-${p.id}',
            customerId: p.customerId,
            subscriptionId: p.subscriptionId,
            channel: p.channel,
            recipient: p.recipient,
            messageBody: null,
            status: 'failed',
            providerMessageId: null,
            error: result.error,
            sentAt: DateTime.now(),
          ));
          await dao.delete(p.id);
        }
      }
      // Refresh the cached count for the badge.
      _ref.read(pendingReminderCountProvider.notifier).state = await dao.count();
    } catch (_) {
      // Any unexpected error: swallow and try again on the next tick.
    } finally {
      _draining = false;
    }
    return sent;
  }
}

final offlineReminderQueueProvider = Provider<OfflineReminderQueue>((ref) {
  final q = OfflineReminderQueue(ref);
  ref.onDispose(q.stop);
  return q;
});

/// Lifecycle observer that ticks the queue when the app comes back to the
/// foreground. Install in main.dart as a [WidgetsBindingObserver].
class OfflineQueueLifecycleObserver extends WidgetsBindingObserver {
  OfflineQueueLifecycleObserver(this._queue);
  final OfflineReminderQueue _queue;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_queue.drain());
    }
  }
}