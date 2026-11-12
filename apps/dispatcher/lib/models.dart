// Data models for Dispatcher App

import 'package:flutter/material.dart';

import 'map_view.dart' show MapTrailPoint;

class DispatchStats {
  final int active;
  final int successful;
  final int failed;
  final int pendingReview;
  final int total;
  final int todayStarted;
  final double successRate;
  final int? avgResponseTime;

  DispatchStats({
    required this.active,
    required this.successful,
    required this.failed,
    required this.pendingReview,
    required this.total,
    required this.todayStarted,
    required this.successRate,
    required this.avgResponseTime,
  });

  factory DispatchStats.fromJson(Map<String, dynamic> json) {
    return DispatchStats(
      active: json['active'] ?? 0,
      successful: json['successful'] ?? 0,
      failed: json['failed'] ?? 0,
      pendingReview: json['pending_review'] ?? 0,
      total: json['total'] ?? 0,
      todayStarted: json['today_started'] ?? 0,
      successRate: (json['success_rate'] ?? 0).toDouble(),
      avgResponseTime: json['avg_response_time'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'active': active,
      'successful': successful,
      'failed': failed,
      'pending_review': pendingReview,
      'total': total,
      'today_started': todayStarted,
      'success_rate': successRate,
      'avg_response_time': avgResponseTime,
    };
  }
}

class DispatchItem {
  final String id;
  final String code;
  final String status;
  final String responder;
  final DateTime timestamp;
  final Map<String, dynamic> destination;
  final Map<String, dynamic>? structure;
  final String? outcome;
  final DateTime? outcomeAt;

  DispatchItem({
    required this.id,
    required this.code,
    required this.status,
    required this.responder,
    required this.timestamp,
    required this.destination,
    this.structure,
    this.outcome,
    this.outcomeAt,
  });

  factory DispatchItem.fromJson(Map<String, dynamic> json) {
    return DispatchItem(
      id: json['dispatch_id'] ?? json['id'] ?? '',
      code: json['code'] ?? '',
      status: json['outcome'] ?? json['status'] ?? 'pending',
      responder: json['responder'] ?? json['actor'] ?? 'unknown',
      timestamp: DateTime.tryParse(json['timestamp'] ?? json['created_at'] ?? json['assigned_at'] ?? '') ?? DateTime.now(),
      destination: (json['destination'] as Map?)?.cast<String, dynamic>() ?? {},
      structure: (json['structure'] as Map?)?.cast<String, dynamic>(),
      outcome: json['outcome'] ?? json['status'],
      outcomeAt: json['outcome_at'] != null ? DateTime.tryParse(json['outcome_at']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'dispatch_id': id,
      'code': code,
      'outcome': status,
      'responder': responder,
      'timestamp': timestamp.toIso8601String(),
      'destination': destination,
      'structure': structure,
    };
  }
}

class DispatchDetail {
  final DispatchItem dispatch;
  final LookupResult? lookup;
  final RouteResult? route;
  final List<DispatchEvent> timeline;

  DispatchDetail({
    required this.dispatch,
    this.lookup,
    this.route,
    required this.timeline,
  });
}

class LookupResult {
  final Map<String, dynamic>? data;
  final String? error;
  final int status;

  LookupResult(this.data, this.error, this.status);

  bool get ok => error == null;
}

class RouteResult {
  final double totalDistanceM;
  final int graphVersion;
  final List<dynamic> legs;
  final int unverifiedLegs;
  final List<String> warnings;

  RouteResult({
    required this.totalDistanceM,
    required this.graphVersion,
    required this.legs,
    required this.unverifiedLegs,
    required this.warnings,
  });

  factory RouteResult.fromJson(Map<String, dynamic> json) {
    return RouteResult(
      totalDistanceM: (json['total_distance_m'] ?? 0).toDouble(),
      graphVersion: json['graph_version'] ?? 0,
      legs: json['legs'] ?? [],
      unverifiedLegs: json['unverified_legs'] ?? 0,
      warnings: (json['warnings'] as List?)?.cast<String>() ?? [],
    );
  }

  /// Polyline through the legs' lat/lon endpoints; empty when the graph
  /// service sent no coordinates.
  List<MapTrailPoint> get path {
    MapTrailPoint? pt(Object? p) {
      if (p is! Map) return null;
      final lat = p['lat'], lon = p['lon'];
      return (lat is num && lon is num) ? MapTrailPoint(lat: lat.toDouble(), lon: lon.toDouble()) : null;
    }

    final out = <MapTrailPoint>[];
    for (final leg in legs.whereType<Map>()) {
      final to = pt(leg['to']);
      if (out.isEmpty) {
        final from = pt(leg['from']);
        if (from == null) return const [];
        out.add(from);
      }
      if (to == null) return const [];
      out.add(to);
    }
    return out;
  }
}

class DispatchEvent {
  final String type;
  final String title;
  final String? description;
  final DateTime timestamp;
  final Map<String, dynamic>? metadata;

  DispatchEvent({
    required this.type,
    required this.title,
    this.description,
    required this.timestamp,
    this.metadata,
  });

  factory DispatchEvent.fromJson(Map<String, dynamic> json) {
    return DispatchEvent(
      type: json['type'] ?? '',
      title: json['title'] ?? '',
      description: json['description'],
      timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
      metadata: (json['metadata'] as Map?)?.cast<String, dynamic>(),
    );
  }
}

class AppSettings {
  final String apiBaseUrl;
  final String graphApiUrl;
  final String role;
  final bool enableNotifications;
  final bool enableHaptics;
  final bool autoRefresh;
  final int refreshInterval;
  final ThemeMode themeMode;
  // Responder start point for routes; defaults to the zones.campus.json centre.
  final double stagingLat;
  final double stagingLon;

  AppSettings({
    this.apiBaseUrl = 'http://127.0.0.1:8090',
    this.graphApiUrl = 'http://127.0.0.1:8092',
    this.role = 'dispatcher',
    this.enableNotifications = true,
    this.enableHaptics = true,
    this.autoRefresh = true,
    this.refreshInterval = 30,
    this.themeMode = ThemeMode.dark,
    this.stagingLat = 12.97,
    this.stagingLon = 77.59,
  });

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      apiBaseUrl: json['api_base_url'] ?? 'http://127.0.0.1:8090',
      graphApiUrl: json['graph_api_url'] ?? 'http://127.0.0.1:8092',
      role: json['role'] ?? 'dispatcher',
      enableNotifications: json['enable_notifications'] ?? true,
      enableHaptics: json['enable_haptics'] ?? true,
      autoRefresh: json['auto_refresh'] ?? true,
      refreshInterval: json['refresh_interval'] ?? 30,
      themeMode: ThemeMode.values.firstWhere(
        (e) => e.name == (json['theme_mode'] ?? 'dark'),
        orElse: () => ThemeMode.dark,
      ),
      stagingLat: (json['staging_lat'] as num?)?.toDouble() ?? 12.97,
      stagingLon: (json['staging_lon'] as num?)?.toDouble() ?? 77.59,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'api_base_url': apiBaseUrl,
      'graph_api_url': graphApiUrl,
      'role': role,
      'enable_notifications': enableNotifications,
      'enable_haptics': enableHaptics,
      'auto_refresh': autoRefresh,
      'refresh_interval': refreshInterval,
      'theme_mode': themeMode.name,
      'staging_lat': stagingLat,
      'staging_lon': stagingLon,
    };
  }

  AppSettings copyWith({
    String? apiBaseUrl,
    String? graphApiUrl,
    String? role,
    bool? enableNotifications,
    bool? enableHaptics,
    bool? autoRefresh,
    int? refreshInterval,
    ThemeMode? themeMode,
    double? stagingLat,
    double? stagingLon,
  }) {
    return AppSettings(
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      graphApiUrl: graphApiUrl ?? this.graphApiUrl,
      role: role ?? this.role,
      enableNotifications: enableNotifications ?? this.enableNotifications,
      enableHaptics: enableHaptics ?? this.enableHaptics,
      autoRefresh: autoRefresh ?? this.autoRefresh,
      refreshInterval: refreshInterval ?? this.refreshInterval,
      themeMode: themeMode ?? this.themeMode,
      stagingLat: stagingLat ?? this.stagingLat,
      stagingLon: stagingLon ?? this.stagingLon,
    );
  }
}