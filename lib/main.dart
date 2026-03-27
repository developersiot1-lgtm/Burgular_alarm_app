import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'splash_screen.dart';
import 'alarm_system.dart';
import 'api_service.dart';
import 'device_registry_service.dart';
import 'settings_manager.dart';
import 'auth_service.dart';       // ← NEW
import 'polygon_background.dart';
import 'notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // Initialize settings
  final settingsManager = SettingsManager();
  await settingsManager.initialize();

  // Local notifications (alarm alerts)
  await NotificationService.instance.init();

  // ── Load saved auth session ──────────────────────────────────
  // (SplashScreen also calls this, but loading here means
  //  AuthService().isLoggedIn is available app-wide immediately)
  await AuthService().loadSession();

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
        // AuthService is a singleton — expose for convenience
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
      title: 'Alarm Control',
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: const Color(0xFF38bdf8)),
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
      builder: (context, child) => PolygonBackground(child: child ?? Container()),
      home: const SplashScreen(),
    );
  }
}
