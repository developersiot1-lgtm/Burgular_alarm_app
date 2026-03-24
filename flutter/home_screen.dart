import 'package:alarm/alarm_system.dart';
import 'package:alarm/api_service.dart';
import 'package:alarm/control_button.dart';
import 'package:alarm/settings_screen.dart';
import 'package:alarm/splash_screen.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'qr_scan_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Accessory model
// ─────────────────────────────────────────────────────────────────────────────
enum AccessoryType { remote, motion, door }

class Accessory {
  final String id;
  final String name;
  final String zone;
  final AccessoryType type;
  // For remote: which mode was paired ('armed' or 'disarmed')
  final String? remoteMode;

  Accessory({
    required this.id,
    required this.name,
    required this.zone,
    required this.type,
    this.remoteMode,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// HomeScreen
// ─────────────────────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late AnimationController _alarmAnimationController;
  late Animation<double> _alarmAnimation;
  ApiService? apiService;

  List<Accessory> _accessories = [];
  bool _isLogExpanded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    apiService = Provider.of<ApiService>(context, listen: false);
  }

  @override
  void initState() {
    super.initState();
    _alarmAnimationController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _alarmAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _alarmAnimationController, curve: Curves.easeInOut),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (apiService != null) {
        final alarmSystem =
        Provider.of<AlarmSystemProvider>(context, listen: false);
        final info = await DeviceInfoPlugin().androidInfo;
        final deviceUuid = info.id;
        alarmSystem.initialize(apiService!, deviceUuid: deviceUuid);
        _registerCurrentDevice();
      }
    });
  }

  Future<void> _registerCurrentDevice() async {
    if (apiService == null) return;
    final info = await DeviceInfoPlugin().androidInfo;
    try {
      await apiService!.registerMobileDevice(info.id, 'My Device', '{}');
    } catch (e) {
      print('Device registration failed: $e');
    }
  }

  @override
  void dispose() {
    _alarmAnimationController.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => SplashScreen()),
    );
    return false;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('BURGLAR ALARM SYSTEM',
              style: TextStyle(letterSpacing: 1.2)),
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _onWillPop,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.add, size: 28),
              tooltip: 'Add Device',
              onPressed: () {
                Navigator.push(
                    context, MaterialPageRoute(builder: (_) => QRScanScreen()));
              },
            ),
            IconButton(
              icon: const Icon(Icons.settings, size: 26),
              tooltip: 'Settings',
              onPressed: () {
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()));
              },
            ),
            Consumer<AlarmSystemProvider>(
              builder: (_, alarm, __) {
                return IconButton(
                  icon: alarm.isLoading
                      ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                      : const Icon(Icons.refresh),
                  onPressed: alarm.isLoading ? null : alarm.loadData,
                );
              },
            ),
          ],
        ),
        body: Consumer<AlarmSystemProvider>(
          builder: (context, alarmSystem, child) {
            if (alarmSystem.currentState == SystemState.alarm) {
              _alarmAnimationController.repeat(reverse: true);
            } else {
              _alarmAnimationController.stop();
              _alarmAnimationController.reset();
            }

            return RefreshIndicator(
              onRefresh: alarmSystem.loadData,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildStatusCard(alarmSystem),
                    const SizedBox(height: 20),
                    _buildControlPanel(alarmSystem),
                    const SizedBox(height: 20),
                    _buildActivityLogSection(alarmSystem),
                    const SizedBox(height: 20),
                    _buildAccessoriesSection(),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STATUS CARD
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildStatusCard(AlarmSystemProvider alarmSystem) {
    return AnimatedBuilder(
      animation: _alarmAnimation,
      builder: (_, child) {
        return Card(
          color: alarmSystem.currentState == SystemState.alarm
              ? Color.lerp(
              const Color(0xFF2D2D2D), Colors.red, _alarmAnimation.value)
              : const Color(0xFF2D2D2D),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: alarmSystem.stateColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      alarmSystem.stateDisplayName,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: alarmSystem.stateColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Last Updated: ${DateFormat('MMM dd, HH:mm').format(DateTime.now())}',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                if (alarmSystem.error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Error: ${alarmSystem.error}',
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CONTROL PANEL
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildControlPanel(AlarmSystemProvider alarmSystem) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
      childAspectRatio: 1.3,
      children: [
        ControlButton(
          title: 'ON',
          icon: Icons.lock,
          color: Colors.green,
          isActive: alarmSystem.currentState == SystemState.armed,
          onPressed: () => alarmSystem.changeSystemState(SystemState.armed),
        ),
        ControlButton(
          title: 'OFF',
          icon: Icons.lock_open,
          color: Colors.red,
          isActive: alarmSystem.currentState == SystemState.disarmed,
          onPressed: () => alarmSystem.changeSystemState(SystemState.disarmed),
        ),
        ControlButton(
          title: 'ALARM',
          icon: Icons.warning,
          color: Colors.red,
          isActive: alarmSystem.currentState == SystemState.alarm,
          onPressed: () => alarmSystem.changeSystemState(SystemState.alarm),
        ),
        ControlButton(
          title: 'RESET',
          icon: Icons.restore,
          color: Colors.orange,
          isActive: alarmSystem.currentState == SystemState.stayArmed,
          onPressed: () => alarmSystem.changeSystemState(SystemState.stayArmed),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ACTIVITY LOG
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildActivityLogSection(AlarmSystemProvider alarmSystem) {
    final logs = alarmSystem.activityLogs;
    final displayLogs =
    _isLogExpanded ? logs : (logs.isNotEmpty ? [logs.first] : []);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () {
                if (logs.isNotEmpty) {
                  setState(() => _isLogExpanded = !_isLogExpanded);
                }
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Recent Activity',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white),
                  ),
                  Icon(
                      _isLogExpanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: Colors.white),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (logs.isEmpty)
              const Text('No recent activity',
                  style: TextStyle(color: Colors.white70)),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: displayLogs.length,
              separatorBuilder: (_, i) =>
              const Divider(color: Colors.white24, height: 1),
              itemBuilder: (ctx, i) {
                final log = displayLogs[i];
                return ListTile(
                  leading: const Icon(Icons.history, color: Colors.white70),
                  title: Text(log.event,
                      style:
                      const TextStyle(color: Colors.white, fontSize: 14)),
                  subtitle: Text(
                    '${log.device} • ${DateFormat('MMM dd, HH:mm').format(DateTime.parse(log.timestamp))}',
                    style:
                    const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ACCESSORIES SECTION
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildAccessoriesSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Accessories',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                IconButton(
                  icon: const Icon(Icons.add, color: Colors.blue),
                  onPressed: _showAddAccessoryTypeSheet,
                ),
              ],
            ),
            const SizedBox(height: 4),

            // 3 accessory type tiles (always visible as quick-add)
            _buildAccessoryTypeTile(
              icon: Icons.settings_remote,
              label: 'Remote Sensor',
              color: Colors.purple,
              onTap: () => _showRemoteModeSheet(),
            ),
            _buildAccessoryTypeTile(
              icon: Icons.directions_walk,
              label: 'Motion Sensor',
              color: Colors.orange,
              onTap: () => _showPairingDialog(AccessoryType.motion),
            ),
            _buildAccessoryTypeTile(
              icon: Icons.door_front_door,
              label: 'Door Sensor',
              color: Colors.teal,
              onTap: () => _showPairingDialog(AccessoryType.door),
            ),

            // Divider only when there are paired accessories
            if (_accessories.isNotEmpty) ...[
              const Divider(color: Colors.white24, height: 24),
              const Text('Paired Accessories',
                  style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _accessories.length,
                itemBuilder: (ctx, i) => _buildPairedTile(_accessories[i], i),
              ),
            ] else
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('No accessories paired yet',
                    style: TextStyle(color: Colors.grey, fontSize: 13)),
              ),
          ],
        ),
      ),
    );
  }

  // Small row tile for the three type buttons
  Widget _buildAccessoryTypeTile({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: color,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ),
            Icon(Icons.chevron_right, color: color.withOpacity(0.6)),
          ],
        ),
      ),
    );
  }

  // Tile for an already-paired accessory
  Widget _buildPairedTile(Accessory acc, int index) {
    IconData icon;
    Color color;
    String subtitle;

    switch (acc.type) {
      case AccessoryType.remote:
        icon = Icons.settings_remote;
        color = Colors.purple;
        subtitle = 'Remote • Mode: ${acc.remoteMode ?? "-"} • ${acc.zone}';
        break;
      case AccessoryType.motion:
        icon = Icons.directions_walk;
        color = Colors.orange;
        subtitle = 'Motion Sensor • ${acc.zone}';
        break;
      case AccessoryType.door:
        icon = Icons.door_front_door;
        color = Colors.teal;
        subtitle = 'Door Sensor • ${acc.zone}';
        break;
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: color.withOpacity(0.15),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(acc.name,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
        onPressed: () => setState(() => _accessories.removeAt(index)),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SHOW TYPE SHEET  (the + button at top right of Accessories)
  // ─────────────────────────────────────────────────────────────────────────
  void _showAddAccessoryTypeSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF2D2D2D),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text('Select Accessory Type',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const Divider(color: Colors.white24),
            ListTile(
              leading:
              const Icon(Icons.settings_remote, color: Colors.purple),
              title: const Text('Remote Sensor',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showRemoteModeSheet();
              },
            ),
            ListTile(
              leading:
              const Icon(Icons.directions_walk, color: Colors.orange),
              title: const Text('Motion Sensor',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showPairingDialog(AccessoryType.motion);
              },
            ),
            ListTile(
              leading:
              const Icon(Icons.door_front_door, color: Colors.teal),
              title: const Text('Door Sensor',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showPairingDialog(AccessoryType.door);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // REMOTE: show Armed / Disarmed choice first
  // ─────────────────────────────────────────────────────────────────────────
  void _showRemoteModeSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF2D2D2D),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Icon(Icons.settings_remote, color: Colors.purple, size: 36),
            const SizedBox(height: 8),
            const Text('Remote Sensor',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('Which button do you want to pair?',
                style: TextStyle(color: Colors.white60, fontSize: 13)),
            const Divider(color: Colors.white24, height: 20),
            ListTile(
              leading: const Icon(Icons.lock, color: Colors.green),
              title: const Text('Armed',
                  style: TextStyle(
                      color: Colors.green, fontWeight: FontWeight.w600)),
              subtitle: const Text('Pair the ARMED button on the remote',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () {
                Navigator.pop(context);
                _showPairingDialog(AccessoryType.remote, remoteMode: 'armed');
              },
            ),
            ListTile(
              leading: const Icon(Icons.lock_open, color: Colors.red),
              title: const Text('Disarmed',
                  style: TextStyle(
                      color: Colors.red, fontWeight: FontWeight.w600)),
              subtitle: const Text('Pair the DISARMED button on the remote',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () {
                Navigator.pop(context);
                _showPairingDialog(AccessoryType.remote,
                    remoteMode: 'disarmed');
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PAIRING DIALOG  (motion, door, and remote after mode is chosen)
  // ─────────────────────────────────────────────────────────────────────────
  void _showPairingDialog(AccessoryType type, {String? remoteMode}) {
    String nameInput = '';
    String zoneInput = '';

    String title;
    IconData icon;
    Color color;

    switch (type) {
      case AccessoryType.remote:
        title =
        'Pair Remote (${remoteMode == 'armed' ? 'Armed' : 'Disarmed'})';
        icon = Icons.settings_remote;
        color = Colors.purple;
        break;
      case AccessoryType.motion:
        title = 'Pair Motion Sensor';
        icon = Icons.directions_walk;
        color = Colors.orange;
        break;
      case AccessoryType.door:
        title = 'Pair Door Sensor';
        icon = Icons.door_front_door;
        color = Colors.teal;
        break;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 10),
            Expanded(
                child: Text(title,
                    style: const TextStyle(color: Colors.white, fontSize: 16))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Pairing animation indicator
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(color)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      type == AccessoryType.remote
                          ? 'Press the ${remoteMode == 'armed' ? 'ARMED' : 'DISARMED'} button on your remote now…'
                          : type == AccessoryType.motion
                          ? 'Trigger the motion sensor once…'
                          : 'Open/close the door sensor once…',
                      style:
                      TextStyle(color: color, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Sensor Name',
                labelStyle: const TextStyle(color: Colors.white54),
                hintText: 'e.g. Living Room Remote',
                hintStyle: const TextStyle(color: Colors.white30),
                enabledBorder: OutlineInputBorder(
                    borderSide:
                    BorderSide(color: color.withOpacity(0.4)),
                    borderRadius: BorderRadius.circular(8)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: color),
                    borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: (v) => nameInput = v,
            ),
            const SizedBox(height: 12),
            TextField(
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Zone (optional)',
                labelStyle: const TextStyle(color: Colors.white54),
                hintText: 'e.g. Entry, Bedroom',
                hintStyle: const TextStyle(color: Colors.white30),
                enabledBorder: OutlineInputBorder(
                    borderSide:
                    BorderSide(color: color.withOpacity(0.4)),
                    borderRadius: BorderRadius.circular(8)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: color),
                    borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: (v) => zoneInput = v,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
            const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.bluetooth_searching, size: 16),
            label: const Text('Pair'),
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              final name =
              nameInput.trim().isEmpty ? _defaultName(type) : nameInput.trim();
              final zone =
              zoneInput.trim().isEmpty ? 'General' : zoneInput.trim();

              Navigator.pop(ctx);

              // Save to database
              await _savePairedAccessoryToDb(
                name: name,
                zone: zone,
                type: type,
                remoteMode: remoteMode,
              );

              // Update local list
              setState(() {
                _accessories.add(Accessory(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: name,
                  zone: zone,
                  type: type,
                  remoteMode: remoteMode,
                ));
              });

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content:
                  Text('✅ $name paired successfully'),
                  backgroundColor: color,
                ));
              }
            },
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Save paired accessory to server (device_registry / device_settings)
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _savePairedAccessoryToDb({
    required String name,
    required String zone,
    required AccessoryType type,
    String? remoteMode,
  }) async {
    if (apiService == null) return;

    try {
      // Derive a unique UUID for this sensor based on name + timestamp
      final sensorUuid =
          'sensor_${type.name}_${DateTime.now().millisecondsSinceEpoch}';

      // Register sensor in device_registry
      await apiService!.deviceRegister(
        deviceUuid: sensorUuid,
        deviceName: name,
        deviceType: _accessoryTypeToString(type),
        connectionType: 'bluetooth',
        zoneName: zone,
        capabilities: {
          'sensor_type': type.name,
          if (remoteMode != null) 'remote_mode': remoteMode,
          'zone': zone,
          'paired_at': DateTime.now().toIso8601String(),
        },
      );

      print('✅ Accessory saved to DB: $name ($sensorUuid)');
    } catch (e) {
      print('❌ Failed to save accessory to DB: $e');
    }
  }

  String _accessoryTypeToString(AccessoryType type) {
    switch (type) {
      case AccessoryType.remote:
        return 'remote';
      case AccessoryType.motion:
        return 'motion';
      case AccessoryType.door:
        return 'door';
    }
  }

  String _defaultName(AccessoryType type) {
    switch (type) {
      case AccessoryType.remote:
        return 'Remote Sensor';
      case AccessoryType.motion:
        return 'Motion Sensor';
      case AccessoryType.door:
        return 'Door Sensor';
    }
  }
}