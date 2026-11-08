// Login / Role Selection Screen

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'design_system.dart';
import 'components.dart';
import 'auth_service.dart';

class LoginScreen extends StatefulWidget {
  final VoidCallback onLoginComplete;

  const LoginScreen({super.key, required this.onLoginComplete});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _nameController = TextEditingController();
  UserRole _selectedRole = UserRole.caller;
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final auth = context.read<AuthService>();
    
    // Validate name for dispatcher/admin
    if (_selectedRole != UserRole.caller && _nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please enter your name', style: DSTypography.bodyMedium.copyWith(color: Colors.white)),
          backgroundColor: DSColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DSBorderRadius.md)),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await auth.setRole(_selectedRole, userName: _nameController.text.trim());
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Logged in as ${_selectedRole.displayName}', style: DSTypography.bodyMedium.copyWith(color: Colors.white)),
            backgroundColor: DSColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DSBorderRadius.md)),
          ),
        );
        widget.onLoginComplete();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Login failed: $e', style: DSTypography.bodyMedium.copyWith(color: Colors.white)),
            backgroundColor: DSColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DSBorderRadius.md)),
          ),
        );
      }
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

                  // Role Selection
                  Text(
                    'Select Your Role',
                    style: DSTypography.titleMedium.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: DSSpacing.md),

                  _RoleSelector(
                    selectedRole: _selectedRole,
                    onChanged: (role) => setState(() => _selectedRole = role),
                  ),

                  const SizedBox(height: DSSpacing.lg),

                  // Name Field (for dispatcher/admin)
                  if (_selectedRole != UserRole.caller) ...[
                    TextField(
                      controller: _nameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: 'Your Name *',
                        hintText: 'Enter your name',
                        prefixIcon: const Icon(Icons.person_rounded),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(DSBorderRadius.md),
                        ),
                      ),
                    ),
                    const SizedBox(height: DSSpacing.md),
                  ],

                  // Role Description
                  _RoleDescriptionCard(role: _selectedRole),

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

class _RoleSelector extends StatelessWidget {
  final UserRole selectedRole;
  final ValueChanged<UserRole> onChanged;

  const _RoleSelector({required this.selectedRole, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final roles = [
      (UserRole.caller, 'Report emergencies', Icons.emergency_rounded, DSColors.primary),
      (UserRole.dispatcher, 'Manage dispatches', Icons.local_shipping_rounded, DSColors.info),
      (UserRole.admin, 'Full system access', Icons.admin_panel_settings_rounded, DSColors.warning),
    ];

    return Column(
      children: roles.map((role) {
        final (userRole, subtitle, icon, color) = role;
        final isSelected = selectedRole == userRole;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onChanged(userRole),
            borderRadius: BorderRadius.circular(DSBorderRadius.lg),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(DSSpacing.md),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(DSBorderRadius.lg),
                border: Border.all(
                  color: isSelected ? color : DSColors.border,
                  width: isSelected ? 2 : 1,
                ),
                color: isSelected ? color.withOpacity(0.1) : Colors.transparent,
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(DSSpacing.md),
                    decoration: BoxDecoration(
                      color: isSelected ? color : color.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(DSBorderRadius.md),
                    ),
                    child: Icon(icon, color: isSelected ? Colors.white : color, size: 24),
                  ),
                  const SizedBox(width: DSSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          userRole.displayName,
                          style: DSTypography.titleMedium.copyWith(
                            fontWeight: FontWeight.w600,
                            color: isSelected ? color : DSColors.textPrimary,
                          ),
                        ),
                        Text(
                          subtitle,
                          style: DSTypography.bodySmall.copyWith(color: DSColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  if (isSelected)
                    Icon(Icons.check_circle_rounded, color: color, size: 24),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _RoleDescriptionCard extends StatelessWidget {
  final UserRole role;

  const _RoleDescriptionCard({required this.role});

  @override
  Widget build(BuildContext context) {
    final (icon, color, description, permissions) = switch (role) {
      UserRole.caller => (
        Icons.emergency_rounded,
        DSColors.primary,
        'Report emergencies from your location. Track your call status and view response.',
        ['Log emergency calls', 'View own call history', 'Track dispatch status'],
      ),
      UserRole.dispatcher => (
        Icons.local_shipping_rounded,
        DSColors.info,
        'Manage emergency dispatches. Assign responders, track outcomes, monitor system.',
        ['View all incoming calls', 'Create & manage dispatches', 'Dashboard & statistics', 'Lookup structures', 'Full dispatch history'],
      ),
      UserRole.admin => (
        Icons.admin_panel_settings_rounded,
        DSColors.warning,
        'Full administrative access. Configure system, manage users, view all data.',
        ['All dispatcher permissions', 'System settings', 'User management', 'API configuration', 'Audit logs'],
      ),
    };

    return DSCard(
      padding: const EdgeInsets.all(DSSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(DSSpacing.sm),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(DSBorderRadius.md),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: DSSpacing.sm),
              Text(
                'About this role',
                style: DSTypography.titleSmall.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: DSSpacing.md),
          Text(
            description,
            style: DSTypography.bodyMedium.copyWith(color: DSColors.textSecondary),
          ),
          const SizedBox(height: DSSpacing.md),
          Text('Permissions:', style: DSTypography.labelMedium.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: DSSpacing.xs),
          ...permissions.map((p) => Padding(
            padding: const EdgeInsets.only(bottom: DSSpacing.xs),
            child: Row(
              children: [
                Icon(Icons.check_rounded, size: 16, color: color),
                const SizedBox(width: DSSpacing.sm),
                Expanded(child: Text(p, style: DSTypography.bodySmall)),
              ],
            ),
          )),
        ],
      ),
    );
  }
}