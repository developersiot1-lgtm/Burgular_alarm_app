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
      final response = await http
          .get(
            Uri.parse(
                '$baseUrl?action=device_check_exists&device_uuid=$deviceUuid'),
          )
          .timeout(Duration(seconds: 10));

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
      if (signalStrength != null)
        data['signal_strength'] = signalStrength.toString();
      if (firmwareVersion != null) data['firmware_version'] = firmwareVersion;
      if (zoneName != null) data['zone_name'] = zoneName;
      if (manufacturer != null) data['manufacturer'] = manufacturer;
      if (model != null) data['model'] = model;
      if (capabilities != null) data['capabilities'] = jsonEncode(capabilities);

      final response = await http
          .post(
            Uri.parse('$baseUrl?action=device_register'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(data),
          )
          .timeout(Duration(seconds: 10));

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
      final response = await http
          .get(
            Uri.parse('$baseUrl?action=device_info&device_uuid=$deviceUuid'),
          )
          .timeout(Duration(seconds: 10));

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
      if (signalStrength != null)
        data['signal_strength'] = signalStrength.toString();
      if (temperature != null) data['temperature'] = temperature.toString();
      if (cpuUsage != null) data['cpu_usage'] = cpuUsage.toString();
      if (memoryUsage != null) data['memory_usage'] = memoryUsage.toString();

      final response = await http
          .post(
            Uri.parse('$baseUrl?action=device_heartbeat'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(data),
          )
          .timeout(Duration(seconds: 10));

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
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=device_create_relationship'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'parent_device_uuid': parentDeviceUuid,
              'child_device_uuid': childDeviceUuid,
              'relationship_type': relationshipType,
            }),
          )
          .timeout(Duration(seconds: 10));

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
      final response = await http
          .get(
            Uri.parse('$baseUrl?action=device_list'),
          )
          .timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['devices'] ?? [];
      }
      return [];
    } catch (e) {
      print('❌ Device list error: $e');
      rethrow;
    }
  }

  /// List devices by type
  Future<List<dynamic>> deviceListByType(String type) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl?action=device_list_by_type&type=$type'),
          )
          .timeout(Duration(seconds: 10));

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
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=updatedevicename'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'device_uuid': deviceUuid,
              'device_name': deviceName,
            }),
          )
          .timeout(Duration(seconds: 10));

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
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=deletedevice'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'device_uuid': deviceUuid,
            }),
          )
          .timeout(Duration(seconds: 10));

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

  Future<Map<String, dynamic>?> registerMobileDevice(
    String deviceUuid,
    String displayName,
    String qrData,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=register_mobile_device'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'deviceuuid': deviceUuid,
              'displayname': displayName,
              'qrdata': qrData,
            }),
          )
          .timeout(Duration(seconds: 10));

      print('REGISTER STATUS: ${response.statusCode}');
      print('REGISTER BODY: ${response.body}');

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      throw Exception(
          'Failed to register device: ${response.statusCode} ${response.body}');
    } catch (e) {
      print('Register mobile device error: $e');
      rethrow;
    }
  }

  /// Get system state
  Future<Map<String, dynamic>?> getSystemState({String? hubDeviceUuid}) async {
    try {
      // Build URL: if we have a hubDeviceUuid, pass it so the server
      // returns the state row for THAT device only.
      final uri = hubDeviceUuid != null && hubDeviceUuid.isNotEmpty
          ? Uri.parse(
              '$baseUrl?action=system_state&device_uuid=${Uri.encodeComponent(hubDeviceUuid)}')
          : Uri.parse('$baseUrl?action=system_state');

      final response = await http.get(uri).timeout(Duration(seconds: 10));

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
  Future<void> updateSystemState(
    String state, {
    required String deviceUuid,
    String? user,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=system_state'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'state': state,
              'user': user ?? 'Mobile App',
              'device_uuid': deviceUuid,
            }),
          )
          .timeout(const Duration(seconds: 5)); // ← was missing entirely

      if (response.statusCode != 200) {
        throw Exception(
            'Failed to update system state (${response.statusCode}): ${response.body}');
      }
    } catch (e) {
      print('❌ updateSystemState error: $e');
      rethrow;
    }
  }

  /// Trigger SOS
  Future<void> triggerSOS(String deviceUuid) async {
    await updateSystemState(
      'alarm',
      deviceUuid: deviceUuid,
      user: 'SOS TRIGGER',
    );
  }

  /// Get devices
  Future<List<dynamic>> getDevices() async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl?action=devices'),
          )
          .timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['devices'] ?? [];
      }
      return [];
    } catch (e) {
      print('❌ Get devices error: $e');
      return [];
    }
  }

  /// Get mobile devices
  Future<List<dynamic>> getMobileDevices({String? deviceUuid}) async {
    try {
      final uri = deviceUuid != null && deviceUuid.isNotEmpty
          ? Uri.parse(
              '$baseUrl?action=mobile_devices&device_uuid=${Uri.encodeComponent(deviceUuid)}')
          : Uri.parse('$baseUrl?action=mobile_devices');

      final response = await http
          .get(
            uri,
          )
          .timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['devices'] ?? [];
      }
      return [];
    } catch (e) {
      print('❌ Get mobile devices error: $e');
      return [];
    }
  }

  /// Get activity logs
  Future<List<dynamic>> getActivityLogs({
    int limit = 100,
    String? deviceUuid,
  }) async {
    try {
      final uri = deviceUuid != null && deviceUuid.isNotEmpty
          ? Uri.parse(
              '$baseUrl?action=logs&limit=$limit&device_uuid=${Uri.encodeComponent(deviceUuid)}',
            )
          : Uri.parse('$baseUrl?action=logs&limit=$limit');

      final response = await http.get(uri).timeout(Duration(seconds: 10));

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

  Future<bool> postActivityLog({
    required String event,
    required String device,
    required String user,
    String? deviceUuid,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=logs'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'event': event,
              'device': device,
              'user': user,
              if (deviceUuid != null && deviceUuid.isNotEmpty)
                'device_uuid': deviceUuid,
            }),
          )
          .timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ Post activity log error: $e');
      return false;
    }
  }

  // ============================================
  // SETTINGS MANAGEMENT
  // ============================================

  /// Get settings
  Future<Map<String, dynamic>?> getSettings(String deviceUuid) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl?action=get_settings&device_uuid=$deviceUuid'),
          )
          .timeout(Duration(seconds: 10));

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
  Future<bool> saveSettings(
      String deviceUuid, Map<String, dynamic> settings) async {
    try {
      final data = {
        'device_uuid': deviceUuid,
        ...settings,
      };

      final response = await http
          .post(
            Uri.parse('$baseUrl?action=save_settings'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(data),
          )
          .timeout(const Duration(seconds: 6));

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
      final response = await http
          .get(
            Uri.parse(
                '$baseUrl?action=sync_settings_to_device&device_uuid=$deviceUuid'),
          )
          .timeout(Duration(seconds: 10));

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
      final response = await http
          .get(
            Uri.parse('$baseUrl?action=get_schedules&device_uuid=$deviceUuid'),
          )
          .timeout(Duration(seconds: 10));

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
  Future<bool> saveSchedules(
      String deviceUuid, List<Map<String, dynamic>> schedules) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=save_schedules'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'device_uuid': deviceUuid,
              'schedules': schedules,
            }),
          )
          .timeout(Duration(seconds: 10));

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
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=delete_schedule'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'device_uuid': deviceUuid,
              'schedule_id': scheduleId,
            }),
          )
          .timeout(Duration(seconds: 10));

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
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=toggle_schedule'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'device_uuid': deviceUuid,
              'schedule_id': scheduleId,
            }),
          )
          .timeout(Duration(seconds: 10));

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
      final response = await http
          .get(
            Uri.parse('$baseUrl?action=get_voice_recordings'),
          )
          .timeout(Duration(seconds: 10));

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
      final response = await http
          .get(
            Uri.parse(
              '$baseUrl?action=get_contact_numbers&device_uuid=${Uri.encodeComponent(deviceUuid)}',
            ),
          )
          .timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['contacts'] ?? [];
      }
      throw Exception('Failed to get contact numbers: ${response.body}');
    } catch (e) {
      print('❌ Get contact numbers error: $e');
      rethrow;
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
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=add_contact_number'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'device_uuid': deviceUuid,
              'phone_number': phoneNumber,
              'number_type': numberType,
              'contact_name': contactName,
            }),
          )
          .timeout(Duration(seconds: 10));

      print('ADD CONTACT STATUS: ${response.statusCode}');
      print('ADD CONTACT BODY: ${response.body}');

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true ||
            result['saved'] == true ||
            result['message']?.toString().toLowerCase().contains('success') ==
                true;
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
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=delete_contact_number'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'device_uuid': deviceUuid,
              'contact_id': contactId,
            }),
          )
          .timeout(Duration(seconds: 10));

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

  Future<Map<String, dynamic>?> accessoryPair({
    required String hubDeviceUuid,
    required String accessoryUuid,
    required String name,
    required String type,
    required String zoneName,
    String? remoteMode,
    String? deviceBleName,
    String status = 'pairing',
  }) async {
    try {
      final body = {
        'hub_device_uuid': hubDeviceUuid,
        'accessory_uuid': accessoryUuid,
        'name': name,
        'type': type,
        'zone_name': zoneName,
        'status': status,
        if (remoteMode != null) 'remote_mode': remoteMode,
        if (deviceBleName != null) 'device_ble_name': deviceBleName,
      };

      final response = await http
          .post(
            Uri.parse('$baseUrl?action=accessory_pair'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final decoded = json.decode(response.body) as Map<String, dynamic>;
        print('✅ accessoryPair response: $decoded');
        return decoded;
      }
      print('❌ accessoryPair HTTP ${response.statusCode}: ${response.body}');
      return null;
    } catch (e) {
      print('❌ accessoryPair error: $e');
      return null;
    }
  }

  /// List all paired accessories for a hub.
  Future<List<dynamic>> accessoryList(String hubDeviceUuid,
      {String? type}) async {
    try {
      var url = '$baseUrl?action=accessory_list&hub_device_uuid=$hubDeviceUuid';
      if (type != null) url += '&type=$type';

      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return json.decode(response.body)['accessories'] ?? [];
      }
      return [];
    } catch (e) {
      print('❌ accessoryList error: $e');
      return [];
    }
  }

  /// Soft-delete a paired accessory by its UUID.
  Future<bool> accessoryDelete(String accessoryUuid) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=accessory_delete'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'accessory_uuid': accessoryUuid}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return json.decode(response.body)['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ accessoryDelete error: $e');
      return false;
    }
  }

  // ============================================
  // ACCESSORY PAIRING — SERVER-SIDE HANDSHAKE
  // ============================================

  /// GET ?action=get_pairing_request&device_uuid=HUB_UUID
  ///
  /// Called by the ESP32 hub to check if the mobile app has queued
  /// a pairing request. Returns the oldest 'pairing' record for
  /// that hub, or { has_request: false } if nothing is pending.
  Future<PairingRequestResult> getPairingRequest(String hubDeviceUuid) async {
    try {
      final response = await http
          .get(
            Uri.parse(
                '$baseUrl?action=get_pairing_request&device_uuid=$hubDeviceUuid'),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        return PairingRequestResult.fromJson(data);
      }
      return PairingRequestResult.none();
    } catch (e) {
      print('❌ getPairingRequest error: $e');
      return PairingRequestResult.none();
    }
  }

  /// POST ?action=update_pairing_status
  ///
  /// Called by the mobile app after BLE pairing completes.
  /// Updates the DB record with the real sensor MAC + BLE name
  /// and sets status to 'paired' or 'failed'.
  ///
  /// [pairingId]      — the id returned by getPairingRequest
  /// [accessoryUuid]  — real BLE MAC of the sensor (e.g. "AA:BB:CC:DD:EE:FF")
  /// [deviceBleName]  — BLE advertised name of the sensor
  /// [status]         — 'paired' or 'failed'
  Future<bool> accessoryUpdatePairingStatus({
    required int pairingId,
    String? accessoryUuid, // real BLE MAC — null if no ACK received
    String? deviceBleName,
    required String status, // 'paired' | 'failed' | 'timeout'
  }) async {
    try {
      final body = <String, dynamic>{
        'pairing_id': pairingId,
        'status': status,
        if (accessoryUuid != null) 'accessory_uuid': accessoryUuid,
        if (deviceBleName != null) 'device_ble_name': deviceBleName,
      };

      final response = await http
          .post(
            Uri.parse('$baseUrl?action=update_pairing_status'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body) as Map<String, dynamic>;
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ accessoryUpdatePairingStatus error: $e');
      return false;
    }
  }

  Future<bool> postAlarmEvent({
    required String deviceUuid,
    required String eventType, // 'ALARM_START' | 'ALARM_TRIGGER' | 'ALARM_STOP'
    String zone = '',
    String message = '',
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl?action=alarm_event'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'device_uuid': deviceUuid,
              'event_type': eventType,
              'zone': zone,
              'message': message,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final result = json.decode(response.body) as Map<String, dynamic>;
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ postAlarmEvent error: $e');
      return false;
    }
  }

  Future<List<dynamic>> getAlarmEvents(String deviceUuid) async {
    try {
      final response = await http.get(
        Uri.parse(
            '$baseUrl?action=alarm_events&device_uuid=$deviceUuid&latest=true'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['events'] ?? [];
      }
    } catch (e) {
      print('Error fetching alarm events: $e');
    }
    return [];
  }

  Future<Map<String, dynamic>?> getAlarmStatus(String deviceUuid) async {
    try {
      final response = await http
          .get(
            Uri.parse(
                '$baseUrl?action=get_alarm_status&device_uuid=$deviceUuid&include_devices=true'),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      print('❌ Get alarm status error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getLatestEvent(String deviceUuid) async {
    try {
      final res = await http.get(
        Uri.parse('$baseUrl?action=latest_event&device_uuid=$deviceUuid'),
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);

        if (data is Map<String, dynamic>) {
          return data;
        }

        return null;
        //return json.decode(res.body);
      }
    } catch (e) {
      print('❌ getLatestEvent error: $e');
    }
    return null;
  }

  // ── GET WIFI UUID BY BLE MAC ────────────────────────────────────────────
  // After Flutter sends WiFi credentials via BLE, the ESP32 connects to WiFi
  // and calls index.php?uuid=ESP32_ALARM_XXXX. PHP merges the BLE MAC record
  // with that WiFi UUID. This method polls device_list to find the merged record.
  // Returns the WiFi UUID (e.g. "ESP32_ALARM_70A2A0A0DC5194") or null if not found.
  Future<String?> getWifiUuidByBleUuid(String bleMac) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl?action=device_list'),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) return null;

      final result = json.decode(response.body);
      final devices = result['devices'] as List<dynamic>? ?? [];

      for (final device in devices) {
        final uuid = device['device_uuid']?.toString() ?? '';
        final bleSvc = device['ble_service_uuid']?.toString() ?? '';

        // Match: ble_service_uuid equals our BLE MAC
        // AND device_uuid is now a WiFi UUID (not a MAC address format XX:XX:XX:XX:XX:XX)
        if ((bleSvc == bleMac || uuid == bleMac) && uuid.isNotEmpty) {
          print('✅ WiFi UUID found: $uuid (ble_mac=$bleSvc)');
          return uuid;
        }
      }
      return null;
    } catch (e) {
      print('⚠️ getWifiUuidByBleUuid error: $e');
      return null;
    }
  }
}

// ============================================================
// PairingRequestResult — returned by getPairingRequest()
// ============================================================
class PairingRequestResult {
  final bool hasRequest;
  final int? pairingId;
  final String? accessoryUuid;
  final String? accessoryType; // 'remote' | 'motion' | 'door'
  final String? accessoryName;
  final String? zoneName;
  final String? remoteMode; // 'armed' | 'disarmed' | null
  final String? requestedAt;

  PairingRequestResult({
    required this.hasRequest,
    this.pairingId,
    this.accessoryUuid,
    this.accessoryType,
    this.accessoryName,
    this.zoneName,
    this.remoteMode,
    this.requestedAt,
  });

  factory PairingRequestResult.none() =>
      PairingRequestResult(hasRequest: false);

  factory PairingRequestResult.fromJson(Map<String, dynamic> json) {
    if (json['has_request'] != true) return PairingRequestResult.none();
    return PairingRequestResult(
      hasRequest: true,
      pairingId: json['pairing_id'] is int
          ? json['pairing_id']
          : int.tryParse('${json['pairing_id']}'),
      accessoryUuid: json['accessory_uuid'],
      accessoryType: json['accessory_type'],
      accessoryName: json['accessory_name'],
      zoneName: json['zone_name'],
      remoteMode: json['remote_mode'],
      requestedAt: json['requested_at'],
    );
  }
}
