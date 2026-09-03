import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_event_deduper.dart';

// ================================================================
// background_alarm_service.dart — Layer 3 (survives app kill/reboot)
//
// ── COMPLETE API FIELD MAP (cross-referenced with index.php) ─────
//
//  ?action=system_state returns:
//    state, updated_by, updated_at, reason, device_uuid,
//    previous_state, id, schedule_active, schedule_name,
//    schedule_desired_state, schedule_window_start/end
//    ⚠️  does NOT have: alarm_active, current_state, state_updated_by,
//                        triggered_sensors
//
//  ?action=get_alarm_status returns:
//    alarm_active (bool), current_state, state_updated_by,
//    state_updated_at, state_reason, triggered_sensors[],
//    resolved_uuids[], checked_at, success
//    ⚠️  does NOT have: state, updated_by
//
// POLLING STRATEGY (THIS FILE):
//   • Always call ?action=system_state for state transitions
//     (per-device scoped, correct field names).
//   • When state is 'alarm', call ?action=get_alarm_status for
//     triggered_sensors detail (sensor name/zone for notification body).
//
// ── FIX HISTORY ──────────────────────────────────────────────────
//
// FIX-A: Background isolate creates ALL channels itself.
//        Background isolates are separate OS processes — they cannot
//        see channels created in the UI isolate (main.dart). Android
//        silently drops notifications to non-existent channels.
//
// FIX-B: Poll uses ?action=system_state (per-device scoped).
//        Old get_alarm_status had no per-device SQL filter.
//
// FIX-C: wasAlarmActive reset when state leaves 'alarm'.
//        Previously it latched true forever → blocked future alarms.
//
// FIX-D: Offline fallback handles both JSON object and plain-string
//        storage formats written by OfflineManager.
//
// FIX-E: BigTextStyleInformation on all notifications.
//
// FIX-F (THIS VERSION): Correct field names from system_state:
//        Read data['state'] (not 'current_state')
//        Read data['updated_by'] (not 'state_updated_by')
//        Infer alarm from rawState == 'alarm' (no 'alarm_active' key)
//
// FIX-G (THIS VERSION): Fetch triggered_sensors from get_alarm_status
//        when alarm is detected, for richer notification body.
//
// Notification IDs:
//   98 = alarm banner (background)
//   97 = foreground service persistent
//   81 = armed  82 = disarmed  83 = stay_armed
// ================================================================

// ── SharedPreferences keys ────────────────────────────────────────
const String _kDeviceUuid = 'connected_device_uuid';
const String _kSoundEnabled = 'alarm_sound_enabled';
const String _kNotifEnabled = 'notification_enabled';
const String _kLegacySoundEnabled = 'alarm_sound';
const String _kLegacyNotifEnabled = 'alarm_notification';
const String _kArmDisarmNotifEnabled = 'arm_disarm_notification';
const String _kAlarmNotifEnabled = 'alarm_notification';
const String _kSystemState = 'system_state';
const String _kLastNotifiedState = 'background_last_notified_state';
const String _kBaseUrl = 'https://monsow.in/alarm/index.php';

// ── Notification IDs ─────────────────────────────────────────────
const int _kNotifIdAlarm = 4;
const int _kNotifIdForeground = 97;
const int _kNotifIdArmed = 1;
const int _kNotifIdDisarmed = 2;
const int _kNotifIdStay = 3;
const int _kNotifIdDeviceOffline = 7;
const int _kNotifIdDeviceOnline = 8;

// ── Channel IDs ───────────────────────────────────────────────────
const String _kChFgService = 'monsow_bg_service';
const String _kChAlarmSound = 'alarm_ch_sys';
const String _kChAlarmSilent = 'alarm_ch_silent';
const String _kChStatusSound = 'status_ch_sys';
const String _kChStatusSilent = 'status_ch_silent';
const String _kChDeviceSound = 'device_ch_sys';
const String _kChDeviceSilent = 'device_ch_silent';

// ================================================================
// HELPERS
// ================================================================
class _BoolRef {
  bool value;
  _BoolRef(this.value);
}

class _StateRef {
  String value;
  _StateRef(this.value);
}

class _NullableBoolRef {
  bool? value;
  _NullableBoolRef(this.value);
}

class _IntRef {
  int value;
  _IntRef(this.value);
}

// ================================================================
// PUBLIC API
// ================================================================

class BackgroundAlarmService {
  static final _service = FlutterBackgroundService();

  static Future<void> initialize() async {
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        isForegroundMode: true,
        autoStart: true,
        autoStartOnBoot: true,
        foregroundServiceNotificationId: _kNotifIdForeground,
        initialNotificationTitle: 'Monsow Alarm Active',
        initialNotificationContent: 'Monitoring for sensor triggers…',
        notificationChannelId: _kChFgService,
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );
    await _service.startService();
  }

  static Future<void> stop() async {
    FlutterBackgroundService().invoke('stopService');
  }

  static Future<void> notifySettingsChanged() async {}
}

// ================================================================
// BACKGROUND ISOLATE ENTRY POINT
// ================================================================

@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await _initPlugin(plugin);

  // FIX-A: Channels must be created in the background isolate.
  // It runs in a separate OS process and cannot inherit channels
  // registered by the UI isolate in main.dart.
  await _createAllChannels(plugin);

  final wasAlarmActive = _BoolRef(false);
  final lastKnownState = _StateRef('');
  final wasOnline = _NullableBoolRef(null);
  final offlineFailCount = _IntRef(0);

  if (service is AndroidServiceInstance) {
    service
        .on('setAsForeground')
        .listen((_) => service.setAsForegroundService());
    service.on('setAsBackground').listen((_) {
      // Keep this as a foreground service so Android is less likely to
      // stop alarm monitoring while the app is not open.
      service.setAsForegroundService();
    });
    await service.setAsForegroundService();
    service.setForegroundNotificationInfo(
      title: 'Monsow Alarm Active',
      content: 'Monitoring sensors…',
    );
  }

  service.on('stopService').listen((_) => service.stopSelf());

  Timer.periodic(const Duration(seconds: 8), (_) async {
    await _pollAndNotify(
      plugin,
      service,
      wasAlarmActive,
      lastKnownState,
      wasOnline,
      offlineFailCount,
    );
  });
  await _pollAndNotify(
    plugin,
    service,
    wasAlarmActive,
    lastKnownState,
    wasOnline,
    offlineFailCount,
  );
}

@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async => true;

// ================================================================
// FIX-A: CREATE CHANNELS IN BACKGROUND ISOLATE
// ================================================================

Future<void> _createAllChannels(FlutterLocalNotificationsPlugin plugin) async {
  final androidPlugin = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  if (androidPlugin == null) return;

  await androidPlugin.createNotificationChannel(
    const AndroidNotificationChannel(
      _kChFgService,
      'Background Service',
      description: 'Keeps the alarm monitor alive in the background',
      importance: Importance.low,
    ),
  );
  await androidPlugin.createNotificationChannel(
    const AndroidNotificationChannel(
      _kChAlarmSound,
      'Security Alarms',
      description: 'Critical sensor trigger alerts — with sound',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ),
  );
  await androidPlugin.createNotificationChannel(
    const AndroidNotificationChannel(
      _kChAlarmSilent,
      'Security Alarms (Silent)',
      description: 'Critical sensor trigger alerts — silent',
      importance: Importance.max,
      playSound: false,
      enableVibration: true,
    ),
  );
  await androidPlugin.createNotificationChannel(
    const AndroidNotificationChannel(
      _kChStatusSound,
      'Alarm Status',
      description: 'Arm and disarm status updates — with sound',
      importance: Importance.high,
      playSound: true,
    ),
  );
  await androidPlugin.createNotificationChannel(
    const AndroidNotificationChannel(
      _kChStatusSilent,
      'Alarm Status (Silent)',
      description: 'Arm and disarm status updates — silent',
      importance: Importance.high,
      playSound: false,
    ),
  );
  await androidPlugin.createNotificationChannel(
    const AndroidNotificationChannel(
      _kChDeviceSound,
      'Device Connection',
      description: 'Device online and offline updates with sound',
      importance: Importance.high,
      playSound: true,
    ),
  );
  await androidPlugin.createNotificationChannel(
    const AndroidNotificationChannel(
      _kChDeviceSilent,
      'Device Connection (Silent)',
      description: 'Device online and offline updates without sound',
      importance: Importance.defaultImportance,
      playSound: false,
    ),
  );
}

// ================================================================
// INIT PLUGIN
// ================================================================

Future<void> _initPlugin(FlutterLocalNotificationsPlugin plugin) async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );
  await plugin.initialize(
    const InitializationSettings(android: androidSettings, iOS: iosSettings),
  );
}

// ================================================================
// POLL + NOTIFY
// ================================================================

Future<void> _pollAndNotify(
  FlutterLocalNotificationsPlugin plugin,
  ServiceInstance service,
  _BoolRef wasAlarmActive,
  _StateRef lastKnownState,
  _NullableBoolRef wasOnline,
  _IntRef offlineFailCount,
) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final deviceUuid = prefs.getString(_kDeviceUuid) ?? '';
  final notifEnabled = prefs.getBool(_kNotifEnabled) ??
      prefs.getBool(_kLegacyNotifEnabled) ??
      true;
  final soundEnabled = prefs.getBool(_kSoundEnabled) ??
      prefs.getBool(_kLegacySoundEnabled) ??
      true;

  if (deviceUuid.isEmpty || !notifEnabled) {
    wasAlarmActive.value = false;
    lastKnownState.value = '';
    wasOnline.value = null;
    offlineFailCount.value = 0;
    return;
  }

  // ── Online path ───────────────────────────────────────────────
  // FIX-B + FIX-F: Use system_state (per-device scoped) and read
  // the correct field names it actually returns.
  //
  //   system_state response key → what we read
  //   'state'      → rawState   (NOT 'current_state')
  //   'updated_by' → actor      (NOT 'state_updated_by')
  //   (no alarm_active field)   → infer from rawState == 'alarm'
  bool onlineOk = false;
  try {
    final res = await http
        .get(
          Uri.parse(
            '$_kBaseUrl?action=system_state&device_uuid=${Uri.encodeComponent(deviceUuid)}',
          ),
        )
        .timeout(const Duration(seconds: 8));

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      // FIX-F: 'state' is the correct key from system_state PHP
      final rawState = (data['state'] ?? '').toString().toLowerCase();

      // FIX-F: system_state has no 'alarm_active'; infer from state value
      final alarmActive = rawState == 'alarm';

      final canonical = _normalise(rawState, alarmActive);
      await prefs.setString(
        _kSystemState,
        jsonEncode(<String, dynamic>{'state': canonical}),
      );

      // Update foreground banner
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'Monsow Alarm',
          content: canonical == 'alarm'
              ? '🚨 ALARM ACTIVE!'
              : canonical == 'armed'
                  ? '🔒 System Armed — monitoring…'
                  : canonical == 'stay_arm'
                      ? '🏠 Stay Armed — monitoring…'
                      : 'Monitoring sensors…',
        );
      }

      // FIX-G: When alarm is detected, fetch triggered_sensors from
      // get_alarm_status (system_state doesn't include sensor detail).
      Map<String, dynamic>? alarmDetail;
      if (canonical == 'alarm') {
        alarmDetail = await _fetchAlarmDetail(deviceUuid);
      }

      // Build serverData merging both responses:
      // - system_state fields for actor/reason
      // - get_alarm_status triggered_sensors for notification body
      final serverData = <String, dynamic>{
        ...data,
        // Normalise actor key so _actorFrom() finds it regardless of source
        'state_updated_by':
            data['updated_by'] ?? data['state_updated_by'] ?? '',
        if (alarmDetail != null) ...alarmDetail,
      };

      await _handleTransition(
        plugin: plugin,
        prefs: prefs,
        newState: canonical,
        lastKnownState: lastKnownState,
        wasAlarmActive: wasAlarmActive,
        soundEnabled: soundEnabled,
        serverData: serverData,
      );
      onlineOk = true;
      offlineFailCount.value = 0;
      await _handleConnectivityChange(
        plugin: plugin,
        wasOnline: wasOnline,
        isOnline: true,
        playSound: false,
      );
    }
  } catch (_) {
    // Server unreachable — fall through to offline path
  }

  // ── Offline fallback ──────────────────────────────────────────
  if (!onlineOk) {
    offlineFailCount.value++;
    if (offlineFailCount.value < 3 && wasOnline.value != false) {
      return;
    }
    await _handleConnectivityChange(
      plugin: plugin,
      wasOnline: wasOnline,
      isOnline: false,
      playSound: soundEnabled,
    );
    await _handleOffline(
      plugin: plugin,
      prefs: prefs,
      lastKnownState: lastKnownState,
      wasAlarmActive: wasAlarmActive,
      soundEnabled: soundEnabled,
    );
  }
}

// ── FIX-G: Fetch alarm sensor detail from get_alarm_status ───────
// Only called when state == 'alarm'. Returns null on any error.
Future<Map<String, dynamic>?> _fetchAlarmDetail(String deviceUuid) async {
  try {
    final res = await http
        .get(
          Uri.parse(
            '$_kBaseUrl?action=get_alarm_status&device_uuid=${Uri.encodeComponent(deviceUuid)}',
          ),
        )
        .timeout(const Duration(seconds: 5));

    if (res.statusCode == 200) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
  } catch (_) {}
  return null;
}

// ── FIX-D: Offline fallback — handles both storage formats ────────
Future<void> _handleOffline({
  required FlutterLocalNotificationsPlugin plugin,
  required SharedPreferences prefs,
  required _StateRef lastKnownState,
  required _BoolRef wasAlarmActive,
  required bool soundEnabled,
}) async {
  try {
    final raw = prefs.getString(_kSystemState);
    if (raw == null || raw.isEmpty) return;

    String stateStr;
    // Try JSON object first: { "state": "armed" }
    // Fall back to plain string: "armed"
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      stateStr = (decoded['state'] ?? '').toString().toLowerCase();
    } catch (_) {
      stateStr = raw.trim().toLowerCase();
    }

    final canonical = _normalise(stateStr, stateStr == 'alarm');
    await _handleTransition(
      plugin: plugin,
      prefs: prefs,
      newState: canonical,
      lastKnownState: lastKnownState,
      wasAlarmActive: wasAlarmActive,
      soundEnabled: soundEnabled,
      serverData: null,
    );
  } catch (_) {}
}

// ── Core transition handler ────────────────────────────────────────
Future<void> _handleConnectivityChange({
  required FlutterLocalNotificationsPlugin plugin,
  required _NullableBoolRef wasOnline,
  required bool isOnline,
  required bool playSound,
}) async {
  if (wasOnline.value == isOnline) return;

  final firstReading = wasOnline.value == null;
  wasOnline.value = isOnline;

  if (isOnline) {
    _cancelIds(plugin, [_kNotifIdDeviceOffline]);
    if (!firstReading) {
      await _postDeviceStatus(
        plugin: plugin,
        id: _kNotifIdDeviceOnline,
        title: 'Device Back Online',
        body: 'Alarm monitoring is connected to the server again.',
        playSound: false,
      );
    }
    return;
  }

  _cancelIds(plugin, [_kNotifIdDeviceOnline]);
  await _postDeviceStatus(
    plugin: plugin,
    id: _kNotifIdDeviceOffline,
    title: 'Device Offline',
    body: 'Using the last saved alarm state until the server reconnects.',
    playSound: playSound,
  );
}

Future<void> _handleTransition({
  required FlutterLocalNotificationsPlugin plugin,
  required SharedPreferences prefs,
  required String newState,
  required _StateRef lastKnownState,
  required _BoolRef wasAlarmActive,
  required bool soundEnabled,
  required Map<String, dynamic>? serverData,
}) async {
  if (newState.isEmpty) return;
  final armDisarmNotifEnabled = prefs.getBool(_kArmDisarmNotifEnabled) ?? true;
  final alarmNotifEnabled = prefs.getBool(_kAlarmNotifEnabled) ?? true;

  // FIX-C: Reset wasAlarmActive whenever NOT in alarm state so the
  // next alarm cycle can fire a new notification.
  if (newState != 'alarm') {
    wasAlarmActive.value = false;
  }

  final previousState = lastKnownState.value.isNotEmpty
      ? lastKnownState.value
      : prefs.getString(_kLastNotifiedState) ?? '';

  if (previousState.isEmpty && newState != 'alarm') {
    lastKnownState.value = newState;
    await prefs.setString(_kLastNotifiedState, newState);
    wasAlarmActive.value = false;
  } else if (newState == previousState) {
    lastKnownState.value = newState;
    return;
  } else {
    lastKnownState.value = newState;
    await prefs.setString(_kLastNotifiedState, newState);
  }

  final actor = _actorFrom(serverData);
  if (!await NotificationEventDeduper.claim(newState)) return;

  switch (newState) {
    case 'armed':
      _cancelIds(plugin, [_kNotifIdAlarm]);
      if (!armDisarmNotifEnabled) break;
      await _postStatus(
        plugin: plugin,
        id: _kNotifIdArmed,
        title: '🔒 System Armed',
        body: '$actor armed the system.',
        playSound: soundEnabled,
      );
      break;

    case 'stay_arm':
      _cancelIds(plugin, [_kNotifIdAlarm]);
      if (!armDisarmNotifEnabled) break;
      await _postStatus(
        plugin: plugin,
        id: _kNotifIdStay,
        title: '🏠 Stay Armed',
        body: '$actor set stay arm.',
        playSound: soundEnabled,
      );
      break;

    case 'disarmed':
      _cancelIds(plugin, [_kNotifIdAlarm, _kNotifIdArmed, _kNotifIdStay]);
      if (!armDisarmNotifEnabled) break;
      await _postStatus(
        plugin: plugin,
        id: _kNotifIdDisarmed,
        title: '🔓 System Disarmed',
        body: '$actor disarmed the system.',
        playSound: false,
      );
      break;

    case 'alarm':
      if (!alarmNotifEnabled) break;
      if (wasAlarmActive.value) return;
      wasAlarmActive.value = true;

      String title = '🚨 ALARM TRIGGERED!';
      String body = 'Sensor triggered — open the app immediately!';

      // FIX-G: triggered_sensors comes from get_alarm_status (merged into serverData)
      if (serverData != null) {
        final sensors =
            (serverData['triggered_sensors'] as List<dynamic>? ?? []);
        if (sensors.isNotEmpty) {
          final first = sensors.first as Map<String, dynamic>;
          final zone = (first['zone'] ?? '').toString();
          final name = (first['name'] ?? '').toString();
          final type = (first['type'] ?? 'sensor').toString();
          final display = zone.isNotEmpty ? zone : name;
          if (display.isNotEmpty) {
            title = '🚨 ALARM! ${_cleanZone(display)}';
            body = '${_typeLabel(type, display)} — open the app immediately!';
          }
        } else {
          // Fallback: use reason field from system_state
          final reason = (serverData['reason'] ?? '').toString();
          if (reason.isNotEmpty) {
            title = '🚨 ALARM! ${_cleanZone(reason)}';
            body =
                '${_typeLabel('sensor', reason)} — open the app immediately!';
          }
        }
      }

      await _postAlarm(plugin, title, body, playSound: soundEnabled);
      break;
  }
}

// ── Normalise ─────────────────────────────────────────────────────
String _normalise(String raw, bool alarmActive) {
  if (alarmActive || raw == 'alarm') return 'alarm';
  if (raw == 'armed' || raw == 'arm') return 'armed';
  if (raw == 'stay' ||
      raw == 'stay_arm' ||
      raw == 'stay_armed' ||
      raw == 'stayarmed' ||
      raw == 'stayarm') return 'stay_arm';
  if (raw == 'disarmed' || raw == 'disarm') return 'disarmed';
  return raw.isEmpty ? '' : 'disarmed';
}

// ── Actor helper ──────────────────────────────────────────────────
String _actorFrom(Map<String, dynamic>? serverData) {
  // Try both key names: system_state uses 'updated_by',
  // get_alarm_status uses 'state_updated_by'.
  // We normalize both into 'state_updated_by' when merging in _pollAndNotify.
  final raw = serverData?['state_updated_by'] ??
      serverData?['updated_by'] ??
      serverData?['actor'];
  final actor = raw?.toString().trim() ?? '';
  if (actor.isEmpty ||
      actor.toLowerCase() == 'api' ||
      actor.toLowerCase() == 'hub') {
    return 'Someone';
  }
  return actor;
}

void _cancelIds(FlutterLocalNotificationsPlugin plugin, List<int> ids) {
  for (final id in ids) {
    plugin.cancel(id).catchError((_) {});
  }
}

// ── Alarm notification ────────────────────────────────────────────
Future<void> _postAlarm(
  FlutterLocalNotificationsPlugin plugin,
  String title,
  String body, {
  bool playSound = true,
}) async {
  final channelId = playSound ? _kChAlarmSound : _kChAlarmSilent;
  final details = AndroidNotificationDetails(
    channelId,
    'Security Alarms',
    channelDescription: 'Critical sensor trigger alerts',
    importance: Importance.max,
    priority: Priority.max,
    playSound: playSound,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    fullScreenIntent: true,
    category: AndroidNotificationCategory.alarm,
    enableVibration: true,
    vibrationPattern: Int64List.fromList(<int>[0, 500, 200, 500, 200, 500]),
    visibility: NotificationVisibility.public,
    ongoing: true,
    autoCancel: false,
    onlyAlertOnce: false,
    styleInformation: BigTextStyleInformation(
      body,
      contentTitle: title,
      summaryText: 'Monsow Alarm',
    ),
  );
  await plugin.show(
    _kNotifIdAlarm,
    title,
    body,
    NotificationDetails(android: details),
  );
}

// ── Status notification ───────────────────────────────────────────
Future<void> _postStatus({
  required FlutterLocalNotificationsPlugin plugin,
  required int id,
  required String title,
  required String body,
  bool playSound = false,
}) async {
  final channelId = playSound ? _kChStatusSound : _kChStatusSilent;
  final details = AndroidNotificationDetails(
    channelId,
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
    onlyAlertOnce: false,
    styleInformation: BigTextStyleInformation(
      body,
      contentTitle: title,
      summaryText: 'Monsow Alarm',
    ),
  );
  await plugin.show(
    id,
    title,
    body,
    NotificationDetails(android: details),
  );
}

// ── Text helpers ──────────────────────────────────────────────────
Future<void> _postDeviceStatus({
  required FlutterLocalNotificationsPlugin plugin,
  required int id,
  required String title,
  required String body,
  bool playSound = false,
}) async {
  final channelId = playSound ? _kChDeviceSound : _kChDeviceSilent;
  final details = AndroidNotificationDetails(
    channelId,
    'Device Connection',
    channelDescription: 'Device online and offline updates',
    importance: Importance.high,
    priority: Priority.high,
    playSound: playSound,
    audioAttributesUsage: AudioAttributesUsage.notification,
    enableVibration: playSound,
    visibility: NotificationVisibility.public,
    autoCancel: true,
    onlyAlertOnce: false,
    styleInformation: BigTextStyleInformation(
      body,
      contentTitle: title,
      summaryText: 'Monsow Alarm',
    ),
  );
  await plugin.show(
    id,
    title,
    body,
    NotificationDetails(android: details),
  );
}

String _cleanZone(String raw) {
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

String _typeLabel(String type, String raw) {
  final t = '${type.toLowerCase()} ${raw.toLowerCase()}';
  if (t.contains('door') || t.contains('open')) return 'Door opened';
  if (t.contains('motion')) return 'Motion detected';
  if (t.contains('remote')) return 'Remote panic triggered';
  if (t.contains('window')) return 'Window opened';
  if (t.contains('camera')) return 'Camera alert';
  return 'Sensor triggered';
}
