// Inbound Call Screen for Dispatcher App
// Receiving emergency calls and converting to dispatch requests

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'design_system.dart';
import 'components.dart';

class InboundCallScreen extends StatefulWidget {
  final String? baseUrl;
  final String role;

  const InboundCallScreen({super.key, this.baseUrl, this.role = 'dispatcher'});

  @override
  State<InboundCallScreen> createState() => _InboundCallScreenState();
}

class _InboundCallScreenState extends State<InboundCallScreen> {
  final String _api = 'http://127.0.0.1:8090';

  // Call form fields
  final TextEditingController _callerNameController = TextEditingController();
  final TextEditingController _callerPhoneController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  final TextEditingController _landmarkController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _structureCodeController = TextEditingController();

  String _callType = 'emergency';
  String _priority = 'high';
  bool _isLoading = false;
  String? _error;
  InboundCallResult? _callResult;

  // Active incoming calls (simulated)
  List<IncomingCall> _activeCalls = [];

  @override
  void initState() {
    super.initState();
    _loadActiveCalls();
  }

  @override
  void dispose() {
    _callerNameController.dispose();
    _callerPhoneController.dispose();
    _locationController.dispose();
    _landmarkController.dispose();
    _descriptionController.dispose();
    _structureCodeController.dispose();
    super.dispose();
  }

  Future<Map<String, String>> _headers() async =>
      {'Content-Type': 'application/json', 'X-Role': widget.role};

  Future<void> _loadActiveCalls() async {
    // Simulated active calls - in production would come from backend
    setState(() {
      _activeCalls = [
        IncomingCall(
          id: 'call-001',
          callerName: 'Priya Sharma',
          phone: '+91-98765-43210',
          location: 'Near SLR-C41001',
          type: 'emergency',
          priority: 'critical',
          description: 'Building collapse reported, people trapped',
          timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
          status: 'pending',
        ),
        IncomingCall(
          id: 'call-002',
          callerName: 'Rajesh Kumar',
          phone: '+91-87654-32109',
          location: 'Zone C4, Block 3',
          type: 'fire',
          priority: 'high',
          description: 'Smoke seen from residential building',
          timestamp: DateTime.now().subtract(const Duration(minutes: 12)),
          status: 'dispatched',
        ),
      ];
    });
  }

  Future<void> _submitCall() async {
    if (_callerNameController.text.trim().isEmpty ||
        _locationController.text.trim().isEmpty ||
        _descriptionController.text.trim().isEmpty) {
      setState(() => _error = 'Please fill all required fields');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final base = widget.baseUrl ?? _api;
      
      // Create a grievance as the inbound call record (using existing endpoint)
      final res = await http.post(
        Uri.parse('$base/v1/grievances'),
        headers: await _headers(),
        body: jsonEncode({
          'device_hash': 'dispatcher_console_${DateTime.now().millisecondsSinceEpoch}',
          'reported_location': {
            'lat': 12.9700, // Would be geocoded from location in production
            'lon': 77.5890,
          },
          'structure_code': _structureCodeController.text.trim().isEmpty 
              ? null 
              : _structureCodeController.text.trim().toUpperCase(),
          'body': 'INBOUND CALL [${_callType.toUpperCase()}] Priority: $_priority\n'
                  'Caller: ${_callerNameController.text.trim()} (${_callerPhoneController.text.trim()})\n'
                  'Location: ${_locationController.text.trim()}\n'
                  'Landmark: ${_landmarkController.text.trim()}\n'
                  'Description: ${_descriptionController.text.trim()}',
        }),
      );

      final body = jsonDecode(res.body) as Map<String, dynamic>;

      if (res.statusCode == 201) {
        setState(() {
          _callResult = InboundCallResult(
            grievanceId: body['grievance_id'] as String,
            crossCheckAction: body['cross_check_action'] as String,
            offsetM: (body['offset_m'] as num?)?.toDouble(),
          );
          // Clear form
          _callerNameController.clear();
          _callerPhoneController.clear();
          _locationController.clear();
          _landmarkController.clear();
          _descriptionController.clear();
          _structureCodeController.clear();
        });
        _loadActiveCalls();
      } else {
        setState(() => _error = body['error']?.toString() ?? 'Failed to log call');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _convertToDispatch(String structureCode) async {
    if (structureCode.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final base = widget.baseUrl ?? _api;
      
      // Lookup structure first
      final lookupRes = await http.post(
        Uri.parse('$base/v1/dispatch/lookup'),
        headers: await _headers(),
        body: jsonEncode({'code': structureCode, 'profile': 'foot'}),
      );

      if (lookupRes.statusCode != 200) {
        final body = jsonDecode(lookupRes.body);
        throw Exception(body['error'] ?? 'Structure not found or not dispatchable');
      }

      // Auto-assign to next available unit
      final assignRes = await http.post(
        Uri.parse('$base/v1/dispatch/assign'),
        headers: await _headers(),
        body: jsonEncode({
          'code': structureCode,
          'responder': 'auto-unit-${DateTime.now().millisecondsSinceEpoch % 100}',
        }),
      );

      if (assignRes.statusCode != 200) {
        final body = jsonDecode(assignRes.body);
        throw Exception(body['error'] ?? 'Failed to create dispatch');
      }

      final assignData = jsonDecode(assignRes.body) as Map<String, dynamic>;
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Dispatch created: ${assignData['dispatch_id']}',
              style: DSTypography.bodyMedium.copyWith(color: Colors.white),
            ),
            backgroundColor: DSColors.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DSBorderRadius.md)),
          ),
        );
      }
      _loadActiveCalls();
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
              child: Row(
                children: [
                  Container(
                                      padding: const EdgeInsets.all(DSSpacing.lg),
                                      decoration: BoxDecoration(
                                        gradient: _priority == 'critical'
                                            ? LinearGradient(colors: [DSColors.error, DSColors.error.withOpacity(0.8)])
                                            : _priority == 'high'
                                                ? LinearGradient(colors: [DSColors.warning, DSColors.warning.withOpacity(0.8)])
                                                : LinearGradient(colors: [DSColors.primary, DSColors.primary.withOpacity(0.8)]),
                                        borderRadius: BorderRadius.circular(DSBorderRadius.xl),
                                      ),
                    child: Icon(
                      _callType == 'fire' ? Icons.local_fire_department_rounded :
                      _callType == 'medical' ? Icons.medical_services_rounded :
                      Icons.emergency_rounded,
                      size: 36,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: DSSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Inbound Emergency Call',
                          style: DSTypography.headlineSmall.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: DSSpacing.xs),
                        Text(
                          'Receive and dispatch emergency calls',
                          style: DSTypography.bodyMedium.copyWith(color: DSColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: DSSpacing.md, vertical: DSSpacing.xs),
                    decoration: BoxDecoration(
                      color: DSColors.warning.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(DSBorderRadius.full),
                      border: Border.all(color: DSColors.warning.withOpacity(0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: DSColors.warning, shape: BoxShape.circle)),
                        const SizedBox(width: DSSpacing.sm),
                        Text('LIVE', style: DSTypography.labelMedium.copyWith(color: DSColors.warning, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Active Calls Panel
          if (_activeCalls.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
                child: DSSectionHeader(
                  title: 'Active Incoming Calls',
                  subtitle: '${_activeCalls.length} call${_activeCalls.length > 1 ? 's' : ''} in queue',
                ),
              ),
            ),

          if (_activeCalls.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
                child: DSCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: _activeCalls.map((call) => _buildCallTile(call)).toList(),
                  ),
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.sectionGap)),

          // New Call Form
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DSSpacing.screenPadding),
              child: DSSectionHeader(
                title: 'Log New Call',
                subtitle: 'Record incoming emergency call details',
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(DSSpacing.screenPadding),
              child: DSCard(
                padding: const EdgeInsets.all(DSSpacing.cardPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Call Type & Priority
                    Row(
                      children: [
                        Expanded(
                          child: _buildSegmentedField(
                            label: 'Call Type',
                            value: _callType,
                            options: const [
                              ('emergency', 'Emergency', Icons.emergency_rounded),
                              ('fire', 'Fire', Icons.local_fire_department_rounded),
                              ('medical', 'Medical', Icons.medical_services_rounded),
                              ('rescue', 'Rescue', Icons.healing_rounded),
                              ('other', 'Other', Icons.more_horiz_rounded),
                            ],
                            onChanged: (v) => setState(() => _callType = v),
                          ),
                        ),
                        const SizedBox(width: DSSpacing.md),
                        Expanded(
                          child: _buildSegmentedField(
                            label: 'Priority',
                            value: _priority,
                            options: const [
                              ('critical', 'Critical', Icons.priority_high_rounded),
                              ('high', 'High', Icons.arrow_upward_rounded),
                              ('medium', 'Medium', Icons.remove_rounded),
                              ('low', 'Low', Icons.arrow_downward_rounded),
                            ],
                            onChanged: (v) => setState(() => _priority = v),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: DSSpacing.md),

                    // Caller Info
                    Text('Caller Information', style: DSTypography.titleSmall.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: DSSpacing.sm),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _callerNameController,
                            decoration: InputDecoration(
                              labelText: 'Caller Name *',
                              hintText: 'John Doe',
                              prefixIcon: const Icon(Icons.person_rounded),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(DSBorderRadius.md)),
                            ),
                          ),
                        ),
                        const SizedBox(width: DSSpacing.md),
                        Expanded(
                          child: TextField(
                            controller: _callerPhoneController,
                            keyboardType: TextInputType.phone,
                            decoration: InputDecoration(
                              labelText: 'Phone Number',
                              hintText: '+91-XXXXXXXXXX',
                              prefixIcon: const Icon(Icons.phone_rounded),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(DSBorderRadius.md)),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: DSSpacing.md),

                    // Location
                    Text('Location', style: DSTypography.titleSmall.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: DSSpacing.sm),
                    TextField(
                      controller: _locationController,
                      decoration: InputDecoration(
                        labelText: 'Location / Address *',
                        hintText: '123 Main St, Zone C4, Block 2',
                        prefixIcon: const Icon(Icons.location_on_rounded),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(DSBorderRadius.md)),
                      ),
                    ),
                    const SizedBox(height: DSSpacing.sm),
                    TextField(
                      controller: _landmarkController,
                      decoration: InputDecoration(
                        labelText: 'Landmark / Nearby Structure',
                        hintText: 'Near SLR-C41001, Blue building',
                        prefixIcon: const Icon(Icons.place_rounded),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(DSBorderRadius.md)),
                      ),
                    ),
                    const SizedBox(height: DSSpacing.sm),
                    TextField(
                      controller: _structureCodeController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText: 'Structure Code (if known)',
                        hintText: 'SLR-C41001',
                        prefixIcon: const Icon(Icons.qr_code_rounded),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(DSBorderRadius.md)),
                      ),
                    ),

                    const SizedBox(height: DSSpacing.md),

                    // Description
                    TextField(
                      controller: _descriptionController,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: 'Description *',
                        hintText: 'What happened? Number of people, injuries, hazards...',
                        prefixIcon: const Icon(Icons.description_rounded),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(DSBorderRadius.md)),
                        alignLabelWithHint: true,
                      ),
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: DSSpacing.md),
                      DSErrorState(
                        title: 'Error',
                        message: _error!,
                        compact: true,
                      ),
                    ],

                    if (_callResult != null) ...[
                      const SizedBox(height: DSSpacing.md),
                      DSCard(
                        padding: const EdgeInsets.all(DSSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.check_circle_rounded, color: DSColors.success, size: 22),
                                const SizedBox(width: DSSpacing.sm),
                                Text('Call Logged Successfully', style: DSTypography.titleMedium.copyWith(fontWeight: FontWeight.w600)),
                              ],
                            ),
                            const SizedBox(height: DSSpacing.sm),
                            Text('Grievance ID: ${_callResult!.grievanceId}', style: DSTypography.bodySmall.copyWith(color: DSColors.textSecondary)),
                            Text('Cross-check: ${_callResult!.crossCheckAction}', style: DSTypography.bodySmall.copyWith(color: DSColors.textSecondary)),
                            if (_callResult!.offsetM != null)
                              Text('Offset: ${_callResult!.offsetM!.toStringAsFixed(1)}m', style: DSTypography.bodySmall.copyWith(color: DSColors.textSecondary)),
                            const SizedBox(height: DSSpacing.md),
                            if (_callResult!.crossCheckAction == 'dedup_candidate')
                              Text('⚠ Location >25m from structure — needs mapper review', style: DSTypography.bodySmall.copyWith(color: DSColors.warning)),
                            const SizedBox(height: DSSpacing.md),
                            DSActionRow(
                              actions: [
                                DSPrimaryButton(
                                  label: 'Create Dispatch for ${_structureCodeController.text}',
                                  icon: Icons.send_rounded,
                                  isExpanded: false,
                                  onPressed: _structureCodeController.text.isEmpty ? null : () => _convertToDispatch(_structureCodeController.text.trim().toUpperCase()),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: DSSpacing.lg),

                    DSActionRow(
                      actions: [
                        DSSecondaryButton(
                          label: 'Clear Form',
                          icon: Icons.clear_rounded,
                          onPressed: () {
                            setState(() {
                              _callerNameController.clear();
                              _callerPhoneController.clear();
                              _locationController.clear();
                              _landmarkController.clear();
                              _descriptionController.clear();
                              _structureCodeController.clear();
                              _error = null;
                              _callResult = null;
                            });
                          },
                        ),
                        DSPrimaryButton(
                          label: _isLoading ? 'Logging...' : 'Log Call',
                          icon: _isLoading ? null : Icons.call_made_rounded,
                          isLoading: _isLoading,
                          onPressed: _submitCall,
                        ),
                      ],
                      alignment: WrapAlignment.end,
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: DSSpacing.xxl)),
        ],
      ),
    );
  }

  Widget _buildSegmentedField({
    required String label,
    required String value,
    required List<(String, String, IconData)> options,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: DSTypography.labelMedium),
        const SizedBox(height: DSSpacing.xs),
        SegmentedButton<String>(
          segments: options.map((opt) {
            final (val, name, icon) = opt;
            return ButtonSegment<String>(
              value: val,
              label: Text(name),
              icon: Icon(icon, size: 18),
            );
          }).toList(),
          selected: {value},
          onSelectionChanged: (selection) => onChanged(selection.first),
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return DSColors.primary.withOpacity(0.15);
              return Colors.transparent;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return DSColors.primary;
              return DSColors.textSecondary;
            }),
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return BorderSide(color: DSColors.primary, width: 1.5);
              return BorderSide(color: DSColors.border, width: 0.5);
            }),
            shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(DSBorderRadius.md))),
            padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: DSSpacing.md, vertical: DSSpacing.sm)),
            minimumSize: WidgetStateProperty.all(const Size(70, 40)),
            visualDensity: VisualDensity.standard,
          ),
        ),
      ],
    );
  }

  Widget _buildCallTile(IncomingCall call) {
    final priorityColor = switch (call.priority) {
      'critical' => DSColors.error,
      'high' => DSColors.warning,
      'medium' => DSColors.info,
      'low' => DSColors.success,
      _ => DSColors.textTertiary,
    };

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showCallDetail(call),
        child: Padding(
          padding: const EdgeInsets.all(DSSpacing.cardPadding),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(DSSpacing.sm),
                decoration: BoxDecoration(
                  color: priorityColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(DSBorderRadius.md),
                ),
                child: Icon(
                  call.type == 'fire' ? Icons.local_fire_department_rounded :
                  call.type == 'medical' ? Icons.medical_services_rounded :
                  Icons.emergency_rounded,
                  color: priorityColor,
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
                            call.callerName,
                            style: DSTypography.titleMedium.copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: DSSpacing.sm),
                        DSStatusBadge(
                          label: call.priority.toUpperCase(),
                          type: switch (call.priority) {
                            'critical' => DSStatusType.error,
                            'high' => DSStatusType.warning,
                            'medium' => DSStatusType.info,
                            'low' => DSStatusType.success,
                            _ => DSStatusType.neutral,
                          },
                          isCompact: true,
                        ),
                        const SizedBox(width: DSSpacing.xs),
                        DSStatusBadge(
                          label: call.status.toUpperCase(),
                          type: switch (call.status) {
                            'pending' => DSStatusType.warning,
                            'dispatched' => DSStatusType.info,
                            'completed' => DSStatusType.success,
                            _ => DSStatusType.neutral,
                          },
                          isCompact: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: DSSpacing.xs),
                    Text(
                      call.location,
                      style: DSTypography.bodySmall.copyWith(color: DSColors.textSecondary),
                    ),
                    Text(
                      '${_formatTime(call.timestamp)} · ${call.type.toUpperCase()}',
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

  void _showCallDetail(IncomingCall call) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _CallDetailSheet(call: call, onConvert: _convertToDispatch),
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

class IncomingCall {
  final String id;
  final String callerName;
  final String phone;
  final String location;
  final String type;
  final String priority;
  final String description;
  final DateTime timestamp;
  final String status;

  IncomingCall({
    required this.id,
    required this.callerName,
    required this.phone,
    required this.location,
    required this.type,
    required this.priority,
    required this.description,
    required this.timestamp,
    required this.status,
  });
}

class InboundCallResult {
  final String grievanceId;
  final String crossCheckAction;
  final double? offsetM;

  InboundCallResult({
    required this.grievanceId,
    required this.crossCheckAction,
    this.offsetM,
  });
}

class _CallDetailSheet extends StatelessWidget {
  final IncomingCall call;
  final Future<void> Function(String) onConvert;

  const _CallDetailSheet({required this.call, required this.onConvert});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final priorityColor = switch (call.priority) {
      'critical' => DSColors.error,
      'high' => DSColors.warning,
      'medium' => DSColors.info,
      'low' => DSColors.success,
      _ => DSColors.textTertiary,
    };

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
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
                          color: priorityColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(DSBorderRadius.md),
                        ),
                        child: Icon(
                          call.type == 'fire' ? Icons.local_fire_department_rounded :
                          call.type == 'medical' ? Icons.medical_services_rounded :
                          Icons.emergency_rounded,
                          color: priorityColor,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: DSSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              call.callerName,
                              style: DSTypography.headlineSmall.copyWith(fontWeight: FontWeight.w700),
                            ),
                            Row(
                              children: [
                                DSStatusBadge(
                                  label: call.priority.toUpperCase(),
                                  type: switch (call.priority) {
                                    'critical' => DSStatusType.error,
                                    'high' => DSStatusType.warning,
                                    'medium' => DSStatusType.info,
                                    'low' => DSStatusType.success,
                                    _ => DSStatusType.neutral,
                                  },
                                ),
                                const SizedBox(width: DSSpacing.xs),
                                DSStatusBadge(
                                  label: call.status.toUpperCase(),
                                  type: switch (call.status) {
                                    'pending' => DSStatusType.warning,
                                    'dispatched' => DSStatusType.info,
                                    'completed' => DSStatusType.success,
                                    _ => DSStatusType.neutral,
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: DSSpacing.lg),
                  Divider(color: DSColors.divider, height: 1),
                  const SizedBox(height: DSSpacing.lg),
                  _DetailRow(icon: Icons.phone_rounded, label: 'Phone', value: call.phone),
                  _DetailRow(icon: Icons.location_on_rounded, label: 'Location', value: call.location),
                  _DetailRow(icon: Icons.category_rounded, label: 'Type', value: call.type.toUpperCase()),
                  _DetailRow(icon: Icons.access_time_rounded, label: 'Received', value: call.timestamp.toString().substring(0, 19).replaceAll('T', ' ')),
                  const SizedBox(height: DSSpacing.md),
                  Text('Description', style: DSTypography.titleSmall.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: DSSpacing.xs),
                  Text(call.description, style: DSTypography.bodyMedium),
                  const SizedBox(height: DSSpacing.lg),
                  if (call.status == 'pending')
                    DSPrimaryButton(
                      label: 'Create Dispatch',
                      icon: Icons.send_rounded,
                      onPressed: () {
                        Navigator.pop(context);
                        // Would need to extract structure code from description or prompt
                      },
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(DSSpacing.lg),
              child: DSSecondaryButton(
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