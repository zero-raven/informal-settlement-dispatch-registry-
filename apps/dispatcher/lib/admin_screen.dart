// Admin Screen — admin-only management panel.
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:provider/provider.dart';

import 'design_system.dart';
import 'components.dart';
import 'auth_service.dart';

class AdminScreen extends StatefulWidget {
  final String? baseUrl;
  final String role;

  const AdminScreen({super.key, this.baseUrl, this.role = 'admin'});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final String _api = 'http://127.0.0.1:8090';

  bool _isLoading = true;
  List<_AdminStructure> _structures = [];
  List<_AdminUser> _users = [];

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<Map<String, String>> _headers() async =>
      context.read<AuthService>().getAuthHeaders();

  Future<void> _loadAll() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final base = widget.baseUrl ?? _api;
      final headers = await _headers();
      final results = await Future.wait([
        http.get(Uri.parse('$base/v1/structures?include_deleted=true'), headers: headers),
        http.get(Uri.parse('$base/v1/admin/users'), headers: headers),
      ]);
      if (!mounted) return;

      if (results[0].statusCode == 200) {
        final data = jsonDecode(results[0].body) as Map<String, dynamic>;
        _structures = (data['structures'] as List? ?? [])
            .map((e) => _AdminStructure.fromJson(e))
            .toList();
      } else {
        _error = 'Failed to load structures: HTTP ${results[0].statusCode}';
      }

      if (results[1].statusCode == 200) {
        final data = jsonDecode(results[1].body) as Map<String, dynamic>;
        _users = (data['users'] as List? ?? [])
            .map((e) => _AdminUser.fromJson(e))
            .toList();
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteStructure(_AdminStructure s) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete structure?'),
        content: Text('Soft-delete ${s.code} (${s.id})? This marks it as deleted but keeps history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: DSColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _isLoading = true);
    try {
      final base = widget.baseUrl ?? _api;
      final headers = await _headers();
      final res = await http.delete(
        Uri.parse('$base/v1/admin/structures/${s.id}'),
        headers: headers,
      );
      if (res.statusCode == 200) {
        await _loadAll();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted: ${s.code}'), backgroundColor: DSColors.success),
          );
        }
      } else {
        final body = jsonDecode(res.body);
        throw Exception(body['error'] ?? 'Delete failed');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: DSColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin Panel')),
      backgroundColor: DSColors.surface0,
      body: RefreshIndicator(
        onRefresh: _loadAll,
        child: ListView(
          padding: const EdgeInsets.all(DSSpacing.md),
          children: [
            _section('Structures', '${_structures.length} total', Icons.apartment_rounded, _buildStructuresList()),
            const SizedBox(height: DSSpacing.lg),
            _section('Users', '${_users.length} accounts', Icons.people_rounded, _buildUsersList()),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, String subtitle, IconData icon, Widget child) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(DSSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: DSColors.primary),
                const SizedBox(width: DSSpacing.sm),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: DSTypography.titleMedium.copyWith(fontWeight: FontWeight.w600)),
                    Text(subtitle, style: DSTypography.bodySmall.copyWith(color: DSColors.textSecondary)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: DSSpacing.md),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildStructuresList() {
    if (_isLoading && _structures.isEmpty) {
      return const Center(child: Padding(
        padding: EdgeInsets.all(32),
        child: CircularProgressIndicator(),
      ));
    }
    if (_structures.isEmpty) {
      return const ListTile(
        leading: Icon(Icons.inbox_rounded),
        title: Text('No structures'),
        subtitle: Text('Structures will appear here after mapping.'),
      );
    }
    return Column(
      children: _structures.map((s) => Card(
        child: ListTile(
          leading: Icon(s.deleted ? Icons.delete_outline_rounded : Icons.apartment_rounded,
              color: s.deleted ? DSColors.error : DSColors.primary),
          title: Text(s.code.isEmpty ? s.id : s.code),
          subtitle: Text('${s.id} · ${s.deleted ? 'DELETED' : 'Active'} · ${s.type}'),
          trailing: s.deleted
              ? const Chip(label: Text('Deleted'), backgroundColor: Color(0xFFFFEBEE))
              : IconButton(
                  icon: const Icon(Icons.delete_rounded, color: DSColors.error),
                  onPressed: () => _deleteStructure(s),
                  tooltip: 'Soft delete',
                ),
        ),
      )).toList(),
    );
  }

  Widget _buildUsersList() {
    if (_users.isEmpty) {
      return const ListTile(
        leading: Icon(Icons.people_outline_rounded),
        title: Text('No users loaded'),
        subtitle: Text('User management requires backend /v1/admin/users endpoint.'),
      );
    }
    return Column(
      children: _users.map((u) => Card(
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: DSColors.primary.withOpacity(0.15),
            child: Text(u.username[0].toUpperCase(), style: const TextStyle(color: DSColors.primary)),
          ),
          title: Text(u.username),
          subtitle: Text('Role: ${u.role} · ${u.active ? 'Active' : 'Inactive'}'),
          trailing: Chip(
            label: Text(u.role.toUpperCase()),
            backgroundColor: u.active ? DSColors.success.withOpacity(0.15) : DSColors.error.withOpacity(0.15),
            labelStyle: TextStyle(color: u.active ? DSColors.success : DSColors.error),
          ),
        ),
      )).toList(),
    );
  }
}

class _AdminStructure {
  final String id;
  final String code;
  final String type;
  final bool deleted;

  _AdminStructure({required this.id, required this.code, required this.type, required this.deleted});

  factory _AdminStructure.fromJson(Map<String, dynamic> json) {
    return _AdminStructure(
      id: json['id'] ?? '',
      code: json['code'] ?? '',
      type: json['structure_type'] ?? 'unknown',
      deleted: json['deleted_at'] != null,
    );
  }
}

class _AdminUser {
  final String username;
  final String role;
  final bool active;

  _AdminUser({required this.username, required this.role, required this.active});

  factory _AdminUser.fromJson(Map<String, dynamic> json) {
    return _AdminUser(
      username: json['username'] ?? '',
      role: json['role'] ?? '',
      active: json['active'] ?? true,
    );
  }
}