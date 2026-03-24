import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Handles direct BLE communication for offline alarm control
class BLEOfflineController with ChangeNotifier {
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;
  BluetoothCharacteristic? _notifyCharacteristic;
  bool _isConnected = false;

  // ✅ Connection state listener subscription
  StreamSubscription<BluetoothConnectionState>? _connectionStateSub;

  // BLE Service UUIDs
  static const String SERVICE_UUID    = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
  static const String WRITE_CHAR_UUID = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
  static const String NOTIFY_CHAR_UUID = 'beb5483e-36e1-4688-b7f5-ea07361b26a9';

  bool get isConnected => _isConnected;
  BluetoothDevice? get connectedDevice => _connectedDevice;

  /// Connect to alarm device via BLE
  Future<bool> connectToDevice(String deviceUuid) async {
    try {
      print('🔵 Searching for device: $deviceUuid');

      // ✅ FIX: Use Set to avoid duplicate devices from scan
      final seen = <String>{};
      BluetoothDevice? foundDevice;

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

      final subscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final id = result.device.remoteId.str;
          if (id == deviceUuid && !seen.contains(id)) {
            seen.add(id);
            foundDevice = result.device;
          }
        }
      });

      await Future.delayed(const Duration(seconds: 10));
      await FlutterBluePlus.stopScan();
      await subscription.cancel();

      if (foundDevice == null) {
        print('❌ Device not found');
        return false;
      }

      _connectedDevice = foundDevice;

      // Connect
      await _connectedDevice!.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      // ✅ FIX: Wait for connection to be confirmed stable before discovering services
      await _connectedDevice!.connectionState
          .where((s) => s == BluetoothConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 10));

      print('✅ Connected to device — discovering services...');

      // Discover services
      final services = await _connectedDevice!.discoverServices();

      // ✅ FIX: Look for custom UUIDs first, then fall back to any writable char
      _writeCharacteristic = null;
      _notifyCharacteristic = null;

      for (final service in services) {
        final svcUuid = service.uuid.toString().toLowerCase();

        for (final char in service.characteristics) {
          final charUuid = char.uuid.toString().toLowerCase();

          // Prefer the custom write char
          if (svcUuid == SERVICE_UUID && charUuid == WRITE_CHAR_UUID) {
            _writeCharacteristic = char;
            print('✅ Found custom WRITE characteristic');
          }

          // Prefer the custom notify char
          if (svcUuid == SERVICE_UUID && charUuid == NOTIFY_CHAR_UUID) {
            _notifyCharacteristic = char;
            print('✅ Found custom NOTIFY characteristic');
          }
        }
      }

      // Fallback: any writable non-system char
      if (_writeCharacteristic == null) {
        print('⚠️ Custom char not found — searching fallback...');
        for (final service in services) {
          for (final char in service.characteristics) {
            final uuid = char.uuid.toString().toLowerCase();
            if (uuid.startsWith('00002a') || uuid == '2b29') continue;
            if (char.properties.write || char.properties.writeWithoutResponse) {
              _writeCharacteristic = char;
              print('✅ Fallback WRITE characteristic: ${char.uuid}');
              break;
            }
          }
          if (_writeCharacteristic != null) break;
        }
      }

      if (_writeCharacteristic == null) {
        print('❌ No writable characteristic found');
        await _connectedDevice!.disconnect();
        return false;
      }

      // Enable notifications if available
      if (_notifyCharacteristic != null) {
        await _notifyCharacteristic!.setNotifyValue(true);
        _notifyCharacteristic!.lastValueStream.listen(_handleDeviceResponse);
        print('✅ Notifications enabled');
      }

      // ✅ FIX: Listen for disconnection so state stays accurate
      await _connectionStateSub?.cancel();
      _connectionStateSub = _connectedDevice!.connectionState.listen((state) {
        final connected = state == BluetoothConnectionState.connected;
        if (_isConnected != connected) {
          _isConnected = connected;
          notifyListeners();
          print(connected ? '✅ BLE reconnected' : '🔴 BLE disconnected');
        }
      });

      _isConnected = true;
      notifyListeners();

      print('✅ BLE setup complete');
      return true;
    } catch (e) {
      print('❌ BLE connection error: $e');
      _isConnected = false;
      notifyListeners();
      return false;
    }
  }

  /// Disconnect from device
  Future<void> disconnect() async {
    await _connectionStateSub?.cancel();
    _connectionStateSub = null;

    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.disconnect();
      } catch (_) {}
      _connectedDevice = null;
      _writeCharacteristic = null;
      _notifyCharacteristic = null;
      _isConnected = false;
      notifyListeners();
      print('🔴 Disconnected from device');
    }
  }

  /// Send alarm state change via BLE (works offline)
  Future<bool> sendAlarmState(String state) async {
    if (!_isConnected || _writeCharacteristic == null) {
      print('❌ Not connected to device');
      return false;
    }

    try {
      final command = {
        'cmd': 'alarm_state',
        'state': state,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      await _sendData(utf8.encode(jsonEncode(command)));
      print('✅ Alarm state sent via BLE: $state');
      return true;
    } catch (e) {
      print('❌ Failed to send alarm state: $e');
      return false;
    }
  }

  /// Trigger SOS alarm (works offline)
  Future<bool> triggerSOSAlarm() async {
    if (!_isConnected || _writeCharacteristic == null) {
      print('❌ Not connected to device');
      return false;
    }

    try {
      final command = {
        'cmd': 'sos_alarm',
        'trigger': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      await _sendData(utf8.encode(jsonEncode(command)));
      print('🚨 SOS ALARM TRIGGERED VIA BLE');
      return true;
    } catch (e) {
      print('❌ Failed to trigger SOS: $e');
      return false;
    }
  }

  /// Stop SOS alarm
  Future<bool> stopSOSAlarm() async {
    if (!_isConnected || _writeCharacteristic == null) {
      print('❌ Not connected to device');
      return false;
    }

    try {
      final command = {
        'cmd': 'sos_alarm',
        'trigger': false,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      await _sendData(utf8.encode(jsonEncode(command)));
      print('✅ SOS alarm stopped via BLE');
      return true;
    } catch (e) {
      print('❌ Failed to stop SOS: $e');
      return false;
    }
  }

  /// Send voice recording data to device
  Future<bool> sendVoiceRecording(Uint8List voiceData) async {
    if (!_isConnected || _writeCharacteristic == null) {
      print('❌ Not connected to device');
      return false;
    }

    try {
      print('📤 Sending voice data (${voiceData.length} bytes)...');

      // Send header first
      final header = {
        'cmd': 'voice_data',
        'size': voiceData.length,
        'sample_rate': 8000,
      };
      await _sendData(utf8.encode(jsonEncode(header)));
      await Future.delayed(const Duration(milliseconds: 200));

      // ✅ FIX: Use _sendData for consistent MTU-aware chunking
      await _sendData(voiceData);

      print('✅ Voice data sent successfully');
      return true;
    } catch (e) {
      print('❌ Failed to send voice data: $e');
      return false;
    }
  }

  /// Request device status
  Future<void> requestDeviceStatus() async {
    if (!_isConnected || _writeCharacteristic == null) return;

    try {
      final command = {
        'cmd': 'get_status',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      await _sendData(utf8.encode(jsonEncode(command)));
    } catch (e) {
      print('❌ Failed to get device status: $e');
    }
  }

  /// ✅ FIX: MTU-aware chunked send — reads actual negotiated MTU
  Future<void> _sendData(List<int> data) async {
    if (_writeCharacteristic == null) {
      throw Exception('No write characteristic available');
    }

    // Get the negotiated MTU; subtract 3 bytes for ATT overhead
    int mtu = 23; // BLE default minimum
    try {
      if (_connectedDevice != null) {
        mtu = await _connectedDevice!.mtu.first;
      }
    } catch (_) {}

    final chunkSize = (mtu - 3).clamp(20, 512);
    final totalChunks = (data.length / chunkSize).ceil();

    print('📦 Sending ${data.length} bytes in $totalChunks chunks (MTU=$mtu, chunk=$chunkSize)');

    for (int i = 0; i < data.length; i += chunkSize) {
      final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
      final chunk = data.sublist(i, end);

      await _writeCharacteristic!.write(
        chunk,
        // ✅ Prefer write-with-response for reliability; only use without-response
        // if the characteristic doesn't support write-with-response
        withoutResponse: !_writeCharacteristic!.properties.write &&
            _writeCharacteristic!.properties.writeWithoutResponse,
      );

      // Small delay between chunks to avoid buffer overflow on ESP32
      await Future.delayed(const Duration(milliseconds: 30));
    }
  }

  /// Handle responses from device
  void _handleDeviceResponse(List<int> value) {
    if (value.isEmpty) return;

    try {
      final data = utf8.decode(value);
      final response = jsonDecode(data) as Map<String, dynamic>;

      print('📥 Device response: $response');

      switch (response['type']) {
        case 'status':
          print('📊 Device status: ${response['data']}');
          break;
        case 'ack':
          print('✅ Command acknowledged');
          break;
        case 'error':
          print('❌ Device error: ${response['message']}');
          break;
        case 'alarm_triggered':
          print('🚨 Alarm triggered on device');
          break;
      }

      notifyListeners();
    } catch (e) {
      // Device may send raw bytes that aren't JSON — ignore parse errors
      print('⚠️ Could not parse device response (raw bytes): $e');
    }
  }

  /// Check if device is in range
  Future<bool> isDeviceInRange(String deviceUuid) async {
    try {
      bool found = false;

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

      final subscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          if (result.device.remoteId.str == deviceUuid) {
            found = true;
          }
        }
      });

      await Future.delayed(const Duration(seconds: 5));
      await FlutterBluePlus.stopScan();
      await subscription.cancel();

      return found;
    } catch (e) {
      print('❌ Range check error: $e');
      return false;
    }
  }

  @override
  void dispose() {
    _connectionStateSub?.cancel();
    super.dispose();
  }
}