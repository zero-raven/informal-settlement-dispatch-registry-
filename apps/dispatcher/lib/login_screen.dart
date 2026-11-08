// Login / Role Selection Screen

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'design_system.dart';
import 'components.dart';
import 'auth_service.dart';

class LoginScreen extends StatefulWidget {
  final VoidCallback onLoginComplete;
  final String? baseUrl;

  const LoginScreen({super.key, required this.onLoginComplete, this.baseUrl});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _apiController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _userController.dispose();
    _passwordController.dispose();
    _apiController.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final auth = context.read<AuthService>();
    final username = _userController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your username and password.');
      return;
    }
    setState(() { _isLoading = true; _error = null; });
    try {
      final base = _apiController.text.trim().isNotEmpty
          ? _apiController.text.trim()
          : (widget.baseUrl ?? 'http://127.0.0.1:8090');
      final ok = await auth.login(username, password, base);
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logged in as ${auth.currentRole.displayName}')),
        );
        widget.onLoginComplete();
      } else {
        setState(() => _error = 'Invalid credentials, or the server is unreachable. Check the server URL.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Login failed: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? DSColors.surface0 : Colors.grey[50],
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(DSSpacing.screenPadding),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: DSCard(
              padding: const EdgeInsets.all(DSSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Logo
                  Container(
                    padding: const EdgeInsets.all(DSSpacing.xl),
                    decoration: BoxDecoration(
                      gradient: DSColors.primaryGradient,
                      borderRadius: BorderRadius.circular(DSBorderRadius.xxl),
                      boxShadow: DSShadows.glowPrimary,
                    ),
                    child: Icon(
                      Icons.local_shipping_rounded,
                      size: 56,
                      color: DSColors.textOnPrimary,
                    ),
                  ),
                  const SizedBox(height: DSSpacing.xl),

                  // Title
                  Text(
                    'Dispatcher',
                    style: DSTypography.displaySmall.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: DSSpacing.xs),
                  Text(
                    'Emergency Operations System',
                    style: DSTypography.bodyMedium.copyWith(color: DSColors.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: DSSpacing.xl),

                  // Credentials — the server decides the role from the account.
                  Text(
                    'Sign in',
                    style: DSTypography.titleMedium.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: DSSpacing.md),
                  TextField(
                    controller: _userController,
                    textCapitalization: TextCapitalization.none,
                    decoration: InputDecoration(
                      labelText: 'Username',
                      hintText: 'e.g. dispatcher, mapper, caller',
                      prefixIcon: const Icon(Icons.person_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(DSBorderRadius.md),
                      ),
                    ),
                  ),
                  const SizedBox(height: DSSpacing.md),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(DSBorderRadius.md),
                      ),
                    ),
                    onSubmitted: (_) => _continue(),
                  ),
                  const SizedBox(height: DSSpacing.md),
                  TextField(
                    controller: _apiController,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: 'Server URL',
                      hintText: widget.baseUrl ?? 'http://192.168.1.5:8090',
                      prefixIcon: const Icon(Icons.api_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(DSBorderRadius.md),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: DSSpacing.md),
                    Text(_error!, style: const TextStyle(color: DSColors.error)),
                  ],
                  const SizedBox(height: DSSpacing.lg),
                  const Text(
                    'Your account determines what you can see: callers report, '
                    'dispatchers coordinate, mappers map offline.',
                    style: TextStyle(color: DSColors.textSecondary),
                  ),

                  const SizedBox(height: DSSpacing.xl),

                  // Continue Button
                  DSPrimaryButton(
                    label: _isLoading ? 'Signing in...' : 'Continue',
                    icon: _isLoading ? null : Icons.arrow_forward_rounded,
                    isLoading: _isLoading,
                    onPressed: _continue,
                  ),

                  const SizedBox(height: DSSpacing.lg),

                  // Device Info
                  Consumer<AuthService>(
                    builder: (context, auth, _) {
                      return Text(
                        'Device: ${auth.deviceHash}',
                        style: DSTypography.bodySmall.copyWith(color: DSColors.textTertiary),
                      );
                    },
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

