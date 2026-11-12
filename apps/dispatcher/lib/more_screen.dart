// More — everything that does not deserve a primary tab, grouped by task.
// Mobile rule: at most five primary destinations; the rest live here.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'auth_service.dart';
import 'create_dispatch_screen.dart';
import 'design_system.dart';
import 'history_screen.dart';
import 'settings_screen.dart';
import 'models.dart';
import 'core/local_store.dart';

class MoreScreen extends StatefulWidget {
  final String? baseUrl;
  final String role;
  final AppSettings initialSettings;
  final ValueChanged<AppSettings>? onSettingsChanged;

  const MoreScreen({
    super.key,
    this.baseUrl,
    this.role = 'dispatcher',
    required this.initialSettings,
    this.onSettingsChanged,
  });

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  int _structures = 0;
  int _pending = 0;
  int _breadcrumbs = 0;
  int _unsyncedBreadcrumbs = 0;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.read<AuthService>();
    if (auth.isMapper && !_loading && _structures == 0) {
      _loadMapperStats();
    }
  }

  Future<void> _loadMapperStats() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final store = await LocalStore.open();
      final structures = await store.countStructures();
      final pending = await store.pendingCount();
      final crumbs = await store.breadcrumbCount();
      final unsynced = await store.unsyncedBreadcrumbCount();
      if (mounted) {
        setState(() {
          _structures = structures;
          _pending = pending;
          _breadcrumbs = crumbs;
          _unsyncedBreadcrumbs = unsynced;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    return Scaffold(
      backgroundColor: DSColors.surface0,
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        padding: const EdgeInsets.all(DSSpacing.md),
        children: [
          if (auth.isMapper) ...[
            if (_loading)
              const Center(child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              ))
            else ...[
              _statCard('Local structures', '$_structures', Icons.apartment_rounded),
              _statCard('Pending sync', '$_pending', Icons.sync_rounded),
              _statCard('GPS breadcrumbs', '$_breadcrumbs', Icons.route_rounded),
              _statCard('Unsynced points', '$_unsyncedBreadcrumbs', Icons.cloud_off_rounded),
              const SizedBox(height: DSSpacing.md),
              _tile(context, Icons.refresh_rounded, 'Refresh stats',
                  'Reload local data counts', _loadMapperStats),
            ],
            const Divider(),
          ],
          if (auth.isDispatcher) ...[
            _tile(context, Icons.add_task_rounded, 'Create dispatch',
                'Assign a responder to a structure', () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CreateDispatchScreen(baseUrl: widget.baseUrl, role: widget.role),
              ));
            }),
            _tile(context, Icons.history_rounded, 'History',
                'All dispatches and their outcomes', () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => HistoryScreen(baseUrl: widget.baseUrl, role: widget.role),
              ));
            }),
          ],
          if (!auth.isMapper)
            _tile(context, Icons.settings_rounded, 'Settings',
                'Server, theme and behaviour', () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SettingsScreen(
                  baseUrl: widget.baseUrl, role: widget.role,
                  initialSettings: widget.initialSettings,
                  onSettingsChanged: widget.onSettingsChanged,
                ),
              ));
            }),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout_rounded),
            title: const Text('Sign out'),
            subtitle: Text(auth.userName.isEmpty ? auth.currentRole.displayName : auth.userName),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => auth.logout(),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, IconData icon, String title, String sub, VoidCallback onTap) {
    return Card(
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(DSSpacing.sm),
          decoration: BoxDecoration(
            color: DSColors.primary.withOpacity(0.12),
            borderRadius: BorderRadius.circular(DSBorderRadius.md),
          ),
          child: Icon(icon, color: DSColors.primary),
        ),
        title: Text(title),
        subtitle: Text(sub),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }

  Widget _statCard(String label, String value, IconData icon) {
    return Card(
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(DSSpacing.sm),
          decoration: BoxDecoration(
            color: DSColors.primary.withOpacity(0.12),
            borderRadius: BorderRadius.circular(DSBorderRadius.md),
          ),
          child: Icon(icon, color: DSColors.primary),
        ),
        title: Text(label),
        subtitle: Text(value, style: DSTypography.headlineSmall.copyWith(fontWeight: FontWeight.w700)),
      ),
    );
  }
}
