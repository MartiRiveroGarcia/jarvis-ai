import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../application/auth_controller.dart';
import '../application/auth_failure.dart';
import 'auth_messages.dart';
import 'widgets/auth_error_banner.dart';

/// In-memory navigation state for /login (passed as GoRouter `extra`, never in
/// the URL). Never carries a password.
class LoginPrefill {
  const LoginPrefill({required this.email, this.notice});

  final String email;
  final String? notice;
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.prefill});

  final LoginPrefill? prefill;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.prefill?.email);
  final _password = TextEditingController();
  bool _obscurePassword = true;
  bool _submitting = false;
  AuthFailure? _failure;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _submitting = true;
      _failure = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .login(email: _email.text.trim(), password: _password.text);
      _password.clear(); // the router navigates away on success
    } on AuthFailure catch (failure) {
      if (mounted) {
        setState(() => _failure = failure);
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    final validation = failure is ValidationFailed ? failure : null;
    final notice = widget.prefill?.notice;

    return AuthLayout(
      children: [
        const JarvisMark(),
        const SizedBox(height: 32),
        if (notice != null && failure == null) ...[
          AuthBanner.info(notice),
          const SizedBox(height: 16),
        ],
        if (failure != null &&
            (validation == null || validation.fieldErrors.isEmpty)) ...[
          AuthBanner.error(authFailureMessage(failure)),
          const SizedBox(height: 16),
        ],
        Form(
          key: _formKey,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('login-email'),
                  controller: _email,
                  enabled: !_submitting,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Email',
                    errorText: validation?.messageFor('email'),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Enter your email' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('login-password'),
                  controller: _password,
                  enabled: !_submitting,
                  obscureText: _obscurePassword,
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    errorText: validation?.messageFor('password'),
                    suffixIcon: IconButton(
                      key: const Key('login-toggle-password'),
                      tooltip: _obscurePassword
                          ? 'Show password'
                          : 'Hide password',
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (value) =>
                      (value ?? '').isEmpty ? 'Enter your password' : null,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('login-submit'),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : const Text('Log in'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _submitting ? null : () => context.go(Routes.register),
          child: const Text('Create an account'),
        ),
      ],
    );
  }
}
