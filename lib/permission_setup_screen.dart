import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import 'notification_service.dart';
import 'splash_screen.dart';

class PermissionSetupScreen extends StatefulWidget {
  const PermissionSetupScreen({super.key});

  @override
  State<PermissionSetupScreen> createState() => _PermissionSetupScreenState();
}

class _PermissionSetupScreenState extends State<PermissionSetupScreen>
    with WidgetsBindingObserver {
  final NotificationService _notifications = NotificationService();
  bool _checking = true;
  bool _notificationAllowed = false;
  bool _batteryAllowed = false;
  bool _fullScreenAllowed = false;

  bool get _ready =>
      !Platform.isAndroid ||
      (_notificationAllowed && _batteryAllowed && _fullScreenAllowed);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    if (!Platform.isAndroid) {
      setState(() => _checking = false);
      return;
    }

    final androidPlugin = _notifications.plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    final notificationsEnabled =
        await androidPlugin?.areNotificationsEnabled() ?? false;
    final batteryStatus = await Permission.ignoreBatteryOptimizations.status;

    if (!mounted) return;
    setState(() {
      _notificationAllowed = notificationsEnabled;
      _batteryAllowed = batteryStatus.isGranted;
      _fullScreenAllowed = true;
      _checking = false;
    });
  }

  Future<void> _requestRequiredPermissions() async {
    setState(() => _checking = true);

    await _notifications.requestPermission();
    await Permission.ignoreBatteryOptimizations.request();
    await _notifications.plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestFullScreenIntentPermission();

    await _refresh();
  }

  void _continue() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const SplashScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _continue();
      });
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              const Icon(Icons.notifications_active,
                  size: 56, color: Color(0xFF0284C7)),
              const SizedBox(height: 18),
              const Text(
                'Enable Alarm Notifications',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Arm, disarm and alarm trigger alerts need these permissions to work even when the app is closed.',
                style: TextStyle(color: Colors.black54, fontSize: 15),
              ),
              const SizedBox(height: 28),
              _PermissionTile(
                title: 'Notifications',
                subtitle: 'Required for arm/disarm/alarm alerts.',
                done: _notificationAllowed,
              ),
              _PermissionTile(
                title: 'Battery unrestricted',
                subtitle: 'Keeps monitoring alive long term.',
                done: _batteryAllowed,
              ),
              _PermissionTile(
                title: 'Alarm pop-up permission',
                subtitle: 'Allows urgent alarm screen/heads-up alert.',
                done: _fullScreenAllowed,
              ),
              const Spacer(),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFF97316)),
                ),
                child: const Text(
                  'For Redmi/Oppo/Vivo/Realme/OnePlus: also enable Auto Start manually in phone settings.',
                  style: TextStyle(color: Color(0xFF9A3412), fontSize: 13),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _requestRequiredPermissions,
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Allow Required Permissions'),
                ),
              ),
              TextButton(
                onPressed: openAppSettings,
                child: const Text('Open App Settings'),
              ),
              TextButton(
                onPressed: _continue,
                child: const Text('Continue Anyway'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool done;

  const _PermissionTile({
    required this.title,
    required this.subtitle,
    required this.done,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: done ? const Color(0xFFEFFDF5) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: done ? const Color(0xFF22C55E) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: done ? const Color(0xFF16A34A) : Colors.grey,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.black54, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
