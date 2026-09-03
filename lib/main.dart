import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'splash_screen.dart';
import 'alarm_system.dart';
import 'api_service.dart';
import 'device_registry_service.dart';
import 'settings_manager.dart';
import 'auth_service.dart';
import 'notification_service.dart';
import 'background_alarm_service.dart';
import 'permission_setup_screen.dart';

// ================================================================
// main.dart — THREE-LAYER NOTIFICATION STRATEGY
//
// LAYER 1 — NotificationService (foreground, app open)
// LAYER 2 — AlarmNotification   (background, app in memory)
// LAYER 3 — BackgroundAlarmService (killed / rebooted)
//
// FIX: All notification channels must be EXPLICITLY CREATED before
// any layer tries to post to them. Android API 26+ silently drops
// or mutes notifications posted to channels that don't exist yet.
//
// CHANNEL CREATION ORDER (critical):
//  1. 'monsow_bg_service'   — foreground service persistent banner (low importance)
//  2. 'alarm_ch_sys'        — alarm with system default sound (max importance)
//  3. 'alarm_ch_silent'     — alarm silent (max importance, no sound)
//  4. 'status_ch_sys'       — arm/disarm status with sound
//  5. 'status_ch_silent'    — arm/disarm status silent
//  6. 'sos_ch_sys'          — SOS with sound
//  7. 'sos_ch_silent'       — SOS silent
//  8. 'battery_ch_sys'      — low battery with sound
//  9. 'battery_ch_silent'   — low battery silent
// 10. 'device_ch_sys'       — device online/offline with sound
// 11. 'device_ch_silent'    — device online/offline silent
//
// WHY SEPARATE sys/silent CHANNELS:
//   Android caches the sound setting per-channel at creation time.
//   You cannot change a channel's sound after creation without
//   deleting and recreating it. Using separate channel IDs for
//   sound-on vs sound-off is the only reliable approach.
// ================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // 1. Settings
  final settingsManager = SettingsManager();
  await settingsManager.initialize();

  // 2. Auth
  await AuthService().loadSession();

  // 3. Init notification plugin ONCE (no double-init)
  final notificationService = NotificationService();
  await notificationService.initialize();
  await notificationService.setSettings(
    alarmSound: settingsManager.alarmSound,
    notification: settingsManager.alarmNotification,
  );

  final androidPlugin = notificationService.plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  // ── 4. CREATE ALL CHANNELS BEFORE STARTING ANY SERVICE ────────
  //
  // CRITICAL: Every channel that any layer (foreground, background,
  // or killed-app service) will post to MUST be created here.
  // If a channel doesn't exist when a notification is posted,
  // Android silently drops or mutes it on API 26+.

  // Foreground service persistent banner (low importance = no sound)
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'monsow_bg_service',
      'Background Service',
      description: 'Keeps the alarm monitor alive in the background',
      importance: Importance.low,
    ),
  );

  // Alarm channels — MUST use max importance + alarm audio attributes
  // for sound to play through Do-Not-Disturb on Android 8+
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'alarm_ch_sys',
      'Security Alarms',
      description: 'Critical sensor trigger alerts — with sound',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      // null sound = Android system default alarm sound
    ),
  );
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'alarm_ch_silent',
      'Security Alarms (Silent)',
      description: 'Critical sensor trigger alerts — silent',
      importance: Importance.max,
      playSound: false,
      enableVibration: true,
    ),
  );

  // SOS channels
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'sos_ch_sys',
      'SOS Emergency',
      description: 'SOS emergency alerts — with sound',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ),
  );
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'sos_ch_silent',
      'SOS Emergency (Silent)',
      description: 'SOS emergency alerts — silent',
      importance: Importance.max,
      playSound: false,
      enableVibration: true,
    ),
  );

  // Status channels (armed / disarmed)
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'status_ch_sys',
      'Alarm Status',
      description: 'Arm and disarm status updates — with sound',
      importance: Importance.high,
      playSound: true,
    ),
  );
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'status_ch_silent',
      'Alarm Status (Silent)',
      description: 'Arm and disarm status updates — silent',
      importance: Importance.high,
      playSound: false,
    ),
  );

  // Battery channels
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'battery_ch_sys',
      'Battery Alerts',
      description: 'Sensor low battery warnings — with sound',
      importance: Importance.high,
      playSound: true,
    ),
  );
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'battery_ch_silent',
      'Battery Alerts (Silent)',
      description: 'Sensor low battery warnings — silent',
      importance: Importance.high,
      playSound: false,
    ),
  );

  // Device online/offline channels
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'device_ch_sys',
      'Device Status',
      description: 'Device online/offline alerts — with sound',
      importance: Importance.high,
      playSound: true,
    ),
  );
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'device_ch_silent',
      'Device Status (Silent)',
      description: 'Device online/offline alerts — silent',
      importance: Importance.high,
      playSound: false,
    ),
  );

  // ── 5. Runtime permissions (Android 13+) ──────────────────────
  await notificationService.requestPermission();
  await androidPlugin?.requestFullScreenIntentPermission();
  await Permission.ignoreBatteryOptimizations.request();
  //await androidPlugin?.requestExactAlarmsPermission();

  // ── 6. Layer 2: in-process background poller ──────────────────
  //    (survives backgrounding, not process kill)
  // BackgroundAlarmService is the single background state poller.
  // Running AlarmNotification here as well caused duplicate banners.

  // ── 7. Layer 3: Foreground Service ────────────────────────────
  //    Channels already created above → will NOT crash.
  //    Called exactly ONCE (removed former duplicate call).
  await BackgroundAlarmService.initialize();

  // ── 8. Launch app ─────────────────────────────────────────────
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AlarmSystemProvider()),
        Provider<ApiService>(create: (_) => ApiService()),
        Provider<DeviceRegistryService>(
          create: (_) => DeviceRegistryService(
            baseUrl: 'https://monsow.in/alarm/index.php',
          ),
        ),
        Provider<SettingsManager>.value(value: settingsManager),
        Provider<AuthService>.value(value: AuthService()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monsow Alarm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        primaryColor: const Color(0xFF38bdf8),
        scaffoldBackgroundColor: Colors.transparent,
        brightness: Brightness.dark,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          iconTheme: IconThemeData(color: Colors.white),
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF38bdf8),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF38bdf8),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withOpacity(0.05),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          hintStyle: const TextStyle(color: Colors.white38),
        ),
        cardColor: Colors.black.withOpacity(0.3),
      ),
      builder: (context, child) {
        return Container(
          decoration: const BoxDecoration(color: Colors.white),
          child: child,
        );
      },
      home: const PermissionSetupScreen(),
    );
  }
}
