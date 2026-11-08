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

class MoreScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    return Scaffold(
      backgroundColor: DSColors.surface0,
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        padding: const EdgeInsets.all(DSSpacing.md),
        children: [
          if (auth.isDispatcher) ...[
          _tile(context, Icons.add_task_rounded, 'Create dispatch',
              'Assign a responder to a structure', () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => CreateDispatchScreen(baseUrl: baseUrl, role: role),
            ));
          }),
          _tile(context, Icons.history_rounded, 'History',
              'All dispatches and their outcomes', () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => HistoryScreen(baseUrl: baseUrl, role: role),
            ));
          }),
          ],
          if (!auth.isMapper)
          _tile(context, Icons.settings_rounded, 'Settings',
              'Server, theme and behaviour', () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SettingsScreen(
                baseUrl: baseUrl, role: role,
                initialSettings: initialSettings,
                onSettingsChanged: onSettingsChanged,
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
}
