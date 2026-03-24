import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'settings_manager.dart';
import 'schedule_management_screen.dart';
import 'voice_recording_screen.dart';
import 'connected_devices_screen.dart';
import 'api_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsManager _settings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = Provider.of<SettingsManager>(context);
  }

  // ✅ FIX: Builds COMPLETE payload — every setting is sent together
  Future<void> _syncSettingToServer(String key, dynamic value) async {
    if (_settings.connectedDeviceUuid.isEmpty) return;
    try {
      final apiService = Provider.of<ApiService>(context, listen: false);
      await apiService.saveSettings(_settings.connectedDeviceUuid, {
        'exit_delay':                        _settings.exitDelay,
        'entry_delay':                       _settings.entryDelay,
        'alarm_duration':                    _settings.alarmDuration,
        'alarm_sound':                       _settings.alarmSound,
        'alarm_call':                        _settings.alarmCall,
        'alarm_sms':                         _settings.alarmSMS,
        'sensor_low_battery_alarm':          _settings.sensorLowBatteryAlarm,
        'alarm_notification':                _settings.alarmNotification,
        'countdown_with_tick_tone':          _settings.countdownWithTickTone,
        'arm_disarm_notification':           _settings.armDisarmNotification,        // ✅ FIX: was missing
        'tamper_alarm':                      _settings.tamperAlarm,                  // ✅ FIX: was missing
        'sensor_low_battery_notification':   _settings.sensorLowBatteryNotification, // ✅ FIX: was missing
        'unanswered_phone_redial_times':     _settings.unansweredPhoneRedialTimes,
        'virtual_password':                  _settings.virtualPassword,
        'hub_language':                      _settings.hubLanguage,                  // ✅ FIX: was wrongly sending deviceName here
        'alarm_call_numbers':                _settings.alarmCallNumbers,
        'alarm_sms_numbers':                 _settings.alarmSMSNumbers,
      });
      print('✅ Synced $key to server');
    } catch (e) {
      print('⚠️ Failed to sync $key: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Device Settings ──────────────────────────────────────
          _buildSection('Device Settings', [
            _buildTextTile(
              'Device Name',
              _settings.deviceName,
                  (value) async {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) =>
                  const Center(child: CircularProgressIndicator()),
                );
                try {
                  await _settings.setDeviceName(value);
                  final apiService =
                  Provider.of<ApiService>(context, listen: false);
                  final ok = await apiService.updateDeviceName(
                      _settings.connectedDeviceUuid, value);
                  Navigator.pop(context);
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(ok
                        ? '✅ Device name updated'
                        : '⚠️ Updated locally only'),
                    backgroundColor: ok ? Colors.green : Colors.orange,
                  ));
                } catch (e) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('❌ Failed: $e'),
                    backgroundColor: Colors.red,
                  ));
                }
              },
            ),
          ]),
          const SizedBox(height: 24),

          // ── Alarm Timing ─────────────────────────────────────────
          _buildSection('Alarm Timing', [
            _buildSliderTile('Exit Delay', _settings.exitDelay.toDouble(),
                0, 120, (v) async {
                  await _settings.setExitDelay(v.round());
                  setState(() {});
                  _syncSettingToServer('exit_delay', v.round());
                }, suffix: 'seconds'),
            _buildSliderTile('Entry Delay', _settings.entryDelay.toDouble(),
                0, 120, (v) async {
                  await _settings.setEntryDelay(v.round());
                  setState(() {});
                  _syncSettingToServer('entry_delay', v.round());
                }, suffix: 'seconds'),
            _buildSliderTile(
                'Alarm Duration', _settings.alarmDuration.toDouble(),
                1, 15, (v) async {
              await _settings.setAlarmDuration(v.round());
              setState(() {});
              _syncSettingToServer('alarm_duration', v.round());
            }, suffix: 'minutes'),
          ]),
          const SizedBox(height: 24),

          // ── Alarm Notifications ──────────────────────────────────
          _buildSection('Alarm Notifications', [
            _buildSwitchTile('Alarm Sound', _settings.alarmSound, (v) async {
              await _settings.setAlarmSound(v);
              setState(() {});
              _syncSettingToServer('alarm_sound', v);
            }),
            _buildSwitchTile(
                'Alarm Notification', _settings.alarmNotification, (v) async {
              await _settings.setAlarmNotification(v);
              setState(() {});
              _syncSettingToServer('alarm_notification', v);
            }),
            _buildSwitchTile('Countdown Tick Tone',
                _settings.countdownWithTickTone, (v) async {
                  await _settings.setCountdownWithTickTone(v);
                  setState(() {});
                  _syncSettingToServer('countdown_with_tick_tone', v);
                }),
            _buildSwitchTile(
                'Low Battery Alarm', _settings.sensorLowBatteryAlarm,
                    (v) async {
                  await _settings.setSensorLowBatteryAlarm(v);
                  setState(() {});
                  _syncSettingToServer('sensor_low_battery_alarm', v);
                }),
            // ✅ FIX: These were in PHP $setting_keys but never sent from Flutter
            _buildSwitchTile(
                'Arm/Disarm Notification', _settings.armDisarmNotification,
                    (v) async {
                  await _settings.setArmDisarmNotification(v);
                  setState(() {});
                  _syncSettingToServer('arm_disarm_notification', v);
                }),
            _buildSwitchTile(
                'Tamper Alarm', _settings.tamperAlarm, (v) async {
              await _settings.setTamperAlarm(v);
              setState(() {});
              _syncSettingToServer('tamper_alarm', v);
            }),
            _buildSwitchTile(
                'Low Battery Notification', _settings.sensorLowBatteryNotification,
                    (v) async {
                  await _settings.setSensorLowBatteryNotification(v);
                  setState(() {});
                  _syncSettingToServer('sensor_low_battery_notification', v);
                }),
          ]),
          const SizedBox(height: 24),

          // ── Alert Settings ───────────────────────────────────────
          _buildSection('Alert Settings', [
            // ✅ FIX: was missing _syncSettingToServer
            _buildSwitchTile('Alarm Call', _settings.alarmCall, (v) async {
              await _settings.setAlarmCall(v);
              setState(() {});
              _syncSettingToServer('alarm_call', v); // ✅ added
            }),
            // ✅ FIX: was missing _syncSettingToServer
            _buildSwitchTile('Alarm SMS', _settings.alarmSMS, (v) async {
              await _settings.setAlarmSMS(v);
              setState(() {});
              _syncSettingToServer('alarm_sms', v); // ✅ added
            }),
            // ✅ FIX: was missing _syncSettingToServer
            _buildSliderTile(
                'Redial Attempts',
                _settings.unansweredPhoneRedialTimes.toDouble(),
                0,
                5, (v) async {
              await _settings.setUnansweredPhoneRedialTimes(v.round());
              setState(() {});
              _syncSettingToServer(
                  'unanswered_phone_redial_times', v.round()); // ✅ added
            }, suffix: 'times'),
          ]),
          const SizedBox(height: 24),

          // ── Security ─────────────────────────────────────────────
          _buildSection('Security', [
            // ✅ FIX: was missing _syncSettingToServer
            _buildTextTile(
              'Virtual Password',
              _settings.virtualPassword.isEmpty ? 'Not set' : '••••••',
                  (value) async {
                await _settings.setVirtualPassword(value);
                setState(() {});
                _syncSettingToServer('virtual_password', value); // ✅ added
              },
              isPassword: true,
            ),
          ]),
          const SizedBox(height: 24),

          // ── Advanced ─────────────────────────────────────────────
          _buildSection('Advanced', [
            _buildNavigationTile('Alarm Schedules', Icons.schedule, () async {
              await Navigator.push(context,
                  MaterialPageRoute(
                      builder: (_) => const ScheduleManagementScreen()));
              setState(() {});
            }),
            _buildNavigationTile('Voice Recordings', Icons.mic, () {
              Navigator.push(context,
                  MaterialPageRoute(
                      builder: (_) => const VoiceRecordingScreen()));
            }),
            _buildNavigationTile('Connected Devices', Icons.devices, () {
              Navigator.push(context,
                  MaterialPageRoute(
                      builder: (_) => const ConnectedDevicesScreen()));
            }),
          ]),
          const SizedBox(height: 24),

          // ── Contact Numbers ──────────────────────────────────────
          _buildSection('Contact Numbers', [
            _buildContactNumbersList(),
          ]),
          const SizedBox(height: 24),

          _buildDangerSection(),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────────

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 12),
          child: Text(title,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue)),
        ),
        Card(child: Column(children: children)),
      ],
    );
  }

  Widget _buildSwitchTile(
      String title, bool value, Function(bool) onChanged) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(color: Colors.white)),
      value: value,
      onChanged: onChanged,
      activeColor: Colors.blue,
    );
  }

  Widget _buildSliderTile(String title, double value, double min, double max,
      Function(double) onChanged,
      {String suffix = ''}) {
    return ListTile(
      title: Text(title, style: const TextStyle(color: Colors.white)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: (max - min).round(),
            label: '${value.round()} $suffix',
            onChanged: onChanged,
          ),
          Text('${value.round()} $suffix',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildTextTile(
      String title, String currentValue, Function(String) onChanged,
      {bool isPassword = false}) {
    return ListTile(
      title: Text(title, style: const TextStyle(color: Colors.white)),
      subtitle:
      Text(currentValue, style: const TextStyle(color: Colors.white70)),
      trailing: const Icon(Icons.edit, color: Colors.blue),
      onTap: () async {
        final controller =
        TextEditingController(text: isPassword ? '' : currentValue);
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Edit $title'),
            content: TextField(
              controller: controller,
              obscureText: isPassword,
              decoration: InputDecoration(
                  labelText: title, border: const OutlineInputBorder()),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  final v = controller.text.trim();
                  if (v.isNotEmpty) {
                    onChanged(v);
                    Navigator.pop(ctx);
                  }
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNavigationTile(
      String title, IconData icon, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: Colors.blue),
      title: Text(title, style: const TextStyle(color: Colors.white)),
      trailing: const Icon(Icons.chevron_right, color: Colors.white70),
      onTap: onTap,
    );
  }

  // ─────────────────────────────────────────────────────────────────
  // CONTACT NUMBERS
  // ─────────────────────────────────────────────────────────────────

  Widget _buildContactNumbersList() {
    final callNumbers = _settings.alarmCallNumbers;
    final smsNumbers  = _settings.alarmSMSNumbers;

    return Column(
      children: [
        if (callNumbers.isNotEmpty) ...[
          const ListTile(
              title: Text('Call Numbers',
                  style: TextStyle(color: Colors.white70, fontSize: 12))),
          ...callNumbers.asMap().entries.map((entry) {
            return ListTile(
              leading: const Icon(Icons.phone, color: Colors.green),
              title: Text(entry.value,
                  style: const TextStyle(color: Colors.white)),
              subtitle: Text('Priority ${entry.key + 1}',
                  style:
                  const TextStyle(color: Colors.white54, fontSize: 11)),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () async {
                  await _settings.removeAlarmCallNumber(entry.value);
                  // ✅ sync deletion to server
                  try {
                    final api =
                    Provider.of<ApiService>(context, listen: false);
                    _syncSettingToServer('alarm_call_numbers', null);
                    // Also delete on server by contact id if needed
                  } catch (_) {}
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Removed call number'),
                      backgroundColor: Colors.orange));
                },
              ),
            );
          }),
        ],
        if (smsNumbers.isNotEmpty) ...[
          const ListTile(
              title: Text('SMS Numbers',
                  style: TextStyle(color: Colors.white70, fontSize: 12))),
          ...smsNumbers.asMap().entries.map((entry) {
            return ListTile(
              leading: const Icon(Icons.sms, color: Colors.blue),
              title: Text(entry.value,
                  style: const TextStyle(color: Colors.white)),
              subtitle: Text('Priority ${entry.key + 1}',
                  style:
                  const TextStyle(color: Colors.white54, fontSize: 11)),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () async {
                  await _settings.removeAlarmSMSNumber(entry.value);
                  _syncSettingToServer('alarm_sms_numbers', null);
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Removed SMS number'),
                      backgroundColor: Colors.orange));
                },
              ),
            );
          }),
        ],
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: ElevatedButton.icon(
                  onPressed: () => _addContactNumber('call'),
                  icon: const Icon(Icons.phone),
                  label: const Text('Add Call'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: ElevatedButton.icon(
                  onPressed: () => _addContactNumber('sms'),
                  icon: const Icon(Icons.sms),
                  label: const Text('Add SMS'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _addContactNumber(String type) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Add ${type.toUpperCase()} Number'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
              labelText: 'Phone Number',
              border: OutlineInputBorder(),
              hintText: '+1234567890'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final n = controller.text.trim();
              if (n.isNotEmpty) Navigator.pop(ctx, n);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      if (type == 'call') {
        await _settings.addAlarmCallNumber(result);
      } else {
        await _settings.addAlarmSMSNumber(result);
      }

      // ✅ sync full settings including new number
      _syncSettingToServer('${type}_number_added', result);

      // Also add directly on server
      try {
        final api = Provider.of<ApiService>(context, listen: false);
        await api.addContactNumber(
          deviceUuid: _settings.connectedDeviceUuid,
          phoneNumber: result,
          numberType: type,
        );
      } catch (_) {}

      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('✅ ${type.toUpperCase()} number added'),
          backgroundColor: Colors.green));
    }
  }

  Widget _buildDangerSection() {
    return Card(
      color: Colors.red.withOpacity(0.1),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.warning, color: Colors.red),
            title: const Text('Factory Reset',
                style: TextStyle(
                    color: Colors.red, fontWeight: FontWeight.bold)),
            subtitle: const Text('This will erase all settings',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Factory Reset'),
                  content: const Text(
                      'Reset all settings to default?\n\nThis cannot be undone.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red),
                      child: const Text('Reset'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await _settings.factoryReset();
                setState(() {});
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Settings reset to defaults')));
                }
              }
            },
          ),
        ],
      ),
    );
  }
}