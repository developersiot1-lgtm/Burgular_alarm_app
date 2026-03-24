import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'splash_screen.dart';
import 'alarm_system.dart';
import 'api_service.dart';
import 'device_registry_service.dart';
import 'settings_manager.dart';
import 'polygon_background.dart'; // ADD THIS IMPORT

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set status bar style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // Initialize settings manager
  final settingsManager = SettingsManager();
  await settingsManager.initialize();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AlarmSystemProvider(),
        ),
        Provider<ApiService>(
          create: (_) => ApiService(),
        ),
        Provider<DeviceRegistryService>(
          create: (_) => DeviceRegistryService(
            baseUrl: 'https://monsow.in/alarm/index.php',
          ),
        ),
        Provider<SettingsManager>.value(
          value: settingsManager,
        ),
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
        scaffoldBackgroundColor: Colors.transparent, // CHANGED: Was Color(0xFF1E1E1E)
        brightness: Brightness.dark,

        // Modern theme customization
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
            backgroundColor: const Color(0xFF38bdf8), // Changed to match primary
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

        // Additional theme for cards
        cardColor: Colors.black.withOpacity(0.3),
      ),

      // THIS IS THE KEY - Wraps entire app with background
      builder: (context, child) {
        return PolygonBackground(
          child: child ?? Container(),
        );
      },

      home: SplashScreen(), // Start with splash screen
    );
  }
}
