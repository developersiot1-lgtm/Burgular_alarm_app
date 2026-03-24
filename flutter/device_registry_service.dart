import 'dart:convert';
import 'package:http/http.dart' as http;

/// Service for managing device registry operations
class DeviceRegistryService {
  final String baseUrl;

  DeviceRegistryService({required this.baseUrl});

  /// Check if device exists
  Future<DeviceCheckResult?> checkDeviceExists(String deviceUuid) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=device_check_exists&device_uuid=$deviceUuid'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return DeviceCheckResult.fromJson(data);
      }
      return null;
    } catch (e) {
      print('❌ Check device exists error: $e');
      return null;
    }
  }

  /// Register device
  Future<DeviceRegistrationResult?> registerDevice({
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
      final requestData = {
        'device_uuid': deviceUuid,
        'display_name': deviceName,
        'device_name': deviceName,
        'device_type': deviceType,
        'connection_type': connectionType,
      };

      // Add optional fields
      if (qrData != null) requestData['qr_data'] = qrData;
      if (macAddress != null) requestData['mac_address'] = macAddress;
      if (ipAddress != null) requestData['ip_address'] = ipAddress;
      if (bleServiceUuid != null) requestData['ble_service_uuid'] = bleServiceUuid;
      if (batteryLevel != null) requestData['battery_level'] = batteryLevel.toString();
      if (signalStrength != null) requestData['signal_strength'] = signalStrength.toString();
      if (firmwareVersion != null) requestData['firmware_version'] = firmwareVersion;
      if (zoneName != null) requestData['zone_name'] = zoneName;
      if (manufacturer != null) requestData['manufacturer'] = manufacturer;
      if (model != null) requestData['model'] = model;
      if (capabilities != null) requestData['capabilities'] = jsonEncode(capabilities);

      print('📤 Sending device registration: $requestData');

      final response = await http.post(
        Uri.parse('$baseUrl?action=device_register'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(requestData),
      ).timeout(Duration(seconds: 10));

      print('📥 Response status: ${response.statusCode}');
      print('📥 Response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return DeviceRegistrationResult.fromJson(data);
      }

      print('❌ Registration failed with status: ${response.statusCode}');
      return null;
    } catch (e) {
      print('❌ Register device error: $e');
      return null;
    }
  }

  /// Get device info
  Future<Map<String, dynamic>?> getDeviceInfo(String deviceUuid) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=device_info&device_uuid=$deviceUuid'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return null;
    } catch (e) {
      print('❌ Get device info error: $e');
      return null;
    }
  }

  /// Send device heartbeat
  Future<bool> sendHeartbeat({
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
      print('❌ Send heartbeat error: $e');
      return false;
    }
  }

  /// Create device relationship
  Future<bool> createDeviceRelationship(
      String parentDeviceUuid,
      String childDeviceUuid,
      String relationshipType,
      ) async {
    try {
      print('🔗 Creating relationship: $parentDeviceUuid controls $childDeviceUuid');

      final response = await http.post(
        Uri.parse('$baseUrl?action=device_create_relationship'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'parent_device_uuid': parentDeviceUuid,
          'child_device_uuid': childDeviceUuid,
          'relationship_type': relationshipType,
        }),
      ).timeout(Duration(seconds: 10));

      print('📥 Relationship response: ${response.statusCode} - ${response.body}');

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
  Future<List<dynamic>> listDevices() async {
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
      print('❌ List devices error: $e');
      return [];
    }
  }

  /// List devices by type
  Future<List<dynamic>> listDevicesByType(String type) async {
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
      print('❌ List devices by type error: $e');
      return [];
    }
  }

  /// Get devices that need attention
  Future<List<dynamic>> getDevicesNeedingAttention() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl?action=device_need_attention'),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['devices'] ?? [];
      }
      return [];
    } catch (e) {
      print('❌ Get devices needing attention error: $e');
      return [];
    }
  }

  /// Update device setting
  Future<bool> updateDeviceSetting({
    required String deviceUuid,
    required String settingKey,
    required dynamic settingValue,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl?action=device_update_setting'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'device_uuid': deviceUuid,
          'setting_key': settingKey,
          'setting_value': settingValue,
        }),
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      print('❌ Update device setting error: $e');
      return false;
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
}

/// Result of device existence check
class DeviceCheckResult {
  final bool exists;
  final int? deviceId;
  final String? deviceName;
  final String? deviceType;
  final String? status;
  final String? lastSeenAt;

  DeviceCheckResult({
    required this.exists,
    this.deviceId,
    this.deviceName,
    this.deviceType,
    this.status,
    this.lastSeenAt,
  });

  factory DeviceCheckResult.fromJson(Map<String, dynamic> json) {
    // Handle device_id as either String or int
    int? parsedDeviceId;
    if (json['device_id'] != null) {
      if (json['device_id'] is String) {
        parsedDeviceId = int.tryParse(json['device_id']);
      } else if (json['device_id'] is int) {
        parsedDeviceId = json['device_id'];
      }
    }

    return DeviceCheckResult(
      exists: json['exists'] ?? false,
      deviceId: parsedDeviceId,
      deviceName: json['device_name'],
      deviceType: json['device_type'],
      status: json['status'],
      lastSeenAt: json['last_seen_at'],
    );
  }
}

/// Result of device registration
class DeviceRegistrationResult {
  final bool success;
  final String message;
  final int deviceId;
  final bool isNew;

  DeviceRegistrationResult({
    required this.success,
    required this.message,
    required this.deviceId,
    required this.isNew,
  });

  factory DeviceRegistrationResult.fromJson(Map<String, dynamic> json) {
    // ✅ FIX: Handle device_id as both String and int from server
    int parsedDeviceId = 0;
    if (json['device_id'] != null) {
      if (json['device_id'] is String) {
        parsedDeviceId = int.tryParse(json['device_id']) ?? 0;
      } else if (json['device_id'] is int) {
        parsedDeviceId = json['device_id'];
      }
    }

    return DeviceRegistrationResult(
      success: json['success'] ?? false,
      message: json['message'] ?? '',
      deviceId: parsedDeviceId,
      isNew: json['is_new'] ?? false,
    );
  }
}