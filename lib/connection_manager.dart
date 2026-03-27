import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'b_l_e_offline_controller.dart';

enum ConnectionMode { wifi, bluetooth, offline }

/// Manages connection priority: WiFi → Bluetooth → Offline
class ConnectionManager with ChangeNotifier {
  ConnectionMode _currentMode = ConnectionMode.offline;
  bool _isOnline = false;
  String? _deviceUuid;

  // ✅ FIX: use Timer.periodic — no more recursive Future.delayed memory leak
  Timer? _healthCheckTimer;

  final BLEOfflineController _bleController = BLEOfflineController();

  static const String _baseUrl = 'https://monsow.in/alarm/index.php';

  // Getters
  ConnectionMode get currentMode    => _currentMode;
  bool get isOnline                 => _isOnline;
  bool get isWiFiMode               => _currentMode == ConnectionMode.wifi;
  bool get isBluetoothMode          => _currentMode == ConnectionMode.bluetooth;
  bool get isOffline                => _currentMode == ConnectionMode.offline;

  // ─────────────────────────────────────────────
  // INIT
  // ─────────────────────────────────────────────

  Future<void> initialize(String deviceUuid) async {
    _deviceUuid = deviceUuid;
    print('🔌 ConnectionManager init for: $deviceUuid');

    final wifiOk = await _tryWiFiConnection();
    if (wifiOk) {
      _currentMode = ConnectionMode.wifi;
      _isOnline    = true;
      print('✅ Connected via WiFi');
    } else {
      print('⚠️ WiFi unavailable — trying Bluetooth...');
      final bleOk = await _bleController.connectToDevice(deviceUuid);
      if (bleOk) {
        _currentMode = ConnectionMode.bluetooth;
        _isOnline    = true;
        print('✅ Connected via Bluetooth');
      } else {
        _currentMode = ConnectionMode.offline;
        _isOnline    = false;
        print('❌ Offline mode');
      }
    }

    notifyListeners();
    _startMonitoring();
  }

  // ─────────────────────────────────────────────
  // WIFI CHECK
  // ─────────────────────────────────────────────

  Future<bool> _tryWiFiConnection() async {
    if (_deviceUuid == null) return false;
    try {
      final conn = await Connectivity().checkConnectivity();
      if (conn == ConnectivityResult.none) return false;

      // Verify server reachability (don't depend on google.com being reachable on all networks).
      final res = await http.get(
        Uri.parse('$_baseUrl?action=device_info&device_uuid=$_deviceUuid'),
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        // Adjust keys to whatever your PHP returns
        return data['device_id'] != null || data['exists'] == true;
      }

      return false;
    } catch (_) {
      return false;
    }
  }

  // ─────────────────────────────────────────────
  // MONITORING
  // ─────────────────────────────────────────────

  void _startMonitoring() {
    Connectivity().onConnectivityChanged.listen((result) async {
      if (result != ConnectivityResult.none) {
        final wifiOk = await _tryWiFiConnection();
        if (wifiOk && _currentMode != ConnectionMode.wifi) {
          print('🔄 Switching to WiFi mode');
          if (_bleController.isConnected) await _bleController.disconnect();
          _currentMode = ConnectionMode.wifi;
          _isOnline    = true;
          notifyListeners();
        }
      } else if (_currentMode == ConnectionMode.wifi) {
        print('🔄 WiFi lost — trying Bluetooth fallback');
        final bleOk = await _bleController.connectToDevice(_deviceUuid!);
        _currentMode = bleOk ? ConnectionMode.bluetooth : ConnectionMode.offline;
        _isOnline    = bleOk;
        notifyListeners();
      }
    });

    _startHealthCheck();
  }

  // ✅ FIX: Timer.periodic instead of recursive Future.delayed
  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer =
        Timer.periodic(const Duration(seconds: 60), (_) async {
          if (_currentMode == ConnectionMode.wifi) {
            final wifiOk = await _tryWiFiConnection();
            if (!wifiOk) {
              print('⚠️ Health check: WiFi failed');
              final bleOk =
              await _bleController.connectToDevice(_deviceUuid!);
              _currentMode =
              bleOk ? ConnectionMode.bluetooth : ConnectionMode.offline;
              _isOnline = bleOk;
              notifyListeners();
            }
          }
        });
  }

  // ─────────────────────────────────────────────
  // SEND COMMANDS
  // ─────────────────────────────────────────────

  Future<bool> sendAlarmCommand(String state, {String? user}) async {
    print('📤 Sending alarm command: $state via ${_currentMode.name}');
    if (_currentMode == ConnectionMode.wifi) {
      return _sendViaWiFi(state, user);
    } else if (_currentMode == ConnectionMode.bluetooth) {
      return _sendViaBluetooth(state);
    }
    return false; // offline — caller should queue
  }

  Future<bool> _sendViaWiFi(String state, String? user) async {
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl?action=system_state'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'state': state,
          'user':  user ?? 'Mobile App',
          'device_uuid': _deviceUuid,
        }),
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        print('✅ WiFi command sent');
        return true;
      }
      throw Exception('Bad status: ${res.statusCode}');
    } catch (e) {
      print('❌ WiFi command error: $e — trying Bluetooth fallback');
      final bleOk = await _bleController.connectToDevice(_deviceUuid!);
      if (bleOk) {
        _currentMode = ConnectionMode.bluetooth;
        notifyListeners();
        return _sendViaBluetooth(state);
      }
      return false;
    }
  }

  Future<bool> _sendViaBluetooth(String state) async {
    final ok = await _bleController.sendAlarmState(state);
    print(ok ? '✅ Bluetooth command sent' : '❌ Bluetooth command failed');
    return ok;
  }

  Future<bool> triggerSOS() async {
    print('🚨 TRIGGERING SOS');
    if (_currentMode == ConnectionMode.wifi) {
      try {
        final res = await http.post(
          Uri.parse('$_baseUrl?action=system_state'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'state': 'alarm',
            'user': 'SOS TRIGGER',
            'device_uuid': _deviceUuid,
            'emergency': true,
          }),
        ).timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) return true;
      } catch (_) {}
    }
    if (_bleController.isConnected ||
        await _bleController.connectToDevice(_deviceUuid!)) {
      return _bleController.triggerSOSAlarm();
    }
    return false;
  }

  Future<void> reconnect() async {
    if (_deviceUuid == null) return;
    if (_bleController.isConnected) await _bleController.disconnect();
    final wifiOk = await _tryWiFiConnection();
    if (wifiOk) {
      _currentMode = ConnectionMode.wifi;
      _isOnline    = true;
    } else {
      final bleOk = await _bleController.connectToDevice(_deviceUuid!);
      _currentMode = bleOk ? ConnectionMode.bluetooth : ConnectionMode.offline;
      _isOnline    = bleOk;
    }
    notifyListeners();
  }

  // ─────────────────────────────────────────────
  // STATUS HELPERS
  // ─────────────────────────────────────────────

  String getConnectionStatus() {
    switch (_currentMode) {
      case ConnectionMode.wifi:      return 'Connected via WiFi';
      case ConnectionMode.bluetooth: return 'Connected via Bluetooth';
      case ConnectionMode.offline:   return 'Offline';
    }
  }

  String getConnectionEmoji() {
    switch (_currentMode) {
      case ConnectionMode.wifi:      return '🌐';
      case ConnectionMode.bluetooth: return '📱';
      case ConnectionMode.offline:   return '❌';
    }
  }

  IconData getConnectionIcon() {
    switch (_currentMode) {
      case ConnectionMode.wifi:      return Icons.wifi;
      case ConnectionMode.bluetooth: return Icons.bluetooth_connected;
      case ConnectionMode.offline:   return Icons.cloud_off;
    }
  }

  Color getConnectionColor() {
    switch (_currentMode) {
      case ConnectionMode.wifi:      return Colors.green;
      case ConnectionMode.bluetooth: return Colors.orange;
      case ConnectionMode.offline:   return Colors.red;
    }
  }

  Map<String, dynamic> getStatusInfo() => {
    'mode':         _currentMode.name,
    'online':       _isOnline,
    'status':       getConnectionStatus(),
    'emoji':        getConnectionEmoji(),
    'icon':         getConnectionIcon(),
    'color':        getConnectionColor(),
    'is_wifi':      isWiFiMode,
    'is_bluetooth': isBluetoothMode,
    'is_offline':   isOffline,
  };

  // ─────────────────────────────────────────────
  // DISPOSE — ✅ cancels timer properly
  // ─────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    _healthCheckTimer?.cancel();
    if (_bleController.isConnected) await _bleController.disconnect();
    super.dispose();
  }
}
