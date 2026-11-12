// Lookup Screen for Dispatcher App
// Core dispatch functionality with professional UI

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'design_system.dart';
import 'components.dart';
import 'map_view.dart';
import 'models.dart';
import 'package:provider/provider.dart';
import 'auth_service.dart';

class LookupScreen extends StatefulWidget {
  final String? baseUrl;
  final double stagingLat;
  final double stagingLon;
  final String role;

  const LookupScreen({
    super.key,
    this.baseUrl,
    required this.stagingLat,
    required this.stagingLon,
    this.role = 'dispatcher',
  });

  @override
  State<LookupScreen> createState() => _LookupScreenState();
}

class _LookupScreenState extends State<LookupScreen> {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final String _api = 'http://127.0.0.1:8090';
  bool _busy = false;
  bool _showStructureList = false;
  LookupResult? _lookup;
  RouteResult? _route;
  String? _outcomeNote;
  List<_StructureSummary> _allStructures = [];
  List<_StructureSummary> _filteredStructures = [];
  bool _loadingStructures = false;

  @override
  void initState() {
    super.initState();
    _loadStructures();
    _searchController.addListener(_filterStructures);
  }

  @override
  void dispose() {
    _codeController.dispose();
    _searchController.dispose();
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

  Future<void> _lookupCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;

    setState(() {
      _busy = true;
      _lookup = null;
      _route = null;
      _outcomeNote = null;
    });

    try {
      final base = widget.baseUrl ?? _api;
      final res = await http.post(
        Uri.parse('$base/v1/dispatch/lookup'),
        headers: await _headers(),
        // The registry asks the graph service for the route (GRAPH_URL); one
        // path, so the app never talks to the graph service directly.
        body: jsonEncode({
          'code': code,
          'profile': 'foot',
          'responder_location': {'lat': widget.stagingLat, 'lon': widget.stagingLon},
        }),
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final route = body['route'];

      setState(() {
        _lookup = LookupResult(
          res.statusCode == 200 ? body : null,
          res.statusCode == 200 ? null : (body['error'] ?? 'lookup_failed'),
          res.statusCode,
        );
        _route = (res.statusCode == 200 && route is Map<String, dynamic>)
            ? RouteResult.fromJson(route)
            : null;
      });
    } catch (e) {
      if (mounted) setState(() => _lookup = LookupResult(null, e.toString(), 0));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recordOutcome(String outcome) async {
    final lookup = _lookup?.data;
    if (lookup == null) return;

    try {
      final base = widget.baseUrl ?? _api;
      final assigned = await http.post(
        Uri.parse('$base/v1/dispatch/assign'),
        headers: await _headers(),
        body: jsonEncode({'code': lookup['code'], 'responder': 'unit-1'}),
      );
      final id = (jsonDecode(assigned.body) as Map)['dispatch_id'];
      await http.post(
        Uri.parse('$base/v1/dispatch/outcome'),
        headers: await _headers(),
        body: jsonEncode({
          'dispatch_id': id,
          'outcome': outcome,
          'code': lookup['code'],
          'actor': 'dispatch:unit-1',
        }),
      );
      if (mounted) {
        setState(() => _outcomeNote = outcome == 'failed'
            ? 'Recorded FAILURE — a mapper re-verification task was opened'
            : 'Recorded SUCCESS');
      }
    } catch (e) {
      if (mounted) setState(() => _outcomeNote = 'Could not record outcome: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lookup'),
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
                    'Structure Lookup',
                    style: DSTypography.displaySmall.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: DSSpacing.xs),
                  Text(
                    'Search structures or enter a code to dispatch',
                    style: DSTypography.bodyMedium.copyWith(
                      color: DSColors.textSecondary,
                    ),
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
                            'Known Structures (${_filteredStructures.length}/${_allStructures.length})',
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

          // Lookup form
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
              child: DSCard(
                padding: const EdgeInsets.all(DSSpacing.cardPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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
                            onSubmitted: (_) => _lookupCode(),
                          ),
                        ),
                        const SizedBox(width: DSSpacing.md),
                        DSPrimaryButton(
                          label: _busy ? 'Looking up...' : 'Look Up',
                          icon: _busy ? null : Icons.search_rounded,
                          isLoading: _busy,
                          isExpanded: false,
                          onPressed: _lookupCode,
                        ),
                      ],
                    ),
                    const SizedBox(height: DSSpacing.sm),
                    Text(
                      'Tip: Tap a structure from the list above to auto-fill the code',
                      style: DSTypography.bodySmall.copyWith(color: DSColors.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.sectionGap)),

          // Result
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
              child: _busy
                  ? DSLoadingState(message: 'Looking up structure...', size: 40)
                  : _lookup != null
                      ? _buildResult()
                      : DSEmptyState(
                          icon: Icons.qr_code_scanner_rounded,
                          title: 'Enter a structure code',
                          message: 'Type a code, search the list, or tap a structure to begin dispatch',
                        ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.xxl)),
        ],
      ),
    );
  }

  Widget _buildStructureListTile(_StructureSummary s) {
    final hasCode = s.code != null && s.code!.isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          _codeController.text = hasCode ? s.code! : s.id;
          _lookupCode();
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

  Color _getStatusColor(String? status) {
    return switch (status?.toLowerCase()) {
      'surveyed' || 'confirmed' || 'active' => DSColors.success,
      'pending' || 'under_review' => DSColors.warning,
      'failed' || 'inactive' => DSColors.error,
      _ => DSColors.textTertiary,
    };
  }

  DSStatusType _getStatusType(String? status) {
    return switch (status?.toLowerCase()) {
      'surveyed' || 'confirmed' || 'active' => DSStatusType.success,
      'pending' || 'under_review' => DSStatusType.warning,
      'failed' || 'inactive' => DSStatusType.error,
      _ => DSStatusType.neutral,
    };
  }

  Widget _buildResult() {
    final l = _lookup!;

    if (!l.ok) {
      return _buildErrorCard(l.error!, l.status);
    }

    final d = l.data!;
    final structure = (d['structure'] as Map?)?.cast<String, dynamic>() ?? {};
    final zone = (d['zone'] as Map?)?.cast<String, dynamic>() ?? {};
    final dest = (d['destination'] as Map).cast<String, dynamic>();

    return Column(
      children: [
        // Structure info card
        DSCard(
          padding: const EdgeInsets.all(DSSpacing.cardPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(DSSpacing.sm),
                    decoration: BoxDecoration(
                      color: DSColors.error.withOpacity( 0.15),
                      borderRadius: BorderRadius.circular(DSBorderRadius.md),
                    ),
                    child: Icon(Icons.place_rounded, color: DSColors.error, size: 24),
                  ),
                  const SizedBox(width: DSSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d['code'] as String,
                          style: DSTypography.headlineSmall.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Zone: ${zone['code'] ?? '?'} · ${structure['structure_type'] ?? 'Unknown'}',
                          style: DSTypography.bodyMedium.copyWith(
                            color: DSColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  DSStatusBadge(
                    label: structure['status'] ?? 'Unknown',
                    type: _getStatusType(structure['status']),
                  ),
                ],
              ),
              const SizedBox(height: DSSpacing.lg),
              Divider(color: DSColors.divider, height: 1),
              const SizedBox(height: DSSpacing.lg),
              Row(
                children: [
                  Icon(Icons.location_on_rounded, size: 18, color: DSColors.textTertiary),
                  const SizedBox(width: DSSpacing.sm),
                  Text(
                    '${dest['lat']}, ${dest['lon']}',
                    style: DSTypography.bodyMedium.copyWith(
                      color: DSColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: DSSpacing.md),
              // PRD 6.3: occupant context
              Row(
                children: [
                  Icon(Icons.person_off_rounded, size: 16, color: DSColors.textTertiary),
                  const SizedBox(width: DSSpacing.sm),
                  Expanded(
                    child: Text(
                      (d['occupant_context'] as Map?)?['present'] == true
                          ? 'Occupant context on file'
                          : 'No occupant context (not consented or not recorded)',
                      style: DSTypography.bodySmall.copyWith(
                        color: DSColors.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: DSSpacing.sectionGap),

        // Route card
        _buildRouteCard(),

        const SizedBox(height: DSSpacing.sectionGap),

        // Action buttons
        _buildActionButtons(),
      ],
    );
  }

  Widget _buildRouteCard() {
    final r = _route;

    return DSCard(
      padding: const EdgeInsets.all(DSSpacing.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.route_rounded, color: DSColors.primary, size: 22),
              const SizedBox(width: DSSpacing.sm),
              Text('Route', style: DSTypography.titleMedium.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              if (r != null)
                DSStatusBadge(
                  label: '${r.unverifiedLegs} inferred',
                  type: r.unverifiedLegs > 0 ? DSStatusType.warning : DSStatusType.success,
                  icon: r.unverifiedLegs > 0 ? Icons.warning_amber_rounded : Icons.verified_rounded,
                  isCompact: true,
                ),
            ],
          ),
          const SizedBox(height: DSSpacing.md),
          if (r == null)
            Text(
              'No route available. The destination is still known — send by the best available access point and report the outcome.',
              style: DSTypography.bodyMedium.copyWith(
                color: DSColors.textSecondary,
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (r.path.length >= 2) ...[
                  OfflineMapView(
                    height: 240,
                    pins: [
                      MapPin(
                        lat: r.path.last.lat,
                        lon: r.path.last.lon,
                        code: _lookup?.data?['code'] as String?,
                        label: 'Destination',
                      ),
                    ],
                    trail: r.path,
                    livePosition: r.path.first,
                  ),
                  const SizedBox(height: DSSpacing.md),
                ],
                Row(
                  children: [
                    _RouteMetric(
                      icon: Icons.straighten_rounded,
                      label: 'Distance',
                      value: '${(r.totalDistanceM / 1000).toStringAsFixed(1)} km',
                    ),
                    const SizedBox(width: DSSpacing.lg),
                    _RouteMetric(
                      icon: Icons.alt_route_rounded,
                      label: 'Legs',
                      value: '${r.legs.length}',
                    ),
                    const SizedBox(width: DSSpacing.lg),
                    _RouteMetric(
                      icon: Icons.layers_rounded,
                      label: 'Graph',
                      value: 'v${r.graphVersion}',
                    ),
                  ],
                ),
                if (r.warnings.isNotEmpty) ...[
                  const SizedBox(height: DSSpacing.md),
                  Divider(color: DSColors.divider, height: 1),
                  const SizedBox(height: DSSpacing.md),
                  ...r.warnings.map((w) => Padding(
                    padding: const EdgeInsets.only(bottom: DSSpacing.xs),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 16, color: DSColors.warning),
                        const SizedBox(width: DSSpacing.sm),
                        Expanded(
                          child: Text(
                            w,
                            style: DSTypography.bodySmall.copyWith(color: DSColors.warning),
                          ),
                        ),
                      ],
                    ),
                  )),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_outcomeNote != null) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: DSSpacing.md),
            child: Semantics(
              label: 'Outcome feedback',
              child: Text(_outcomeNote!, style: DSTypography.bodyMedium),
            ),
          ),
        ],
        Row(
      children: [
        Expanded(
          child: DSSecondaryButton(
            label: 'Reached',
            icon: Icons.check_rounded,
            onPressed: () => _recordOutcome('confirmed'),
          ),
        ),
        const SizedBox(width: DSSpacing.md),
        Expanded(
          child: DSPrimaryButton(
            label: 'Failed',
            icon: Icons.report_problem_rounded,
            onPressed: () => _recordOutcome('failed'),
          ),
        ),
      ],
        ),
      ],
    );
  }

  Widget _buildErrorCard(String error, int status) {
    final (icon, colour, advice) = switch (error) {
      'outside_mapped_zone' => (
        Icons.block_rounded,
        DSColors.error,
        'Dispatch is limited to the pilot mapped zone. Ask a mapper team to survey this zone.',
      ),
      'structure_in_dedup_review' => (
        Icons.help_outline_rounded,
        DSColors.warning,
        'Identity is unresolved. A human must review the duplicate before anyone is sent.',
      ),
      'code_not_finalized' => (
        Icons.pause_circle_outline_rounded,
        DSColors.warning,
        'This structure has no stable code yet.',
      ),
      'code_superseded' => (
        Icons.sync_problem_rounded,
        DSColors.warning,
        'This placard is out of date — the structure was merged. Use the surviving code.',
      ),
      'structure_not_found' => (
        Icons.search_off_rounded,
        DSColors.error,
        'No such code.',
      ),
      _ => (Icons.error_rounded, DSColors.error, 'Lookup failed.'),
    };

    return DSCard(
      padding: const EdgeInsets.all(DSSpacing.cardPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(DSSpacing.sm),
            decoration: BoxDecoration(
              color: colour.withOpacity( 0.15),
              borderRadius: BorderRadius.circular(DSBorderRadius.md),
            ),
            child: Icon(icon, color: colour, size: 28),
          ),
          const SizedBox(width: DSSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'HTTP $status',
                      style: DSTypography.labelMedium.copyWith(
                        color: DSColors.textTertiary,
                      ),
                    ),
                    const SizedBox(width: DSSpacing.sm),
                    DSStatusBadge(
                      label: 'ERROR',
                      type: DSStatusType.error,
                      isCompact: true,
                    ),
                  ],
                ),
                const SizedBox(height: DSSpacing.xs),
                Text(error, style: DSTypography.titleMedium),
                const SizedBox(height: DSSpacing.sm),
                Text(advice, style: DSTypography.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteMetric extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _RouteMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(DSSpacing.sm),
            decoration: BoxDecoration(
              color: DSColors.primary.withOpacity( 0.15),
              borderRadius: BorderRadius.circular(DSBorderRadius.md),
            ),
            child: Icon(icon, color: DSColors.primary, size: 20),
          ),
          const SizedBox(height: DSSpacing.sm),
          Text(
            value,
            style: DSTypography.titleMedium.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            label,
            style: DSTypography.labelSmall.copyWith(color: DSColors.textTertiary),
          ),
        ],
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