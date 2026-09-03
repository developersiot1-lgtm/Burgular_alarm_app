import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'accessories_screen.dart';
import 'api_service.dart';
import 'connected_devices_screen.dart';
import 'notification_service.dart';
import 'schedule_management_screen.dart';
import 'settings_manager.dart';
import 'voice_recording_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsManager _settings;
  bool _contactsLoadedFromServer = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = Provider.of<SettingsManager>(context);
    if (!_contactsLoadedFromServer) {
      _contactsLoadedFromServer = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadContactNumbersFromServer();
      });
    }
  }

  Future<void> _loadContactNumbersFromServer() async {
    if (_settings.connectedDeviceUuid.isEmpty) return;

    try {
      final apiService = Provider.of<ApiService>(context, listen: false);
      final contacts =
          await apiService.getContactNumbers(_settings.connectedDeviceUuid);

      final callNumbers = <String>[];
      final smsNumbers = <String>[];
      for (final contact in contacts) {
        if (contact is! Map) continue;
        final number = (contact['phone_number'] ?? '').toString().trim();
        final type = (contact['number_type'] ?? '').toString().toLowerCase();
        if (number.isEmpty) continue;
        if (type == 'sms') {
          smsNumbers.add(number);
        } else {
          callNumbers.add(number);
        }
      }

      await _settings.setAlarmCallNumbers(callNumbers);
      await _settings.setAlarmSMSNumbers(smsNumbers);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Failed to load contact numbers from server: $e');
    }
  }

  Future<void> _syncSettingToServer(String key, dynamic value) async {
    if (_settings.connectedDeviceUuid.isEmpty) return;

    try {
      final apiService = Provider.of<ApiService>(context, listen: false);

      await apiService.saveSettings(_settings.connectedDeviceUuid, {
        'device_name': _settings.deviceName,
        'exit_delay': _settings.exitDelay,
        'entry_delay': _settings.entryDelay,
        'alarm_duration': _settings.alarmDuration,
        'alarm_sound': _settings.alarmSound,
        'alarm_call': _settings.alarmCall,
        'alarm_sms': _settings.alarmSMS,
        'sensor_low_battery_alarm': _settings.sensorLowBatteryAlarm,
        'alarm_notification': _settings.alarmNotification,
        'countdown_with_tick_tone': _settings.countdownWithTickTone,
        'arm_disarm_notification': _settings.armDisarmNotification,
        'tamper_alarm': _settings.tamperAlarm,
        'sensor_low_battery_notification':
            _settings.sensorLowBatteryNotification,
        'unanswered_phone_redial_times': _settings.unansweredPhoneRedialTimes,
        'virtual_password': _settings.virtualPassword,
        'hub_language': _settings.hubLanguage,
        'alarm_call_numbers': _settings.alarmCallNumbers,
        'alarm_sms_numbers': _settings.alarmSMSNumbers,
      });

      debugPrint('✅ Synced $key to server');
    } catch (e) {
      debugPrint('⚠️ Failed to sync $key: $e');
    }
  }

  Future<bool> _saveAllSettingsToServer() async {
    if (_settings.connectedDeviceUuid.isEmpty) return false;

    final apiService = Provider.of<ApiService>(context, listen: false);
    return apiService.saveSettings(_settings.connectedDeviceUuid, {
      'device_name': _settings.deviceName,
      'exit_delay': _settings.exitDelay,
      'entry_delay': _settings.entryDelay,
      'alarm_duration': _settings.alarmDuration,
      'alarm_sound': _settings.alarmSound,
      'alarm_call': _settings.alarmCall,
      'alarm_sms': _settings.alarmSMS,
      'sensor_low_battery_alarm': _settings.sensorLowBatteryAlarm,
      'alarm_notification': _settings.alarmNotification,
      'countdown_with_tick_tone': _settings.countdownWithTickTone,
      'arm_disarm_notification': _settings.armDisarmNotification,
      'tamper_alarm': _settings.tamperAlarm,
      'sensor_low_battery_notification':
          _settings.sensorLowBatteryNotification,
      'unanswered_phone_redial_times': _settings.unansweredPhoneRedialTimes,
      'virtual_password': _settings.virtualPassword,
      'hub_language': _settings.hubLanguage,
      'alarm_call_numbers': _settings.alarmCallNumbers,
      'alarm_sms_numbers': _settings.alarmSMSNumbers,
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_settings.canManageCurrentDevice) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.maybePop(context);
      });
      return const Scaffold(
        backgroundColor: Colors.white,
        body: SizedBox.shrink(),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.black),
        title: const Text(
          'Settings',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
                    _settings.connectedDeviceUuid,
                    value,
                  );

                  await _syncSettingToServer('device_name', value);
                  if (mounted) Navigator.pop(context);
                  setState(() {});
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        ok
                            ? '✅ Device name updated'
                            : '⚠️ Updated locally only',
                      ),
                      backgroundColor: ok ? Colors.green : Colors.red,
                    ),
                  );
                } catch (e) {
                  if (mounted) Navigator.pop(context);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('❌ Failed: $e'),
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
              (v) async {
                await _settings.setExitDelay(v.round());
                setState(() {});
                _syncSettingToServer('exit_delay', v.round());
              },
              suffix: 'seconds',
            ),
            _buildSliderTile(
              'Entry Delay',
              _settings.entryDelay.toDouble(),
              0,
              120,
              (v) async {
                await _settings.setEntryDelay(v.round());
                setState(() {});
                _syncSettingToServer('entry_delay', v.round());
              },
              suffix: 'seconds',
            ),
            _buildSliderTile(
              'Alarm Duration',
              _settings.alarmDuration.toDouble(),
              1,
              15,
              (v) async {
                await _settings.setAlarmDuration(v.round());
                setState(() {});
                _syncSettingToServer('alarm_duration', v.round());
              },
              suffix: 'minutes',
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection('Alarm Notifications', [
            _buildSwitchTile(
              'Alarm Sound',
              _settings.alarmSound,
              (v) async {
                await _settings.setAlarmSound(v);

                await NotificationService().setSettings(
                  alarmSound: v,
                  notification: _settings.alarmNotification,
                );

                setState(() {});
                _syncSettingToServer('alarm_sound', v);
              },
            ),
            _buildSwitchTile(
              'Alarm Notification',
              _settings.alarmNotification,
              (v) async {
                await _settings.setAlarmNotification(v);

                await NotificationService().setSettings(
                  alarmSound: _settings.alarmSound,
                  notification: v,
                );

                setState(() {});
                _syncSettingToServer('alarm_notification', v);
              },
            ),
            _buildSwitchTile(
              'Countdown Tick Tone',
              _settings.countdownWithTickTone,
              (v) async {
                await _settings.setCountdownWithTickTone(v);
                setState(() {});
                _syncSettingToServer('countdown_with_tick_tone', v);
              },
            ),
            _buildSwitchTile(
              'Low Battery Alarm',
              _settings.sensorLowBatteryAlarm,
              (v) async {
                await _settings.setSensorLowBatteryAlarm(v);
                setState(() {});
                _syncSettingToServer('sensor_low_battery_alarm', v);
              },
            ),
            _buildSwitchTile(
              'Arm/Disarm Notification',
              _settings.armDisarmNotification,
              (v) async {
                await _settings.setArmDisarmNotification(v);
                setState(() {});
                _syncSettingToServer('arm_disarm_notification', v);
              },
            ),
            _buildSwitchTile(
              'Tamper Alarm',
              _settings.tamperAlarm,
              (v) async {
                await _settings.setTamperAlarm(v);
                setState(() {});
                _syncSettingToServer('tamper_alarm', v);
              },
            ),
            _buildSwitchTile(
              'Low Battery Notification',
              _settings.sensorLowBatteryNotification,
              (v) async {
                await _settings.setSensorLowBatteryNotification(v);
                setState(() {});
                _syncSettingToServer('sensor_low_battery_notification', v);
              },
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection('Alert Settings', [
            _buildSwitchTile(
              'Alarm Call',
              _settings.alarmCall,
              (v) async {
                await _settings.setAlarmCall(v);
                setState(() {});
                _syncSettingToServer('alarm_call', v);
              },
            ),
            _buildSwitchTile(
              'Alarm SMS',
              _settings.alarmSMS,
              (v) async {
                await _settings.setAlarmSMS(v);
                setState(() {});
                _syncSettingToServer('alarm_sms', v);
              },
            ),
            _buildSliderTile(
              'Redial Attempts',
              _settings.unansweredPhoneRedialTimes.toDouble(),
              0,
              5,
              (v) async {
                await _settings.setUnansweredPhoneRedialTimes(v.round());
                setState(() {});
                _syncSettingToServer(
                  'unanswered_phone_redial_times',
                  v.round(),
                );
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
                _syncSettingToServer('virtual_password', value);
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
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ScheduleManagementScreen(),
                  ),
                );
                setState(() {});
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
            _buildNavigationTile(
              'Accessories',
              Icons.sensors,
              () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AccessoriesScreen(),
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
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.deepPurpleAccent,
            ),
          ),
        ),
        Card(
          color: Colors.white,
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFFEAEAEA)),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _buildSwitchTile(String title, bool value, Function(bool) onChanged) {
    return SwitchListTile(
      title: Text(
        title,
        style:
            const TextStyle(color: Colors.black, fontWeight: FontWeight.w500),
      ),
      value: value,
      onChanged: (v) => onChanged(v),
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
      title: Text(
        title,
        style:
            const TextStyle(color: Colors.black, fontWeight: FontWeight.w500),
      ),
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
            onChanged: (v) => onChanged(v),
          ),
          Text(
            '${value.round()} $suffix',
            style: const TextStyle(color: Colors.black, fontSize: 12),
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
      title: Text(
        title,
        style:
            const TextStyle(color: Colors.black, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        currentValue,
        style: const TextStyle(color: Colors.black),
      ),
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
    String title,
    IconData icon,
    VoidCallback onTap,
  ) {
    return ListTile(
      leading: Icon(icon, color: Colors.blue),
      title: Text(
        title,
        style:
            const TextStyle(color: Colors.black, fontWeight: FontWeight.w500),
      ),
      trailing: const Icon(Icons.chevron_right, color: Colors.black54),
      onTap: onTap,
    );
  }

  Widget _buildContactNumbersList() {
    final callNumbers = _settings.alarmCallNumbers;
    final smsNumbers = _settings.alarmSMSNumbers;

    return Column(
      children: [
        if (callNumbers.isNotEmpty) ...[
          const ListTile(
            title: Text(
              'Call Numbers',
              style: TextStyle(color: Colors.black54, fontSize: 12),
            ),
          ),
          ...callNumbers.asMap().entries.map((entry) {
            return ListTile(
              leading: const Icon(Icons.phone, color: Colors.green),
              title: Text(
                entry.value,
                style: const TextStyle(color: Colors.black),
              ),
              subtitle: Text(
                'Priority ${entry.key + 1}',
                style: const TextStyle(color: Colors.black54, fontSize: 11),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () async {
                  await _settings.removeAlarmCallNumber(entry.value);
                  _syncSettingToServer('alarm_call_numbers', null);
                  setState(() {});
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Removed call number'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                },
              ),
            );
          }),
        ],
        if (smsNumbers.isNotEmpty) ...[
          const ListTile(
            title: Text(
              'SMS Numbers',
              style: TextStyle(color: Colors.black54, fontSize: 12),
            ),
          ),
          ...smsNumbers.asMap().entries.map((entry) {
            return ListTile(
              leading: const Icon(Icons.sms, color: Colors.blue),
              title: Text(
                entry.value,
                style: const TextStyle(color: Colors.black),
              ),
              subtitle: Text(
                'Priority ${entry.key + 1}',
                style: const TextStyle(color: Colors.black54, fontSize: 11),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () async {
                  await _settings.removeAlarmSMSNumber(entry.value);
                  _syncSettingToServer('alarm_sms_numbers', null);
                  setState(() {});
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Removed SMS number'),
                      backgroundColor: Colors.orange,
                    ),
                  );
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
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
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
                    foregroundColor: Colors.white,
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
              final n = controller.text.trim();
              if (n.isNotEmpty) Navigator.pop(ctx, n);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      try {
        final number = result.trim();
        if (type == 'sms') {
          await _settings.addAlarmSMSNumber(number);
        } else {
          await _settings.addAlarmCallNumber(number);
        }
        if (mounted) setState(() {});

        final api = Provider.of<ApiService>(context, listen: false);
        final saved = await api.addContactNumber(
          deviceUuid: _settings.connectedDeviceUuid,
          phoneNumber: number,
          numberType: type,
        );
        if (!saved) {
          final fallbackSaved = await _saveAllSettingsToServer();
          if (!fallbackSaved) {
            throw Exception('Server did not save the number');
          }
        }

        await _loadContactNumbersFromServer();
        _syncSettingToServer('${type}_number_added', number);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add ${type.toUpperCase()} number: $e'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      setState(() {});
      if (!mounted) return;
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
      color: Colors.white,
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFFFD6D6)),
      ),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.warning, color: Colors.red),
            title: const Text(
              'Factory Reset',
              style: TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.w900,
              ),
            ),
            subtitle: const Text(
              'This will erase all settings',
              style: TextStyle(color: Colors.black87, fontSize: 16),
            ),
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Factory Reset'),
                  content: const Text(
                    'Reset all settings to default?\n\nThis cannot be undone.',
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
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Settings reset to defaults'),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
