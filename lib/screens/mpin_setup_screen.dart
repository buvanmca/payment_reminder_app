import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth_state.dart';
import '../core/mpin_state.dart';

/// MPIN setup / change screen.
///
/// Two modes, picked by [isChange]:
///
///  * `false` (default) — first-time setup. Stages: create new → confirm.
///    Used post-login when the user has no PIN yet.
///  * `true` — reached from Settings → Change MPIN. Stages: verify current
///    → create new → confirm. The new PIN must differ from the current one
///    (checked by hashing the candidate against the stored salt before save),
///    so the user can't \"change\" to the same value they already had.
class MpinSetupScreen extends ConsumerStatefulWidget {
  const MpinSetupScreen({super.key, this.isChange = false});

  final bool isChange;

  @override
  ConsumerState<MpinSetupScreen> createState() => _MpinSetupScreenState();
}

enum _SetupStage { verifyCurrent, create, confirm }

class _MpinSetupScreenState extends ConsumerState<MpinSetupScreen> {
  final _pinController = TextEditingController();
  late _SetupStage _stage;
  String _firstPin = '';
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _stage =
        widget.isChange ? _SetupStage.verifyCurrent : _SetupStage.create;
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    final pin = _pinController.text;
    if (pin.length != 4) {
      setState(() => _error = 'Enter all 4 digits');
      return;
    }

    final controller = ref.read(mpinControllerProvider.notifier);

    if (_stage == _SetupStage.verifyCurrent) {
      // Goes through the normal verify path so wrong attempts still feed
      // the lockout counter — no free brute-force window via the change
      // flow. On success we deliberately don't advance \"isUnlocked\"
      // semantics any further (the user is already unlocked to be in
      // Settings); we just clear the input and move to the new-PIN stage.
      setState(() {
        _saving = true;
        _error = null;
      });
      final ok = await controller.verify(pin);
      if (!mounted) return;
      if (!ok) {
        final st = ref.read(mpinControllerProvider);
        setState(() {
          _saving = false;
          _pinController.clear();
          _error = st.isLockedNow
              ? 'Too many wrong attempts. Try again later.'
              : 'Wrong current MPIN.';
        });
        return;
      }
      setState(() {
        _saving = false;
        _stage = _SetupStage.create;
        _pinController.clear();
        _error = null;
      });
      return;
    }

    if (_stage == _SetupStage.create) {
      // Reject reuse of the existing PIN — \"change\" should mean change.
      // matchesCurrent is read-only and never penalises the attempt
      // counter, so a fat-fingered user doesn't get locked out for
      // accidentally re-typing their current PIN.
      if (widget.isChange && await controller.matchesCurrent(pin)) {
        if (!mounted) return;
        setState(() {
          _error = 'New MPIN must be different from your current MPIN.';
          _pinController.clear();
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _firstPin = pin;
        _stage = _SetupStage.confirm;
        _error = null;
        _pinController.clear();
      });
      return;
    }

    if (pin != _firstPin) {
      setState(() {
        _error = 'PINs don’t match. Start over.';
        _stage = _SetupStage.create;
        _firstPin = '';
        _pinController.clear();
      });
      return;
    }

    final auth = ref.read(authControllerProvider).valueOrNull;
    final orgId = auth?.orgId;
    if (orgId == null || orgId.isEmpty) {
      // Should never happen — the router gates this screen behind a live
      // session. Surface defensively rather than save a PIN with no owner.
      setState(() => _error = 'Session expired. Please log in again.');
      await ref.read(authControllerProvider.notifier).logout();
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await controller.setPin(pin, orgId: orgId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF2E7D32),
          content: Text(widget.isChange
              ? 'MPIN updated.'
              : 'MPIN set. You’ll use it to unlock the app.'),
        ),
      );
      context.go('/');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  String _title() {
    switch (_stage) {
      case _SetupStage.verifyCurrent:
        return 'Enter your current MPIN';
      case _SetupStage.create:
        return widget.isChange ? 'Choose a new MPIN' : 'Create your MPIN';
      case _SetupStage.confirm:
        return 'Confirm your MPIN';
    }
  }

  String _subtitle() {
    switch (_stage) {
      case _SetupStage.verifyCurrent:
        return 'Confirm it’s really you before changing your MPIN.';
      case _SetupStage.create:
        return widget.isChange
            ? 'Pick a 4-digit PIN that’s different from your current one.'
            : 'You’ll use this 4-digit PIN to unlock PayBells on this '
                'device. Avoid 1234, 0000, or your birth year.';
      case _SetupStage.confirm:
        return 'Re-enter the 4-digit PIN you just chose.';
    }
  }

  String _ctaLabel() {
    switch (_stage) {
      case _SetupStage.verifyCurrent:
        return 'Continue';
      case _SetupStage.create:
        return 'Continue';
      case _SetupStage.confirm:
        return 'Confirm';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConfirm = _stage == _SetupStage.confirm;
    return Scaffold(
      appBar: widget.isChange
          ? AppBar(
              title: const Text('Change MPIN'),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _saving ? null : () => context.go('/'),
              ),
            )
          : null,
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
                  const Icon(Icons.lock_outline,
                      size: 64, color: Color(0xFF0078D4)),
                  const SizedBox(height: 12),
                  Text(
                    _title(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _subtitle(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _pinController,
                    autofocus: true,
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
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _saving ? null : _onSubmit,
                    child: _saving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(_ctaLabel()),
                          ),
                  ),
                  if (isConfirm)
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () {
                              setState(() {
                                _stage = _SetupStage.create;
                                _firstPin = '';
                                _error = null;
                                _pinController.clear();
                              });
                            },
                      child: const Text('Start over'),
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
