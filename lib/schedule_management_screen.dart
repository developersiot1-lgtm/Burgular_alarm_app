import 'package:alarm/alarm_schedule.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'settings_manager.dart';
import 'api_service.dart';

class ScheduleManagementScreen extends StatefulWidget {
  const ScheduleManagementScreen({Key? key}) : super(key: key);

  @override
  _ScheduleManagementScreenState createState() =>
      _ScheduleManagementScreenState();
}

class _ScheduleManagementScreenState
    extends State<ScheduleManagementScreen> {
  final SettingsManager _settingsManager = SettingsManager();
  List<AlarmSchedule> _schedules = [];
  final _uuid = const Uuid();
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _loadSchedules();
  }

  // ✅ FIX: load from server first, fall back to local
  Future<void> _loadSchedules() async {
    // Always load local first so UI is instant
    setState(() {
      _schedules = _settingsManager.getSchedules();
    });

    // Then try to fetch from server and update
    try {
      final deviceUuid = _settingsManager.connectedDeviceUuid;
      if (deviceUuid.isEmpty) return;
      final api = Provider.of<ApiService>(context, listen: false);
      final serverSchedules = await api.getSchedules(deviceUuid);
      if (serverSchedules.isNotEmpty) {
        final parsed = serverSchedules.map((s) {
          return AlarmSchedule.fromJson({
            'id':         s['schedule_id'] ?? s['id'].toString(),
            'name':       s['schedule_name'] ?? s['name'],
            'startTime':  s['start_time'],
            'endTime':    s['end_time'],
            'activeDays': s['active_days'] is List
                ? s['active_days']
                : [],
            'isEnabled':  s['is_enabled'] ?? true,
          });
        }).toList();
        await _settingsManager.setSchedules(parsed);
        setState(() { _schedules = parsed; });
      }
    } catch (e) {
      print('⚠️ Could not load schedules from server: $e');
    }
  }

  // ✅ FIX: saves to server + local
  Future<void> _saveSchedulesToServer() async {
    setState(() { _isSyncing = true; });
    try {
      final deviceUuid = _settingsManager.connectedDeviceUuid;
      if (deviceUuid.isEmpty) return;
      final api = Provider.of<ApiService>(context, listen: false);
      final payload = _schedules.map((s) => s.toJson()).toList();
      final ok = await api.saveSchedules(deviceUuid, payload);
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('✅ Schedules saved'), backgroundColor: Colors.green));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('⚠️ Saved locally only'), backgroundColor: Colors.orange));
      }
    } catch (e) {
      print('❌ Save schedules error: $e');
    } finally {
      setState(() { _isSyncing = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        title: const Text('Alarm Schedules'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (_isSyncing)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white)),
            )
          else
            IconButton(
                icon: const Icon(Icons.cloud_upload),
                tooltip: 'Save to server',
                onPressed: _saveSchedulesToServer),
          IconButton(icon: const Icon(Icons.add), onPressed: _addNewSchedule),
        ],
      ),
      body: _schedules.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _schedules.length,
        itemBuilder: (context, index) =>
            _buildScheduleCard(_schedules[index]),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.schedule, size: 80, color: Colors.white24),
          const SizedBox(height: 20),
          const Text('No Schedules Yet',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          const Text('Tap + to create your first schedule',
              style: TextStyle(color: Colors.white38, fontSize: 14)),
          const SizedBox(height: 30),
          ElevatedButton.icon(
            onPressed: _addNewSchedule,
            icon: const Icon(Icons.add),
            label: const Text('Add Schedule'),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleCard(AlarmSchedule schedule) {
    return Card(
      color: const Color(0xFF2D2D2D),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(schedule.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                ),
                Switch(
                  value: schedule.isEnabled,
                  onChanged: (v) => _toggleSchedule(schedule),
                  activeColor: Colors.blue,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.access_time,
                    color: Colors.white70, size: 16),
                const SizedBox(width: 8),
                Text(
                    '${schedule.formattedStartTime} — ${schedule.formattedEndTime}',
                    style: const TextStyle(color: Colors.white70)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.calendar_today,
                    color: Colors.white70, size: 16),
                const SizedBox(width: 8),
                Text(schedule.activeDaysString,
                    style: const TextStyle(color: Colors.white70)),
              ],
            ),
            const SizedBox(height: 8),
            if (schedule.isActiveNow())
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green),
                ),
                child: const Text('🟢 Active Now',
                    style: TextStyle(color: Colors.green, fontSize: 12)),
              ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _editSchedule(schedule),
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('Edit'),
                ),
                TextButton.icon(
                  onPressed: () => _deleteSchedule(schedule),
                  icon: const Icon(Icons.delete, size: 16, color: Colors.red),
                  label: const Text('Delete',
                      style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleSchedule(AlarmSchedule schedule) async {
    await _settingsManager.toggleSchedule(schedule.id);
    setState(() { _schedules = _settingsManager.getSchedules(); });
    // ✅ sync toggle to server
    try {
      final deviceUuid = _settingsManager.connectedDeviceUuid;
      if (deviceUuid.isEmpty) return;
      final api = Provider.of<ApiService>(context, listen: false);
      await api.toggleSchedule(deviceUuid, schedule.id);
    } catch (e) {
      print('⚠️ Toggle sync error: $e');
    }
  }

  Future<void> _deleteSchedule(AlarmSchedule schedule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Schedule'),
        content: Text('Delete "${schedule.name}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _settingsManager.deleteSchedule(schedule.id);
    setState(() { _schedules = _settingsManager.getSchedules(); });
    // ✅ sync deletion to server
    try {
      final deviceUuid = _settingsManager.connectedDeviceUuid;
      if (deviceUuid.isEmpty) return;
      final api = Provider.of<ApiService>(context, listen: false);
      await api.deleteSchedule(deviceUuid, schedule.id);
    } catch (e) {
      print('⚠️ Delete sync error: $e');
    }
  }

  void _addNewSchedule() => _showScheduleDialog();
  void _editSchedule(AlarmSchedule schedule) =>
      _showScheduleDialog(existing: schedule);

  void _showScheduleDialog({AlarmSchedule? existing}) {
    final nameCtrl =
    TextEditingController(text: existing?.name ?? '');
    TimeOfDay startTime =
        existing?.startTime ?? const TimeOfDay(hour: 22, minute: 0);
    TimeOfDay endTime =
        existing?.endTime ?? const TimeOfDay(hour: 6, minute: 0);
    List<int> activeDays = existing?.activeDays.toList() ?? [0, 1, 2, 3, 4];
    final dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          backgroundColor: const Color(0xFF2D2D2D),
          title: Text(existing == null ? 'New Schedule' : 'Edit Schedule',
              style: const TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Schedule Name',
                    labelStyle: TextStyle(color: Colors.white70),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final t = await showTimePicker(
                              context: ctx, initialTime: startTime);
                          if (t != null) setDState(() => startTime = t);
                        },
                        child: Text('Start: ${_formatTime(startTime)}',
                            style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final t = await showTimePicker(
                              context: ctx, initialTime: endTime);
                          if (t != null) setDState(() => endTime = t);
                        },
                        child: Text('End: ${_formatTime(endTime)}',
                            style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('Active Days',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: List.generate(7, (i) {
                    final active = activeDays.contains(i);
                    return FilterChip(
                      label: Text(dayNames[i]),
                      selected: active,
                      onSelected: (sel) {
                        setDState(() {
                          if (sel) {
                            activeDays.add(i);
                            activeDays.sort();
                          } else {
                            activeDays.remove(i);
                          }
                        });
                      },
                    );
                  }),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.white54))),
            ElevatedButton(
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty) return;
                Navigator.pop(ctx);
                final schedule = AlarmSchedule(
                  id:         existing?.id ?? _uuid.v4(),
                  name:       nameCtrl.text.trim(),
                  startTime:  startTime,
                  endTime:    endTime,
                  activeDays: activeDays,
                  isEnabled:  existing?.isEnabled ?? true,
                );
                if (existing == null) {
                  await _settingsManager.addSchedule(schedule);
                } else {
                  await _settingsManager.updateSchedule(schedule);
                }
                setState(() { _schedules = _settingsManager.getSchedules(); });
                // ✅ save to server
                await _saveSchedulesToServer();
              },
              child: Text(existing == null ? 'Add' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    final p = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '$h:$m $p';
  }
}