import 'package:sqflite_sqlcipher/sqflite.dart';

import 'local_db.dart';

enum ReminderChannel { whatsApp, email, sms }

extension ReminderChannelDb on ReminderChannel {
  int get dbValue => switch (this) {
        ReminderChannel.whatsApp => 1,
        ReminderChannel.email => 2,
        ReminderChannel.sms => 3,
      };
  static ReminderChannel fromDb(int v) => switch (v) {
        2 => ReminderChannel.email,
        3 => ReminderChannel.sms,
        _ => ReminderChannel.whatsApp,
      };
}

class LocalReminder {
  LocalReminder({
    required this.id,
    this.customerId,
    this.subscriptionId,
    required this.channel,
    required this.recipient,
    this.messageBody,
    required this.status,
    this.providerMessageId,
    this.error,
    required this.sentAt,
  });

  final String id;
  final String? customerId;
  final String? subscriptionId;
  final ReminderChannel channel;
  final String recipient;
  final String? messageBody;
  final String status;
  final String? providerMessageId;
  final String? error;
  final DateTime sentAt;

  Map<String, Object?> toRow() => {
        'id': id,
        'customer_id': customerId,
        'subscription_id': subscriptionId,
        'channel': channel.dbValue,
        'recipient': recipient,
        'message_body': messageBody,
        'status': status,
        'provider_message_id': providerMessageId,
        'error': error,
        'sent_at': sentAt.toIso8601String(),
      };

  static LocalReminder fromRow(Map<String, Object?> r) => LocalReminder(
        id: r['id'] as String,
        customerId: r['customer_id'] as String?,
        subscriptionId: r['subscription_id'] as String?,
        channel: ReminderChannelDb.fromDb(r['channel'] as int),
        recipient: r['recipient'] as String,
        messageBody: r['message_body'] as String?,
        status: r['status'] as String,
        providerMessageId: r['provider_message_id'] as String?,
        error: r['error'] as String?,
        sentAt: DateTime.parse(r['sent_at'] as String),
      );
}

class ReminderHistoryDao {
  Future<Database> _db() => LocalDb.instance.open();

  Future<void> add(LocalReminder r) async {
    final db = await _db();
    await db.insert('reminder_history', r.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<LocalReminder>> list({int limit = 100, String? customerId}) async {
    final db = await _db();
    final rows = customerId == null
        ? await db.query('reminder_history', orderBy: 'sent_at DESC', limit: limit)
        : await db.query('reminder_history',
            where: 'customer_id = ?',
            whereArgs: [customerId],
            orderBy: 'sent_at DESC',
            limit: limit);
    return rows.map(LocalReminder.fromRow).toList();
  }

  /// Permanently deletes the reminder-history rows with the given [ids] and
  /// returns the number of rows removed. Drives the Reports screen's
  /// multi-select delete. Deletes in chunks so a large "select all" stays well
  /// under SQLite's bound-variable limit (~999 per statement).
  Future<int> deleteByIds(List<String> ids) async {
    if (ids.isEmpty) return 0;
    final db = await _db();
    var deleted = 0;
    const chunkSize = 500;
    for (var i = 0; i < ids.length; i += chunkSize) {
      final end = (i + chunkSize) < ids.length ? i + chunkSize : ids.length;
      final slice = ids.sublist(i, end);
      final placeholders = List.filled(slice.length, '?').join(',');
      deleted += await db.delete(
        'reminder_history',
        where: 'id IN ($placeholders)',
        whereArgs: slice,
      );
    }
    return deleted;
  }

  Future<Map<String, int>> statusCountsLast30Days() async {
    final db = await _db();
    final cutoff = DateTime.now().subtract(const Duration(days: 30)).toIso8601String();
    final rows = await db.rawQuery(
      'SELECT status, COUNT(*) AS c FROM reminder_history WHERE sent_at >= ? GROUP BY status',
      [cutoff],
    );
    return {for (final r in rows) r['status'] as String: (r['c'] as int?) ?? 0};
  }

  /// True if any reminder (sent or pending-failed) was logged for this
  /// subscription after the given cutoff. Used by the scheduler to avoid
  /// double-sending today's reminder.
  Future<bool> hasSendForSubscriptionAfter(String subscriptionId, DateTime after) async {
    final db = await _db();
    final rows = await db.rawQuery(
      'SELECT 1 FROM reminder_history '
      'WHERE subscription_id = ? AND sent_at >= ? LIMIT 1',
      [subscriptionId, after.toIso8601String()],
    );
    return rows.isNotEmpty;
  }

  /// Number of successful sends for this subscription after the given cutoff.
  /// Used by the scheduler to enforce overdue follow-up max counts.
  Future<int> countSentForSubscriptionAfter(String subscriptionId, DateTime after) async {
    final db = await _db();
    final rows = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM reminder_history "
      "WHERE subscription_id = ? AND sent_at >= ? AND status = 'sent'",
      [subscriptionId, after.toIso8601String()],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// Per-channel variant of [hasSendForSubscriptionAfter]. The scheduler uses
  /// this so that an SMS dispatch does not suppress a same-day WhatsApp/email
  /// dispatch for the same subscription (or vice versa). Channels are
  /// independent retry tracks.
  Future<bool> hasSendForSubscriptionAndChannelAfter(
    String subscriptionId,
    ReminderChannel channel,
    DateTime after,
  ) async {
    final db = await _db();
    final rows = await db.rawQuery(
      'SELECT 1 FROM reminder_history '
      'WHERE subscription_id = ? AND channel = ? AND sent_at >= ? LIMIT 1',
      [subscriptionId, channel.dbValue, after.toIso8601String()],
    );
    return rows.isNotEmpty;
  }
}