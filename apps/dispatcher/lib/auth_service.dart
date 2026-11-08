// Authentication & Role Management Service
//
// Real authentication: login exchanges credentials for a server-signed
// bearer token (POST /v1/auth/login). The role comes from the server's
// response — it is never chosen on the device. The token is persisted
// and sent as `Authorization: Bearer …` on every privileged request;
// the server verifies it and derives the role from it.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math';

enum UserRole {
  caller('caller', 'Caller (Citizen)'),
  dispatcher('dispatcher', 'Dispatcher'),
  admin('admin', 'Administrator'),
  mapper('mapper', 'Mapper (Field)');

  const UserRole(this.value, this.displayName);
  final String value;
  final String displayName;

  static UserRole fromString(String value) {
    return UserRole.values.firstWhere(
      (r) => r.value == value,
      orElse: () => UserRole.caller,
    );
  }
}

class AuthService extends ChangeNotifier {
  static const String _roleKey = 'user_role';
  static const String _deviceHashKey = 'device_hash';
  static const String _tokenKey = 'auth_token';
  static const String _userNameKey = 'user_name';

  UserRole _currentRole = UserRole.caller;
  String _deviceHash = '';
  String _authToken = '';
  String _userName = '';
  bool _isInitialized = false;
  bool _hasExplicitRole = false;

  UserRole get currentRole => _currentRole;
  bool get hasExplicitRole => _hasExplicitRole;
  String get deviceHash => _deviceHash;
  String get authToken => _authToken;
  String get userName => _userName;
  bool get isInitialized => _isInitialized;
  bool get isLoggedIn => _authToken.isNotEmpty;
  bool get isDispatcher => _currentRole == UserRole.dispatcher || _currentRole == UserRole.admin;
  bool get isMapper => _currentRole == UserRole.mapper;
  bool get isAdmin => _currentRole == UserRole.admin;
  bool get isCaller => _currentRole == UserRole.caller;

  Future<void> initialize() async {
    if (_isInitialized) return;
    final prefs = await SharedPreferences.getInstance();
    _deviceHash = prefs.getString(_deviceHashKey) ?? _generateDeviceHash();
    if (!prefs.containsKey(_deviceHashKey)) {
      await prefs.setString(_deviceHashKey, _deviceHash);
    }
    final roleStr = prefs.getString(_roleKey);
    _currentRole = roleStr != null ? UserRole.fromString(roleStr) : UserRole.caller;
    _hasExplicitRole = roleStr != null;
    _authToken = prefs.getString(_tokenKey) ?? '';
    _userName = prefs.getString(_userNameKey) ?? '';
    _isInitialized = true;
    notifyListeners();
  }

  String _generateDeviceHash() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes).substring(0, 16);
  }

  /// Log in with credentials. The server decides the role; the device
  /// only stores what it is given. Returns true on success.
  Future<bool> login(String username, String password, String baseUrl) async {
    final res = await http.post(
      Uri.parse('$baseUrl/v1/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return false;
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final prefs = await SharedPreferences.getInstance();
    _authToken = body['token'] as String;
    _userName = body['username'] as String;
    _currentRole = UserRole.fromString(body['role'] as String);
    _hasExplicitRole = true;
    await prefs.setString(_tokenKey, _authToken);
    await prefs.setString(_userNameKey, _userName);
    await prefs.setString(_roleKey, _currentRole.value);
    notifyListeners();
    return true;
  }

  /// Exchange the current token for a fresh one (call on 401 / expiry).
  Future<bool> refresh(String baseUrl) async {
    if (_authToken.isEmpty) return false;
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/v1/auth/refresh'),
        headers: {'Authorization': 'Bearer $_authToken'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        await logout();
        return false;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      _authToken = body['token'] as String;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, _authToken);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Map<String, String> getAuthHeaders() {
    return {
      'Content-Type': 'application/json',
      if (_authToken.isNotEmpty) 'Authorization': 'Bearer $_authToken',
      'X-Device-Hash': _deviceHash,
    };
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_roleKey);
    await prefs.remove(_tokenKey);
    await prefs.remove(_userNameKey);
    _currentRole = UserRole.caller;
    _hasExplicitRole = false;
    _authToken = '';
    _userName = '';
    notifyListeners();
  }

  String getRoleDisplayName() => _currentRole.displayName;

  List<UserRole> getAvailableRoles() {
    return [UserRole.caller, UserRole.dispatcher, UserRole.admin, UserRole.mapper];
  }
}
