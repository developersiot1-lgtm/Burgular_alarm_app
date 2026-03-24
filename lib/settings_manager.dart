import 'dart:convert';
import 'package:alarm/alarm_schedule.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// User-visible display name for this device (shown in UI, stored in device_registry.device_name)
  String get deviceName => _prefs?.getString('device_name') ?? 'My Alarm System';
  Future<void> setDeviceName(String value) async =>
      _prefs?.setString('device_name', value);

  /// The ESP32/BLE identifier string (e.g. "ESP32_ALARM_SETUP_5194").
  /// Stored in device_settings as key "hub_language".
  /// Set once during pairing — NOT the user-editable display name.
  String get hubLanguage => _prefs?.getString('hub_language') ?? '';
  Future<void> setHubLanguage(String value) async =>
      _prefs?.setString('hub_language', value);

  String get connectedDeviceUuid =>
      _prefs?.getString('connected_device_uuid') ?? '';
  Future<void> setConnectedDeviceUuid(String value) async =>
      _prefs?.setString('connected_device_uuid', value);

  bool get isDeviceConfigured => connectedDeviceUuid.isNotEmpty;

  bool get isFirstTimeSetup => _prefs?.getBool('first_time_setup') ?? true;
  Future<void> setFirstTimeSetup(bool value) async =>
      _prefs?.setBool('first_time_setup', value);

  // ============================================================================
  // SCHEDULE MANAGEMENT
  // ============================================================================

  List<AlarmSchedule> getSchedules() {
    final schedulesJson = _prefs?.getStringList('alarm_schedules') ?? [];
    return schedulesJson
        .map((json) => AlarmSchedule.fromJson(jsonDecode(json)))
        .toList();
  }

  Future<void> setSchedules(List<AlarmSchedule> schedules) async {
    final schedulesJson =
    schedules.map((s) => jsonEncode(s.toJson())).toList();
    await _prefs?.setStringList('alarm_schedules', schedulesJson);
  }

  Future<void> addSchedule(AlarmSchedule schedule) async {
    final schedules = getSchedules();
    schedules.add(schedule);
    await setSchedules(schedules);
  }

  Future<void> updateSchedule(AlarmSchedule schedule) async {
    final schedules = getSchedules();
    final index = schedules.indexWhere((s) => s.id == schedule.id);
    if (index != -1) {
      schedules[index] = schedule;
      await setSchedules(schedules);
    }
  }

  Future<void> deleteSchedule(String scheduleId) async {
    final schedules = getSchedules();
    schedules.removeWhere((s) => s.id == scheduleId);
    await setSchedules(schedules);
  }

  Future<void> toggleSchedule(String scheduleId) async {
    final schedules = getSchedules();
    final index = schedules.indexWhere((s) => s.id == scheduleId);
    if (index != -1) {
      schedules[index] =
          schedules[index].copyWith(isEnabled: !schedules[index].isEnabled);
      await setSchedules(schedules);
    }
  }

  bool isAnyScheduleActive() =>
      getSchedules().any((s) => s.isActiveNow());

  AlarmSchedule? getActiveSchedule() {
    try {
      return getSchedules().firstWhere((s) => s.isActiveNow());
    } catch (_) {
      return null;
    }
  }

  // ============================================================================
  // ALARM TIMING SETTINGS
  // Keys must exactly match PHP $setting_keys in saveSettings()
  // ============================================================================

  int get exitDelay => _prefs?.getInt('exit_delay') ?? 70;
  Future<void> setExitDelay(int value) async =>
      _prefs?.setInt('exit_delay', value);

  int get entryDelay => _prefs?.getInt('entry_delay') ?? 60;
  Future<void> setEntryDelay(int value) async =>
      _prefs?.setInt('entry_delay', value);

  int get alarmDuration => _prefs?.getInt('alarm_duration') ?? 5;
  Future<void> setAlarmDuration(int value) async =>
      _prefs?.setInt('alarm_duration', value);

  // ============================================================================
  // ALARM NOTIFICATION SETTINGS
  // ============================================================================

  bool get alarmSound => _prefs?.getBool('alarm_sound') ?? true;
  Future<void> setAlarmSound(bool value) async =>
      _prefs?.setBool('alarm_sound', value);

  bool get alarmNotification => _prefs?.getBool('alarm_notification') ?? true;
  Future<void> setAlarmNotification(bool value) async =>
      _prefs?.setBool('alarm_notification', value);

  bool get countdownWithTickTone =>
      _prefs?.getBool('countdown_with_tick_tone') ?? true;
  Future<void> setCountdownWithTickTone(bool value) async =>
      _prefs?.setBool('countdown_with_tick_tone', value);

  bool get sensorLowBatteryAlarm =>
      _prefs?.getBool('sensor_low_battery_alarm') ?? true;
  Future<void> setSensorLowBatteryAlarm(bool value) async =>
      _prefs?.setBool('sensor_low_battery_alarm', value);

  /// ✅ FIX: was completely missing — push notification when arm/disarm happens
  bool get armDisarmNotification =>
      _prefs?.getBool('arm_disarm_notification') ?? true;
  Future<void> setArmDisarmNotification(bool value) async =>
      _prefs?.setBool('arm_disarm_notification', value);

  /// ✅ FIX: was completely missing — alarm triggers if device cover is tampered
  bool get tamperAlarm => _prefs?.getBool('tamper_alarm') ?? true;
  Future<void> setTamperAlarm(bool value) async =>
      _prefs?.setBool('tamper_alarm', value);

  /// ✅ FIX: was completely missing — push notification for low battery (vs alarm sound)
  bool get sensorLowBatteryNotification =>
      _prefs?.getBool('sensor_low_battery_notification') ?? true;
  Future<void> setSensorLowBatteryNotification(bool value) async =>
      _prefs?.setBool('sensor_low_battery_notification', value);

  // ============================================================================
  // ALERT SETTINGS
  // ============================================================================

  bool get alarmCall => _prefs?.getBool('alarm_call') ?? true;
  Future<void> setAlarmCall(bool value) async =>
      _prefs?.setBool('alarm_call', value);

  bool get alarmSMS => _prefs?.getBool('alarm_sms') ?? true;
  Future<void> setAlarmSMS(bool value) async =>
      _prefs?.setBool('alarm_sms', value);

  int get unansweredPhoneRedialTimes =>
      _prefs?.getInt('unanswered_phone_redial_times') ?? 2;
  Future<void> setUnansweredPhoneRedialTimes(int value) async =>
      _prefs?.setInt('unanswered_phone_redial_times', value);

  // ============================================================================
  // SECURITY
  // ============================================================================

  String get virtualPassword => _prefs?.getString('virtual_password') ?? '';
  Future<void> setVirtualPassword(String value) async =>
      _prefs?.setString('virtual_password', value);

  bool verifyPassword(String password) {
    final stored = virtualPassword;
    return stored.isEmpty || stored == password;
  }

  // ============================================================================
  // CONTACT NUMBERS
  // ============================================================================

  List<String> get alarmCallNumbers =>
      _prefs?.getStringList('alarm_call_numbers') ?? [];
  Future<void> setAlarmCallNumbers(List<String> numbers) async =>
      _prefs?.setStringList('alarm_call_numbers', numbers);

  Future<void> addAlarmCallNumber(String number) async {
    final numbers = alarmCallNumbers;
    if (!numbers.contains(number) && numbers.length < 6) {
      numbers.add(number);
      await setAlarmCallNumbers(numbers);
    }
  }

  Future<void> removeAlarmCallNumber(String number) async {
    final numbers = alarmCallNumbers;
    numbers.remove(number);
    await setAlarmCallNumbers(numbers);
  }

  List<String> get alarmSMSNumbers =>
      _prefs?.getStringList('alarm_sms_numbers') ?? [];
  Future<void> setAlarmSMSNumbers(List<String> numbers) async =>
      _prefs?.setStringList('alarm_sms_numbers', numbers);

  Future<void> addAlarmSMSNumber(String number) async {
    final numbers = alarmSMSNumbers;
    if (!numbers.contains(number) && numbers.length < 6) {
      numbers.add(number);
      await setAlarmSMSNumbers(numbers);
    }
  }

  Future<void> removeAlarmSMSNumber(String number) async {
    final numbers = alarmSMSNumbers;
    numbers.remove(number);
    await setAlarmSMSNumbers(numbers);
  }

  List<String> getAllContactNumbers() {
    final all = <String>{};
    all.addAll(alarmCallNumbers);
    all.addAll(alarmSMSNumbers);
    return all.toList();
  }

  bool hasContactNumbers() =>
      alarmCallNumbers.isNotEmpty || alarmSMSNumbers.isNotEmpty;

  // ============================================================================
  // FACTORY RESET
  // ============================================================================

  Future<void> factoryReset() async => _prefs?.clear();
}