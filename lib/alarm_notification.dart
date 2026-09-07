import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_manager.dart';
import 'notification_service.dart';

// ================================================================
// alarm_notification.dart — Background status poller (Layer 2)
//
// FIXED: Now sends notifications for ALL state changes:
//
//   disarmed  → 🔓 System Disarmed  (silent, always)
//   armed     → 🔒 System Armed     (sound follows user setting)
//   stay_arm  → 🏠 Stay Armed       (sound follows user setting)
//   alarm     → 🚨 ALARM TRIGGERED  (sound follows user setting)
//
// FIXED: _lastKnownState tracks every transition, not just alarm.
//   Every state change fires exactly ONE notification.
//
// FIXED: Offline fallback — when the HTTP poll fails (no internet /
//   BLE-only mode), reads the last state that alarm_system.dart
//   saved to SharedPreferences via OfflineManager.saveSystemState().
//   Key: 'system_state', format: {"state":"armed","timestamp":"..."}
//   This makes arm/disarm/stay notifications work even without WiFi.
//
// UNCHANGED: Do NOT call _plugin.initialize() here.
//   NotificationService already owns the singleton plugin.
//   Calling initialize() a second time resets channel registry.
//
// Notification IDs (no overlap with other layers):
//   91 = armed   92 = disarmed   93 = stay_arm   99 = alarm
// ================================================================

class AlarmNotification {
  // Reuse singleton plugin — no double-init
  static FlutterLocalNotificationsPlugin get _plugin =>
      NotificationService().plugin;

  static Timer? _pollTimer;

  // Last normalised state — detects every transition
  static String _lastKnownState = ''; // ''|'armed'|'stay_arm'|'disarmed'|'alarm'
  static bool   _wasAlarmActive = false; // prevents duplicate alarm notifications

  static const int _idArmed    = 91;
  static const int _idDisarmed = 92;
  static const int _idStay     = 93;
  static const int _idAlarm    = 99;

  // ── Public API ────────────────────────────────────────────────
  static Future<void> init() async {
    _startPolling();
  }

  static void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ── Polling ───────────────────────────────────────────────────
  static void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 8),
          (_) => _checkState(),
    );
  }

  static Future<void> _checkState() async {
    final deviceUuid = SettingsManager().connectedDeviceUuid;
    if (deviceUuid.isEmpty) return;

    if (!NotificationService().isNotificationEnabled) {
      _lastKnownState = '';
      _wasAlarmActive = false;
      return;
    }

    // ── Online path ──────────────────────────────────────────────
    bool onlineOk = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt('auth_user_id');
      final uri = Uri.parse('https://monsow.in/alarm/index.php').replace(
        queryParameters: {
          'action': 'get_alarm_status',
          'device_uuid': deviceUuid,
          if (userId != null && userId > 0) 'user_id': userId.toString(),
        },
      );
      final res = await http
          .get(uri)
          .timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        final data        = jsonDecode(res.body) as Map<String, dynamic>;
        final alarmActive = data['alarm_active'] == true;
        final rawState    = (data['current_state'] ?? '').toString().toLowerCase();
        final canonical   = _normalise(rawState, alarmActive);
        await _handleTransition(canonical, serverData: data);
        onlineOk = true;
      }
    } catch (_) {
      // Server unreachable — fall through to offline path
    }

    // ── Offline fallback: read last state saved locally ──────────
    if (!onlineOk) {
      await _checkOfflineState();
    }
  }

  // alarm_system.dart → OfflineManager.saveSystemState() writes:
  //   prefs.setString('system_state', jsonEncode({'state': '...', 'timestamp': '...'}))
  static Future<void> _checkOfflineState() async {
    try {
      final prefs     = await SharedPreferences.getInstance();
      final raw       = prefs.getString('system_state');
      if (raw == null || raw.isEmpty) return;
      final decoded   = jsonDecode(raw) as Map<String, dynamic>;
      final stateStr  = (decoded['state'] ?? '').toString().toLowerCase();
      final canonical = _normalise(stateStr, stateStr == 'alarm');
      await _handleTransition(canonical, serverData: null);
    } catch (_) {
      // Silent
    }
  }

  // ── Normalise to one of: armed / stay_arm / disarmed / alarm / '' ─
  static String _normalise(String raw, bool alarmActive) {
    if (alarmActive || raw == 'alarm')  return 'alarm';
    if (raw == 'armed' || raw == 'arm') return 'armed';
    // Also handles Dart enum .name == 'stayArmed' (lowercased below)
    if (raw == 'stay'      ||
        raw == 'stay_arm'  ||
        raw == 'stay_armed'||
        raw == 'stayarmed' ||
        raw == 'stayarm') return 'stay_arm';
    if (raw == 'disarmed' || raw == 'disarm') return 'disarmed';
    return raw.isEmpty ? '' : 'disarmed';
  }

  // ── Fire notification only when state changes ─────────────────
  static Future<void> _handleTransition(
      String newState, {
        required Map<String, dynamic>? serverData,
      }) async {
    if (newState.isEmpty)            return;
    if (newState == _lastKnownState) return; // no change — skip

    _lastKnownState = newState;
    final playSound = NotificationService().isAlarmSoundEnabled;
    final actor = _actorFrom(serverData);

    switch (newState) {

      case 'armed':
        _wasAlarmActive = false;
        _cancel([_idAlarm]);
        await _postStatus(
          id: _idArmed,
          title: '🔒 System Armed',
          body: '$actor armed the system.',
          playSound: playSound,
        );
        break;

      case 'stay_arm':
        _wasAlarmActive = false;
        _cancel([_idAlarm]);
        await _postStatus(
          id: _idStay,
          title: '🏠 Stay Armed',
          body: '$actor set stay arm.',
          playSound: playSound,
        );
        break;

      case 'disarmed':
        _wasAlarmActive = false;
        _cancel([_idAlarm, _idArmed, _idStay]);
        await _postStatus(
          id: _idDisarmed,
          title: '🔓 System Disarmed',
          body: '$actor disarmed the system.',
          playSound: false, // disarmed is always silent
        );
        break;

      case 'alarm':
        if (_wasAlarmActive) return; // already notified this alarm session
        _wasAlarmActive = true;

        String title = '🚨 ALARM TRIGGERED!';
        String body  = 'Sensor triggered — open the app immediately!';

        if (serverData != null) {
          final sensors =
          (serverData['triggered_sensors'] as List<dynamic>? ?? []);
          if (sensors.isNotEmpty) {
            final first   = sensors.first as Map<String, dynamic>;
            final zone    = (first['zone'] ?? '').toString();
            final name    = (first['name'] ?? '').toString();
            final type    = (first['type'] ?? 'sensor').toString();
            final display = name.isNotEmpty ? name : zone;
            title = '🚨 ALARM! ${_cleanZone(display)}';
            body  = '${_typeLabel(type, display)} — open the app immediately!';
          }
        }

        await _postAlarm(title, body, playSound: playSound);
        break;
    }
  }

  static void _cancel(List<int> ids) {
    for (final id in ids) {
      _plugin.cancel(id).catchError((_) {});
    }
  }

  // ── Alarm notification — max importance, alarm audio stream ──
  static String _actorFrom(Map<String, dynamic>? serverData) {
    final raw = serverData?['state_updated_by'] ??
        serverData?['updated_by'] ??
        serverData?['actor'];
    final actor = raw?.toString().trim() ?? '';
    if (actor.isEmpty || actor.toLowerCase() == 'api') {
      return 'Someone';
    }
    return actor;
  }

  static Future<void> _postAlarm(
      String title,
      String body, {
        bool playSound = true,
      }) async {
    final details = AndroidNotificationDetails(
      'alarm_ch_${playSound ? 'sys' : 'silent'}',
      'Security Alarms',
      channelDescription: 'Critical sensor trigger alerts',
      importance: Importance.max,
      priority: Priority.max,
      playSound: playSound,
      audioAttributesUsage: AudioAttributesUsage.alarm, // bypasses DnD
      fullScreenIntent: true,
      category: AndroidNotificationCategory.alarm,
      enableVibration: true,
      vibrationPattern: Int64List.fromList(<int>[0, 500, 200, 500, 200, 500]),
      visibility: NotificationVisibility.public,
      ongoing: false,
      autoCancel: false,
    );
    await _plugin.show(
      _idAlarm, title, body, NotificationDetails(android: details),
    );
  }

  // ── Status notification — armed / disarmed / stay ─────────────
  static Future<void> _postStatus({
    required int    id,
    required String title,
    required String body,
    bool playSound = false,
  }) async {
    final details = AndroidNotificationDetails(
      'status_ch_${playSound ? 'sys' : 'silent'}',
      'Alarm Status',
      channelDescription: 'Arm and disarm status updates',
      importance: Importance.high,
      priority: Priority.high,
      playSound: playSound,
      audioAttributesUsage: AudioAttributesUsage.notification,
      enableVibration: true,
      vibrationPattern: Int64List.fromList(<int>[0, 200, 100, 200]),
      visibility: NotificationVisibility.public,
      autoCancel: true,
    );
    await _plugin.show(
      id, title, body, NotificationDetails(android: details),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────
  static String _cleanZone(String raw) {
    if (raw.isEmpty) return 'Sensor';
    String s = raw
        .replaceAll(
      RegExp(r'\b(OPEN|CLOSED|MOTION|TRIGGER|ALARM|START|SENSOR)\b',
          caseSensitive: false),
      '',
    )
        .replaceAll(
      RegExp(r'\s*-\s*zone\s*', caseSensitive: false),
      ' Zone ',
    )
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    if (s.isEmpty) return raw;
    return s
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join(' ');
  }

  static String _typeLabel(String type, String raw) {
    final t = '${type.toLowerCase()} ${raw.toLowerCase()}';
    if (t.contains('door') || t.contains('open')) return 'Door opened';
    if (t.contains('motion'))                      return 'Motion detected';
    if (t.contains('remote'))                      return 'Remote panic triggered';
    if (t.contains('window'))                      return 'Window opened';
    if (t.contains('camera'))                      return 'Camera alert';
    return 'Sensor triggered';
  }
}
