import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'alarm_system.dart';
import 'notification_event_deduper.dart';

// ================================================================
// notification_service.dart
//
// FIXES IN THIS FILE:
//
// FIX 1 — Sound not playing in foreground / backgrounded app:
//   Added audioAttributesUsage: AudioAttributesUsage.alarm to the
//   AndroidNotificationDetails for alarm/SOS channels.
//   Without this, Android routes notification sound through the
//   NOTIFICATION audio stream (which Do-Not-Disturb can mute).
//   AudioAttributesUsage.alarm routes through the ALARM stream,
//   which bypasses DnD and plays even on silent mode on many devices.
//   The background service already had this fix — now foreground matches.
//
// FIX 2 — Channel ID mismatch causing silent notifications:
//   Channels are now created explicitly in main.dart.
//   Channel IDs used here MUST exactly match those created in main.dart:
//     alarm/sos   → '{base}_ch_sys'   or '{base}_ch_silent'
//     status etc  → '{base}_ch_sys'   or '{base}_ch_silent'
//   This file already used the correct format — no change needed there.
//
// FIX 3 (pre-existing, kept): _startAlarmLoop uses Duration(seconds:3)
//   A zero-duration periodic timer was flooding the notification manager.
// ================================================================

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  // Single plugin instance — shared with AlarmNotification via getter
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // Public so AlarmNotification can reuse the same instance
  FlutterLocalNotificationsPlugin get plugin => _plugin;

  bool _initialized = false;

  static const String _keySoundEnabled = 'alarm_sound_enabled';
  static const String _keyNotifEnabled = 'notification_enabled';
  static const String _keyAlarmNotification = 'alarm_notification';
  static const String _keyArmDisarmNotification = 'arm_disarm_notification';
  static const String _keyLowBatteryNotification =
      'sensor_low_battery_notification';

  bool _soundEnabled = true;
  bool _notifEnabled = true;

  bool get isNotificationEnabled => _notifEnabled;
  bool get isAlarmSoundEnabled => _soundEnabled;

  Timer? _alarmTimer;
  bool _alarmLoopRunning = false;
  String _loopTitle = '';
  String _loopBody = '';

  static const int idArmed = 1;
  static const int idDisarmed = 2;
  static const int idStayArmed = 3;
  static const int idAlarm = 4;
  static const int idSOS = 5;
  static const int idLowBattery = 6;
  static const int idDeviceOffline = 7;
  static const int idDeviceOnline = 8;

  static final Int64List _vibAlarm =
      Int64List.fromList(<int>[0, 500, 200, 500, 200, 500]);
  static final Int64List _vibSOS = Int64List.fromList(
      <int>[0, 300, 100, 300, 100, 300, 500, 800, 100, 800, 100, 800]);
  static final Int64List _vibStatus =
      Int64List.fromList(<int>[0, 200, 100, 200]);
  static final Int64List _vibBatt = Int64List.fromList(<int>[0, 150, 100, 150]);

  // ── INIT ──────────────────────────────────────────────────────
  Future<void> initialize() async {
    if (_initialized) return;

    // Restore persisted settings BEFORE anything else
    final prefs = await SharedPreferences.getInstance();
    _soundEnabled = prefs.getBool(_keySoundEnabled) ?? true;
    _notifEnabled = prefs.getBool(_keyNotifEnabled) ?? true;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: _onTap,
    );

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();

    // Delete old channels to force recreate with correct sound settings.
    // NOTE: The new channels are created in main.dart before this is called.
    final oldChannels = [
      'alarm',
      'status',
      'battery',
      'device',
      'sos',
      'alarm_ch_silent',
      'alarm_ch_emergency',
      'alarm_app_alarm_v3_emergency',
      'alarm_app_alarm_v3_silent',
      'alarm_app_alarm_v4_emergency',
      'alarm_app_alarm_v4_silent',
      'alarm_app_status_v4_silent',
      'alarm_app_status_v4_sys_default',
      'alarm_emergency',
      'alarm_default',
    ];
    for (final ch in oldChannels) {
      await androidPlugin?.deleteNotificationChannel(ch);
    }

    _initialized = true;
  }

  Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  // ── SETTINGS ──────────────────────────────────────────────────
  Future<void> setSettings({
    required bool alarmSound,
    required bool notification,
  }) async {
    _soundEnabled = alarmSound;
    _notifEnabled = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySoundEnabled, alarmSound);
    await prefs.setBool(_keyNotifEnabled, true);
    await prefs.setBool(_keyAlarmNotification, notification);
  }

  // ── STATE CHANGE NOTIFICATIONS ────────────────────────────────
  Future<void> notifyStateChange(SystemState newState, {String? actor}) async {
    await _ensureInit();
    final prefs = await SharedPreferences.getInstance();
    final alarmNotification = prefs.getBool(_keyAlarmNotification) ?? true;
    final armDisarmNotification =
        prefs.getBool(_keyArmDisarmNotification) ?? true;
    final who = _displayActor(actor);
    final stateKey = _stateKey(newState);

    if (newState == SystemState.disarmed) {
      _stopAlarmLoop();
      try {
        await _plugin.cancel(idAlarm);
        await _plugin.cancel(idSOS);
      } catch (_) {}
      HapticFeedback.lightImpact();
      if (!_notifEnabled || !armDisarmNotification) return;
      if (!await NotificationEventDeduper.claim(stateKey)) return;
      await _post(
        id: idDisarmed,
        chBase: 'status',
        title: '🔓 System Disarmed',
        body: '$who disarmed the system.',
        importance: Importance.high,
        priority: Priority.high,
        vibration: _vibStatus,
        playSound: false,
        color: Colors.grey,
        isAlarmChannel: false,
      );
      return;
    }

    if (!await NotificationEventDeduper.claim(stateKey)) return;

    switch (newState) {
      case SystemState.armed:
        if (!_notifEnabled || !armDisarmNotification) return;
        HapticFeedback.mediumImpact();
        await _post(
          id: idArmed,
          chBase: 'status',
          title: '🔒 System Armed',
          body: '$who armed the system.',
          importance: Importance.high,
          priority: Priority.high,
          vibration: _vibStatus,
          playSound: _soundEnabled,
          color: Colors.green,
          isAlarmChannel: false,
        );
        break;
      case SystemState.stayArmed:
        if (!_notifEnabled || !armDisarmNotification) return;
        HapticFeedback.mediumImpact();
        await _post(
          id: idStayArmed,
          chBase: 'status',
          title: '🏠 Stay Armed',
          body: '$who set stay arm.',
          importance: Importance.high,
          priority: Priority.high,
          vibration: _vibStatus,
          playSound: _soundEnabled,
          color: Colors.orange,
          isAlarmChannel: false,
        );
        break;
      case SystemState.alarm:
        if (!_notifEnabled || !alarmNotification) return;
        HapticFeedback.heavyImpact();
        _startAlarmLoop(
          '🚨 ALARM TRIGGERED!',
          'Security breach — check immediately!',
        );
        break;
      default:
        break;
    }
  }

  String _stateKey(SystemState state) {
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

  String _displayActor(String? actor) {
    final clean = actor?.trim() ?? '';
    if (clean.isEmpty ||
        clean.toLowerCase() == 'api' ||
        clean.toLowerCase() == 'mobile app') {
      return 'Someone';
    }
    return clean;
  }

  // ── ALARM TRIGGERED (with sensor name from DB) ────────────────
  Future<void> notifyAlarmTriggered({
    String? sensorName,
    String? sensorType,
    String? zoneName,
    String? message,
    String? zone,
  }) async {
    await _ensureInit();

    if (!_notifEnabled) {
      HapticFeedback.heavyImpact();
      _startAlarmLoop('🚨 ALARM!', 'Sensor triggered!');
      return;
    }

    final type = sensorType ?? 'door';
    final name = sensorName ?? message ?? 'Sensor';
    final zn = zoneName ?? zone ?? '';

    // Show exact sensor text from DB e.g. "bed - zone 1 OPEN"
    final body = (zn.isNotEmpty && zn != name) ? '$name — $zn' : name;

    _startAlarmLoop(
      '🚨 ${_icon(type)} ${_label(type)} Triggered!',
      body,
      payload: 'sensor:$type:$name',
    );
  }

  Future<void> notifySensorTriggered({
    required String sensorName,
    required String sensorType,
    required String zone,
  }) =>
      notifyAlarmTriggered(
          sensorName: sensorName, sensorType: sensorType, zoneName: zone);

  // ── SOS ───────────────────────────────────────────────────────
  Future<void> notifySOSTriggered() async {
    await _ensureInit();
    HapticFeedback.heavyImpact();
    _startAlarmLoop(
      '🆘 SOS EMERGENCY!',
      'Emergency SOS activated! Contacts notified.',
      notifId: idSOS,
      chBase: 'sos',
    );
  }

  Future<void> cancelSOSNotification() async {
    _stopAlarmLoop();
    try {
      await _plugin.cancel(idSOS);
    } catch (_) {}
  }

  // ── LOW BATTERY ───────────────────────────────────────────────
  Future<void> notifyLowBattery({
    required String deviceName,
    required int batteryLevel,
  }) async {
    await _ensureInit();
    final prefs = await SharedPreferences.getInstance();
    final lowBatteryNotification =
        prefs.getBool(_keyLowBatteryNotification) ?? true;
    if (!_notifEnabled || !lowBatteryNotification) return;
    await _post(
      id: idLowBattery,
      chBase: 'battery',
      title: '🔋 Low Battery — $deviceName',
      body: '$deviceName is at $batteryLevel%. Replace soon.',
      importance: Importance.high,
      priority: Priority.high,
      vibration: _vibBatt,
      playSound: _soundEnabled,
      color: Colors.orange,
      isAlarmChannel: false,
    );
  }

  // ── DEVICE ONLINE / OFFLINE ───────────────────────────────────
  Future<void> notifyDeviceOffline(String n) async {
    await _ensureInit();
    if (!_notifEnabled) return;
    await _post(
      id: idDeviceOffline,
      chBase: 'device',
      title: '📡 Device Offline',
      body: '$n has gone offline.',
      importance: Importance.high,
      priority: Priority.high,
      playSound: _soundEnabled,
      color: Colors.red,
      isAlarmChannel: false,
    );
  }

  Future<void> notifyDeviceOnline(String n) async {
    await _ensureInit();
    if (!_notifEnabled) return;
    try {
      await _plugin.cancel(idDeviceOffline);
    } catch (_) {}
    await _post(
      id: idDeviceOnline,
      chBase: 'device',
      title: '✅ Device Online',
      body: '$n is back online.',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      playSound: false,
      color: Colors.green,
      isAlarmChannel: false,
    );
  }

  // ── CANCEL ────────────────────────────────────────────────────
  Future<void> cancel(int id) async {
    if (id == idAlarm || id == idSOS) _stopAlarmLoop();
    try {
      await _plugin.cancel(id);
    } catch (_) {}
  }

  Future<void> cancelAll() async {
    _stopAlarmLoop();
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }

  Future<void> stopAlarmImmediately() async {
    _stopAlarmLoop();
    try {
      await _plugin.cancel(idAlarm);
    } catch (_) {}
  }

  // ── ALARM LOOP ────────────────────────────────────────────────
  void _startAlarmLoop(
    String title,
    String body, {
    String? payload,
    int notifId = idAlarm,
    String chBase = 'alarm',
  }) {
    _loopTitle = title;
    _loopBody = body;

    // Post first banner immediately
    _postAlarmBanner(
      title: title,
      body: body,
      payload: payload,
      notifId: notifId,
      chBase: chBase,
    );

    if (_alarmLoopRunning) return;
    _alarmLoopRunning = true;

    _alarmTimer?.cancel();

    // 3-second repeat keeps alarm persistent without spamming.
    _alarmTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) {
        if (!_alarmLoopRunning) return;
        if (!_notifEnabled) return;
        _postAlarmBanner(
          title: _loopTitle,
          body: _loopBody,
          payload: payload,
          notifId: notifId,
          chBase: chBase,
        );
      },
    );
  }

  void _stopAlarmLoop() {
    _alarmTimer?.cancel();
    _alarmTimer = null;
    _alarmLoopRunning = false;
  }

  void _postAlarmBanner({
    required String title,
    required String body,
    String? payload,
    int notifId = idAlarm,
    String chBase = 'alarm',
  }) {
    if (!_notifEnabled) return;
    _post(
      id: notifId,
      chBase: chBase,
      title: title,
      body: body,
      importance: Importance.max,
      priority: Priority.max,
      vibration: _vibAlarm,
      playSound: _soundEnabled,
      ongoing: false,
      autoCancel: false,
      payload: payload ?? 'alarm',
      color: Colors.red,
      fullScreen: true,
      // FIX 1: isAlarmChannel=true → uses AudioAttributesUsage.alarm
      // so sound plays through DnD / silent mode
      isAlarmChannel: true,
    );
  }

  // ── CORE POST ─────────────────────────────────────────────────
  Future<void> _post({
    required int id,
    required String chBase,
    required String title,
    required String body,
    required Importance importance,
    required Priority priority,
    Int64List? vibration,
    bool playSound = false,
    bool ongoing = false,
    bool autoCancel = true,
    String? payload,
    Color? color,
    bool fullScreen = false,
    // FIX 1: new flag — alarm/SOS channels need alarm audio attributes
    // so sound bypasses Do-Not-Disturb on Android 8+
    bool isAlarmChannel = false,
  }) async {
    // Encode sound state in channel ID — matches channels created in main.dart
    final String chSuffix = playSound ? 'sys' : 'silent';
    final String channelId = '${chBase}_ch_$chSuffix';

    final androidDetails = AndroidNotificationDetails(
      channelId,
      _channelName(chBase),
      channelDescription: _channelDesc(chBase),
      importance: importance,
      priority: priority,
      ongoing: ongoing,
      autoCancel: autoCancel,
      playSound: playSound,
      // FIX 1: Route alarm/SOS audio through the ALARM stream.
      // The NOTIFICATION stream is blocked by DnD/silent mode.
      // The ALARM stream is not — it plays at full volume.
      // Only set this for alarm/SOS channels; status/battery don't need it.
      audioAttributesUsage: isAlarmChannel
          ? AudioAttributesUsage.alarm
          : AudioAttributesUsage.notification,
      fullScreenIntent: fullScreen,
      category: fullScreen ? AndroidNotificationCategory.alarm : null,
      enableVibration: vibration != null,
      vibrationPattern: vibration,
      color: color,
      icon: '@mipmap/ic_launcher',
      largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
        summaryText: 'Monsow Alarm',
      ),
      visibility: NotificationVisibility.public,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    try {
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: androidDetails,
          iOS: iosDetails,
        ),
        payload: payload,
      );
    } catch (e) {
      debugPrint('⚠️ Notification error: $e');
    }
  }

  String _channelName(String base) {
    switch (base) {
      case 'alarm':
        return 'Security Alarms';
      case 'sos':
        return 'SOS Emergency';
      case 'status':
        return 'Alarm Status';
      case 'battery':
        return 'Battery Alerts';
      case 'device':
        return 'Device Status';
      default:
        return 'Monsow Alarm';
    }
  }

  String _channelDesc(String base) {
    switch (base) {
      case 'alarm':
        return 'Critical sensor trigger alerts';
      case 'sos':
        return 'SOS emergency alerts';
      case 'status':
        return 'Arm and disarm status updates';
      case 'battery':
        return 'Sensor low battery warnings';
      case 'device':
        return 'Device online/offline alerts';
      default:
        return 'Alarm system notifications';
    }
  }

  void _onTap(NotificationResponse r) => debugPrint('🔔 Tapped: ${r.payload}');

  Future<void> _ensureInit() async {
    if (!_initialized) await initialize();
  }

  String _icon(String type) {
    switch (type.toLowerCase()) {
      case 'door':
        return '🚪';
      case 'window':
        return '🪟';
      case 'motion':
        return '👁️';
      case 'remote':
        return '📡';
      case 'camera':
        return '📷';
      default:
        return '⚠️';
    }
  }

  String _label(String type) {
    switch (type.toLowerCase()) {
      case 'door':
        return 'Door Sensor';
      case 'window':
        return 'Window Sensor';
      case 'motion':
        return 'Motion Sensor';
      case 'remote':
        return 'Remote Sensor';
      case 'camera':
        return 'Camera';
      default:
        return 'Sensor';
    }
  }
}
