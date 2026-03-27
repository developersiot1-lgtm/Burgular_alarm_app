import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // Bump channel id so Android will create a fresh channel with our latest settings.
  // (Existing channels keep their sound/importance until user changes them manually.)
  static const String _channelId = 'alarm_events_v2';

  Timer? _alarmToneTimer;
  DateTime? _alarmToneEndsAt;

  Future<void> init() async {
    if (_initialized) return;

    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await _plugin.initialize(initSettings);

      // Android 13+ runtime permission.
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
    } catch (e) {
      // Never allow notification setup failures to break arm/disarm UI.
      // (Some devices/ROMs throw PlatformException from the plugin.)
      // The app will continue without system notifications.
      // ignore: avoid_print
      print('Notification init failed: $e');
      return;
    }

    _initialized = true;
  }

  void startAlarmToneLoop({Duration duration = const Duration(minutes: 5)}) {
    // Repeated short alert beep (no bundled audio file needed).
    // This is best-effort; devices/ROMs may still mute based on user settings.
    _alarmToneTimer?.cancel();
    _alarmToneEndsAt = DateTime.now().add(duration);
    _alarmToneTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      final endsAt = _alarmToneEndsAt;
      if (endsAt == null || DateTime.now().isAfter(endsAt)) {
        t.cancel();
        return;
      }
      try {
        SystemSound.play(SystemSoundType.alert);
        HapticFeedback.heavyImpact();
      } catch (_) {
        // Ignore: tone loop is best-effort.
      }
    });
  }

  void stopAlarmToneLoop() {
    _alarmToneTimer?.cancel();
    _alarmToneTimer = null;
    _alarmToneEndsAt = null;
  }

  Future<void> showAlarmTriggered({
    required String title,
    required String body,
    bool startAlarmTone = false,
  }) async {
    if (!_initialized) {
      await init();
    }
    if (!_initialized) return;

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      'Alarm Events',
      channelDescription: 'Notifications when sensors trigger the alarm',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      category: AndroidNotificationCategory.alarm,
    );

    const details = NotificationDetails(android: androidDetails);
    try {
      await _plugin.show(1, title, body, details);
      if (startAlarmTone) {
        startAlarmToneLoop();
      }
    } catch (e) {
      // ignore: avoid_print
      print('Notification show failed: $e');
    }
  }
}
