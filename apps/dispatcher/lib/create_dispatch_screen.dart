// Create Dispatch Screen for Dispatcher App
// Standalone dispatch request creation and management

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'design_system.dart';
import 'components.dart';
import 'models.dart';
import 'package:provider/provider.dart';
import 'auth_service.dart';

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
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _responderController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  bool _isLoading = false;
  bool _isLookingUp = false;
  bool _showStructureList = false;
  StructureInfo? _structureInfo;
  String? _error;
  List<DispatchItem> _pendingDispatches = [];
  List<_StructureSummary> _allStructures = [];
  List<_StructureSummary> _filteredStructures = [];
  bool _loadingStructures = false;

  @override
  void initState() {
    super.initState();
    _loadPendingDispatches();
    _loadStructures();
    _searchController.addListener(_filterStructures);
  }

  @override
  void dispose() {
    _codeController.dispose();
    _searchController.dispose();
    _responderController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadStructures() async {
    setState(() => _loadingStructures = true);
    try {
      final base = widget.baseUrl ?? _api;
      final headers = await _headers();
      final res = await http.get(
        Uri.parse('$base/v1/structures?include_deleted=false'),
        headers: headers,
      ).timeout(const Duration(seconds: 10));
      
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final structures = (data['structures'] as List? ?? []);
        if (mounted) {
          setState(() {
            _allStructures = structures.map((e) => _StructureSummary.fromJson(e)).toList();
            _filteredStructures = _allStructures;
            _loadingStructures = false;
          });
        }
      } else {
        if (mounted) setState(() => _loadingStructures = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loadingStructures = false);
    }
  }

  void _filterStructures() {
    final query = _searchController.text.toLowerCase().trim();
    setState(() {
      if (query.isEmpty) {
        _filteredStructures = _allStructures;
      } else {
        _filteredStructures = _allStructures.where((s) =>
          (s.code?.toLowerCase().contains(query) ?? false) ||
          s.id.toLowerCase().contains(query) ||
          (s.type?.toLowerCase().contains(query) ?? false) ||
          (s.status?.toLowerCase().contains(query) ?? false)
        ).toList();
      }
    });
  }

  Future<Map<String, String>> _headers() async =>
      context.read<AuthService>().getAuthHeaders();

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
      if (_structureInfo == null) {
        setState(() => _error = 'Please lookup a structure code first.');
        return;
      }
      if (_responderController.text.trim().isEmpty) {
        setState(() => _error = 'Please enter a responder name/ID.');
        return;
      }

      setState(() { _isLoading = true; _error = null; });

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
          throw Exception(body['error'] ?? 'Assign failed (HTTP ${assignRes.statusCode})');
        }

        final assignData = jsonDecode(assignRes.body) as Map<String, dynamic>;
        final dispatchId = assignData['dispatch_id'] as String;

        // Clear form on success
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
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create dispatch'),
        actions: [
          IconButton(
            icon: Icon(_showStructureList ? Icons.close_rounded : Icons.list_rounded),
            onPressed: () => setState(() => _showStructureList = !_showStructureList),
            tooltip: _showStructureList ? 'Hide list' : 'Show all structures',
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadStructures,
            tooltip: 'Refresh structures',
          ),
        ],
      ),
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

          // Structure list panel
          if (_showStructureList)
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
                          Icon(Icons.apartment_rounded, color: DSColors.primary, size: 22),
                          const SizedBox(width: DSSpacing.sm),
                          Text(
                            'Available Structures (${_filteredStructures.length}/${_allStructures.length})',
                            style: DSTypography.titleMedium.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const Spacer(),
                          if (_loadingStructures)
                            const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                      const SizedBox(height: DSSpacing.md),
                      TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          labelText: 'Search structures',
                          hintText: 'Search by code, ID, type, or status...',
                          prefixIcon: const Icon(Icons.search_rounded),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(DSBorderRadius.md),
                          ),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear_rounded),
                                  onPressed: () => _searchController.clear(),
                                )
                              : null,
                        ),
                      ),
                      const SizedBox(height: DSSpacing.md),
                      if (_filteredStructures.isEmpty && !_loadingStructures)
                        DSEmptyState(
                          icon: Icons.apartment_outlined,
                          title: _searchController.text.isEmpty ? 'No structures mapped' : 'No matches found',
                          message: _searchController.text.isEmpty
                              ? 'Mapper teams need to survey the area first.'
                              : 'Try a different search term.',
                          compact: true,
                        )
                      else
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 400),
                          child: ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _filteredStructures.length,
                            separatorBuilder: (_, __) => Divider(
                              color: DSColors.divider,
                              height: 1,
                              indent: DSSpacing.md,
                              endIndent: DSSpacing.md,
                            ),
                            itemBuilder: (_, index) => _buildStructureListTile(_filteredStructures[index]),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.sectionGap)),

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
                    const SizedBox(height: DSSpacing.sm),
                    Text(
                      'Tip: Tap a structure from the list above to auto-fill the code',
                      style: DSTypography.bodySmall.copyWith(color: DSColors.textTertiary),
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
                    if (_error != null && _structureInfo == null) ...[
                      const SizedBox(height: DSSpacing.md),
                      DSErrorState(
                        title: 'Cannot create dispatch',
                        message: _error!,
                        compact: true,
                      ),
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
                      if (_error != null) ...[
                        const SizedBox(height: DSSpacing.md),
                        DSErrorState(
                          title: 'Dispatch failed',
                          message: _error!,
                          compact: true,
                        ),
                      ],
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

  Widget _buildStructureListTile(_StructureSummary s) {
    final hasCode = s.code != null && s.code!.isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          _codeController.text = hasCode ? s.code! : s.id;
          _lookupStructure();
          setState(() => _showStructureList = false);
        },
        borderRadius: BorderRadius.circular(DSBorderRadius.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: DSSpacing.md,
            vertical: DSSpacing.sm,
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(DSSpacing.sm),
                decoration: BoxDecoration(
                  color: _getStatusColor(s.status).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(DSBorderRadius.md),
                ),
                child: Icon(
                  Icons.apartment_rounded,
                  color: _getStatusColor(s.status),
                  size: 20,
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
                            hasCode ? s.code! : s.id,
                            style: DSTypography.titleSmall.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: DSSpacing.sm),
                        DSStatusBadge(
                          label: (s.status ?? 'unknown').toUpperCase(),
                          type: _getStatusType(s.status),
                          isCompact: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: DSSpacing.xs),
                    Text(
                      '${s.type ?? 'Unknown'} · ${s.coords}',
                      style: DSTypography.bodySmall.copyWith(color: DSColors.textTertiary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                color: DSColors.textTertiary,
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }


}


class _StructureSummary {
  final String id;
  final String? code;
  final String? type;
  final String? status;
  final double? lat;
  final double? lon;

  _StructureSummary({
    required this.id,
    this.code,
    this.type,
    this.status,
    this.lat,
    this.lon,
  });

  factory _StructureSummary.fromJson(Map<String, dynamic> json) {
    return _StructureSummary(
      id: json['id'] ?? '',
      code: json['code'] as String?,
      type: json['structure_type'] as String?,
      status: json['status'] as String?,
      lat: (json['lat'] as num?)?.toDouble(),
      lon: (json['lon'] as num?)?.toDouble(),
    );
  }

  String get coords {
    if (lat != null && lon != null) {
      return '${lat!.toStringAsFixed(4)}, ${lon!.toStringAsFixed(4)}';
    }
    return 'Unknown location';
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
