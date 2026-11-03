import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth_state.dart';
import '../core/mpin_state.dart';

/// Gate that sits between a valid session token and the rest of the app on
/// every cold start (and after the OS evicts the process). Successful entry
/// sets [MpinState.isUnlocked] for the lifetime of the foreground session.
class MpinUnlockScreen extends ConsumerStatefulWidget {
  const MpinUnlockScreen({super.key});

  @override
  ConsumerState<MpinUnlockScreen> createState() => _MpinUnlockScreenState();
}

class _MpinUnlockScreenState extends ConsumerState<MpinUnlockScreen> {
  final _pinController = TextEditingController();
  String? _error;
  bool _verifying = false;
  Timer? _lockoutTicker;
  Duration _lockoutRemaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _maybeStartLockoutTicker();
  }

  @override
  void dispose() {
    _pinController.dispose();
    _lockoutTicker?.cancel();
    super.dispose();
  }

  void _maybeStartLockoutTicker() {
    final st = ref.read(mpinControllerProvider);
    final until = st.lockUntil;
    if (until == null) return;
    final remaining = until.difference(DateTime.now());
    if (remaining.inSeconds <= 0) return;
    _lockoutRemaining = remaining;
    _lockoutTicker?.cancel();
    _lockoutTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = until.difference(DateTime.now());
      if (left.inSeconds <= 0) {
        t.cancel();
        if (!mounted) return;
        setState(() {
          _lockoutRemaining = Duration.zero;
          _error = null;
        });
      } else {
        if (!mounted) return;
        setState(() => _lockoutRemaining = left);
      }
    });
  }

  Future<void> _onSubmit() async {
    final pin = _pinController.text;
    final st = ref.read(mpinControllerProvider);
    if (st.isLockedNow) {
      _maybeStartLockoutTicker();
      return;
    }
    if (pin.length != 4) {
      setState(() => _error = 'Enter all 4 digits');
      return;
    }

    setState(() {
      _verifying = true;
      _error = null;
    });
    final ok = await ref.read(mpinControllerProvider.notifier).verify(pin);
    if (!mounted) return;

    if (ok) {
      // Router redirect picks up MpinState.isUnlocked and lands the user on
      // their original destination (defaults to dashboard).
      context.go('/');
      return;
    }

    final after = ref.read(mpinControllerProvider);
    final attemptsLeft =
        kMpinAttemptLimit - (after.failedAttempts % kMpinAttemptLimit);
    setState(() {
      _verifying = false;
      _pinController.clear();
      _error = after.isLockedNow
          ? 'Too many wrong attempts.'
          : 'Wrong MPIN. $attemptsLeft attempt${attemptsLeft == 1 ? '' : 's'} '
              'left before lockout.';
    });
    _maybeStartLockoutTicker();
  }

  Future<void> _onForgotMpin() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset MPIN?'),
        content: const Text(
            'You will be logged out and asked to sign in with your email and '
            'password. Your MPIN will be cleared so you can pick a new one.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset MPIN')),
        ],
      ),
    );
    if (confirm != true) return;
    await ref.read(mpinControllerProvider.notifier).clear();
    await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(mpinControllerProvider);
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final hint = auth?.email ?? '';
    final isLocked = st.isLockedNow && _lockoutRemaining.inSeconds > 0;
    final showForgot = st.failedAttempts >= 3;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_open_outlined,
                      size: 64, color: Color(0xFF0078D4)),
                  const SizedBox(height: 12),
                  const Text('Enter your MPIN',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  if (hint.isNotEmpty)
                    Text(hint,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _pinController,
                    autofocus: !isLocked,
                    enabled: !isLocked,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 4,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 28,
                        letterSpacing: 16,
                        fontWeight: FontWeight.w600),
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    decoration: const InputDecoration(
                      counterText: '',
                      border: OutlineInputBorder(),
                      hintText: '• • • •',
                    ),
                    onSubmitted: (_) => _onSubmit(),
                  ),
                  const SizedBox(height: 12),
                  if (isLocked)
                    Text(
                      'Locked for ${_formatLockout(_lockoutRemaining)}.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.red, fontWeight: FontWeight.w600),
                    )
                  else if (_error != null)
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: (_verifying || isLocked) ? null : _onSubmit,
                    child: _verifying
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('Unlock'),
                          ),
                  ),
                  if (showForgot)
                    TextButton(
                      onPressed: _verifying ? null : _onForgotMpin,
                      child: const Text('Forgot MPIN? Sign in with password'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatLockout(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    }
    return '${seconds}s';
  }
}
