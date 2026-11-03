import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/auth_state.dart';
import '../core/currency.dart';
import '../core/feature_flags.dart';
import '../core/reminder_config.dart';
import '../core/reminder_dispatcher.dart';
import '../core/sms_template.dart';
import '../core/subscription_banner.dart';
import '../core/tab_controller.dart';
import '../api/reminder_dispatch_api.dart' show ReminderSendResult;
import '../local/dashboard_repository.dart';
import '../models/dashboard.dart';
import '../widgets/whatsapp_icon.dart';

class DashboardTab extends ConsumerWidget {
  const DashboardTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localDashboardProvider);
    final auth = ref.watch(authControllerProvider);
    // Prefer the stored Name (set during login/register from the User row).
    // Fall back to deriving from the email's local-part for sessions saved
    // before the Name field was wired through (pre-update tokens still in
    // secure storage).
    final name = auth.maybeWhen(data: (s) => s.name, orElse: () => null);
    final email = auth.maybeWhen(data: (s) => s.email, orElse: () => null);
    final greetingName = (name != null && name.isNotEmpty) ? name : _deriveName(email);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(localDashboardProvider),
          ),
        ],
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorBox(message: '$e', onRetry: () => ref.invalidate(localDashboardProvider)),
        data: (d) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(localDashboardProvider),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _GreetingCard(name: greetingName),
              const SizedBox(height: 16),
              _KpiGrid(d: d),
              const SizedBox(height: 16),
              _DueSummaryRow(
                d: d,
                onTapPill: (filter) {
                  ref.read(plansFilterProvider.notifier).state = filter;
                  ref.read(tabIndexProvider.notifier).state = AppTabs.plans;
                },
              ),
              const SizedBox(height: 16),
              _RecentOverdueCard(items: d.recentOverdue),
              const SizedBox(height: 16),
              _ReminderStatsCard(d: d),
              const SizedBox(height: 16),
              _FooterStrip(d: d),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  static String _deriveName(String? email) {
    if (email == null || email.isEmpty) return 'there';
    final local = email.split('@').first;
    if (local.isEmpty) return 'there';
    return local[0].toUpperCase() + local.substring(1);
  }
}

class _GreetingCard extends StatelessWidget {
  const _GreetingCard({required this.name});
  final String name;

  String _greetingPrefix() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd MMM yyyy');
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [scheme.primary, scheme.primary.withOpacity(0.75)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_greetingPrefix()}, $name!',
                  style: TextStyle(color: scheme.onPrimary, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  "Here's your collection overview for today.",
                  style: TextStyle(color: scheme.onPrimary.withOpacity(0.85), fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.onPrimary.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.calendar_today, size: 14, color: scheme.onPrimary),
                const SizedBox(width: 6),
                Text(
                  dateFmt.format(DateTime.now()),
                  style: TextStyle(color: scheme.onPrimary, fontWeight: FontWeight.w600, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.d});
  final DashboardSnapshot d;

  @override
  Widget build(BuildContext context) {
    final fmt = CurrencyConfig.money;
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.35,
      children: [
        _KpiCard(
          icon: Icons.account_balance,
          color: Colors.indigo,
          label: 'Total Receivable',
          value: fmt.format(d.totalReceivable),
          deltaPct: null,
          hint: '${d.activeSubscriptions} active plan${d.activeSubscriptions == 1 ? '' : 's'}',
        ),
        _KpiCard(
          icon: Icons.account_balance_wallet,
          color: Colors.green,
          label: 'Collected This Month',
          value: fmt.format(d.collectedThisMonth),
          deltaPct: d.collectionAmountChangePct,
          hint: 'vs last month',
        ),
        _KpiCard(
          icon: Icons.error_outline,
          color: Colors.orange.shade700,
          label: 'Pending Amount',
          value: fmt.format(d.pendingDuesTotal),
          deltaPct: d.pendingAmountChangePct,
          hint: 'vs last month',
          higherIsBad: true,
        ),
        _KpiCard(
          icon: Icons.schedule,
          color: Colors.red,
          label: 'Overdue',
          value: '${d.overdueSubscriptions}',
          deltaPct: null,
          hint: '${d.overdueSubscriptions == 1 ? 'plan' : 'plans'} past due',
        ),
      ],
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.deltaPct,
    required this.hint,
    this.higherIsBad = false,
  });
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final double? deltaPct;
  final String hint;
  final bool higherIsBad;

  @override
  Widget build(BuildContext context) {
    final dp = deltaPct;
    Widget? deltaChip;
    if (dp != null && dp.abs() > 0.05) {
      final isPositiveDirection = dp > 0;
      final isGood = isPositiveDirection != higherIsBad;
      final chipColor = isGood ? Colors.green : Colors.red;
      deltaChip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: chipColor.withOpacity(0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isPositiveDirection ? Icons.trending_up : Icons.trending_down, size: 12, color: chipColor),
            const SizedBox(width: 2),
            Text(
              '${dp.abs().toStringAsFixed(1)}%',
              style: TextStyle(color: chipColor, fontWeight: FontWeight.w700, fontSize: 11),
            ),
          ],
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: color, size: 18),
                ),
                const Spacer(),
                if (deltaChip != null) deltaChip,
              ],
            ),
            const SizedBox(height: 10),
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            Text(hint, style: TextStyle(color: Colors.grey.shade600, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

class _DueSummaryRow extends StatelessWidget {
  const _DueSummaryRow({required this.d, required this.onTapPill});
  final DashboardSnapshot d;
  final void Function(PlansFilter filter) onTapPill;

  @override
  Widget build(BuildContext context) {
    final pills = <_PillEntry>[
      _PillEntry(PlansFilter.overdue,
          _Pill(color: Colors.red, icon: Icons.error, label: 'Overdue', count: d.overdueSubscriptions)),
      _PillEntry(PlansFilter.dueToday,
          _Pill(color: Colors.orange, icon: Icons.today, label: 'Due Today', count: d.dueTodayCount)),
      _PillEntry(PlansFilter.thisWeek,
          _Pill(color: Colors.blue, icon: Icons.date_range, label: 'This Week', count: d.dueThisWeekCount)),
      _PillEntry(PlansFilter.upcoming,
          _Pill(color: Colors.green, icon: Icons.event_available, label: 'Upcoming', count: d.upcomingCount)),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  const Text('Payment Due Summary', style: TextStyle(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton(
                      onPressed: () => onTapPill(PlansFilter.none),
                      child: const Text('View All')),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: pills
                  .map((entry) => Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: InkWell(
                            onTap: () => onTapPill(entry.filter),
                            borderRadius: BorderRadius.circular(10),
                            child: entry.pill,
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _PillEntry {
  _PillEntry(this.filter, this.pill);
  final PlansFilter filter;
  final _Pill pill;
}

class _Pill extends StatelessWidget {
  const _Pill({required this.color, required this.icon, required this.label, required this.count});
  final Color color;
  final IconData icon;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 6),
          Text('$count', style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// Overdue list with per-row instant-send buttons. Tapping the WhatsApp or
/// email icon dispatches a reminder via the cloud /api/send-* endpoint and
/// records the result in local reminder_history.
class _RecentOverdueCard extends ConsumerStatefulWidget {
  const _RecentOverdueCard({required this.items});
  final List<OverdueItem> items;

  @override
  ConsumerState<_RecentOverdueCard> createState() => _RecentOverdueCardState();
}

class _RecentOverdueCardState extends ConsumerState<_RecentOverdueCard> {
  final Set<String> _busy = <String>{};

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.warning_amber, color: Colors.red, size: 18),
                SizedBox(width: 6),
                Text('Recent Overdue', style: TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 8),
            if (widget.items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    'Nothing overdue right now',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ),
              )
            else
              ...widget.items.map(_buildRow),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(OverdueItem it) {
    final fmt = CurrencyConfig.money;
    final hasPhone = (it.phone ?? '').isNotEmpty;
    final hasEmail = (it.email ?? '').isNotEmpty;
    final cfg = ref.watch(reminderConfigProvider).maybeWhen(
          data: (c) => c,
          orElse: () => const ReminderConfig(),
        );
    final smsEnabled = cfg.smsMode != SmsMode.disabled;
    final waBusy = _busy.contains('wa:${it.subscriptionId}');
    final emBusy = _busy.contains('em:${it.subscriptionId}');
    final smsBusy = _busy.contains('sm:${it.subscriptionId}');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: Colors.red.shade100,
            child: Text(
              it.customerName.isEmpty ? '?' : it.customerName[0].toUpperCase(),
              style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(it.customerName, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  '${it.daysOverdue} day${it.daysOverdue == 1 ? '' : 's'} overdue  -  ${it.planName}',
                  style: TextStyle(color: Colors.red.shade700, fontSize: 11),
                ),
                Text(
                  fmt.format(it.amount),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          // WhatsApp disabled app-wide (kWhatsAppEnabled).
          if (kWhatsAppEnabled)
            IconButton(
              tooltip: hasPhone ? 'Send WhatsApp reminder' : 'No phone on file',
              icon: waBusy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const WhatsAppIcon(size: 22),
              onPressed: hasPhone && !waBusy ? () => _send(it, channel: _OverdueChannel.whatsApp) : null,
            ),
          IconButton(
            tooltip: hasEmail ? 'Send email reminder' : 'No email on file',
            icon: emBusy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.email, color: Colors.blue),
            onPressed: hasEmail && !emBusy ? () => _send(it, channel: _OverdueChannel.email) : null,
          ),
          if (smsEnabled)
            IconButton(
              tooltip: hasPhone ? 'Send SMS reminder' : 'No phone on file',
              icon: smsBusy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sms, color: Colors.teal),
              onPressed: hasPhone && !smsBusy ? () => _send(it, channel: _OverdueChannel.sms) : null,
            ),
        ],
      ),
    );
  }

  Future<void> _send(OverdueItem it, {required _OverdueChannel channel}) async {
    if (!LicenseGuard.allowWrite(ref)) {
      LicenseGuard.blockWithMessage(context);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final keyPrefix = switch (channel) {
      _OverdueChannel.whatsApp => 'wa',
      _OverdueChannel.email => 'em',
      _OverdueChannel.sms => 'sm',
    };
    final key = '$keyPrefix:${it.subscriptionId}';
    setState(() => _busy.add(key));
    try {
      final dispatcher = ref.read(reminderDispatcherProvider);
      late final ReminderSendResult result;
      switch (channel) {
        case _OverdueChannel.whatsApp:
          result = await dispatcher.sendWhatsApp(
            phone: it.phone ?? '',
            customerName: it.customerName,
            amount: it.amount,
            dueDate: it.dueDate,
            customerId: it.customerId,
            subscriptionId: it.subscriptionId,
          );
          break;
        case _OverdueChannel.email:
          final emailCfg = ref.read(reminderConfigProvider).maybeWhen(
                data: (c) => c,
                orElse: () => const ReminderConfig(),
              );
          // Per-subscription reminder: {details} is this one plan's line.
          final emailDetails =
              formatOverdueDetails([(name: it.planName, amount: it.amount)]);
          result = await dispatcher.sendEmail(
            email: it.email ?? '',
            customerName: it.customerName,
            amount: it.amount,
            dueDate: it.dueDate,
            customerId: it.customerId,
            subscriptionId: it.subscriptionId,
            subject: renderMessageTemplate(emailCfg.emailSubject,
                name: it.customerName,
                amount: it.amount,
                dueDate: it.dueDate,
                plan: it.planName,
                details: emailDetails),
            body: renderMessageTemplate(emailCfg.emailTemplate,
                name: it.customerName,
                amount: it.amount,
                dueDate: it.dueDate,
                plan: it.planName,
                details: emailDetails),
          );
          break;
        case _OverdueChannel.sms:
          final cfg = ref.read(reminderConfigProvider).maybeWhen(
                data: (c) => c,
                orElse: () => const ReminderConfig(),
              );
          final body = renderMessageTemplate(
            cfg.smsTemplate,
            name: it.customerName,
            amount: it.amount,
            dueDate: it.dueDate,
            plan: it.planName,
            details: formatOverdueDetails([(name: it.planName, amount: it.amount)]),
          );
          result = await dispatcher.sendSms(
            phone: it.phone ?? '',
            body: body,
            customerName: it.customerName,
            amount: it.amount,
            dueDate: it.dueDate,
            customerId: it.customerId,
            subscriptionId: it.subscriptionId,
          );
          break;
      }
      ref.invalidate(localDashboardProvider);
      ref.read(dataRevisionProvider.notifier).state++;
      if (!mounted) return;
      final color = result.sent
          ? Colors.green.shade700
          : result.networkError
              ? Colors.orange.shade700
              : Colors.red.shade700;
      final channelLabel = switch (channel) {
        _OverdueChannel.whatsApp => 'WhatsApp',
        _OverdueChannel.email => 'Email',
        _OverdueChannel.sms => 'SMS',
      };
      final text = result.sent
          ? '$channelLabel sent to ${it.customerName}'
          : result.networkError
              ? 'Offline — queued. Will send when reachable.'
              : 'Send failed: ${result.error ?? result.status}';
      messenger.showSnackBar(SnackBar(backgroundColor: color, content: Text(text)));
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }
}

enum _OverdueChannel { whatsApp, email, sms }

class _ReminderStatsCard extends StatelessWidget {
  const _ReminderStatsCard({required this.d});
  final DashboardSnapshot d;

  @override
  Widget build(BuildContext context) {
    final segments = <_Segment>[
      _Segment('SMS', d.remindersSmsSent, Colors.teal),
      _Segment('Email', d.remindersEmailSent, Colors.blue),
      _Segment('Pending', d.remindersPending, Colors.orange),
      _Segment('Failed', d.remindersFailedThisMonth, Colors.red),
    ].where((s) => s.value > 0).toList();
    final total = d.remindersTotal;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.donut_small, color: Colors.purple, size: 18),
                SizedBox(width: 6),
                Text('Reminder Statistics', style: TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 160,
              child: total == 0
                  ? Center(
                      child: Text(
                        'No reminders yet this month',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    )
                  : Stack(
                      alignment: Alignment.center,
                      children: [
                        PieChart(
                          PieChartData(
                            sectionsSpace: 2,
                            centerSpaceRadius: 44,
                            sections: [
                              for (final s in segments)
                                PieChartSectionData(
                                  value: s.value.toDouble(),
                                  color: s.color,
                                  title: '',
                                  radius: 28,
                                ),
                            ],
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('$total', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                            const Text('Total', style: TextStyle(color: Colors.grey, fontSize: 11)),
                          ],
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                for (final s in [
                  _Segment('SMS Sent', d.remindersSmsSent, Colors.teal),
                  _Segment('Email Sent', d.remindersEmailSent, Colors.blue),
                  _Segment('Pending', d.remindersPending, Colors.orange),
                  _Segment('Failed', d.remindersFailedThisMonth, Colors.red),
                ])
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Text('${s.label}: ${s.value}', style: const TextStyle(fontSize: 11)),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Segment {
  final String label;
  final int value;
  final Color color;
  _Segment(this.label, this.value, this.color);
}

class _FooterStrip extends StatelessWidget {
  const _FooterStrip({required this.d});
  final DashboardSnapshot d;

  @override
  Widget build(BuildContext context) {
    final timeFmt = DateFormat('dd MMM  -  HH:mm');
    final updated = d.lastUpdatedUtc.toLocal();
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: _FooterStat(icon: Icons.people, label: 'Customers', value: '${d.totalCustomers}')),
                Expanded(child: _FooterStat(icon: Icons.person, label: 'Active', value: '${d.activeCustomers}')),
                Expanded(child: _FooterStat(icon: Icons.send, label: 'Sent today', value: '${d.remindersSentToday}')),
                Expanded(child: _FooterStat(icon: Icons.percent, label: 'SMS success', value: '${d.smsSuccessRatePct.toStringAsFixed(0)}%')),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.update, size: 12, color: Colors.grey.shade600),
                const SizedBox(width: 4),
                Text(
                  'Last updated ${timeFmt.format(updated)}',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FooterStat extends StatelessWidget {
  const _FooterStat({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 10)),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}