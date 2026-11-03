import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth_state.dart';

/// OTP entry screen the user lands on after a successful /api/auth/register.
/// Reads its state from [pendingVerificationProvider] (email, expiry,
/// resend cooldown, attempts left); the AuthController owns the API calls.
class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key});

  @override
  ConsumerState<VerifyEmailScreen> createState() =>
      _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  final _codeController = TextEditingController();
  Timer? _ticker;
  // Re-built each tick so the countdown labels recompute. We don't need to
  // store the values -- they're derived from the provider's timestamps.
  Duration _expiryRemaining = Duration.zero;
  Duration _cooldownRemaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _tick();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    final pending = ref.read(pendingVerificationProvider);
    if (pending == null) return;
    final now = DateTime.now().toUtc();
    setState(() {
      _expiryRemaining = pending.expiresAtUtc.isAfter(now)
          ? pending.expiresAtUtc.difference(now)
          : Duration.zero;
      _cooldownRemaining = pending.resendAvailableAtUtc.isAfter(now)
          ? pending.resendAvailableAtUtc.difference(now)
          : Duration.zero;
    });
  }

  String _format(Duration d) {
    if (d.inSeconds <= 0) return '0s';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return m > 0 ? '${m}m ${s}s' : '${s}s';
  }

  Future<void> _onSubmit() async {
    final pending = ref.read(pendingVerificationProvider);
    if (pending == null) return;
    final code = _codeController.text.trim();
    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.red,
          content: Text('Enter the 6-digit code from your email.'),
        ),
      );
      return;
    }
    await ref
        .read(authControllerProvider.notifier)
        .verifyEmail(pending.email, code);
    if (!mounted) return;
    final after = ref.read(authControllerProvider);
    if (after.hasError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 4),
          content: Text(after.error?.toString() ?? 'Verification failed'),
        ),
      );
      _codeController.clear();
    }
  }

  Future<void> _onResend() async {
    final pending = ref.read(pendingVerificationProvider);
    if (pending == null) return;
    if (_cooldownRemaining.inSeconds > 0) return;
    await ref
        .read(authControllerProvider.notifier)
        .resendVerification(pending.email);
    if (!mounted) return;
    final after = ref.read(authControllerProvider);
    if (after.hasError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 4),
          content: Text(after.error?.toString() ?? 'Could not resend'),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF2E7D32),
          content: Text('A fresh code is on its way.'),
        ),
      );
      _codeController.clear();
    }
  }

  void _onChangeEmail() {
    ref.read(authControllerProvider.notifier).cancelPendingVerification();
    // Router redirect picks up the cleared pending state and bounces back
    // to /login; we hint the user toward Register where they can retype.
    context.go('/register');
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(pendingVerificationProvider);
    final auth = ref.watch(authControllerProvider);
    if (pending == null) {
      // Defensive -- the router should have bounced us off this screen.
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final expired = _expiryRemaining.inSeconds <= 0;
    final canResend = _cooldownRemaining.inSeconds <= 0 && !auth.isLoading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify your email'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: auth.isLoading ? null : _onChangeEmail,
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.mark_email_read_outlined,
                      size: 64, color: Color(0xFF0078D4)),
                  const SizedBox(height: 12),
                  Text(
                    'Check your inbox',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'We sent a 6-digit code to\n${pending.email}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                  if (!pending.deliveredByEmail) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade100,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'Dev mode: SMTP is not configured on the backend. '
                        'Look for the OTP in the backend log instead.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  TextField(
                    controller: _codeController,
                    autofocus: true,
                    enabled: !expired && !auth.isLoading,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 26,
                        letterSpacing: 12,
                        fontWeight: FontWeight.w600),
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: const InputDecoration(
                      counterText: '',
                      border: OutlineInputBorder(),
                      hintText: '------',
                    ),
                    onSubmitted: (_) => _onSubmit(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        expired
                            ? 'Code expired'
                            : 'Expires in ${_format(_expiryRemaining)}',
                        style: TextStyle(
                          color: expired ? Colors.red : Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        '${pending.attemptsRemaining} attempt'
                        '${pending.attemptsRemaining == 1 ? '' : 's'} left',
                        style: const TextStyle(
                            color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed:
                        (auth.isLoading || expired) ? null : _onSubmit,
                    child: auth.isLoading
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('Verify'),
                          ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: canResend ? _onResend : null,
                    child: Text(
                      canResend
                          ? 'Resend code'
                          : 'Resend in ${_format(_cooldownRemaining)}',
                    ),
                  ),
                  TextButton(
                    onPressed: auth.isLoading ? null : _onChangeEmail,
                    child: const Text('Wrong email? Start over'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
