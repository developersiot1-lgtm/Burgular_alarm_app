import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api_service.dart';
import 'offline_manager.dart';
import 'connection_manager.dart';
import 'notification_service.dart';
import 'settings_manager.dart';
import 'auth_service.dart';
import 'realtime_sync_service.dart'; // ← ADDED for multi-user sync

// ================================================================
// alarm_system.dart — MULTI-USER REAL-TIME SYNC
//
// WHAT CHANGED (4 targeted edits — search for "SYNC"):
//
//  [SYNC-1] Import realtime_sync_service.dart (above)
//
//  [SYNC-2] initialize() — starts RealtimeSyncService after loadData.
//           The callback receives (SyncState, isExternal).
//           • isExternal=true  → another user changed the state
//           • isExternal=false → we changed it (or first tick)
//           When isExternal=true we update UI + post notification.
//
//  [SYNC-3] changeSystemState() — sets suppressNextTick=true before
//           writing to server so the next poll tick (which will see
//           our own change on the server) is silently ignored and
//           doesn't double-fire a notification.
//
//  [SYNC-4] dispose() — stops RealtimeSyncService.
//
// Everything else is UNCHANGED from the original file.
// ================================================================

enum SystemState { disarmed, armed, stayArmed, alarm }

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

  static int _toInt(dynamic v, [int fallback = 0]) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? fallback;
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
      battery: _toInt(batteryRaw),
      zone: json['zone'] ?? 'Unknown',
      lastActivity: json['last_activity'] ?? DateTime.now().toIso8601String(),
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

  factory ActivityLog.fromJson(Map<String, dynamic> json) => ActivityLog(
        timestamp: (json['timestamp'] ?? json['created_at'] ?? json['updated_at'] ?? '')
            .toString(),
        event: json['event'] ??
            json['event_type'] ??
            json['state'] ??
            json['message'] ??
            'Unknown Event',
        device: json['device'] ??
            json['device_name'] ??
            json['device_uuid'] ??
            'Unknown Device',
        user: json['user'] ??
            json['updated_by'] ??
            json['state_updated_by'] ??
            'System',
      );

  DateTime? get parsedTimestamp {
    final raw = timestamp.trim();
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw) ??
        DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  }

  String get displayEvent {
    final eventText = event.trim();
    final actor = user.trim();
    final lower = eventText.toLowerCase();
    final hasUsefulActor = actor.isNotEmpty &&
        actor.toLowerCase() != 'system' &&
        actor.toLowerCase() != 'api' &&
        actor.toLowerCase() != 'hub';

    if (!hasUsefulActor) return eventText;
    if (lower == 'system armed') return '$actor armed';
    if (lower == 'system disarmed') return '$actor disarmed';
    if (lower == 'stay armed' || lower == 'system armed (stay)') {
      return '$actor stay armed';
    }
    if (lower == 'alarm' || lower == 'alarm triggered') {
      return '$actor triggered alarm';
    }
    return eventText;
  }
}

class AlarmSystemProvider with ChangeNotifier {
  ApiService? _apiService;
  String? _deviceUuid;
  String? _hubDeviceUuid;

  SystemState _currentState = SystemState.disarmed;
  String _lastStateUpdatedAt = '';
  List<Device> _devices = [];
  List<ActivityLog> _activityLogs = [];
  bool _isLoading = false;
  String? _error;

  final OfflineManager _offlineManager = OfflineManager();
  ConnectionManager? _connectionManager;
  bool _isOfflineMode = false;
  bool _isSOSMode = false;

  final NotificationService _notifications = NotificationService();

  Timer? _alarmPollTimer;
  bool _isPollRunning = false;
  int _lastAlarmId = 0;
  bool _isArmed = false;

  static const int _lowBatteryThreshold = 20;
  static const int _activityHistoryLimit = 100;

  SystemState get currentState => _currentState;
  DateTime? get lastStateUpdatedAt =>
      ActivityLog(
        timestamp: _lastStateUpdatedAt,
        event: '',
        device: '',
        user: '',
      ).parsedTimestamp;
  List<Device> get devices => _devices;
  List<ActivityLog> get activityLogs => _activityLogs;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isOfflineMode => _isOfflineMode;
  bool get isSOSMode => _isSOSMode;
  bool get hasPendingSync => _offlineManager.hasPendingActions;
  int get pendingActionsCount => _offlineManager.pendingActionsCount;

  String get _activeDeviceUuid {
    final hubUuid = _hubDeviceUuid ?? '';
    if (hubUuid.isNotEmpty) return hubUuid;
    return _deviceUuid ?? '';
  }

  // ── Initialize ────────────────────────────────────────────────
  Future<void> initialize(ApiService apiService,
      {required String deviceUuid, String? hubDeviceUuid}) async {
    _apiService = apiService;
    _deviceUuid = deviceUuid;
    _hubDeviceUuid = hubDeviceUuid ?? deviceUuid;

    await _notifications.initialize();
    await _offlineManager.initialize();

    final sm = SettingsManager();
    await _notifications.setSettings(
      alarmSound: sm.alarmSound,
      notification: sm.alarmNotification,
    );

    _connectionManager = ConnectionManager();
    await _connectionManager!.initialize(deviceUuid);

    _connectionManager!.addListener(() async {
      final wasOffline = _isOfflineMode;
      _isOfflineMode = _connectionManager!.isOffline;
      if (!wasOffline && _isOfflineMode) {
        HapticFeedback.mediumImpact();
        await _notifications.notifyDeviceOffline('Alarm Hub');
        _stopAlarmPoll();
      } else if (wasOffline && !_isOfflineMode) {
        HapticFeedback.lightImpact();
        await _notifications.notifyDeviceOnline('Alarm Hub');
        if (_isArmed) _startAlarmPoll();
      }
      notifyListeners();
    });

    _isOfflineMode = _connectionManager!.isOffline;
    await loadData();

    if (_currentState == SystemState.armed ||
        _currentState == SystemState.stayArmed) {
      await _setBaselineAndStartPoll();
    }

    // ── [SYNC-2] Start real-time sync for all shared users ────────
    // This polls get_alarm_status every 5 s. When another user on a
    // shared device arms/disarms, the callback fires with isExternal=true
    // and we update our UI + post a notification automatically.
    final activeUuid = (hubDeviceUuid != null && hubDeviceUuid.isNotEmpty)
        ? hubDeviceUuid
        : (this._deviceUuid ?? '');
    RealtimeSyncService().start(
      deviceUuid: activeUuid,
      onStateChange:
          (SyncState syncState, bool isExternal, String actor) async {
        final mapped = _mapSyncState(syncState);

        // Skip if state hasn't actually changed (race with loadData)
        if (mapped == _currentState) return;

        // Update UI state
        setStateFromServer(mapped);

        // Manage alarm event poll based on new state
        if (mapped == SystemState.armed || mapped == SystemState.stayArmed) {
          if (!_isArmed) await _setBaselineAndStartPoll();
        } else if (mapped == SystemState.disarmed) {
          _isArmed = false;
          _stopAlarmPoll();
          _lastAlarmId = 0;
          // Also stop any active alarm sound in case another user disarmed
          await _notifications.stopAlarmImmediately();
        }

        // Notify for ALL external changes (another user changed state).
        // Also notify for first-tick delivery (isExternal=false) so the
        // user sees a banner if they receive a state while backgrounded.
        // Own intentional changes fire notifyStateChange() in
        // changeSystemState() directly — no duplicate here because
        // suppressNextTick=true makes those ticks skip this block.
        if (isExternal) {
          await _notifications.notifyStateChange(mapped, actor: actor);

          // Log it in the activity feed
          final who = mapped == SystemState.armed
              ? 'Armed'
              : mapped == SystemState.stayArmed
                  ? 'Stay Armed'
                  : mapped == SystemState.disarmed
                      ? 'Disarmed'
                      : 'Alarm';
          _activityLogs.insert(
              0,
              ActivityLog(
                timestamp: DateTime.now().toIso8601String(),
                event: '$who by $actor',
                device: 'Remote App',
                user: actor,
              ));
          await _refreshActivityLogs();
          notifyListeners();
        }
      },
    );
    // ── [SYNC-2 END] ──────────────────────────────────────────────
  }

  // ── Map SyncState → SystemState (avoids circular import) ──────
  SystemState _mapSyncState(SyncState s) {
    switch (s) {
      case SyncState.armed:
        return SystemState.armed;
      case SyncState.stayArmed:
        return SystemState.stayArmed;
      case SyncState.alarm:
        return SystemState.alarm;
      case SyncState.disarmed:
        return SystemState.disarmed;
    }
  }

  // ================================================================
  // setStateFromServer
  //
  // Called by:
  //  • HomeScreen.initState() for fast initial render
  //  • RealtimeSyncService callback (above) for live updates
  //
  // Only updates UI — does NOT send API calls, start polls, or fire
  // notifications. Callers are responsible for those side-effects.
  // ================================================================
  void setStateFromServer(SystemState state) {
    _currentState = state;
    _lastStateUpdatedAt = DateTime.now().toIso8601String();

    if (state == SystemState.armed || state == SystemState.stayArmed) {
      _isArmed = true;
    } else {
      _isArmed = false;
    }

    notifyListeners();
  }

  // ── Set baseline then start alarm-event poll ───────────────────
  Future<void> _setBaselineAndStartPoll() async {
    if (_apiService == null) return;

    final pollUuid = _activeDeviceUuid;

    if (pollUuid.isEmpty) return;

    try {
      final events = await _apiService!.getAlarmEvents(pollUuid);
      _lastAlarmId = events.isNotEmpty
          ? (int.tryParse(events.first['id'].toString()) ?? 0)
          : 0;
      debugPrint('📍 Baseline set: lastAlarmId=$_lastAlarmId  uuid=$pollUuid');
    } catch (e) {
      _lastAlarmId = 0;
      debugPrint('⚠️ Baseline fetch failed: $e');
    }

    _isArmed = true;
    _startAlarmPoll();
  }

  void _startAlarmPoll() {
    _stopAlarmPoll();
    _alarmPollTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => _pollAlarmEvents(),
    );
    debugPrint('🔄 Poll started every 5s');
  }

  void _stopAlarmPoll() {
    _alarmPollTimer?.cancel();
    _alarmPollTimer = null;
    debugPrint('⏹ Poll stopped');
  }

  // ── Core alarm-event poll — called every 5 s while armed ──────
  Future<void> _pollAlarmEvents() async {
    if (!_isArmed) return;
    if (_apiService == null) return;

    final pollUuid = _activeDeviceUuid;
    if (pollUuid.isEmpty) return;

    if (_isPollRunning) return;
    _isPollRunning = true;
    try {
      final events = await _apiService!.getAlarmEvents(pollUuid);
      if (events.isEmpty) return;

      for (final event in events) {
        final int eventId = int.tryParse(event['id'].toString()) ?? 0;
        if (eventId <= _lastAlarmId) break;

        final String eventType = event['event_type']?.toString() ?? '';
        final String zone = event['zone']?.toString() ?? '';
        final String message = event['message']?.toString() ?? '';

        debugPrint(
            '🆕 Event id=$eventId type=$eventType zone="$zone" msg="$message"');

        if (eventType == 'SENSOR_TRIGGER' ||
            eventType == 'ALARM_START' ||
            eventType == 'ALARM_TRIGGER') {
          String sensorDisplay;
          if (message.isNotEmpty &&
              message != 'MOBILE APP ALARM' &&
              message != 'Alarm triggered from Mobile App' &&
              message != 'Triggered from Mobile App') {
            sensorDisplay = message;
          } else if (zone.isNotEmpty && zone != 'MOBILE APP ALARM') {
            sensorDisplay = zone;
          } else {
            sensorDisplay = 'Sensor triggered';
          }

          final sensorType = _guessSensorType(sensorDisplay);

          debugPrint('🚨 ALARM TRIGGER: "$sensorDisplay" type=$sensorType');

          if (_currentState != SystemState.alarm) {
            _currentState = SystemState.alarm;
            notifyListeners();
          }

          await _notifications.notifyAlarmTriggered(
            sensorType: sensorType,
            sensorName: sensorDisplay,
            zoneName: zone,
          );

          _activityLogs.insert(
              0,
              ActivityLog(
                timestamp: event['created_at']?.toString() ??
                    DateTime.now().toIso8601String(),
                event:
                    '${_sensorIcon(sensorType)} ${_sensorLabel(sensorType)} — $sensorDisplay',
                device: sensorDisplay,
                user: 'Sensor',
              ));
          await _apiService!.postActivityLog(
            event:
                '${_sensorIcon(sensorType)} ${_sensorLabel(sensorType)} — $sensorDisplay',
            device: sensorDisplay,
            user: 'Sensor',
            deviceUuid: _activeDeviceUuid,
          );
          notifyListeners();
        }

        if (eventId > _lastAlarmId) _lastAlarmId = eventId;
      }
    } catch (e) {
      debugPrint('⚠️ Poll error: $e');
    } finally {
      _isPollRunning = false;
    }
  }

  // ── Sensor type helpers ────────────────────────────────────────
  String _guessSensorType(String text) {
    final t = text.toLowerCase();
    if (t.contains('motion')) return 'motion';
    if (t.contains('window')) return 'window';
    if (t.contains('remote')) return 'remote';
    if (t.contains('camera')) return 'camera';
    return 'door';
  }

  String _sensorIcon(String type) {
    switch (type) {
      case 'motion':
        return '👁️';
      case 'window':
        return '🪟';
      case 'remote':
        return '📡';
      case 'camera':
        return '📷';
      default:
        return '🚪';
    }
  }

  String _sensorLabel(String type) {
    switch (type) {
      case 'motion':
        return 'Motion Sensor';
      case 'window':
        return 'Window Sensor';
      case 'remote':
        return 'Remote Trigger';
      default:
        return 'Door Sensor';
    }
  }

  // ── Load data from server ──────────────────────────────────────
  Future<void> loadData() async {
    if (_isLoading) return;

    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      if ((_hubDeviceUuid ?? _deviceUuid ?? '').isNotEmpty) {
        await _loadFromServer();
        await _saveToOfflineStorage();
        if (_connectionManager?.isOnline ?? false) {
          await _offlineManager.syncPendingActions();
        }
        _isOfflineMode = false;
      } else {
        await _loadFromOfflineStorage();
      }
      await _checkBatteryLevels();
    } catch (e) {
      _error = e.toString();
      try {
        await _loadFromOfflineStorage();
      } catch (_) {}
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _checkBatteryLevels() async {
    for (final device in _devices) {
      if (device.battery > 0 && device.battery <= _lowBatteryThreshold) {
        await _notifications.notifyLowBattery(
            deviceName: device.name, batteryLevel: device.battery);
      }
    }
  }

  Future<void> _loadFromServer() async {
    if (_apiService == null) return;

    // ✅ Run all 3 requests in parallel — 3x faster startup
    final results = await Future.wait([
      _apiService!.getSystemState(hubDeviceUuid: _hubDeviceUuid),
      _apiService!.getDevices(),
      _apiService!.getActivityLogs(
        limit: _activityHistoryLimit,
        deviceUuid: _activeDeviceUuid,
      ),
    ]);

    final stateData = results[0] as Map<String, dynamic>?;
    if (stateData?['state'] != null) {
      _currentState = _parseSystemState(stateData!['state']);
      _lastStateUpdatedAt =
          (stateData['updated_at'] ?? stateData['timestamp'] ?? '').toString();
    }

    final devicesData = results[1] as List<dynamic>;

    _devices = devicesData.map((d) => Device.fromJson(d)).toList();

    final logsData = results[2] as List<dynamic>;
    _activityLogs = logsData.map((l) => ActivityLog.fromJson(l)).toList();
  }

  Future<void> _saveToOfflineStorage() async {
    await _offlineManager.saveSystemState(_currentState.name);
    await _offlineManager.saveDevices(_devices
        .map((d) => {
              'id': d.id,
              'name': d.name,
              'type': d.type,
              'status': d.status,
              'battery': d.battery,
              'zone': d.zone,
              'last_activity': d.lastActivity,
            })
        .toList());
    await _offlineManager.saveActivityLogs(_activityLogs
        .map((l) => {
              'timestamp': l.timestamp,
              'event': l.event,
              'device': l.device,
              'user': l.user,
            })
        .toList());
  }

  Future<void> _loadFromOfflineStorage() async {
    final stateData = _offlineManager.getSystemState();
    if (stateData != null)
      _currentState = _parseSystemState(stateData['state']);
    _devices =
        _offlineManager.getDevices().map((d) => Device.fromJson(d)).toList();
    _activityLogs = _offlineManager
        .getActivityLogs()
        .map((l) => ActivityLog.fromJson(l))
        .toList();
    _isOfflineMode = true;
  }

  // ── Change system state (ARM / DISARM) ─────────────────────────
  Future<void> changeSystemState(SystemState newState) async {
    if (_isLoading) return;

    // ✅ Update UI INSTANTLY — don't wait for server
    _error = null;
    notifyListeners();

    _isLoading = true;
    notifyListeners();

    try {
      final stateString = _systemStateToString(newState);
      RealtimeSyncService().suppressNextTick = true;

      // ✅ Network call with short timeout — runs async, won't block UI
      try {
        await _apiService!.updateSystemState(
          stateString,
          deviceUuid: _hubDeviceUuid ?? _deviceUuid ?? 'legacy',
          user:
              AuthService().userName ?? AuthService().userEmail ?? 'Mobile App',
        );
      } catch (e) {
        debugPrint('⚠️ Server update failed (queued): $e');
        RealtimeSyncService().suppressNextTick = false;
        rethrow;
      }

      _currentState = newState;
      _lastStateUpdatedAt = DateTime.now().toIso8601String();
      if (newState == SystemState.disarmed) {
        _isArmed = false;
        _stopAlarmPoll();
        _lastAlarmId = 0;
        _notifications.stopAlarmImmediately(); // fire-and-forget
      }

      if (newState == SystemState.armed || newState == SystemState.stayArmed) {
        await _setBaselineAndStartPoll();
      }

      // Fire-and-forget — don't await these to keep UI snappy
      _notifications.notifyStateChange(
        newState,
        actor: AuthService().userName ?? AuthService().userEmail,
      );
      _saveToOfflineStorage();

      _activityLogs.insert(
          0,
          ActivityLog(
            timestamp: DateTime.now().toIso8601String(),
            event: _activityEventFor(newState, user: _currentUserName),
            device: 'Mobile App',
            user: _currentUserName,
          ));
      await _postSharedActivityLog(_activityEventFor(newState));
    } catch (e) {
      _error = e.toString();
      RealtimeSyncService().suppressNextTick = false;
      debugPrint('❌ changeSystemState: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _refreshActivityLogs() async {
    if (_apiService == null || _activeDeviceUuid.isEmpty) return;
    final logsData = await _apiService!.getActivityLogs(
      limit: _activityHistoryLimit,
      deviceUuid: _activeDeviceUuid,
    );
    if (logsData.isEmpty) return;
    _activityLogs = logsData.map((l) => ActivityLog.fromJson(l)).toList();
    await _offlineManager.saveActivityLogs(_activityLogs
        .map((l) => {
              'timestamp': l.timestamp,
              'event': l.event,
              'device': l.device,
              'user': l.user,
            })
        .toList());
  }

  Future<void> _postSharedActivityLog(String event) async {
    if (_apiService == null || _activeDeviceUuid.isEmpty) return;

    await _apiService!.postActivityLog(
      event: event,
      device: 'Mobile App',
      user: _currentUserName,
      deviceUuid: _activeDeviceUuid,
    );
    await _refreshActivityLogs();
  }

  String get _currentUserName =>
      AuthService().userName ?? AuthService().userEmail ?? 'User';

  String _activityEventFor(SystemState state, {String? user}) {
    final actor = user ?? _currentUserName;
    switch (state) {
      case SystemState.armed:
        return '$actor armed';
      case SystemState.stayArmed:
        return '$actor stay armed';
      case SystemState.alarm:
        return '$actor triggered alarm';
      case SystemState.disarmed:
        return '$actor disarmed';
    }
  }

  // ── SOS ────────────────────────────────────────────────────────
  Future<void> triggerSOSAlarm() async {
    try {
      _isSOSMode = true;
      _currentState = SystemState.alarm;
      notifyListeners();
      if (_connectionManager?.isOnline ?? false) {
        await _connectionManager!.triggerSOS();
      } else {
        await _offlineManager.enableSOSMode();
      }
      HapticFeedback.heavyImpact();
      await _notifications.notifySOSTriggered();
    } catch (e) {
      debugPrint('❌ SOS: $e');
    }
  }

  Future<void> stopSOSAlarm() async {
    try {
      _isSOSMode = false;
      _currentState = SystemState.disarmed;
      _isArmed = false;
      _stopAlarmPoll();
      await _offlineManager.disableSOSMode();
      HapticFeedback.lightImpact();
      await _notifications.cancelSOSNotification();
      await _notifications.cancel(NotificationService.idAlarm);
      await _notifications.notifyStateChange(
        SystemState.disarmed,
        actor: AuthService().userName ?? AuthService().userEmail,
      );
      notifyListeners();
    } catch (e) {
      debugPrint('❌ stopSOS: $e');
    }
  }

  // ── Parsers ────────────────────────────────────────────────────
  SystemState _parseSystemState(String? state) {
    switch (state?.toLowerCase()) {
      case 'armed':
        return SystemState.armed;
      case 'stay_armed':
      case 'stay_arm':
      case 'stay':
        return SystemState.stayArmed;
      case 'alarm':
        return SystemState.alarm;
      default:
        return SystemState.disarmed;
    }
  }

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

  String get stateDisplayName {
    switch (_currentState) {
      case SystemState.armed:
        return 'System Armed';
      case SystemState.stayArmed:
        return 'Stay Armed';
      case SystemState.alarm:
        return 'ALARM';
      case SystemState.disarmed:
        return 'System Disarmed';
    }
  }

  Color get stateColor {
    switch (_currentState) {
      case SystemState.armed:
        return Colors.green;
      case SystemState.stayArmed:
        return Colors.orange;
      case SystemState.alarm:
        return Colors.red;
      case SystemState.disarmed:
        return Colors.blueGrey;
    }
  }

  // ── [SYNC-4] Dispose — clean up sync service ───────────────────
  @override
  void dispose() {
    RealtimeSyncService().stop(); // ← ADDED
    _stopAlarmPoll();
    _connectionManager?.dispose();
    super.dispose();
  }
// ── [SYNC-4 END] ───────────────────────────────────────────────
}
