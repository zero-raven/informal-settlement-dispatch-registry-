// Create Dispatch Screen for Dispatcher App
// Standalone dispatch request creation and management

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'design_system.dart';
import 'components.dart';
import 'models.dart';

class CreateDispatchScreen extends StatefulWidget {
  final String? baseUrl;
  final String role;

  const CreateDispatchScreen({super.key, this.baseUrl, this.role = 'dispatcher'});

  @override
  State<CreateDispatchScreen> createState() => _CreateDispatchScreenState();
}

class _CreateDispatchScreenState extends State<CreateDispatchScreen> {
  final String _api = 'http://127.0.0.1:8090';
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _responderController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  bool _isLoading = false;
  bool _isLookingUp = false;
  StructureInfo? _structureInfo;
  String? _error;
  List<DispatchItem> _pendingDispatches = [];

  @override
  void initState() {
    super.initState();
    _loadPendingDispatches();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _responderController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<Map<String, String>> _headers() async =>
      {'Content-Type': 'application/json', 'X-Role': widget.role};

  Future<void> _loadPendingDispatches() async {
    try {
      final base = widget.baseUrl ?? _api;
      final res = await http.get(
        Uri.parse('$base/v1/dispatch/recent?limit=20'),
        headers: await _headers(),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final all = (data['dispatches'] as List)
            .map((e) => DispatchItem.fromJson(e))
            .toList();
        setState(() {
          _pendingDispatches = all.where((d) =>
            d.status != 'confirmed' && d.status != 'failed'
          ).toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _lookupStructure() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.isEmpty) return;

    setState(() {
      _isLookingUp = true;
      _structureInfo = null;
      _error = null;
    });

    try {
      final base = widget.baseUrl ?? _api;
      final res = await http.post(
        Uri.parse('$base/v1/dispatch/lookup'),
        headers: await _headers(),
        body: jsonEncode({'code': code, 'profile': 'foot'}),
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;

      if (res.statusCode == 200) {
        setState(() {
          _structureInfo = StructureInfo(
            code: body['code'] as String,
            destination: (body['destination'] as Map).cast<String, dynamic>(),
            zone: (body['zone'] as Map).cast<String, dynamic>(),
            structure: (body['structure'] as Map).cast<String, dynamic>(),
            route: body['route'],
          );
        });
      } else {
        setState(() => _error = body['error']?.toString() ?? 'Lookup failed');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLookingUp = false);
    }
  }

  Future<void> _createDispatch() async {
    if (_structureInfo == null || _responderController.text.trim().isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final base = widget.baseUrl ?? _api;
      
      // Step 1: Assign
      final assignRes = await http.post(
        Uri.parse('$base/v1/dispatch/assign'),
        headers: await _headers(),
        body: jsonEncode({
          'code': _structureInfo!.code,
          'responder': _responderController.text.trim(),
        }),
      );

      if (assignRes.statusCode != 200) {
        final body = jsonDecode(assignRes.body);
        throw Exception(body['error'] ?? 'Assign failed');
      }

      final assignData = jsonDecode(assignRes.body) as Map<String, dynamic>;
      final dispatchId = assignData['dispatch_id'] as String;

      // Step 2: If notes provided, we could store them (backend doesn't have notes field yet)
      // For now just show success

      setState(() {
        _codeController.clear();
        _responderController.clear();
        _notesController.clear();
        _structureInfo = null;
        _error = null;
      });

      _loadPendingDispatches();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Dispatch created: $dispatchId', style: DSTypography.bodyMedium.copyWith(color: Colors.white)),
            backgroundColor: DSColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DSBorderRadius.md)),
          ),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
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
                    'Create Dispatch',
                    style: DSTypography.displaySmall.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: DSSpacing.xs),
                  Text(
                    'Assign a responder to a structure',
                    style: DSTypography.bodyMedium.copyWith(color: DSColors.textSecondary),
                  ),
                ],
              ),
            ),
          ),

          // Structure Lookup Section
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
              child: DSCard(
                padding: const EdgeInsets.all(DSSpacing.cardPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.qr_code_rounded, color: DSColors.primary, size: 22),
                        const SizedBox(width: DSSpacing.sm),
                        Text('Structure Lookup', style: DSTypography.titleMedium.copyWith(fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: DSSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _codeController,
                            textCapitalization: TextCapitalization.characters,
                            decoration: InputDecoration(
                              labelText: 'Structure Code',
                              hintText: 'SLR-C41001',
                              prefixIcon: const Icon(Icons.qr_code_rounded),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(DSBorderRadius.md),
                              ),
                            ),
                            onSubmitted: (_) => _lookupStructure(),
                          ),
                        ),
                        const SizedBox(width: DSSpacing.md),
                        DSPrimaryButton(
                          label: _isLookingUp ? 'Looking up...' : 'Lookup',
                          icon: _isLookingUp ? null : Icons.search_rounded,
                          isLoading: _isLookingUp,
                          isExpanded: false,
                          onPressed: _lookupStructure,
                        ),
                      ],
                    ),
                    if (_isLookingUp) ...[
                      const SizedBox(height: DSSpacing.md),
                      const DSLoadingState(message: 'Validating structure...', size: 32),
                    ],
                    if (_error != null && _structureInfo == null) ...[
                      const SizedBox(height: DSSpacing.md),
                      DSErrorState(
                        title: 'Lookup Failed',
                        message: _error!,
                        compact: true,
                      ),
                    ],
                    if (_structureInfo != null) ...[
                      const SizedBox(height: DSSpacing.md),
                      Divider(color: DSColors.divider, height: 1),
                      const SizedBox(height: DSSpacing.md),
                      _buildStructureInfo(_structureInfo!),
                    ],
                  ],
                ),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.sectionGap)),

          // Assign Responder Section
          if (_structureInfo != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
                child: DSCard(
                  padding: const EdgeInsets.all(DSSpacing.cardPadding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.person_rounded, color: DSColors.primary, size: 22),
                          const SizedBox(width: DSSpacing.sm),
                          Text('Assign Responder', style: DSTypography.titleMedium.copyWith(fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: DSSpacing.md),
                      TextField(
                        controller: _responderController,
                        decoration: InputDecoration(
                          labelText: 'Responder ID / Name',
                          hintText: 'unit-1, team-alpha, etc.',
                          prefixIcon: const Icon(Icons.badge_rounded),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(DSBorderRadius.md),
                          ),
                        ),
                      ),
                      const SizedBox(height: DSSpacing.md),
                      TextField(
                        controller: _notesController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: 'Notes (optional)',
                          hintText: 'Priority, special instructions, etc.',
                          prefixIcon: const Icon(Icons.note_rounded),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(DSBorderRadius.md),
                          ),
                        ),
                      ),
                      const SizedBox(height: DSSpacing.md),
                      DSActionRow(
                        actions: [
                          DSPrimaryButton(
                            label: _isLoading ? 'Creating...' : 'Create Dispatch',
                            icon: _isLoading ? null : Icons.send_rounded,
                            isLoading: _isLoading,
                            onPressed: _createDispatch,
                          ),
                        ],
                        alignment: WrapAlignment.end,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.sectionGap)),

          // Pending Dispatches Section
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
              child: DSSectionHeader(
                title: 'Pending Dispatches',
                subtitle: 'Active assignments awaiting outcome',
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
              child: _pendingDispatches.isEmpty
                  ? DSEmptyState(
                      icon: Icons.local_shipping_outlined,
                      title: 'No pending dispatches',
                      message: 'Create a dispatch to see it here.',
                    )
                  : DSCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: _pendingDispatches.map((d) => _buildPendingTile(d)).toList(),
                      ),
                    ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.xxl)),
        ],
      ),
    );
  }

  Widget _buildStructureInfo(StructureInfo info) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(DSSpacing.sm),
              decoration: BoxDecoration(
                color: DSColors.primary.withOpacity(0.15),
                borderRadius: BorderRadius.circular(DSBorderRadius.md),
              ),
              child: Icon(Icons.place_rounded, color: DSColors.primary, size: 22),
            ),
            const SizedBox(width: DSSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.code,
                    style: DSTypography.titleMedium.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'Zone: ${info.zone['code']} · ${info.structure['structure_type']}',
                    style: DSTypography.bodySmall.copyWith(color: DSColors.textSecondary),
                  ),
                ],
              ),
            ),
            DSStatusBadge(
              label: info.structure['status']?.toString().toUpperCase() ?? 'UNKNOWN',
              type: _getStatusType(info.structure['status'] as String?),
            ),
          ],
        ),
        const SizedBox(height: DSSpacing.md),
        Row(
          children: [
            Icon(Icons.location_on_rounded, size: 16, color: DSColors.textTertiary),
            const SizedBox(width: DSSpacing.sm),
            Text(
              '${info.destination['lat']}, ${info.destination['lon']}',
              style: DSTypography.bodySmall.copyWith(color: DSColors.textSecondary),
            ),
            const SizedBox(width: DSSpacing.lg),
            if (info.route != null) ...[
              Icon(Icons.route_rounded, size: 16, color: DSColors.textTertiary),
              const SizedBox(width: DSSpacing.sm),
              Text(
                '${(info.route!['total_distance_m'] as num? ?? 0 / 1000).toStringAsFixed(1)} km',
                style: DSTypography.bodySmall.copyWith(color: DSColors.textSecondary),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildPendingTile(DispatchItem dispatch) {
    final statusColor = switch (dispatch.status) {
      'confirmed' => DSColors.success,
      'failed' => DSColors.error,
      'pending' => DSColors.warning,
      'assigned' => DSColors.info,
      _ => DSColors.textTertiary,
    };

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showDispatchDetail(dispatch),
        child: Padding(
          padding: const EdgeInsets.all(DSSpacing.cardPadding),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(DSSpacing.sm),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(DSBorderRadius.md),
                ),
                child: Icon(
                  dispatch.status == 'assigned' ? Icons.local_shipping_rounded :
                  dispatch.status == 'pending' ? Icons.hourglass_top_rounded :
                  Icons.help_outline_rounded,
                  color: statusColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: DSSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            dispatch.code,
                            style: DSTypography.titleMedium.copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: DSSpacing.sm),
                        DSStatusBadge(
                          label: dispatch.status.toUpperCase(),
                          type: _getStatusType(dispatch.status),
                          isCompact: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: DSSpacing.xs),
                    Text(
                      'Responder: ${dispatch.responder}',
                      style: DSTypography.bodySmall.copyWith(color: DSColors.textSecondary),
                    ),
                    Text(
                      '${_formatTime(dispatch.timestamp)}',
                      style: DSTypography.labelSmall.copyWith(color: DSColors.textTertiary),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: DSColors.textTertiary, size: 24),
            ],
          ),
        ),
      ),
    );
  }

  void _showDispatchDetail(DispatchItem dispatch) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _DispatchDetailSheet(dispatch: dispatch),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Color _getStatusColor(String? status) {
    return switch (status?.toLowerCase()) {
      'active' || 'confirmed' || 'assigned' => DSColors.success,
      'failed' || 'rejected' => DSColors.error,
      'pending' || 'corroborating' => DSColors.warning,
      'candidate' => DSColors.info,
      _ => DSColors.textTertiary,
    };
  }

  DSStatusType _getStatusType(String? status) {
    return switch (status?.toLowerCase()) {
      'active' || 'confirmed' || 'assigned' => DSStatusType.success,
      'failed' || 'rejected' => DSStatusType.error,
      'pending' || 'corroborating' => DSStatusType.warning,
      'candidate' => DSStatusType.info,
      _ => DSStatusType.neutral,
    };
  }
}

class StructureInfo {
  final String code;
  final Map<String, dynamic> destination;
  final Map<String, dynamic> zone;
  final Map<String, dynamic> structure;
  final Map<String, dynamic>? route;

  StructureInfo({
    required this.code,
    required this.destination,
    required this.zone,
    required this.structure,
    this.route,
  });
}

class _DispatchDetailSheet extends StatelessWidget {
  final DispatchItem dispatch;

  const _DispatchDetailSheet({required this.dispatch});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusColor = switch (dispatch.status) {
      'confirmed' => DSColors.success,
      'failed' => DSColors.error,
      'pending' => DSColors.warning,
      'assigned' => DSColors.info,
      _ => DSColors.textTertiary,
    };

    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: isDark ? DSColors.surface1 : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(DSBorderRadius.xl)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: DSSpacing.md),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: DSColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(DSSpacing.cardPadding),
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(DSSpacing.md),
                        decoration: BoxDecoration(
                          color: statusColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(DSBorderRadius.md),
                        ),
                        child: Icon(
                          dispatch.status == 'confirmed'
                              ? Icons.check_circle_rounded
                              : dispatch.status == 'failed'
                                  ? Icons.cancel_rounded
                                  : dispatch.status == 'assigned'
                                      ? Icons.local_shipping_rounded
                                      : Icons.hourglass_top_rounded,
                          color: statusColor,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: DSSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              dispatch.code,
                              style: DSTypography.headlineSmall.copyWith(fontWeight: FontWeight.w700),
                            ),
                            DSStatusBadge(
                              label: dispatch.status.toUpperCase(),
                              type: switch (dispatch.status) {
                                'confirmed' => DSStatusType.success,
                                'failed' => DSStatusType.error,
                                'pending' => DSStatusType.warning,
                                'assigned' => DSStatusType.info,
                                _ => DSStatusType.neutral,
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: DSSpacing.lg),
                  Divider(color: DSColors.divider, height: 1),
                  const SizedBox(height: DSSpacing.lg),
                  _DetailRow(
                    icon: Icons.person_rounded,
                    label: 'Responder',
                    value: dispatch.responder,
                  ),
                  _DetailRow(
                    icon: Icons.access_time_rounded,
                    label: 'Assigned',
                    value: dispatch.timestamp.toString().substring(0, 19).replaceAll('T', ' '),
                  ),
                  if (dispatch.outcome != null) ...[
                    _DetailRow(
                      icon: Icons.flag_rounded,
                      label: 'Outcome',
                      value: dispatch.outcome!.toUpperCase(),
                    ),
                    if (dispatch.outcomeAt != null)
                      _DetailRow(
                        icon: Icons.check_circle_outline_rounded,
                        label: 'Completed',
                        value: dispatch.outcomeAt!.toString().substring(0, 19).replaceAll('T', ' '),
                      ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(DSSpacing.lg),
              child: DSPrimaryButton(
                label: 'Close',
                icon: Icons.close_rounded,
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: DSSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: DSColors.textTertiary),
          const SizedBox(width: DSSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: DSTypography.labelSmall.copyWith(color: DSColors.textTertiary)),
                Text(value, style: DSTypography.bodyMedium.copyWith(fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}