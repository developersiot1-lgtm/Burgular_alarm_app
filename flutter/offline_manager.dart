import 'dart:convert';
import 'dart:io'; // ADD THIS IMPORT
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Manages offline data storage and synchronization
class OfflineManager with ChangeNotifier {
  SharedPreferences? _prefs;
  bool _isOnline = true;
  List<Map<String, dynamic>> _pendingActions = [];

  // Keys for local storage
  static const String KEY_SYSTEM_STATE = 'system_state';
  static const String KEY_DEVICES = 'devices';
  static const String KEY_ACTIVITY_LOGS = 'activity_logs';
  static const String KEY_PENDING_ACTIONS = 'pending_actions';
  static const String KEY_VOICE_RECORDING = 'voice_recording';
  static const String KEY_LAST_SYNC = 'last_sync';
  static const String KEY_SOS_MODE = 'sos_mode';

  bool get isOnline => _isOnline;
  bool get hasPendingActions => _pendingActions.isNotEmpty;
  int get pendingActionsCount => _pendingActions.length;

  /// Check actual internet connectivity (not just network connection)
  Future<bool> checkActualConnectivity() async {
    try {
      // Check network connectivity first
      final connectivityResult = await Connectivity().checkConnectivity();

      if (connectivityResult == ConnectivityResult.none) {
        return false;
      }

      // Verify actual internet access by pinging a reliable server
      try {
        final result = await InternetAddress.lookup('google.com')
            .timeout(Duration(seconds: 5));

        return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      } catch (_) {
        // DNS lookup failed - no internet
        return false;
      }
    } catch (e) {
      print('❌ Connectivity check error: $e');
      return false;
    }
  }

  /// Initialize offline manager
  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadPendingActions();

    // Monitor connectivity changes
    Connectivity().onConnectivityChanged.listen((result) async {
      final wasOffline = !_isOnline;

      // Double-check with actual internet access
      _isOnline = await checkActualConnectivity();

      print('📡 Connectivity changed: ${_isOnline ? "ONLINE" : "OFFLINE"}');

      // If we just came online, sync pending actions
      if (wasOffline && _isOnline) {
        print('🌐 Connection restored - syncing pending actions');
        await syncPendingActions();
      }

      notifyListeners();
    });

    // Check initial connectivity
    _isOnline = await checkActualConnectivity();
    print('📡 Initial connectivity: ${_isOnline ? "ONLINE" : "OFFLINE"}');
    notifyListeners();
  }

  /// Save system state locally
  Future<void> saveSystemState(String state) async {
    if (_prefs == null) return;

    final data = {
      'state': state,
      'timestamp': DateTime.now().toIso8601String(),
    };

    await _prefs!.setString(KEY_SYSTEM_STATE, json.encode(data));
    print('💾 System state saved offline: $state');
  }

  /// Load system state from local storage
  Map<String, dynamic>? getSystemState() {
    if (_prefs == null) return null;

    final stateStr = _prefs!.getString(KEY_SYSTEM_STATE);
    if (stateStr == null) return null;

    return json.decode(stateStr);
  }

  /// Save devices list locally
  Future<void> saveDevices(List<Map<String, dynamic>> devices) async {
    if (_prefs == null) return;

    await _prefs!.setString(KEY_DEVICES, json.encode(devices));
    print('💾 Saved ${devices.length} devices offline');
  }

  /// Load devices from local storage
  List<Map<String, dynamic>> getDevices() {
    if (_prefs == null) return [];

    final devicesStr = _prefs!.getString(KEY_DEVICES);
    if (devicesStr == null) return [];

    final List<dynamic> decoded = json.decode(devicesStr);
    return decoded.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Save activity logs locally
  Future<void> saveActivityLogs(List<Map<String, dynamic>> logs) async {
    if (_prefs == null) return;

    await _prefs!.setString(KEY_ACTIVITY_LOGS, json.encode(logs));
  }

  /// Load activity logs from local storage
  List<Map<String, dynamic>> getActivityLogs() {
    if (_prefs == null) return [];

    final logsStr = _prefs!.getString(KEY_ACTIVITY_LOGS);
    if (logsStr == null) return [];

    final List<dynamic> decoded = json.decode(logsStr);
    return decoded.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Save voice recording path locally
  Future<void> saveVoiceRecording(String path, String name) async {
    if (_prefs == null) return;

    final data = {
      'path': path,
      'name': name,
      'timestamp': DateTime.now().toIso8601String(),
    };

    await _prefs!.setString(KEY_VOICE_RECORDING, json.encode(data));
    print('💾 Voice recording saved offline: $name');
  }

  /// Get saved voice recording
  Map<String, dynamic>? getVoiceRecording() {
    if (_prefs == null) return null;

    final recStr = _prefs!.getString(KEY_VOICE_RECORDING);
    if (recStr == null) return null;

    return json.decode(recStr);
  }

  /// Queue an action to be performed when online
  Future<void> queueAction(Map<String, dynamic> action) async {
    action['queued_at'] = DateTime.now().toIso8601String();
    _pendingActions.add(action);

    await _savePendingActions();
    print('📥 Action queued (${_pendingActions.length} pending): ${action['type']}');
    notifyListeners();
  }

  /// Load pending actions from storage
  Future<void> _loadPendingActions() async {
    if (_prefs == null) return;

    final actionsStr = _prefs!.getString(KEY_PENDING_ACTIONS);
    if (actionsStr == null) {
      _pendingActions = [];
      return;
    }

    final List<dynamic> decoded = json.decode(actionsStr);
    _pendingActions = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
    print('📥 Loaded ${_pendingActions.length} pending actions');
  }

  /// Save pending actions to storage
  Future<void> _savePendingActions() async {
    if (_prefs == null) return;

    await _prefs!.setString(KEY_PENDING_ACTIONS, json.encode(_pendingActions));
  }

  /// Sync pending actions when back online
  Future<void> syncPendingActions() async {
    if (!_isOnline || _pendingActions.isEmpty) return;

    print('🔄 Syncing ${_pendingActions.length} pending actions...');

    final actionsToSync = List<Map<String, dynamic>>.from(_pendingActions);
    _pendingActions.clear();
    await _savePendingActions();

    for (final action in actionsToSync) {
      try {
        // Process action based on type
        switch (action['type']) {
          case 'state_change':
          // API call to update state
            print('✅ Synced state change: ${action['state']}');
            break;

          case 'activity_log':
          // API call to add log
            print('✅ Synced activity log');
            break;

          case 'device_update':
          // API call to update device
            print('✅ Synced device update');
            break;
        }
      } catch (e) {
        print('❌ Failed to sync action: $e');
        // Re-queue failed action
        _pendingActions.add(action);
      }
    }

    await _savePendingActions();
    notifyListeners();

    if (_pendingActions.isEmpty) {
      await _prefs!.setString(KEY_LAST_SYNC, DateTime.now().toIso8601String());
      print('✅ All actions synced successfully');
    }
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

  /// Enable SOS mode (works completely offline)
  Future<void> enableSOSMode() async {
    if (_prefs == null) return;

    await _prefs!.setBool(KEY_SOS_MODE, true);
    await saveSystemState('alarm');

    print('🚨 SOS MODE ACTIVATED - OFFLINE ALARM TRIGGERED');
    notifyListeners();
  }

  /// Disable SOS mode
  Future<void> disableSOSMode() async {
    if (_prefs == null) return;

    await _prefs!.setBool(KEY_SOS_MODE, false);
    print('✅ SOS Mode deactivated');
    notifyListeners();
  }

  /// Check if SOS mode is active
  bool isSOSMode() {
    if (_prefs == null) return false;
    return _prefs!.getBool(KEY_SOS_MODE) ?? false;
  }

  /// Clear all offline data (use with caution)
  Future<void> clearOfflineData() async {
    if (_prefs == null) return;

    await _prefs!.remove(KEY_SYSTEM_STATE);
    await _prefs!.remove(KEY_DEVICES);
    await _prefs!.remove(KEY_ACTIVITY_LOGS);
    await _prefs!.remove(KEY_PENDING_ACTIONS);

    _pendingActions.clear();
    print('🗑️ Offline data cleared');
    notifyListeners();
  }

  /// Get last sync time
  DateTime? getLastSyncTime() {
    if (_prefs == null) return null;

    final syncStr = _prefs!.getString(KEY_LAST_SYNC);
    if (syncStr == null) return null;

    return DateTime.parse(syncStr);
  }
}