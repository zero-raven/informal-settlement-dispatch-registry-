// Dashboard/Home Screen for Dispatcher App
// Professional dark theme with responsive layout and functional elements

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'design_system.dart';
import 'components.dart';
import 'models.dart';
import 'package:provider/provider.dart';
import 'auth_service.dart';

class DashboardScreen extends StatefulWidget {
  final String? baseUrl;
  final String role;
  final ValueChanged<int>? onTabChange;

  const DashboardScreen({
    super.key,
    this.baseUrl,
    this.role = 'dispatcher',
    this.onTabChange,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final String _api = 'http://127.0.0.1:8090';

  DispatchStats? _stats;
  List<DispatchItem> _recentDispatches = [];
  bool _isLoading = true;
  String? _error;
  String? _backendStatus;

  @override
  void initState() {
    super.initState();
    _loadDashboardData();
  }

  Future<void> _loadDashboardData() async {
    setState(() => _isLoading = true);
    try {
      final base = widget.baseUrl ?? _api;
      final headers = context.read<AuthService>().getAuthHeaders();

      final results = await Future.wait([
        http.get(Uri.parse('$base/v1/dispatch/stats'), headers: headers),
        http.get(Uri.parse('$base/v1/dispatch/recent?limit=10'), headers: headers),
        http.get(Uri.parse('$base/v1/dispatch/capabilities'), headers: headers),
      ]);

      final statsRes = results[0];
      final recentRes = results[1];
      final capsRes = results[2];

      if (statsRes.statusCode == 200) {
        _stats = DispatchStats.fromJson(jsonDecode(statsRes.body));
      }

      if (recentRes.statusCode == 200) {
        final data = jsonDecode(recentRes.body) as Map<String, dynamic>;
        _recentDispatches = (data['dispatches'] as List)
            .map((e) => DispatchItem.fromJson(e))
            .toList();
      }

      if (capsRes.statusCode == 200) {
        final c = jsonDecode(capsRes.body) as Map<String, dynamic>;
        _backendStatus = 'Backend: ${c['backend']} · Profiles: ${(c['profiles'] as List).join(', ')}';
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _navigateToTab(int index) {
    widget.onTabChange?.call(index);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isWide = MediaQuery.of(context).size.width > 768;

    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      backgroundColor: isDark ? DSColors.surface0 : Colors.grey[50],
      body: RefreshIndicator(
        onRefresh: _loadDashboardData,
        color: DSColors.primary,
        child: CustomScrollView(
          slivers: [
            // Hero section with status
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  DSSpacing.screenPadding,
                  DSSpacing.screenPadding,
                  DSSpacing.screenPadding,
                  DSSpacing.md,
                ),
                child: _buildHeroSection(isDark),
              ),
            ),

            // Stats grid - responsive
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
                child: _buildStatsGrid(isWide),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.sectionGap)),

            // Recent dispatches + Quick actions side by side on wide, stacked on narrow
            if (isWide)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
                  child: _buildWideLayout(),
                ),
              )
            else
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
                  child: Column(
                    children: [
                      _buildRecentDispatchesSection(),
                      const SizedBox(height: DSSpacing.sectionGap),
                      _buildQuickActionsSection(),
                    ],
                  ),
                ),
              ),

            const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.xxl)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroSection(bool isDark) {
    return DSCard(
      padding: const EdgeInsets.all(DSSpacing.cardPadding),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(DSSpacing.lg),
            decoration: BoxDecoration(
              gradient: DSColors.primaryGradient,
              borderRadius: BorderRadius.circular(DSBorderRadius.xl),
              boxShadow: DSShadows.glowPrimary,
            ),
            child: Icon(
              Icons.local_shipping_rounded,
              size: 36,
              color: DSColors.textOnPrimary,
            ),
          ),
          const SizedBox(width: DSSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Dispatcher Dashboard',
                  style: DSTypography.headlineSmall.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: DSSpacing.xs),
                Text(
                  'Emergency Operations Overview',
                  style: DSTypography.bodyMedium.copyWith(
                    color: DSColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          _buildStatusChip(),
        ],
      ),
    );
  }

  Widget _buildStatusChip() {
    final isOnline = _backendStatus != null && _backendStatus!.contains('Backend:');
    final statusColor = isOnline ? DSColors.success : DSColors.error;
    final statusText = isOnline ? 'System Online' : 'System Offline';

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: DSSpacing.md,
        vertical: DSSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(DSBorderRadius.full),
        border: Border.all(color: statusColor.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: DSSpacing.sm),
          Text(
            statusText,
            style: DSTypography.labelMedium.copyWith(
              color: statusColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsGrid(bool isWide) {
    final crossAxisCount = isWide ? 4 : 2;
    final childAspectRatio = isWide ? 1.5 : 1.3;

    if (_stats == null) {
      return GridView.count(
        crossAxisCount: crossAxisCount,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: DSSpacing.md,
        crossAxisSpacing: DSSpacing.md,
        childAspectRatio: childAspectRatio,
        children: List.generate(4, (_) => DSShimmerPlaceholder.rectangular(
          width: double.infinity,
          height: 100,
          borderRadius: BorderRadius.circular(DSBorderRadius.lg),
        )),
      );
    }

    return GridView.count(
      crossAxisCount: crossAxisCount,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: DSSpacing.md,
      crossAxisSpacing: DSSpacing.md,
      childAspectRatio: childAspectRatio,
      children: [
        _buildStatCard(
          label: 'Active Dispatches',
          value: _stats!.active.toString(),
          icon: Icons.local_shipping_rounded,
          iconColor: DSColors.primary,
          gradient: DSColors.primaryGradient,
          subtitle: '+${_stats!.todayStarted} started today',
          trend: _stats!.todayStarted > 0 ? 'up' : 'neutral',
          onTap: () => _navigateToTab(2),
        ),
        _buildStatCard(
          label: 'Success Rate',
          value: '${_stats!.successRate}%',
          icon: Icons.check_circle_rounded,
          iconColor: DSColors.success,
          gradient: LinearGradient(
            colors: [DSColors.success, DSColors.success.withOpacity(0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          subtitle: _stats!.total > 0 ? '${_stats!.successful}/${_stats!.total} confirmed' : 'No data',
          trend: _stats!.successRate >= 80 ? 'up' : _stats!.successRate >= 50 ? 'neutral' : 'down',
          onTap: () => _navigateToTab(2),
        ),
        _buildStatCard(
          label: 'Pending Review',
          value: _stats!.pendingReview.toString(),
          icon: Icons.pending_actions_rounded,
          iconColor: DSColors.warning,
          gradient: LinearGradient(
            colors: [DSColors.warning, DSColors.warning.withOpacity(0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          subtitle: 'Requires attention',
          trend: _stats!.pendingReview > 0 ? 'up' : 'neutral',
          onTap: () => _navigateToTab(1),
        ),
        _buildStatCard(
          label: 'Avg Response',
          value: _stats!.avgResponseTime == null ? '—' : '${_stats!.avgResponseTime}m',
          icon: Icons.timer_rounded,
          iconColor: DSColors.info,
          gradient: LinearGradient(
            colors: [DSColors.info, DSColors.info.withOpacity(0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          subtitle: 'Time to destination',
          trend: _stats!.avgResponseTime == null
              ? 'neutral'
              : _stats!.avgResponseTime! <= 15 ? 'up' : _stats!.avgResponseTime! <= 30 ? 'neutral' : 'down',
          onTap: () => _navigateToTab(2),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required String label,
    required String value,
    required IconData icon,
    required Color iconColor,
    required Gradient gradient,
    required String subtitle,
    required String trend,
    VoidCallback? onTap,
  }) {
    final trendColor = switch (trend) {
      'up' => DSColors.success,
      'down' => DSColors.error,
      _ => DSColors.textTertiary,
    };
    final trendIcon = switch (trend) {
      'up' => Icons.trending_up_rounded,
      'down' => Icons.trending_down_rounded,
      _ => Icons.trending_flat_rounded,
    };

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DSBorderRadius.lg),
        child: DSCard(
          padding: const EdgeInsets.all(DSSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(DSSpacing.sm),
                    decoration: BoxDecoration(
                      gradient: gradient,
                      borderRadius: BorderRadius.circular(DSBorderRadius.md),
                    ),
                    child: Icon(icon, color: DSColors.textOnPrimary, size: 22),
                  ),
                  const Spacer(),
                  Icon(trendIcon, color: trendColor, size: 18),
                ],
              ),
              const SizedBox(height: DSSpacing.md),
              Text(
                value,
                style: DSTypography.headlineMedium.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: DSSpacing.xs),
              Text(
                label,
                style: DSTypography.labelMedium.copyWith(
                  color: DSColors.textSecondary,
                ),
              ),
              const SizedBox(height: DSSpacing.xs),
              Text(
                subtitle,
                style: DSTypography.bodySmall.copyWith(
                  color: DSColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWideLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: _buildRecentDispatchesSection(),
        ),
        const SizedBox(width: DSSpacing.lg),
        Expanded(
          flex: 2,
          child: _buildQuickActionsSection(),
        ),
      ],
    );
  }

  Widget _buildRecentDispatchesSection() {
    return DSCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(DSSpacing.cardPadding),
            child: Row(
              children: [
                Text(
                  'Recent Dispatches',
                  style: DSTypography.titleLarge.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _navigateToTab(2),
                  icon: const Icon(Icons.history_rounded, size: 18),
                  label: const Text('View All'),
                  style: TextButton.styleFrom(
                    foregroundColor: DSColors.primary,
                  ),
                ),
              ],
            ),
          ),
          Divider(color: DSColors.divider, height: 1),
          // List
          _isLoading
              ? DSSkeletonList(itemCount: 3, itemHeight: 72)
              : _error != null
                  ? DSErrorState(
                      title: 'Failed to load',
                      message: _error!,
                      onRetry: _loadDashboardData,
                      compact: true,
                    )
                  : _recentDispatches.isEmpty
                      ? DSEmptyState(
                          icon: Icons.local_shipping_outlined,
                          title: 'No recent dispatches',
                          message: 'Dispatches will appear here once recorded.',
                          compact: true,
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _recentDispatches.length,
                          separatorBuilder: (_, __) => Divider(
                            color: DSColors.divider,
                            height: 1,
                            indent: DSSpacing.cardPadding,
                            endIndent: DSSpacing.cardPadding,
                          ),
                          itemBuilder: (_, index) => _buildDispatchTile(_recentDispatches[index]),
                        ),
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

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showDispatchDetail(dispatch),
        borderRadius: BorderRadius.circular(DSBorderRadius.lg),
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
                child: Icon(statusIcon, color: statusColor, size: 22),
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
                    Text(
                      '${dispatch.destination['lat']?.toStringAsFixed(4)}, ${dispatch.destination['lon']?.toStringAsFixed(4)}',
                      style: DSTypography.bodySmall.copyWith(
                        color: DSColors.textTertiary,
                      ),
                    ),
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
        ),
      ),
    );
  }

  Widget _buildQuickActionsSection() {
    final actions = [
      _QuickActionItem(
        icon: Icons.qr_code_scanner_rounded,
        label: 'Lookup Structure',
        subtitle: 'Find by code',
        color: DSColors.primary,
        onTap: () => _navigateToTab(1),
      ),
      _QuickActionItem(
        icon: Icons.history_rounded,
        label: 'Dispatch History',
        subtitle: 'View all records',
        color: DSColors.info,
        onTap: () => _navigateToTab(2),
      ),
      _QuickActionItem(
        icon: Icons.settings_rounded,
        label: 'Settings',
        subtitle: 'Configure app',
        color: DSColors.textTertiary,
        onTap: () => _navigateToTab(3),
      ),
      _QuickActionItem(
        icon: Icons.help_outline_rounded,
        label: 'Help & Docs',
        subtitle: 'Documentation',
        color: DSColors.warning,
        onTap: () => _showHelpDialog(),
      ),
    ];

    return DSCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(DSSpacing.cardPadding),
            child: Text(
              'Quick Actions',
              style: DSTypography.titleLarge.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Divider(color: DSColors.divider, height: 1),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: DSSpacing.md,
            crossAxisSpacing: DSSpacing.md,
            childAspectRatio: 1.0,
            padding: const EdgeInsets.all(DSSpacing.cardPadding),
            children: actions.map((action) => _QuickActionCard(action: action)).toList(),
          ),
        ],
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

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => DSDialog(
        title: 'Help & Documentation',
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
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _QuickActionItem {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _QuickActionItem({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });
}

class _QuickActionCard extends StatelessWidget {
  final _QuickActionItem action;

  const _QuickActionCard({required this.action});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: action.onTap,
        borderRadius: BorderRadius.circular(DSBorderRadius.lg),
        child: DSCard(
          padding: const EdgeInsets.all(DSSpacing.md),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(DSSpacing.md),
                decoration: BoxDecoration(
                  color: action.color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(DSBorderRadius.md),
                ),
                child: Icon(action.icon, color: action.color, size: 28),
              ),
              const SizedBox(height: DSSpacing.md),
              Text(
                action.label,
                style: DSTypography.titleSmall.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: DSSpacing.xs),
              Text(
                action.subtitle,
                style: DSTypography.bodySmall.copyWith(
                  color: DSColors.textTertiary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
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

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
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
                              style: DSTypography.headlineSmall.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
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
                  const SizedBox(height: DSSpacing.lg),
                  Divider(color: DSColors.divider, height: 1),
                  const SizedBox(height: DSSpacing.lg),
                  _DetailRow(
                    icon: Icons.location_on_rounded,
                    label: 'Location',
                    value: '${dispatch.destination['lat']?.toStringAsFixed(6)}, ${dispatch.destination['lon']?.toStringAsFixed(6)}',
                  ),
                  _DetailRow(
                    icon: Icons.person_rounded,
                    label: 'Responder',
                    value: dispatch.responder,
                  ),
                  _DetailRow(
                    icon: Icons.access_time_rounded,
                    label: 'Dispatched',
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
                  style: DSTypography.labelSmall.copyWith(color: DSColors.textTertiary),
                ),
                Text(
                  value,
                  style: DSTypography.bodyMedium.copyWith(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}