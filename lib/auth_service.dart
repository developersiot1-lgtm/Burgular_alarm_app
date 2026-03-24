import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ================================================================
// auth_service.dart
// Handles all login / register / forgot-password API calls
// and persists the logged-in user to SharedPreferences.
// ================================================================

class AuthService {
  static const String _baseUrl = 'https://monsow.in/alarm/auth.php';

  // SharedPrefs keys
  static const String _keyUserId    = 'auth_user_id';
  static const String _keyUserName  = 'auth_user_name';
  static const String _keyUserEmail = 'auth_user_email';

  // ── Singleton ────────────────────────────────────────────────
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  // ── Safe JSON decode — never throws FormatException ──────────
  Map<String, dynamic>? _safeJson(http.Response res) {
    final body = res.body.trim();
    if (body.isEmpty) {
      print('⚠️ Empty response body from server (status ${res.statusCode})');
      return null;
    }
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      print('⚠️ Bad JSON from server: ${body.substring(0, body.length.clamp(0, 200))}');
      return null;
    }
  }

  // ── Cached current user ──────────────────────────────────────
  int?    _userId;
  String? _userName;
  String? _userEmail;

  int?    get userId    => _userId;
  String? get userName  => _userName;
  String? get userEmail => _userEmail;
  bool    get isLoggedIn => _userId != null && _userId! > 0;

  // ── Load saved session on app start ─────────────────────────
  Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _userId    = prefs.getInt(_keyUserId);
    _userName  = prefs.getString(_keyUserName);
    _userEmail = prefs.getString(_keyUserEmail);
  }

  Future<void> _saveSession(int userId, String name, String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyUserId,       userId);
    await prefs.setString(_keyUserName,  name);
    await prefs.setString(_keyUserEmail, email);
    _userId    = userId;
    _userName  = name;
    _userEmail = email;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUserId);
    await prefs.remove(_keyUserName);
    await prefs.remove(_keyUserEmail);
    _userId    = null;
    _userName  = null;
    _userEmail = null;
  }

  // ── REGISTER ─────────────────────────────────────────────────
  Future<AuthResult> register({
    required String name,
    required String email,
    required String password,
  }) async {
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl?action=register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name, 'email': email, 'password': password}),
      ).timeout(const Duration(seconds: 15));

      final data = _safeJson(res);
      if (data == null) return AuthResult.failure('Server returned invalid response. Check server logs.');
      if (data['success'] == true) {
        await _saveSession(data['user_id'], data['name'], data['email']);
        return AuthResult.success(data['message'] ?? 'Registered');
      }
      return AuthResult.failure(data['message'] ?? 'Registration failed');
    } catch (e) {
      return AuthResult.failure('Network error: $e');
    }
  }

  // ── LOGIN ────────────────────────────────────────────────────
  Future<AuthResult> login({
    required String email,
    required String password,
  }) async {
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl?action=login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      ).timeout(const Duration(seconds: 15));

      final data = _safeJson(res);
      if (data == null) return AuthResult.failure('Server returned invalid response. Check server logs.');
      if (data['success'] == true) {
        await _saveSession(data['user_id'], data['name'], data['email']);
        return AuthResult.success(data['message'] ?? 'Login successful');
      }
      return AuthResult.failure(data['message'] ?? 'Login failed');
    } catch (e) {
      return AuthResult.failure('Network error: $e');
    }
  }

  // ── FORGOT PASSWORD — send OTP ───────────────────────────────
  Future<AuthResult> forgotPassword(String email) async {
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl?action=forgot_password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      ).timeout(const Duration(seconds: 15));

      final data = _safeJson(res);
      if (data == null) return AuthResult.failure('Server returned invalid response.');
      return data['success'] == true
          ? AuthResult.success(data['message'] ?? 'OTP sent')
          : AuthResult.failure(data['message'] ?? 'Failed');
    } catch (e) {
      return AuthResult.failure('Network error: $e');
    }
  }

  // ── VERIFY OTP ───────────────────────────────────────────────
  Future<AuthResult> verifyOtp(String email, String otp) async {
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl?action=verify_otp'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'otp': otp}),
      ).timeout(const Duration(seconds: 15));

      final data = _safeJson(res);
      if (data == null) return AuthResult.failure('Server returned invalid response.');
      return data['success'] == true
          ? AuthResult.success(data['message'] ?? 'Verified')
          : AuthResult.failure(data['message'] ?? 'Invalid code');
    } catch (e) {
      return AuthResult.failure('Network error: $e');
    }
  }

  // ── RESET PASSWORD ───────────────────────────────────────────
  Future<AuthResult> resetPassword({
    required String email,
    required String otp,
    required String newPassword,
  }) async {
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl?action=reset_password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'otp': otp, 'new_password': newPassword}),
      ).timeout(const Duration(seconds: 15));

      final data = _safeJson(res);
      if (data == null) return AuthResult.failure('Server returned invalid response.');
      return data['success'] == true
          ? AuthResult.success(data['message'] ?? 'Password reset')
          : AuthResult.failure(data['message'] ?? 'Failed');
    } catch (e) {
      return AuthResult.failure('Network error: $e');
    }
  }

  // ── LINK DEVICE TO USER ──────────────────────────────────────
  Future<bool> addUserDevice(String deviceUuid) async {
    if (_userId == null) return false;
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl?action=add_user_device'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': _userId, 'device_uuid': deviceUuid}),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return data['success'] == true;
    } catch (e) {
      return false;
    }
  }

  // ── GET USER'S DEVICES ───────────────────────────────────────
  Future<List<Map<String, dynamic>>> getUserDevices() async {
    if (_userId == null) return [];
    try {
      final res = await http.get(
        Uri.parse('$_baseUrl?action=get_user_devices&user_id=$_userId'),
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return List<Map<String, dynamic>>.from(data['devices'] ?? []);
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  // ── REMOVE DEVICE FROM USER ──────────────────────────────────
  Future<bool> removeUserDevice(String deviceUuid) async {
    if (_userId == null) return false;
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl?action=remove_user_device'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': _userId, 'device_uuid': deviceUuid}),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return data['success'] == true;
    } catch (e) {
      return false;
    }
  }
}

// ── Result wrapper ────────────────────────────────────────────
class AuthResult {
  final bool success;
  final String message;
  AuthResult._({required this.success, required this.message});
  factory AuthResult.success(String msg) => AuthResult._(success: true,  message: msg);
  factory AuthResult.failure(String msg) => AuthResult._(success: false, message: msg);
}