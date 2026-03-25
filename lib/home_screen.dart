import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:alarm/alarm_system.dart';
import 'package:alarm/api_service.dart';
import 'package:alarm/control_button.dart';
import 'package:alarm/settings_screen.dart';
import 'package:alarm/splash_screen.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;           // ✅ ADDED — needed by _notifyHubToStartPairing
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'qr_scan_screen.dart';
import 'settings_manager.dart';

// =============================================================================
// ACCESSORY STATUS ENUM
// =============================================================================
enum AccessoryStatus { pairing, paired, failed, timeout }

// =============================================================================
// ACCESSORY MODEL
// =============================================================================
enum AccessoryType { remote, motion, door }

class Accessory {
  final String id;
  final String name;
  final String deviceName;
  final String zone;
  final AccessoryType type;
  final String? remoteMode;
  final AccessoryStatus status;
  final int? pairingId;

  Accessory({
    required this.id,
    required this.name,
    required this.deviceName,
    required this.zone,
    required this.type,
    this.remoteMode,
    this.status = AccessoryStatus.pairing,
    this.pairingId,
  });

  Map<String, dynamic> toJson() => {
    'id':         id,
    'name':       name,
    'deviceName': deviceName,
    'zone':       zone,
    'type':       type.name,
    'remoteMode': remoteMode,
    'status':     status.name,
    'pairingId':  pairingId,
  };

  factory Accessory.fromLocalJson(Map<String, dynamic> j) {
    AccessoryType t;
    switch (j['type']) {
      case 'motion': t = AccessoryType.motion; break;
      case 'door':   t = AccessoryType.door;   break;
      default:       t = AccessoryType.remote;
    }
    AccessoryStatus s;
    switch (j['status']) {
      case 'paired':  s = AccessoryStatus.paired;  break;
      case 'failed':  s = AccessoryStatus.failed;  break;
      case 'timeout': s = AccessoryStatus.timeout; break;
      default:        s = AccessoryStatus.pairing;
    }
    return Accessory(
      id:         j['id']         ?? '',
      name:       j['name']       ?? 'Sensor',
      deviceName: j['deviceName'] ?? j['name'] ?? 'Sensor',
      zone:       j['zone']       ?? 'General',
      type:       t,
      remoteMode: j['remoteMode'],
      status:     s,
      pairingId:  j['pairingId'],
    );
  }

  factory Accessory.fromServerJson(Map<String, dynamic> j) {
    AccessoryType t;
    switch (j['accessory_type'] ?? j['type']) {
      case 'motion': t = AccessoryType.motion; break;
      case 'door':   t = AccessoryType.door;   break;
      default:       t = AccessoryType.remote;
    }
    AccessoryStatus s;
    switch (j['status']) {
      case 'paired':  s = AccessoryStatus.paired;  break;
      case 'failed':  s = AccessoryStatus.failed;  break;
      default:        s = AccessoryStatus.pairing;
    }
    return Accessory(
      id:         j['accessory_uuid'] ?? j['id'] ?? '',
      name:       j['accessory_name'] ?? j['name'] ?? 'Sensor',
      deviceName: j['device_ble_name'] ?? j['deviceName'] ?? 'Sensor',
      zone:       j['zone_name']       ?? j['zone'] ?? 'General',
      type:       t,
      remoteMode: j['remote_mode'] ?? j['remoteMode'],
      status:     s,
      pairingId:  j['id'] is int ? j['id'] : int.tryParse(j['id']?.toString() ?? ''),
    );
  }

  Accessory copyWith({
    String? id, String? name, String? deviceName, String? zone,
    AccessoryType? type, String? remoteMode,
    AccessoryStatus? status, int? pairingId,
  }) => Accessory(
    id:         id         ?? this.id,
    name:       name       ?? this.name,
    deviceName: deviceName ?? this.deviceName,
    zone:       zone       ?? this.zone,
    type:       type       ?? this.type,
    remoteMode: remoteMode ?? this.remoteMode,
    status:     status     ?? this.status,
    pairingId:  pairingId  ?? this.pairingId,
  );
}

// =============================================================================
// LOCAL ACCESSORY STORAGE
// =============================================================================
class AccessoryStorage {
  static const String _key = 'local_accessories';

  static Future<List<Accessory>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return [];
      final list  = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Accessory.fromLocalJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      print('⚠️ AccessoryStorage.load error: $e');
      return [];
    }
  }

  static Future<void> save(List<Accessory> accessories) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = jsonEncode(accessories.map((a) => a.toJson()).toList());
      await prefs.setString(_key, raw);
      print('✅ Accessories saved locally (${accessories.length} items)');
    } catch (e) {
      print('⚠️ AccessoryStorage.save error: $e');
    }
  }

  static Future<void> remove(String accessoryId) async {
    final list = await load();
    list.removeWhere((a) => a.id == accessoryId);
    await save(list);
  }

  static Future<void> update(Accessory updated) async {
    final list = await load();
    final idx  = list.indexWhere((a) => a.id == updated.id);
    if (idx >= 0) {
      list[idx] = updated;
    } else {
      list.add(updated);
    }
    await save(list);
  }
}

// =============================================================================
// HOME SCREEN
// =============================================================================
class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late AnimationController _alarmAnimationController;
  late Animation<double>   _alarmAnimation;
  ApiService? _apiService;
  String?     _hubDeviceUuid;

  List<Accessory> _accessories        = [];
  bool            _isLogExpanded      = false;
  bool            _accessoriesLoading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _apiService = Provider.of<ApiService>(context, listen: false);
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
      if (_apiService != null) {
        final alarmSystem =
        Provider.of<AlarmSystemProvider>(context, listen: false);
        final info       = await DeviceInfoPlugin().androidInfo;
        final deviceUuid = info.id;
        alarmSystem.initialize(_apiService!, deviceUuid: deviceUuid);
        _registerCurrentMobileDevice(deviceUuid);

        final settings = SettingsManager();
        _hubDeviceUuid  = settings.connectedDeviceUuid;
        _loadAccessories();
      }
    });
  }

  Future<void> _registerCurrentMobileDevice(String deviceUuid) async {
    if (_apiService == null) return;
    try {
      await _apiService!.registerMobileDevice(deviceUuid, 'My Device', '{}');
    } catch (e) {
      print('❌ Mobile device registration failed: $e');
    }
  }

  Future<void> _loadAccessories() async {
    setState(() => _accessoriesLoading = true);
    try {
      final local = await AccessoryStorage.load();
      if (mounted) setState(() => _accessories = local);

      if (_hubDeviceUuid != null && _hubDeviceUuid!.isNotEmpty && _apiService != null) {
        final serverList = await _apiService!.accessoryList(_hubDeviceUuid!);
        if (serverList.isNotEmpty) {
          final parsed = serverList
              .map((s) => Accessory.fromServerJson(Map<String, dynamic>.from(s)))
              .toList();
          await AccessoryStorage.save(parsed);
          if (mounted) setState(() => _accessories = parsed);
          print('✅ Synced ${parsed.length} accessories from server');
        }
      }
    } catch (e) {
      print('❌ Load accessories error: $e');
    } finally {
      if (mounted) setState(() => _accessoriesLoading = false);
    }
  }

  @override
  void dispose() {
    _alarmAnimationController.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => SplashScreen()));
    return false;
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================
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
              icon: const Icon(Icons.arrow_back), onPressed: _onWillPop),
          actions: [
            IconButton(
              icon: const Icon(Icons.add, size: 28),
              tooltip: 'Add Device',
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => QRScanScreen())),
            ),
            IconButton(
              icon: const Icon(Icons.settings, size: 26),
              tooltip: 'Settings',
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen())),
            ),
            Consumer<AlarmSystemProvider>(
              builder: (_, alarm, __) => IconButton(
                icon: alarm.isLoading
                    ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.refresh),
                onPressed: alarm.isLoading ? null : alarm.loadData,
              ),
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
              onRefresh: () async {
                await alarmSystem.loadData();
                await _loadAccessories();
              },
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

  // ===========================================================================
  // STATUS CARD
  // ===========================================================================
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
                      width: 16, height: 16,
                      decoration: BoxDecoration(
                          color: alarmSystem.stateColor,
                          shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      alarmSystem.stateDisplayName,
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: alarmSystem.stateColor),
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
                        borderRadius: BorderRadius.circular(8)),
                    child: Text('Error: ${alarmSystem.error}',
                        style: const TextStyle(
                            color: Colors.red, fontSize: 12)),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // CONTROL PANEL
  // ===========================================================================
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
          onPressed: () =>
              alarmSystem.changeSystemState(SystemState.disarmed),
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
          onPressed: () =>
              alarmSystem.changeSystemState(SystemState.stayArmed),
        ),
      ],
    );
  }

  // ===========================================================================
  // ACTIVITY LOG
  // ===========================================================================
  Widget _buildActivityLogSection(AlarmSystemProvider alarmSystem) {
    final logs        = alarmSystem.activityLogs;
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
                  const Text('Recent Activity',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white)),
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
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14)),
                  subtitle: Text(
                    '${log.device} • ${DateFormat('MMM dd, HH:mm').format(DateTime.parse(log.timestamp))}',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // ACCESSORIES SECTION
  // ===========================================================================
  Widget _buildAccessoriesSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Accessories',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                Row(
                  children: [
                    if (_accessoriesLoading)
                      const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    IconButton(
                      icon: const Icon(Icons.add, color: Colors.blue),
                      onPressed: _showAddAccessoryTypeSheet,
                    ),
                  ],
                ),
              ],
            ),
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
              onTap: () => _showPairingScreen(AccessoryType.motion),
            ),
            _buildAccessoryTypeTile(
              icon: Icons.door_front_door,
              label: 'Door Sensor',
              color: Colors.teal,
              onTap: () => _showPairingScreen(AccessoryType.door),
            ),
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
                itemBuilder: (ctx, i) =>
                    _buildPairedTile(_accessories[i], i),
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

  Widget _buildPairedTile(Accessory acc, int index) {
    IconData icon;
    Color    color;
    String   subtitle;

    switch (acc.type) {
      case AccessoryType.remote:
        icon     = Icons.settings_remote;
        color    = Colors.purple;
        subtitle = 'Remote • Mode: ${acc.remoteMode ?? "-"} • ${acc.zone}';
        break;
      case AccessoryType.motion:
        icon     = Icons.directions_walk;
        color    = Colors.orange;
        subtitle = 'Motion Sensor • ${acc.zone}';
        break;
      case AccessoryType.door:
        icon     = Icons.door_front_door;
        color    = Colors.teal;
        subtitle = 'Door Sensor • ${acc.zone}';
        break;
    }

    Color  statusColor;
    String statusLabel;
    switch (acc.status) {
      case AccessoryStatus.paired:
        statusColor = Colors.green;  statusLabel = 'PAIRED';   break;
      case AccessoryStatus.failed:
        statusColor = Colors.red;    statusLabel = 'FAILED';   break;
      case AccessoryStatus.timeout:
        statusColor = Colors.red;    statusLabel = 'TIMEOUT';  break;
      case AccessoryStatus.pairing:
      default:
        statusColor = Colors.orange; statusLabel = 'PAIRING…'; break;
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: color.withOpacity(0.15),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Row(children: [
        Expanded(
          child: Text(acc.name,
              style: const TextStyle(color: Colors.white, fontSize: 14)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.2),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: statusColor, width: 1),
          ),
          child: Text(statusLabel,
              style: TextStyle(
                  color: statusColor,
                  fontSize: 10,
                  fontWeight: FontWeight.bold)),
        ),
      ]),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          if (acc.deviceName.isNotEmpty && acc.deviceName != acc.name)
            Text('Device: ${acc.deviceName}',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
        onPressed: () => _deleteAccessory(acc, index),
      ),
    );
  }

  Future<void> _deleteAccessory(Accessory acc, int index) async {
    setState(() => _accessories.removeAt(index));
    await AccessoryStorage.remove(acc.id);
    if (_apiService != null) {
      try { await _apiService!.accessoryDelete(acc.id); } catch (_) {}
    }
    print('✅ Accessory removed: ${acc.name}');
  }

  // ===========================================================================
  // BOTTOM SHEETS
  // ===========================================================================
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
              leading: const Icon(Icons.settings_remote, color: Colors.purple),
              title: const Text('Remote Sensor',
                  style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); _showRemoteModeSheet(); },
            ),
            ListTile(
              leading: const Icon(Icons.directions_walk, color: Colors.orange),
              title: const Text('Motion Sensor',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showPairingScreen(AccessoryType.motion);
              },
            ),
            ListTile(
              leading: const Icon(Icons.door_front_door, color: Colors.teal),
              title: const Text('Door Sensor',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showPairingScreen(AccessoryType.door);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

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
                _showPairingScreen(AccessoryType.remote, remoteMode: 'armed');
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
                _showPairingScreen(AccessoryType.remote, remoteMode: 'disarmed');
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // OPEN PAIRING DIALOG
  // ===========================================================================
  void _showPairingScreen(AccessoryType type, {String? remoteMode}) {
    final nameCtrl = TextEditingController();
    final zoneCtrl = TextEditingController();

    String   typeLabel, instructions;
    IconData typeIcon;
    Color    typeColor;

    switch (type) {
      case AccessoryType.remote:
        typeLabel    = 'Remote (${remoteMode == 'armed' ? 'Armed' : 'Disarmed'})';
        typeIcon     = Icons.settings_remote;
        typeColor    = Colors.purple;
        instructions = 'Power on the remote and press the '
            '${remoteMode == 'armed' ? 'ARMED' : 'DISARMED'} button.';
        break;
      case AccessoryType.motion:
        typeLabel    = 'Motion Sensor';
        typeIcon     = Icons.directions_walk;
        typeColor    = Colors.orange;
        instructions = 'Power on the motion sensor and keep it close.';
        break;
      case AccessoryType.door:
        typeLabel    = 'Door Sensor';
        typeIcon     = Icons.door_front_door;
        typeColor    = Colors.teal;
        instructions = 'Power on the door sensor and keep it close.';
        break;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PairingDialog(
        type:           type,
        typeLabel:      typeLabel,
        typeIcon:       typeIcon,
        typeColor:      typeColor,
        instructions:   instructions,
        remoteMode:     remoteMode,
        nameController: nameCtrl,
        zoneController: zoneCtrl,
        hubDeviceUuid:  _hubDeviceUuid ?? '',
        apiService:     _apiService,
        onPaired: (accessory) async {
          final idx = _accessories.indexWhere((a) => a.id == accessory.id);
          if (idx >= 0) {
            setState(() => _accessories[idx] = accessory);
          } else {
            setState(() => _accessories.add(accessory));
          }
          await AccessoryStorage.save(_accessories);
          print('✅ Accessory saved locally: ${accessory.name} '
              'status=${accessory.status.name}');
        },
      ),
    );
  }
}

// =============================================================================
// PAIRING DIALOG
// =============================================================================
class _PairingDialog extends StatefulWidget {
  final AccessoryType type;
  final String        typeLabel;
  final IconData      typeIcon;
  final Color         typeColor;
  final String        instructions;
  final String?       remoteMode;
  final TextEditingController nameController;
  final TextEditingController zoneController;
  final String        hubDeviceUuid;
  final ApiService?   apiService;
  final void Function(Accessory) onPaired;

  const _PairingDialog({
    required this.type,
    required this.typeLabel,
    required this.typeIcon,
    required this.typeColor,
    required this.instructions,
    required this.remoteMode,
    required this.nameController,
    required this.zoneController,
    required this.hubDeviceUuid,
    required this.apiService,
    required this.onPaired,
  });

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  static const String _svcUuid    = '703de63c-1c78-703d-e63c-1a42b93437e2';
  static const String _writeUuid  = '703de63c-1c78-703d-e63c-1a42b93437e3';
  static const String _notifyUuid = '703de63c-1c78-703d-e63c-1a42b93437e4';
  static const int    _totalSec   = 30;
  static const String _buildTag   = 'HUB BLE PATCH 24MAR';

  int    _secondsLeft    = _totalSec;
  bool   _isPairing      = false;
  bool   _pairingDone    = false;
  bool   _pairingSuccess = false;
  String _statusMsg      = '';
  bool   _triedConnect   = false;

  String? _pairedMac;
  String? _pairedBleName;
  int?    _pairingId;
  bool    _hubAckOnly = false;

  Timer?                                _timer;
  StreamSubscription<List<ScanResult>>? _scanSub;
  BluetoothDevice?                      _currentDevice;

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  Future<void> _cleanup() async {
    _timer?.cancel();
    await _scanSub?.cancel();
    try { await FlutterBluePlus.stopScan(); } catch (_) {}
    try { await _currentDevice?.disconnect(); } catch (_) {}
  }

  // ===========================================================================
  // STEP 1 — POST pairing record to server
  // ===========================================================================
  bool _looksLikeHubResult(ScanResult result) {
    final advName = result.device.platformName.isNotEmpty
        ? result.device.platformName
        : result.advertisementData.advName;
    if (advName.toLowerCase().contains('esp32_alarm_setup')) {
      return true;
    }

    for (final serviceUuid in result.advertisementData.serviceUuids) {
      if (serviceUuid.toString().toLowerCase() == _svcUuid) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _connectToHubBle() async {
    try {
      await _scanSub?.cancel();
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    _triedConnect = false;
    final completer = Completer<bool>();

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    } catch (e) {
      print('?? Hub BLE scan start failed: $e');
      return false;
    }

    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      if (!_isPairing || _pairingDone || _triedConnect || completer.isCompleted) {
        return;
      }

      for (final r in results) {
        if (_triedConnect || _pairingDone || completer.isCompleted) break;
        if (!_looksLikeHubResult(r)) continue;

        final advName = r.device.platformName.isNotEmpty
            ? r.device.platformName
            : r.advertisementData.advName;

        _triedConnect = true;
        if (mounted) {
          setState(() => _statusMsg = 'Found hub "$advName" - connecting...');
        }

        final ok = await _tryConnectAndVerify(r.device, advName);
        if (!completer.isCompleted) {
          completer.complete(ok);
        }
        break;
      }
    });

    try {
      return await completer.future.timeout(const Duration(seconds: 12), onTimeout: () => false);
    } finally {
      try {
        await _scanSub?.cancel();
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
  }
  Future<int?> _createServerPairingRecord(String tempUuid) async {
    if (widget.apiService == null || widget.hubDeviceUuid.isEmpty) return null;
    try {
      final result = await widget.apiService!.accessoryPair(
        hubDeviceUuid: widget.hubDeviceUuid,
        accessoryUuid: tempUuid,
        name:          widget.nameController.text.trim(),
        type:          widget.type.name,
        zoneName:      widget.zoneController.text.trim().isEmpty
            ? 'General'
            : widget.zoneController.text.trim(),
        remoteMode:    widget.remoteMode,
        status:        'pairing',
      );
      if (result != null && result['success'] == true) {
        final id = result['id'];
        print('✅ Server pairing record created. pairingId=$id');
        return id is int ? id : int.tryParse(id?.toString() ?? '');
      }
    } catch (e) {
      print('⚠️ Server pairing record error (non-fatal): $e');
    }
    return null;
  }

  // ===========================================================================
  // STEP 2 — Notify hub + BLE scan
  // ===========================================================================
  Future<void> _startPairing() async {
    final name = widget.nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please enter a sensor name first'),
          backgroundColor: Colors.orange));
      return;
    }

    final tempUuid =
        'pairing_${widget.type.name}_${DateTime.now().millisecondsSinceEpoch}';

    setState(() {
      _isPairing      = true;
      _pairingDone    = false;
      _pairingSuccess = false;
      _secondsLeft    = _totalSec;
      _statusMsg      = 'Saving pairing request…';
      _pairedMac      = null;
      _pairedBleName  = null;
      _pairingId      = null;
      _triedConnect   = false;
    });

    // ── STEP 1: Create DB record ──────────────────────────────────────────────
    _pairingId = await _createServerPairingRecord(tempUuid);

    // ── STEP 2: Notify hub immediately ───────────────────────────────────────
    if (mounted) setState(() => _statusMsg = 'Notifying hub to start pairing…');
    final hubNotified = await _notifyHubToStartPairing();

    if (mounted) {
      setState(() => _statusMsg = hubNotified
          ? 'Hub notified ✓ — waiting for ${_sensorLabel()} to respond…'
          : 'Scanning for ${_sensorLabel()}…');
    }

    // STEP 3: Send pair_request to hub BLE
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        t.cancel();
        if (!_pairingDone) _finishPairing(success: false, reason: 'timeout');
      }
    });

    if (mounted) {
      setState(() => _statusMsg = 'Connecting to hub Bluetooth...');
    }

    final hubBleOk = await _connectToHubBle();
    if (!hubBleOk && mounted && !_pairingDone) {
      setState(() => _statusMsg = 'Hub Bluetooth not reachable - still waiting...');
    }
  }

  // ===========================================================================
  // ✅ NEW — Notify hub to start pairing mode
  //
  // POSTs this JSON to the server so the ESP32 hub picks it up on next poll:
  // {
  //   "state":           "pairing_started",
  //   "device_uuid":     "ESP32_ALARM_001",
  //   "accessory_type":  "door",          ← "door" | "motion" | "remote"
  //   "pairing_id":      42,
  //   "name":            "Front Door",
  //   "zone":            "Entry",
  //   "remote_mode":     null,            ← only present for remote type
  //   "user":            "Mobile App",
  //   "timestamp":       1711234567890
  // }
  //
  // The ESP32 hub firmware should poll system_state OR get_pairing_request
  // and when it sees state="pairing_started", broadcast a BLE advertisement
  // so the sensor auto-connects.
  // ===========================================================================
  Future<bool> _notifyHubToStartPairing() async {
    if (widget.hubDeviceUuid.isEmpty) {
      print('⚠️ No hub UUID — skipping hub notification');
      return false;
    }

    try {
      final payload = <String, dynamic>{
        'state':          'pairing_started',
        'device_uuid':    widget.hubDeviceUuid,
        'accessory_type': widget.type.name,
        'pairing_id':     _pairingId,
        'name':           widget.nameController.text.trim(),
        'zone':           widget.zoneController.text.trim().isEmpty
            ? 'General'
            : widget.zoneController.text.trim(),
        'user':           'Mobile App',
        'timestamp':      DateTime.now().millisecondsSinceEpoch,
      };

      // Only include remote_mode for remote type
      if (widget.remoteMode != null) {
        payload['remote_mode'] = widget.remoteMode;
      }

      print('📤 Notifying hub to start pairing: $payload');

      final response = await http.post(
        Uri.parse('https://monsow.in/alarm/index.php?action=system_state'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 8));

      final ok = response.statusCode == 200;
      print(ok
          ? '✅ Hub notified — pairing_started sent for ${widget.type.name}'
          : '⚠️ Hub notification returned ${response.statusCode}');
      return ok;
    } catch (e) {
      // Non-fatal — BLE scan continues even if hub notification fails
      print('⚠️ Hub notification failed (non-fatal): $e');
      return false;
    }
  }

  // ===========================================================================
  // ✅ NEW — Human-readable sensor label for status messages
  // ===========================================================================
  String _sensorLabel() {
    switch (widget.type) {
      case AccessoryType.door:   return 'door sensor';
      case AccessoryType.motion: return 'motion sensor';
      case AccessoryType.remote: return 'remote';
    }
  }

  // ===========================================================================
  // STEP 3 — Connect, verify, send pair_request JSON, wait for sensor_ack
  // ===========================================================================
  Future<bool> _tryConnectAndVerify(
      BluetoothDevice device, String advName) async {
    _currentDevice = device;
    try {
      await device.connect(
          timeout: const Duration(seconds: 10), autoConnect: false);
      await device.connectionState
          .where((s) => s == BluetoothConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 10));

      final services = await device.discoverServices();

      BluetoothCharacteristic? writeChar;
      BluetoothCharacteristic? notifyChar;

      for (final svc in services) {
        if (svc.uuid.toString().toLowerCase() != _svcUuid) continue;
        for (final ch in svc.characteristics) {
          final u = ch.uuid.toString().toLowerCase();
          if (u == _writeUuid)  writeChar  = ch;
          if (u == _notifyUuid) notifyChar = ch;
        }
      }

      if (writeChar == null) {
        for (final svc in services) {
          for (final ch in svc.characteristics) {
            final u = ch.uuid.toString().toLowerCase();
            if (u.startsWith('00002a') || u == '2b29') continue;
            if (ch.properties.write || ch.properties.writeWithoutResponse) {
              writeChar = ch;
              break;
            }
          }
          if (writeChar != null) break;
        }
      }

      if (writeChar == null) {
        await device.disconnect();
        return false;
      }

      if (notifyChar != null) await notifyChar.setNotifyValue(true);

      // ── Send pair_request JSON to sensor ───────────────────────────────────
      final pairCmd = jsonEncode({
        'cmd':        'pair_request',
        'type':       widget.type.name,
        'name':       widget.nameController.text.trim(),
        'zone':       widget.zoneController.text.trim().isEmpty
            ? 'General'
            : widget.zoneController.text.trim(),
        'hub_uuid':   widget.hubDeviceUuid,
        'pairing_id': _pairingId,
        if (widget.remoteMode != null) 'remote_mode': widget.remoteMode,
        'timestamp':  DateTime.now().millisecondsSinceEpoch,
      });

      if (mounted) {
        setState(() => _statusMsg = 'Waiting for RF sensor signal...');
      }

      final bytes = Uint8List.fromList(utf8.encode(pairCmd));
      const chunkSize = 20;
      for (int i = 0; i < bytes.length; i += chunkSize) {
        final end   = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
        final chunk = bytes.sublist(i, end);
        final useWWR = !writeChar!.properties.write &&
            writeChar.properties.writeWithoutResponse;
        await writeChar.write(chunk, withoutResponse: useWWR);
        await Future.delayed(const Duration(milliseconds: 30));
      }

      // ── Wait for sensor_ack ────────────────────────────────────────────────
      bool    ackOk     = false;
      String? sensorMac;
      String? sensorBle;

      _hubAckOnly = false;
      if (notifyChar != null) {
        try {
          final raw = await notifyChar.lastValueStream
              .where((v) => v.isNotEmpty)
              .first
.timeout(Duration(seconds: _totalSec));
          final ack = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
          final ackType = ack['type']?.toString();
          final ackStatus = ack['status']?.toString() ?? '';
          if (ackType == 'sensor_ack' && ackStatus.isNotEmpty) {
            ackOk = true;
            _hubAckOnly = ackStatus != 'paired';
            if (!_hubAckOnly) {
              sensorMac = ack['mac']?.toString();
              sensorBle = ack['ble_name']?.toString();
            }
            print('? Hub BLE ack: $ack');
          }
        } catch (e) {
          print('?? No sensor_ack from hub: $e');
          ackOk = false;
        }
      }

      if (!ackOk) {
        await device.disconnect();
        return false;
      }

      _pairedMac     = sensorMac ?? device.remoteId.str;
      _pairedBleName = sensorBle ?? advName;

      await device.disconnect();
      _finishPairing(success: true);
      return true;
    } catch (e) {
      print('❌ BLE connect error for $advName: $e');
      try { await device.disconnect(); } catch (_) {}
      return false;
    }
  }

  // ===========================================================================
  // STEP 4 — Update server + save locally
  // ===========================================================================
  void _finishPairing({required bool success, String? reason}) {
    _cleanup();
    if (!mounted) return;
    setState(() {
      _isPairing      = false;
      _pairingDone    = true;
      _pairingSuccess = success;
      _statusMsg = success
          ? (_hubAckOnly
              ? 'Hub accepted pairing request.'
              : 'Sensor paired via Bluetooth!')
          : reason == 'timeout'
          ? 'No sensor found within $_totalSec seconds.\n\n'
          'Make sure the sensor is:\n• Powered on\n• Within Bluetooth range'
          : 'Pairing failed. Please try again.';
    });

    if (widget.apiService != null && _pairingId != null) {
      final newStatus =
      success ? (_hubAckOnly ? 'pairing' : 'paired') : (reason == 'timeout' ? 'timeout' : 'failed');
      widget.apiService!
          .accessoryUpdatePairingStatus(
        pairingId:     _pairingId!,
        accessoryUuid: _pairedMac,
        deviceBleName: _pairedBleName,
        status:        newStatus,
      )
          .then((_) => print('✅ Server pairing status → $newStatus'))
          .catchError((e) => print('⚠️ Server status update failed: $e'));
    }
  }

  void _confirmPaired() {
    final name = widget.nameController.text.trim().isEmpty
        ? _defaultName()
        : widget.nameController.text.trim();
    final zone = widget.zoneController.text.trim().isEmpty
        ? 'General'
        : widget.zoneController.text.trim();
    final mac  = _pairedMac ??
        'pairing_${widget.type.name}_${DateTime.now().millisecondsSinceEpoch}';

    final accessory = Accessory(
      id:         mac,
      name:       name,
      deviceName: _pairedBleName ?? name,
      zone:       zone,
      type:       widget.type,
      remoteMode: widget.remoteMode,
      status:     _pairingSuccess
          ? (_hubAckOnly ? AccessoryStatus.pairing : AccessoryStatus.paired)
          : AccessoryStatus.pairing,
      pairingId:  _pairingId,
    );

    widget.onPaired(accessory);
    Navigator.pop(context);
  }

  void _retryPairing() {
    _cleanup();
    setState(() {
      _isPairing      = false;
      _pairingDone    = false;
      _pairingSuccess = false;
      _secondsLeft    = _totalSec;
      _statusMsg      = '';
      _pairedMac      = null;
      _pairedBleName  = null;
      _triedConnect   = false;
      _pairingId      = null;
    });
  }

  String _defaultName() {
    switch (widget.type) {
      case AccessoryType.remote: return 'Remote Sensor';
      case AccessoryType.motion: return 'Motion Sensor';
      case AccessoryType.door:   return 'Door Sensor';
    }
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2D2D2D),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(children: [
        Icon(widget.typeIcon, color: widget.typeColor, size: 28),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Pair ${widget.typeLabel}',
              style: const TextStyle(color: Colors.white, fontSize: 16)),
        ),
      ]),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: widget.nameController,
            enabled: !_isPairing,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Sensor Name *',
              labelStyle: const TextStyle(color: Colors.white54),
              hintText: 'e.g. Living Room Sensor',
              hintStyle: const TextStyle(color: Colors.white30),
              enabledBorder: OutlineInputBorder(
                  borderSide:
                  BorderSide(color: widget.typeColor.withOpacity(0.4)),
                  borderRadius: BorderRadius.circular(8)),
              focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: widget.typeColor),
                  borderRadius: BorderRadius.circular(8)),
              disabledBorder: OutlineInputBorder(
                  borderSide:
                  BorderSide(color: widget.typeColor.withOpacity(0.15)),
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.zoneController,
            enabled: !_isPairing,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Zone (optional)',
              labelStyle: const TextStyle(color: Colors.white54),
              hintText: 'e.g. Entry, Bedroom',
              hintStyle: const TextStyle(color: Colors.white30),
              enabledBorder: OutlineInputBorder(
                  borderSide:
                  BorderSide(color: widget.typeColor.withOpacity(0.4)),
                  borderRadius: BorderRadius.circular(8)),
              focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: widget.typeColor),
                  borderRadius: BorderRadius.circular(8)),
              disabledBorder: OutlineInputBorder(
                  borderSide:
                  BorderSide(color: widget.typeColor.withOpacity(0.15)),
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(height: 16),

          if (!_isPairing && !_pairingDone)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: widget.typeColor.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border:
                Border.all(color: widget.typeColor.withOpacity(0.3)),
              ),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.bluetooth,
                        color: widget.typeColor, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.instructions,
                                style: TextStyle(
                                    color: widget.typeColor, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text(
                                'Pairing uses Bluetooth — keep sensor close.',
                                style: TextStyle(
                                    color: widget.typeColor.withOpacity(0.7),
                                    fontSize: 11)),
                          ]),
                    ),
                  ]),
            ),

          if (_isPairing) _buildProgress(),
          if (_pairingDone && _pairingSuccess) _buildSuccess(),
          if (_pairingDone && !_pairingSuccess) _buildFailure(),
        ]),
      ),
      actions: _buildActions(),
    );
  }

  Widget _buildProgress() {
    final progress = _secondsLeft / _totalSec;
    return Column(children: [
      const SizedBox(height: 8),
      Stack(alignment: Alignment.center, children: [
        SizedBox(
          width: 80, height: 80,
          child: CircularProgressIndicator(
            value: progress,
            strokeWidth: 6,
            valueColor: AlwaysStoppedAnimation(widget.typeColor),
            backgroundColor: widget.typeColor.withOpacity(0.15),
          ),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.bluetooth_searching,
              color: widget.typeColor, size: 20),
          Text('$_secondsLeft',
              style: TextStyle(
                  color: widget.typeColor,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
        ]),
      ]),
      const SizedBox(height: 12),
      const Text(_buildTag,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38, fontSize: 11)),
      const SizedBox(height: 6),
      Text(_statusMsg,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 13)),
      if (_pairingId != null) ...[
        const SizedBox(height: 6),
        Text('Pairing ID: $_pairingId',
            style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
    ]);
  }

  Widget _buildSuccess() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.green.withOpacity(0.12),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.green),
    ),
    child:
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Icon(Icons.check_circle, color: Colors.green, size: 24),
        SizedBox(width: 10),
        Text('Sensor Paired via Bluetooth!',
            style: TextStyle(
                color: Colors.green,
                fontWeight: FontWeight.bold,
                fontSize: 15)),
      ]),
      if (_pairedBleName != null) ...[
        const SizedBox(height: 8),
        Text('Sensor: $_pairedBleName',
            style:
            const TextStyle(color: Colors.white70, fontSize: 13)),
        Text('MAC: $_pairedMac',
            style:
            const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
      if (_pairingId != null) ...[
        const SizedBox(height: 4),
        Text('Server ID: $_pairingId  •  Status: paired',
            style:
            const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
      const SizedBox(height: 6),
      const Text('Tap "Save" to finish.',
          style: TextStyle(color: Colors.white54, fontSize: 12)),
    ]),
  );

  Widget _buildFailure() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.red.withOpacity(0.12),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.red),
    ),
    child:
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Icon(Icons.error_outline, color: Colors.red, size: 24),
        SizedBox(width: 10),
        Text('Pairing Failed',
            style: TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
                fontSize: 15)),
      ]),
      const SizedBox(height: 6),
      Text(_statusMsg,
          style:
          const TextStyle(color: Colors.white70, fontSize: 12)),
    ]),
  );

  List<Widget> _buildActions() {
    if (!_isPairing && !_pairingDone) {
      return [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel',
              style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.bluetooth_searching,
              size: 16, color: Colors.white),
          label: const Text('Start Pairing'),
          style: ElevatedButton.styleFrom(
              backgroundColor: widget.typeColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8))),
          onPressed: _startPairing,
        ),
      ];
    }
    if (_isPairing) {
      return [
        TextButton(
          onPressed: () =>
              _finishPairing(success: false, reason: 'cancelled'),
          child: const Text('Cancel',
              style: TextStyle(color: Colors.white54)),
        ),
      ];
    }
    if (_pairingDone && _pairingSuccess) {
      return [
        TextButton(
          onPressed: _retryPairing,
          child: const Text('Retry',
              style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.save, size: 16),
          label: const Text('Save'),
          style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8))),
          onPressed: _confirmPaired,
        ),
      ];
    }
    return [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close',
            style: TextStyle(color: Colors.white54)),
      ),
      ElevatedButton.icon(
        icon: const Icon(Icons.refresh, size: 16),
        label: const Text('Try Again'),
        style: ElevatedButton.styleFrom(
            backgroundColor: widget.typeColor,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8))),
        onPressed: _retryPairing,
      ),
    ];
  }
}




