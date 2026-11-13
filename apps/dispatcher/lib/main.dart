/// Dispatcher App — Emergency Operations
/// Multi-screen app with role-based access control.
/// Professional dark theme per design system.

library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

import 'design_system.dart';
import 'components.dart';
import 'models.dart';
import 'auth_service.dart';
import 'login_screen.dart';
import 'dashboard_screen.dart';
import 'inbound_call_screen.dart';
import 'lookup_screen.dart';
import 'map_screen.dart';
import 'mapper_screen.dart';
import 'more_screen.dart';
import 'admin_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final auth = AuthService();
  // Restore the persisted role/device hash before first frame. Previously
  // initialize() was never called, so every launch reset to caller.
  await auth.initialize();
  runApp(
    ChangeNotifierProvider<AuthService>.value(value: auth, child: const DispatcherApp()),
  );
}

const String kDefaultApiUrl = 'http://127.0.0.1:8090';
const String kDefaultGraphUrl = 'http://127.0.0.1:8092';

class DispatcherApp extends StatefulWidget {
  const DispatcherApp({super.key, this.baseUrl});

  final String? baseUrl;

  @override
  State<DispatcherApp> createState() => _DispatcherAppState();
}

class _DispatcherAppState extends State<DispatcherApp> {
  AppSettings _settings = AppSettings();
  ThemeMode _themeMode = ThemeMode.dark;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settingsStr = prefs.getString('app_settings');
      if (settingsStr != null) {
        _settings = AppSettings.fromJson(
          jsonDecode(settingsStr) as Map<String, dynamic>);
      }
      _themeMode = _settings.themeMode;
    } catch (_) {
      // Use defaults
    }
    if (mounted) setState(() => _isInitialized = true);
  }

  void _updateSettings(AppSettings newSettings) {
    setState(() {
      _settings = newSettings;
      _themeMode = newSettings.themeMode;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return MaterialApp(
        title: 'Dispatch',
        debugShowCheckedModeBanner: false,
        theme: DSTheme.lightTheme,
        darkTheme: DSTheme.darkTheme,
        themeMode: _themeMode,
        home: const _LoadingScreen(),
      );
    }

    return Consumer<AuthService>(
      builder: (context, auth, _) {
        if (!auth.isInitialized) {
          return MaterialApp(
            title: 'Dispatch',
            debugShowCheckedModeBanner: false,
            theme: DSTheme.lightTheme,
            darkTheme: DSTheme.darkTheme,
            themeMode: _themeMode,
            home: const _LoadingScreen(),
          );
        }

        return MaterialApp(
          title: 'Dispatch',
          debugShowCheckedModeBanner: false,
          theme: DSTheme.lightTheme,
          darkTheme: DSTheme.darkTheme,
          themeMode: _themeMode,
          home: _AuthGate(
            settings: _settings,
            onSettingsChanged: _updateSettings,
            baseUrl: widget.baseUrl,
          ),
        );
      },
    );
  }
}

class _AuthGate extends StatelessWidget {
  final AppSettings settings;
  final ValueChanged<AppSettings> onSettingsChanged;
  final String? baseUrl;

  const _AuthGate({
    required this.settings,
    required this.onSettingsChanged,
    this.baseUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthService>(
      builder: (context, auth, _) {
        return _MainShell(
          settings: settings,
          onSettingsChanged: onSettingsChanged,
          baseUrl: baseUrl,
        );
      },
    );
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? DSColors.surface0 : Colors.white,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(DSSpacing.xl),
              decoration: BoxDecoration(
                gradient: DSColors.primaryGradient,
                borderRadius: BorderRadius.circular(DSBorderRadius.xxl),
                boxShadow: DSShadows.glowPrimary,
              ),
              child: Icon(
                Icons.local_shipping_rounded,
                size: 64,
                color: DSColors.textOnPrimary,
              ),
            ),
            const SizedBox(height: DSSpacing.xl),
            Text(
              'Dispatcher',
              style: DSTypography.displaySmall.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: DSSpacing.md),
            const DSLoadingState(message: 'Loading...'),
          ],
        ),
      ),
    );
  }
}

class _MainShell extends StatefulWidget {
  final AppSettings settings;
  final ValueChanged<AppSettings> onSettingsChanged;
  final String? baseUrl;

  const _MainShell({
    required this.settings,
    required this.onSettingsChanged,
    this.baseUrl,
  });

  @override
  State<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<_MainShell> {
  int _currentIndex = 0;
  late AppSettings _settings;
  String? _backendStatus;
  bool _isProbing = false;

  // Mobile IA: at most five primary destinations per role. Everything
  // else (Create, History, Settings, Admin, Sign out) lives under "More".
  final List<_NavItem> _allNavItems = [
    _NavItem(
      icon: Icons.dashboard_rounded,
      activeIcon: Icons.dashboard_rounded,
      label: 'Home',
      roles: [UserRole.dispatcher],
    ),
    _NavItem(
      icon: Icons.call_received_rounded,
      activeIcon: Icons.call_received_rounded,
      label: 'Calls',
      roles: [UserRole.caller, UserRole.dispatcher],
    ),
    _NavItem(
      icon: Icons.qr_code_scanner_rounded,
      activeIcon: Icons.qr_code_rounded,
      label: 'Lookup',
      roles: [UserRole.dispatcher],
    ),
    _NavItem(
      icon: Icons.map_rounded,
      activeIcon: Icons.map_rounded,
      label: 'Map',
      roles: [UserRole.dispatcher],
    ),
    _NavItem(
      icon: Icons.edit_location_rounded,
      activeIcon: Icons.edit_location_rounded,
      label: 'Field',
      roles: [UserRole.mapper],
    ),
    _NavItem(
      icon: Icons.admin_panel_settings_rounded,
      activeIcon: Icons.admin_panel_settings_rounded,
      label: 'Admin',
      roles: [UserRole.dispatcher],
    ),
    _NavItem(
      icon: Icons.more_horiz_rounded,
      activeIcon: Icons.more_horiz_rounded,
      label: 'More',
      roles: [UserRole.caller, UserRole.dispatcher, UserRole.mapper],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    _probeBackend();
  }

  List<_NavItem> get _visibleNavItems {
    final auth = context.read<AuthService>();
    if (auth.currentRole == UserRole.caller) {
      return _allNavItems.where((item) => item.roles.contains(UserRole.caller)).toList();
    }
    return _allNavItems.where((item) => item.roles.contains(auth.currentRole)).toList();
  }

  Future<void> _probeBackend() async {
    if (_isProbing) return;
    setState(() => _isProbing = true);
    try {
      final base = widget.baseUrl ?? _settings.apiBaseUrl;
      final auth = context.read<AuthService>();
      final res = await http.get(
        Uri.parse('$base/v1/dispatch/capabilities'),
        headers: auth.getAuthHeaders(),
      ).timeout(const Duration(seconds: 5));

      if (mounted) {
        if (res.statusCode == 200) {
          final c = jsonDecode(res.body) as Map<String, dynamic>;
          setState(() => _backendStatus =
              'Backend: ${c['backend']} · Profiles: ${(c['profiles'] as List).join(', ')}');
        } else {
          setState(() => _backendStatus =
              'Registry API unreachable (HTTP ${res.statusCode})');
        }
      }
    } catch (_) {
      if (mounted) setState(() => _backendStatus = 'Registry API unreachable');
    } finally {
      if (mounted) setState(() => _isProbing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final visibleItems = _visibleNavItems;
    final currentIndex = _currentIndex.clamp(0, visibleItems.length - 1);

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: currentIndex,
            children: _buildScreens(auth),
          ),
          if (!auth.hasExplicitRole)
            Positioned.fill(
              child: LoginScreen(
                baseUrl: widget.baseUrl ?? _settings.apiBaseUrl,
                onLoginComplete: () => setState(() {}),
              ),
            ),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Visible backend status: on a phone the default URL is loopback,
          // so the user must see at once whether the API URL needs fixing.
          Semantics(
            label: 'Backend status: ${_backendStatus ?? 'checking'}',
            child: InkWell(
              onTap: _isProbing ? null : _probeBackend,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isProbing)
                      const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      Icon(
                        (_backendStatus ?? '').contains('unreachable')
                            ? Icons.cloud_off_rounded
                            : Icons.cloud_done_rounded,
                        size: 16),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        _isProbing
                            ? 'Checking backend…'
                            : (_backendStatus ?? 'Backend status unknown — tap to retry'),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (visibleItems.length > 1)
            NavigationBar(
              selectedIndex: _currentIndex.clamp(0, visibleItems.length - 1),
              onDestinationSelected: (index) => setState(() => _currentIndex = index),
              destinations: visibleItems.map((item) {
                return NavigationDestination(
                  icon: Icon(item.icon),
                  selectedIcon: Icon(item.activeIcon),
                  label: item.label,
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildScreens(AuthService auth) {
    final baseUrl = widget.baseUrl ?? _settings.apiBaseUrl;
    final role = auth.currentRole.value;

    // Order must match the filtered _allNavItems order per role:
    // dispatcher: Home, Calls, Lookup, Map, Admin, More
    // caller: Calls, More
    // mapper: Field, More
    return [
      if (auth.isDispatcher) DashboardScreen(baseUrl: baseUrl, role: role),
      InboundCallScreen(baseUrl: baseUrl, role: role),
      if (auth.isDispatcher) LookupScreen(
          baseUrl: baseUrl,
          stagingLat: _settings.stagingLat,
          stagingLon: _settings.stagingLon,
          role: role,
        ),
      if (auth.isDispatcher) MapScreen(baseUrl: baseUrl, role: role),
      if (auth.isDispatcher) AdminScreen(baseUrl: baseUrl, role: role),
      if (auth.isMapper) MapperScreen(baseUrl: baseUrl),
      MoreScreen(baseUrl: baseUrl, role: role, initialSettings: _settings,
          onSettingsChanged: (s) { _settings = s; _probeBackend(); }),
    ];
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final List<UserRole> roles;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.roles,
  });
}