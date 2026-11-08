// History/Logs Screen for Dispatcher App

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'design_system.dart';
import 'components.dart';
import 'models.dart';
import 'package:provider/provider.dart';
import 'auth_service.dart';

class HistoryScreen extends StatefulWidget {
  final String? baseUrl;
  final String role;

  const HistoryScreen({super.key, this.baseUrl, this.role = 'dispatcher'});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final String _api = 'http://127.0.0.1:8090';

  List<DispatchItem> _dispatches = [];
  bool _isLoading = true;
  String? _error;
  String _filter = 'all';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    try {
      final base = widget.baseUrl ?? _api;
      final headers = context.read<AuthService>().getAuthHeaders();

      final res = await http.get(
        Uri.parse('$base/v1/dispatch/recent?limit=100'),
        headers: headers,
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _dispatches = (data['dispatches'] as List)
            .map((e) => DispatchItem.fromJson(e))
            .toList();
      } else {
        _error = 'Failed to load history: ${res.statusCode}';
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<DispatchItem> get _filteredDispatches {
    return _dispatches.where((d) {
      if (_filter != 'all' && d.status != _filter) return false;
      if (_searchController.text.isNotEmpty) {
        final query = _searchController.text.toLowerCase();
        if (!d.code.toLowerCase().contains(query) &&
            !d.responder.toLowerCase().contains(query)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
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
                    'Dispatch History',
                    style: DSTypography.displaySmall.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: DSSpacing.xs),
                  Text(
                    'All recorded dispatches and outcomes',
                    style: DSTypography.bodyMedium.copyWith(
                      color: DSColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: DSSpacing.lg),

                  // Search and filter row
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: 'Search by code or responder...',
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: _searchController.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear_rounded),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() {});
                                    },
                                  )
                                : null,
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: DSSpacing.md),
                      _FilterChips(
                        selectedFilter: _filter,
                        onChanged: (value) => setState(() => _filter = value),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // List
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
              child: _isLoading
                  ? DSSkeletonList(itemCount: 5, itemHeight: 96)
                  : _error != null
                      ? DSErrorState(
                          title: 'Failed to load history',
                          message: _error!,
                          onRetry: _loadHistory,
                        )
                      : _filteredDispatches.isEmpty
                          ? DSEmptyState(
                              icon: Icons.history_rounded,
                              title: _searchController.text.isNotEmpty
                                  ? 'No matching dispatches'
                                  : 'No dispatch history',
                              message: _searchController.text.isNotEmpty
                                  ? 'Try adjusting your search or filter'
                                  : 'Dispatches will appear here once recorded.',
                              action: _searchController.text.isNotEmpty
                                  ? DSSecondaryButton(
                                      label: 'Clear Search',
                                      onPressed: () {
                                        _searchController.clear();
                                        setState(() {});
                                      },
                                    )
                                  : null,
                            )
                          : Column(
                              children: _filteredDispatches
                                  .map((d) => _buildDispatchTile(d))
                                  .toList(),
                            ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.xxl)),
        ],
      ),
    );
  }

  Widget _buildDispatchTile(DispatchItem dispatch) {
    final statusColor = switch (dispatch.status) {
      'confirmed' => DSColors.success,
      'failed' => DSColors.error,
      'pending' => DSColors.warning,
      _ => DSColors.textTertiary,
    };

    final statusIcon = switch (dispatch.status) {
      'confirmed' => Icons.check_circle_rounded,
      'failed' => Icons.cancel_rounded,
      'pending' => Icons.hourglass_top_rounded,
      _ => Icons.help_outline_rounded,
    };

    return DSCard(
      margin: const EdgeInsets.only(bottom: DSSpacing.sm),
      padding: const EdgeInsets.all(DSSpacing.md),
      onTap: () => _showDispatchDetail(dispatch),
      isInteractive: true,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(DSSpacing.sm),
            decoration: BoxDecoration(
              color: statusColor.withOpacity( 0.15),
              borderRadius: BorderRadius.circular(DSBorderRadius.md),
            ),
            child: Icon(statusIcon, color: statusColor, size: 22),
          ),
          const SizedBox(width: DSSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        dispatch.code,
                        style: DSTypography.titleMedium.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: DSSpacing.sm),
                    DSStatusBadge(
                      label: dispatch.status.toUpperCase(),
                      type: switch (dispatch.status) {
                        'confirmed' => DSStatusType.success,
                        'failed' => DSStatusType.error,
                        'pending' => DSStatusType.warning,
                        _ => DSStatusType.neutral,
                      },
                      isCompact: true,
                    ),
                  ],
                ),
                const SizedBox(height: DSSpacing.xs),
                Row(
                  children: [
                    Icon(
                      Icons.location_on_rounded,
                      size: 14,
                      color: DSColors.textTertiary,
                    ),
                    const SizedBox(width: DSSpacing.xs),
                    Expanded(
                      child: Text(
                        '${dispatch.destination['lat']?.toStringAsFixed(4)}, ${dispatch.destination['lon']?.toStringAsFixed(4)}',
                        style: DSTypography.bodySmall.copyWith(
                          color: DSColors.textTertiary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: DSSpacing.xs),
                Text(
                  '${_formatTime(dispatch.timestamp)} · ${dispatch.responder}',
                  style: DSTypography.labelSmall.copyWith(
                    color: DSColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: DSColors.textTertiary,
            size: 24,
          ),
        ],
      ),
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

  void _showDispatchDetail(DispatchItem dispatch) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _DispatchDetailSheet(dispatch: dispatch),
    );
  }
}

class _FilterChips extends StatelessWidget {
  final String selectedFilter;
  final ValueChanged<String> onChanged;

  const _FilterChips({
    required this.selectedFilter,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final filters = [
      ('all', 'All', Icons.list_rounded),
      ('confirmed', 'Success', Icons.check_circle_rounded),
      ('failed', 'Failed', Icons.cancel_rounded),
      ('pending', 'Pending', Icons.hourglass_top_rounded),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: filters.map((filter) {
          final (value, label, icon) = filter;
          final isSelected = selectedFilter == value;
          return Padding(
            padding: const EdgeInsets.only(right: DSSpacing.sm),
            child: FilterChip(
              selected: isSelected,
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: isSelected ? DSColors.textOnPrimary : DSColors.textTertiary,
                  ),
                  const SizedBox(width: DSSpacing.xs),
                  Text(label),
                ],
              ),
              onSelected: (_) => onChanged(value),
              backgroundColor: Theme.of(context).cardTheme.color,
              selectedColor: DSColors.primary.withOpacity( 0.15),
              checkmarkColor: DSColors.primary,
              labelStyle: DSTypography.labelMedium.copyWith(
                color: isSelected ? DSColors.primary : DSColors.textSecondary,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              ),
              side: BorderSide(
                color: isSelected ? DSColors.primary : DSColors.border,
                width: isSelected ? 1.5 : 0.5,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DSBorderRadius.full),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: DSSpacing.md,
                vertical: DSSpacing.xs,
              ),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          );
        }).toList(),
      ),
    );
  }
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
      _ => DSColors.textTertiary,
    };

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      decoration: BoxDecoration(
        color: isDark ? DSColors.surface1 : Colors.white,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(DSBorderRadius.xxl),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: DSSpacing.md),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: DSColors.textTertiary.withOpacity( 0.5),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.all(DSSpacing.lg),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(DSSpacing.md),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity( 0.15),
                    borderRadius: BorderRadius.circular(DSBorderRadius.lg),
                  ),
                  child: Icon(
                    switch (dispatch.status) {
                      'confirmed' => Icons.check_circle_rounded,
                      'failed' => Icons.cancel_rounded,
                      'pending' => Icons.hourglass_top_rounded,
                      _ => Icons.help_outline_rounded,
                    },
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
                        style: DSTypography.headlineSmall.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: DSSpacing.xs),
                      DSStatusBadge(
                        label: dispatch.status.toUpperCase(),
                        type: switch (dispatch.status) {
                          'confirmed' => DSStatusType.success,
                          'failed' => DSStatusType.error,
                          'pending' => DSStatusType.warning,
                          _ => DSStatusType.neutral,
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Divider(color: DSColors.divider, height: 1),

          // Details
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(DSSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DetailRow(
                    icon: Icons.person_rounded,
                    label: 'Responder',
                    value: dispatch.responder,
                  ),
                  _DetailRow(
                    icon: Icons.access_time_rounded,
                    label: 'Timestamp',
                    value: _formatFullTime(dispatch.timestamp),
                  ),
                  _DetailRow(
                    icon: Icons.location_on_rounded,
                    label: 'Destination',
                    value:
                        '${dispatch.destination['lat']?.toStringAsFixed(6)}, ${dispatch.destination['lon']?.toStringAsFixed(6)}',
                  ),
                  if (dispatch.structure != null) ...[
                    _DetailRow(
                      icon: Icons.home_work_rounded,
                      label: 'Structure Type',
                      value: dispatch.structure!['structure_type'] ?? 'Unknown',
                    ),
                    _DetailRow(
                      icon: Icons.flag_rounded,
                      label: 'Zone',
                      value: dispatch.structure!['zone_code'] ?? 'Unknown',
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Action buttons
          Padding(
            padding: const EdgeInsets.all(DSSpacing.lg),
            child: Row(
              children: [
                Expanded(
                  child: DSSecondaryButton(
                    label: 'Close',
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatFullTime(DateTime time) {
    return '${time.day}/${time.month}/${time.year} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

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
                Text(
                  label,
                  style: DSTypography.labelSmall.copyWith(
                    color: DSColors.textTertiary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: DSTypography.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}