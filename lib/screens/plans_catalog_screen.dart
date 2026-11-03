import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/subscription_banner.dart';
import '../core/tab_controller.dart';
import '../local/plans_dao.dart';

/// Catalog of reusable plan templates. Reached from the Subscriptions tab via
/// the "Manage plans" action. A subscription is then created against one of
/// these plans, which auto-fills its amount and frequency.
final _plansProvider = FutureProvider.autoDispose<List<LocalPlan>>((ref) async {
  ref.watch(dataRevisionProvider);
  return ref.read(plansDaoProvider).list();
});

String planFreqLabel(int f) => switch (f) {
      1 => 'Monthly',
      2 => 'Quarterly',
      3 => 'Half Yearly',
      4 => 'Yearly',
      _ => 'Monthly',
    };

class PlansCatalogScreen extends ConsumerWidget {
  const PlansCatalogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(_plansProvider);
    final money =
        CurrencyConfig.money;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Plans'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(_plansProvider),
          ),
        ],
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (plans) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(_plansProvider),
          child: plans.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 120),
                    Icon(Icons.list_alt_outlined, size: 56, color: Colors.grey),
                    SizedBox(height: 12),
                    Center(
                      child: Text(
                        'No plans yet.\nTap "New plan" to create one.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  ],
                )
              : ListView.separated(
                  itemCount: plans.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final plan = plans[i];
                    return ListTile(
                      leading: const Icon(Icons.list_alt),
                      title: Text(plan.name),
                      subtitle: Text(
                        '${money.format(plan.amount)}  -  ${planFreqLabel(plan.frequency)}'
                        '${plan.isActive ? "" : "  -  Inactive"}',
                      ),
                      onTap: () => _openPlanDialog(context, ref, existing: plan),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Actions',
                        onSelected: (v) {
                          if (v == 'edit') {
                            _openPlanDialog(context, ref, existing: plan);
                          }
                          if (v == 'delete') _confirmDelete(context, ref, plan);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'edit',
                              child: ListTile(
                                  leading: Icon(Icons.edit), title: Text('Edit'))),
                          PopupMenuItem(
                              value: 'delete',
                              child: ListTile(
                                  leading:
                                      Icon(Icons.delete_forever, color: Colors.red),
                                  title: Text('Delete'))),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New plan'),
        onPressed: () {
          if (!LicenseGuard.allowWrite(ref)) {
            LicenseGuard.blockWithMessage(context);
            return;
          }
          _openPlanDialog(context, ref);
        },
      ),
    );
  }

  Future<void> _openPlanDialog(
    BuildContext context,
    WidgetRef ref, {
    LocalPlan? existing,
  }) async {
    final isEdit = existing != null;
    final name = TextEditingController(text: existing?.name ?? '');
    final amount = TextEditingController(
      text: existing != null ? existing.amount.toStringAsFixed(0) : '',
    );
    int frequency = existing?.frequency ?? 1;
    final formKey = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(isEdit ? 'Edit plan' : 'New plan'),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Plan name'),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  TextFormField(
                    controller: amount,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Amount'),
                    validator: (v) {
                      final d = double.tryParse(v ?? '');
                      return (d == null || d <= 0)
                          ? 'Enter amount greater than 0'
                          : null;
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
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
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
      final dao = ref.read(plansDaoProvider);
      // Block duplicate plan names (case-insensitive). On edit, exclude self.
      final dup = await dao.findByName(name.text, excludeId: existing?.id);
      if (dup != null) {
        if (!context.mounted) return;
        messenger.showSnackBar(SnackBar(
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
          content: Text('A plan named "${dup.name}" already exists.'),
        ));
        return;
      }
      final now = DateTime.now();
      final record = LocalPlan(
        id: existing?.id ?? 'p-${now.microsecondsSinceEpoch}',
        name: name.text.trim(),
        amount: double.parse(amount.text),
        frequency: frequency,
        isActive: existing?.isActive ?? true,
        createdAt: existing?.createdAt ?? now,
        updatedAt: isEdit ? now : null,
      );
      await dao.upsert(record);
      ref.invalidate(_plansProvider);
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

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, LocalPlan plan) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete plan?'),
        content: Text(
          '"${plan.name}" will be removed from the catalog. '
          'Existing subscriptions keep their saved plan details and are not '
          'affected. This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
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
      await ref.read(plansDaoProvider).delete(plan.id);
      ref.invalidate(_plansProvider);
      ref.read(dataRevisionProvider.notifier).state++;
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Text('Deleted plan: ${plan.name}'),
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
