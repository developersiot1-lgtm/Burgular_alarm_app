import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const String _channelId = 'alarm_events';

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

  Future<void> showAlarmTriggered({required String title, required String body}) async {
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
    );

    const details = NotificationDetails(android: androidDetails);
    try {
      await _plugin.show(1, title, body, details);
    } catch (e) {
      // ignore: avoid_print
      print('Notification show failed: $e');
    }
  }
}
