import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'auth_service.dart';
import 'login_screen.dart';
import 'qr_scan_screen.dart';
import 'home_screen.dart';
import 'settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ================================================================
// favourite_screen.dart  (WHITE UI VERSION)
//
// FIX APPLIED:
//   _pollAllArmStates() now calls ?action=system_state&device_uuid=UUID
//   instead of ?action=get_alarm_status&device_uuid=UUID
//
//   WHY: get_alarm_status queries system_state WITHOUT a device_uuid
//        filter (ORDER BY updated_at DESC LIMIT 1), so it returns
//        the GLOBAL last-changed device's state — causing all devices
//        to show the same arm state.
//
//        system_state (GET) correctly filters by device_uuid because
//        getSystemState() in PHP was already fixed to scope per device.
//
//   No other logic changed.
// ================================================================

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({Key? key}) : super(key: key);

  @override
  _FavoritesScreenState createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<Map<String, dynamic>> _devices = [];
  bool _isLoading = true;

  final Map<String, String> _armStates = {};
  Timer? _statePoller;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void dispose() {
    _statePoller?.cancel();
    super.dispose();
  }

  static const String _kPendingDevices = 'pending_local_devices';

  Future<void> _loadDevices() async {
    setState(() => _isLoading = true);
    try {
      // ── Fetch server devices (may fail if offline) ────────────
      List<Map<String, dynamic>> serverDevices = [];
      try {
        serverDevices = await AuthService().getUserDevices();
      } catch (e) {
        print('⚠️ Could not fetch server devices: $e');
      }

      // ── Merge locally-saved pending devices ───────────────────
      // These are devices that were paired via BLE but not yet
      // confirmed by the server (e.g. provisioning AP had no internet).
      final merged = List<Map<String, dynamic>>.from(serverDevices);
      final pendingDevices = await _loadPendingLocalDevices();

      for (final pending in pendingDevices) {
        final uuid = pending['device_uuid']?.toString() ?? '';
        final alreadyInServer =
            serverDevices.any((d) => d['device_uuid'] == uuid);
        if (!alreadyInServer && uuid.isNotEmpty) {
          merged.add({
            'device_uuid': uuid,
            'device_name': pending['device_name'] ?? 'Alarm Device',
            'status': 'offline', // unknown until server confirms
            'last_seen_at': pending['added_at'],
            'is_pending': true, // flag for UI badge
            'role': 'admin',
            'access_type': 'owner',
          });
        }
      }

      if (merged.isEmpty) {
        final settings = SettingsManager();
        await settings.initialize();
        final localUuid = settings.connectedDeviceUuid;
        if (localUuid.isNotEmpty) {
          final role = settings.currentDeviceRole;
          merged.add({
            'device_uuid': localUuid,
            'device_name': settings.deviceName,
            'status': 'offline',
            'last_seen_at': DateTime.now().toIso8601String(),
            'is_local': true,
            'role': role,
            'access_type': role == 'admin' ? 'owner' : 'shared',
          });
        }
      }

      if (mounted) {
        setState(() {
          _devices = merged;
          _isLoading = false;
        });
        _startStatePolling();
        await _pollAllArmStates();
        // Retry syncing pending devices to server in background
        _syncPendingDevicesToServer(pendingDevices);
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<List<Map<String, dynamic>>> _loadPendingLocalDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPendingDevices) ?? '[]';
      final pending = List<Map<String, dynamic>>.from(
        (jsonDecode(raw) as List)
            .map((e) => Map<String, dynamic>.from(e as Map)),
      );
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      final active = <Map<String, dynamic>>[];

      for (final device in pending) {
        final addedAt = DateTime.tryParse(device['added_at']?.toString() ?? '');
        if (addedAt == null || addedAt.isAfter(cutoff)) {
          active.add(device);
        }
      }

      if (active.length != pending.length) {
        await prefs.setString(_kPendingDevices, jsonEncode(active));
      }

      return active;
    } catch (_) {
      return [];
    }
  }

  Future<void> _removePendingLocalDevice(String deviceUuid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPendingDevices) ?? '[]';
      final list = List<Map<String, dynamic>>.from(
        (jsonDecode(raw) as List)
            .map((e) => Map<String, dynamic>.from(e as Map)),
      );
      list.removeWhere((d) => d['device_uuid'] == deviceUuid);
      await prefs.setString(_kPendingDevices, jsonEncode(list));
    } catch (e) {
      print('Could not remove pending device $deviceUuid: $e');
    }
  }

  /// Retry server registration + user-device linking for any locally-saved
  /// pending devices.  Once confirmed, remove them from local storage.
  void _syncPendingDevicesToServer(List<Map<String, dynamic>> pending) async {
    if (pending.isEmpty) return;

    final serverOnline = await _isAlarmServerReachable();
    if (!serverOnline) {
      print('Pending device sync postponed: alarm server is unreachable.');
      return;
    }

    print('Syncing ${pending.length} pending device(s) to server...');

    final prefs = await SharedPreferences.getInstance();

    for (final device in pending) {
      final uuid = device['device_uuid']?.toString() ?? '';
      final name = device['device_name']?.toString() ?? 'Alarm Device';
      if (uuid.isEmpty) continue;

      try {
        // Register on device_registry
        final regRes = await http
            .post(
              Uri.parse(
                  'https://monsow.in/alarm/index.php?action=device_register'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'device_uuid': uuid,
                'device_name': name,
                'device_type': 'alarm',
                'connection_type': 'wifi',
                'ble_service_uuid': uuid,
              }),
            )
            .timeout(const Duration(seconds: 10));

        final regResult = jsonDecode(regRes.body);

        // Link to user account
        final linked = await AuthService().addUserDevice(uuid);

        if ((regResult['success'] == true) && linked) {
          // Remove from local pending list
          final raw = prefs.getString(_kPendingDevices) ?? '[]';
          final list = List<Map<String, dynamic>>.from(
            (jsonDecode(raw) as List)
                .map((e) => Map<String, dynamic>.from(e as Map)),
          );
          list.removeWhere((d) => d['device_uuid'] == uuid);
          await prefs.setString(_kPendingDevices, jsonEncode(list));

          print('Pending device synced and confirmed: $uuid');

          // Reload to replace the pending entry with the server entry
          if (mounted) _loadDevices();
        }
      } catch (e) {
        print('Could not sync pending device $uuid: $e');
      }
    }
  }

  Future<bool> _isAlarmServerReachable() async {
    try {
      final res = await http
          .get(Uri.parse('https://monsow.in/alarm/index.php?action=test'))
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void _startStatePolling() {
    _statePoller?.cancel();
    _statePoller = Timer.periodic(
      const Duration(seconds: 6),
      (_) => _pollAllArmStates(),
    );
  }

  // ── FIX: use ?action=system_state&device_uuid=UUID ───────────────
  // The old code called get_alarm_status which had no device_uuid filter
  // in the SQL — it returned the last globally changed device's state.
  // system_state correctly scopes its query per device_uuid.
  Future<void> _pollAllArmStates() async {
    if (_devices.isEmpty) return;

    for (final device in _devices) {
      final uuid = device['device_uuid']?.toString() ?? '';
      if (uuid.isEmpty) continue;

      try {
        final userId = AuthService().userId;
        final uri = Uri.parse('https://monsow.in/alarm/index.php').replace(
          queryParameters: {
            'action': 'system_state',
            'device_uuid': uuid,
            if (userId != null) 'user_id': userId.toString(),
          },
        );
        final res = await http
            .get(uri)
            .timeout(const Duration(seconds: 5));

        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;

          // system_state returns { "state": "armed" | "disarmed" | "stay_arm" | "alarm" }
          final rawState =
              (data['state'] ?? 'disarmed').toString().toLowerCase();

          String state;
          if (rawState == 'alarm') {
            state = 'alarm';
          } else if (rawState == 'armed') {
            state = 'armed';
          } else if (rawState == 'stay_arm' ||
              rawState == 'stay_armed' ||
              rawState == 'stay') {
            state = 'stay';
          } else {
            state = 'disarmed';
          }

          if (mounted && _armStates[uuid] != state) {
            setState(() => _armStates[uuid] = state);
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text(
          'Logout',
          style: TextStyle(color: Colors.black),
        ),
        content: const Text(
          'Are you sure you want to logout?',
          style: TextStyle(color: Colors.black87),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.black54),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await AuthService().logout();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    }
  }

  Future<void> _shareDevice(Map<String, dynamic> device) async {
    if (!_canManageDevice(device)) return;

    final deviceUuid = device['device_uuid'] as String;
    final deviceName = device['device_name'] ?? 'Unknown Device';
    final emailCtrl = TextEditingController();
    String selectedRole = 'user';

    final shareInput = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Colors.white,
          title: const Text(
            'Share Device',
            style: TextStyle(color: Colors.black),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Share "$deviceName" with:',
                style: const TextStyle(color: Colors.black87),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: Colors.black),
                decoration: const InputDecoration(
                  hintText: 'Enter email',
                  hintStyle: TextStyle(color: Colors.black38),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Access role',
                style: TextStyle(
                  color: Colors.black87,
                  fontWeight: FontWeight.w600,
                ),
              ),
              RadioListTile<String>(
                value: 'user',
                groupValue: selectedRole,
                onChanged: (v) =>
                    setDialogState(() => selectedRole = v ?? 'user'),
                title: const Text('User'),
                subtitle: const Text(
                  'Can use the device, but cannot share or change settings',
                ),
                contentPadding: EdgeInsets.zero,
              ),
              RadioListTile<String>(
                value: 'admin',
                groupValue: selectedRole,
                onChanged: (v) =>
                    setDialogState(() => selectedRole = v ?? 'user'),
                title: const Text('Admin'),
                subtitle: const Text(
                  'Can share this device and change settings for everyone',
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.black54),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, {
                'email': emailCtrl.text.trim(),
                'role': selectedRole,
              }),
              child: const Text('Share'),
            ),
          ],
        ),
      ),
    );

    final email = shareInput?['email'] ?? '';
    final role = shareInput?['role'] ?? 'user';
    if (email.isEmpty) return;

    final result = await AuthService().shareDevice(
      targetEmail: email,
      deviceUuid: deviceUuid,
      role: role,
    );

    if (!mounted) return;

    if (result.success && result.loginInfo != null) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.white,
          title: const Text(
            '✅ Shared Successfully!',
            style: TextStyle(color: Colors.green),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'New user created:',
                style: TextStyle(color: Colors.black87, fontSize: 16),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green, width: 1.5),
                ),
                child: Column(
                  children: [
                    Text(
                      result.loginInfo!,
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'User ID: ${result.userId}',
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Share this login info with them as ${role.toUpperCase()}.',
                style: const TextStyle(
                  color: Colors.black54,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: const Text(
                  '💡 Any arm/disarm from your phone or theirs will instantly update both apps.',
                  style: TextStyle(color: Colors.blue, fontSize: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'OK',
                style: TextStyle(color: Colors.black),
              ),
            ),
          ],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _removeDevice(Map<String, dynamic> device) async {
    final deviceUuid = device['device_uuid'] as String;
    final deviceName = device['device_name'] ?? 'Unknown Device';
    final isPending = device['is_pending'] == true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
            SizedBox(width: 10),
            Text(
              'Remove Device',
              style: TextStyle(color: Colors.black),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Remove this device from your account?',
              style: TextStyle(color: Colors.black87),
            ),
            const SizedBox(height: 8),
            Text(
              deviceName,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.black54),
            ),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.remove_circle, size: 18),
            label: const Text('Remove'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final ok =
        isPending ? true : await AuthService().removeUserDevice(deviceUuid);
    if (ok) {
      await _removePendingLocalDevice(deviceUuid);
      final settings = SettingsManager();
      if (settings.connectedDeviceUuid == deviceUuid) {
        await settings.clearConnectedDevice();
      }
      setState(() {
        _devices.removeWhere((d) => d['device_uuid'] == deviceUuid);
        _armStates.remove(deviceUuid);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$deviceName removed'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not remove device. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ── _connectToDevice: sets SettingsManager so HomeScreen/AlarmSystemProvider
  //    knows WHICH device UUID to use for arm/disarm calls.
  //    device_name is also stored so the Home screen can display it and
  //    the provider can identify which device is active.
  Future<void> _connectToDevice(String deviceUuid, String deviceName) async {
    final device = _devices.firstWhere(
      (d) => d['device_uuid']?.toString() == deviceUuid,
      orElse: () => <String, dynamic>{'role': 'user'},
    );
    final role = _deviceRole(device);
    final settings = SettingsManager();
    await settings.setConnectedDeviceUuid(deviceUuid); // ← provider reads this
    await settings
        .setDeviceName(deviceName); // ← used for display + identification
    await settings.setHubLanguage(deviceUuid);
    await settings.setCurrentDeviceRole(role);
    await settings.setFirstTimeSetup(false);

    if (mounted) {
      _statePoller?.cancel();
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => HomeScreen(),
        ),
      );
      // Resume polling when we return from HomeScreen
      _startStatePolling();
      await _pollAllArmStates();
    }
  }

  void _addNewDevice() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => QRScanScreen()),
    ).then((_) => _loadDevices());
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService();

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.security, color: Colors.blue, size: 20),
                SizedBox(width: 8),
                Text(
                  'My Devices',
                  style: TextStyle(fontSize: 18, color: Colors.black),
                ),
              ],
            ),
            if (user.userName != null)
              Text(
                user.userName!,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.black54,
                  fontWeight: FontWeight.normal,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.black),
            onPressed: _loadDevices,
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.red),
            onPressed: _logout,
            tooltip: 'Logout',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addNewDevice,
        backgroundColor: Colors.blue,
        icon: const Icon(Icons.add),
        label: const Text('Add Device'),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.blue),
            )
          : _devices.isEmpty
              ? _buildEmpty()
              : _buildList(),
    );
  }

  Widget _buildList() => RefreshIndicator(
        onRefresh: _loadDevices,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
          itemCount: _devices.length,
          itemBuilder: (_, i) => _buildCard(_devices[i]),
        ),
      );

  Widget _buildCard(Map<String, dynamic> device) {
    final uuid = device['device_uuid']?.toString() ?? '';
    final isPending =
        device['is_pending'] == true; // locally-saved, not yet on server
    final isOnline = device['status'] == 'online';
    final name = device['device_name'] ?? 'Unknown Device';
    final lastSeen = _formatDate(device['last_seen_at']?.toString());
    final battery = device['battery_level'];
    final canManage = _canManageDevice(device);

    final armState = isPending ? 'offline' : (_armStates[uuid] ?? 'unknown');
    final _ArmBadge badge = _armBadgeFor(armState);

    // Pending devices use a blue border to signal "syncing to server"
    final borderColor = isPending
        ? Colors.blue.shade300
        : (isOnline ? Colors.green.shade300 : Colors.orange.shade300);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _connectToDevice(uuid, name),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: borderColor,
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.06),
                  blurRadius: 10,
                  spreadRadius: 1,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: (isOnline ? Colors.green : Colors.orange)
                        .withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.security,
                    color: isOnline ? Colors.green : Colors.orange,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          if (isPending)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(6),
                                border:
                                    Border.all(color: Colors.orange.shade200),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.cloud_off_outlined,
                                    color: Colors.orange,
                                    size: 12,
                                  ),
                                  SizedBox(width: 4),
                                  Text('Pending',
                                      style: TextStyle(
                                        color: Colors.orange,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      )),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: isOnline ? Colors.green : Colors.orange,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              isOnline ? 'ONLINE' : 'OFFLINE',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: badge.color.withOpacity(0.9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  badge.emoji,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  badge.label,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Last seen: $lastSeen',
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 12,
                        ),
                      ),
                      if (battery != null)
                        Text(
                          'Battery: $battery%',
                          style: TextStyle(
                            color: battery < 20 ? Colors.red : Colors.black54,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (canManage) ...[
                      IconButton(
                        icon: const Icon(
                          Icons.share,
                          color: Colors.black54,
                          size: 20,
                        ),
                        tooltip: 'Share device',
                        onPressed: () => _shareDevice(device),
                      ),
                      const SizedBox(height: 8),
                    ],
                    const Icon(
                      Icons.arrow_forward_ios,
                      color: Colors.black38,
                      size: 18,
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () => _removeDevice(device),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.red.withOpacity(0.25),
                          ),
                        ),
                        child: const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _canManageDevice(Map<String, dynamic> device) {
    return _deviceRole(device) == 'admin';
  }

  String _deviceRole(Map<String, dynamic> device) {
    final role = device['role']?.toString().trim().toLowerCase();
    if (role == 'admin') return 'admin';
    if (role == 'user') return 'user';

    final accessType = device['access_type']?.toString().toLowerCase();
    // 'shared' access = regular user; only explicit 'owner'/'admin' gets admin
    if (accessType == 'shared') return 'user';
    if (accessType == 'owner' || accessType == 'admin') return 'admin';

    // ── SAFE DEFAULT ──────────────────────────────────────────────
    // Previously this returned 'admin' which gave ALL users with
    // missing/unknown role the ability to share devices and access
    // settings. Changed to 'user' so only explicit admins get
    // management access.
    return 'user';
  }

  _ArmBadge _armBadgeFor(String state) {
    switch (state) {
      case 'armed':
        return _ArmBadge(
          emoji: '🔒',
          label: 'ARMED',
          color: Colors.green.shade700,
        );
      case 'stay':
        return _ArmBadge(
          emoji: '🏠',
          label: 'STAY',
          color: Colors.teal.shade700,
        );
      case 'alarm':
        return _ArmBadge(
          emoji: '🚨',
          label: 'ALARM!',
          color: Colors.red.shade700,
        );
      case 'disarmed':
        return _ArmBadge(
          emoji: '🔓',
          label: 'DISARMED',
          color: Colors.grey.shade700,
        );
      case 'offline':
        return _ArmBadge(
          emoji: '',
          label: 'OFFLINE',
          color: Colors.grey.shade700,
        );
      default:
        return _ArmBadge(
          emoji: '',
          label: '…',
          color: Colors.grey.shade800,
        );
    }
  }

  Widget _buildEmpty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.security_outlined,
                size: 80,
                color: Colors.black.withOpacity(0.15),
              ),
              const SizedBox(height: 24),
              const Text(
                'No Devices Yet',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Tap "Add Device" to scan the QR code\non your alarm unit.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54, fontSize: 15),
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: _addNewDevice,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR Code'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  String _formatDate(String? dateStr) {
    if (dateStr == null) return 'Never';
    try {
      final date = DateTime.parse(dateStr);
      final diff = DateTime.now().difference(date);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inHours < 1) return '${diff.inMinutes}m ago';
      if (diff.inDays < 1) return '${diff.inHours}h ago';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${date.day}/${date.month}/${date.year}';
    } catch (_) {
      return 'Unknown';
    }
  }
}

class _ArmBadge {
  final String emoji;
  final String label;
  final Color color;

  const _ArmBadge({
    required this.emoji,
    required this.label,
    required this.color,
  });
}
