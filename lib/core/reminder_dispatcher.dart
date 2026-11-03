import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/reminder_dispatch_api.dart';
import '../local/pending_reminders_dao.dart';
import '../local/reminder_history_dao.dart';
import 'license_state.dart';
import 'sms_sender.dart';

/// User-facing reminder send. On a connection-level failure (server down,
/// timeout) we enqueue to pending_reminders instead of recording a failure
/// in history; the OfflineReminderQueue worker will drain it once the server
/// is reachable again. Server-side failures (bad license, invalid phone) are
/// recorded in history as failed since retrying with the same payload would
/// not help.
class ReminderDispatcher {
  ReminderDispatcher(
    this._api,
    this._history,
    this._pending,
    this._readLicenseKey, {
    required SmsSender smsSender,
    this.onPendingCountChanged,
  }) : _smsSender = smsSender;

  final ReminderDispatchApi _api;
  final ReminderHistoryDao _history;
  final PendingRemindersDao _pending;
  final String? Function() _readLicenseKey;
  final SmsSender _smsSender;
  final void Function(int)? onPendingCountChanged;

  Future<ReminderSendResult> sendWhatsApp({
    required String phone,
    required String customerName,
    required double amount,
    required DateTime dueDate,
    String? customerId,
    String? subscriptionId,
    String? templateName,
  }) async {
    final key = _readLicenseKey();
    if (key == null || key.isEmpty) {
      return ReminderSendResult(status: 'failed', error: 'No license activated');
    }
    final result = await _api.sendWhatsApp(
      licenseKey: key,
      phone: phone,
      customerName: customerName,
      amount: amount,
      dueDate: dueDate,
      templateName: templateName,
    );
    await _afterApi(
      result: result,
      channel: ReminderChannel.whatsApp,
      recipient: phone,
      customerName: customerName,
      amount: amount,
      dueDate: dueDate,
      customerId: customerId,
      subscriptionId: subscriptionId,
      historyIdPrefix: 'wa',
    );
    return result;
  }

  Future<ReminderSendResult> sendEmail({
    required String email,
    required String customerName,
    required double amount,
    required DateTime dueDate,
    String? customerId,
    String? subscriptionId,
    String? templateName,
    String? subject,
    String? body,
  }) async {
    final key = _readLicenseKey();
    if (key == null || key.isEmpty) {
      return ReminderSendResult(status: 'failed', error: 'No license activated');
    }
    final result = await _api.sendEmail(
      licenseKey: key,
      email: email,
      customerName: customerName,
      amount: amount,
      dueDate: dueDate,
      templateName: templateName,
      subject: subject,
      body: body,
    );
    await _afterApi(
      result: result,
      channel: ReminderChannel.email,
      recipient: email,
      customerName: customerName,
      amount: amount,
      dueDate: dueDate,
      customerId: customerId,
      subscriptionId: subscriptionId,
      historyIdPrefix: 'em',
      // Snapshot the rendered body/subject so an offline retry sends exactly
      // what the user saw, even if they later edit the template.
      messageBody: body,
      emailSubject: subject,
    );
    return result;
  }

  /// Sends an SMS reminder using the device's default SMS SIM. Bypasses the
  /// backend API entirely — no license-key check is required since the wire
  /// goes straight from the device to the carrier. License gating still
  /// applies at the UI layer via `LicenseGuard.allowWrite`.
  ///
  /// On a `deviceError` (no SIM, airplane mode, transient modem failure) the
  /// reminder is queued to `pending_reminders` for the offline worker to
  /// retry. On `permissionDenied` / `platformUnsupported` the reminder is
  /// logged as failed in history — retrying will not help; the user must
  /// re-grant SMS permission or switch to a supported platform.
  Future<ReminderSendResult> sendSms({
    required String phone,
    required String body,
    required String customerName,
    required double amount,
    required DateTime dueDate,
    String? customerId,
    String? subscriptionId,
  }) async {
    final smsResult = await _smsSender.send(phone: phone, body: body);
    final now = DateTime.now();
    final historyId = 'sm-${now.microsecondsSinceEpoch}';

    if (smsResult.sent) {
      await _history.add(LocalReminder(
        id: historyId,
        customerId: customerId,
        subscriptionId: subscriptionId,
        channel: ReminderChannel.sms,
        recipient: phone,
        messageBody: body,
        status: 'sent',
        providerMessageId: null,
        error: null,
        sentAt: now,
      ));
      return ReminderSendResult(status: 'sent', messageId: null);
    }

    if (smsResult.status == SmsSendStatus.deviceError) {
      // Transient — queue for retry. Mirror the network-error path used for
      // WhatsApp/email in [_afterApi].
      await _pending.enqueue(PendingReminder(
        id: historyId,
        customerId: customerId,
        subscriptionId: subscriptionId,
        channel: ReminderChannel.sms,
        recipient: phone,
        customerName: customerName,
        amount: amount,
        dueDate: dueDate,
        scheduledFor: now,
        createdAt: now,
        lastError: smsResult.error,
        messageBody: body,
      ));
      onPendingCountChanged?.call(await _pending.count());
      // Surface as a network-style failure to the UI so the existing
      // "queued — will retry" snackbar copy applies cleanly.
      return ReminderSendResult(
        status: 'queued',
        error: smsResult.error,
        networkError: true,
      );
    }

    // permissionDenied / platformUnsupported — log as permanently failed.
    await _history.add(LocalReminder(
      id: historyId,
      customerId: customerId,
      subscriptionId: subscriptionId,
      channel: ReminderChannel.sms,
      recipient: phone,
      messageBody: body,
      status: 'failed',
      providerMessageId: null,
      error: smsResult.error ?? 'SMS unavailable',
      sentAt: now,
    ));
    return ReminderSendResult(status: 'failed', error: smsResult.error);
  }

  Future<void> _afterApi({
    required ReminderSendResult result,
    required ReminderChannel channel,
    required String recipient,
    required String customerName,
    required double amount,
    required DateTime dueDate,
    required String? customerId,
    required String? subscriptionId,
    required String historyIdPrefix,
    String? messageBody,
    String? emailSubject,
  }) async {
    final now = DateTime.now();
    if (result.networkError) {
      // Server unreachable — queue for later. Do NOT log to history yet; once
      // the queue drains and we get a real outcome, history records that.
      await _pending.enqueue(PendingReminder(
        id: '$historyIdPrefix-${now.microsecondsSinceEpoch}',
        customerId: customerId,
        subscriptionId: subscriptionId,
        channel: channel,
        recipient: recipient,
        customerName: customerName,
        amount: amount,
        dueDate: dueDate,
        scheduledFor: now,
        createdAt: now,
        lastError: result.error,
        messageBody: messageBody,
        emailSubject: emailSubject,
      ));
      onPendingCountChanged?.call(await _pending.count());
      return;
    }
    await _history.add(LocalReminder(
      id: '$historyIdPrefix-${now.microsecondsSinceEpoch}',
      customerId: customerId,
      subscriptionId: subscriptionId,
      channel: channel,
      recipient: recipient,
      messageBody: null,
      status: result.status,
      providerMessageId: result.messageId,
      error: result.error,
      sentAt: now,
    ));
  }
}

final reminderHistoryDaoProvider =
    Provider<ReminderHistoryDao>((_) => ReminderHistoryDao());
final pendingRemindersDaoProvider =
    Provider<PendingRemindersDao>((_) => PendingRemindersDao());

/// Cached count exposed to the UI for badging without re-querying the DB on
/// every rebuild. Updated by the dispatcher (on enqueue) and by the offline
/// queue worker (on every drain tick). Lives here, not in
/// offline_reminder_queue.dart, so the dispatcher can update it without
/// creating a circular import.
final pendingReminderCountProvider = StateProvider<int>((_) => 0);

final reminderDispatcherProvider = Provider<ReminderDispatcher>((ref) {
  final api = ref.read(reminderDispatchApiProvider);
  final history = ref.read(reminderHistoryDaoProvider);
  final pending = ref.read(pendingRemindersDaoProvider);
  final smsSender = ref.read(smsSenderProvider);
  return ReminderDispatcher(
    api,
    history,
    pending,
    () => ref.read(licenseControllerProvider).licenseKey,
    smsSender: smsSender,
    onPendingCountChanged: (n) =>
        ref.read(pendingReminderCountProvider.notifier).state = n,
  );
});