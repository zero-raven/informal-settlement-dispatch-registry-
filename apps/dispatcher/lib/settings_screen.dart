// Settings Screen for Dispatcher App

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'design_system.dart';
import 'components.dart';
import 'models.dart';
import 'package:provider/provider.dart';
import 'auth_service.dart';

class SettingsScreen extends StatefulWidget {
  final String? baseUrl;
  final String role;
  final AppSettings initialSettings;
  final ValueChanged<AppSettings>? onSettingsChanged;

  const SettingsScreen({
    super.key,
    this.baseUrl,
    this.role = 'dispatcher',
    required this.initialSettings,
    this.onSettingsChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _settings;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
  }

  Future<void> _saveSettings() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_settings', jsonEncode(_settings.toJson()));
      widget.onSettingsChanged?.call(_settings);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Settings saved',
              style: DSTypography.bodyMedium.copyWith(color: Colors.white),
            ),
            backgroundColor: DSColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DSBorderRadius.md),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to save: $e',
              style: DSTypography.bodyMedium.copyWith(color: Colors.white),
            ),
            backgroundColor: DSColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DSBorderRadius.md),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _testConnection() async {
    setState(() => _isLoading = true);
    try {
      final res = await http.get(
        Uri.parse('${_settings.apiBaseUrl}/v1/dispatch/capabilities'),
        headers: context.read<AuthService>().getAuthHeaders(),
      ).timeout(const Duration(seconds: 5));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              res.statusCode == 200
                  ? 'Connection successful'
                  : 'Connection failed: ${res.statusCode}',
              style: DSTypography.bodyMedium.copyWith(color: Colors.white),
            ),
            backgroundColor: res.statusCode == 200 ? DSColors.success : DSColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DSBorderRadius.md),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection error: $e', style: DSTypography.bodyMedium),
            backgroundColor: DSColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DSBorderRadius.md),
            ),
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
      appBar: AppBar(title: const Text('Settings')),
      backgroundColor: isDark ? DSColors.surface0 : Colors.grey[50],
      body: CustomScrollView(
        slivers: [
          // Header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(DSSpacing.screenPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Settings',
                    style: DSTypography.displaySmall.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: DSSpacing.xs),
                  Text(
                    'Configure the app to your needs',
                    style: DSTypography.bodyMedium.copyWith(
                      color: DSColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // API Configuration
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
              child: DSSectionHeader(
                title: 'API Configuration',
                subtitle: 'Backend connection settings',
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(DSSpacing.screenPadding),
              child: Column(
                children: [
                  _buildTextField(
                    label: 'Registry API Base URL',
                    initialValue: _settings.apiBaseUrl,
                    hint: 'http://127.0.0.1:8090',
                    onChanged: (v) => _settings = _settings.copyWith(apiBaseUrl: v),
                    prefixIcon: Icons.api_rounded,
                    helperText: 'Use Tailscale IP (100.x.x.x) for remote access',
                  ),
                  const SizedBox(height: DSSpacing.md),
                  // Routes come via the registry (its GRAPH_URL); the app only
                  // needs where responders start from.
                  _buildTextField(
                    label: 'Responder start latitude',
                    initialValue: _settings.stagingLat.toString(),
                    hint: '12.97',
                    onChanged: (v) {
                      final d = double.tryParse(v.trim());
                      if (d != null) _settings = _settings.copyWith(stagingLat: d);
                    },
                    prefixIcon: Icons.my_location_rounded,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  ),
                  const SizedBox(height: DSSpacing.md),
                  _buildTextField(
                    label: 'Responder start longitude',
                    initialValue: _settings.stagingLon.toString(),
                    hint: '77.59',
                    onChanged: (v) {
                      final d = double.tryParse(v.trim());
                      if (d != null) _settings = _settings.copyWith(stagingLon: d);
                    },
                    prefixIcon: Icons.my_location_rounded,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  ),
                  const SizedBox(height: DSSpacing.md),
                  _buildDropdown(
                    label: 'Role',
                    value: _settings.role,
                    items: const [
                      DropdownMenuItem(value: 'dispatcher', child: Text('Dispatcher')),
                      DropdownMenuItem(value: 'mapper', child: Text('Mapper')),
                      DropdownMenuItem(value: 'admin', child: Text('Admin')),
                    ],
                    onChanged: (v) => _settings = _settings.copyWith(role: v!),
                    prefixIcon: Icons.badge_rounded,
                  ),
                  const SizedBox(height: DSSpacing.md),
                  DSActionRow(
                    actions: [
                      DSPrimaryButton(
                        label: 'Test Connection',
                        icon: Icons.wifi_rounded,
                        isLoading: _isLoading,
                        isExpanded: false,
                        onPressed: _testConnection,
                      ),
                    ],
                    alignment: WrapAlignment.end,
                  ),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.sectionGap)),

          // Appearance
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
              child: DSSectionHeader(
                title: 'Appearance',
                subtitle: 'Theme and display options',
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(DSSpacing.screenPadding),
              child: Column(
                children: [
                  _buildSegmentedControl(
                    label: 'Theme Mode',
                    value: _settings.themeMode,
                    options: const [
                      (ThemeMode.light, 'Light', Icons.light_mode_rounded),
                      (ThemeMode.dark, 'Dark', Icons.dark_mode_rounded),
                      (ThemeMode.system, 'System', Icons.brightness_auto_rounded),
                    ],
                    onChanged: (v) {
                      setState(() => _settings = _settings.copyWith(themeMode: v));
                    },
                  ),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.sectionGap)),

          // Behavior
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
              child: DSSectionHeader(
                title: 'Behavior',
                subtitle: 'App behavior and notifications',
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(DSSpacing.screenPadding),
              child: Column(
                children: [
                  _buildSwitchTile(
                    title: 'Enable Notifications',
                    subtitle: 'Receive push notifications for dispatches',
                    value: _settings.enableNotifications,
                    onChanged: (v) {
                      setState(() => _settings = _settings.copyWith(enableNotifications: v));
                    },
                    icon: Icons.notifications_rounded,
                  ),
                  _buildSwitchTile(
                    title: 'Enable Haptics',
                    subtitle: 'Vibration feedback on interactions',
                    value: _settings.enableHaptics,
                    onChanged: (v) {
                      setState(() => _settings = _settings.copyWith(enableHaptics: v));
                    },
                    icon: Icons.vibration_rounded,
                  ),
                  _buildSwitchTile(
                    title: 'Auto Refresh',
                    subtitle: 'Automatically refresh dashboard data',
                    value: _settings.autoRefresh,
                    onChanged: (v) {
                      setState(() => _settings = _settings.copyWith(autoRefresh: v));
                    },
                    icon: Icons.refresh_rounded,
                  ),
                  const SizedBox(height: DSSpacing.md),
                  if (_settings.autoRefresh)
                    _buildTextField(
                      label: 'Refresh Interval (seconds)',
                      initialValue: _settings.refreshInterval.toString(),
                      hint: '30',
                      keyboardType: TextInputType.number,
                      onChanged: (v) =>
                          _settings = _settings.copyWith(refreshInterval: int.tryParse(v) ?? 30),
                      prefixIcon: Icons.timer_rounded,
                    ),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.sectionGap)),

          // About
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
              child: DSSectionHeader(
                title: 'About',
                subtitle: 'App information and version',
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(DSSpacing.screenPadding),
              child: Column(
                children: [
                  DSCard(
                    padding: const EdgeInsets.all(DSSpacing.cardPadding),
                    child: Column(
                      children: [
                        _AboutRow(
                          icon: Icons.info_outline_rounded,
                          label: 'Version',
                          value: '1.0.0',
                        ),
                        _AboutRow(
                          icon: Icons.code_rounded,
                          label: 'Build',
                          value: '2024.11.01',
                        ),
                        _AboutRow(
                          icon: Icons.description_rounded,
                          label: 'License',
                          value: 'MIT',
                        ),
                        _AboutRow(
                          icon: Icons.privacy_tip_rounded,
                          label: 'Privacy',
                          value: 'No personal data stored',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: DSSpacing.lg),
                  DSActionRow(
                    actions: [
                      DSSecondaryButton(
                        label: 'View Documentation',
                        icon: Icons.menu_book_rounded,
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => DSDialog(
                              title: 'Documentation',
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Project documentation is available in the repository.', style: DSTypography.bodyMedium),
                                  const SizedBox(height: DSSpacing.md),
                                  Text('Key files:', style: DSTypography.titleSmall),
                                  Text('• docs/api.md - API specification', style: DSTypography.bodySmall),
                                  Text('• docs/development-plan.md - Development roadmap', style: DSTypography.bodySmall),
                                  Text('• docs/PRESENT_DEMO.md - Demo presentation guide', style: DSTypography.bodySmall),
                                  Text('• README.md - Project overview', style: DSTypography.bodySmall),
                                ],
                              ),
                              actions: [
                                DSPrimaryButton(label: 'Close', onPressed: () => Navigator.pop(context)),
                              ],
                            ),
                          );
                        },
                      ),
                      DSSecondaryButton(
                        label: 'Report Issue',
                        icon: Icons.bug_report_rounded,
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => DSDialog(
                              title: 'Report Issue',
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('To report issues or request features:', style: DSTypography.bodyMedium),
                                  const SizedBox(height: DSSpacing.md),
                                  Text('1. Create an issue in the project repository', style: DSTypography.bodySmall),
                                  Text('2. Include steps to reproduce', style: DSTypography.bodySmall),
                                  Text('3. Add device/OS info and logs', style: DSTypography.bodySmall),
                                ],
                              ),
                              actions: [
                                DSPrimaryButton(label: 'Close', onPressed: () => Navigator.pop(context)),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.xxl)),

          // Save button
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(DSSpacing.screenPadding),
              child: DSPrimaryButton(
                label: _isLoading ? 'Saving...' : 'Save Settings',
                icon: Icons.save_rounded,
                isLoading: _isLoading,
                onPressed: _saveSettings,
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.xxl)),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required String initialValue,
    required String hint,
    required ValueChanged<String> onChanged,
    required IconData prefixIcon,
    TextInputType? keyboardType,
    String? helperText,
  }) {
    // TextFormField (not a controller created in build) so editing a URL
    // on a phone does not lose the cursor on every rebuild.
    return TextFormField(
      initialValue: initialValue,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helperText,
        prefixIcon: Icon(prefixIcon),
      ),
      onChanged: onChanged,
    );
  }

  Widget _buildDropdown({
    required String label,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
    required IconData prefixIcon,
  }) {
    return DropdownButtonFormField<String>(
      value: value,
      items: items,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(prefixIcon),
      ),
    );
  }

  Widget _buildSwitchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required IconData icon,
  }) {
    return DSCard(
      padding: const EdgeInsets.all(DSSpacing.md),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(DSSpacing.sm),
            decoration: BoxDecoration(
              color: DSColors.primary.withOpacity(0.15),
              borderRadius: BorderRadius.circular(DSBorderRadius.md),
            ),
            child: Icon(icon, color: DSColors.primary, size: 22),
          ),
          const SizedBox(width: DSSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: DSTypography.titleMedium),
                const SizedBox(height: DSSpacing.xs),
                Text(subtitle, style: DSTypography.bodySmall),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: DSColors.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentedControl({
    required String label,
    required ThemeMode value,
    required List<(ThemeMode, String, IconData)> options,
    required ValueChanged<ThemeMode> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: DSTypography.titleMedium),
        const SizedBox(height: DSSpacing.md),
        SegmentedButton<ThemeMode>(
          segments: options.map((opt) {
            final (mode, name, icon) = opt;
            return ButtonSegment<ThemeMode>(
              value: mode,
              label: Text(name),
              icon: Icon(icon, size: 18),
            );
          }).toList(),
          selected: {value},
          onSelectionChanged: (selection) => onChanged(selection.first),
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return DSColors.primary.withOpacity(0.15);
              }
              return Colors.transparent;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return DSColors.primary;
              }
              return DSColors.textSecondary;
            }),
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return BorderSide(color: DSColors.primary, width: 1.5);
              }
              return BorderSide(color: DSColors.border, width: 0.5);
            }),
            shape: WidgetStateProperty.all(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DSBorderRadius.md),
              ),
            ),
            padding: WidgetStateProperty.all(
              const EdgeInsets.symmetric(
                horizontal: DSSpacing.lg,
                vertical: DSSpacing.md,
              ),
            ),
            minimumSize: WidgetStateProperty.all(const Size(80, 44)),
            visualDensity: VisualDensity.standard,
          ),
        ),
      ],
    );
  }
}

class _AboutRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _AboutRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: DSSpacing.sm),
      child: Row(
        children: [
          Icon(icon, size: 20, color: DSColors.textTertiary),
          const SizedBox(width: DSSpacing.md),
          Expanded(
            child: Text(label, style: DSTypography.bodyMedium),
          ),
          Text(
            value,
            style: DSTypography.bodyMedium.copyWith(
              color: DSColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}