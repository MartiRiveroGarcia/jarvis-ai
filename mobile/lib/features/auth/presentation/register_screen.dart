import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../application/auth_controller.dart';
import '../application/auth_failure.dart';
import '../domain/password_policy.dart';
import 'auth_messages.dart';
import 'login_screen.dart';
import 'widgets/auth_error_banner.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  /// Shown when POST /register itself failed on the network: the account may or
  /// may not exist, so registration is not reported as failed.
  static const uncertainRegistrationMessage =
      "Couldn't reach the server. If your account was created, try logging in.";

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _obscurePassword = true;
  bool _submitting = false;
  AuthFailure? _failure;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) {
      return;
    }
    final email = _email.text.trim();
    setState(() {
      _submitting = true;
      _failure = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .register(email: email, password: _password.text);
      _password.clear();
      _confirmPassword.clear();
    } on RegisteredButSignInFailed catch (failure) {
      // The account exists: never report this as a failed registration.
      if (mounted) {
        context.go(
          Routes.login,
          extra: LoginPrefill(
            email: failure.email,
            notice: authFailureMessage(failure),
          ),
        );
      }
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

    return AuthLayout(
      children: [
        const JarvisMark(),
        const SizedBox(height: 32),
        if (failure != null &&
            (validation == null || validation.fieldErrors.isEmpty)) ...[
          AuthBanner.error(
            failure is NetworkFailure
                ? uncertainRegistrationMessage
                : authFailureMessage(failure),
          ),
          const SizedBox(height: 16),
        ],
        Form(
          key: _formKey,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('register-email'),
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
                  key: const Key('register-password'),
                  controller: _password,
                  enabled: !_submitting,
                  obscureText: _obscurePassword,
                  autofillHints: const [AutofillHints.newPassword],
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    helperText:
                        '$minPasswordLength–$maxPasswordLength characters. '
                        'Spaces allowed — try a passphrase.',
                    helperMaxLines: 2,
                    errorText: validation?.messageFor('password'),
                    suffixIcon: IconButton(
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
                  validator: (value) {
                    final length = (value ?? '').length;
                    if (length == 0) {
                      return 'Enter a password';
                    }
                    if (length < minPasswordLength ||
                        length > maxPasswordLength) {
                      return 'Use $minPasswordLength–$maxPasswordLength '
                          'characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('register-confirm-password'),
                  controller: _confirmPassword,
                  enabled: !_submitting,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    labelText: 'Confirm password',
                  ),
                  validator: (value) {
                    if ((value ?? '').isEmpty) {
                      return 'Confirm your password';
                    }
                    return value == _password.text
                        ? null
                        : "Passwords don't match";
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('register-submit'),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : const Text('Create account'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _submitting ? null : () => context.go(Routes.login),
          child: const Text('Already have an account? Log in'),
        ),
      ],
    );
  }
}
