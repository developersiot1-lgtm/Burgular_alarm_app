import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'b_l_e_offline_controller.dart';
enum ConnectionMode {
  wifi,       // Primary: Via internet/server
  bluetooth,  // Fallback: Direct BLE
  offline,    // No connection
}
/// Manages connection priority: WiFi primary, Bluetooth fallback
///
///
/// Connection Priority:
/// 1. WiFi (via Internet/Server) - Primary
/// 2. Bluetooth (Direct BLE) - Fallback
/// 3. Offline (Queue actions) - Last resort
class ConnectionManager with ChangeNotifier {
  // Connection modes


  ConnectionMode _currentMode = ConnectionMode.offline;
  bool _isOnline = false;
  String? _deviceUuid;

  final BLEOfflineController _bleController = BLEOfflineController();

  // Getters
  ConnectionMode get currentMode => _currentMode;
  bool get isOnline => _isOnline;
  bool get isWiFiMode => _currentMode == ConnectionMode.wifi;
  bool get isBluetoothMode => _currentMode == ConnectionMode.bluetooth;
  bool get isOffline => _currentMode == ConnectionMode.offline;

  /// Initialize connection manager
  Future<void> initialize(String deviceUuid) async {
    _deviceUuid = deviceUuid;

    print('🔌 Initializing ConnectionManager for device: $deviceUuid');

    // Try WiFi first (primary method)
    bool wifiSuccess = await _tryWiFiConnection();

    if (wifiSuccess) {
      _currentMode = ConnectionMode.wifi;
      _isOnline = true;
      print('✅ Connected via WiFi');
    } else {
      // WiFi failed, try Bluetooth fallback
      print('⚠️ WiFi unavailable, trying Bluetooth...');

      bool bleSuccess = await _bleController.connectToDevice(deviceUuid);

      if (bleSuccess) {
        _currentMode = ConnectionMode.bluetooth;
        _isOnline = true;
        print('✅ Connected via Bluetooth (fallback)');
      } else {
        _currentMode = ConnectionMode.offline;
        _isOnline = false;
        print('❌ No connection available - offline mode');
      }
    }

    notifyListeners();

    // Start monitoring for connection changes
    _startMonitoring();
  }

  /// Try WiFi connection (via server)
  Future<bool> _tryWiFiConnection() async {
    if (_deviceUuid == null) return false;

    try {
      // Check network connectivity
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        print('📡 No network connection');
        return false;
      }

      // Verify actual internet access
      try {
        final result = await InternetAddress.lookup('google.com')
            .timeout(Duration(seconds: 5));

        if (result.isEmpty || result[0].rawAddress.isEmpty) {
          print('📡 Network connected but no internet access');
          return false;
        }
      } catch (_) {
        print('📡 DNS lookup failed - no internet');
        return false;
      }

      // Try to reach server and verify device
      final response = await http.get(
        Uri.parse('https://monsow.in/alarm/index.php?action=device_info&device_uuid=$_deviceUuid'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['id'] != null) {
          // ✅ FIX: Only print when connection mode actually changes, not on every health check
          if (_currentMode != ConnectionMode.wifi) {
            print('✅ WiFi connection verified - device exists on server');
          }
          return true;
        }
      }

      print('⚠️ Server responded but device not found');
      return false;
    } catch (e) {
      print('❌ WiFi connection check failed: $e');
      return false;
    }
  }

  /// Monitor and switch connections automatically
  void _startMonitoring() {
    if (_deviceUuid == null) return;

    // Monitor internet connectivity changes
    Connectivity().onConnectivityChanged.listen((result) async {
      final wasWiFi = _currentMode == ConnectionMode.wifi;

      print('📡 Connectivity changed: $result');

      if (result != ConnectivityResult.none) {
        // Internet might be available, try switching to WiFi
        bool wifiSuccess = await _tryWiFiConnection();

        if (wifiSuccess && !wasWiFi) {
          print('🔄 Switching from ${_currentMode.name} to WiFi mode');

          final oldMode = _currentMode;
          _currentMode = ConnectionMode.wifi;
          _isOnline = true;

          // Disconnect Bluetooth if connected
          if (oldMode == ConnectionMode.bluetooth && _bleController.isConnected) {
            await _bleController.disconnect();
            print('📱 Bluetooth disconnected (WiFi now active)');
          }

          notifyListeners();
        }
      } else {
        // Internet lost, switch to Bluetooth fallback
        if (_currentMode == ConnectionMode.wifi) {
          print('🔄 WiFi lost, switching to Bluetooth fallback');

          bool bleSuccess = await _bleController.connectToDevice(_deviceUuid!);

          if (bleSuccess) {
            _currentMode = ConnectionMode.bluetooth;
            _isOnline = true;
            print('✅ Bluetooth fallback active');
          } else {
            _currentMode = ConnectionMode.offline;
            _isOnline = false;
            print('❌ Bluetooth fallback failed - offline mode');
          }

          notifyListeners();
        }
      }
    });

    // Periodic health check (every 60 seconds)
    _startHealthCheck();
  }

  /// Periodic health check to verify connection
  void _startHealthCheck() {
    Future.delayed(Duration(seconds: 60), () async {
      if (_currentMode == ConnectionMode.wifi) {
        bool wifiOk = await _tryWiFiConnection();

        if (!wifiOk) {
          print('⚠️ Health check: WiFi failed, trying Bluetooth');

          bool bleSuccess = await _bleController.connectToDevice(_deviceUuid!);

          if (bleSuccess) {
            _currentMode = ConnectionMode.bluetooth;
            print('✅ Health check: Switched to Bluetooth');
          } else {
            _currentMode = ConnectionMode.offline;
            _isOnline = false;
            print('❌ Health check: Now offline');
          }

          notifyListeners();
        }
      }

      // Schedule next health check
      _startHealthCheck();
    });
  }

  /// Send alarm command (automatically uses correct connection)
  Future<bool> sendAlarmCommand(String state, {String? user}) async {
    print('📤 Sending alarm command: $state via ${_currentMode.name}');

    if (_currentMode == ConnectionMode.wifi) {
      // Send via WiFi (server API)
      return await _sendViaWiFi(state, user);
    } else if (_currentMode == ConnectionMode.bluetooth) {
      // Send via Bluetooth directly
      return await _sendViaBluetooth(state);
    } else {
      print('❌ No connection available - command queued for later');
      // Queue for later (handled by offline_manager)
      return false;
    }
  }

  /// Send via WiFi (through server)
  Future<bool> _sendViaWiFi(String state, String? user) async {
    try {
      final response = await http.post(
        Uri.parse('https://monsow.in/alarm/index.php?action=system_state'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'state': state,
          'user': user ?? 'Mobile App',
          'device_uuid': _deviceUuid,
        }),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        print('✅ WiFi command sent successfully');
        return true;
      } else {
        print('❌ WiFi command failed: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('❌ WiFi command error: $e');

      // WiFi failed, try switching to Bluetooth
      print('🔄 Attempting Bluetooth fallback...');
      bool bleSuccess = await _bleController.connectToDevice(_deviceUuid!);

      if (bleSuccess) {
        _currentMode = ConnectionMode.bluetooth;
        notifyListeners();
        return await _sendViaBluetooth(state);
      }

      return false;
    }
  }

  /// Send via Bluetooth (direct to device)
  Future<bool> _sendViaBluetooth(String state) async {
    try {
      bool success = await _bleController.sendAlarmState(state);

      if (success) {
        print('✅ Bluetooth command sent successfully');
      } else {
        print('❌ Bluetooth command failed');
      }

      return success;
    } catch (e) {
      print('❌ Bluetooth command error: $e');
      return false;
    }
  }

  /// Trigger SOS alarm (tries both connections)
  Future<bool> triggerSOS() async {
    print('🚨 TRIGGERING SOS ALARM');

    // Try WiFi first
    if (_currentMode == ConnectionMode.wifi) {
      try {
        final response = await http.post(
          Uri.parse('https://monsow.in/alarm/index.php?action=system_state'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'state': 'alarm',
            'user': 'SOS TRIGGER',
            'device_uuid': _deviceUuid,
            'emergency': true,
          }),
        ).timeout(Duration(seconds: 5));

        if (response.statusCode == 200) {
          print('✅ SOS sent via WiFi');
          return true;
        }
      } catch (e) {
        print('⚠️ WiFi SOS failed, trying Bluetooth: $e');
      }
    }

    // Fallback to Bluetooth
    if (_bleController.isConnected || await _bleController.connectToDevice(_deviceUuid!)) {
      bool success = await _bleController.triggerSOSAlarm();

      if (success) {
        print('✅ SOS sent via Bluetooth');
        return true;
      }
    }

    print('❌ SOS failed on all connections');
    return false;
  }

  /// Force reconnection
  Future<void> reconnect() async {
    if (_deviceUuid == null) return;

    print('🔄 Force reconnect requested');

    // Disconnect everything
    if (_bleController.isConnected) {
      await _bleController.disconnect();
    }

    // Try WiFi first
    bool wifiSuccess = await _tryWiFiConnection();

    if (wifiSuccess) {
      _currentMode = ConnectionMode.wifi;
      _isOnline = true;
      print('✅ Reconnected via WiFi');
    } else {
      // Try Bluetooth
      bool bleSuccess = await _bleController.connectToDevice(_deviceUuid!);

      if (bleSuccess) {
        _currentMode = ConnectionMode.bluetooth;
        _isOnline = true;
        print('✅ Reconnected via Bluetooth');
      } else {
        _currentMode = ConnectionMode.offline;
        _isOnline = false;
        print('❌ Reconnection failed - offline');
      }
    }

    notifyListeners();
  }

  /// Get connection status text
  String getConnectionStatus() {
    switch (_currentMode) {
      case ConnectionMode.wifi:
        return 'Connected via WiFi';
      case ConnectionMode.bluetooth:
        return 'Connected via Bluetooth';
      case ConnectionMode.offline:
        return 'Offline';
    }
  }

  /// Get connection status emoji
  String getConnectionEmoji() {
    switch (_currentMode) {
      case ConnectionMode.wifi:
        return '🌐';
      case ConnectionMode.bluetooth:
        return '📱';
      case ConnectionMode.offline:
        return '❌';
    }
  }

  /// Get connection icon
  IconData getConnectionIcon() {
    switch (_currentMode) {
      case ConnectionMode.wifi:
        return Icons.wifi;
      case ConnectionMode.bluetooth:
        return Icons.bluetooth_connected;
      case ConnectionMode.offline:
        return Icons.cloud_off;
    }
  }

  /// Get connection color
  Color getConnectionColor() {
    switch (_currentMode) {
      case ConnectionMode.wifi:
        return Colors.green;
      case ConnectionMode.bluetooth:
        return Colors.orange;
      case ConnectionMode.offline:
        return Colors.red;
    }
  }

  /// Get detailed status for UI
  Map<String, dynamic> getStatusInfo() {
    return {
      'mode': _currentMode.name,
      'online': _isOnline,
      'status': getConnectionStatus(),
      'emoji': getConnectionEmoji(),
      'icon': getConnectionIcon(),
      'color': getConnectionColor(),
      'is_wifi': isWiFiMode,
      'is_bluetooth': isBluetoothMode,
      'is_offline': isOffline,
    };
  }

  /// Cleanup
  Future<void> dispose() async {
    if (_bleController.isConnected) {
      await _bleController.disconnect();
    }
    super.dispose();
  }
}