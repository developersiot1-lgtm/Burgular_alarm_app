<?php
header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit();
}

error_reporting(E_ALL);
ini_set('display_errors', 1);
ini_set('log_errors', 1);

// Load config from environment and optionally from server/config.php (not committed).
// Example env vars: MONS_ALARM_DB_HOST, MONS_ALARM_DB_USER, MONS_ALARM_DB_PASS, MONS_ALARM_DB_NAME
$GLOBALS['MONS_ALARM_CONFIG'] = [
    'db_host' => getenv('MONS_ALARM_DB_HOST') ?: 'localhost',
    'db_user' => getenv('MONS_ALARM_DB_USER') ?: 'mons_alarm_user',
    'db_pass' => getenv('MONS_ALARM_DB_PASS') ?: '',
    'db_name' => getenv('MONS_ALARM_DB_NAME') ?: 'mons_alarm_db',
];

$localConfigPath = __DIR__ . '/config.php';
if (is_file($localConfigPath)) {
    $localCfg = require $localConfigPath;
    if (is_array($localCfg)) {
        $GLOBALS['MONS_ALARM_CONFIG'] = array_merge($GLOBALS['MONS_ALARM_CONFIG'], $localCfg);
    }
}

// ============================================
// DATABASE CONNECTION CLASS
// ============================================
class Database {
    private $host;
    private $username;
    private $password;
    private $database;
    private $connection;

    public function __construct() {
        try {
            $cfg = $GLOBALS['MONS_ALARM_CONFIG'] ?? [];
            $this->host = $cfg['db_host'] ?? 'localhost';
            $this->username = $cfg['db_user'] ?? 'mons_alarm_user';
            $this->password = $cfg['db_pass'] ?? '';
            $this->database = $cfg['db_name'] ?? 'mons_alarm_db';

            $dsn = "mysql:host={$this->host};dbname={$this->database};charset=utf8mb4";
            $this->connection = new PDO($dsn, $this->username, $this->password);
            $this->connection->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
            $this->connection->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE, PDO::FETCH_ASSOC);
        } catch (PDOException $e) {
            error_log("Database connection failed: " . $e->getMessage());
            throw new Exception("Database connection failed");
        }
    }

    public function query($sql, $params = []) {
        try {
            $stmt = $this->connection->prepare($sql);
            $stmt->execute($params);
            return $stmt;
        } catch (PDOException $e) {
            error_log("Query failed: " . $e->getMessage());
            throw new Exception("Database query failed: " . $e->getMessage());
        }
    }

    public function fetchAll($sql, $params = []) {
        $stmt = $this->query($sql, $params);
        return $stmt->fetchAll();
    }

    public function fetchOne($sql, $params = []) {
        $stmt = $this->query($sql, $params);
        return $stmt->fetch();
    }

    public function insert($table, $data) {
        $columns = implode(', ', array_keys($data));
        $placeholders = ':' . implode(', :', array_keys($data));
        $sql = "INSERT INTO {$table} ({$columns}) VALUES ({$placeholders})";
        $stmt = $this->query($sql, $data);
        return $this->connection->lastInsertId();
    }

    public function update($table, $data, $where, $whereParams = []) {
        $setParts = [];
        foreach ($data as $key => $value) {
            $setParts[] = "{$key} = :{$key}";
        }
        $setClause = implode(', ', $setParts);
        $sql = "UPDATE {$table} SET {$setClause} WHERE {$where}";
        $params = array_merge($data, $whereParams);
        return $this->query($sql, $params);
    }

    public function beginTransaction() {
        return $this->connection->beginTransaction();
    }

    public function commit() {
        return $this->connection->commit();
    }

    public function rollBack() {
        return $this->connection->rollBack();
    }

    public function getConnection() {
        return $this->connection;
    }
}

// ============================================
// ENHANCED API ROUTER WITH DEVICE REGISTRY
// ============================================
class ApiRouter {
    private $db;
    private $requestMethod;

    public function __construct() {
        try {
            $this->db = new Database();
            $this->requestMethod = $_SERVER['REQUEST_METHOD'];
        } catch (Exception $e) {
            $this->sendResponse(['error' => 'Database connection failed'], 500);
        }
    }

    public function route() {
        
        /* ==========================================================
           🔹 ESP32 AUTO-REGISTER ENTRY POINT (NEW)
           URL: index.php?uuid=ESP32_ALARM_001
        ========================================================== */
        if (isset($_GET['uuid']) && !isset($_GET['action'])) {

            $uuid = trim($_GET['uuid']);

            if ($uuid === '') {
                $this->sendResponse(['error' => 'UUID missing'], 400);
            }

            $device = $this->db->fetchOne(
                "SELECT id FROM device_registry WHERE device_uuid = ?",
                [$uuid]
            );
         if (!$device) {

    // ✅ Always create new device (NO MERGE)
    $device_id = $this->db->insert('device_registry', [
        'device_uuid'     => $uuid,
        'device_name'     => 'ESP32 Alarm',
        'device_type'     => 'alarm',
        'connection_type' => 'wifi',
        'status'          => 'online',
        'last_seen_at'    => date('Y-m-d H:i:s'),
    ]);

} else {

    $device_id = $device['id'];

    $this->db->update(
        'device_registry',
        [
            'status'       => 'online',
            'last_seen_at' => date('Y-m-d H:i:s'),
        ],
        'device_uuid = :uuid',
        ['uuid' => $uuid]
    );
}
  

            $this->sendResponse([
                'success'      => true,
                'device_uuid' => $uuid,
                'device_id'   => $device_id
            ]);
        }

        $action = $_GET['action'] ?? '';

        try {
            switch ($action) {
                // ============================================
                // DEVICE REGISTRY ENDPOINTS (NEW)
                // ============================================
                
                case 'device_check_exists':
                    if ($this->requestMethod === 'POST' || $this->requestMethod === 'GET') {
                        $this->deviceCheckExists();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'device_register':
                    if ($this->requestMethod === 'POST') {
                        $this->deviceRegister();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'device_info':
                    if ($this->requestMethod === 'GET') {
                        $this->deviceGetInfo();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'device_heartbeat':
                    if ($this->requestMethod === 'POST') {
                        $this->deviceHeartbeat();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;
              case 'get_alarm_status':
                 if ($this->requestMethod === 'GET') {
                  $this->getAlarmStatus();
                 }
                  break;
                case 'device_list':
                    if ($this->requestMethod === 'GET') {
                        $this->deviceList();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'device_list_by_type':
                    if ($this->requestMethod === 'GET') {
                        $this->deviceListByType();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'device_need_attention':
                    if ($this->requestMethod === 'GET') {
                        $this->deviceNeedAttention();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'device_update_setting':
                    if ($this->requestMethod === 'POST') {
                        $this->deviceUpdateSetting();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'device_create_relationship':
                    if ($this->requestMethod === 'POST') {
                        $this->deviceCreateRelationship();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                // ============================================
                // EXISTING ENDPOINTS (KEPT FOR COMPATIBILITY)
                // ============================================

                case 'register_mobile_device':
                    if ($this->requestMethod === 'POST') {
                        $this->registerMobileDevice();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'test':
                    $this->handleTest();
                    break;

                case 'system_state':
                    if ($this->requestMethod === 'GET') {
                        $this->getSystemState();
                    } elseif ($this->requestMethod === 'POST') {
                        $this->updateSystemState();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'devices':
                    if ($this->requestMethod === 'GET') {
                        $this->getDevices();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'mobile_devices':
                    if ($this->requestMethod === 'GET') {
                        $this->getMobileDevices();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'logs':
                    if ($this->requestMethod === 'GET') {
                        $this->getActivityLogs();
                    } elseif ($this->requestMethod === 'POST') {
                        $this->addActivityLog();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'save_wifi_credentials':
                    if ($this->requestMethod === 'POST') {
                        $this->saveWifiCredentials();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'get_wifi_credentials':
                    if ($this->requestMethod === 'GET') {
                        $this->getWifiCredentials();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'save_voice_recording':
                    if ($this->requestMethod === 'POST') {
                        $this->saveVoiceRecording();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'get_voice_recordings':
                    if ($this->requestMethod === 'GET') {
                        $this->getVoiceRecordings();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'get_settings':
                    if ($this->requestMethod === 'GET') {
                        $this->getSettings();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'save_settings':
                    if ($this->requestMethod === 'POST') {
                        $this->saveSettings();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'get_all_settings':
                    if ($this->requestMethod === 'GET') {
                        $this->getAllSettings();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'sync_settings_to_device':
                    if ($this->requestMethod === 'GET' || $this->requestMethod === 'POST') {
                        $this->syncSettingsToDevice();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;
                    case 'get_pairing_request':
    if ($this->requestMethod === 'GET') {
        $this->getPairingRequest();
    } else {
        $this->sendResponse(['error' => 'Method not allowed'], 405);
    }
    break;
 
 case 'alarm_event':
    if ($this->requestMethod === 'POST') {
        $this->alarmEvent();
    }
    break;
case 'update_pairing_status':
    if ($this->requestMethod === 'POST') {
        $this->updatePairingStatus();
    } else {
        $this->sendResponse(['error' => 'Method not allowed'], 405);
    }
    break;


                case 'delete_contact_number':
                    if ($this->requestMethod === 'POST') {
                        $this->deleteContactNumber();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'add_contact_number':
                    if ($this->requestMethod === 'POST') {
                        $this->addContactNumber();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'get_contact_numbers':
                    if ($this->requestMethod === 'GET') {
                        $this->getContactNumbers();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'get_settings_history':
                    if ($this->requestMethod === 'GET') {
                        $this->getSettingsHistory();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;

                case 'get_sync_logs':
                    if ($this->requestMethod === 'GET') {
                        $this->getSyncLogs();
                    } else {
                        $this->sendResponse(['error' => 'Method not allowed'], 405);
                    }
                    break;
                     case 'accessory_pair':
            if ($this->requestMethod === 'POST') { $this->accessoryPair(); }
            break;
        case 'accessory_list':
            if ($this->requestMethod === 'GET')  { $this->accessoryList(); }
            break;
        case 'accessory_delete':
            if ($this->requestMethod === 'POST') { $this->accessoryDelete(); }
            break;
                    case 'save_schedules':
    if ($this->requestMethod === 'POST') {
        $this->saveSchedules();
    }
    break;

case 'get_schedules':
    if ($this->requestMethod === 'GET') {
        $this->getSchedules();
    }
    break;

case 'delete_schedule':
    if ($this->requestMethod === 'POST') {
        $this->deleteSchedule();
    }
    break;
        case 'updatedevicename':
        if ($this->requestMethod === 'POST') {
            $this->updateDeviceName();
        } else {
            $this->sendResponse(['error' => 'Method not allowed'], 405);
        }
        break;

    case 'deletedevice':
        if ($this->requestMethod === 'POST') {
            $this->deleteDevice();
        } else {
            $this->sendResponse(['error' => 'Method not allowed'], 405);
        }
        break;


case 'toggle_schedule':
    if ($this->requestMethod === 'POST') {
        $this->toggleSchedule();
    }
    break;

                case '':
                    $this->sendResponse([
                        'message' => 'Burglar Alarm System API with Device Registry', 
                        'version' => '3.0',
                        'features' => ['device_registry', 'settings_management', 'legacy_support']
                    ]);
                    break;

                default:
                    $this->sendResponse(['error' => 'Unknown action: ' . $action], 400);
            }
        } catch (Exception $e) {
            error_log("API Error: " . $e->getMessage());
            $this->sendResponse(['error' => 'Internal server error: ' . $e->getMessage()], 500);
        }
    }

    // ============================================
    // DEVICE REGISTRY METHODS (NEW)
    // ============================================

    /**
     * Check if device exists in registry
     * GET/POST ?action=device_check_exists&device_uuid=xxx
     */
    private function deviceCheckExists() {
        try {
            $input = $this->requestMethod === 'POST' ? $this->getInput() : $_GET;
            $device_uuid = $input['device_uuid'] ?? '';

            if (empty($device_uuid)) {
                throw new Exception('Device UUID is required');
            }

            $device = $this->db->fetchOne(
                "SELECT id, device_uuid, device_name, device_type, status, last_seen_at 
                 FROM device_registry 
                 WHERE device_uuid = ? AND is_active = TRUE",
                [$device_uuid]
            );

            if ($device) {
                $this->sendResponse([
                    'exists' => true,
                    'device_id' => $device['id'],
                    'device_name' => $device['device_name'],
                    'device_type' => $device['device_type'],
                    'status' => $device['status'],
                    'last_seen_at' => $device['last_seen_at']
                ]);
            } else {
                $this->sendResponse([
                    'exists' => false,
                    'message' => 'Device not found in registry'
                ]);
            }

        } catch (Exception $e) {
            error_log("Device check exists error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * Register new device or update existing
     * POST ?action=device_register
     */
    private function deviceRegister() {
        try {
            $data = $this->getInput();

            $required = ['device_uuid', 'device_name', 'device_type', 'connection_type'];
            foreach ($required as $field) {
                if (empty($data[$field])) {
                    throw new Exception("Missing required field: $field");
                }
            }

            // Check if device already exists
            $existing = $this->db->fetchOne(
                "SELECT id FROM device_registry WHERE device_uuid = ?",
                [$data['device_uuid']]
            );

            if ($existing) {
                // Update existing device
                $updateData = [
                    'device_name' => $data['device_name'],
                    'status' => 'online',
                    'last_seen_at' => date('Y-m-d H:i:s')
                ];

                if (!empty($data['battery_level'])) {
                    $updateData['battery_level'] = $data['battery_level'];
                }
                if (!empty($data['signal_strength'])) {
                    $updateData['signal_strength'] = $data['signal_strength'];
                }

                $this->db->update(
                    'device_registry',
                    $updateData,
                    'device_uuid = :uuid',
                    ['uuid' => $data['device_uuid']]
                );

                // Log activity
                $this->db->insert('device_activity_log', [
                    'device_id' => $existing['id'],
                    'activity_type' => 'device_reconnected',
                    'new_value' => 'Device reconnected to system',
                    'severity' => 'info'
                ]);

                $this->sendResponse([
                    'success' => true,
                    'message' => 'Device recognized and updated',
                    'device_id' => $existing['id'],
                    'is_new' => false
                ]);

            } else {
                // Register new device
                $insertData = [
                    'device_uuid' => $data['device_uuid'],
                    'device_name' => $data['device_name'],
                    'device_type' => $data['device_type'],
                    'connection_type' => $data['connection_type'],
                    'status' => 'online',
                    'last_seen_at' => date('Y-m-d H:i:s')
                ];

                // Optional fields
                $optionalFields = [
                    'mac_address', 'ip_address', 'ble_service_uuid', 'qr_data',
                    'battery_level', 'signal_strength', 'firmware_version',
                    'zone_name', 'manufacturer', 'model', 'capabilities'
                ];

                foreach ($optionalFields as $field) {
                    if (!empty($data[$field])) {
                        if ($field === 'capabilities' && is_array($data[$field])) {
                            $insertData[$field] = json_encode($data[$field]);
                        } else {
                            $insertData[$field] = $data[$field];
                        }
                    }
                }

                $device_id = $this->db->insert('device_registry', $insertData);

                // Log activity
                $this->db->insert('device_activity_log', [
                    'device_id' => $device_id,
                    'activity_type' => 'device_registered',
                    'new_value' => 'New device registered in system',
                    'severity' => 'info'
                ]);

                $this->sendResponse([
                    'success' => true,
                    'message' => 'Device registered successfully',
                    'device_id' => $device_id,
                    'is_new' => true
                ]);
            }

        } catch (Exception $e) {
            error_log("Device register error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }
// ✅ CORRECTED updateDeviceName function for index.php

private function updateDeviceName()
{
    try {
        $data = $this->getInput();
        $deviceUuid = $data['device_uuid'] ?? null;  // Changed from deviceuuid to device_uuid
        $deviceName = $data['device_name'] ?? null;  // Changed from devicename to device_name

        error_log("UpdateDeviceName called with UUID: $deviceUuid, Name: $deviceName");

        if (empty($deviceUuid) || empty($deviceName)) {
            throw new Exception('Device UUID and device name are required');
        }

        // ✅ FIXED: Use correct table name (device_registry) and snake_case columns
        $result = $this->db->query(
            'UPDATE device_registry SET device_name = ? WHERE device_uuid = ?',
            [$deviceName, $deviceUuid]
        );

        $rowCount = $result->rowCount();
        error_log("UPDATE affected rows: $rowCount");

        if ($rowCount > 0) {
            $this->sendResponse([
                'success' => true,
                'message' => 'Device name updated successfully'
            ]);
        } else {
            // Check if device exists
            $exists = $this->db->fetchOne(
                'SELECT id, device_name FROM device_registry WHERE device_uuid = ?',
                [$deviceUuid]
            );

            if ($exists) {
                error_log("Device exists but name unchanged: " . $exists['device_name']);
                $this->sendResponse([
                    'success' => true,
                    'message' => 'Device name already set to this value'
                ]);
            } else {
                error_log("Device not found in device_registry with UUID: $deviceUuid");
                
                // List all devices to help debug
                $allDevices = $this->db->fetchAll('SELECT device_uuid, device_name FROM device_registry LIMIT 10');
                error_log("Existing devices: " . json_encode($allDevices));
                
                $this->sendResponse([
                    'success' => false,
                    'message' => 'No device found with that UUID',
                    'debug' => [
                        'searched_uuid' => $deviceUuid,
                        'total_devices' => count($allDevices)
                    ]
                ], 404);
            }
        }
    } catch (Exception $e) {
        error_log('Update device name error: ' . $e->getMessage());
        $this->sendResponse(['success' => false, 'error' => $e->getMessage()], 500);
    }
}

// ✅ ALSO UPDATE deleteDevice to use correct table
private function deleteDevice()
{
    try {
        $data = $this->getInput();
        $deviceUuid = $data['device_uuid'] ?? null;  // Changed from deviceuuid

        if (empty($deviceUuid)) {
            throw new Exception('Device UUID is required');
        }

        // ✅ FIXED: Use correct table name (device_registry)
        $result = $this->db->query(
            'DELETE FROM device_registry WHERE device_uuid = ?',
            [$deviceUuid]
        );

        if ($result->rowCount() > 0) {
            $this->sendResponse([
                'success' => true,
                'message' => 'Device deleted successfully',
            ]);
        } else {
            $this->sendResponse([
                'success' => false,
                'message' => 'No device found with that UUID',
            ], 404);
        }
    } catch (Exception $e) {
        error_log('Delete device error: ' . $e->getMessage());
        $this->sendResponse(['success' => false, 'error' => $e->getMessage()], 500);
    }
}
    /**
     * Get full device information
     * GET ?action=device_info&device_uuid=xxx
     */
    private function deviceGetInfo() {
        try {
            $device_uuid = $_GET['device_uuid'] ?? '';

            if (empty($device_uuid)) {
                throw new Exception('Device UUID is required');
            }

            $device = $this->db->fetchOne(
                "SELECT * FROM device_registry WHERE device_uuid = ? AND is_active = TRUE",
                [$device_uuid]
            );

            if (!$device) {
                throw new Exception('Device not found');
            }

            // Get device settings
            $settings = $this->db->fetchAll(
                "SELECT setting_category, setting_key, setting_value, setting_type 
                 FROM device_settings_v2 
                 WHERE device_id = ?",
                [$device['id']]
            );

            $device['settings'] = $settings;

            // Get relationships
            $relationships = $this->db->fetchAll(
                "SELECT dr2.device_name, dr2.device_type, drel.relationship_type
                 FROM device_relationships drel
                 JOIN device_registry dr2 ON dr2.id = drel.child_device_id
                 WHERE drel.parent_device_id = ? AND drel.is_active = TRUE",
                [$device['id']]
            );

            $device['controlled_devices'] = $relationships;

            // Get recent activity
            $activity = $this->db->fetchAll(
                "SELECT activity_type, new_value, severity, timestamp
                 FROM device_activity_log
                 WHERE device_id = ?
                 ORDER BY timestamp DESC
                 LIMIT 10",
                [$device['id']]
            );

            $device['recent_activity'] = $activity;

            // Decode JSON fields
            if (!empty($device['capabilities'])) {
                $device['capabilities'] = json_decode($device['capabilities'], true);
            }
            if (!empty($device['tags'])) {
                $device['tags'] = json_decode($device['tags'], true);
            }

            $this->sendResponse($device);

        } catch (Exception $e) {
            error_log("Device get info error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * Send device heartbeat
     * POST ?action=device_heartbeat
     */
    private function deviceHeartbeat() {
        try {
            $data = $this->getInput();
            $device_uuid = $data['device_uuid'] ?? '';

            if (empty($device_uuid)) {
                throw new Exception('Device UUID is required');
            }

            $updateData = [
                'last_seen_at' => date('Y-m-d H:i:s'),
                'status' => 'online'
            ];

            if (isset($data['battery_level'])) {
                $updateData['battery_level'] = intval($data['battery_level']);
            }
            if (isset($data['signal_strength'])) {
                $updateData['signal_strength'] = intval($data['signal_strength']);
            }

            $this->db->update(
                'device_registry',
                $updateData,
                'device_uuid = :uuid',
                ['uuid' => $device_uuid]
            );

            // Log health metrics if provided
            if (isset($data['battery_level']) || isset($data['signal_strength'])) {
                $device = $this->db->fetchOne(
                    "SELECT id FROM device_registry WHERE device_uuid = ?",
                    [$device_uuid]
                );

                if ($device) {
                    $metricsData = [
                        'device_id' => $device['id']
                    ];

                    $metricFields = ['battery_level', 'signal_strength', 'temperature', 
                                    'cpu_usage', 'memory_usage', 'ping_latency_ms'];
                    
                    foreach ($metricFields as $field) {
                        if (isset($data[$field])) {
                            $metricsData[$field] = $data[$field];
                        }
                    }

                    $this->db->insert('device_health_metrics', $metricsData);
                }
            }

            $this->sendResponse(['success' => true]);

        } catch (Exception $e) {
            error_log("Device heartbeat error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * List all devices
     * GET ?action=device_list
     */
    private function deviceList() {
        try {
            $devices = $this->db->fetchAll(
                "SELECT id, device_uuid, device_name, device_type, connection_type,
                        status, battery_level, signal_strength, zone_name, 
                        last_seen_at, registered_at
                 FROM device_registry
                 WHERE is_active = TRUE
                 ORDER BY device_name"
            );

            $this->sendResponse([
                'success' => true,
                'total' => count($devices),
                'devices' => $devices
            ]);

        } catch (Exception $e) {
            error_log("Device list error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * List devices by type
     * GET ?action=device_list_by_type&type=mobile_phone
     */
    private function deviceListByType() {
        try {
            $type = $_GET['type'] ?? '';

            if (empty($type)) {
                throw new Exception('Device type is required');
            }

            $devices = $this->db->fetchAll(
                "SELECT * FROM device_registry
                 WHERE device_type = ? AND is_active = TRUE
                 ORDER BY device_name",
                [$type]
            );

            $this->sendResponse([
                'success' => true,
                'type' => $type,
                'total' => count($devices),
                'devices' => $devices
            ]);

        } catch (Exception $e) {
            error_log("Device list by type error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * Get devices that need attention
     * GET ?action=device_need_attention
     */
    private function deviceNeedAttention() {
        try {
            $devices = $this->db->fetchAll(
                "SELECT id, device_uuid, device_name, device_type, status, 
                        battery_level, zone_name, last_seen_at,
                        CASE 
                            WHEN status = 'offline' THEN 'Device Offline'
                            WHEN battery_level < 10 THEN 'Critical Battery'
                            WHEN battery_level < 20 THEN 'Low Battery'
                            ELSE 'Unknown Issue'
                        END as issue_type
                 FROM device_registry
                 WHERE (status = 'offline' OR battery_level < 20)
                   AND is_active = TRUE
                 ORDER BY 
                    CASE 
                        WHEN battery_level < 10 THEN 1
                        WHEN status = 'offline' THEN 2
                        WHEN battery_level < 20 THEN 3
                        ELSE 4
                    END"
            );

            $this->sendResponse([
                'success' => true,
                'total' => count($devices),
                'devices' => $devices
            ]);

        } catch (Exception $e) {
            error_log("Device need attention error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * Update device setting
     * POST ?action=device_update_setting
     */
    private function deviceUpdateSetting() {
        try {
            $data = $this->getInput();
            $device_uuid = $data['device_uuid'] ?? '';
            $setting_key = $data['setting_key'] ?? '';
            $setting_value = $data['setting_value'] ?? '';

            if (empty($device_uuid) || empty($setting_key)) {
                throw new Exception('Device UUID and setting key are required');
            }

            $device = $this->db->fetchOne(
                "SELECT id FROM device_registry WHERE device_uuid = ?",
                [$device_uuid]
            );

            if (!$device) {
                throw new Exception('Device not found');
            }

            // Determine data type
            $setting_type = 'string';
            if (is_int($setting_value)) {
                $setting_type = 'integer';
            } elseif (is_bool($setting_value)) {
                $setting_type = 'boolean';
            } elseif (is_array($setting_value)) {
                $setting_type = 'json';
                $setting_value = json_encode($setting_value);
            }

            $stmt = $this->db->getConnection()->prepare(
                "INSERT INTO device_settings_v2 (device_id, setting_category, setting_key, setting_value, setting_type)
                 VALUES (?, 'general', ?, ?, ?)
                 ON DUPLICATE KEY UPDATE 
                    setting_value = VALUES(setting_value),
                    setting_type = VALUES(setting_type),
                    is_synced = FALSE"
            );

            $stmt->execute([$device['id'], $setting_key, $setting_value, $setting_type]);

            $this->sendResponse(['success' => true]);

        } catch (Exception $e) {
            error_log("Device update setting error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * Create device relationship
     * POST ?action=device_create_relationship
     */
    private function deviceCreateRelationship() {
        try {
            $data = $this->getInput();
            $parent_uuid = $data['parent_device_uuid'] ?? '';
            $child_uuid = $data['child_device_uuid'] ?? '';
            $relationship_type = $data['relationship_type'] ?? 'controls';

            if (empty($parent_uuid) || empty($child_uuid)) {
                throw new Exception('Both parent and child device UUIDs are required');
            }

            $parent = $this->db->fetchOne(
                "SELECT id FROM device_registry WHERE device_uuid = ?",
                [$parent_uuid]
            );

            $child = $this->db->fetchOne(
                "SELECT id FROM device_registry WHERE device_uuid = ?",
                [$child_uuid]
            );

            if (!$parent || !$child) {
                throw new Exception('One or both devices not found');
            }

            $this->db->insert('device_relationships', [
                'parent_device_id' => $parent['id'],
                'child_device_id' => $child['id'],
                'relationship_type' => $relationship_type,
                'is_active' => true
            ]);

            $this->sendResponse(['success' => true]);

        } catch (Exception $e) {
            error_log("Device create relationship error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    // ============================================
    // SETTINGS MANAGEMENT METHODS (EXISTING - KEPT)
    // ============================================
private function syncSettingsToDevice() {
    try {
        $device_uuid = trim(
            $_GET['device_uuid'] ?? $_POST['device_uuid'] ?? ''
        );
        $request_device_name = trim($_GET['device_name'] ?? $_POST['device_name'] ?? '');

        if ($device_uuid === '') {
            throw new Exception('device_uuid is required');
        }

        // ── Step 1: Get device name from device_registry ──────────────────
        $device_name = $request_device_name;

// ── Step 2: Get latest settings from settings_sync_log ────────────
// Single source of truth — Flutter always writes here via saveSettings()
$resolved_uuid = $device_uuid;

$buildAltUuid = function (string $uuid, int $delta): string {
    $hex = strtoupper($uuid);
    $hex = preg_replace('/[^0-9A-F]/', '', $hex);
    if (strlen($hex) !== 12) {
        return '';
    }
    $bytes = str_split($hex, 2);
    $last = hexdec($bytes[5]);
    $bytes[5] = sprintf('%02X', ($last + $delta) & 0xFF);
    return implode(':', $bytes);
};

$uuidsToTry = [
    $device_uuid,
    $buildAltUuid($device_uuid, 2),
    $buildAltUuid($device_uuid, -2),
];

$syncRow = null;
foreach ($uuidsToTry as $candidate) {
    if (!$candidate) {
        continue;
    }
    $row = $this->db->fetchOne(
        "SELECT id, device_uuid, synced_at, settings_json
         FROM settings_sync_log
         WHERE device_uuid = ?
           AND sync_type = 'upload'
           AND sync_status = 'success'
         ORDER BY id DESC
         LIMIT 1",
        [$candidate]
    );
    if ($row && !empty($row['settings_json'])) {
        $syncRow = $row;
        $resolved_uuid = $candidate;
        break;
    }
}

if (!$syncRow || empty($syncRow['settings_json'])) {
    // No settings saved yet — return safe defaults
    $settingsJson = null;
} else {
    $settingsJson = $syncRow['settings_json'];
}
        // ── Step 4: Decode stored JSON blob ───────────────────────────────
        $settings = [];
        if (!empty($settingsJson)) {
            $decoded = json_decode($settingsJson, true);
            if (is_array($decoded)) {
                $settings = $decoded;
            }
        }

        // Some deployments store a wrapper like {"settings_json":{...}} in the log.
        if (isset($settings['settings_json']) && is_array($settings['settings_json'])) {
            $settings = $settings['settings_json'];
        }

        // If device_name wasn't passed in the request, try to read it from the log payload.
        if ($device_name === '' && isset($settings['device_name']) && is_string($settings['device_name'])) {
            $device_name = trim($settings['device_name']);
        }

        // ── Step 5: Guarantee required keys have safe defaults ────────────
        // These match exactly the keys the ESP32 firmware reads,
        // and the keys Flutter's saveSettings() posts.
        $defaults = [
            'exit_delay'                      => 70,
            'entry_delay'                     => 60,
            'alarm_duration'                  => 5,
            'alarm_sound'                     => true,
            'alarm_call'                      => true,
            'alarm_sms'                       => true,
            'alarm_notification'              => true,
            'countdown_with_tick_tone'        => true,
            'sensor_low_battery_alarm'        => true,
            'arm_disarm_notification'         => true,
            'tamper_alarm'                    => true,
            'sensor_low_battery_notification' => true,
            'unanswered_phone_redial_times'   => 2,
            'virtual_password'                => '',
            'hub_language'                    => '',
            'alarm_call_numbers'              => [],
            'alarm_sms_numbers'               => [],
        ];

        foreach ($defaults as $key => $default) {
            if (!array_key_exists($key, $settings)) {
                $settings[$key] = $default;
            }
        }

        // ── Step 6: Cast integer fields so json_encode() outputs 70 not "70"
        $intFields = [
            'exit_delay',
            'entry_delay',
            'alarm_duration',
            'unanswered_phone_redial_times',
        ];
        foreach ($intFields as $f) {
            if (isset($settings[$f])) {
                $settings[$f] = (int) $settings[$f];
            }
        }

        // ── Step 7: Cast boolean fields so json_encode() outputs true not "true"
        $boolFields = [
            'alarm_sound',
            'alarm_call',
            'alarm_sms',
            'alarm_notification',
            'countdown_with_tick_tone',
            'sensor_low_battery_alarm',
            'arm_disarm_notification',
            'tamper_alarm',
            'sensor_low_battery_notification',
        ];
        foreach ($boolFields as $f) {
            if (isset($settings[$f])) {
                $v = $settings[$f];
                $settings[$f] = ($v === true || $v === 1 || $v === '1' || $v === 'true');
            }
        }

        // ── Step 8: Ensure number arrays encode as [] not {} ──────────────
        foreach (['alarm_call_numbers', 'alarm_sms_numbers'] as $numField) {
            $normalized = [];
            if (isset($settings[$numField]) && is_array($settings[$numField])) {
                foreach ($settings[$numField] as $n) {
                    // Support either ["+91123..."] or [{"number":"+91123...","name":"..."}].
                    $phone = is_array($n) ? ($n['number'] ?? ($n['phone'] ?? '')) : $n;
                    $phone = trim((string) $phone);
                    if ($phone !== '') {
                        $normalized[] = $phone;
                    }
                }
            }
            $settings[$numField] = array_values($normalized);
        }

        // ── Step 9: Send response ──────────────────────────────────────────
        $this->sendResponse([
            'success'       => true,
            'device_uuid'   => $device_uuid,
            'resolved_device_uuid' => $resolved_uuid,
            'device_name'   => $device_name,
            'settings_source' => 'settings_sync_log',
            'sync_log_id'   => $syncRow['id'] ?? null,
            'sync_log_synced_at' => $syncRow['synced_at'] ?? null,
            'settings_json' => $settings,
        ]);

    } catch (Exception $e) {
        error_log("syncSettingsToDevice error: " . $e->getMessage());
        $this->sendResponse(['error' => $e->getMessage()], 500);
    }
}
    private function getSettings() {
        try {
            $device_uuid = $_GET['device_uuid'] ?? '';

            if (empty($device_uuid)) {
                throw new Exception('Device UUID is required');
            }

            $device = $this->db->fetchOne(
                "SELECT id FROM device_registry WHERE device_uuid = ?",
                [$device_uuid]
            );

            if (!$device) {
                throw new Exception('Device not found');
            }

            $device_id = $device['id'];

            $settings_rows = $this->db->fetchAll(
                "SELECT setting_key, setting_value, data_type FROM device_settings 
                 WHERE device_id = ?
                 ORDER BY setting_key",
                [$device_id]
            );

            $settings = [
                'device_uuid' => $device_uuid,
                'device_id' => $device_id
            ];

            foreach ($settings_rows as $row) {
                $value = $row['setting_value'];
                
                if ($row['data_type'] === 'integer') {
                    $value = intval($value);
                } elseif ($row['data_type'] === 'boolean') {
                    $value = $value === 'true' || $value === '1';
                } elseif ($row['data_type'] === 'json') {
                    $value = json_decode($value, true);
                }
                
                $settings[$row['setting_key']] = $value;
            }

            $contacts = $this->db->fetchAll(
                "SELECT id, phone_number, contact_name, number_type, priority, is_active
                 FROM contact_numbers
                 WHERE device_id = ? AND is_active = TRUE
                 ORDER BY number_type, priority",
                [$device_id]
            );

            $alarm_call_numbers = [];
            $alarm_sms_numbers = [];

            foreach ($contacts as $contact) {
                if ($contact['number_type'] === 'call') {
                    $alarm_call_numbers[] = $contact['phone_number'];
                } else {
                    $alarm_sms_numbers[] = $contact['phone_number'];
                }
            }

            $settings['alarm_call_numbers'] = $alarm_call_numbers;
            $settings['alarm_sms_numbers'] = $alarm_sms_numbers;

            $this->sendResponse([
                'success' => true,
                'settings' => $settings
            ]);

        } catch (Exception $e) {
            error_log("ERROR in getSettings: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }
private function saveSettings() {
    try {
        $data        = $this->getInput();
        $device_uuid = $data['device_uuid'] ?? '';

        if (empty($device_uuid)) {
            throw new Exception('Device UUID is required');
        }

        // ─────────────────────────────────────────────
        // GET / CREATE DEVICE
        // ─────────────────────────────────────────────
        $device = $this->db->fetchOne(
            "SELECT id, device_name FROM device_registry WHERE device_uuid = ?",
            [$device_uuid]
        );

        if (!$device) {
            $displayname = $data['device_name'] ?? ('Device ' . substr($device_uuid, 0, 8));

            $device_id = $this->db->insert('device_registry', [
                'device_uuid'     => $device_uuid,
                'device_name'     => $displayname,
                'device_type'     => 'alarm',
                'connection_type' => 'wifi',
                'status'          => 'online',
                'last_seen_at'    => date('Y-m-d H:i:s'),
            ]);

            $device_name = $displayname;
        } else {
            $device_id   = (int)$device['id'];
            $device_name = $device['device_name'] ?? '';

            $this->db->query(
                "UPDATE device_registry SET last_seen_at = ? WHERE id = ?",
                [date('Y-m-d H:i:s'), $device_id]
            );
        }

        // ─────────────────────────────────────────────
        // UPDATE DEVICE NAME
        // ─────────────────────────────────────────────
        if (!empty($data['device_name'])) {
            $this->db->query(
                "UPDATE device_registry SET device_name = ? WHERE id = ?",
                [$data['device_name'], $device_id]
            );
            $device_name = $data['device_name'];
        }

        $this->db->beginTransaction();

        // ─────────────────────────────────────────────
        // SETTINGS KEYS
        // ─────────────────────────────────────────────
        $setting_keys = [
            'device_name',
            'exit_delay',
            'entry_delay',
            'alarm_duration',
            'alarm_sound',
            'alarm_call',
            'alarm_sms',
            'sensor_low_battery_alarm',
            'alarm_notification',
            'countdown_with_tick_tone',
            'arm_disarm_notification',
            'tamper_alarm',
            'sensor_low_battery_notification',
            'hub_language',
            'virtual_password',
            'unanswered_phone_redial_times',
        ];

        $saved_count = 0;

        foreach ($setting_keys as $key) {
            if (!isset($data[$key])) continue;

            $value = $data[$key];

            if (is_bool($value)) {
                $data_type = 'boolean';
                $value = $value ? 'true' : 'false';
            } elseif (is_numeric($value)) {
                $data_type = 'integer';
                $value = strval($value);
            } elseif (is_array($value) || is_object($value)) {
                $data_type = 'json';
                $value = json_encode($value);
            } else {
                $data_type = 'string';
                $value = strval($value);
            }

            $stmt = $this->db->getConnection()->prepare(
                "INSERT INTO device_settings
                     (device_id, setting_key, setting_value, data_type, updated_at)
                 VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
                 ON DUPLICATE KEY UPDATE
                     setting_value = VALUES(setting_value),
                     data_type     = VALUES(data_type),
                     updated_at    = CURRENT_TIMESTAMP"
            );

            if ($stmt->execute([$device_id, $key, $value, $data_type])) {
                $saved_count++;
            }
        }

        // ─────────────────────────────────────────────
        // BUILD SNAPSHOT JSON
        // ─────────────────────────────────────────────
        $jsonSnapshot = ['device_uuid' => $device_uuid];

        if (!empty($device_name)) {
            $jsonSnapshot['device_name'] = $device_name;
        }

        foreach ($setting_keys as $key) {
            if (isset($data[$key])) {
                $jsonSnapshot[$key] = $data[$key];
            }
        }

        // CONTACT NUMBERS IN JSON
        if (!empty($data['alarm_call_numbers'])) {
            $jsonSnapshot['alarm_call_numbers'] = $data['alarm_call_numbers'];
        }
        if (!empty($data['alarm_sms_numbers'])) {
            $jsonSnapshot['alarm_sms_numbers'] = $data['alarm_sms_numbers'];
        }

        $jsonSnapshot['saved_at'] = date('Y-m-d H:i:s');



        // ─────────────────────────────────────────────
        // TIMING SYNC
        // ─────────────────────────────────────────────
        $timingUpdate = [];

        if (isset($data['exit_delay']))     $timingUpdate['exit_delay'] = intval($data['exit_delay']);
        if (isset($data['entry_delay']))    $timingUpdate['entry_delay'] = intval($data['entry_delay']);
        if (isset($data['alarm_duration'])) $timingUpdate['alarm_duration'] = intval($data['alarm_duration']);

        if (!empty($timingUpdate)) {
            $setClauses = [];
            $setValues  = [];

            foreach ($timingUpdate as $col => $val) {
                $setClauses[] = "`$col` = ?";
                $setValues[]  = $val;
            }

            $setValues[] = $device_id;

            $this->db->query(
                "UPDATE device_registry SET " . implode(', ', $setClauses) . " WHERE id = ?",
                $setValues
            );
        }

        // ─────────────────────────────────────────────
        // CONTACT NUMBERS SAVE (IMPORTANT)
        // ─────────────────────────────────────────────

        // DEBUG LOG
        error_log("CALL NUMBERS: " . json_encode($data['alarm_call_numbers'] ?? []));
        error_log("SMS NUMBERS: " . json_encode($data['alarm_sms_numbers'] ?? []));

        // DELETE OLD (soft)
        $this->db->query(
            "UPDATE contact_numbers SET is_active = 0 WHERE device_id = ?",
            [$device_id]
        );

        $call_count = 0;
        $sms_count  = 0;

        // CALL
        if (!empty($data['alarm_call_numbers']) && is_array($data['alarm_call_numbers'])) {
            $priority = 1;

            foreach ($data['alarm_call_numbers'] as $number) {
                $phone = is_array($number) ? ($number['number'] ?? '') : $number;
                $name  = is_array($number) ? ($number['name'] ?? '') : '';

                $phone = trim($phone);
                if ($phone === '') continue;

                $stmt = $this->db->getConnection()->prepare(
                    "INSERT INTO contact_numbers
                        (device_id, number_type, phone_number, contact_name, priority, is_active)
                     VALUES (?, 'call', ?, ?, ?, 1)
                     ON DUPLICATE KEY UPDATE
                        is_active = 1,
                        priority = VALUES(priority),
                        contact_name = VALUES(contact_name)"
                );

                if ($stmt->execute([$device_id, $phone, $name, $priority])) {
                    $call_count++;
                }

                $priority++;
            }
        }

        // SMS
        if (!empty($data['alarm_sms_numbers']) && is_array($data['alarm_sms_numbers'])) {
            $priority = 1;

            foreach ($data['alarm_sms_numbers'] as $number) {
                $phone = is_array($number) ? ($number['number'] ?? '') : $number;
                $name  = is_array($number) ? ($number['name'] ?? '') : '';

                $phone = trim($phone);
                if ($phone === '') continue;

                $stmt = $this->db->getConnection()->prepare(
                    "INSERT INTO contact_numbers
                        (device_id, number_type, phone_number, contact_name, priority, is_active)
                     VALUES (?, 'sms', ?, ?, ?, 1)
                     ON DUPLICATE KEY UPDATE
                        is_active = 1,
                        priority = VALUES(priority),
                        contact_name = VALUES(contact_name)"
                );

                if ($stmt->execute([$device_id, $phone, $name, $priority])) {
                    $sms_count++;
                }

                $priority++;
            }
        }

        // ─────────────────────────────────────────────
        // LOGS
        // ─────────────────────────────────────────────
        $this->db->insert('settings_sync_log', [
            'device_uuid'   => $device_uuid,
            'device_id'     => $device_id,
            'sync_type'     => 'upload',
            'settings_json' => json_encode($jsonSnapshot, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT),
            'sync_status'   => 'success',
        ]);

        $this->db->insert('device_activity_log', [
            'device_id'     => $device_id,
            'activity_type' => 'settings_updated',
            'old_value'     => null,
            'new_value'     => json_encode($jsonSnapshot, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT),
            'severity'      => 'info',
        ]);

        $this->db->commit();

        $this->sendResponse([
            'success'        => true,
            'message'        => 'Settings saved successfully',
            'device_id'      => $device_id,
            'saved_settings' => $saved_count,
            'call_numbers'   => $call_count,
            'sms_numbers'    => $sms_count,
        ]);

    } catch (Exception $e) {
        if ($this->db->getConnection()->inTransaction()) {
            $this->db->rollBack();
        }

        error_log("ERROR in saveSettings: " . $e->getMessage());

        $this->sendResponse([
            'success' => false,
            'error'   => $e->getMessage()
        ], 500);
    }
}
    private function getAlarmStatus() {
    try {
        $device_uuid = $_GET['device_uuid'] ?? '';
 
        if (empty($device_uuid)) {
            throw new Exception('device_uuid is required');
        }
 
        // ── Get current system state ──────────────────────────
        $state = $this->db->fetchOne(
            "SELECT state FROM system_state
             ORDER BY updated_at DESC LIMIT 1"
        );
 
        $currentState = $state['state'] ?? 'disarmed';
        $alarmActive  = ($currentState === 'alarm');
 
        // ── Get triggered sensors from activity_logs ──────────
        // The ESP32 / alarm hub logs sensor triggers as activity events.
        // We look for recent events (last 30 s) that contain sensor keywords.
        $triggeredSensors = [];
 
        if ($alarmActive) {
            $rows = $this->db->fetchAll(
                "SELECT 
                     al.id,
                     al.device        AS name,
                     al.event,
                     al.timestamp,
                     COALESCE(dr.device_type, 'sensor') AS type,
                     COALESCE(dr.zone_name,   '')        AS zone
                 FROM activity_logs al
                 LEFT JOIN device_registry dr
                       ON dr.device_name = al.device
                      AND dr.device_uuid = ?
                 WHERE al.timestamp >= DATE_SUB(NOW(), INTERVAL 30 SECOND)
                   AND (
                       LOWER(al.event) LIKE '%trigger%'
                    OR LOWER(al.event) LIKE '%alarm%'
                    OR LOWER(al.event) LIKE '%breach%'
                    OR LOWER(al.event) LIKE '%sensor%'
                    OR LOWER(al.event) LIKE '%door%'
                    OR LOWER(al.event) LIKE '%motion%'
                    OR LOWER(al.event) LIKE '%window%'
                   )
                 ORDER BY al.timestamp DESC
                 LIMIT 5",
                [$device_uuid]
            );
 
            foreach ($rows as $row) {
                // Guess sensor type from device name / event text
                $type = $this->_guessSensorType(
                    $row['type'],
                    $row['name'],
                    $row['event']
                );
 
                $triggeredSensors[] = [
                    'id'   => (string)$row['id'],
                    'name' => $row['name'],
                    'type' => $type,
                    'zone' => $row['zone'],
                ];
            }
        }
 
        // ── Also check paired_accessories for triggered sensors ─
        // If ESP32 marks an accessory status = 'triggered', include it
        if ($alarmActive) {
            $hub = $this->db->fetchOne(
                "SELECT id FROM device_registry
                 WHERE (device_uuid = ? OR ble_service_uuid = ?)
                   AND is_active = 1 LIMIT 1",
                [$device_uuid, $device_uuid]
            );
 
            if ($hub) {
                $accessories = $this->db->fetchAll(
                    "SELECT 
                         accessory_uuid   AS id,
                         accessory_name   AS name,
                         accessory_type   AS type,
                         zone_name        AS zone
                     FROM paired_accessories
                     WHERE hub_device_id = ?
                       AND status = 'triggered'
                       AND is_active = 1
                     ORDER BY last_seen_at DESC
                     LIMIT 5",
                    [$hub['id']]
                );
 
                // Merge, dedup by id
                $existingIds = array_column($triggeredSensors, 'id');
                foreach ($accessories as $acc) {
                    if (!in_array($acc['id'], $existingIds)) {
                        $triggeredSensors[] = $acc;
                        $existingIds[] = $acc['id'];
                    }
                }
            }
        }
 
        $this->sendResponse([
            'success'           => true,
            'alarm_active'      => $alarmActive,
            'current_state'     => $currentState,
            'triggered_sensors' => $triggeredSensors,
            'checked_at'        => date('Y-m-d H:i:s'),
        ]);
 
    } catch (Exception $e) {
        error_log("getAlarmStatus error: " . $e->getMessage());
        $this->sendResponse(['error' => $e->getMessage()], 500);
    }
}
 
// ── Helper: guess sensor type from device name / event text ──
private function _guessSensorType(
    string $dbType,
    string $name,
    string $event
): string {
    // Trust the DB type if it's a known sensor type
    if (in_array($dbType, ['door', 'window', 'motion', 'remote', 'camera'])) {
        return $dbType;
    }
 
    $combined = strtolower($name . ' ' . $event);
 
    if (str_contains($combined, 'door'))   return 'door';
    if (str_contains($combined, 'window')) return 'window';
    if (str_contains($combined, 'motion')) return 'motion';
    if (str_contains($combined, 'remote')) return 'remote';
    if (str_contains($combined, 'camera')) return 'camera';
 
    return 'sensor';
}

 
    private function getContactNumbers() {
        try {
            $device_uuid = $_GET['device_uuid'] ?? '';

            if (empty($device_uuid)) {
                $this->sendResponse(['error' => 'Device UUID required'], 400);
                return;
            }

            $device = $this->db->fetchOne(
                "SELECT id FROM device_registry WHERE device_uuid = ?",
                [$device_uuid]
            );
            
            if (!$device) {
                $this->sendResponse(['error' => 'Device not found'], 404);
                return;
            }

            $device_id = $device['id'];
            
            $contacts = $this->db->fetchAll(
                "SELECT id, phone_number, contact_name, number_type, priority, is_active
                 FROM contact_numbers 
                 WHERE device_id = ? AND is_active = 1
                 ORDER BY number_type ASC, priority ASC",
                [$device_id]
            );

            $this->sendResponse([
                'success' => true,
                'device_id' => $device_id,
                'device_uuid' => $device_uuid,
                'total_contacts' => count($contacts),
                'contacts' => $contacts
            ]);

        } catch (Exception $e) {
            error_log("Get contact numbers error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    private function addContactNumber() {
        try {
            $data = $this->getInput();
            $device_uuid = $data['device_uuid'] ?? '';
            $phone_number = $data['phone_number'] ?? '';
            $number_type = $data['number_type'] ?? 'call';

            if (empty($device_uuid) || empty($phone_number)) {
                throw new Exception('Device UUID and phone number are required');
            }

          $device = $this->db->fetchOne(
    "SELECT id FROM device_registry WHERE device_uuid = ?",
    [$device_uuid]
);

if (!$device) {
    // fallback to mobile_devices for legacy support
    $device = $this->db->fetchOne(
        "SELECT id FROM mobile_devices WHERE device_uuid = ?",
        [$device_uuid]
    );
}

if (!$device) {
    throw new Exception('Device not found');
}

            $device_id = $device['id'];

            $maxPriority = $this->db->fetchOne(
                "SELECT MAX(priority) as max_priority FROM contact_numbers 
                 WHERE device_id = ? AND number_type = ?",
                [$device_id, $number_type]
            );

            $priority = ($maxPriority['max_priority'] ?? 0) + 1;

            $this->db->insert('contact_numbers', [
                'device_id' => $device_id,
                'phone_number' => $phone_number,
                'contact_name' => $data['contact_name'] ?? '',
                'number_type' => $number_type,
                'priority' => $priority,
                'is_active' => true
            ]);

            $this->logActivity("Contact Added: $phone_number ($number_type)", 'Contact Management', $data['user'] ?? 'API');

            $this->sendResponse(['success' => true]);

        } catch (Exception $e) {
            error_log("Add contact number error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    private function deleteContactNumber() {
        try {
            $data = $this->getInput();
            $device_uuid = $data['device_uuid'] ?? '';
            $contact_id = $data['contact_id'] ?? '';

            if (empty($device_uuid) || empty($contact_id)) {
                throw new Exception('Device UUID and contact ID are required');
            }

         $device = $this->db->fetchOne(
    "SELECT id FROM device_registry WHERE device_uuid = ?",
    [$device_uuid]
);

if (!$device) {
    $device = $this->db->fetchOne(
        "SELECT id FROM mobile_devices WHERE device_uuid = ?",
        [$device_uuid]
    );
}

if (!$device) {
    throw new Exception('Device not found');
}

            $device_id = $device['id'];

            $this->db->query(
                "UPDATE contact_numbers SET is_active = FALSE WHERE id = ? AND device_id = ?",
                [$contact_id, $device_id]
            );

            $this->logActivity("Contact Removed: ID $contact_id", 'Contact Management', $data['user'] ?? 'API');

            $this->sendResponse(['success' => true]);

        } catch (Exception $e) {
            error_log("Delete contact number error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    private function getSettingsHistory() {
        try {
            $device_uuid = $_GET['device_uuid'] ?? '';
            $limit = min(max(1, intval($_GET['limit'] ?? 50)), 500);

            if (empty($device_uuid)) {
                throw new Exception('Device UUID is required');
            }

            $device = $this->db->fetchOne(
                "SELECT id FROM mobile_devices WHERE device_uuid = ?",
                [$device_uuid]
            );

            if (!$device) {
                throw new Exception('Device not found');
            }

            $history = $this->db->fetchAll(
                "SELECT id, device_id, setting_name, old_value, new_value, changed_by, changed_at
                 FROM settings_history
                 WHERE device_id = ?
                 ORDER BY changed_at DESC
                 LIMIT " . intval($limit),
                [$device['id']]
            );

            $this->sendResponse([
                'success' => true,
                'total' => count($history),
                'history' => $history
            ]);

        } catch (Exception $e) {
            error_log("Get settings history error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    private function getSyncLogs() {
        try {
            $device_uuid = $_GET['device_uuid'] ?? '';
            $limit = min(max(1, intval($_GET['limit'] ?? 50)), 500);

            if (empty($device_uuid)) {
                throw new Exception('Device UUID is required');
            }

            $device = $this->db->fetchOne(
                "SELECT id FROM mobile_devices WHERE device_uuid = ?",
                [$device_uuid]
            );

            if (!$device) {
                throw new Exception('Device not found');
            }

            $logs = $this->db->fetchAll(
                "SELECT id, device_id, sync_type, sync_status, error_message, synced_at
                 FROM settings_sync_log
                 WHERE device_id = ?
                 ORDER BY synced_at DESC
                 LIMIT " . intval($limit),
                [$device['id']]
            );

            $this->sendResponse([
                'success' => true,
                'total' => count($logs),
                'logs' => $logs
            ]);

        } catch (Exception $e) {
            error_log("Get sync logs error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    private function getAllSettings() {
        try {
            $all_settings = $this->db->fetchAll(
                "SELECT ds.id, ds.device_id, ds.setting_key, ds.setting_value, ds.data_type, 
                        ds.updated_at, md.device_uuid, md.display_name
                 FROM device_settings ds
                 JOIN mobile_devices md ON ds.device_id = md.id
                 ORDER BY md.device_uuid, ds.setting_key"
            );

            $this->sendResponse([
                'success' => true,
                'total' => count($all_settings),
                'settings' => $all_settings
            ]);

        } catch (Exception $e) {
            error_log("Get all settings error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }

    // ============================================
    // EXISTING METHODS (KEPT FOR COMPATIBILITY)
    // ============================================

    private function registerMobileDevice() {
        try {
            $input = $this->getInput();

            if (!isset($input['device_uuid'], $input['display_name'], $input['qr_data'])) {
                $this->sendResponse(['error' => 'Missing required parameters'], 400);
                return;
            }

            $deviceUuid = $input['device_uuid'];
            $exists = $this->db->fetchOne(
                "SELECT * FROM mobile_devices WHERE device_uuid = :device_uuid",
                ['device_uuid' => $deviceUuid]
            );

            if ($exists) {
                $this->db->update(
                    'mobile_devices',
                    [
                        'display_name' => $input['display_name'],
                        'status' => 'online',
                        'qr_data' => $input['qr_data'],
                        'last_active_at' => date('Y-m-d H:i:s')
                    ],
                    'device_uuid = :device_uuid',
                    ['device_uuid' => $deviceUuid]
                );
                $this->logActivity('Device Re-registered: ' . $input['display_name'], 'Mobile Device', 'API');
            } else {
                $this->db->insert('mobile_devices', [
                    'device_uuid' => $input['device_uuid'],
                    'display_name' => $input['display_name'],
                    'status' => 'online',
                    'qr_data' => $input['qr_data'],
                    'registered_at' => date('Y-m-d H:i:s'),
                    'last_active_at' => date('Y-m-d H:i:s')
                ]);
                $this->logActivity('Device Registered: ' . $input['display_name'], 'Mobile Device', 'API');
            }

            $this->sendResponse([
                'status' => 'registered',
                'success' => true,
                'message' => 'Device registered successfully',
                'device_uuid' => $input['device_uuid']
            ]);

        } catch (Exception $e) {
            error_log("Registration error: " . $e->getMessage());
            $this->sendResponse(['error' => 'Registration failed: ' . $e->getMessage()], 500);
        }
    }

    private function getMobileDevices()
{
    $devices = $this->db->fetchAll(
        "SELECT
             id,
             deviceuuid,
             displayname,
             status,
             registeredat,
             lastactiveat,
             devicetype,
             connectiontype,
             devicemodel
         FROM mobiledevices
         ORDER BY lastactiveat DESC, registeredat DESC"
    );

    $this->sendResponse(['devices' => $devices]);
}


    private function saveWifiCredentials() {
        $input = $this->getInput();
        if (!isset($input['device_uuid'], $input['ssid'], $input['password'])) {
            $this->sendResponse(['error' => 'Missing parameters'], 400);
            return;
        }

        $exists = $this->db->fetchOne(
            "SELECT * FROM device_wifi WHERE device_uuid = :device_uuid",
            ['device_uuid' => $input['device_uuid']]
        );

        $data = [
            'device_uuid' => $input['device_uuid'],
            'ssid' => $input['ssid'],
            'password' => $input['password'],
            'updated_at' => date('Y-m-d H:i:s')
        ];

        if ($exists) {
            $this->db->update('device_wifi', $data, 'device_uuid = :device_uuid', ['device_uuid' => $input['device_uuid']]);
        } else {
            $data['created_at'] = date('Y-m-d H:i:s');
            $this->db->insert('device_wifi', $data);
        }

        $this->sendResponse(['success' => true]);
    }

    private function getWifiCredentials() {
        $device_uuid = $_GET['device_uuid'] ?? '';
        if (!$device_uuid) {
            $this->sendResponse(['error' => 'Missing device_uuid'], 400);
            return;
        }

        $wifi = $this->db->fetchOne(
            "SELECT ssid, password FROM device_wifi WHERE device_uuid = :device_uuid",
            ['device_uuid' => $device_uuid]
        );

        $this->sendResponse(['wifi' => $wifi ?: null]);
    }

    private function isValidWavFile($filePath) {
        $handle = fopen($filePath, 'rb');
        if (!$handle) {
            return false;
        }

        $riff = fread($handle, 4);
        $fileSizeBytes = fread($handle, 4);
        $wave = fread($handle, 4);

        if ($riff !== 'RIFF' || $wave !== 'WAVE') {
            fclose($handle);
            return false;
        }

        $fmtFound = false;
        while (!feof($handle)) {
            $chunkId = fread($handle, 4);
            if (empty($chunkId) || strlen($chunkId) < 4) {
                break;
            }

            $chunkSizeRaw = fread($handle, 4);
            if (strlen($chunkSizeRaw) < 4) {
                break;
            }

            $chunkSize = unpack('V', $chunkSizeRaw)[1];

            if ($chunkId === 'fmt ') {
                $fmtFound = true;
                $fmtData = fread($handle, $chunkSize);

                if (strlen($fmtData) < 16) {
                    fclose($handle);
                    return false;
                }

                $audioFormat = unpack('v', substr($fmtData, 0, 2))[1];
                $channels = unpack('v', substr($fmtData, 2, 2))[1];
                $sampleRate = unpack('V', substr($fmtData, 4, 4))[1];
                $bitDepth = unpack('v', substr($fmtData, 14, 2))[1];

                $isValid = ($audioFormat === 1 && $channels === 1 && $sampleRate === 8000 && $bitDepth === 8);

                fclose($handle);
                return $isValid;
            }

            if ($chunkId !== 'fmt ') {
                fseek($handle, $chunkSize, SEEK_CUR);
            }
        }

        fclose($handle);
        return $fmtFound;
    }

    private function saveVoiceRecording() {
        try {
            if (!isset($_FILES['voice_file']['tmp_name']) || empty($_FILES['voice_file']['tmp_name'])) {
                $this->sendResponse(['error' => 'Missing voice_file upload'], 400);
                return;
            }

            if (!isset($_POST['name']) || empty($_POST['name'])) {
                $this->sendResponse(['error' => 'Missing name parameter'], 400);
                return;
            }

            $fileTmpPath = $_FILES['voice_file']['tmp_name'];

            $uploadDir = __DIR__ . '/uploads/';

            if (!file_exists($uploadDir)) {
                if (!mkdir($uploadDir, 0777, true)) {
                    $this->sendResponse(['error' => 'Failed to create uploads directory'], 500);
                    return;
                }
            }

            if (!$this->isValidWavFile($fileTmpPath)) {
                $this->sendResponse(['error' => 'Invalid WAV file format'], 400);
                return;
            }

            $wavContent = file_get_contents($fileTmpPath);
            $rawPcmData = substr($wavContent, 44);
            $bytes = unpack('C*', $rawPcmData);

            $cArrayString = "const unsigned char voice_data[] = {";
            foreach ($bytes as $b) {
                $cArrayString .= sprintf("0x%02X,", $b);
            }
            $cArrayString = rtrim($cArrayString, ',') . "};\n";
            $cArrayString .= "const unsigned int voice_data_len = " . count($bytes) . ";\n";

            $name = $_POST['name'];
            $data = [
                'name' => $name,
                'voice_data' => $cArrayString,
                'voice_data_len' => count($bytes),
                'sample_rate' => 8000,
                'bit_depth' => 8,
                'channels' => 1,
                'format' => 'unsigned_pcm'
            ];

            $id = $this->db->insert('voice_recordings', $data);

            $this->logActivity('Voice Recording Uploaded: ' . $name, 'Voice Recorder', 'Mobile App');

            $this->sendResponse([
                'success' => true,
                'id' => $id,
                'message' => 'Voice recording saved successfully'
            ]);

        } catch (Exception $e) {
            error_log("Save voice recording error: " . $e->getMessage());
            $this->sendResponse(['error' => 'Failed to save voice recording: ' . $e->getMessage()], 500);
        }
    }

    private function getVoiceRecordings() {
        try {
            $recordings = $this->db->fetchAll(
                "SELECT id, name, sample_rate, file_url, created_at FROM voice_recordings ORDER BY created_at DESC"
            );
            $this->sendResponse(['success' => true, 'recordings' => $recordings]);
        } catch (Exception $e) {
            error_log("Get voice recordings error: " . $e->getMessage());
            $this->sendResponse(['error' => 'Failed to fetch voice recordings: ' . $e->getMessage()], 500);
        }
    }

    private function addActivityLog() {
        $input = $this->getInput();
        if (!isset($input['event']) || !isset($input['device']) || !isset($input['user'])) {
            $this->sendResponse(['error' => 'Missing required fields'], 400);
            return;
        }

        $logData = [
            'event' => $input['event'],
            'device' => $input['device'],
            'user' => $input['user'],
            'details' => $input['details'] ?? null,
            'severity' => $input['severity'] ?? 'info',
            'timestamp' => date('Y-m-d H:i:s'),
            'ip_address' => $_SERVER['REMOTE_ADDR'] ?? null
        ];

        $id = $this->db->insert('activity_logs', $logData);
        $this->sendResponse(['success' => true, 'id' => $id]);
    }

    private function handleTest() {
        if ($this->requestMethod === 'GET') {
            $this->sendResponse([
                'message' => 'API is working',
                'timestamp' => date('Y-m-d H:i:s'),
                'server' => $_SERVER['SERVER_NAME'] ?? 'localhost',
                'device_registry_enabled' => true
            ]);
        } else {
            $this->sendResponse(['error' => 'Method not allowed'], 405);
        }
    }

    private function getSystemState() {
        $state = $this->db->fetchOne("SELECT * FROM system_state ORDER BY updated_at DESC LIMIT 1");
        if (!$state) {
            $defaultState = [
                'state' => 'disarmed',
                'updated_at' => date('Y-m-d H:i:s'),
                'updated_by' => 'system'
            ];
            $this->db->insert('system_state', $defaultState);
            $state = $defaultState;
        }
        $this->sendResponse($state);
    }

    private function updateSystemState() {
    error_log("SYSTEM STATE INPUT: " . json_encode($this->getInput()));
        $input = $this->getInput();
        if (!isset($input['state'])) {
            $this->sendResponse(['error' => 'State is required'], 400);
            return;
        }

        $validStates = ['disarmed', 'armed', 'stay_arm', 'alarm'];
        if (!in_array($input['state'], $validStates)) {
            $this->sendResponse(['error' => 'Invalid state'], 400);
            return;
        }

        $prev = $this->db->fetchOne("SELECT state FROM system_state ORDER BY id DESC LIMIT 1");
        $reason = null;
        if (isset($input['reason']) && is_string($input['reason'])) {
            $reason = trim($input['reason']);
        } elseif (isset($input['alarm_reason']) && is_string($input['alarm_reason'])) {
            $reason = trim($input['alarm_reason']);
        } elseif (isset($input['triggered_sensor']) && is_string($input['triggered_sensor'])) {
            $reason = trim($input['triggered_sensor']);
        }
        if ($reason === '') {
            $reason = null;
        }

        $stateData = [
            'state' => $input['state'],
            'previous_state' => $prev['state'] ?? null,
            'updated_at' => date('Y-m-d H:i:s'),
            'updated_by' => $input['user'] ?? 'api',
            'reason' => $reason,
        ];

        $this->db->insert('system_state', $stateData);
        $this->logActivity($this->getStateDisplayName($input['state']), 'Control Panel', $input['user'] ?? 'API');

        $this->sendResponse(['success' => true, 'state' => $input['state']]);
    }

    private function getDevices() {
        $devices = $this->db->fetchAll(
            "SELECT 
                id,
                device_name AS name,
                device_type AS type,
                status,
                COALESCE(battery_level, 0) AS battery,
                COALESCE(zone_name, '') AS zone,
                last_seen_at AS last_activity,
                registered_at AS created_at,
                device_uuid,
                connection_type
             FROM device_registry
             WHERE is_active = TRUE
             ORDER BY device_name"
        );
        $this->sendResponse(['devices' => $devices]);
    }

    private function getActivityLogs() {
        $limit = $_GET['limit'] ?? 50;
        $limit = min(max(1, intval($limit)), 100);
        $sql = "SELECT timestamp, event, device, user FROM activity_logs ORDER BY timestamp DESC LIMIT $limit";
        $logs = $this->db->fetchAll($sql);
        $this->sendResponse(['logs' => $logs]);
    }

    private function getInput() {
        return json_decode(file_get_contents('php://input'), true) ?? [];
    }

    private function sendResponse($data, $statusCode = 200) {
        http_response_code($statusCode);
        echo json_encode($data, JSON_PRETTY_PRINT);
        exit();
    }

    private function logActivity($event, $device, $user) {
        try {
            $logData = [
                'timestamp' => date('Y-m-d H:i:s'),
                'event' => $event,
                'device' => $device,
                'user' => $user
            ];
            $this->db->insert('activity_logs', $logData);
        } catch (Exception $e) {
            error_log("Failed to log activity: " . $e->getMessage());
        }
    }

    private function getStateDisplayName($state) {
        switch ($state) {
            case 'armed': return 'System Armed';
            case 'stay_arm': return 'System Armed (Stay)';
            case 'alarm': return 'Alarm Triggered';
            case 'disarmed': return 'System Disarmed';
            default: return 'System State Changed';
        }
    }
    private function saveSchedules() {
    try {
        $data = $this->getInput();
        $device_uuid = $data['device_uuid'] ?? '';
        $schedules = $data['schedules'] ?? [];

        if (empty($device_uuid)) {
            throw new Exception('Device UUID is required');
        }

        $device = $this->db->fetchOne(
            "SELECT id FROM device_registry WHERE device_uuid = ?",
            [$device_uuid]
        );

        if (!$device) {
            $device = $this->db->fetchOne(
                "SELECT id FROM mobile_devices WHERE device_uuid = ?",
                [$device_uuid]
            );
        }

        if (!$device) {
            throw new Exception('Device not found');
        }

        $device_id = $device['id'];
        $this->db->beginTransaction();

        $this->db->query(
            "DELETE FROM alarm_schedules WHERE device_id = ?",
            [$device_id]
        );

        $inserted = 0;
        foreach ($schedules as $schedule) {
            if (empty($schedule['id']) || empty($schedule['name'])) {
                continue;
            }

            $scheduleData = [
                'device_id' => $device_id,
                'schedule_id' => $schedule['id'],
                'schedule_name' => $schedule['name'],
                'start_time' => $schedule['startTime'] ?? '00:00',
                'end_time' => $schedule['endTime'] ?? '00:00',
                'active_days' => json_encode($schedule['activeDays'] ?? []),
                'is_enabled' => ($schedule['isEnabled'] ?? true) ? 1 : 0,
            ];

            $this->db->insert('alarm_schedules', $scheduleData);
            $inserted++;
        }

        $this->db->commit();

        $this->sendResponse([
            'success' => true,
            'message' => "Saved $inserted schedules",
            'total' => $inserted,
        ]);

    } catch (Exception $e) {
        if ($this->db->getConnection()->inTransaction()) {
            $this->db->rollBack();
        }
        error_log("Save schedules error: " . $e->getMessage());
        $this->sendResponse(['error' => $e->getMessage()], 500);
    }
}

private function getSchedules() {
    try {
        $device_uuid = $_GET['device_uuid'] ?? '';

        if (empty($device_uuid)) {
            throw new Exception('Device UUID is required');
        }

        $device = $this->db->fetchOne(
            "SELECT id FROM device_registry WHERE device_uuid = ?",
            [$device_uuid]
        );

        if (!$device) {
            $device = $this->db->fetchOne(
                "SELECT id FROM mobile_devices WHERE device_uuid = ?",
                [$device_uuid]
            );
        }

        if (!$device) {
            throw new Exception('Device not found');
        }

        $device_id = $device['id'];

        $schedules = $this->db->fetchAll(
            "SELECT id, schedule_id, schedule_name, start_time, end_time, 
                    active_days, is_enabled, created_at, updated_at
             FROM alarm_schedules
             WHERE device_id = ?
             ORDER BY schedule_name",
            [$device_id]
        );

        foreach ($schedules as &$schedule) {
            $schedule['active_days'] = json_decode($schedule['active_days'], true);
            $schedule['is_enabled'] = (bool)$schedule['is_enabled'];
        }

        $this->sendResponse([
            'success' => true,
            'device_uuid' => $device_uuid,
            'total' => count($schedules),
            'schedules' => $schedules,
        ]);

    } catch (Exception $e) {
        error_log("Get schedules error: " . $e->getMessage());
        $this->sendResponse(['error' => $e->getMessage()], 500);
    }
}

private function deleteSchedule() {
    try {
        $data = $this->getInput();
        $device_uuid = $data['device_uuid'] ?? '';
        $schedule_id = $data['schedule_id'] ?? '';

        if (empty($device_uuid) || empty($schedule_id)) {
            throw new Exception('Device UUID and schedule ID are required');
        }

        $device = $this->db->fetchOne(
            "SELECT id FROM device_registry WHERE device_uuid = ?",
            [$device_uuid]
        );

        if (!$device) {
            $device = $this->db->fetchOne(
                "SELECT id FROM mobile_devices WHERE device_uuid = ?",
                [$device_uuid]
            );
        }

        if (!$device) {
            throw new Exception('Device not found');
        }

        $this->db->query(
            "DELETE FROM alarm_schedules WHERE device_id = ? AND schedule_id = ?",
            [$device['id'], $schedule_id]
        );

        $this->sendResponse(['success' => true]);

    } catch (Exception $e) {
        error_log("Delete schedule error: " . $e->getMessage());
        $this->sendResponse(['error' => $e->getMessage()], 500);
    }
}
private function alarmEvent() {
    try {
        $data = $this->getInput();

        $device_uuid = $data['device_uuid'] ?? '';
        $event_type  = $data['event_type'] ?? '';
        $zone        = $data['zone'] ?? '';
        $message     = $data['message'] ?? '';
        $timestamp   = date('Y-m-d H:i:s');

        if (empty($device_uuid) || empty($event_type)) {
            throw new Exception("Missing required fields");
        }

        // ✅ Save event
        $this->db->insert('alarm_events', [
            'device_uuid' => $device_uuid,
            'event_type'  => $event_type,
            'zone'        => $zone,
            'message'     => $message,
            'created_at'  => $timestamp
        ]);

        // ✅ Update system state
        if ($event_type === 'ALARM_TRIGGER') {
            $this->db->query(
                "UPDATE system_state SET state='alarm', updated_at=?",
                [$timestamp]
            );
        }

        $this->sendResponse([
            'success' => true,
            'message' => 'Event stored'
        ]);

    } catch (Exception $e) {
        $this->sendResponse(['error' => $e->getMessage()], 500);
    }
}

 // POST ?action=accessorypair
// Body JSON: { hubdeviceuuid, accessoryuuid, name, type, zonename, remotemode, deviceblename }
// POST ?action=accessorypair
// Body JSON: { hubdeviceuuid, accessoryuuid, name, type, zonename, remotemode, deviceblename }
private function accessoryPair() {
    try {
        $data          = $this->getInput();
        $hubuuid       = $data['hub_device_uuid'] ?? null;
        $accessoryuuid = $data['accessory_uuid']  ?? null;
        $name          = $data['name']            ?? 'Sensor';
        $type          = $data['type']            ?? null;
        $zone          = $data['zone_name']       ?? 'General';
        $remotemode    = $data['remote_mode']     ?? null;
        $deviceblename = $data['device_ble_name'] ?? null;
        $status        = $data['status']          ?? 'pairing'; // ← default pairing

        if (empty($hubuuid) || empty($accessoryuuid) || empty($type)) {
            throw new Exception('hub_device_uuid, accessory_uuid and type are required');
        }

        $validTypes = ['remote', 'motion', 'door'];
        if (!in_array($type, $validTypes)) {
            throw new Exception('type must be remote, motion, or door');
        }

        // ── Build JSON payload ──────────────────────────────────
        $payload = [
            'hub_device_uuid' => $hubuuid,
            'accessory_uuid'  => $accessoryuuid,
            'name'            => $name,
            'type'            => $type,
            'zone_name'       => $zone,
            'remote_mode'     => $remotemode,
            'device_ble_name' => $deviceblename,
            'status'          => $status,
            'requested_at'    => date('Y-m-d H:i:s'),
        ];
        $payloadJson = json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);

        // ── Find hub ────────────────────────────────────────────
        $hub = $this->db->fetchOne(
    "SELECT id FROM device_registry
     WHERE (device_uuid = ? OR ble_service_uuid = ?)
       AND is_active = 1
     LIMIT 1",
    [$hubuuid, $hubuuid]
);
if (!$hub) {
    throw new Exception('Hub device not found in device_registry');
}
        $hubid = $hub['id'];
        $now   = date('Y-m-d H:i:s');

        // ── Check if exists ─────────────────────────────────────
        $existing = $this->db->fetchOne(
            "SELECT id FROM paired_accessories WHERE accessory_uuid = ?",
            [$accessoryuuid]
        );

        if ($existing) {
            $updateData = [
                'accessory_name'  => $name,
                'accessory_type'  => $type,
                'zone_name'       => $zone,
                'remote_mode'     => $remotemode,
                'pairing_payload' => $payloadJson,
                'status'          => $status,
                'is_active'       => 1,
                'last_seen_at'    => $now,
            ];
            if ($deviceblename !== null) {
                $updateData['device_ble_name'] = $deviceblename;
            }

            $this->db->update(
                'paired_accessories',
                $updateData,
                'accessory_uuid = :accessory_uuid',
                ['accessory_uuid' => $accessoryuuid]
            );

            $this->sendResponse([
                'success' => true,
                'action'  => 'updated',
                'id'      => $existing['id'],
                'status'  => $status,
            ]);
        } else {
            // ── INSERT new row as pairing ───────────────────────
            $insertData = [
                'hub_device_id'   => $hubid,
                'accessory_uuid'  => $accessoryuuid,
                'accessory_name'  => $name,
                'device_ble_name' => $deviceblename,
                'accessory_type'  => $type,
                'remote_mode'     => $remotemode,
                'zone_name'       => $zone,
                'pairing_payload' => $payloadJson,
                'status'          => $status,   // ← 'pairing'
                'is_active'       => 1,
                'last_seen_at'    => $now,
            ];

            $id = $this->db->insert('paired_accessories', $insertData);

            $this->sendResponse([
                'success' => true,
                'action'  => 'created',
                'id'      => $id,
                'status'  => $status,
            ]);
        }

    } catch (Exception $e) {
        error_log('accessoryPair error: ' . $e->getMessage());
        $this->sendResponse(['success' => false, 'error' => $e->getMessage()], 500);
    }
}

    // ----------------------------------------------------------
    // GET ?action=accessory_list&hub_device_uuid=xxx
    //     optional: &type=door   to filter by type
    // ----------------------------------------------------------
    private function accessoryList() {
        try {
            $hub_uuid = $_GET['hub_device_uuid'] ?? '';
            $type     = $_GET['type']            ?? '';
 
            if (empty($hub_uuid)) {
                throw new Exception('hub_device_uuid is required');
            }
 
            $hub = $this->db->fetchOne(
    "SELECT id FROM device_registry
     WHERE (device_uuid = ? OR ble_service_uuid = ?)
       AND is_active = 1
     LIMIT 1",
    [$hub_uuid, $hub_uuid]
);
if (!$hub) {
    throw new Exception('Hub device not found');
}
            $sql    = "SELECT * FROM paired_accessories WHERE hub_device_id = ? AND is_active = 1";
            $params = [$hub['id']];
 
            if (!empty($type)) {
                $sql    .= " AND accessory_type = ?";
                $params[] = $type;
            }
            $sql .= " ORDER BY accessory_type, accessory_name";
 
            $accessories = $this->db->fetchAll($sql, $params);
 
            $this->sendResponse([
                'success'     => true,
                'total'       => count($accessories),
                'accessories' => $accessories,
            ]);
 
        } catch (Exception $e) {
            error_log("accessoryList error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }
 
 
    // ----------------------------------------------------------
    // POST ?action=accessory_delete
    // Body: { accessory_uuid }
    // ----------------------------------------------------------
    private function accessoryDelete() {
        try {
            $data            = $this->getInput();
            $accessory_uuid  = $data['accessory_uuid'] ?? '';
 
            if (empty($accessory_uuid)) {
                throw new Exception('accessory_uuid is required');
            }
 
            $result = $this->db->query(
                "UPDATE paired_accessories SET is_active = 0 WHERE accessory_uuid = ?",
                [$accessory_uuid]
            );
 
            if ($result->rowCount() > 0) {
                $this->sendResponse(['success' => true]);
            } else {
                $this->sendResponse(['success' => false, 'message' => 'Accessory not found'], 404);
            }
 
        } catch (Exception $e) {
            error_log("accessoryDelete error: " . $e->getMessage());
            $this->sendResponse(['error' => $e->getMessage()], 500);
        }
    }
private function getPairingRequest() {
    try {
        $device_uuid = trim($_GET['device_uuid'] ?? '');
        $hub_uuid = trim($_GET['hub_device_uuid'] ?? '');

        if ($device_uuid === '' && $hub_uuid === '') {
            throw new Exception('device_uuid or hub_device_uuid is required');
        }
        $search = $device_uuid !== '' ? $device_uuid : $hub_uuid;

// Search by device_uuid OR ble_service_uuid so ESP32's WiFi UUID
// finds the same record as Flutter's BLE MAC
$hub = $this->db->fetchOne(
    "SELECT id, device_uuid
     FROM device_registry
     WHERE (device_uuid = ? OR ble_service_uuid = ?)
       AND is_active = 1
     LIMIT 1",
    [$search, $search]
);
        
        if (!$hub) {
            $this->sendResponse(['has_request' => false, 'message' => 'Hub not found']);
            return;
        }
 
        // Fetch the oldest pending pairing record for this hub
        $row = $this->db->fetchOne(
            "SELECT id, accessory_uuid, accessory_type, accessory_name,
                    zone_name, remote_mode, paired_at AS requested_at
             FROM paired_accessories
             WHERE hub_device_id = ?
               AND status = 'pairing'
               AND is_active = 1
             ORDER BY paired_at ASC
             LIMIT 1",
            [$hub['id']]
        );
 
        if (!$row) {
            $this->sendResponse(['has_request' => false]);
            return;
        }
 
        $this->sendResponse([
            'has_request'    => true,
            'pairing_id'     => (int)$row['id'],
            'accessory_uuid' => $row['accessory_uuid'],
            'accessory_type' => $row['accessory_type'],
            'accessory_name' => $row['accessory_name'],
            'name'           => $row['accessory_name'],
            'type'           => $row['accessory_type'],
            'status'         => 'pairing',
            'zone_name'      => $row['zone_name'] ?? 'General',
            'remote_mode'    => $row['remote_mode'],
            'requested_at'   => $row['requested_at'],
        ]);
 
    } catch (Exception $e) {
        error_log('getPairingRequest error: ' . $e->getMessage());
        $this->sendResponse(['error' => $e->getMessage()], 500);
    }
}
private function updatePairingStatus() {
    try {
        $data          = $this->getInput();
        $pairing_id    = (int)($data['pairing_id']      ?? 0);
        $new_uuid      = trim($data['accessory_uuid']   ?? '');
        $ble_name      = trim($data['device_ble_name']  ?? '');
        $status        = trim($data['status']           ?? 'paired');
 
        // Validate status
        $allowed = ['paired', 'failed', 'pairing', 'pairing_started', 'already_paired', 'timeout'];
        if (!in_array($status, $allowed)) {
            throw new Exception("status must be one of: " . implode(', ', $allowed));
        }
 
        if ($pairing_id <= 0 && $new_uuid === '') {
            throw new Exception('pairing_id or accessory_uuid is required');
        }

        if ($pairing_id > 0) {
            $existing = $this->db->fetchOne(
                "SELECT id, accessory_uuid FROM paired_accessories WHERE id = ?",
                [$pairing_id]
            );
        } else {
            $existing = $this->db->fetchOne(
                "SELECT id, accessory_uuid FROM paired_accessories WHERE accessory_uuid = ?",
                [$new_uuid]
            );
        }
 
        if (!$existing) {
            throw new Exception('Pairing record not found');
        }

        $pairing_id = (int)$existing['id'];
 
        // Build update data
        $updateData = [
            'status'       => $status,
            'last_seen_at' => date('Y-m-d H:i:s'),
        ];
 
        // Only update the UUID + BLE name if the ESP32 sent back a real MAC
        // (i.e. it's not the temp "pairing_xxx" placeholder UUID)
        if (!empty($new_uuid) && !str_starts_with($new_uuid, 'pairing_')) {
            $updateData['accessory_uuid']  = $new_uuid;
            if (!empty($ble_name)) {
                $updateData['device_ble_name'] = $ble_name;
            }
        } elseif (!empty($ble_name)) {
            $updateData['device_ble_name'] = $ble_name;
        }
 
        $this->db->update(
            'paired_accessories',
            $updateData,
            'id = :id',
            ['id' => $pairing_id]
        );
 
        // Log the status change
        error_log("Pairing id=$pairing_id updated to status=$status"
                  . " uuid=$new_uuid ble_name=$ble_name");
 
        $this->sendResponse([
            'success'    => true,
            'pairing_id' => $pairing_id,
            'status'     => $status,
        ]);
 
    } catch (Exception $e) {
        error_log('updatePairingStatus error: ' . $e->getMessage());
        $this->sendResponse(['error' => $e->getMessage()], 500);
    }
}
private function toggleSchedule() {
    try {
        $data = $this->getInput();
        $device_uuid = $data['device_uuid'] ?? '';
        $schedule_id = $data['schedule_id'] ?? '';

        if (empty($device_uuid) || empty($schedule_id)) {
            throw new Exception('Device UUID and schedule ID are required');
        }

        $device = $this->db->fetchOne(
            "SELECT id FROM device_registry WHERE device_uuid = ?",
            [$device_uuid]
        );

        if (!$device) {
            $device = $this->db->fetchOne(
                "SELECT id FROM mobile_devices WHERE device_uuid = ?",
                [$device_uuid]
            );
        }

        if (!$device) {
            throw new Exception('Device not found');
        }

        $this->db->query(
            "UPDATE alarm_schedules 
             SET is_enabled = NOT is_enabled 
             WHERE device_id = ? AND schedule_id = ?",
            [$device['id'], $schedule_id]
        );

        $this->sendResponse(['success' => true]);

    } catch (Exception $e) {
        error_log("Toggle schedule error: " . $e->getMessage());
        $this->sendResponse(['error' => $e->getMessage()], 500);
    }
}
}

// ============================================
// INITIALIZE AND ROUTE
// ============================================

$router = new ApiRouter();
$router->route();

?>
