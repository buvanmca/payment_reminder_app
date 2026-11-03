import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../core/license_state.dart';

class LicenseSetupScreen extends ConsumerStatefulWidget {
  const LicenseSetupScreen({super.key});

  @override
  ConsumerState<LicenseSetupScreen> createState() => _LicenseSetupScreenState();
}

class _LicenseSetupScreenState extends ConsumerState<LicenseSetupScreen> {
  final _ctrl = TextEditingController(text: 'DEMO-LICENSE-0001');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = await ref.read(licenseControllerProvider.notifier).activate(_ctrl.text);
      if (!mounted) return;
      setState(() => _busy = false);
      if (state.isActive) {
        context.pop(true);
      } else {
        setState(() => _error = state.message ?? 'License is ${state.gate.name}.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(licenseControllerProvider);
    final df = DateFormat('dd-MMM-yyyy');
    return Scaffold(
      appBar: AppBar(title: const Text('Activate License')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Enter the license key issued for this device. The key binds to this '
              'device on first validation; re-installing on a new device requires '
              'a new key.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              decoration: const InputDecoration(
                labelText: 'License key',
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _activate,
              child: _busy
                  ? const SizedBox(
                      height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Activate'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            if (st.licenseKey != null) ...[
              const SizedBox(height: 24),
              Text('Current key: ${st.licenseKey}'),
              if (st.validUntil != null &&
                  (st.gate == LicenseGate.active || st.gate == LicenseGate.expired))
                Text('Valid until: ${df.format(st.validUntil!)}'),
              Text('Status: ${st.gate.name}'),
            ],
          ],
        ),
      ),
    );
  }
}