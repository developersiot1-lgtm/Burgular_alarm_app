#define TINY_GSM_MODEM_SIM7600
#define TINY_GSM_DEBUG Serial

#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLE2902.h>
#include <TinyGsmClient.h>
#include <RCSwitch.h>
#include <nvs_flash.h>

// -------------------------------------------------------------------
// Basic hardware
// -------------------------------------------------------------------
HardwareSerial SerialAT(2);
TinyGsm modem(SerialAT);
RCSwitch rf;
Preferences prefs;
BLEServer *bleServer = nullptr;
BLECharacteristic *wifiRxCharacteristic = nullptr;
BLECharacteristic *wifiTxCharacteristic = nullptr;

static const int MODEM_RX = 16;
static const int MODEM_TX = 17;
static const int MODEM_BAUD = 115200;

static const int BUZZER_PIN = 4;
static const int STATUS_LED_PIN = 22;
static const int RF_PIN = 35;

// Manual wired door zones. Set unused pins to -1.
static const int DOOR_ZONE_PINS[] = {
  19, 18, 5,
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1
};
static const char *DOOR_ZONE_NAMES[] = {
  "DOOR 1",
  "DOOR 2",
  "DOOR 3",
  "DOOR 4",
  "DOOR 5",
  "DOOR 6",
  "DOOR 7",
  "DOOR 8",
  "DOOR 9",
  "DOOR 10",
  "DOOR 11",
  "DOOR 12",
  "DOOR 13",
  "DOOR 14",
  "DOOR 15",
  "DOOR 16",
  "DOOR 17",
  "DOOR 18",
  "DOOR 19",
  "DOOR 20",
  "DOOR 21",
  "DOOR 22"
};
static const uint8_t DOOR_ZONE_COUNT = sizeof(DOOR_ZONE_PINS) / sizeof(DOOR_ZONE_PINS[0]);

// -------------------------------------------------------------------
// App / server setup
// -------------------------------------------------------------------
static const char *DEFAULT_WIFI_SSID = "";
static const char *DEFAULT_WIFI_PASSWORD = "";
static const char *SYSTEM_STATE_URL = "http://monsow.in/alarm/index.php?action=system_state";
static const char *DEVICE_REGISTER_URL = "http://monsow.in/alarm/index.php?action=device_register";
static const char *PREF_NAMESPACE = "alarmcfg";
static const char *PREF_WIFI_SSID = "wifi_ssid";
static const char *PREF_WIFI_PASS = "wifi_pass";
static const char *BLE_DEVICE_NAME = "ESP32_ALARM_SETUP";
static const char *BLE_SERVICE_UUID = "703DE63C-1C78-703D-E63C-1A42B93437E2";
static const char *BLE_RX_UUID = "703DE63C-1C78-703D-E63C-1A42B93437E3";
static const char *BLE_TX_UUID = "703DE63C-1C78-703D-E63C-1A42B93437E4";
static const bool CLEAR_WIFI_ON_EVERY_BOOT = true;

// Poll interval for app/server arm-disarm state.
static const unsigned long STATE_POLL_MS = 500;
static const unsigned long MODEM_NETWORK_TIMEOUT_MS = 15000;

// -------------------------------------------------------------------
// Manual contact numbers
// Edit these directly in code.
// -------------------------------------------------------------------
static const char *SMS_NUMBERS[] = {
  "+919344962337"
};

static const char *CALL_NUMBERS[] = {
  "+919344962337"
};

static const uint8_t SMS_NUMBER_COUNT = sizeof(SMS_NUMBERS) / sizeof(SMS_NUMBERS[0]);
static const uint8_t CALL_NUMBER_COUNT = sizeof(CALL_NUMBERS) / sizeof(CALL_NUMBERS[0]);

// -------------------------------------------------------------------
// Manual RF codes
// Replace these with your own saved RF values.
// -------------------------------------------------------------------
enum RfType : uint8_t {
  RF_TYPE_NONE = 0,
  RF_TYPE_DOOR = 1,
  RF_TYPE_REMOTE_ARM = 2,
  RF_TYPE_REMOTE_DISARM = 3,
  RF_TYPE_PANIC = 4
};

struct ManualRfItem {
  uint32_t code;
  RfType type;
  const char *name;
};

static const ManualRfItem RF_ITEMS[] = {
  {9341065UL, RF_TYPE_DOOR, "DOOR 1"},
  {9432329UL, RF_TYPE_DOOR, "DOOR 2"},
  {9343897UL, RF_TYPE_DOOR, "DOOR 3"},
  {9343913UL, RF_TYPE_DOOR, "DOOR 4"},
  {9432217UL, RF_TYPE_DOOR, "DOOR 5"},
  {9520185UL, RF_TYPE_DOOR, "DOOR 6"},
  {9260793UL, RF_TYPE_DOOR, "DOOR 7"},
  {9508521UL, RF_TYPE_DOOR, "DOOR 8"},
  {9519369UL, RF_TYPE_DOOR, "DOOR 9"},
  {8983401UL, RF_TYPE_DOOR, "DOOR 10"},
  {9331129UL, RF_TYPE_DOOR, "DOOR 11"},
  {9052441UL, RF_TYPE_DOOR, "DOOR 12"},
  {9343929UL, RF_TYPE_DOOR, "DOOR 13"},
  {8923801UL, RF_TYPE_DOOR, "DOOR 14"},
  {8771257UL, RF_TYPE_DOOR, "DOOR 15"},
  {9521129UL, RF_TYPE_DOOR, "DOOR 16"},
  {9263625UL, RF_TYPE_DOOR, "DOOR 17"},
  {9252505UL, RF_TYPE_DOOR, "DOOR 18"},
  {9332233UL, RF_TYPE_DOOR, "DOOR 19"},
  {9333497UL, RF_TYPE_DOOR, "DOOR 20"},
  {9516585UL, RF_TYPE_DOOR, "DOOR 21"},
  {9262969UL, RF_TYPE_DOOR, "DOOR 22"}
};

static const uint8_t RF_ITEM_COUNT = sizeof(RF_ITEMS) / sizeof(RF_ITEMS[0]);

// -------------------------------------------------------------------
// Runtime state
// -------------------------------------------------------------------
enum SystemMode : uint8_t {
  MODE_DISARMED = 0,
  MODE_ARMED = 1,
  MODE_STAY_ARM = 2,
  MODE_ALARM = 3
};

SystemMode currentMode = MODE_DISARMED;
String lastServerState = "disarmed";
unsigned long lastStatePollAt = 0;
unsigned long lastAlarmActionAt = 0;
unsigned long lastWiFiAttemptAt = 0;
bool alarmOutputsEnabled = false;
int lastDoorZoneState[DOOR_ZONE_COUNT];
bool bleProvisioningActive = false;
bool wifiProvisioned = false;
bool deviceRegistered = false;
String provisionedSsid;
String provisionedPassword;

// -------------------------------------------------------------------
// BLE provisioning
// -------------------------------------------------------------------
class WifiProvisioningCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    std::string raw = characteristic->getValue();
    if (raw.empty()) {
      Serial.println("[BLE] Write received but payload is empty");
      return;
    }

    Serial.printf("[BLE] RX bytes=%u\n", static_cast<unsigned>(raw.size()));
    String payload = String(raw.c_str());
    payload.trim();
    Serial.printf("[BLE] RX raw text: %s\n", payload.c_str());

    String cmd;
    String ssid;
    String password;
    String pairType;
    String pairName;
    String pairZone;
    String pairId;

    int cmdKey = payload.indexOf("\"cmd\"");
    if (cmdKey >= 0) {
      int cmdColon = payload.indexOf(':', cmdKey);
      int cmdQ1 = payload.indexOf('"', cmdColon + 1);
      int cmdQ2 = payload.indexOf('"', cmdQ1 + 1);
      if (cmdColon >= 0 && cmdQ1 >= 0 && cmdQ2 > cmdQ1) {
        cmd = payload.substring(cmdQ1 + 1, cmdQ2);
      }
    }

    if (cmd == "pair_request") {
      int typeKey = payload.indexOf("\"type\"");
      int nameKey = payload.indexOf("\"name\"");
      int zoneKey = payload.indexOf("\"zone\"");
      int pairingIdKey = payload.indexOf("\"pairing_id\"");

      if (typeKey >= 0) {
        int colon = payload.indexOf(':', typeKey);
        int q1 = payload.indexOf('"', colon + 1);
        int q2 = payload.indexOf('"', q1 + 1);
        if (colon >= 0 && q1 >= 0 && q2 > q1) pairType = payload.substring(q1 + 1, q2);
      }
      if (nameKey >= 0) {
        int colon = payload.indexOf(':', nameKey);
        int q1 = payload.indexOf('"', colon + 1);
        int q2 = payload.indexOf('"', q1 + 1);
        if (colon >= 0 && q1 >= 0 && q2 > q1) pairName = payload.substring(q1 + 1, q2);
      }
      if (zoneKey >= 0) {
        int colon = payload.indexOf(':', zoneKey);
        int q1 = payload.indexOf('"', colon + 1);
        int q2 = payload.indexOf('"', q1 + 1);
        if (colon >= 0 && q1 >= 0 && q2 > q1) pairZone = payload.substring(q1 + 1, q2);
      }
      if (pairingIdKey >= 0) {
        int colon = payload.indexOf(':', pairingIdKey);
        int end = payload.indexOf(',', colon + 1);
        if (end < 0) end = payload.indexOf('}', colon + 1);
        if (colon >= 0 && end > colon) pairId = payload.substring(colon + 1, end);
        pairId.trim();
      }

      Serial.println("[BLE] Pair request received");
      Serial.printf("[BLE] Pair type=%s\n", pairType.c_str());
      Serial.printf("[BLE] Pair name=%s\n", pairName.c_str());
      Serial.printf("[BLE] Pair zone=%s\n", pairZone.c_str());
      Serial.printf("[BLE] Pair pairing_id=%s\n", pairId.c_str());

      if (wifiTxCharacteristic) {
        String ack = "{\"type\":\"sensor_ack\",\"status\":\"pairing_started\",\"pairing_id\":" + (pairId.length() ? pairId : "0") + ",\"mac\":\"" + WiFi.macAddress() + "\",\"ble_name\":\"" + String(BLE_DEVICE_NAME) + "\"}";
        wifiTxCharacteristic->setValue(ack.c_str());
        wifiTxCharacteristic->notify();
        Serial.printf("[BLE] TX notify: %s\n", ack.c_str());
      }
      return;
    }

    int ssidKey = payload.indexOf("\"ssid\"");
    int passKey = payload.indexOf("\"password\"");
    if (ssidKey >= 0 && passKey >= 0) {
      Serial.println("[BLE] Payload format detected: JSON");
      int ssidColon = payload.indexOf(':', ssidKey);
      int ssidQ1 = payload.indexOf('"', ssidColon + 1);
      int ssidQ2 = payload.indexOf('"', ssidQ1 + 1);
      int passColon = payload.indexOf(':', passKey);
      int passQ1 = payload.indexOf('"', passColon + 1);
      int passQ2 = payload.indexOf('"', passQ1 + 1);
      if (ssidColon >= 0 && ssidQ1 >= 0 && ssidQ2 > ssidQ1) {
        ssid = payload.substring(ssidQ1 + 1, ssidQ2);
      }
      if (passColon >= 0 && passQ1 >= 0 && passQ2 > passQ1) {
        password = payload.substring(passQ1 + 1, passQ2);
      }
    } else {
      int separator = payload.indexOf('|');
      if (separator > 0) {
        Serial.println("[BLE] Payload format detected: SSID|PASSWORD");
        ssid = payload.substring(0, separator);
        password = payload.substring(separator + 1);
      }
    }

    ssid.trim();
    password.trim();

    Serial.printf("[BLE] Parsed SSID=%s\n", ssid.c_str());
    Serial.printf("[BLE] Parsed password length=%u\n", static_cast<unsigned>(password.length()));

    if (ssid.length() == 0) {
      Serial.println("[BLE] Invalid WiFi payload");
      if (wifiTxCharacteristic) {
        wifiTxCharacteristic->setValue("INVALID_WIFI_PAYLOAD");
        wifiTxCharacteristic->notify();
        Serial.println("[BLE] TX notify: INVALID_WIFI_PAYLOAD");
      }
      return;
    }

    provisionedSsid = ssid;
    provisionedPassword = password;

    prefs.begin(PREF_NAMESPACE, false);
    prefs.putString(PREF_WIFI_SSID, provisionedSsid);
    prefs.putString(PREF_WIFI_PASS, provisionedPassword);
    prefs.end();

    wifiProvisioned = true;
    Serial.printf("[BLE] WiFi saved SSID=%s\n", provisionedSsid.c_str());

    if (wifiTxCharacteristic) {
      wifiTxCharacteristic->setValue("WIFI_SAVED");
      wifiTxCharacteristic->notify();
      Serial.println("[BLE] TX notify: WIFI_SAVED");
    }
  }
};

// -------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------
void beep(uint8_t count, uint16_t onMs = 120, uint16_t offMs = 120) {
  for (uint8_t i = 0; i < count; i++) {
    digitalWrite(BUZZER_PIN, HIGH);
    delay(onMs);
    digitalWrite(BUZZER_PIN, LOW);
    delay(offMs);
  }
}

void setAlarmOutputs(bool on) {
  alarmOutputsEnabled = on;
  digitalWrite(STATUS_LED_PIN, on ? HIGH : LOW);
  digitalWrite(BUZZER_PIN, on ? HIGH : LOW);
}

void loadWifiCredentials() {
  prefs.begin(PREF_NAMESPACE, true);
  provisionedSsid = prefs.getString(PREF_WIFI_SSID, DEFAULT_WIFI_SSID);
  provisionedPassword = prefs.getString(PREF_WIFI_PASS, DEFAULT_WIFI_PASSWORD);
  prefs.end();
  wifiProvisioned = provisionedSsid.length() > 0;
  Serial.printf("[WIFI] Stored SSID present=%s\n", wifiProvisioned ? "YES" : "NO");
}

void clearWifiCredentials() {
  prefs.begin(PREF_NAMESPACE, false);
  prefs.remove(PREF_WIFI_SSID);
  prefs.remove(PREF_WIFI_PASS);
  prefs.end();
  provisionedSsid = "";
  provisionedPassword = "";
  wifiProvisioned = false;
  Serial.println("[WIFI] Stored credentials cleared");
}

void clearAllStoredData() {
  esp_err_t err = nvs_flash_erase();
  if (err == ESP_OK) {
    Serial.println("[BOOT] All stored NVS data erased");
  } else {
    Serial.printf("[BOOT] NVS erase failed: %d\n", static_cast<int>(err));
  }
  err = nvs_flash_init();
  if (err == ESP_OK) {
    Serial.println("[BOOT] NVS reinitialized");
  } else {
    Serial.printf("[BOOT] NVS init failed: %d\n", static_cast<int>(err));
  }
  provisionedSsid = "";
  provisionedPassword = "";
  wifiProvisioned = false;
}

void startBleProvisioning() {
  if (bleProvisioningActive) {
    return;
  }

  Serial.println("[BLE] Starting provisioning mode");
  BLEDevice::init(BLE_DEVICE_NAME);
  bleServer = BLEDevice::createServer();
  BLEService *service = bleServer->createService(BLE_SERVICE_UUID);

  wifiRxCharacteristic = service->createCharacteristic(
    BLE_RX_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );

  wifiTxCharacteristic = service->createCharacteristic(
    BLE_TX_UUID,
    BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ
  );

  wifiRxCharacteristic->setCallbacks(new WifiProvisioningCallbacks());
  wifiTxCharacteristic->setValue("READY_FOR_WIFI");

  service->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(BLE_SERVICE_UUID);
  advertising->start();

  bleProvisioningActive = true;
  Serial.printf("[BLE] Device name=%s\n", BLE_DEVICE_NAME);
}

void stopBleProvisioning() {
  if (!bleProvisioningActive) {
    return;
  }
  BLEDevice::getAdvertising()->stop();
  BLEDevice::deinit(false);
  bleProvisioningActive = false;
  Serial.println("[BLE] Provisioning stopped");
}

String extractJsonString(const String &body, const char *key) {
  String pattern = "\"" + String(key) + "\"";
  int keyPos = body.indexOf(pattern);
  if (keyPos < 0) return "";
  int colon = body.indexOf(':', keyPos);
  int firstQuote = body.indexOf('"', colon + 1);
  int secondQuote = body.indexOf('"', firstQuote + 1);
  if (colon < 0 || firstQuote < 0 || secondQuote < 0) return "";
  return body.substring(firstQuote + 1, secondQuote);
}

String jsonEscape(const String &value) {
  String out;
  for (size_t i = 0; i < value.length(); i++) {
    char c = value[i];
    if (c == '\\' || c == '"') {
      out += '\\';
    }
    out += c;
  }
  return out;
}

String deviceUuid() {
  return WiFi.macAddress();
}

String deviceName() {
  String mac = deviceUuid();
  String suffix = mac;
  suffix.replace(":", "");
  if (suffix.length() > 6) {
    suffix = suffix.substring(suffix.length() - 6);
  }
  return "ESP32 Alarm " + suffix;
}

String readAtResponse(uint32_t timeoutMs = 1000) {
  String out;
  unsigned long start = millis();
  while (millis() - start < timeoutMs) {
    while (SerialAT.available()) {
      out += static_cast<char>(SerialAT.read());
    }
  }
  out.trim();
  return out;
}

String queryAt(const char *command, uint32_t timeoutMs = 1000) {
  while (SerialAT.available()) {
    SerialAT.read();
  }
  SerialAT.println(command);
  return readAtResponse(timeoutMs);
}

void logModemStatus() {
  String creg = queryAt("AT+CREG?", 700);
  String cgreg = queryAt("AT+CGREG?", 700);
  String cops = queryAt("AT+COPS?", 1000);
  int signal = modem.getSignalQuality();
  bool netConnected = modem.isNetworkConnected();

  Serial.printf("[MODEM] isNetworkConnected=%s\n", netConnected ? "YES" : "NO");
  Serial.printf("[MODEM] Signal quality=%d\n", signal);
  Serial.printf("[MODEM] CREG=%s\n", creg.c_str());
  Serial.printf("[MODEM] CGREG=%s\n", cgreg.c_str());
  Serial.printf("[MODEM] COPS=%s\n", cops.c_str());
}

bool gsmLooksUsable() {
  int signal = modem.getSignalQuality();
  bool netConnected = modem.isNetworkConnected();
  String cops = queryAt("AT+COPS?", 1000);
  return netConnected || signal > 0 || cops.indexOf("+COPS:") >= 0;
}

void registerDeviceToServer() {
  if (WiFi.status() != WL_CONNECTED) {
    return;
  }

  HTTPClient http;
  http.begin(DEVICE_REGISTER_URL);
  http.addHeader("Content-Type", "application/json");

  String payload = "{";
  payload += "\"device_uuid\":\"" + jsonEscape(deviceUuid()) + "\",";
  payload += "\"device_name\":\"" + jsonEscape(deviceName()) + "\",";
  payload += "\"device_type\":\"alarm\",";
  payload += "\"connection_type\":\"wifi\",";
  payload += "\"mac_address\":\"" + jsonEscape(WiFi.macAddress()) + "\",";
  payload += "\"ip_address\":\"" + jsonEscape(WiFi.localIP().toString()) + "\"";
  payload += "}";

  Serial.printf("[REG] POST %s\n", DEVICE_REGISTER_URL);
  Serial.printf("[REG] Payload: %s\n", payload.c_str());
  int status = http.POST(payload);
  String body = http.getString();
  Serial.printf("[REG] Status=%d body=%s\n", status, body.c_str());

  if (status == 200) {
    deviceRegistered = true;
    if (wifiTxCharacteristic) {
      wifiTxCharacteristic->setValue("DEVICE_REGISTERED");
      wifiTxCharacteristic->notify();
    }
  }

  http.end();
}

void sendSMS(const char *number, const String &message) {
  if (!number || strlen(number) < 10) return;
  Serial.printf("[SMS] Sending to %s: %s\n", number, message.c_str());
  modem.sendSMS(number, message);
  delay(500);
}

void sendSmsToAll(const String &message) {
  for (uint8_t i = 0; i < SMS_NUMBER_COUNT; i++) {
    sendSMS(SMS_NUMBERS[i], message);
  }
}

void callNumber(const char *number, uint32_t durationMs = 20000) {
  if (!number || strlen(number) < 10) return;
  Serial.printf("[CALL] Calling %s\n", number);
  modem.callNumber(number);
  delay(durationMs);
  modem.callHangup();
  delay(1500);
}

void callAll() {
  for (uint8_t i = 0; i < CALL_NUMBER_COUNT; i++) {
    callNumber(CALL_NUMBERS[i]);
  }
}

void sendAlert(const String &message, bool allowCall) {
  sendSmsToAll(message);
  if (allowCall) {
    callAll();
  }
}

void setMode(SystemMode mode, const char *reason) {
  currentMode = mode;
  switch (mode) {
    case MODE_ARMED:
      setAlarmOutputs(false);
      beep(1);
      Serial.printf("[STATE] ARMED by %s\n", reason);
      break;
    case MODE_DISARMED:
      setAlarmOutputs(false);
      beep(2);
      Serial.printf("[STATE] DISARMED by %s\n", reason);
      break;
    case MODE_STAY_ARM:
      setAlarmOutputs(false);
      beep(3);
      Serial.printf("[STATE] STAY ARM by %s\n", reason);
      break;
    case MODE_ALARM:
      Serial.printf("[STATE] ALARM by %s\n", reason);
      break;
  }
}

void triggerAlarm(const String &reason, bool allowCall) {
  unsigned long now = millis();
  if (now - lastAlarmActionAt < 3000) {
    return;
  }
  lastAlarmActionAt = now;
  currentMode = MODE_ALARM;
  Serial.printf("[ALARM] %s\n", reason.c_str());
  sendAlert("ALERT: " + reason, allowCall);
}

void handleDoorTrigger(const char *zoneName) {
  if (currentMode == MODE_DISARMED) {
    return;
  }
  bool allowCall = (currentMode != MODE_STAY_ARM);
  triggerAlarm(String(zoneName) + " OPEN", allowCall);
}

void handleServerState(const String &state) {
  if (state.length() == 0 || state == lastServerState) {
    return;
  }

  Serial.printf("[SYNC] Server state changed to %s\n", state.c_str());
  lastServerState = state;

  if (state == "armed") {
    setMode(MODE_ARMED, "APP");
  } else if (state == "disarmed") {
    setMode(MODE_DISARMED, "APP");
  } else if (state == "stay_arm") {
    setMode(MODE_STAY_ARM, "APP");
  } else if (state == "alarm") {
    triggerAlarm("MOBILE APP ALARM", true);
  }
}

void pollSystemState() {
  if (WiFi.status() != WL_CONNECTED) {
    return;
  }

  unsigned long now = millis();
  if (now - lastStatePollAt < STATE_POLL_MS) {
    return;
  }
  lastStatePollAt = now;

  HTTPClient http;
  http.begin(SYSTEM_STATE_URL);
  int status = http.GET();
  if (status == 200) {
    String body = http.getString();
    String state = extractJsonString(body, "state");
    if (state.length() > 0) {
      handleServerState(state);
    } else {
      Serial.printf("[SYNC] No state in response: %s\n", body.c_str());
    }
  } else {
    Serial.printf("[SYNC] HTTP GET failed status=%d\n", status);
  }
  http.end();
}

void connectWiFi() {
  if (!wifiProvisioned) {
    Serial.println("[WIFI] No credentials stored");
    return;
  }

  lastWiFiAttemptAt = millis();
  Serial.printf("[WIFI] Connecting to %s\n", provisionedSsid.c_str());
  WiFi.mode(WIFI_STA);
  WiFi.begin(provisionedSsid.c_str(), provisionedPassword.c_str());

  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 20000) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("[WIFI] Connected IP=%s\n", WiFi.localIP().toString().c_str());
    if (wifiTxCharacteristic) {
      wifiTxCharacteristic->setValue("WIFI_CONNECTED");
      wifiTxCharacteristic->notify();
    }
    registerDeviceToServer();
  } else {
    Serial.println("[WIFI] Connection failed");
    if (wifiTxCharacteristic) {
      wifiTxCharacteristic->setValue("WIFI_FAILED");
      wifiTxCharacteristic->notify();
    }
    startBleProvisioning();
  }
}

void initModem() {
  Serial.println("[MODEM] Starting UART");
  SerialAT.begin(MODEM_BAUD, SERIAL_8N1, MODEM_RX, MODEM_TX);
  delay(3000);

  Serial.println("[MODEM] Restarting modem");
  if (modem.restart()) {
    Serial.println("[MODEM] Restart OK");
  } else {
    Serial.println("[MODEM] Restart failed");
  }

  logModemStatus();

  Serial.println("[MODEM] Waiting for network");
  unsigned long start = millis();
  while (!modem.waitForNetwork()) {
    Serial.println("[MODEM] Network retry");
    if (millis() - start >= MODEM_NETWORK_TIMEOUT_MS) {
      Serial.printf("[MODEM] Network timeout after %lu ms\n", MODEM_NETWORK_TIMEOUT_MS);
      logModemStatus();
      if (gsmLooksUsable()) {
        Serial.println("[MODEM] GSM looks usable despite waitForNetwork timeout");
      } else {
        Serial.println("[MODEM] GSM not usable yet");
      }
      Serial.println("[MODEM] Continuing boot without blocking WiFi/app control");
      return;
    }
    delay(1000);
  }
  Serial.println("[MODEM] Network connected");
  logModemStatus();
}

void handleRfCode(uint32_t code) {
  for (uint8_t i = 0; i < RF_ITEM_COUNT; i++) {
    if (RF_ITEMS[i].code == 0 || RF_ITEMS[i].code != code) {
      continue;
    }

    Serial.printf("[RF] Matched %s\n", RF_ITEMS[i].name);
    switch (RF_ITEMS[i].type) {
      case RF_TYPE_DOOR:
        handleDoorTrigger(RF_ITEMS[i].name);
        return;
      case RF_TYPE_REMOTE_ARM:
        setMode(MODE_ARMED, "RF");
        return;
      case RF_TYPE_REMOTE_DISARM:
        setMode(MODE_DISARMED, "RF");
        return;
      case RF_TYPE_PANIC:
        triggerAlarm("RF PANIC BUTTON", true);
        return;
      default:
        return;
    }
  }
}

void pollRf() {
  if (!rf.available()) {
    return;
  }

  uint32_t code = rf.getReceivedValue();
  rf.resetAvailable();
  if (code == 0) {
    return;
  }

  Serial.printf("[RF] code=%lu\n", static_cast<unsigned long>(code));
  handleRfCode(code);
}

void pollDoorZones() {
  for (uint8_t i = 0; i < DOOR_ZONE_COUNT; i++) {
    if (DOOR_ZONE_PINS[i] < 0) continue;

    int state = digitalRead(DOOR_ZONE_PINS[i]);
    if (currentMode != MODE_DISARMED && lastDoorZoneState[i] == HIGH && state == LOW) {
      handleDoorTrigger(DOOR_ZONE_NAMES[i]);
    }
    lastDoorZoneState[i] = state;
  }
}

void updateAlarmBuzzer() {
  if (currentMode == MODE_ALARM) {
    bool on = ((millis() / 250) % 2) == 0;
    digitalWrite(BUZZER_PIN, on ? HIGH : LOW);
    digitalWrite(STATUS_LED_PIN, on ? HIGH : LOW);
  }
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("================================");
  Serial.println("[BOOT] APP ARM/DISARM ONLY SKETCH");
  Serial.println("================================");

  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(STATUS_LED_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);
  digitalWrite(STATUS_LED_PIN, LOW);

  for (uint8_t i = 0; i < DOOR_ZONE_COUNT; i++) {
    if (DOOR_ZONE_PINS[i] >= 0) {
      pinMode(DOOR_ZONE_PINS[i], INPUT_PULLUP);
      lastDoorZoneState[i] = digitalRead(DOOR_ZONE_PINS[i]);
      Serial.printf("[ZONE] %s on GPIO %d initial=%d\n", DOOR_ZONE_NAMES[i], DOOR_ZONE_PINS[i], lastDoorZoneState[i]);
    }
  }

  rf.enableReceive(RF_PIN);
  Serial.printf("[RF] Receiver enabled on GPIO %d\n", RF_PIN);

  if (CLEAR_WIFI_ON_EVERY_BOOT) {
    clearAllStoredData();
  } else {
    loadWifiCredentials();
  }
  if (!wifiProvisioned) {
    startBleProvisioning();
  }
  connectWiFi();
  initModem();
  setMode(MODE_DISARMED, "BOOT");
}

void loop() {
  if (WiFi.status() != WL_CONNECTED && wifiProvisioned && millis() - lastWiFiAttemptAt > 10000) {
    connectWiFi();
  }
  pollSystemState();
  pollRf();
  pollDoorZones();
  updateAlarmBuzzer();
  delay(50);
}
