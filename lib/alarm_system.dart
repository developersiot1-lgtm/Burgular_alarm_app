import 'package:flutter/material.dart';
import 'api_service.dart';
import 'offline_manager.dart';
import 'connection_manager.dart';
import 'notification_service.dart';
import 'settings_manager.dart';

/// System states
enum SystemState {
  disarmed,
  armed,
  stayArmed,
  alarm,
}

/// Device model
class Device {
  final String id;
  final String name;
  final String type;
  final String status;
  final int battery;
  final String zone;
  final String lastActivity;

  Device({
    required this.id,
    required this.name,
    required this.type,
    required this.status,
    required this.battery,
    required this.zone,
    required this.lastActivity,
  });
  static int _toInt(dynamic value, [int fallback = 0]) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }
  factory Device.fromJson(Map json) {
    final batteryRaw =
        json['battery'] ?? json['battery_level'] ?? json['batterylevel'];

    return Device(
      id: json['id']?.toString() ?? '',
      name: json['name'] ?? 'Unknown Device',
      type: json['type'] ?? 'unknown',
      status: json['status'] ?? 'offline',
      battery: _toInt(batteryRaw), // ✅ safe parse
      zone: json['zone'] ?? 'Unknown',
      lastActivity:
      json['last_activity'] ?? DateTime.now().toIso8601String(),
    );
  }


  String get typeIcon {
    switch (type) {
      case 'door':
        return '🚪';
      case 'window':
        return '🪟';
      case 'motion':
        return '👁️';
      case 'camera':
        return '📷';
      default:
        return '📱';
    }
  }
}

/// Activity log model
class ActivityLog {
  final String timestamp;
  final String event;
  final String device;
  final String user;

  ActivityLog({
    required this.timestamp,
    required this.event,
    required this.device,
    required this.user,
  });

  factory ActivityLog.fromJson(Map<String, dynamic> json) {
    return ActivityLog(
      timestamp: json['timestamp'] ?? DateTime.now().toIso8601String(),
      event: json['event'] ?? 'Unknown Event',
      device: json['device'] ?? 'Unknown Device',
      user: json['user'] ?? 'System',
    );
  }
}

/// Alarm System Provider
class AlarmSystemProvider with ChangeNotifier {
  ApiService? _apiService;
  String? _deviceUuid;

  SystemState _currentState = SystemState.disarmed;
  List<Device> _devices = [];
  List<ActivityLog> _activityLogs = [];
  bool _isLoading = false;
  String? _error;

  // Offline support
  final OfflineManager _offlineManager = OfflineManager();
  ConnectionManager? _connectionManager;
  bool _isOfflineMode = false;
  bool _isSOSMode = false;

  Timer? _systemStatePollTimer;
  bool _systemStatePollInFlight = false;
  int? _lastSystemStateId;
  String? _lastSystemStateReason;

  // Getters
  SystemState get currentState => _currentState;
  List<Device> get devices => _devices;
  List<ActivityLog> get activityLogs => _activityLogs;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isOfflineMode => _isOfflineMode;
  bool get isSOSMode => _isSOSMode;
  bool get hasPendingSync => _offlineManager.hasPendingActions;
  int get pendingActionsCount => _offlineManager.pendingActionsCount;

  /// Initialize alarm system
  Future<void> initialize(ApiService apiService, {required String deviceUuid}) async {
    _apiService = apiService;
    _deviceUuid = deviceUuid;

    // Initialize offline manager
    await _offlineManager.initialize();

    // Initialize connection manager
    _connectionManager = ConnectionManager();
    await _connectionManager!.initialize(deviceUuid);

    // Listen to connection changes
    _connectionManager!.addListener(() {
      _isOfflineMode = _connectionManager!.isOffline;
      notifyListeners();
    });

    _isOfflineMode = _connectionManager!.isOffline;

    // Load initial data
    await loadData();

    // Keep watching for alarm triggers so the app can notify immediately.
    _startSystemStatePolling();
  }

  static int? _toIntOrNull(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }

  void _startSystemStatePolling() {
    _systemStatePollTimer?.cancel();
    _systemStatePollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pollSystemState();
    });
  }

  Future<void> _pollSystemState() async {
    if (_apiService == null) return;
    if (!(_connectionManager?.isOnline ?? false)) return;
    if (_systemStatePollInFlight) return;

    _systemStatePollInFlight = true;
    try {
      final stateData = await _apiService!.getSystemState();
      if (stateData == null) return;

      final newId = _toIntOrNull(stateData['id']);
      final newState = _parseSystemState(stateData['state']);
      final reasonRaw = stateData['reason'] ?? stateData['alarm_reason'] ?? stateData['triggered_sensor'];
      final reason = reasonRaw?.toString();

      final changed = (newId != null && newId != _lastSystemStateId) ||
          (newId == null && newState != _currentState);

      if (!changed) return;

      _lastSystemStateId = newId;
      _lastSystemStateReason = reason;
      _currentState = newState;
      notifyListeners();

      if (newState == SystemState.alarm && SettingsManager().alarmNotification) {
        final body = (reason != null && reason.trim().isNotEmpty)
            ? 'Triggered: $reason'
            : 'Alarm triggered';
        await NotificationService.instance.showAlarmTriggered(
          title: 'ALARM',
          body: body,
        );
      }
    } catch (e) {
      // Don't surface polling failures as UI errors; it should be best-effort.
      print('❌ System state poll error: $e');
    } finally {
      _systemStatePollInFlight = false;
    }
  }

  /// Load data from server or offline storage
  Future<void> loadData() async {
    if (_isLoading) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      if (_connectionManager?.isOnline ?? false) {
        // Load from server
        await _loadFromServer();

        // Save to offline storage
        await _saveToOfflineStorage();

        // Sync pending actions
        await _offlineManager.syncPendingActions();
      } else {
        // Load from offline storage
        await _loadFromOfflineStorage();
      }
    } catch (e) {
      _error = e.toString();
      print('❌ Load data error: $e');

      // Try loading from offline storage as fallback
      try {
        await _loadFromOfflineStorage();
      } catch (offlineError) {
        print('❌ Offline load error: $offlineError');
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Load data from server
  Future<void> _loadFromServer() async {
    if (_apiService == null) return;

    // Get system state
    final stateData = await _apiService!.getSystemState();
    if (stateData != null && stateData['state'] != null) {
      _currentState = _parseSystemState(stateData['state']);
      _lastSystemStateId = _toIntOrNull(stateData['id']);
      _lastSystemStateReason =
          (stateData['reason'] ?? stateData['alarm_reason'] ?? stateData['triggered_sensor'])?.toString();
    }

    // Get devices
    final devicesData = await _apiService!.getDevices();
    _devices = devicesData.map((d) => Device.fromJson(d)).toList();

    // Get activity logs
    final logsData = await _apiService!.getActivityLogs(limit: 50);
    _activityLogs = logsData.map((l) => ActivityLog.fromJson(l)).toList();
  }

  /// Save data to offline storage
  Future<void> _saveToOfflineStorage() async {
    await _offlineManager.saveSystemState(_currentState.name);
    await _offlineManager.saveDevices(
      _devices.map((d) => {
        'id': d.id,
        'name': d.name,
        'type': d.type,
        'status': d.status,
        'battery': d.battery,
        'zone': d.zone,
        'last_activity': d.lastActivity,
      }).toList(),
    );
    await _offlineManager.saveActivityLogs(
      _activityLogs.map((l) => {
        'timestamp': l.timestamp,
        'event': l.event,
        'device': l.device,
        'user': l.user,
      }).toList(),
    );
  }

  /// Load data from offline storage
  Future<void> _loadFromOfflineStorage() async {
    final stateData = _offlineManager.getSystemState();
    if (stateData != null) {
      _currentState = _parseSystemState(stateData['state']);
    }

    final devicesData = _offlineManager.getDevices();
    _devices = devicesData.map((d) => Device.fromJson(d)).toList();

    final logsData = _offlineManager.getActivityLogs();
    _activityLogs = logsData.map((l) => ActivityLog.fromJson(l)).toList();

    _isOfflineMode = true;
  }

  /// Change system state
  Future<void> changeSystemState(SystemState newState) async {
    if (_isLoading) return;

    _isLoading = true;
    notifyListeners();

    try {
      final stateString = _systemStateToString(newState);

      if (_connectionManager?.isOnline ?? false) {
        // Send to server via connection manager
        final success = await _connectionManager!.sendAlarmCommand(
          stateString,
          user: 'Mobile App',
        );

        if (success) {
          _currentState = newState;
          await _saveToOfflineStorage();
        } else {
          throw Exception('Failed to change state');
        }
      } else {
        // Queue action for later
        await _offlineManager.queueAction({
          'type': 'state_change',
          'state': stateString,
          'user': 'Mobile App',
        });

        // Update local state
        _currentState = newState;
        await _saveToOfflineStorage();
      }

      // Add activity log (local)
      _activityLogs.insert(0, ActivityLog(
        timestamp: DateTime.now().toIso8601String(),
        event: stateDisplayName,
        device: 'Mobile App',
        user: 'User',
      ));

// Queue log so it also goes to PHP logs table
      await _offlineManager.queueAction({
        'type': 'activity_log',
        'event': stateDisplayName,   // e.g. "ARMED", "DISARMED"
        'device': 'Mobile App',
        'user': 'User',
      });

// If we are online, push it immediately
      if (_offlineManager.isOnline) {
        await _offlineManager.syncPendingActions();
      }

      _error = null;
    } catch (e) {
      _error = e.toString();
      print('❌ Change state error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }

  }

  @override
  void dispose() {
    _systemStatePollTimer?.cancel();
    super.dispose();
  }

  /// Trigger SOS alarm
  Future<void> triggerSOSAlarm() async {
    try {
      _isSOSMode = true;
      notifyListeners();

      if (_connectionManager?.isOnline ?? false) {
        await _connectionManager!.triggerSOS();
      } else {
        await _offlineManager.enableSOSMode();
      }

      _currentState = SystemState.alarm;
      notifyListeners();
    } catch (e) {
      print('❌ Trigger SOS error: $e');
    }
  }

  /// Stop SOS alarm
  Future<void> stopSOSAlarm() async {
    try {
      _isSOSMode = false;
      await _offlineManager.disableSOSMode();
      _currentState = SystemState.disarmed;
      notifyListeners();
    } catch (e) {
      print('❌ Stop SOS error: $e');
    }
  }

  /// Parse system state from string
  SystemState _parseSystemState(String? state) {
    switch (state?.toLowerCase()) {
      case 'armed':
        return SystemState.armed;
      case 'stay_armed':
      case 'stay_arm':
        return SystemState.stayArmed;
      case 'alarm':
        return SystemState.alarm;
      case 'disarmed':
      default:
        return SystemState.disarmed;
    }
  }

  /// Convert system state to string
  String _systemStateToString(SystemState state) {
    switch (state) {
      case SystemState.armed:
        return 'armed';
      case SystemState.stayArmed:
        return 'stay_arm';
      case SystemState.alarm:
        return 'alarm';
      case SystemState.disarmed:
        return 'disarmed';
    }
  }

  /// Get state display name
  String get stateDisplayName {
    switch (_currentState) {
      case SystemState.armed:
        return 'ARMED';
      case SystemState.stayArmed:
        return 'STAY ARMED';
      case SystemState.alarm:
        return 'ALARM';
      case SystemState.disarmed:
        return 'DISARMED';
    }
  }

  /// Get state color
  Color get stateColor {
    switch (_currentState) {
      case SystemState.armed:
        return Colors.green;
      case SystemState.stayArmed:
        return Colors.orange;
      case SystemState.alarm:
        return Colors.red;
      case SystemState.disarmed:
        return Colors.grey;
    }
  }

  @override
  void dispose() {
    _connectionManager?.dispose();
    super.dispose();
  }
}
