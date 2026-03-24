import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Manages offline data storage and synchronization
class OfflineManager with ChangeNotifier {
  SharedPreferences? _prefs;
  bool _isOnline = true;
  List<Map<String, dynamic>> _pendingActions = [];

  static const String _baseUrl = 'https://monsow.in/alarm/index.php';

  static const String KEY_SYSTEM_STATE   = 'system_state';
  static const String KEY_DEVICES        = 'devices';
  static const String KEY_ACTIVITY_LOGS  = 'activity_logs';
  static const String KEY_PENDING_ACTIONS = 'pending_actions';
  static const String KEY_VOICE_RECORDING = 'voice_recording';
  static const String KEY_LAST_SYNC      = 'last_sync';
  static const String KEY_SOS_MODE       = 'sos_mode';

  bool get isOnline             => _isOnline;
  bool get hasPendingActions    => _pendingActions.isNotEmpty;
  int  get pendingActionsCount  => _pendingActions.length;

  // ─────────────────────────────────────────────
  // INIT
  // ─────────────────────────────────────────────

  Future<bool> checkActualConnectivity() async {
    try {
      final result = await Connectivity().checkConnectivity();
      if (result == ConnectivityResult.none) return false;
      final lookup = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));
      return lookup.isNotEmpty && lookup[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadPendingActions();

    Connectivity().onConnectivityChanged.listen((result) async {
      final wasOffline = !_isOnline;
      _isOnline = await checkActualConnectivity();
      if (wasOffline && _isOnline) await syncPendingActions();
      notifyListeners();
    });

    _isOnline = await checkActualConnectivity();
    notifyListeners();
  }

  // ─────────────────────────────────────────────
  // SAVE / LOAD LOCAL STATE
  // ─────────────────────────────────────────────

  Future<void> saveSystemState(String state) async {
    await _prefs?.setString(KEY_SYSTEM_STATE,
        json.encode({'state': state, 'timestamp': DateTime.now().toIso8601String()}));
  }

  Map<String, dynamic>? getSystemState() {
    final s = _prefs?.getString(KEY_SYSTEM_STATE);
    return s == null ? null : json.decode(s);
  }

  Future<void> saveDevices(List<Map<String, dynamic>> devices) async =>
      _prefs?.setString(KEY_DEVICES, json.encode(devices));

  List<Map<String, dynamic>> getDevices() {
    final s = _prefs?.getString(KEY_DEVICES);
    if (s == null) return [];
    return (json.decode(s) as List).map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> saveActivityLogs(List<Map<String, dynamic>> logs) async =>
      _prefs?.setString(KEY_ACTIVITY_LOGS, json.encode(logs));

  List<Map<String, dynamic>> getActivityLogs() {
    final s = _prefs?.getString(KEY_ACTIVITY_LOGS);
    if (s == null) return [];
    return (json.decode(s) as List).map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> saveVoiceRecording(String path, String name) async =>
      _prefs?.setString(KEY_VOICE_RECORDING,
          json.encode({'path': path, 'name': name, 'timestamp': DateTime.now().toIso8601String()}));

  Map<String, dynamic>? getVoiceRecording() {
    final s = _prefs?.getString(KEY_VOICE_RECORDING);
    return s == null ? null : json.decode(s);
  }

  Future<List<int>?> getSavedVoiceRecording() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final base64Audio = prefs.getString('offline_voice_data');
      if (base64Audio == null) return null;
      return base64Decode(base64Audio);
    } catch (e) {
      debugPrint('getSavedVoiceRecording error: $e');
      return null;
    }
  }

  // ─────────────────────────────────────────────
  // PENDING ACTION QUEUE
  // ─────────────────────────────────────────────

  Future<void> queueAction(Map<String, dynamic> action) async {
    action['queued_at'] = DateTime.now().toIso8601String();
    _pendingActions.add(action);
    await _savePendingActions();
    notifyListeners();
  }

  Future<void> _loadPendingActions() async {
    final s = _prefs?.getString(KEY_PENDING_ACTIONS);
    if (s == null) { _pendingActions = []; return; }
    _pendingActions =
        (json.decode(s) as List).map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> _savePendingActions() async =>
      _prefs?.setString(KEY_PENDING_ACTIONS, json.encode(_pendingActions));

  // ─────────────────────────────────────────────
  // ✅ FIXED: REAL HTTP calls for every pending action
  // ─────────────────────────────────────────────

  Future<void> syncPendingActions() async {
    if (!_isOnline || _pendingActions.isEmpty) return;

    print('🔄 Syncing ${_pendingActions.length} pending actions...');
    final actionsToSync = List<Map<String, dynamic>>.from(_pendingActions);
    _pendingActions.clear();
    await _savePendingActions();

    for (final action in actionsToSync) {
      try {
        switch (action['type']) {

        // ✅ FIXED: actually POSTs the state to the server
          case 'state_change':
            final res = await http.post(
              Uri.parse('$_baseUrl?action=system_state'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'state': action['state'],
                'user':  action['user'] ?? 'offline_sync',
              }),
            ).timeout(const Duration(seconds: 10));
            if (res.statusCode != 200) {
              throw Exception('State sync failed: ${res.statusCode}');
            }
            print('✅ Synced state change: ${action['state']}');
            break;

        // ✅ FIXED: actually POSTs the log entry
          case 'activity_log':
            await http.post(
              Uri.parse('$_baseUrl?action=logs'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'event':  action['event']  ?? 'Offline Action',
                'device': action['device'] ?? 'Mobile App',
                'user':   action['user']   ?? 'offline_sync',
              }),
            ).timeout(const Duration(seconds: 10));
            print('✅ Synced activity log');
            break;

        // ✅ FIXED: actually POSTs the heartbeat
          case 'device_update':
            await http.post(
              Uri.parse('$_baseUrl?action=device_heartbeat'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'device_uuid': action['device_uuid'],
                'status':      action['status'] ?? 'online',
              }),
            ).timeout(const Duration(seconds: 10));
            print('✅ Synced device update');
            break;
        }
      } catch (e) {
        print('❌ Failed to sync action: $e — re-queuing');
        _pendingActions.add(action);
      }
    }

    await _savePendingActions();
    notifyListeners();

    if (_pendingActions.isEmpty) {
      await _prefs?.setString(KEY_LAST_SYNC, DateTime.now().toIso8601String());
      print('✅ All actions synced successfully');
    }
  }

  // ─────────────────────────────────────────────
  // SOS MODE
  // ─────────────────────────────────────────────

  Future<void> enableSOSMode() async {
    await _prefs?.setBool(KEY_SOS_MODE, true);
    await saveSystemState('alarm');
    notifyListeners();
  }

  Future<void> disableSOSMode() async {
    await _prefs?.setBool(KEY_SOS_MODE, false);
    notifyListeners();
  }

  bool isSOSMode() => _prefs?.getBool(KEY_SOS_MODE) ?? false;

  // ─────────────────────────────────────────────
  // UTILITIES
  // ─────────────────────────────────────────────

  Future<void> clearOfflineData() async {
    await _prefs?.remove(KEY_SYSTEM_STATE);
    await _prefs?.remove(KEY_DEVICES);
    await _prefs?.remove(KEY_ACTIVITY_LOGS);
    await _prefs?.remove(KEY_PENDING_ACTIONS);
    _pendingActions.clear();
    notifyListeners();
  }

  DateTime? getLastSyncTime() {
    final s = _prefs?.getString(KEY_LAST_SYNC);
    return s == null ? null : DateTime.parse(s);
  }
}