import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'device_registry_service.dart';
import 'qr_scan_screen.dart';
import 'home_screen.dart';
import 'settings_manager.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({Key? key}) : super(key: key);

  @override
  _FavoritesScreenState createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<Map<String, dynamic>> _connectedDevices = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadConnectedDevices();
  }

  Future<void> _loadConnectedDevices() async {
    setState(() => _isLoading = true);

    try {
      final deviceRegistry =
      Provider.of<DeviceRegistryService>(context, listen: false);
      final devices = await deviceRegistry.listDevicesByType('alarm');

      if (mounted) {
        setState(() {
          _connectedDevices = devices
              .map((device) => {
            'device_uuid': device['device_uuid'],
            'device_name': device['device_name'],
            'last_seen': device['last_seen_at']?.toString() ?? 'Unknown',
            'status': device['status'],
          })
              .toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      print('❌ Error loading devices: $e');
      if (mounted) {
        setState(() {
          _connectedDevices = [];
          _isLoading = false;
        });
      }
    }
  }

  // ✅ NEW: Delete device with confirmation dialog
  Future<void> _deleteDevice(Map<String, dynamic> device) async {
    final deviceUuid = device['device_uuid'] as String;
    final deviceName = device['device_name'] ?? 'Unknown Device';

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
            SizedBox(width: 10),
            Text('Delete Device', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to delete:',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              deviceName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.red, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This device will be removed from your account. This cannot be undone.',
                      style: TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete, size: 18),
            label: const Text('Delete'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // Show loading snackbar
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Text('Deleting $deviceName...'),
              ],
            ),
            duration: const Duration(seconds: 10),
            backgroundColor: Colors.orange,
          ),
        );
      }

      final deviceRegistry =
      Provider.of<DeviceRegistryService>(context, listen: false);
      final success = await deviceRegistry.deleteDevice(deviceUuid);

      if (!mounted) return;

      ScaffoldMessenger.of(context).clearSnackBars();

      if (success) {
        // Remove from local list immediately
        setState(() {
          _connectedDevices
              .removeWhere((d) => d['device_uuid'] == deviceUuid);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ $deviceName deleted successfully'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Failed to delete $deviceName. Please try again.'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.favorite, color: Colors.red, size: 24),
            SizedBox(width: 8),
            Text('My Devices'),
          ],
        ),
        backgroundColor: const Color(0xFF2D2D2D),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadConnectedDevices,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.blue),
            SizedBox(height: 16),
            Text(
              'Loading devices...',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      )
          : _connectedDevices.isEmpty
          ? _buildEmptyState()
          : _buildDeviceList(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addNewDevice,
        icon: const Icon(Icons.add),
        label: const Text('Add Device'),
        backgroundColor: Colors.blue,
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.devices_other, size: 100, color: Colors.white24),
            const SizedBox(height: 30),
            const Text(
              'No Devices Added',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const Text(
              'Add your first alarm device to get started',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 16),
            ),
            const SizedBox(height: 40),
            _buildSetupInstructions(),
          ],
        ),
      ),
    );
  }

  Widget _buildSetupInstructions() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        children: [
          _buildSetupStep(
              Icons.qr_code_scanner, 'Scan QR Code', 'on your alarm device'),
          const SizedBox(height: 16),
          _buildSetupStep(
              Icons.bluetooth, 'Connect via Bluetooth', 'pair with the device'),
          const SizedBox(height: 16),
          _buildSetupStep(
              Icons.check_circle, 'Start Controlling', 'your alarm system'),
        ],
      ),
    );
  }

  Widget _buildSetupStep(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: Colors.blue, size: 24),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              Text(subtitle,
                  style:
                  const TextStyle(color: Colors.white54, fontSize: 14)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceList() {
    return RefreshIndicator(
      onRefresh: _loadConnectedDevices,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _connectedDevices.length,
        itemBuilder: (context, index) {
          final device = _connectedDevices[index];
          return _buildDeviceCard(device);
        },
      ),
    );
  }

  Widget _buildDeviceCard(Map<String, dynamic> device) {
    final isOnline = device['status'] == 'online';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () =>
              _connectToDevice(device['device_uuid'], device['device_name']),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isOnline
                    ? [const Color(0xFF2D2D2D), const Color(0xFF1E3A1E)]
                    : [const Color(0xFF2D2D2D), const Color(0xFF3A2D1E)],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isOnline ? Colors.green : Colors.orange,
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color:
                  (isOnline ? Colors.green : Colors.orange).withOpacity(0.2),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Row(
              children: [
                // Device Icon
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: isOnline
                        ? Colors.green.withOpacity(0.2)
                        : Colors.orange.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.security,
                    color: isOnline ? Colors.green : Colors.orange,
                    size: 32,
                  ),
                ),

                const SizedBox(width: 16),

                // Device Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device['device_name'] ?? 'Unknown Device',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
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
                      const SizedBox(height: 6),
                      Text(
                        'Last seen: ${_formatDate(device['last_seen'])}',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),

                // ✅ NEW: Delete icon button on the right
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Navigate arrow
                    const Icon(Icons.arrow_forward_ios,
                        color: Colors.white54, size: 18),
                    const SizedBox(height: 12),
                    // Delete button
                    GestureDetector(
                      onTap: () => _deleteDevice(device),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.red.withOpacity(0.4), width: 1),
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

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr == 'Unknown') return 'Never';

    try {
      final date = DateTime.parse(dateStr);
      final now = DateTime.now();
      final difference = now.difference(date);

      if (difference.inMinutes < 1) return 'Just now';
      if (difference.inHours < 1) return '${difference.inMinutes}m ago';
      if (difference.inDays < 1) return '${difference.inHours}h ago';
      if (difference.inDays < 7) return '${difference.inDays}d ago';

      return '${date.day}/${date.month}/${date.year}';
    } catch (e) {
      return 'Unknown';
    }
  }

  void _addNewDevice() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => QRScanScreen()),
    ).then((_) => _loadConnectedDevices());
  }

  Future<void> _connectToDevice(String deviceUuid, String deviceName) async {
    final settingsManager = SettingsManager();

    await settingsManager.setConnectedDeviceUuid(deviceUuid);
    await settingsManager.setDeviceName(deviceName);
    await settingsManager.setFirstTimeSetup(false);

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => HomeScreen()),
      );
    }
  }
}