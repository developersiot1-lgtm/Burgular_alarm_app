import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class ApiService {
  static const String baseUrl = 'https://monsow.in/alarm/index.php';

  // ============================================
  // DEVICE REGISTRY METHODS (NEW)
  // ============================================

  /// Check if device exists in registry
  Future<Map<String, dynamic>?> deviceCheckExists(String deviceUuid) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=device_check_exists&device_uuid=$deviceUuid'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        return json.decode(response.body);

      }
      return null;
    } catch (e) {
      print('❌ Device check exists error: $e');
      return null;
    }
  }

  /// Register new device in registry
  Future<Map<String, dynamic>?> deviceRegister({
    required String deviceUuid,
    required String deviceName,
    required String deviceType,
    required String connectionType,
    String? qrData,
    String? macAddress,
    String? ipAddress,
    String? bleServiceUuid,
    int? batteryLevel,
    int? signalStrength,
    String? firmwareVersion,
    String? zoneName,
    String? manufacturer,
    String? model,
    Map<String, dynamic>? capabilities,
  }) async {
    try {
      final data = {
        'device_uuid': deviceUuid,
        'device_name': deviceName,
        'device_type': deviceType,
        'connection_type': connectionType,
      };

      // Add optional fields
      if (qrData != null) data['qr_data'] = qrData;
      if (macAddress != null) data['mac_address'] = macAddress;
      if (ipAddress != null) data['ip_address'] = ipAddress;
      if (bleServiceUuid != null) data['ble_service_uuid'] = bleServiceUuid;
      if (batteryLevel != null) data['battery_level'] = batteryLevel.toString();
      if (signalStrength != null) data['signal_strength'] = signalStrength .toString();
      if (firmwareVersion != null) data['firmware_version'] = firmwareVersion;
      if (zoneName != null) data['zone_name'] = zoneName;
      if (manufacturer != null) data['manufacturer'] = manufacturer;
      if (model != null) data['model'] = model;
      if (capabilities != null) data['capabilities'] = capabilities.toString();

      final response = await http.post(
        Uri.parse('$baseUrl?action=device_register'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(data),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return null;
    } catch (e) {
      print('❌ Device register error: $e');
      return null;
    }
  }

  /// Get device information
  Future<Map<String, dynamic>?> deviceGetInfo(String deviceUuid) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=device_info&device_uuid=$deviceUuid'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return null;
    } catch (e) {
      print('❌ Device get info error: $e');
      return null;
    }
  }

  /// Send device heartbeat
  Future<bool> deviceHeartbeat({
    required String deviceUuid,
    int? batteryLevel,
    int? signalStrength,
    double? temperature,
    int? cpuUsage,
    int? memoryUsage,
  }) async {
    try {
      final data = {'device_uuid': deviceUuid};

      if (batteryLevel != null) data['battery_level'] = batteryLevel.toString();
      if (signalStrength != null) data['signal_strength'] = signalStrength.toString();
      if (temperature != null) data['temperature'] = temperature.toString();
      if (cpuUsage != null) data['cpu_usage'] = cpuUsage.toString();
      if (memoryUsage != null) data['memory_usage'] = memoryUsage.toString();

      final response = await http.post(
        Uri.parse('$baseUrl?action=device_heartbeat'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(data),
      ).timeout(Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      print('❌ Device heartbeat error: $e');
      return false;
    }
  }

  /// Create device relationship
  Future<bool> createDeviceRelationship({
    required String parentDeviceUuid,
    required String childDeviceUuid,
    String relationshipType = 'controls',
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl?action=device_create_relationship'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'parent_device_uuid': parentDeviceUuid,
          'child_device_uuid': childDeviceUuid,
          'relationship_type': relationshipType,
        }),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ Create relationship error: $e');
      return false;
    }
  }

  /// List all devices
  Future<List<dynamic>> deviceList() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=device_list'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['devices'] ?? [];
      }
      return [];
    } catch (e) {
      print('❌ Device list error: $e');
      return [];
    }
  }

  /// List devices by type
  Future<List<dynamic>> deviceListByType(String type) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=device_list_by_type&type=$type'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['devices'] ?? [];
      }
      return [];
    } catch (e) {
      print('❌ Device list by type error: $e');
      return [];
    }
  }

  /// Update device name
  Future<bool> updateDeviceName(String deviceUuid, String deviceName) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl?action=updatedevicename'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'device_uuid': deviceUuid,
          'device_name': deviceName,
        }),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ Update device name error: $e');
      return false;
    }
  }

  /// Delete device
  Future<bool> deleteDevice(String deviceUuid) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl?action=deletedevice'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'device_uuid': deviceUuid,
        }),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ Delete device error: $e');
      return false;
    }
  }

  // ============================================
  // EXISTING METHODS (KEPT FOR COMPATIBILITY)
  // ============================================

  /// Register mobile device (legacy method)
  Future<Map<String, dynamic>> registerMobileDevice(
      String deviceUuid,
      String displayName,
      String qrData,
      ) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl?action=register_mobile_device'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'device_uuid': deviceUuid,
          'display_name': displayName,
          'qr_data': qrData,
        }),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      throw Exception('Failed to register device');
    } catch (e) {
      print('❌ Register mobile device error: $e');
      rethrow;
    }
  }

  /// Get system state
  Future<Map<String, dynamic>?> getSystemState() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=system_state'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return null;
    } catch (e) {
      print('❌ Get system state error: $e');
      return null;
    }
  }

  /// Update system state
  Future<void> updateSystemState(String state, {String? user}) async {
    try {
      await http.post(
        Uri.parse('$baseUrl?action=system_state'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'state': state,
          'user': user ?? 'Mobile App',
        }),
      ).timeout(Duration(seconds: 10));
    } catch (e) {
      print('❌ Update system state error: $e');
      rethrow;
    }
  }

  /// Trigger SOS
  Future<void> triggerSOS() async {
    await updateSystemState('alarm', user: 'SOS TRIGGER');
  }

  /// Get devices
  Future<List<dynamic>> getDevices() async {
    return deviceList();
  }

  /// Get mobile devices
  Future<List<dynamic>> getMobileDevices() async {
    return deviceList();
  }

  /// Get activity logs
  Future<List<dynamic>> getActivityLogs({int limit = 50}) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=logs&limit=$limit'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['logs'] ?? [];
      }
      return [];
    } catch (e) {
      print('❌ Get activity logs error: $e');
      return [];
    }
  }

  // ============================================
  // SETTINGS MANAGEMENT
  // ============================================

  /// Get settings
  Future<Map<String, dynamic>?> getSettings(String deviceUuid) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=get_settings&device_uuid=$deviceUuid'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['settings'];
      }
      return null;
    } catch (e) {
      print('❌ Get settings error: $e');
      return null;
    }
  }

  /// Save settings
  Future<bool> saveSettings(String deviceUuid, Map<String, dynamic> settings) async {
    try {
      final data = {
        'device_uuid': deviceUuid,
        ...settings,
      };

      final response = await http.post(
        Uri.parse('$baseUrl?action=save_settings'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(data),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ Save settings error: $e');
      return false;
    }
  }

  /// Sync settings to device
  Future<Map<String, dynamic>?> syncSettingsToDevice(String deviceUuid) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=sync_settings_to_device&device_uuid=$deviceUuid'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return null;
    } catch (e) {
      print('❌ Sync settings error: $e');
      return null;
    }
  }

  // ============================================
  // SCHEDULE MANAGEMENT
  // ============================================

  /// Get schedules
  Future<List<dynamic>> getSchedules(String deviceUuid) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=get_schedules&device_uuid=$deviceUuid'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['schedules'] ?? [];
      }
      return [];
    } catch (e) {
      print('❌ Get schedules error: $e');
      return [];
    }
  }

  /// Save schedules
  Future<bool> saveSchedules(String deviceUuid, List<Map<String, dynamic>> schedules) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl?action=save_schedules'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'device_uuid': deviceUuid,
          'schedules': schedules,
        }),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ Save schedules error: $e');
      return false;
    }
  }

  /// Delete schedule
  Future<bool> deleteSchedule(String deviceUuid, String scheduleId) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl?action=delete_schedule'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'device_uuid': deviceUuid,
          'schedule_id': scheduleId,
        }),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ Delete schedule error: $e');
      return false;
    }
  }

  /// Toggle schedule
  Future<bool> toggleSchedule(String deviceUuid, String scheduleId) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl?action=toggle_schedule'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'device_uuid': deviceUuid,
          'schedule_id': scheduleId,
        }),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ Toggle schedule error: $e');
      return false;
    }
  }

  // ============================================
  // VOICE RECORDINGS
  // ============================================

  /// Upload voice recording
  Future<bool> uploadVoiceRecording({
    required String name,
    required String filePath,
    int sampleRate = 8000,
  }) async {
    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl?action=save_voice_recording'),
      );

      request.fields['name'] = name;
      request.fields['sample_rate'] = sampleRate.toString();

      request.files.add(
        await http.MultipartFile.fromPath('voice_file', filePath),
      );

      final response = await request.send().timeout(Duration(seconds: 30));

      return response.statusCode == 200;
    } catch (e) {
      print('❌ Upload voice recording error: $e');
      return false;
    }
  }

  /// Get voice recordings
  Future<List<dynamic>> getVoiceRecordings() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=get_voice_recordings'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['recordings'] ?? [];
      }
      return [];
    } catch (e) {
      print('❌ Get voice recordings error: $e');
      return [];
    }
  }

  /// Fetch and save voice recording
  Future<String> fetchAndSaveVoiceH(int recordingId) async {
    try {
      final recordings = await getVoiceRecordings();
      final recording = recordings.firstWhere(
            (r) => r['id'] == recordingId,
        orElse: () => null,
      );

      if (recording == null) {
        throw Exception('Recording not found');
      }

      final dir = await getApplicationDocumentsDirectory();
      final filePath = '${dir.path}/voice_${recordingId}.wav';

      // If file_url exists, download it
      if (recording['file_url'] != null) {
        final response = await http.get(Uri.parse(recording['file_url']));
        if (response.statusCode == 200) {
          await File(filePath).writeAsBytes(response.bodyBytes);
        }
      }

      return filePath;
    } catch (e) {
      print('❌ Fetch voice recording error: $e');
      rethrow;
    }
  }

  // ============================================
  // CONTACT NUMBERS
  // ============================================

  /// Get contact numbers
  Future<List<dynamic>> getContactNumbers(String deviceUuid) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=get_contact_numbers&device_uuid=$deviceUuid'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['contacts'] ?? [];
      }
      return [];
    } catch (e) {
      print('❌ Get contact numbers error: $e');
      return [];
    }
  }

  /// Add contact number
  Future<bool> addContactNumber({
    required String deviceUuid,
    required String phoneNumber,
    required String numberType, // 'call' or 'sms'
    String? contactName,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl?action=add_contact_number'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'device_uuid': deviceUuid,
          'phone_number': phoneNumber,
          'number_type': numberType,
          'contact_name': contactName,
        }),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ Add contact number error: $e');
      return false;
    }
  }

  /// Delete contact number
  Future<bool> deleteContactNumber({
    required String deviceUuid,
    required int contactId,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl?action=delete_contact_number'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'device_uuid': deviceUuid,
          'contact_id': contactId,
        }),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ Delete contact number error: $e');
      return false;
    }
  }
}
