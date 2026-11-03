import 'package:sqflite_sqlcipher/sqflite.dart';

import 'local_db.dart';
import 'reminder_history_dao.dart' show ReminderChannel, ReminderChannelDb;

class PendingReminder {
  PendingReminder({
    required this.id,
    this.customerId,
    this.subscriptionId,
    required this.channel,
    required this.recipient,
    required this.customerName,
    required this.amount,
    required this.dueDate,
    required this.scheduledFor,
    this.retryCount = 0,
    this.lastError,
    this.lastAttemptAt,
    required this.createdAt,
    this.messageBody,
    this.emailSubject,
  });

  final String id;
  final String? customerId;
  final String? subscriptionId;
  final ReminderChannel channel;
  final String recipient;
  final String customerName;
  final double amount;
  final DateTime dueDate;
  final DateTime scheduledFor;
  final int retryCount;
  final String? lastError;
  final DateTime? lastAttemptAt;
  final DateTime createdAt;
  /// Pre-rendered message body. Populated for [ReminderChannel.sms] and
  /// [ReminderChannel.email] entries so the offline queue replays the exact
  /// wording the user saw, even if they edit the template afterwards. Null for
  /// WhatsApp, which re-derives its body server-side.
  final String? messageBody;

  /// Pre-rendered email subject. Only populated for [ReminderChannel.email]
  /// entries; null otherwise.
  final String? emailSubject;

  Map<String, Object?> toRow() => {
        'id': id,
        'customer_id': customerId,
        'subscription_id': subscriptionId,
        'channel': channel.dbValue,
        'recipient': recipient,
        'customer_name': customerName,
        'amount': amount,
        'due_date': dueDate.toIso8601String(),
        'scheduled_for': scheduledFor.toIso8601String(),
        'retry_count': retryCount,
        'last_error': lastError,
        'last_attempt_at': lastAttemptAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'message_body': messageBody,
        'email_subject': emailSubject,
      };

  static PendingReminder fromRow(Map<String, Object?> r) => PendingReminder(
        id: r['id'] as String,
        customerId: r['customer_id'] as String?,
        subscriptionId: r['subscription_id'] as String?,
        channel: ReminderChannelDb.fromDb(r['channel'] as int),
        recipient: r['recipient'] as String,
        customerName: r['customer_name'] as String,
        amount: (r['amount'] as num).toDouble(),
        dueDate: DateTime.parse(r['due_date'] as String),
        scheduledFor: DateTime.parse(r['scheduled_for'] as String),
        retryCount: (r['retry_count'] as int?) ?? 0,
        lastError: r['last_error'] as String?,
        lastAttemptAt: (r['last_attempt_at'] as String?) == null
            ? null
            : DateTime.parse(r['last_attempt_at'] as String),
        createdAt: DateTime.parse(r['created_at'] as String),
        messageBody: r['message_body'] as String?,
        emailSubject: r['email_subject'] as String?,
      );
}

class PendingRemindersDao {
  Future<Database> _db() => LocalDb.instance.open();

  Future<void> enqueue(PendingReminder p) async {
    final db = await _db();
    await db.insert('pending_reminders', p.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<PendingReminder>> dueForSend({DateTime? asOf, int limit = 20}) async {
    final db = await _db();
    final cutoff = (asOf ?? DateTime.now()).toIso8601String();
    final rows = await db.query(
      'pending_reminders',
      where: 'scheduled_for <= ?',
      whereArgs: [cutoff],
      orderBy: 'scheduled_for ASC, created_at ASC',
      limit: limit,
    );
    return rows.map(PendingReminder.fromRow).toList();
  }

  Future<List<PendingReminder>> all() async {
    final db = await _db();
    final rows = await db.query('pending_reminders', orderBy: 'scheduled_for ASC');
    return rows.map(PendingReminder.fromRow).toList();
  }

  Future<int> count() async {
    final db = await _db();
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM pending_reminders');
    return (rows.first['c'] as int?) ?? 0;
  }

  /// True if any reminder for this subscription is currently queued. Used by
  /// the scheduler to avoid stacking duplicate sends while the existing one
  /// is still waiting to drain.
  Future<bool> hasPendingForSubscription(String subscriptionId) async {
    final db = await _db();
    final rows = await db.rawQuery(
      'SELECT 1 FROM pending_reminders WHERE subscription_id = ? LIMIT 1',
      [subscriptionId],
    );
    return rows.isNotEmpty;
  }

  /// Per-channel variant. SMS and WhatsApp/email queues are independent so a
  /// pending WhatsApp send must not block a same-day SMS dispatch.
  Future<bool> hasPendingForSubscriptionAndChannel(
    String subscriptionId,
    ReminderChannel channel,
  ) async {
    final db = await _db();
    final rows = await db.rawQuery(
      'SELECT 1 FROM pending_reminders '
      'WHERE subscription_id = ? AND channel = ? LIMIT 1',
      [subscriptionId, channel.dbValue],
    );
    return rows.isNotEmpty;
  }

  Future<void> delete(String id) async {
    final db = await _db();
    await db.delete('pending_reminders', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> recordRetry(String id, String? error) async {
    final db = await _db();
    await db.rawUpdate(
      'UPDATE pending_reminders '
      'SET retry_count = retry_count + 1, last_error = ?, last_attempt_at = ? '
      'WHERE id = ?',
      [error, DateTime.now().toIso8601String(), id],
    );
  }
}