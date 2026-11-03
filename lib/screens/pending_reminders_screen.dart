import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/currency.dart';
import '../core/offline_reminder_queue.dart';
import '../core/reminder_dispatcher.dart';
import '../local/pending_reminders_dao.dart';
import '../local/reminder_history_dao.dart';
import '../widgets/whatsapp_icon.dart';

final _pendingListProvider =
    FutureProvider.autoDispose<List<PendingReminder>>((ref) async {
  return ref.read(pendingRemindersDaoProvider).all();
});

class PendingRemindersScreen extends ConsumerWidget {
  const PendingRemindersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(_pendingListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pending Reminders'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(_pendingListProvider),
          ),
        ],
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (rows) => rows.isEmpty
            ? const _EmptyState()
            : Column(
                children: [
                  const _QueueBanner(),
                  Expanded(
                    child: ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => _PendingTile(
                        item: rows[i],
                        onChanged: () => ref.invalidate(_pendingListProvider),
                      ),
                    ),
                  ),
                ],
              ),
      ),
      floatingActionButton: state.maybeWhen(
        data: (rows) => rows.isEmpty
            ? null
            : FloatingActionButton.extended(
                icon: const Icon(Icons.send),
                label: const Text('Send all now'),
                onPressed: () => _drainAll(context, ref),
              ),
        orElse: () => null,
      ),
    );
  }

  Future<void> _drainAll(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final queue = ref.read(offlineReminderQueueProvider);
    final sent = await queue.drain();
    ref.invalidate(_pendingListProvider);
    if (!context.mounted) return;
    messenger.showSnackBar(SnackBar(
      backgroundColor: sent > 0 ? Colors.green.shade700 : Colors.orange.shade700,
      content: Text(sent > 0
          ? 'Sent $sent reminder${sent == 1 ? '' : 's'}'
          : 'Could not reach server. Will retry automatically.'),
    ));
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mark_email_read_outlined,
                size: 56, color: Colors.green.shade400),
            const SizedBox(height: 12),
            const Text(
              'All caught up',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'No reminders are waiting to be sent. '
              'Anything that fails to deliver will appear here so you can retry it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade700),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueBanner extends StatelessWidget {
  const _QueueBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, color: Colors.amber.shade800, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'These reminders couldn\'t be delivered yet. '
              'They will be sent automatically once the server is reachable.',
              style: TextStyle(color: Colors.amber.shade900, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingTile extends ConsumerWidget {
  const _PendingTile({required this.item, required this.onChanged});
  final PendingReminder item;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = CurrencyConfig.money;
    final df = DateFormat('dd-MMM-yyyy HH:mm');
    final isWa = item.channel == ReminderChannel.whatsApp;
    final channelLabel = isWa ? 'WhatsApp' : 'Email';
    final waitedFor = _humanizeDuration(DateTime.now().difference(item.createdAt));

    final reasonLine = _statusMessage(
      retryCount: item.retryCount,
      lastError: item.lastError,
      lastAttemptAt: item.lastAttemptAt,
      channelLabel: channelLabel,
    );

    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            (isWa ? Colors.green : Colors.blue).withOpacity(0.15),
        child: isWa
            ? const WhatsAppIcon(size: 22)
            : const Icon(Icons.email, color: Colors.blue, size: 20),
      ),
      title: Text(
        item.customerName,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$channelLabel reminder for ${money.format(item.amount)} '
                'to ${item.recipient}'),
            const SizedBox(height: 2),
            Text(
              'Queued ${df.format(item.createdAt)} (waiting $waitedFor)',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 14, color: Colors.amber.shade800),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    reasonLine,
                    style: TextStyle(
                        color: Colors.amber.shade900,
                        fontSize: 12,
                        fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'retry') _retry(context, ref);
          if (v == 'cancel') _cancel(context, ref);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
              value: 'retry',
              child: ListTile(leading: Icon(Icons.refresh), title: Text('Retry now'))),
          PopupMenuItem(
              value: 'cancel',
              child: ListTile(
                  leading: Icon(Icons.delete_outline, color: Colors.red),
                  title: Text('Cancel'))),
        ],
      ),
    );
  }

  static String _humanizeDuration(Duration d) {
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min';
    if (d.inDays < 1) return '${d.inHours} hr';
    return '${d.inDays} day${d.inDays == 1 ? '' : 's'}';
  }

  static String _statusMessage({
    required int retryCount,
    required String? lastError,
    required DateTime? lastAttemptAt,
    required String channelLabel,
  }) {
    if (retryCount == 0 || lastAttemptAt == null) {
      return 'Waiting for the server. We\'ll send this $channelLabel '
          'reminder automatically once you\'re back online.';
    }
    final attemptsWord =
        '$retryCount attempt${retryCount == 1 ? '' : 's'} so far';
    if (lastError == null || lastError.isEmpty) {
      return 'Server unreachable - $attemptsWord. Will keep retrying in the background.';
    }
    return 'Last attempt failed ($lastError) - $attemptsWord. Will retry automatically.';
  }

  Future<void> _retry(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final sent = await ref.read(offlineReminderQueueProvider).drain();
    onChanged();
    if (!context.mounted) return;
    messenger.showSnackBar(SnackBar(
      backgroundColor: sent > 0 ? Colors.green.shade700 : Colors.orange.shade700,
      content: Text(sent > 0
          ? 'Sent $sent reminder${sent == 1 ? '' : 's'}'
          : 'Still offline. Will retry automatically.'),
    ));
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel queued reminder?'),
        content: Text('Drop the queued reminder for ${item.customerName}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(pendingRemindersDaoProvider).delete(item.id);
    final remaining = await ref.read(pendingRemindersDaoProvider).count();
    ref.read(pendingReminderCountProvider.notifier).state = remaining;
    onChanged();
  }
}