import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'auth_service.dart';
import 'login_screen.dart';
import 'qr_scan_screen.dart';
import 'home_screen.dart';
import 'settings_manager.dart';

// ================================================================
// favourite_screen.dart  (UPDATED — multi-user)
// - Loads ONLY the devices belonging to the logged-in user
//   via auth.php?action=get_user_devices
// - Logout button in AppBar
// - After QR pairing: links the new device to the user automatically
// ================================================================

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({Key? key}) : super(key: key);
  @override
  _FavoritesScreenState createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<Map<String, dynamic>> _devices = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  // ── Load only THIS user's devices ────────────────────────────
  Future<void> _loadDevices() async {
    setState(() => _isLoading = true);
    try {
      final devices = await AuthService().getUserDevices();
      if (mounted) {
        setState(() {
          _devices = devices;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Logout ───────────────────────────────────────────────────
  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        title: const Text('Logout', style: TextStyle(color: Colors.white)),
        content: const Text('Are you sure you want to logout?',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
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

  // ── Delete device from user's list ───────────────────────────
  Future<void> _removeDevice(Map<String, dynamic> device) async {
    final deviceUuid = device['device_uuid'] as String;
    final deviceName = device['device_name'] ?? 'Unknown Device';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
          SizedBox(width: 10),
          Text('Remove Device', style: TextStyle(color: Colors.white)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Remove this device from your account?',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          Text(deviceName,
              style: const TextStyle(color: Colors.white, fontSize: 16,
                  fontWeight: FontWeight.bold)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.remove_circle, size: 18),
            label: const Text('Remove'),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final ok = await AuthService().removeUserDevice(deviceUuid);
    if (ok) {
      setState(() => _devices.removeWhere((d) => d['device_uuid'] == deviceUuid));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$deviceName removed'), backgroundColor: Colors.green),
        );
      }
    }
  }

  // ── Navigate to device control ───────────────────────────────
  Future<void> _connectToDevice(String deviceUuid, String deviceName) async {
    final settings = SettingsManager();
    await settings.setConnectedDeviceUuid(deviceUuid); // WiFi UUID from device_registry
    await settings.setDeviceName(deviceName);
    await settings.setHubLanguage(deviceUuid);         // ✅ hub_language = same WiFi UUID
    await settings.setFirstTimeSetup(false);
    if (mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => HomeScreen()));
    }
  }

  // ── Add new device via QR scan ───────────────────────────────
  void _addNewDevice() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => QRScanScreen()),
    ).then((_) => _loadDevices()); // refresh list after pairing
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService();

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2D2D2D),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.security, color: Colors.blue, size: 20),
              SizedBox(width: 8),
              Text('My Devices', style: TextStyle(fontSize: 18)),
            ]),
            if (user.userName != null)
              Text(user.userName!,
                  style: const TextStyle(fontSize: 11, color: Colors.white54,
                      fontWeight: FontWeight.normal)),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh),   onPressed: _loadDevices),
          IconButton(icon: const Icon(Icons.logout, color: Colors.red), onPressed: _logout,
              tooltip: 'Logout'),
        ],
      ),

      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addNewDevice,
        backgroundColor: Colors.blue,
        icon: const Icon(Icons.add),
        label: const Text('Add Device'),
      ),

      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.blue))
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
    final isOnline = device['status'] == 'online';
    final name     = device['device_name'] ?? 'Unknown Device';
    final lastSeen = _formatDate(device['last_seen_at']?.toString());
    final battery  = device['battery_level'];

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _connectToDevice(device['device_uuid'], name),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: isOnline
                  ? [const Color(0xFF2D2D2D), const Color(0xFF1E3A1E)]
                  : [const Color(0xFF2D2D2D), const Color(0xFF3A2D1E)]),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: isOnline ? Colors.green : Colors.orange, width: 2),
              boxShadow: [BoxShadow(
                color: (isOnline ? Colors.green : Colors.orange).withOpacity(0.2),
                blurRadius: 10, spreadRadius: 2,
              )],
            ),
            child: Row(children: [
              // Icon
              Container(
                width: 60, height: 60,
                decoration: BoxDecoration(
                  color: (isOnline ? Colors.green : Colors.orange).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.security,
                    color: isOnline ? Colors.green : Colors.orange, size: 32),
              ),
              const SizedBox(width: 16),

              // Info
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(color: Colors.white,
                      fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: isOnline ? Colors.green : Colors.orange,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(isOnline ? 'ONLINE' : 'OFFLINE',
                        style: const TextStyle(color: Colors.white,
                            fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 6),
                  Text('Last seen: $lastSeen',
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  if (battery != null)
                    Text('Battery: $battery%',
                        style: TextStyle(
                            color: battery < 20 ? Colors.red : Colors.white54,
                            fontSize: 12)),
                ],
              )),

              // Actions
              Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.arrow_forward_ios, color: Colors.white54, size: 18),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () => _removeDevice(device),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withOpacity(0.4)),
                    ),
                    child: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.security_outlined, size: 80, color: Colors.white.withOpacity(0.2)),
        const SizedBox(height: 24),
        const Text('No Devices Yet', style: TextStyle(color: Colors.white,
            fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        const Text('Tap "Add Device" to scan the QR code\non your alarm unit.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 15)),
        const SizedBox(height: 32),
        ElevatedButton.icon(
          onPressed: _addNewDevice,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan QR Code'),
          style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue, padding:
          const EdgeInsets.symmetric(horizontal: 28, vertical: 14)),
        ),
      ]),
    ),
  );

  String _formatDate(String? dateStr) {
    if (dateStr == null) return 'Never';
    try {
      final date = DateTime.parse(dateStr);
      final diff = DateTime.now().difference(date);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inHours  < 1) return '${diff.inMinutes}m ago';
      if (diff.inDays   < 1) return '${diff.inHours}h ago';
      if (diff.inDays   < 7) return '${diff.inDays}d ago';
      return '${date.day}/${date.month}/${date.year}';
    } catch (_) {
      return 'Unknown';
    }
  }
}