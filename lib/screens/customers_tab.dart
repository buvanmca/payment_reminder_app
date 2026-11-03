import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/feature_flags.dart';
import '../core/reminder_config.dart';
import '../core/reminder_dispatcher.dart';
import '../core/sms_template.dart';
import '../core/subscription_banner.dart';
import '../core/tab_controller.dart';
import '../local/customers_dao.dart';
import '../local/subscriptions_dao.dart';
import '../widgets/whatsapp_icon.dart';

final customersDaoProvider = Provider<CustomersDao>((_) => CustomersDao());
final subscriptionsDaoProvider = Provider<SubscriptionsDao>((_) => SubscriptionsDao());

final _searchProvider = StateProvider.autoDispose<String>((_) => '');

// Email: standard local@domain.tld form.
final _customerEmailRe =
    RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');

// Indian mobile: 10 digits beginning with 6/7/8/9, optional +91/91/0 prefix.
final _customerMobileRe = RegExp(r'^(?:\+?91|0)?[6-9]\d{9}$');

String? _validateIndianMobile(String? v) {
  if (v == null || v.trim().isEmpty) return 'Required';
  final digits = v.replaceAll(RegExp(r'[\s-]'), '');
  if (!_customerMobileRe.hasMatch(digits)) {
    return 'Enter a valid 10-digit Indian mobile';
  }
  return null;
}

String? _validateOptionalEmail(String? v) {
  if (v == null || v.trim().isEmpty) return null;
  if (!_customerEmailRe.hasMatch(v.trim())) return 'Enter a valid email';
  return null;
}

class _CustomerRow {
  _CustomerRow(this.customer, this.totalDue, this.totalAdvance);
  final LocalCustomer customer;
  final double totalDue;
  final double totalAdvance;
}

final _customersProvider = FutureProvider.autoDispose<List<_CustomerRow>>((ref) async {
  ref.watch(dataRevisionProvider);
  final search = ref.watch(_searchProvider);
  final dao = ref.read(customersDaoProvider);
  final subs = ref.read(subscriptionsDaoProvider);
  final list = await dao.list(search: search);
  final rows = <_CustomerRow>[];
  for (final c in list) {
    final due = await subs.totalDueForCustomer(c.id);
    final advance = await subs.totalAdvanceForCustomer(c.id);
    rows.add(_CustomerRow(c, due, advance));
  }
  return rows;
});

class CustomersTab extends ConsumerStatefulWidget {
  const CustomersTab({super.key});
  @override
  ConsumerState<CustomersTab> createState() => _CustomersTabState();
}

class _CustomersTabState extends ConsumerState<CustomersTab> {
  final _searchCtrl = TextEditingController();

  /// IDs of customers selected for a bulk action. Non-empty => selection mode.
  final Set<String> _selected = <String>{};
  bool get _selectionMode => _selected.isNotEmpty;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

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
        title: Text('Delete ${ids.length} '
            'customer${ids.length == 1 ? "" : "s"}?'),
        content: const Text(
          'The selected customers will be removed permanently. '
          'All plans and payments associated with them will also be deleted. '
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
      final dao = ref.read(customersDaoProvider);
      for (final id in ids) {
        await dao.delete(id);
      }
      _clearSelection();
      ref.invalidate(_customersProvider);
      ref.read(dataRevisionProvider.notifier).state++;
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Text('Deleted ${ids.length} customer${ids.length == 1 ? "" : "s"}'),
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
    final state = ref.watch(_customersProvider);
    final cfg = ref.watch(reminderConfigProvider).maybeWhen(
          data: (c) => c,
          orElse: () => const ReminderConfig(),
        );
    final fmt = CurrencyConfig.money;

    ref.listen<AppIntent?>(pendingIntentProvider, (_, next) {
      if (next == AppIntent.addCustomer) {
        ref.read(pendingIntentProvider.notifier).state = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openCustomerDialog(context);
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
                  onPressed: () => _confirmDeleteSelected(context),
                ),
              ],
            )
          : AppBar(
              title: const Text('Customers'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => ref.invalidate(_customersProvider),
                ),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Search name or mobile',
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (v) => ref.read(_searchProvider.notifier).state = v.trim(),
                  ),
                ),
              ),
            ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (rows) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(_customersProvider),
          child: rows.isEmpty
              ? const Center(child: Text('No customers yet'))
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final c = r.customer;
                    final selected = _selected.contains(c.id);
                    return ListTile(
                      selected: selected,
                      onLongPress: () => _toggleSelected(c.id),
                      onTap: _selectionMode
                          ? () => _toggleSelected(c.id)
                          : () => _openCustomerDialog(context, existing: c),
                      leading: _selectionMode
                          ? Checkbox(
                              value: selected,
                              onChanged: (_) => _toggleSelected(c.id),
                            )
                          : CircleAvatar(child: Text(c.name.isEmpty ? '?' : c.name[0].toUpperCase())),
                      title: Text(c.name),
                      subtitle: Text(c.mobile),
                      trailing: _selectionMode
                          ? null
                          : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (r.totalDue > 0)
                            Text(fmt.format(r.totalDue),
                                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600))
                          else if (r.totalAdvance > 0)
                            Text('${fmt.format(r.totalAdvance)} advance',
                                style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600))
                          else
                            const Icon(Icons.check_circle, color: Colors.green, size: 18),
                          PopupMenuButton<String>(
                            tooltip: 'Actions',
                            onSelected: (v) {
                              if (v == 'edit') _openCustomerDialog(context, existing: c);
                              if (v == 'wa') _sendWhatsApp(context, c, r.totalDue);
                              if (v == 'em') _sendEmail(context, c, r.totalDue);
                              if (v == 'sms') _sendSms(context, c, r.totalDue);
                              if (v == 'delete') _confirmDelete(context, c);
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                  value: 'edit', child: ListTile(leading: Icon(Icons.edit), title: Text('Edit'))),
                              // Reminders only go to active customers, so the
                              // send actions are hidden for inactive ones
                              // (the send methods also guard defensively).
                              // WhatsApp disabled app-wide (kWhatsAppEnabled).
                              if (kWhatsAppEnabled && c.isActive && r.totalDue > 0)
                                const PopupMenuItem(
                                    value: 'wa',
                                    child: ListTile(
                                        leading: WhatsAppIcon(size: 22),
                                        title: Text('Send WhatsApp'))),
                              if (c.isActive && r.totalDue > 0)
                                const PopupMenuItem(
                                    value: 'em',
                                    child: ListTile(
                                        leading: Icon(Icons.email), title: Text('Send Email'))),
                              if (c.isActive && r.totalDue > 0 && cfg.smsMode != SmsMode.disabled && c.mobile.isNotEmpty)
                                const PopupMenuItem(
                                    value: 'sms',
                                    child: ListTile(
                                        leading: Icon(Icons.sms, color: Colors.teal),
                                        title: Text('Send SMS'))),
                              const PopupMenuItem(
                                  value: 'delete',
                                  child: ListTile(
                                      leading: Icon(Icons.delete, color: Colors.red),
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
              onPressed: () {
                if (!LicenseGuard.allowWrite(ref)) {
                  LicenseGuard.blockWithMessage(context);
                  return;
                }
                _openCustomerDialog(context);
              },
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
    );
  }

  /// Instant reminders (WhatsApp / Email / SMS) go only to active customers —
  /// same rule the automatic scheduler already enforces. Returns false and
  /// shows a message when the customer is inactive.
  bool _ensureActiveForReminder(BuildContext context, LocalCustomer c) {
    if (c.isActive) return true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: Colors.orange.shade700,
      duration: const Duration(seconds: 4),
      content: Text(
        '${c.name} is inactive. Reactivate the customer to send reminders.',
      ),
    ));
    return false;
  }

  Future<void> _sendWhatsApp(BuildContext context, LocalCustomer c, double amount) async {
    if (!LicenseGuard.allowWrite(ref)) {
      LicenseGuard.blockWithMessage(context);
      return;
    }
    if (!_ensureActiveForReminder(context, c)) return;
    final messenger = ScaffoldMessenger.of(context);
    final dispatcher = ref.read(reminderDispatcherProvider);
    final result = await dispatcher.sendWhatsApp(
      phone: c.mobile,
      customerName: c.name,
      amount: amount > 0 ? amount : 0,
      dueDate: DateTime.now(),
      customerId: c.id,
    );
    ref.read(dataRevisionProvider.notifier).state++;
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      backgroundColor: result.sent
          ? Colors.green.shade700
          : result.networkError
              ? Colors.orange.shade700
              : Colors.red.shade700,
      content: Text(result.sent
          ? 'WhatsApp sent to ${c.name}'
          : result.networkError
              ? 'Offline — queued. Will send when server is up.'
              : 'WhatsApp failed: ${result.error ?? result.status}'),
    ));
  }

  Future<void> _sendEmail(BuildContext context, LocalCustomer c, double amount) async {
    if (!LicenseGuard.allowWrite(ref)) {
      LicenseGuard.blockWithMessage(context);
      return;
    }
    if (!_ensureActiveForReminder(context, c)) return;
    final email = c.email;
    if (email == null || email.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Colors.orange.shade700,
        duration: const Duration(seconds: 4),
        content: Text(
          'No email address configured for ${c.name}. Edit the customer to add one.',
        ),
      ));
      return;
    }
    final cfg = ref.read(reminderConfigProvider).maybeWhen(
          data: (c) => c,
          orElse: () => const ReminderConfig(),
        );
    final messenger = ScaffoldMessenger.of(context);
    final dispatcher = ref.read(reminderDispatcherProvider);
    final amt = amount > 0 ? amount : 0.0;
    final dueDate = DateTime.now();
    // Itemize the customer's overdue subscriptions; {amount} stays the total.
    final lines = await ref.read(subscriptionsDaoProvider).overdueBreakdownForCustomer(c.id);
    final details = formatOverdueDetails(
        lines.map((l) => (name: l.planName, amount: l.outstanding)).toList());
    // Render the template literally. The breakdown appears only where the
    // user kept the {details} placeholder; if they deleted it, the details
    // section must NOT come back. (We previously auto-appended an "Overdue
    // payments" block whenever {details} was absent, which defeated removing
    // the placeholder — see the email-formatting bug report.)
    final body = renderMessageTemplate(cfg.emailTemplate,
        name: c.name, amount: amt, dueDate: dueDate, details: details);
    final subject = renderMessageTemplate(cfg.emailSubject,
        name: c.name, amount: amt, dueDate: dueDate, details: details);
    final result = await dispatcher.sendEmail(
      email: email,
      customerName: c.name,
      amount: amt,
      dueDate: dueDate,
      customerId: c.id,
      subject: subject,
      body: body,
    );
    ref.read(dataRevisionProvider.notifier).state++;
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      backgroundColor: result.sent
          ? Colors.green.shade700
          : result.networkError
              ? Colors.orange.shade700
              : Colors.red.shade700,
      content: Text(result.sent
          ? 'Email sent to ${c.name}'
          : result.networkError
              ? 'Offline — queued. Will send when server is up.'
              : 'Email failed: ${result.error ?? result.status}'),
    ));
  }

  Future<void> _sendSms(BuildContext context, LocalCustomer c, double amount) async {
    if (!LicenseGuard.allowWrite(ref)) {
      LicenseGuard.blockWithMessage(context);
      return;
    }
    if (!_ensureActiveForReminder(context, c)) return;
    final cfg = ref.read(reminderConfigProvider).maybeWhen(
          data: (c) => c,
          orElse: () => const ReminderConfig(),
        );
    final messenger = ScaffoldMessenger.of(context);
    final dispatcher = ref.read(reminderDispatcherProvider);
    final amt = amount > 0 ? amount : 0.0;
    final dueDate = DateTime.now();
    // Itemize the customer's overdue subscriptions; {amount} stays the total.
    final lines = await ref.read(subscriptionsDaoProvider).overdueBreakdownForCustomer(c.id);
    final details = formatOverdueDetails(
        lines.map((l) => (name: l.planName, amount: l.outstanding)).toList());
    // Render the template literally — the {details} block appears only if the
    // user kept the placeholder, matching the email behavior above.
    final body = renderMessageTemplate(
      cfg.smsTemplate,
      name: c.name,
      amount: amt,
      dueDate: dueDate,
      details: details,
    );
    final result = await dispatcher.sendSms(
      phone: c.mobile,
      body: body,
      customerName: c.name,
      amount: amt,
      dueDate: dueDate,
      customerId: c.id,
    );
    ref.read(dataRevisionProvider.notifier).state++;
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      backgroundColor: result.sent
          ? Colors.green.shade700
          : result.networkError
              ? Colors.orange.shade700
              : Colors.red.shade700,
      content: Text(result.sent
          ? 'SMS sent to ${c.name}'
          : result.networkError
              ? 'Queued — will retry when SIM is reachable.'
              : 'SMS failed: ${result.error ?? result.status}'),
    ));
  }

  Future<void> _openCustomerDialog(BuildContext context, {LocalCustomer? existing}) async {
    final isEdit = existing != null;
    final name = TextEditingController(text: existing?.name ?? '');
    final mobile = TextEditingController(text: existing?.mobile ?? '');
    final email = TextEditingController(text: existing?.email ?? '');
    final address = TextEditingController(text: existing?.address ?? '');
    bool isActive = existing?.isActive ?? true;
    final formKey = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(isEdit ? 'Edit customer' : 'Add customer'),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Name'),
                    validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                  TextFormField(
                    controller: mobile,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Mobile'),
                    validator: _validateIndianMobile,
                  ),
                  TextFormField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email (optional)'),
                    validator: _validateOptionalEmail,
                  ),
                  TextFormField(
                    controller: address,
                    decoration: const InputDecoration(labelText: 'Address (optional)'),
                  ),
                  if (isEdit)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active'),
                      value: isActive,
                      onChanged: (v) => setLocal(() => isActive = v),
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

    if (ok != true) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dao = ref.read(customersDaoProvider);
      final em = email.text.trim().isEmpty ? null : email.text.trim();
      final ad = address.text.trim().isEmpty ? null : address.text.trim();
      final now = DateTime.now();
      // Block duplicate customers (same name, same mobile). On edit pass the
      // existing id so the customer's own row isn't reported as a clash with
      // itself.
      final dup = await dao.findByNameAndMobile(
        name.text.trim(),
        mobile.text.trim(),
        excludeId: existing?.id,
      );
      if (dup != null) {
        if (!mounted) return;
        messenger.showSnackBar(SnackBar(
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
          content: Text(
            'A customer named "${dup.name}" with mobile ${dup.mobile} already exists.',
          ),
        ));
        return;
      }
      final record = LocalCustomer(
        id: existing?.id ?? 'c-${now.microsecondsSinceEpoch}',
        name: name.text.trim(),
        mobile: mobile.text.trim(),
        email: em,
        address: ad,
        isActive: isActive,
        notes: existing?.notes,
        createdAt: existing?.createdAt ?? now,
        updatedAt: isEdit ? now : null,
      );
      await dao.upsert(record);
      ref.invalidate(_customersProvider);
      ref.read(dataRevisionProvider.notifier).state++;
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Text(isEdit ? 'Customer updated' : 'Customer added'),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
        content: Text('Save failed: $e'),
      ));
    }
  }

  Future<void> _confirmDelete(BuildContext context, LocalCustomer c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete customer?'),
        content: Text(
          '"${c.name}" will be removed permanently. '
          'All plans and payments associated with this customer will also be deleted. '
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
      await ref.read(customersDaoProvider).delete(c.id);
      ref.invalidate(_customersProvider);
      ref.read(dataRevisionProvider.notifier).state++;
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Text('Deleted ${c.name}'),
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
}