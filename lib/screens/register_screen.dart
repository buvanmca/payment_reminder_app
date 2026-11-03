import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth_state.dart';
import '../core/config.dart';
import '../core/license_state.dart';

class _BusinessTypeOption {
  const _BusinessTypeOption(this.value, this.label);
  final int value;
  final String label;
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _orgName = TextEditingController();
  final _orgMobile = TextEditingController();
  final _adminName = TextEditingController();
  final _adminEmail = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  int _businessType = 99;
  bool _obscure = true;
  bool _obscureConfirm = true;

  // Values mirror the backend BusinessType enum. Value 2 was previously
  // Society — retired; new code points are added rather than reused.
  // Listed alphabetically by label for the dropdown UI.
  static const _businessTypes = [
    _BusinessTypeOption(7, 'Coaching Classes'),
    _BusinessTypeOption(5, 'Dance Academies'),
    _BusinessTypeOption(1, 'Gyms'),
    _BusinessTypeOption(8, 'Music Classes'),
    _BusinessTypeOption(99, 'Others'),
    _BusinessTypeOption(6, 'Play Schools'),
    _BusinessTypeOption(9, 'Sports Academies'),
    _BusinessTypeOption(3, 'Tuition Centers'),
    _BusinessTypeOption(4, 'Yoga Centers'),
  ];

  @override
  void dispose() {
    _orgName.dispose();
    _orgMobile.dispose();
    _adminName.dispose();
    _adminEmail.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    // Belt-and-braces guard: if the license became active between build and
    // tap, refuse to submit. The build() branch above already hides the form
    // in this case, so this only fires on a race.
    if (ref.read(licenseControllerProvider).isActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          content: const Text(
            'A license is already activated on this device. '
            'Account creation is disabled.',
          ),
        ),
      );
      return;
    }
    await ref.read(authControllerProvider.notifier).register(
          organizationName: _orgName.text.trim(),
          businessType: _businessType,
          organizationMobile: _orgMobile.text.trim(),
          adminName: _adminName.text.trim(),
          adminEmail: _adminEmail.text.trim(),
          adminPassword: _password.text,
        );
    final state = ref.read(authControllerProvider);
    if (!mounted) return;
    if (state is AsyncError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
          content: Text(state.error.toString()),
        ),
      );
      return;
    }
    // Success no longer hands back a JWT — the router watches
    // pendingVerificationProvider and bounces to /verify-email
    // automatically. Show a brief confirmation so the screen change
    // doesn't feel abrupt.
    if (ref.read(pendingVerificationProvider) != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF2E7D32),
          content: Text('Account created. Check your email for the OTP.'),
        ),
      );
    }
  }

  String? _required(String? v) => (v == null || v.trim().isEmpty) ? 'Required' : null;

  // Email: standard RFC-ish form (local@domain.tld).
  static final _emailRe =
      RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');

  String? _email(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    if (!_emailRe.hasMatch(v.trim())) return 'Enter a valid email';
    return null;
  }

  // Indian mobile: 10 digits beginning with 6/7/8/9, with an optional
  // +91 / 91 / 0 prefix. Spaces and dashes are tolerated and stripped
  // before validation so the user can type "+91 98765 43210".
  static final _indianMobileRe = RegExp(r'^(?:\+?91|0)?[6-9]\d{9}$');

  String? _mobile(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    final digits = v.replaceAll(RegExp(r'[\s-]'), '');
    if (!_indianMobileRe.hasMatch(digits)) {
      return 'Enter a valid 10-digit Indian mobile';
    }
    return null;
  }

  String? _password8(String? v) {
    if (v == null || v.isEmpty) return 'Required';
    if (v.length < 8) return 'At least 8 characters';
    return null;
  }

  String? _matchPassword(String? v) =>
      (v != _password.text) ? 'Passwords do not match' : null;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final license = ref.watch(licenseControllerProvider);
    final theme = Theme.of(context);

    // Once a license has been activated on this device, registration is
    // disabled — the device is bound to the existing organization and a
    // second account would just thrash the local DB / license cache. The
    // user is steered back to the login screen instead.
    if (license.isActive) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Create your account'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.verified_user_outlined,
                        size: 56, color: theme.colorScheme.primary),
                    const SizedBox(height: 16),
                    Text(
                      'Account creation disabled',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'A license is already activated on this device, so '
                      'additional accounts cannot be created here. Please '
                      'log in with the existing account, or deactivate the '
                      'license from Settings before registering a new one.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('Back to login'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create your account'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Account details', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _orgName,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Business name',
                        prefixIcon: Icon(Icons.business_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      value: _businessType,
                      decoration: const InputDecoration(
                        labelText: 'Business type',
                        prefixIcon: Icon(Icons.category_outlined),
                        border: OutlineInputBorder(),
                      ),
                      items: _businessTypes
                          .map((b) => DropdownMenuItem(value: b.value, child: Text(b.label)))
                          .toList(),
                      onChanged: (v) => setState(() => _businessType = v ?? 99),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _orgMobile,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Business mobile',
                        prefixIcon: Icon(Icons.phone_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: _mobile,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _adminName,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Your name',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _adminEmail,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Your email (login)',
                        prefixIcon: Icon(Icons.email_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: _email,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'Password (min 8)',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                        border: const OutlineInputBorder(),
                      ),
                      validator: _password8,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _confirmPassword,
                      obscureText: _obscureConfirm,
                      decoration: InputDecoration(
                        labelText: 'Confirm password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                        ),
                        border: const OutlineInputBorder(),
                      ),
                      validator: _matchPassword,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: auth.isLoading ? null : _submit,
                      child: auth.isLoading
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Text('Create account'),
                            ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Backend: ${AppConfig.apiBaseUrl}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
