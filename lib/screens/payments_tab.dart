import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/currency.dart';
import '../core/subscription_banner.dart';
import '../core/tab_controller.dart';
import '../local/payments_dao.dart';
import '../local/subscription_date_calc.dart';
import '../local/subscriptions_dao.dart';
import 'customers_tab.dart' show customersDaoProvider, subscriptionsDaoProvider;

class _PaymentRow {
  _PaymentRow(this.payment, this.planName, this.customerName);
  final LocalPayment payment;
  final String planName;
  final String customerName;
}

final _paymentsProvider = FutureProvider.autoDispose<List<_PaymentRow>>((ref) async {
  ref.watch(dataRevisionProvider);
  final paymentsDao = ref.read(paymentsDaoProvider);
  final subsDao = ref.read(subscriptionsDaoProvider);
  final customersDao = ref.read(customersDaoProvider);
  final payments = await paymentsDao.list();
  final subs = <String, LocalSubscription>{};
  final customers = <String, String>{};
  final out = <_PaymentRow>[];
  for (final p in payments) {
    var s = subs[p.subscriptionId];
    if (s == null) {
      s = await subsDao.get(p.subscriptionId);
      if (s != null) subs[p.subscriptionId] = s;
    }
    String customerName = '(unknown)';
    String planName = '(plan removed)';
    if (s != null) {
      planName = s.planName;
      var n = customers[s.customerId];
      if (n == null) {
        final c = await customersDao.get(s.customerId);
        n = c?.name ?? '(unknown)';
        customers[s.customerId] = n;
      }
      customerName = n;
    }
    out.add(_PaymentRow(p, planName, customerName));
  }
  return out;
});

final paymentsDaoProvider = Provider<PaymentsDao>((_) => PaymentsDao());

class PaymentsTab extends ConsumerStatefulWidget {
  const PaymentsTab({super.key});

  @override
  ConsumerState<PaymentsTab> createState() => _PaymentsTabState();
}

class _PaymentsTabState extends ConsumerState<PaymentsTab> {
  /// IDs of payments selected for a bulk delete. Non-empty => selection mode.
  final Set<String> _selected = <String>{};
  bool get _selectionMode => _selected.isNotEmpty;

  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _confirmDeleteSelected(BuildContext context, List<_PaymentRow> rows) async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${ids.length} payment${ids.length == 1 ? "" : "s"}?'),
        content: const Text(
          'The selected payments will be removed permanently. '
          'Affected plans keep their next due date; adjust a plan separately '
          'if you need to. This cannot be undone.',
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
      final paymentsDao = ref.read(paymentsDaoProvider);
      // Collect the subscriptions touched so we can recompute their next-due
      // once after all deletes (a removed payment can roll a plan back to due).
      final byId = {for (final r in rows) r.payment.id: r.payment};
      final affectedSubs = <String>{};
      for (final id in ids) {
        final sub = byId[id]?.subscriptionId;
        if (sub != null) affectedSubs.add(sub);
        await paymentsDao.delete(id);
      }
      for (final subId in affectedSubs) {
        await _recomputeNextDue(ref, subId);
      }
      _clearSelection();
      ref.invalidate(_paymentsProvider);
      ref.read(dataRevisionProvider.notifier).state++;
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Text('Deleted ${ids.length} payment${ids.length == 1 ? "" : "s"}'),
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
    final state = ref.watch(_paymentsProvider);
    final money = CurrencyConfig.money;
    final df = DateFormat('dd-MMM-yyyy');

    ref.listen<AppIntent?>(pendingIntentProvider, (_, next) {
      if (next == AppIntent.recordPayment) {
        ref.read(pendingIntentProvider.notifier).state = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) _openPaymentDialog(context, ref);
        });
      }
    });

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
                  onPressed: () => _confirmDeleteSelected(
                      context, ref.read(_paymentsProvider).valueOrNull ?? const []),
                ),
              ],
            )
          : AppBar(
              title: const Text('Payments'),
              actions: [
                IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(_paymentsProvider)),
              ],
            ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (rows) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(_paymentsProvider),
          child: rows.isEmpty
              ? const Center(child: Text('No payments yet'))
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final p = r.payment;
                    final selected = _selected.contains(p.id);
                    return ListTile(
                      selected: selected,
                      onLongPress: () => _toggleSelected(p.id),
                      onTap: _selectionMode
                          ? () => _toggleSelected(p.id)
                          : () => _openPaymentDialog(context, ref, existing: r),
                      leading: _selectionMode
                          ? Checkbox(
                              value: selected,
                              onChanged: (_) => _toggleSelected(p.id),
                            )
                          : CircleAvatar(
                              backgroundColor: Colors.green.shade100,
                              child: const Icon(Icons.check, color: Colors.green),
                            ),
                      title: Text('${r.customerName}  -  ${r.planName}'),
                      subtitle: Text('${df.format(p.paymentDate)}  -  ${_modeLabel(p.paymentMode)}'
                          '${p.transactionRef != null ? "  -  ${p.transactionRef}" : ""}'),
                      trailing: _selectionMode
                          ? null
                          : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            money.format(p.amount),
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                          ),
                          PopupMenuButton<String>(
                            tooltip: 'Actions',
                            onSelected: (v) {
                              if (v == 'edit') _openPaymentDialog(context, ref, existing: r);
                              if (v == 'delete') _confirmDelete(context, ref, r);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                  value: 'edit',
                                  child: ListTile(leading: Icon(Icons.edit), title: Text('Edit'))),
                              PopupMenuItem(
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
        ),
      ),
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('Record'),
              onPressed: () {
                if (!LicenseGuard.allowWrite(ref)) {
                  LicenseGuard.blockWithMessage(context);
                  return;
                }
                _openPaymentDialog(context, ref);
              },
            ),
    );
  }

  static String _modeLabel(int m) => switch (m) {
        1 => 'Cash',
        2 => 'UPI',
        3 => 'Bank',
        4 => 'Card',
        5 => 'Cheque',
        _ => 'Other',
      };

  /// Single dialog used for both Record (create) and Edit. On create we also
  /// advance the subscription's next_due_date by one period; on edit we leave
  /// the next_due_date alone (the admin can adjust the plan separately if
  /// needed — silently rewinding here would be surprising).
  Future<void> _openPaymentDialog(BuildContext context, WidgetRef ref, {_PaymentRow? existing}) async {
    final isEdit = existing != null;
    final allSubs = await ref.read(subscriptionsDaoProvider).list();
    final eligibleSubs = isEdit
        ? allSubs.where((s) => s.id == existing.payment.subscriptionId).toList()
        : allSubs.where((s) => s.status != 3).toList();
    if (!context.mounted) return;
    if (eligibleSubs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Create a plan first')));
      return;
    }
    final customersDao = ref.read(customersDaoProvider);
    final customerNames = <String, String>{};
    for (final s in eligibleSubs) {
      if (!customerNames.containsKey(s.customerId)) {
        final c = await customersDao.get(s.customerId);
        customerNames[s.customerId] = c?.name ?? '(unknown)';
      }
    }
    if (!context.mounted) return;

    LocalSubscription? selected = isEdit
        ? eligibleSubs.firstWhere((s) => s.id == existing.payment.subscriptionId,
            orElse: () => eligibleSubs.first)
        : eligibleSubs.first;
    final amount = TextEditingController(
      text: isEdit
          ? existing.payment.amount.toStringAsFixed(0)
          : selected.amount.toStringAsFixed(0),
    );
    final txRef = TextEditingController(text: existing?.payment.transactionRef ?? '');
    int mode = existing?.payment.paymentMode ?? 1;
    DateTime paymentDate = existing?.payment.paymentDate ?? DateTime.now();
    final dateFmt = DateFormat('dd-MMM-yyyy');
    final formKey = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(isEdit ? 'Edit payment' : 'Record payment'),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<LocalSubscription>(
                    value: selected,
                    items: eligibleSubs
                        .map((s) => DropdownMenuItem(
                              value: s,
                              child: Text('${customerNames[s.customerId] ?? "?"}  -  ${s.planName}'),
                            ))
                        .toList(),
                    onChanged: isEdit
                        ? null
                        : (s) {
                            setLocal(() {
                              selected = s;
                              amount.text = s?.amount.toStringAsFixed(0) ?? '';
                            });
                          },
                    decoration: const InputDecoration(labelText: 'Plan'),
                    disabledHint: selected == null
                        ? null
                        : Text('${customerNames[selected!.customerId] ?? "?"}  -  ${selected!.planName}'),
                  ),
                  TextFormField(
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Amount'),
                    validator: (v) {
                      final d = double.tryParse(v ?? '');
                      return (d == null || d <= 0) ? 'Enter amount > 0' : null;
                    },
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: paymentDate,
                        firstDate: DateTime(now.year - 5),
                        lastDate: now,
                        helpText: 'Select payment date',
                      );
                      if (picked != null) {
                        setLocal(() => paymentDate = picked);
                      }
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Payment date',
                        suffixIcon: Icon(Icons.calendar_today),
                      ),
                      child: Text(dateFmt.format(paymentDate)),
                    ),
                  ),
                  DropdownButtonFormField<int>(
                    value: mode,
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('Cash')),
                      DropdownMenuItem(value: 2, child: Text('UPI')),
                      DropdownMenuItem(value: 3, child: Text('Bank Transfer')),
                      DropdownMenuItem(value: 4, child: Text('Card')),
                      DropdownMenuItem(value: 5, child: Text('Cheque')),
                      DropdownMenuItem(value: 99, child: Text('Other')),
                    ],
                    onChanged: (v) => setLocal(() => mode = v ?? 1),
                    decoration: const InputDecoration(labelText: 'Mode'),
                  ),
                  TextFormField(
                    controller: txRef,
                    decoration: const InputDecoration(labelText: 'Transaction ref (optional)'),
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

    if (ok != true || selected == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final paymentsDao = ref.read(paymentsDaoProvider);
      final now = DateTime.now();
      final s = selected!;
      final amt = double.parse(amount.text);
      final ref0 = txRef.text.trim().isEmpty ? null : txRef.text.trim();

      if (isEdit) {
        await paymentsDao.upsert(LocalPayment(
          id: existing.payment.id,
          subscriptionId: existing.payment.subscriptionId,
          amount: amt,
          paymentDate: paymentDate,
          paymentMode: mode,
          transactionRef: ref0,
          notes: existing.payment.notes,
          createdAt: existing.payment.createdAt,
        ));
        // Recompute next_due from cumulative payments so the cycle the
        // user is editing stays in sync with the dashboard.
        await _recomputeNextDue(ref, existing.payment.subscriptionId);
      } else {
        await paymentsDao.upsert(LocalPayment(
          id: 'p-${now.microsecondsSinceEpoch}',
          subscriptionId: s.id,
          amount: amt,
          paymentDate: paymentDate,
          paymentMode: mode,
          transactionRef: ref0,
          notes: null,
          createdAt: now,
        ));
        // Recompute next_due based on cumulative payments. A partial
        // payment (paid < plan amount) leaves next_due unchanged; once the
        // cycle is fully paid the next_due advances to the start of the
        // next cycle.
        await _recomputeNextDue(ref, s.id);
      }
      ref.invalidate(_paymentsProvider);
      ref.read(dataRevisionProvider.notifier).state++;
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Text(isEdit ? 'Payment updated' : 'Payment recorded'),
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

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, _PaymentRow row) async {
    final p = row.payment;
    final money = CurrencyConfig.money;
    final df = DateFormat('dd-MMM-yyyy');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete payment?'),
        content: Text(
          'Remove the ${money.format(p.amount)} payment for ${row.customerName} - ${row.planName} '
          'on ${df.format(p.paymentDate)}? '
          'The plan\'s next due date will not be reset; adjust the plan separately if you need to.',
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
      await ref.read(paymentsDaoProvider).delete(p.id);
      // Recompute next_due now that this payment is gone — a deleted
      // payment may roll the plan back into a "due" state.
      await _recomputeNextDue(ref, p.subscriptionId);
      ref.invalidate(_paymentsProvider);
      ref.read(dataRevisionProvider.notifier).state++;
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Text('Deleted ${money.format(p.amount)} payment'),
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

  /// Recompute the subscription's next_due_date from its cumulative payments.
  /// Persists the new value only if it actually changed, to avoid touching
  /// updated_at on no-op recomputes.
  Future<void> _recomputeNextDue(WidgetRef ref, String subscriptionId) async {
    final subsDao = ref.read(subscriptionsDaoProvider);
    final paymentsDao = ref.read(paymentsDaoProvider);
    final s = await subsDao.get(subscriptionId);
    if (s == null) return;
    final totalPaid = await paymentsDao.totalForSubscription(subscriptionId);
    final newNextDue = computeNextDueFor(
      startDate: s.startDate,
      frequency: s.frequency,
      amountPerCycle: s.amount,
      totalPaid: totalPaid,
    );
    if (newNextDue.isAtSameMomentAs(s.nextDueDate)) return;
    await subsDao.upsert(LocalSubscription(
      id: s.id,
      customerId: s.customerId,
      planName: s.planName,
      amount: s.amount,
      frequency: s.frequency,
      startDate: s.startDate,
      nextDueDate: newNextDue,
      status: s.status,
      createdAt: s.createdAt,
      updatedAt: DateTime.now(),
    ));
  }
}