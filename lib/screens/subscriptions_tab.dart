import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/currency.dart';
import '../core/subscription_banner.dart';
import '../core/tab_controller.dart';
import '../local/customers_dao.dart';
import '../local/plans_dao.dart';
import '../local/subscription_date_calc.dart';
import '../local/subscriptions_dao.dart';
import 'customers_tab.dart' show customersDaoProvider, subscriptionsDaoProvider;
import 'plans_catalog_screen.dart';

class _SubRow {
  _SubRow(this.subscription, this.customerName);
  final LocalSubscription subscription;
  final String customerName;

  int daysUntilDue(DateTime today) =>
      subscription.nextDueDate.difference(today).inDays;
}

final _subsProvider = FutureProvider.autoDispose<List<_SubRow>>((ref) async {
  ref.watch(dataRevisionProvider);
  final subs = await ref.read(subscriptionsDaoProvider).list();
  final customersDao = ref.read(customersDaoProvider);
  final cache = <String, String>{};
  final out = <_SubRow>[];
  for (final s in subs) {
    var name = cache[s.customerId];
    if (name == null) {
      final c = await customersDao.get(s.customerId);
      name = c?.name ?? '(unknown)';
      cache[s.customerId] = name;
    }
    out.add(_SubRow(s, name));
  }
  return out;
});

bool _matchesFilter(_SubRow row, PlansFilter filter, DateTime today) {
  if (filter == PlansFilter.none) return true;
  // Cancelled plans never match Due Summary buckets.
  if (row.subscription.status == 3) return false;
  // Active only.
  if (row.subscription.status != 1) return false;
  final due = DateTime(row.subscription.nextDueDate.year,
      row.subscription.nextDueDate.month, row.subscription.nextDueDate.day);
  final daysUntilDue = due.difference(today).inDays;
  return switch (filter) {
    PlansFilter.overdue => daysUntilDue < 0,
    PlansFilter.dueToday => daysUntilDue == 0,
    PlansFilter.thisWeek => daysUntilDue >= 0 && daysUntilDue < 7,
    PlansFilter.upcoming => daysUntilDue >= 7,
    PlansFilter.none => true,
  };
}

String _filterLabel(PlansFilter f) => switch (f) {
      PlansFilter.overdue => 'Overdue',
      PlansFilter.dueToday => 'Due today',
      PlansFilter.thisWeek => 'Due this week',
      PlansFilter.upcoming => 'Upcoming',
      PlansFilter.none => '',
    };

class SubscriptionsTab extends ConsumerStatefulWidget {
  const SubscriptionsTab({super.key});

  @override
  ConsumerState<SubscriptionsTab> createState() => _SubscriptionsTabState();
}

class _SubscriptionsTabState extends ConsumerState<SubscriptionsTab> {
  /// IDs of plans selected for a bulk delete. Non-empty => selection mode.
  final Set<String> _selected = <String>{};
  bool get _selectionMode => _selected.isNotEmpty;

  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _confirmDeleteSelected(BuildContext context) async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${ids.length} plan${ids.length == 1 ? "" : "s"}?'),
        content: const Text(
          'The selected plans will be removed permanently. '
          'All payments recorded under them will also be deleted. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      // FK CASCADE removes each plan's payments automatically.
      final dao = ref.read(subscriptionsDaoProvider);
      for (final id in ids) {
        await dao.delete(id);
      }
      _clearSelection();
      ref.invalidate(_subsProvider);
      ref.read(dataRevisionProvider.notifier).state++;
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Text('Deleted ${ids.length} plan${ids.length == 1 ? "" : "s"}'),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
        content: Text('Delete failed: $e'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(_subsProvider);
    final filter = ref.watch(plansFilterProvider);
    final money = CurrencyConfig.money;
    final df = DateFormat('dd-MMM-yyyy');
    final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

    return Scaffold(
      appBar: _selectionMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Clear selection',
                onPressed: _clearSelection,
              ),
              title: Text('${_selected.length} selected'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.delete),
                  tooltip: 'Delete selected',
                  onPressed: () => _confirmDeleteSelected(context),
                ),
              ],
            )
          : AppBar(
        title: const Text('Plans'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt_outlined),
            tooltip: 'Manage plans',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PlansCatalogScreen()),
            ),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(_subsProvider)),
        ],
        bottom: filter == PlansFilter.none
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    children: [
                      Chip(
                        label: Text('Filter: ${_filterLabel(filter)}'),
                        onDeleted: () =>
                            ref.read(plansFilterProvider.notifier).state = PlansFilter.none,
                        deleteIcon: const Icon(Icons.close, size: 16),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (allRows) {
          final rows = allRows.where((r) => _matchesFilter(r, filter, today)).toList();
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(_subsProvider),
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      filter == PlansFilter.none
                          ? 'No plans yet'
                          : 'No plans match: ${_filterLabel(filter)}',
                    ),
                  )
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = rows[i];
                      final s = r.subscription;
                      final daysUntilDue = r.daysUntilDue(today);
                      final overdue = daysUntilDue < 0;
                      final cancelled = s.status == 3;
                      final selected = _selected.contains(s.id);
                      return ListTile(
                        selected: selected,
                        onLongPress: () => _toggleSelected(s.id),
                        onTap: _selectionMode
                            ? () => _toggleSelected(s.id)
                            : (cancelled ? null : () => _openSubscriptionDialog(context, ref, existing: r)),
                        leading: _selectionMode
                            ? Checkbox(
                                value: selected,
                                onChanged: (_) => _toggleSelected(s.id),
                              )
                            : const Icon(Icons.subscriptions),
                        title: Text('${r.customerName}  -  ${s.planName}'),
                        subtitle: Text(
                          '${money.format(s.amount)} ${_freqLabel(s.frequency)}  -  Due ${df.format(s.nextDueDate)}'
                          '${cancelled ? "  -  Cancelled" : ""}',
                        ),
                        trailing: _selectionMode
                            ? null
                            : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              cancelled
                                  ? '-'
                                  : (overdue ? '${-daysUntilDue}d overdue' : '${daysUntilDue}d'),
                              style: TextStyle(
                                color: cancelled
                                    ? Colors.grey
                                    : (overdue ? Colors.red : Colors.green.shade700),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: 'Actions',
                              onSelected: (v) {
                                if (v == 'edit') _openSubscriptionDialog(context, ref, existing: r);
                                if (v == 'cancel') _confirmCancel(context, ref, r);
                                if (v == 'delete') _confirmDelete(context, ref, r);
                              },
                              itemBuilder: (_) => [
                                if (!cancelled)
                                  const PopupMenuItem(
                                      value: 'edit',
                                      child: ListTile(leading: Icon(Icons.edit), title: Text('Edit'))),
                                if (!cancelled)
                                  const PopupMenuItem(
                                      value: 'cancel',
                                      child: ListTile(
                                          leading: Icon(Icons.cancel, color: Colors.orange),
                                          title: Text('Cancel plan'))),
                                const PopupMenuItem(
                                    value: 'delete',
                                    child: ListTile(
                                        leading: Icon(Icons.delete_forever, color: Colors.red),
                                        title: Text('Delete'))),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          );
        },
      ),
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('New plan'),
              onPressed: () {
                if (!LicenseGuard.allowWrite(ref)) {
                  LicenseGuard.blockWithMessage(context);
                  return;
                }
                _openSubscriptionDialog(context, ref);
              },
            ),
    );
  }

  static String _freqLabel(int f) => switch (f) {
        1 => 'Monthly',
        2 => 'Quarterly',
        3 => 'Half Yearly',
        4 => 'Yearly',
        _ => 'Monthly',
      };

  Future<void> _openSubscriptionDialog(
    BuildContext context,
    WidgetRef ref, {
    _SubRow? existing,
  }) async {
    final isEdit = existing != null;
    final allCustomers = await ref.read(customersDaoProvider).list();
    if (!context.mounted) return;
    // New plans may only be created for active customers — an inactive
    // customer is paused, so we don't start a new billing relationship for
    // them. On edit we keep the full list so the existing customer still
    // resolves even if they were deactivated after the plan was created.
    final customers =
        isEdit ? allCustomers : allCustomers.where((c) => c.isActive).toList();
    if (customers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(allCustomers.isEmpty
              ? 'Add a customer first'
              : 'No active customers. Activate a customer before creating a plan.'),
        ),
      );
      return;
    }
    LocalCustomer? selected = isEdit
        ? customers.firstWhere(
            (c) => c.id == existing.subscription.customerId,
            orElse: () => customers.first,
          )
        : customers.first;
    final plans = await ref.read(plansDaoProvider).list(activeOnly: true);
    if (!context.mounted) return;
    if (plans.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Add a plan first'),
          action: SnackBarAction(
            label: 'Manage plans',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PlansCatalogScreen()),
            ),
          ),
        ),
      );
      return;
    }

    // Preselect the plan on edit: by plan_id, falling back to a name match for
    // legacy rows created before the catalog existed.
    LocalPlan? selectedPlan;
    final exSub = existing?.subscription;
    if (exSub != null) {
      for (final p in plans) {
        if (p.id == exSub.planId) {
          selectedPlan = p;
          break;
        }
      }
      if (selectedPlan == null) {
        for (final p in plans) {
          if (p.name.toLowerCase() == exSub.planName.toLowerCase()) {
            selectedPlan = p;
            break;
          }
        }
      }
    }

    final money =
        CurrencyConfig.money;
    final amount = TextEditingController(
      text: existing != null ? existing.subscription.amount.toStringAsFixed(0) : '',
    );
    int frequency =
        existing?.subscription.frequency ?? selectedPlan?.frequency ?? 1;
    DateTime startDate = existing?.subscription.startDate ?? DateTime.now();
    final formKey = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(isEdit ? 'Edit plan' : 'Create plan'),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<LocalCustomer>(
                    value: selected,
                    items: customers
                        .map((c) => DropdownMenuItem(value: c, child: Text(c.name)))
                        .toList(),
                    onChanged: isEdit ? null : (c) => setLocal(() => selected = c),
                    decoration: const InputDecoration(labelText: 'Customer'),
                    disabledHint: selected != null ? Text(selected!.name) : null,
                  ),
                  DropdownButtonFormField<LocalPlan>(
                    value: selectedPlan,
                    isExpanded: true,
                    items: plans
                        .map((p) => DropdownMenuItem(
                              value: p,
                              child: Text(
                                '${p.name}  -  ${money.format(p.amount)} ${_freqLabel(p.frequency)}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: (p) => setLocal(() {
                      selectedPlan = p;
                      // Selecting a plan auto-fills amount & frequency from the
                      // catalog template; amount stays editable for overrides.
                      if (p != null) {
                        amount.text = p.amount.toStringAsFixed(0);
                        frequency = p.frequency;
                      }
                    }),
                    decoration: const InputDecoration(labelText: 'Plan'),
                    validator: (v) => v == null ? 'Select a plan' : null,
                  ),
                  TextFormField(
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Amount'),
                    validator: (v) {
                      final d = double.tryParse(v ?? '');
                      return (d == null || d <= 0) ? 'Enter amount greater than 0' : null;
                    },
                  ),
                  DropdownButtonFormField<int>(
                    value: frequency,
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('Monthly')),
                      DropdownMenuItem(value: 2, child: Text('Quarterly')),
                      DropdownMenuItem(value: 3, child: Text('Half Yearly')),
                      DropdownMenuItem(value: 4, child: Text('Yearly')),
                    ],
                    onChanged: (v) => setLocal(() => frequency = v ?? 1),
                    decoration: const InputDecoration(labelText: 'Frequency'),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Start date'),
                    subtitle: Text(DateFormat('dd-MMM-yyyy').format(startDate)),
                    trailing: const Icon(Icons.calendar_today, size: 18),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: startDate,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setLocal(() => startDate = picked);
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
              },
              child: const Text('Save'),
            ),
          ],
        );
      }),
    );

    if (ok != true || selected == null || selectedPlan == null) return;
    final messenger = ScaffoldMessenger.of(context);
    // Defensive: the create dropdown only lists active customers, but guard
    // the write path too so an inactive customer can never get a new plan.
    if (!isEdit && !selected!.isActive) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 5),
        content: Text('Cannot create a plan for inactive customer "${selected!.name}".'),
      ));
      return;
    }
    try {
      final dao = ref.read(subscriptionsDaoProvider);
      final now = DateTime.now();
      final amt = double.parse(amount.text);
      // Block duplicate subscriptions (same plan for the same customer). On
      // edit, exclude the existing row so we don't report it as a duplicate
      // of itself.
      final dup = await dao.findByCustomerAndPlanName(
        selected!.id,
        selectedPlan!.name,
        excludeId: existing?.subscription.id,
      );
      if (dup != null) {
        if (!context.mounted) return;
        messenger.showSnackBar(SnackBar(
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
          content: Text(
            '${selected!.name} already has a plan named "${dup.planName}".',
          ),
        ));
        return;
      }
      // Issue 7: synchronize next_due_date to the user's chosen start_date on
      // edit. The previous logic kept the existing next_due_date when it was
      // after the new start date, which silently swallowed any move to an
      // earlier (past) date. If the user wants the next-due to advance past
      // the start date they record a payment, which calls advance() below.
      final nextDue = startDate;
      final record = LocalSubscription(
        id: existing?.subscription.id ?? 's-${now.microsecondsSinceEpoch}',
        customerId: selected!.id,
        planId: selectedPlan!.id,
        planName: selectedPlan!.name,
        amount: amt,
        frequency: frequency,
        startDate: startDate,
        nextDueDate: nextDue,
        status: existing?.subscription.status ?? 1,
        createdAt: existing?.subscription.createdAt ?? now,
        updatedAt: isEdit ? now : null,
      );
      await dao.upsert(record);
      // Clear any active filter so the new/updated plan is visible. Without
      // this a plan that doesn't match the current Due Summary filter would
      // be saved silently and look like nothing happened.
      ref.read(plansFilterProvider.notifier).state = PlansFilter.none;
      ref.invalidate(_subsProvider);
      ref.read(dataRevisionProvider.notifier).state++;
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Text(isEdit ? 'Plan updated' : 'Plan created'),
      ));
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
        content: Text('Save failed: $e'),
      ));
    }
  }

  Future<void> _confirmCancel(BuildContext context, WidgetRef ref, _SubRow row) async {
    final s = row.subscription;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel plan?'),
        content: Text('"${s.planName}" for ${row.customerName} will stop generating reminders.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel plan'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dao = ref.read(subscriptionsDaoProvider);
      final cancelled = LocalSubscription(
        id: s.id,
        customerId: s.customerId,
        planName: s.planName,
        amount: s.amount,
        frequency: s.frequency,
        startDate: s.startDate,
        nextDueDate: s.nextDueDate,
        status: 3,
        createdAt: s.createdAt,
        updatedAt: DateTime.now(),
      );
      await dao.upsert(cancelled);
      ref.invalidate(_subsProvider);
      ref.read(dataRevisionProvider.notifier).state++;
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Text('Plan cancelled: ${s.planName}'),
      ));
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
        content: Text('Cancel failed: $e'),
      ));
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, _SubRow row) async {
    final s = row.subscription;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete plan?'),
        content: Text(
          '"${s.planName}" for ${row.customerName} will be removed permanently. '
          'All recorded payments under this plan will also be deleted. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      // FK CASCADE on payments(subscription_id) removes related payments
      // automatically (PRAGMA foreign_keys is enabled in LocalDb.open).
      await ref.read(subscriptionsDaoProvider).delete(s.id);
      ref.invalidate(_subsProvider);
      ref.read(dataRevisionProvider.notifier).state++;
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Text('Deleted plan: ${s.planName}'),
      ));
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
        content: Text('Delete failed: $e'),
      ));
    }
  }
}

/// Re-exported for use by Payments tab when it needs to advance next_due_date.
DateTime advanceNextDue(DateTime current, int frequency) =>
    SubscriptionDateCalc.advance(current, frequency);