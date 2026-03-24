import 'dart:async';
import 'dart:convert';
import 'package:alarm/favourite_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:wifi_iot/wifi_iot.dart';
import 'package:provider/provider.dart';
import 'auth_service.dart';
import 'splash_screen.dart';
import 'api_service.dart';
import 'settings_manager.dart';
import 'device_registry_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// STEP 1 – Bluetooth Device Picker
// ─────────────────────────────────────────────────────────────────────────────
class BluetoothDevicePickerScreen extends StatefulWidget {
  final String scannedQRCode;

  const BluetoothDevicePickerScreen({Key? key, required this.scannedQRCode})
      : super(key: key);

  @override
  _BluetoothDevicePickerScreenState createState() =>
      _BluetoothDevicePickerScreenState();
}

class _BluetoothDevicePickerScreenState
    extends State<BluetoothDevicePickerScreen> {
  final Map<String, ScanResult> _resultsMap = {};
  bool _isScanning = false;
  bool _isConnecting = false;
  BluetoothDevice? _connectedDevice;

  StreamSubscription<List<ScanResult>>? _scanSub;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<bool> _requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    final denied = statuses.values.any((s) => !s.isGranted);
    if (denied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bluetooth & Location permissions are required.'),
          backgroundColor: Colors.red,
        ),
      );
    }
    return !denied;
  }

  Future<void> _startScan() async {
    if (_isScanning) return;
    if (!await _requestPermissions()) return;

    setState(() {
      _isScanning = true;
      _resultsMap.clear();
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 20),
        androidScanMode: AndroidScanMode.lowLatency,
      );

      await _scanSub?.cancel();

      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) return;
        setState(() {
          for (final r in results) {
            _resultsMap[r.device.remoteId.str] = r;
          }
        });
      });

      Future.delayed(const Duration(seconds: 20), () async {
        if (!mounted) return;
        await FlutterBluePlus.stopScan();
        if (mounted) setState(() => _isScanning = false);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isScanning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Scan failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _onDeviceTapped(BluetoothDevice device) async {
    if (_isConnecting) return;

    final confirmed = await _showPairDialog(device);
    if (confirmed != true) return;

    setState(() => _isConnecting = true);

    try {
      // Stop scanning before connecting
      await _scanSub?.cancel();
      await FlutterBluePlus.stopScan();
      if (mounted) setState(() => _isScanning = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                ),
                SizedBox(width: 12),
                Text('Connecting to device...'),
              ],
            ),
            duration: Duration(seconds: 30),
          ),
        );
      }

      // Connect
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      // ✅ FIX 1: Wait for connection to be truly stable
      await device.connectionState
          .where((s) => s == BluetoothConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 10));

      print('✅ Connection confirmed stable. Discovering services...');

      // ✅ FIX 2: Discover services HERE once, then pass writeChar to next screen
      final services = await device.discoverServices();
      print('✅ Services discovered: ${services.length} services');

      // ✅ FIX 3: Find the write characteristic once — WiFiSetupScreen won't re-discover
      final writeChar = _findWriteCharacteristic(services);

      if (writeChar == null) {
        throw Exception(
          'No writable characteristic found on device.\n'
              'Make sure ESP32 firmware is running correctly.',
        );
      }

      print('✅ Write characteristic found: ${writeChar.uuid}');

      setState(() => _connectedDevice = device);
      if (!mounted) return;

      ScaffoldMessenger.of(context).clearSnackBars();

      // ✅ FIX 4: Pass writeChar directly — eliminates the fbp-code: 6 error
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => WiFiSetupScreen(
            scannedQRCode: widget.scannedQRCode,
            bluetoothDevice: device,
            writeCharacteristic: writeChar,
          ),
        ),
      );
    } catch (e) {
      print('❌ Connection error: $e');

      try {
        await device.disconnect();
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();

        String errorMsg = 'Connection failed: $e';
        if (e.toString().contains('Timed out')) {
          errorMsg =
          'Connection timeout. Make sure device is powered on and close by.';
        } else if (e.toString().contains('133')) {
          errorMsg =
          'Connection error (133). Restart Bluetooth on your phone and retry.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMsg),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  /// ✅ Centralized characteristic finder used in one place only
  BluetoothCharacteristic? _findWriteCharacteristic(
      List<BluetoothService> services) {
    const customServiceUuid = '703de63c-1c78-703d-e63c-1a42b93437e2';
    const customWriteCharUuid = '703de63c-1c78-703d-e63c-1a42b93437e3';

    // Priority 1: Look for the specific custom characteristic
    for (final service in services) {
      print('  Service: ${service.uuid}');
      if (service.uuid.toString().toLowerCase() == customServiceUuid) {
        for (final char in service.characteristics) {
          print(
              '    Char: ${char.uuid} write=${char.properties.write} writeNoResp=${char.properties.writeWithoutResponse}');
          if (char.uuid.toString().toLowerCase() == customWriteCharUuid) {
            print('  ✅ Found custom write char!');
            return char;
          }
        }
      }
    }

    // Priority 2: Any writable non-system characteristic
    for (final service in services) {
      for (final char in service.characteristics) {
        final uuid = char.uuid.toString().toLowerCase();
        // Skip standard GATT characteristics
        if (uuid.startsWith('00002a') || uuid == '2b29') continue;

        if (char.properties.write || char.properties.writeWithoutResponse) {
          print('  ✅ Fallback write char: ${char.uuid}');
          return char;
        }
      }
    }

    return null;
  }

  Future<bool?> _showPairDialog(BluetoothDevice device) {
    final displayName =
    device.platformName.isNotEmpty ? device.platformName : 'Unknown Device';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pair with Device'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Device: $displayName',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('ID: ${device.remoteId}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 16),
            const Text('This will:'),
            const SizedBox(height: 4),
            const Text('• Connect via Bluetooth'),
            const Text('• Configure your Wi-Fi'),
            const Text('• Register with the alarm system'),
            const Text('• Add to your favourites'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Pair Device'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = _resultsMap.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Bluetooth Device'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rescan',
            onPressed: _isScanning ? null : _startScan,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.blue.shade300),
            ),
            child: Row(
              children: [
                const Icon(Icons.qr_code_2, color: Colors.blue),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('QR Code scanned ✓',
                          style: TextStyle(
                              color: Colors.blue,
                              fontWeight: FontWeight.bold)),
                      Text(
                        widget.scannedQRCode,
                        style:
                        const TextStyle(color: Colors.amber, fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _StepIndicator(currentStep: 1),
          if (_isScanning)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Scanning… ${devices.length} device(s) found',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          Expanded(
            child: devices.isEmpty
                ? Center(
              child: _isScanning
                  ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Scanning for nearby Bluetooth devices…'),
                  SizedBox(height: 8),
                  Text(
                    'Keep your alarm device powered on and close by.',
                    style: TextStyle(color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ],
              )
                  : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bluetooth_disabled,
                      size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text('No Bluetooth devices found',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text(
                    'Make sure Bluetooth is ON and\nyour device is within range.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: _startScan,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Scan Again'),
                  ),
                ],
              ),
            )
                : ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: devices.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final result = devices[index];
                final device = result.device;
                final name = device.platformName.isNotEmpty
                    ? device.platformName
                    : (result.advertisementData.advName.isNotEmpty
                    ? result.advertisementData.advName
                    : 'Unknown Device');
                final rssi = result.rssi;
                final isConnected =
                    _connectedDevice?.remoteId == device.remoteId;

                return Card(
                  color:
                  isConnected ? Colors.green.withOpacity(0.1) : null,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isConnected
                          ? Colors.green.withOpacity(0.2)
                          : Colors.blue.withOpacity(0.15),
                      child: Icon(
                        isConnected
                            ? Icons.bluetooth_connected
                            : Icons.bluetooth,
                        color:
                        isConnected ? Colors.green : Colors.blue,
                      ),
                    ),
                    title: Text(name,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          device.remoteId.str,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey),
                        ),
                        Row(
                          children: [
                            Icon(_rssiIcon(rssi),
                                size: 14, color: _rssiColor(rssi)),
                            const SizedBox(width: 4),
                            Text('$rssi dBm',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: _rssiColor(rssi))),
                          ],
                        ),
                      ],
                    ),
                    trailing: _isConnecting
                        ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2),
                    )
                        : const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: _isConnecting
                        ? null
                        : () => _onDeviceTapped(device),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  IconData _rssiIcon(int rssi) {
    if (rssi >= -60) return Icons.signal_wifi_4_bar;
    if (rssi >= -75) return Icons.network_wifi_3_bar;
    if (rssi >= -85) return Icons.network_wifi_2_bar;
    return Icons.signal_wifi_0_bar;
  }

  Color _rssiColor(int rssi) {
    if (rssi >= -60) return Colors.green;
    if (rssi >= -75) return Colors.orange;
    return Colors.red;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STEP 2 – Wi-Fi Setup Screen
// ─────────────────────────────────────────────────────────────────────────────
class WiFiSetupScreen extends StatefulWidget {
  final String scannedQRCode;
  final BluetoothDevice bluetoothDevice;
  // ✅ FIX: Accept already-discovered write characteristic — no re-discovery needed
  final BluetoothCharacteristic writeCharacteristic;

  const WiFiSetupScreen({
    Key? key,
    required this.scannedQRCode,
    required this.bluetoothDevice,
    required this.writeCharacteristic,
  }) : super(key: key);

  @override
  _WiFiSetupScreenState createState() => _WiFiSetupScreenState();
}

class _WiFiSetupScreenState extends State<WiFiSetupScreen> {
  List<String> _wifiNetworks = [];
  String? _selectedSSID;
  final TextEditingController _passwordController = TextEditingController();
  bool _isWifiScanning = false;
  bool _isSaving = false;
  bool _obscurePassword = true;

  // ✅ FIX: Monitor BLE connection so we know if it drops between screens
  StreamSubscription<BluetoothConnectionState>? _connectionStateSub;
  bool _bleConnected = true;
  // ✅ FIX: Flag to suppress the disconnect warning after intentional disconnect on success
  bool _setupComplete = false;

  @override
  void initState() {
    super.initState();
    _scanWifi();
    _monitorBleConnection();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _connectionStateSub?.cancel();
    super.dispose();
  }

  void _monitorBleConnection() {
    _connectionStateSub =
        widget.bluetoothDevice.connectionState.listen((state) {
          final connected = state == BluetoothConnectionState.connected;
          if (mounted && connected != _bleConnected) {
            setState(() => _bleConnected = connected);
            // ✅ FIX: Only show warning if setup has NOT completed yet.
            // After success we intentionally call disconnect() which would
            // otherwise trigger this false "Bluetooth disconnected" warning.
            if (!connected && !_setupComplete) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      '⚠️ Bluetooth disconnected! Tap Retry or go back to reconnect.'),
                  backgroundColor: Colors.orange,
                  duration: Duration(seconds: 5),
                ),
              );
            }
          }
        });
  }

  /// ✅ FIX: Reconnect + re-discover services if BLE dropped
  Future<bool> _ensureBleConnected() async {
    final state = await widget.bluetoothDevice.connectionState.first;
    if (state == BluetoothConnectionState.connected) return true;

    print('🔄 BLE dropped — attempting reconnect...');
    try {
      await widget.bluetoothDevice.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );
      await widget.bluetoothDevice.connectionState
          .where((s) => s == BluetoothConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 10));
      print('✅ Reconnected!');
      if (mounted) setState(() => _bleConnected = true);
      return true;
    } catch (e) {
      print('❌ Reconnect failed: $e');
      return false;
    }
  }

  Future<void> _scanWifi() async {
    setState(() {
      _isWifiScanning = true;
      _wifiNetworks = [];
    });

    try {
      final enabled = await WiFiForIoTPlugin.isEnabled();
      if (!enabled) await WiFiForIoTPlugin.setEnabled(true);

      final results = await WiFiForIoTPlugin.loadWifiList();
      final ssids = results
          .map((e) => e.ssid)
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList()
        ..sort();

      if (mounted) setState(() => _wifiNetworks = ssids);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Wi-Fi scan error: $e'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isWifiScanning = false);
    }
  }

  Future<void> _connectAndFinish() async {
    if (_selectedSSID == null || _selectedSSID!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a Wi-Fi network.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final password = _passwordController.text;
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter the Wi-Fi password.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      // ✅ FIX: Verify BLE still connected before sending
      final isConnected = await _ensureBleConnected();
      if (!isConnected) {
        throw Exception(
          'Bluetooth connection lost. Please go back and reconnect to the device.',
        );
      }

      // ✅ FIX: Use the pre-discovered writeCharacteristic — NO discoverServices() here
      await _sendCredentialsViaBLE(_selectedSSID!, password);

      await _saveCredentialsToServer(
          widget.bluetoothDevice.remoteId.str, _selectedSSID!, password);

      await _registerAlarmDevice();

      // ✅ FIX: Mark setup as complete BEFORE disconnecting so the
      // connection monitor doesn't show a false "disconnected" warning
      _setupComplete = true;

      try {
        await widget.bluetoothDevice.disconnect();
      } catch (_) {}

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Device added to favourites!'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => FavoritesScreen()),
            (_) => false,
      );
    } catch (e) {
      print('❌ Setup failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Setup failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// ✅ FIX: Uses widget.writeCharacteristic directly
  /// The old version called discoverServices() here — that caused fbp-code: 6
  Future<void> _sendCredentialsViaBLE(String ssid, String password) async {
    print('📤 Sending WiFi credentials via BLE...');

    final writeChar = widget.writeCharacteristic;
    print('✅ Using pre-discovered char: ${writeChar.uuid}');

    // Request larger MTU
    try {
      final mtu = await widget.bluetoothDevice.requestMtu(512);
      print('✅ MTU negotiated: $mtu bytes');
    } catch (e) {
      print('⚠️ MTU request failed (using default): $e');
    }

    final payload = jsonEncode({
      'cmd': 'wifi_config',
      'ssid': ssid,
      'password': password,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    print('📦 Payload (${payload.length} chars)');

    final bytes = utf8.encode(payload);

    // Get current MTU for safe chunk size
    int mtuSize = 23;
    try {
      mtuSize = await widget.bluetoothDevice.mtu.first;
    } catch (_) {}
    final chunkSize = mtuSize - 3; // Subtract 3 bytes for ATT overhead

    print('📦 Chunk size: $chunkSize, Total bytes: ${bytes.length}');

    final totalChunks = (bytes.length / chunkSize).ceil();

    for (int i = 0; i < bytes.length; i += chunkSize) {
      final end =
      (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      final chunk = bytes.sublist(i, end);
      final chunkNum = (i / chunkSize).floor() + 1;

      print('📤 Chunk $chunkNum/$totalChunks (${chunk.length} bytes)...');

      try {
        await writeChar.write(
          chunk,
          withoutResponse: writeChar.properties.writeWithoutResponse &&
              !writeChar.properties.write,
        );
        await Future.delayed(const Duration(milliseconds: 100));
      } catch (e) {
        print('❌ Write failed on chunk $chunkNum: $e');
        throw Exception(
            'Failed to send credentials (chunk $chunkNum/$totalChunks): $e');
      }
    }

    print('✅ All $totalChunks chunks sent!');
    await Future.delayed(const Duration(seconds: 2));
    print('✅ WiFi config complete!');
  }

  Future<void> _saveCredentialsToServer(
      String deviceUuid, String ssid, String password) async {
    final response = await http
        .post(
      Uri.parse(
          'https://monsow.in/alarm/index.php?action=save_wifi_credentials'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'device_uuid': deviceUuid,
        'ssid': ssid,
        'password': password,
      }),
    )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('Server error ${response.statusCode}: ${response.body}');
    }

    final result = jsonDecode(response.body);
    if (result['success'] != true) {
      throw Exception(
          'Database save failed: ${result['error'] ?? 'Unknown error'}');
    }
  }

  Future<void> _registerAlarmDevice() async {
    final deviceUuid = widget.bluetoothDevice.remoteId.str;
    final deviceName = widget.bluetoothDevice.platformName.isNotEmpty
        ? widget.bluetoothDevice.platformName
        : 'Alarm Device';

    final apiService = Provider.of<ApiService>(context, listen: false);

    // ── Step 1: Register the device in device_registry ────────────────────────
    final result = await apiService.deviceRegister(
      deviceUuid: deviceUuid,
      deviceName: deviceName,
      deviceType: 'alarm',
      connectionType: 'wifi_ble',
      qrData: widget.scannedQRCode,
      bleServiceUuid: deviceUuid,
    );

    if (result == null || result['success'] != true) {
      throw Exception('Device registration failed. Please try again.');
    }

    // ── Step 2: Link device to the logged-in user ─────────────────────────────
    // This is what makes it appear in FavoritesScreen via getUserDevices()
    final linked = await AuthService().addUserDevice(deviceUuid);
    if (!linked) {
      // Non-fatal: device is registered but not linked to user account.
      // This can happen if the user is not logged in or server is slow.
      print('⚠️ Device registered but could not be linked to user account. '
          'It may not appear in Favourites until re-linked.');
    }

    // ── Step 3: Save UUID locally so HomeScreen can use it ────────────────────
    final settings = Provider.of<SettingsManager>(context, listen: false);
    await settings.setConnectedDeviceUuid(deviceUuid);
    await settings.setDeviceName(deviceName);
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect to Wi-Fi'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            widget.bluetoothDevice.disconnect();
            Navigator.pop(context);
          },
        ),
      ),
      body: Column(
        children: [
          // BLE connection status banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _bleConnected
                  ? Colors.green.withOpacity(0.12)
                  : Colors.orange.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _bleConnected
                    ? Colors.green.shade300
                    : Colors.orange.shade300,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _bleConnected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  color: _bleConnected ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _bleConnected
                            ? 'Bluetooth Connected ✓'
                            : 'Bluetooth Disconnected ⚠️',
                        style: TextStyle(
                          color:
                          _bleConnected ? Colors.green : Colors.orange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        widget.bluetoothDevice.platformName.isNotEmpty
                            ? widget.bluetoothDevice.platformName
                            : widget.bluetoothDevice.remoteId.str,
                        style: TextStyle(
                          color:
                          _bleConnected ? Colors.green : Colors.orange,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!_bleConnected)
                  TextButton(
                    onPressed: () async {
                      final ok = await _ensureBleConnected();
                      if (mounted && !ok) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Reconnect failed. Go back and try again.'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
                    child: const Text('Retry',
                        style: TextStyle(color: Colors.orange)),
                  ),
              ],
            ),
          ),

          _StepIndicator(currentStep: 2),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Select Wi-Fi Network',
                    style:
                    TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Choose the network your alarm device will use.',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      if (_isWifiScanning)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child:
                            CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      Text(
                        _isWifiScanning
                            ? 'Scanning for networks…'
                            : '${_wifiNetworks.length} network(s) found',
                        style: const TextStyle(color: Colors.grey),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _isWifiScanning ? null : _scanWifi,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Refresh'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_wifiNetworks.isEmpty && !_isWifiScanning)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade700),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Center(
                        child: Text(
                          'No Wi-Fi networks found.\nMake sure Wi-Fi is enabled and tap Refresh.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  else
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade700),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        children:
                        _wifiNetworks.asMap().entries.map((entry) {
                          final i = entry.key;
                          final ssid = entry.value;
                          final isSelected = _selectedSSID == ssid;

                          return Column(
                            children: [
                              if (i > 0)
                                const Divider(height: 1, thickness: 1),
                              ListTile(
                                leading: Icon(
                                  Icons.wifi,
                                  color: isSelected
                                      ? Colors.blue
                                      : Colors.grey,
                                ),
                                title: Text(
                                  ssid,
                                  style: TextStyle(
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color:
                                    isSelected ? Colors.blue : null,
                                  ),
                                ),
                                trailing: isSelected
                                    ? const Icon(Icons.check_circle,
                                    color: Colors.blue)
                                    : null,
                                onTap: () =>
                                    setState(() => _selectedSSID = ssid),
                              ),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                  const SizedBox(height: 20),
                  const Text(
                    'Wi-Fi Password',
                    style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      hintText: 'Enter Wi-Fi password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      // Disable if saving or BLE disconnected
                      onPressed: (_isSaving || !_bleConnected)
                          ? null
                          : _connectAndFinish,
                      icon: _isSaving
                          ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                          : const Icon(Icons.done),
                      label: Text(
                        _isSaving
                            ? 'Setting up…'
                            : !_bleConnected
                            ? 'Bluetooth Disconnected'
                            : 'Connect & Add to Favourites',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.blue.shade300),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline,
                            color: Colors.blue, size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'The Wi-Fi credentials are sent to your alarm device '
                                'via Bluetooth. Once connected to Wi-Fi, the device will '
                                'be controllable from anywhere.',
                            style:
                            TextStyle(color: Colors.blue, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared widgets
// ─────────────────────────────────────────────────────────────────────────────
class _StepIndicator extends StatelessWidget {
  final int currentStep;
  const _StepIndicator({required this.currentStep});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _StepDot(label: 'Scan QR', step: 0, current: currentStep),
          _StepLine(active: currentStep >= 1),
          _StepDot(label: 'Bluetooth', step: 1, current: currentStep),
          _StepLine(active: currentStep >= 2),
          _StepDot(label: 'Wi-Fi', step: 2, current: currentStep),
          _StepLine(active: currentStep >= 3),
          _StepDot(label: 'Done', step: 3, current: currentStep),
        ],
      ),
    );
  }
}

class _StepDot extends StatelessWidget {
  final String label;
  final int step;
  final int current;

  const _StepDot(
      {required this.label, required this.step, required this.current});

  @override
  Widget build(BuildContext context) {
    final done = current > step;
    final active = current == step;
    return Column(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done
                ? Colors.green
                : active
                ? Colors.blue
                : Colors.grey.shade700,
          ),
          child: Center(
            child: done
                ? const Icon(Icons.check, color: Colors.white, size: 16)
                : Text(
              '${step + 1}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: done
                ? Colors.green
                : active
                ? Colors.blue
                : Colors.grey,
          ),
        ),
      ],
    );
  }
}

class _StepLine extends StatelessWidget {
  final bool active;
  const _StepLine({required this.active});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.only(bottom: 16),
        color: active ? Colors.blue : Colors.grey.shade700,
      ),
    );
  }
}