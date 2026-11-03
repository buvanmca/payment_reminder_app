import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/currency.dart';
import '../core/tab_controller.dart';
import '../local/customers_dao.dart';
import '../local/reminder_history_dao.dart';
import 'customers_tab.dart' show customersDaoProvider;
import 'reports_data.dart';
import 'reports_filter_state.dart';

final _customerListProvider = FutureProvider.autoDispose<List<LocalCustomer>>((ref) async {
  ref.watch(dataRevisionProvider);
  return ref.read(customersDaoProvider).list();
});

class ReportsTab extends ConsumerStatefulWidget {
  const ReportsTab({super.key});
  @override
  ConsumerState<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends ConsumerState<ReportsTab>
    with SingleTickerProviderStateMixin {
  late final TabController _innerTabs;
  final _searchCtrl = TextEditingController();
  bool _filtersExpanded = false;

  @override
  void initState() {
    super.initState();
    _innerTabs = TabController(length: 2, vsync: this);
    _innerTabs.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _innerTabs.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filters = ref.watch(reportFiltersProvider);
    if (_searchCtrl.text != filters.search) {
      _searchCtrl.text = filters.search;
      _searchCtrl.selection = TextSelection.fromPosition(
          TextPosition(offset: _searchCtrl.text.length));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refreshAll,
          ),
          IconButton(
            tooltip: 'Export current view as CSV',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () => _exportCurrentView(context),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: TabBar(
            controller: _innerTabs,
            isScrollable: true,
            tabs: const [
              Tab(text: 'Activity'),
              Tab(text: 'Reminders'),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          _FilterCard(
            expanded: _filtersExpanded,
            onExpand: (v) => setState(() => _filtersExpanded = v),
            searchCtrl: _searchCtrl,
          ),
          const _ActiveFilterChips(),
          Expanded(
            child: TabBarView(
              controller: _innerTabs,
              children: const [
                _ActivityView(),
                _RemindersView(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _refreshAll() {
    ref.invalidate(reportCombinedProvider);
    ref.invalidate(reportRemindersProvider);
  }

  Future<void> _exportCurrentView(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final viewIndex = _innerTabs.index;
      final csv = await _buildCsvForView(viewIndex);
      if (csv == null) {
        messenger.showSnackBar(const SnackBar(content: Text('Nothing to export')));
        return;
      }
      final filename = _filenameForView(viewIndex);
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, filename));
      await file.writeAsString(csv, flush: true);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/csv')],
        subject: 'Payment Reminder – $filename',
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text('Export failed: $e'),
      ));
    }
  }

  String _filenameForView(int i) {
    final stamp = DateFormat('yyyyMMdd-HHmm').format(DateTime.now());
    return switch (i) {
      0 => 'report-activity-$stamp.csv',
      1 => 'report-reminders-$stamp.csv',
      _ => 'report-$stamp.csv',
    };
  }

  Future<String?> _buildCsvForView(int i) async {
    final money = NumberFormat('0.00', 'en_IN');
    final df = DateFormat('yyyy-MM-dd');
    switch (i) {
      case 0:
        final rows = await ref.read(reportCombinedProvider.future);
        if (rows.isEmpty) return null;
        return _csv([
          [
            'Customer', 'Mobile', 'Email', 'Plan', 'Plan Amount',
            'Frequency (months)', 'Next Due',
            'Paid (range)', 'Payments (range)',
            'Outstanding', 'Last Payment Date', 'Last Payment Mode'
          ],
          ...rows.map((r) => [
                r.customer.name,
                r.customer.mobile,
                r.customer.email ?? '',
                r.plan.planName,
                money.format(r.plan.amount),
                '${r.plan.frequency}',
                df.format(r.plan.nextDueDate),
                money.format(r.paidInRange),
                '${r.paymentsInRange}',
                money.format(r.outstanding),
                r.lastPaymentDate == null ? '' : df.format(r.lastPaymentDate!),
                r.lastPaymentMode == null ? '' : _modeLabel(r.lastPaymentMode!),
              ]),
        ]);
      case 1:
        final rows = await ref.read(reportRemindersProvider.future);
        if (rows.isEmpty) return null;
        return _csv([
          ['Sent At', 'Customer', 'Channel', 'Recipient', 'Status', 'Error'],
          ...rows.map((r) => [
                DateFormat('yyyy-MM-dd HH:mm').format(r.reminder.sentAt),
                r.customerName,
                _channelLabel(r.reminder.channel),
                r.reminder.recipient,
                r.reminder.status,
                r.reminder.error ?? '',
              ]),
        ]);
    }
    return null;
  }

  static String _csv(List<List<String>> rows) {
    String esc(String v) {
      final needsQuote = v.contains(',') || v.contains('"') || v.contains('\n');
      final s = v.replaceAll('"', '""');
      return needsQuote ? '"$s"' : s;
    }
    return rows.map((r) => r.map(esc).join(',')).join('\n');
  }
}

String _modeLabel(int m) => switch (m) {
      PaymentMode.cash => 'Cash',
      PaymentMode.upi => 'UPI',
      PaymentMode.bank => 'Bank',
      PaymentMode.card => 'Card',
      PaymentMode.cheque => 'Cheque',
      _ => 'Other',
    };

String _channelLabel(ReminderChannel c) => switch (c) {
      ReminderChannel.whatsApp => 'WhatsApp',
      ReminderChannel.email => 'Email',
      ReminderChannel.sms => 'SMS',
    };

class _FilterCard extends ConsumerWidget {
  const _FilterCard({
    required this.expanded,
    required this.onExpand,
    required this.searchCtrl,
  });
  final bool expanded;
  final ValueChanged<bool> onExpand;
  final TextEditingController searchCtrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(reportFiltersProvider);
    final customersAsync = ref.watch(_customerListProvider);
    final df = DateFormat('dd-MMM-yyyy');
    final rangeLabel = filters.dateRange == null
        ? 'All time'
        : '${df.format(filters.dateRange!.start)}  –  ${df.format(filters.dateRange!.end)}';

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: expanded,
          onExpansionChanged: onExpand,
          leading: const Icon(Icons.filter_list),
          title: Text('Filters: $rangeLabel'),
          subtitle: filters.hasAnyFilter
              ? const Text('Tap to adjust',
                  style: TextStyle(fontSize: 11, color: Colors.grey))
              : const Text('Current month — tap to adjust',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          children: [
            // Date range picker
            InkWell(
              onTap: () => _pickDateRange(context, ref),
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Date range',
                  suffixIcon: Icon(Icons.calendar_today),
                ),
                child: Text(rangeLabel),
              ),
            ),
            const SizedBox(height: 8),
            // Customer dropdown
            customersAsync.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('Customers: $e'),
              data: (customers) => DropdownButtonFormField<String?>(
                value: filters.customerId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Customer'),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('All customers')),
                  ...customers.map((c) => DropdownMenuItem<String?>(
                        value: c.id,
                        child: Text('${c.name}  –  ${c.mobile}',
                            overflow: TextOverflow.ellipsis),
                      )),
                ],
                onChanged: (v) {
                  ref.read(reportFiltersProvider.notifier).state =
                      filters.copyWith(customerId: v);
                },
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int?>(
              value: filters.paymentMode,
              decoration: const InputDecoration(labelText: 'Payment mode'),
              items: const [
                DropdownMenuItem(value: null, child: Text('All')),
                DropdownMenuItem(value: PaymentMode.cash, child: Text('Cash')),
                DropdownMenuItem(value: PaymentMode.upi, child: Text('UPI')),
                DropdownMenuItem(value: PaymentMode.bank, child: Text('Bank')),
                DropdownMenuItem(value: PaymentMode.card, child: Text('Card')),
                DropdownMenuItem(value: PaymentMode.cheque, child: Text('Cheque')),
                DropdownMenuItem(value: PaymentMode.other, child: Text('Other')),
              ],
              onChanged: (v) {
                ref.read(reportFiltersProvider.notifier).state =
                    filters.copyWith(paymentMode: v);
              },
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<ReminderChannel?>(
              value: filters.channel,
              decoration: const InputDecoration(labelText: 'Reminder channel'),
              // WhatsApp is disabled app-wide, so it's not offered as a filter.
              items: const [
                DropdownMenuItem(value: null, child: Text('All')),
                DropdownMenuItem(
                    value: ReminderChannel.email, child: Text('Email')),
                DropdownMenuItem(
                    value: ReminderChannel.sms, child: Text('SMS')),
              ],
              onChanged: (v) {
                ref.read(reportFiltersProvider.notifier).state =
                    filters.copyWith(channel: v);
              },
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              value: filters.reminderStatus,
              decoration: const InputDecoration(labelText: 'Reminder status'),
              items: const [
                DropdownMenuItem(value: null, child: Text('All')),
                DropdownMenuItem(value: 'sent', child: Text('Sent')),
                DropdownMenuItem(value: 'failed', child: Text('Failed')),
              ],
              onChanged: (v) {
                ref.read(reportFiltersProvider.notifier).state =
                    filters.copyWith(reminderStatus: v);
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: searchCtrl,
              decoration: InputDecoration(
                labelText: 'Search (name / mobile / plan / ref)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          searchCtrl.clear();
                          ref.read(reportFiltersProvider.notifier).state =
                              filters.copyWith(search: '');
                        },
                      ),
              ),
              onChanged: (v) {
                ref.read(reportFiltersProvider.notifier).state =
                    filters.copyWith(search: v);
              },
              textInputAction: TextInputAction.search,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reset to current month'),
                  onPressed: () {
                    searchCtrl.clear();
                    ref.read(reportFiltersProvider.notifier).state =
                        ReportFilters(dateRange: currentMonthRange());
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDateRange(BuildContext context, WidgetRef ref) async {
    final filters = ref.read(reportFiltersProvider);
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: filters.dateRange,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      helpText: 'Select report period',
    );
    if (picked != null) {
      ref.read(reportFiltersProvider.notifier).state =
          filters.copyWith(dateRange: picked);
    }
  }
}

class _ActiveFilterChips extends ConsumerWidget {
  const _ActiveFilterChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(reportFiltersProvider);
    final customersAsync = ref.watch(_customerListProvider);
    final df = DateFormat('dd-MMM');
    final chips = <Widget>[];

    void clear(ReportFilters Function(ReportFilters) mutate) {
      ref.read(reportFiltersProvider.notifier).state = mutate(filters);
    }

    if (filters.dateRange != null) {
      final r = filters.dateRange!;
      chips.add(_chip(
        '${df.format(r.start)} – ${df.format(r.end)}',
        () => clear((f) => f.copyWith(dateRange: null)),
      ));
    }
    if (filters.customerId != null) {
      String label = 'Customer';
      customersAsync.whenData((list) {
        final c = list.where((c) => c.id == filters.customerId).firstOrNull;
        if (c != null) label = c.name;
      });
      chips.add(_chip(label, () => clear((f) => f.copyWith(customerId: null))));
    }
    if (filters.paymentMode != null) {
      chips.add(_chip('Mode: ${_modeLabel(filters.paymentMode!)}',
          () => clear((f) => f.copyWith(paymentMode: null))));
    }
    if (filters.channel != null) {
      chips.add(_chip('Channel: ${_channelLabel(filters.channel!)}',
          () => clear((f) => f.copyWith(channel: null))));
    }
    if (filters.reminderStatus != null) {
      chips.add(_chip('Reminder: ${filters.reminderStatus}',
          () => clear((f) => f.copyWith(reminderStatus: null))));
    }
    if (filters.search.isNotEmpty) {
      chips.add(_chip('"${filters.search}"',
          () => clear((f) => f.copyWith(search: ''))));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Wrap(spacing: 6, runSpacing: 4, children: chips),
    );
  }

  Widget _chip(String label, VoidCallback onClear) {
    return InputChip(
      label: Text(label),
      onDeleted: onClear,
      visualDensity: VisualDensity.compact,
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}


class _ActivityView extends ConsumerWidget {
  const _ActivityView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(reportCombinedProvider);
    final money = CurrencyConfig.money;
    final df = DateFormat('dd-MMM-yyyy');
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (rows) => RefreshIndicator(
        onRefresh: () async => ref.invalidate(reportCombinedProvider),
        child: rows.isEmpty
            ? const _EmptyState(message: 'No activity matches the current filters')
            : SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        minWidth: MediaQuery.of(context).size.width),
                    child: DataTable(
                      headingRowColor: WidgetStateProperty.all(
                          Theme.of(context).colorScheme.primary.withOpacity(0.08)),
                      headingTextStyle: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 12),
                      dataTextStyle: const TextStyle(fontSize: 12),
                      columnSpacing: 18,
                      horizontalMargin: 12,
                      columns: const [
                        DataColumn(label: Text('Customer')),
                        DataColumn(label: Text('Mobile')),
                        DataColumn(label: Text('Plan')),
                        DataColumn(label: Text('Amount'), numeric: true),
                        DataColumn(label: Text('Freq')),
                        DataColumn(label: Text('Next Due')),
                        DataColumn(label: Text('Paid'), numeric: true),
                        DataColumn(label: Text('# Pmts'), numeric: true),
                        DataColumn(label: Text('Outstanding'), numeric: true),
                        DataColumn(label: Text('Last Pmt')),
                        DataColumn(label: Text('Last Mode')),
                      ],
                      rows: [
                        for (final r in rows)
                          DataRow(cells: [
                            DataCell(Text(r.customer.name,
                                overflow: TextOverflow.ellipsis)),
                            DataCell(Text(r.customer.mobile)),
                            DataCell(Text(r.plan.planName,
                                overflow: TextOverflow.ellipsis)),
                            DataCell(Text(money.format(r.plan.amount))),
                            DataCell(Text('${r.plan.frequency}m')),
                            DataCell(Text(df.format(r.plan.nextDueDate))),
                            DataCell(Text(
                              money.format(r.paidInRange),
                              style: TextStyle(
                                color: r.paidInRange > 0
                                    ? Colors.green.shade700
                                    : Colors.grey,
                                fontWeight: FontWeight.w600,
                              ),
                            )),
                            DataCell(Text('${r.paymentsInRange}')),
                            DataCell(Text(
                              money.format(r.outstanding),
                              style: TextStyle(
                                color: r.outstanding > 0
                                    ? Colors.red.shade700
                                    : Colors.grey,
                                fontWeight: FontWeight.w600,
                              ),
                            )),
                            DataCell(Text(r.lastPaymentDate == null
                                ? '—'
                                : df.format(r.lastPaymentDate!))),
                            DataCell(Text(r.lastPaymentMode == null
                                ? '—'
                                : _modeLabel(r.lastPaymentMode!))),
                          ]),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

}


class _RemindersView extends ConsumerStatefulWidget {
  const _RemindersView();
  @override
  ConsumerState<_RemindersView> createState() => _RemindersViewState();
}

class _RemindersViewState extends ConsumerState<_RemindersView> {
  // Ids of reminder-history rows the user has ticked for deletion. Pruned in
  // build() to whatever is currently visible so the count and select-all
  // checkbox always reflect the active filters.
  final Set<String> _selected = {};

  Future<void> _deleteSelected(List<ReminderReportRow> visible) async {
    final ids = visible
        .map((r) => r.reminder.id)
        .where(_selected.contains)
        .toList();
    if (ids.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete reminders?'),
        content: Text(
          'This will permanently delete ${ids.length} reminder '
          'record${ids.length == 1 ? '' : 's'}. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final removed =
          await ref.read(reminderHistoryDaoProvider).deleteByIds(ids);
      if (!mounted) return;
      setState(() => _selected.clear());
      ref.invalidate(reportRemindersProvider);
      // Reminder rows feed the report summary and dashboard counters; bump the
      // shared revision so every dependent view recomputes after the delete.
      ref.read(dataRevisionProvider.notifier).state++;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content:
            Text('Deleted $removed reminder${removed == 1 ? '' : 's'}'),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text('Delete failed: $e'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(reportRemindersProvider);
    final df = DateFormat('dd-MMM-yyyy HH:mm');
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (rows) {
        // Drop any selected ids that are no longer present (deleted, or hidden
        // by a filter change) so we never delete off-screen rows.
        final visibleIds = {for (final r in rows) r.reminder.id};
        _selected.retainWhere(visibleIds.contains);

        if (rows.isEmpty) {
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(reportRemindersProvider),
            child: const _EmptyState(
                message: 'No reminders in the selected period'),
          );
        }

        return Column(
          children: [
            if (_selected.isNotEmpty)
              _SelectionBar(
                count: _selected.length,
                onClear: () => setState(_selected.clear),
                onDelete: () => _deleteSelected(rows),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async =>
                    ref.invalidate(reportRemindersProvider),
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          minWidth: MediaQuery.of(context).size.width),
                      child: DataTable(
                        headingRowColor: WidgetStateProperty.all(
                            Theme.of(context)
                                .colorScheme
                                .primary
                                .withOpacity(0.08)),
                        headingTextStyle: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 12),
                        dataTextStyle: const TextStyle(fontSize: 12),
                        columnSpacing: 18,
                        horizontalMargin: 12,
                        // Header checkbox selects/clears every visible row.
                        onSelectAll: (v) {
                          setState(() {
                            if (v == true) {
                              _selected
                                ..clear()
                                ..addAll(visibleIds);
                            } else {
                              _selected.clear();
                            }
                          });
                        },
                        columns: const [
                          DataColumn(label: Text('Sent At')),
                          DataColumn(label: Text('Customer')),
                          DataColumn(label: Text('Channel')),
                          DataColumn(label: Text('Recipient')),
                          DataColumn(label: Text('Status')),
                          DataColumn(label: Text('Error')),
                        ],
                        rows: [
                          for (final r in rows)
                            DataRow(
                              selected: _selected.contains(r.reminder.id),
                              onSelectChanged: (v) {
                                setState(() {
                                  if (v == true) {
                                    _selected.add(r.reminder.id);
                                  } else {
                                    _selected.remove(r.reminder.id);
                                  }
                                });
                              },
                              cells: [
                                DataCell(Text(df.format(r.reminder.sentAt))),
                                DataCell(Text(r.customerName,
                                    overflow: TextOverflow.ellipsis)),
                                DataCell(Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      switch (r.reminder.channel) {
                                        ReminderChannel.email => Icons.email,
                                        ReminderChannel.sms => Icons.sms,
                                        ReminderChannel.whatsApp => Icons.chat,
                                      },
                                      size: 14,
                                      color: Colors.grey.shade700,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(_channelLabel(r.reminder.channel)),
                                  ],
                                )),
                                DataCell(Text(r.reminder.recipient,
                                    overflow: TextOverflow.ellipsis)),
                                DataCell(Text(
                                  r.reminder.status.toUpperCase(),
                                  style: TextStyle(
                                    color: r.reminder.status == 'sent'
                                        ? Colors.green.shade700
                                        : Colors.red.shade700,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11,
                                  ),
                                )),
                                DataCell(SizedBox(
                                  width: 200,
                                  child: Text(
                                    r.reminder.error ?? '—',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                )),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Contextual action bar shown above the Reminders grid while one or more rows
/// are selected. Lets the user clear the selection or bulk-delete it.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onClear,
    required this.onDelete,
  });
  final int count;
  final VoidCallback onClear;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.primary.withOpacity(0.10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Text(
              '$count selected',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            TextButton(onPressed: onClear, child: const Text('Clear')),
            const SizedBox(width: 8),
            FilledButton.icon(
              style:
                  FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 80),
        Icon(Icons.inbox_outlined, size: 56, color: Colors.grey.shade400),
        const SizedBox(height: 12),
        Center(
          child: Text(message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600)),
        ),
      ],
    );
  }
}
