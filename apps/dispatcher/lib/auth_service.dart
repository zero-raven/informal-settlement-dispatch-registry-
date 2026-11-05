// Authentication & Role Management Service

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:math';

enum UserRole {
  caller('caller', 'Caller (Citizen)'),
  dispatcher('dispatcher', 'Dispatcher'),
  admin('admin', 'Administrator');

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

  UserRole get currentRole => _currentRole;
  String get deviceHash => _deviceHash;
  String get authToken => _authToken;
  String get userName => _userName;
  bool get isInitialized => _isInitialized;
  bool get isDispatcher => _currentRole == UserRole.dispatcher || _currentRole == UserRole.admin;
  bool get isAdmin => _currentRole == UserRole.admin;
  bool get isCaller => _currentRole == UserRole.caller;

  Future<void> initialize() async {
    if (_isInitialized) return;
    
    final prefs = await SharedPreferences.getInstance();
    
    // Load or generate device hash
    _deviceHash = prefs.getString(_deviceHashKey) ?? _generateDeviceHash();
    if (!prefs.containsKey(_deviceHashKey)) {
      await prefs.setString(_deviceHashKey, _deviceHash);
    }

    // Load role
    final roleStr = prefs.getString(_roleKey);
    _currentRole = roleStr != null ? UserRole.fromString(roleStr) : UserRole.caller;

    // Load token and user name
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

  Future<void> setRole(UserRole role, {String userName = ''}) async {
    final prefs = await SharedPreferences.getInstance();
    _currentRole = role;
    await prefs.setString(_roleKey, role.value);
    
    if (userName.isNotEmpty) {
      _userName = userName;
      await prefs.setString(_userNameKey, userName);
    }
    
    // Generate new mock token for role change
    _authToken = _generateMockToken(role);
    await prefs.setString(_tokenKey, _authToken);
    
    notifyListeners();
  }

  String _generateMockToken(UserRole role) {
    final payload = {
      'sub': 'user_${_deviceHash}',
      'role': role.value,
      'device_hash': _deviceHash,
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'exp': (DateTime.now().add(const Duration(days: 30))).millisecondsSinceEpoch ~/ 1000,
    };
    // Mock JWT-like token (not real JWT, just demo)
    final encoded = base64Url.encode(utf8.encode(jsonEncode(payload)));
    return 'mock.$encoded.signature';
  }

  Map<String, String> getAuthHeaders() {
    return {
      'Content-Type': 'application/json',
      'X-Role': _currentRole.value,
      'Authorization': 'Bearer $_authToken',
      'X-Device-Hash': _deviceHash,
    };
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_roleKey);
    await prefs.remove(_tokenKey);
    await prefs.remove(_userNameKey);
    _currentRole = UserRole.caller;
    _authToken = '';
    _userName = '';
    notifyListeners();
  }

  String getRoleDisplayName() {
    return _currentRole.displayName;
  }

  List<UserRole> getAvailableRoles() {
    return [UserRole.caller, UserRole.dispatcher, UserRole.admin];
  }
}