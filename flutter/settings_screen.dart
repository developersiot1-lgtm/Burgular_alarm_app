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
  /// Sync a single setting to the server
  Future<void> _syncSettingToServer(String key, dynamic value) async {
    try {
      final apiService = Provider.of<ApiService>(context, listen: false);

      // Build complete settings payload
      final settings = {
        'device_uuid': _settings.connectedDeviceUuid,
        'exit_delay': _settings.exitDelay,
        'entry_delay': _settings.entryDelay,
        'alarm_duration': _settings.alarmDuration,
        'alarm_sound': _settings.alarmSound,
        'alarm_call': _settings.alarmCall,
        'alarm_sms': _settings.alarmSMS,
        'sensor_low_battery_alarm': _settings.sensorLowBatteryAlarm,
        'alarm_notification': _settings.alarmNotification,
        'countdown_with_tick_tone': _settings.countdownWithTickTone,
        'unanswered_phone_redial_times': _settings.unansweredPhoneRedialTimes,
        'virtual_password': _settings.virtualPassword,
        'hub_language': _settings.deviceName,
        'alarm_call_numbers': _settings.alarmCallNumbers,
        'alarm_sms_numbers': _settings.alarmSMSNumbers,
      };

      await apiService.saveSettings(_settings.connectedDeviceUuid, settings);
      print('✅ Synced $key to server: $value');

    } catch (e) {
      print('⚠️ Failed to sync $key to server: $e');
      // Don't show error to user - local save already succeeded
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSection('Device Settings', [
            _buildTextTile(
              'Device Name',
              _settings.deviceName,
                  (value) async {
                // ✅ Show loading indicator
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (ctx) => Center(child: CircularProgressIndicator()),
                );

                try {
                  // Save locally
                  await _settings.setDeviceName(value);

                  // ✅ Update on server
                  final apiService = Provider.of<ApiService>(context, listen: false);
                  final success = await apiService.updateDeviceName(
                    _settings.connectedDeviceUuid,
                    value,
                  );

                  Navigator.pop(context); // Close loading

                  if (success) {
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('✅ Device name updated'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('⚠️ Updated locally only'),
                        backgroundColor: Colors.orange,
                      ),
                    );
                  }
                } catch (e) {
                  Navigator.pop(context); // Close loading
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('❌ Failed to update: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection('Alarm Timing', [
            _buildSliderTile(
              'Exit Delay',
              _settings.exitDelay.toDouble(),
              0,
              120,
                  (value) async {
                await _settings.setExitDelay(value.round());
                setState(() {});
                _syncSettingToServer('exit_delay', value.round());
              },
              suffix: 'seconds',
            ),
            _buildSliderTile(
              'Entry Delay',
              _settings.entryDelay.toDouble(),
              0,
              120,
                  (value) async {
                await _settings.setEntryDelay(value.round());
                setState(() {});
                _syncSettingToServer('entry_delay', value.round());
              },
              suffix: 'seconds',
            ),
            _buildSliderTile(
              'Alarm Duration',
              _settings.alarmDuration.toDouble(),
              1,
              15,
                  (value) async {
                await _settings.setAlarmDuration(value.round());
                setState(() {});
                _syncSettingToServer('alarm_duration', value.round());
              },
              suffix: 'minutes',
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection('Alarm Notifications', [
            _buildSwitchTile(
              'Alarm Sound',
              _settings.alarmSound,
                  (value) async {
                await _settings.setAlarmSound(value);
                setState(() {});
                _syncSettingToServer('alarm_sound', value);
              },
            ),
            _buildSwitchTile(
              'Alarm Notification',
              _settings.alarmNotification,
                  (value) async {
                await _settings.setAlarmNotification(value);
                setState(() {});
              },
            ),
            _buildSwitchTile(
              'Countdown Tick Tone',
              _settings.countdownWithTickTone,
                  (value) async {
                await _settings.setCountdownWithTickTone(value);
                setState(() {});
              },
            ),
            _buildSwitchTile(
              'Low Battery Alarm',
              _settings.sensorLowBatteryAlarm,
                  (value) async {
                await _settings.setSensorLowBatteryAlarm(value);
                setState(() {});
              },
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection('Alert Settings', [
            _buildSwitchTile(
              'Alarm Call',
              _settings.alarmCall,
                  (value) async {
                await _settings.setAlarmCall(value);
                setState(() {});
              },
            ),
            _buildSwitchTile(
              'Alarm SMS',
              _settings.alarmSMS,
                  (value) async {
                await _settings.setAlarmSMS(value);
                setState(() {});
              },
            ),
            _buildSliderTile(
              'Redial Attempts',
              _settings.unansweredPhoneRedialTimes.toDouble(),
              0,
              5,
                  (value) async {
                await _settings.setUnansweredPhoneRedialTimes(value.round());
                setState(() {});
              },
              suffix: 'times',
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection('Security', [
            _buildTextTile(
              'Virtual Password',
              _settings.virtualPassword.isEmpty ? 'Not set' : '••••••',
                  (value) async {
                await _settings.setVirtualPassword(value);
                setState(() {});
              },
              isPassword: true,
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection('Advanced', [
            _buildNavigationTile(
              'Alarm Schedules',
              Icons.schedule,
                  () async {
                // ✅ Refresh on return
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ScheduleManagementScreen(),
                  ),
                );
                setState(() {}); // Refresh UI
              },
            ),
            _buildNavigationTile(
              'Voice Recordings',
              Icons.mic,
                  () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const VoiceRecordingScreen(),
                  ),
                );
              },
            ),
            _buildNavigationTile(
              'Connected Devices',
              Icons.devices,
                  () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ConnectedDevicesScreen(),
                  ),
                );
              },
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection('Contact Numbers', [
            _buildContactNumbersList(),
          ]),
          const SizedBox(height: 24),
          _buildDangerSection(),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 12),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
        ),
        Card(
          child: Column(
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _buildSwitchTile(
      String title,
      bool value,
      Function(bool) onChanged,
      ) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(color: Colors.white)),
      value: value,
      onChanged: onChanged,
      activeColor: Colors.blue,
    );
  }

  Widget _buildSliderTile(
      String title,
      double value,
      double min,
      double max,
      Function(double) onChanged, {
        String suffix = '',
      }) {
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
          Text(
            '${value.round()} $suffix',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildTextTile(
      String title,
      String currentValue,
      Function(String) onChanged, {
        bool isPassword = false,
      }) {
    return ListTile(
      title: Text(title, style: const TextStyle(color: Colors.white)),
      subtitle: Text(
        currentValue,
        style: const TextStyle(color: Colors.white70),
      ),
      trailing: const Icon(Icons.edit, color: Colors.blue),
      onTap: () async {
        final controller = TextEditingController(
          text: isPassword ? '' : currentValue,
        );

        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Edit $title'),
            content: TextField(
              controller: controller,
              obscureText: isPassword,
              decoration: InputDecoration(
                labelText: title,
                border: const OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  final newValue = controller.text.trim();
                  if (newValue.isNotEmpty) {
                    onChanged(newValue);
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
      String title,
      IconData icon,
      VoidCallback onTap,
      ) {
    return ListTile(
      leading: Icon(icon, color: Colors.blue),
      title: Text(title, style: const TextStyle(color: Colors.white)),
      trailing: const Icon(Icons.chevron_right, color: Colors.white70),
      onTap: onTap,
    );
  }

  Widget _buildContactNumbersList() {
    final callNumbers = _settings.alarmCallNumbers;
    final smsNumbers = _settings.alarmSMSNumbers;

    return Column(
      children: [
        // Call Numbers
        if (callNumbers.isNotEmpty) ...[
          const ListTile(
            title: Text(
              'Call Numbers',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          ...callNumbers.asMap().entries.map((entry) {
            final index = entry.key;
            final number = entry.value;
            return ListTile(
              leading: const Icon(Icons.phone, color: Colors.green),
              title: Text(number, style: const TextStyle(color: Colors.white)),
              subtitle: Text(
                'Priority ${index + 1}',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () async {
                  await _settings.removeAlarmCallNumber(number);
                  // ✅ FIX: Sync deletion with server
                  // Re-save the entire updated list to keep server in sync
                  try {
                    final apiService = Provider.of<ApiService>(context, listen: false);
                    final updatedNumbers = _settings.alarmCallNumbers;
                    for (final n in updatedNumbers) {
                      await apiService.addContactNumber(
                        deviceUuid: _settings.connectedDeviceUuid,
                        phoneNumber: n,
                        numberType: 'call',
                      );
                    }
                  } catch (e) {
                    print('⚠️ Server sync failed: $e');
                  }
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Removed call number'), backgroundColor: Colors.orange),
                  );
                },
              ),
            );
          }),
        ],

        // SMS Numbers
        if (smsNumbers.isNotEmpty) ...[
          const ListTile(
            title: Text(
              'SMS Numbers',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          ...smsNumbers.asMap().entries.map((entry) {
            final index = entry.key;
            final number = entry.value;
            return ListTile(
              leading: const Icon(Icons.sms, color: Colors.blue),
              title: Text(number, style: const TextStyle(color: Colors.white)),
              subtitle: Text(
                'Priority ${index + 1}',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () async {
                  await _settings.removeAlarmSMSNumber(number);
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Removed SMS number'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                },
              ),
            );
          }),
        ],

        // Add Number Buttons
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
                    backgroundColor: Colors.green,
                  ),
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
                    backgroundColor: Colors.blue,
                  ),
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
            hintText: '+1234567890',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final number = controller.text.trim();
              if (number.isNotEmpty) {
                Navigator.pop(ctx, number);
              }
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

      // ✅ FIX: Also save to server database
      try {
        final apiService = Provider.of<ApiService>(context, listen: false);
        await apiService.addContactNumber(
          deviceUuid: _settings.connectedDeviceUuid,
          phoneNumber: result,
          numberType: type,
        );
      } catch (e) {
        print('⚠️ Server sync failed: $e');
      }

      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ ${type.toUpperCase()} number added'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Widget _buildDangerSection() {
    return Card(
      color: Colors.red.withOpacity(0.1),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.warning, color: Colors.red),
            title: const Text(
              'Factory Reset',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
            subtitle: const Text(
              'This will erase all settings',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Factory Reset'),
                  content: const Text(
                    'Are you sure you want to reset all settings to default?\n\nThis action cannot be undone.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      child: const Text('Reset'),
                    ),
                  ],
                ),
              );

              if (confirmed == true) {
                await _settings.factoryReset();
                setState(() {});
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Settings reset to defaults'),
                    ),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }
}
