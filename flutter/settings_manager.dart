import 'dart:convert';
import 'package:alarm/alarm_schedule.dart';
import 'package:shared_preferences/shared_preferences.dart';
//import 'schedule_model.dart';

/// Manages app settings and preferences
class SettingsManager {
  static final SettingsManager _instance = SettingsManager._internal();
  factory SettingsManager() => _instance;
  SettingsManager._internal();

  SharedPreferences? _prefs;

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ============================================================================
  // DEVICE CONFIGURATION
  // ============================================================================

  /// Device Name (replaces Hub Language)
  String get deviceName => _prefs?.getString('device_name') ?? 'My Alarm System';
  Future<void> setDeviceName(String value) async {
    await _prefs?.setString('device_name', value);
  }

  /// Connected Device UUID
  String get connectedDeviceUuid => _prefs?.getString('connected_device_uuid') ?? '';
  Future<void> setConnectedDeviceUuid(String value) async {
    await _prefs?.setString('connected_device_uuid', value);
  }

  /// Check if device is configured
  bool get isDeviceConfigured => connectedDeviceUuid.isNotEmpty;

  /// First time setup completed
  bool get isFirstTimeSetup => _prefs?.getBool('first_time_setup') ?? true;
  Future<void> setFirstTimeSetup(bool value) async {
    await _prefs?.setBool('first_time_setup', value);
  }

  // ============================================================================
  // SCHEDULE MANAGEMENT (Replaces Timers)
  // ============================================================================

  /// Get all alarm schedules
  List<AlarmSchedule> getSchedules() {
    final schedulesJson = _prefs?.getStringList('alarm_schedules') ?? [];
    return schedulesJson
        .map((json) => AlarmSchedule.fromJson(jsonDecode(json)))
        .toList();
  }

  /// Save all schedules
  Future<void> setSchedules(List<AlarmSchedule> schedules) async {
    final schedulesJson = schedules
        .map((schedule) => jsonEncode(schedule.toJson()))
        .toList();
    await _prefs?.setStringList('alarm_schedules', schedulesJson);
  }

  /// Add a new schedule
  Future<void> addSchedule(AlarmSchedule schedule) async {
    final schedules = getSchedules();
    schedules.add(schedule);
    await setSchedules(schedules);
  }

  /// Update existing schedule
  Future<void> updateSchedule(AlarmSchedule schedule) async {
    final schedules = getSchedules();
    final index = schedules.indexWhere((s) => s.id == schedule.id);
    if (index != -1) {
      schedules[index] = schedule;
      await setSchedules(schedules);
    }
  }

  /// Delete a schedule
  Future<void> deleteSchedule(String scheduleId) async {
    final schedules = getSchedules();
    schedules.removeWhere((s) => s.id == scheduleId);
    await setSchedules(schedules);
  }

  /// Toggle schedule enabled/disabled
  Future<void> toggleSchedule(String scheduleId) async {
    final schedules = getSchedules();
    final index = schedules.indexWhere((s) => s.id == scheduleId);
    if (index != -1) {
      schedules[index] = schedules[index].copyWith(
        isEnabled: !schedules[index].isEnabled,
      );
      await setSchedules(schedules);
    }
  }

  /// Check if any schedule is currently active
  bool isAnyScheduleActive() {
    final schedules = getSchedules();
    return schedules.any((schedule) => schedule.isActiveNow());
  }

  /// Get currently active schedule
  AlarmSchedule? getActiveSchedule() {
    final schedules = getSchedules();
    try {
      return schedules.firstWhere((schedule) => schedule.isActiveNow());
    } catch (e) {
      return null;
    }
  }

  // ============================================================================
  // ALARM SETTINGS
  // ============================================================================

  // Exit Delay
  int get exitDelay => _prefs?.getInt('exit_delay') ?? 70;
  Future<void> setExitDelay(int value) async {
    await _prefs?.setInt('exit_delay', value);
  }

  // Entry Delay
  int get entryDelay => _prefs?.getInt('entry_delay') ?? 60;
  Future<void> setEntryDelay(int value) async {
    await _prefs?.setInt('entry_delay', value);
  }

  // Alarm Duration
  int get alarmDuration => _prefs?.getInt('alarm_duration') ?? 5;
  Future<void> setAlarmDuration(int value) async {
    await _prefs?.setInt('alarm_duration', value);
  }

  // Alarm Sound
  bool get alarmSound => _prefs?.getBool('alarm_sound') ?? true;
  Future<void> setAlarmSound(bool value) async {
    await _prefs?.setBool('alarm_sound', value);
  }

  // Sensor Low Battery Alarm
  bool get sensorLowBatteryAlarm => _prefs?.getBool('sensor_low_battery_alarm') ?? true;
  Future<void> setSensorLowBatteryAlarm(bool value) async {
    await _prefs?.setBool('sensor_low_battery_alarm', value);
  }

  // Alarm Notification
  bool get alarmNotification => _prefs?.getBool('alarm_notification') ?? true;
  Future<void> setAlarmNotification(bool value) async {
    await _prefs?.setBool('alarm_notification', value);
  }

  // Countdown with Tick Tone
  bool get countdownWithTickTone => _prefs?.getBool('countdown_tick_tone') ?? true;
  Future<void> setCountdownWithTickTone(bool value) async {
    await _prefs?.setBool('countdown_tick_tone', value);
  }

  // Alarm Call
  bool get alarmCall => _prefs?.getBool('alarm_call') ?? true;
  Future<void> setAlarmCall(bool value) async {
    await _prefs?.setBool('alarm_call', value);
  }

  // Alarm SMS
  bool get alarmSMS => _prefs?.getBool('alarm_sms') ?? true;
  Future<void> setAlarmSMS(bool value) async {
    await _prefs?.setBool('alarm_sms', value);
  }

  // Unanswered Phone Redial Times
  int get unansweredPhoneRedialTimes => _prefs?.getInt('unanswered_redial') ?? 2;
  Future<void> setUnansweredPhoneRedialTimes(int value) async {
    await _prefs?.setInt('unanswered_redial', value);
  }

  // Virtual Password
  String get virtualPassword => _prefs?.getString('virtual_password') ?? '';
  Future<void> setVirtualPassword(String value) async {
    await _prefs?.setString('virtual_password', value);
  }

  // Verify virtual password
  bool verifyPassword(String password) {
    final stored = virtualPassword;
    return stored.isEmpty || stored == password;
  }

  // ============================================================================
  // CONTACT NUMBERS
  // ============================================================================

  // Multiple Alarm Call Numbers
  List<String> get alarmCallNumbers => _prefs?.getStringList('alarm_call_numbers') ?? [];
  Future<void> setAlarmCallNumbers(List<String> numbers) async {
    await _prefs?.setStringList('alarm_call_numbers', numbers);
  }

  // Add a single call number
  Future<void> addAlarmCallNumber(String number) async {
    final numbers = alarmCallNumbers;
    if (!numbers.contains(number) && numbers.length < 6) {
      numbers.add(number);
      await setAlarmCallNumbers(numbers);
    }
  }

  // Remove a call number
  Future<void> removeAlarmCallNumber(String number) async {
    final numbers = alarmCallNumbers;
    numbers.remove(number);
    await setAlarmCallNumbers(numbers);
  }

  // Multiple Alarm SMS Numbers
  List<String> get alarmSMSNumbers => _prefs?.getStringList('alarm_sms_numbers') ?? [];
  Future<void> setAlarmSMSNumbers(List<String> numbers) async {
    await _prefs?.setStringList('alarm_sms_numbers', numbers);
  }

  // Add a single SMS number
  Future<void> addAlarmSMSNumber(String number) async {
    final numbers = alarmSMSNumbers;
    if (!numbers.contains(number) && numbers.length < 6) {
      numbers.add(number);
      await setAlarmSMSNumbers(numbers);
    }
  }

  // Remove an SMS number
  Future<void> removeAlarmSMSNumber(String number) async {
    final numbers = alarmSMSNumbers;
    numbers.remove(number);
    await setAlarmSMSNumbers(numbers);
  }

  // Get all contact numbers (call + SMS combined)
  List<String> getAllContactNumbers() {
    final allNumbers = <String>{};
    allNumbers.addAll(alarmCallNumbers);
    allNumbers.addAll(alarmSMSNumbers);
    return allNumbers.toList();
  }

  // Check if any contact numbers are configured
  bool hasContactNumbers() {
    return alarmCallNumbers.isNotEmpty || alarmSMSNumbers.isNotEmpty;
  }

  // ============================================================================
  // DEPRECATED (kept for backward compatibility)
  // ============================================================================

  @Deprecated('Use deviceName instead')
  String get hubLanguage => deviceName;

  @Deprecated('Use setDeviceName instead')
  Future<void> setHubLanguage(String value) async {
    await setDeviceName(value);
  }

  @Deprecated('Use alarmCallNumbers instead')
  String get alarmCallNumber {
    final numbers = alarmCallNumbers;
    return numbers.isEmpty ? '' : numbers.first;
  }

  @Deprecated('Use setAlarmCallNumbers instead')
  Future<void> setAlarmCallNumber(String value) async {
    if (value.isNotEmpty) {
      await setAlarmCallNumbers([value]);
    }
  }

  @Deprecated('Use alarmSMSNumbers instead')
  String get alarmSMSNumber {
    final numbers = alarmSMSNumbers;
    return numbers.isEmpty ? '' : numbers.first;
  }

  @Deprecated('Use setAlarmSMSNumbers instead')
  Future<void> setAlarmSMSNumber(String value) async {
    if (value.isNotEmpty) {
      await setAlarmSMSNumbers([value]);
    }
  }

  // ============================================================================
  // FACTORY RESET
  // ============================================================================

  Future<void> factoryReset() async {
    await _prefs?.clear();
  }
}