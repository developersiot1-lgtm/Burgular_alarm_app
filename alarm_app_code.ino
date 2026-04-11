#define TINY_GSM_MODEM_A7672X
#define TINY_GSM_DEBUG Serial

#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <Wire.h>
#include <BLEDevice.h>
#include <BLE2902.h>
#include <TinyGsmClient.h>
#include <RCSwitch.h>
#include <nvs_flash.h>
#include <esp_system.h>
#include <Adafruit_MCP23X17.h>

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

Adafruit_MCP23X17 mcp;
bool mcpAvailable = false;

static const int MODEM_RX = 16;
static const int MODEM_TX = 17;
static const int MODEM_BAUD = 115200;

static const int BUZZER_PIN = 4;
static const int STATUS_LED_PIN = 22;
static const int RF_PIN = 35;

// MCP23017 (I2C) wiring for wired door sensors
static const int I2C_SDA_PIN = 27;
static const int I2C_SCL_PIN = 32;
static const uint8_t MCP23017_ADDR = 0x20;  // A0/A1/A2 tied to GND -> 0x20

// Manual wired door zones. Set unused pins to -1.
static const int DOOR_ZONE_PINS[] = {
  // Using MCP23017 for wired zones, so ESP32 GPIO zones are disabled by default.
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1
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
static const char *SETTINGS_URL_BASE = "http://monsow.in/alarm/index.php?action=sync_settings_to_device&device_uuid=";
static const char *PREF_NAMESPACE = "alarmcfg";
static const char *PREF_WIFI_SSID = "wifi_ssid";
static const char *PREF_WIFI_PASS = "wifi_pass";
static const char *PREF_SETTINGS_CACHE = "set_cache";
static const char *BLE_DEVICE_NAME = "MONSOW_052604";
static const char *BLE_SERVICE_UUID = "703DE63C-1C78-703D-E63C-1A42B93437E2";
static const char *BLE_RX_UUID = "703DE63C-1C78-703D-E63C-1A42B93437E3";
static const char *BLE_TX_UUID = "703DE63C-1C78-703D-E63C-1A42B93437E4";
static const bool CLEAR_WIFI_ON_EVERY_BOOT = true;
static const bool ERASE_ALL_NVS_ON_RESET_BUTTON = true;

// RTC memory survives RESET (EN) but is cleared on a real power cut.
// This lets us differentiate "button reset" vs "power off/on".
RTC_DATA_ATTR uint32_t rtcWarmResetMarker = 0;
static const uint32_t RTC_WARM_RESET_MAGIC = 0xB16B00B5UL;

// Poll interval for app/server arm-disarm state.
static const unsigned long STATE_POLL_DISARMED_MS = 500;
static const unsigned long STATE_POLL_ARMED_MS = 2500;
static const unsigned long MODEM_NETWORK_TIMEOUT_MS = 15000;
static const unsigned long RF_PAIR_WINDOW_MS = 30000;
static const unsigned long WIFI_CONNECT_TIMEOUT_MS = 8000;
static const unsigned long WIFI_RETRY_ONLINE_MS = 2000;
static const unsigned long WIFI_RETRY_OFFLINE_MS = 30000;
static const bool START_BLE_PROVISIONING_ON_WIFI_FAIL = false;
static const unsigned long HTTP_TIMEOUT_DISARMED_MS = 8000;
static const unsigned long HTTP_TIMEOUT_ARMED_MS = 1500;
static const uint8_t SERVER_OFFLINE_AFTER_FAILS = 3;
static const unsigned long SERVER_DECLARE_OFFLINE_AFTER_MS = 20000;
static const unsigned long SERVER_OFFLINE_RETRY_MS = 30000;
static const bool AUTO_ARM_ON_SERVER_OFFLINE = true;
static const unsigned long AUTO_ARM_DELAY_MS = 15000;

// With INPUT_PULLUP and a reed switch to GND:
// door CLOSED (magnet near)  -> pin LOW
// door OPEN   (magnet away)  -> pin HIGH
static const int DOOR_OPEN_STATE = HIGH;
static const int DOOR_CLOSED_STATE = LOW;

static const uint8_t MCP_WIRED_ZONE_COUNT = 10;
// Zone mapping:
// 1-8  -> GPB0..GPB7
// 9    -> GPA0
// 10   -> GPA1
static const uint8_t MCP_WIRED_ZONE_PINS[MCP_WIRED_ZONE_COUNT] = {
  8, 9, 10, 11, 12, 13, 14, 15,  // GPB0..GPB7
  0, 1                            // GPA0..GPA1
};

// -------------------------------------------------------------------
// Contact numbers synced from server
// -------------------------------------------------------------------
static const uint8_t MAX_CONTACT_NUMBERS = 8;
static const uint8_t CONTACT_NUMBER_LEN = 24;
char smsNumbers[MAX_CONTACT_NUMBERS][CONTACT_NUMBER_LEN];
char callNumbers[MAX_CONTACT_NUMBERS][CONTACT_NUMBER_LEN];
uint8_t smsNumberCount = 0;
uint8_t callNumberCount = 0;
unsigned long lastSettingsFetchAt = 0;
static const unsigned long SETTINGS_FETCH_MS = 1000;
String cachedSettingsJson;

// -------------------------------------------------------------------
// Manual RF codes
// Replace these with your own saved RF values.
// -------------------------------------------------------------------
enum RfType : uint8_t {
  RF_TYPE_NONE = 0,
  RF_TYPE_DOOR = 1,
  RF_TYPE_REMOTE_ARM = 2,
  RF_TYPE_REMOTE_DISARM = 3,
  RF_TYPE_PANIC = 4,
  RF_TYPE_MOTION = 5
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
static const uint8_t MAX_LEARNED_RF_ITEMS = 16;
static const char *PREF_LEARNED_RF_COUNT = "lrf_cnt";
static const char *PREF_LEARNED_RF_DATA = "lrf_data";

struct LearnedRfItem {
  uint32_t code;
  uint8_t type;
  char name[24];
  char zone[24];
};

LearnedRfItem learnedRfItems[MAX_LEARNED_RF_ITEMS];
uint8_t learnedRfItemCount = 0;

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
bool offlineMode = false;
unsigned long offlineModeSinceAt = 0;
bool serverOnline = true;
uint8_t serverFailCount = 0;
unsigned long serverFailWindowStartedAt = 0;
unsigned long lastServerOkAt = 0;
unsigned long nextServerRetryAt = 0;
bool autoArmScheduled = false;
bool autoArmDone = false;
unsigned long autoArmDueAt = 0;
bool alarmOutputsEnabled = false;
int lastDoorZoneState[DOOR_ZONE_COUNT];
uint16_t settingExitDelaySeconds = 0;
uint16_t settingEntryDelaySeconds = 0;
uint16_t settingAlarmDurationMinutes = 5;
bool settingAlarmSound = true;
unsigned long exitDelayEndsAt = 0;
bool exitDelayActive = false;
unsigned long entryDelayEndsAt = 0;
bool entryDelayActive = false;
String pendingAlarmReason;
bool pendingAlarmAllowCall = false;
SystemMode modeBeforeAlarm = MODE_DISARMED;
unsigned long alarmEndsAt = 0;
unsigned long lastCountdownTickAt = 0;
bool settingAlarmCall = true;
bool settingAlarmSms = true;
bool settingSensorLowBatteryAlarm = true;
bool settingAlarmNotification = true;
bool settingCountdownWithTickTone = true;
bool settingArmDisarmNotification = true;
bool settingTamperAlarm = true;
bool settingSensorLowBatteryNotification = true;
uint8_t settingUnansweredPhoneRedialTimes = 0;
String settingHubLanguage;
String settingVirtualPassword;
void clearContactNumbers() {
  memset(smsNumbers, 0, sizeof(smsNumbers));
  memset(callNumbers, 0, sizeof(callNumbers));
  smsNumberCount = 0;
  callNumberCount = 0;
}

void setOfflineMode(bool on, const char *reason) {
  if (offlineMode == on) return;
  offlineMode = on;
  offlineModeSinceAt = on ? millis() : 0;
  Serial.printf("[OFFLINE] %s (%s)\n", on ? "ENABLED" : "DISABLED", reason ? reason : "");
  if (on) {
    scheduleAutoArmIfNeeded(reason);
  } else {
    cancelAutoArmSchedule();
  }
  if (wifiTxCharacteristic) {
    wifiTxCharacteristic->setValue(on ? "OFFLINE_MODE" : "ONLINE_MODE");
    wifiTxCharacteristic->notify();
  }
}

void cancelAutoArmSchedule() {
  autoArmScheduled = false;
  autoArmDueAt = 0;
}

void scheduleAutoArmIfNeeded(const char *reason) {
  if (!AUTO_ARM_ON_SERVER_OFFLINE) return;
  if (autoArmDone || autoArmScheduled) return;
  if (currentMode != MODE_DISARMED) return;
  autoArmScheduled = true;
  autoArmDueAt = millis() + AUTO_ARM_DELAY_MS;
  Serial.printf("[OFFLINE] Auto-arm scheduled in %lu ms (%s)\n",
                static_cast<unsigned long>(AUTO_ARM_DELAY_MS),
                reason ? reason : "");
}

void serviceAutoArmSchedule() {
  if (!autoArmScheduled || autoArmDueAt == 0) return;
  if (millis() < autoArmDueAt) return;

  // Only auto-arm if we're still offline from server or wifi.
  if (currentMode == MODE_DISARMED && (offlineMode || !serverOnline)) {
    Serial.println("[OFFLINE] Auto-arming to local sensor/alarm mode");
    setMode(MODE_ARMED, "OFFLINE");
    autoArmDone = true;
  }
  cancelAutoArmSchedule();
}

bool shouldSendArmDisarmSms(const char *reason) {
  if (!settingArmDisarmNotification) return false;
  if (!reason) return true;
  // Avoid spamming SMS on boot or automatic offline fallback.
  if (strcmp(reason, "BOOT") == 0) return false;
  if (strcmp(reason, "OFFLINE") == 0) return false;
  return true;
}

bool allowServerRequests() {
  if (WiFi.status() != WL_CONNECTED) {
    return false;
  }
  if (!serverOnline && nextServerRetryAt > 0 && millis() < nextServerRetryAt) {
    return false;
  }
  return true;
}

void noteServerOk() {
  lastServerOkAt = millis();
  serverFailCount = 0;
  serverFailWindowStartedAt = 0;
  if (!serverOnline) {
    serverOnline = true;
    nextServerRetryAt = 0;
    Serial.println("[SERVER] ONLINE");
    cancelAutoArmSchedule();
    autoArmDone = false;
    if (wifiTxCharacteristic) {
      wifiTxCharacteristic->setValue("SERVER_ONLINE");
      wifiTxCharacteristic->notify();
    }
  }
}

void noteServerFail(const char *tag, int status) {
  (void)tag;
  (void)status;
  if (serverFailCount == 0) {
    serverFailWindowStartedAt = millis();
  }
  serverFailCount = (serverFailCount < 250) ? (serverFailCount + 1) : serverFailCount;

  // Only declare server offline if failures persist for some time, to avoid flapping on transient timeouts.
  if (serverOnline &&
      serverFailCount >= SERVER_OFFLINE_AFTER_FAILS &&
      serverFailWindowStartedAt > 0 &&
      (millis() - serverFailWindowStartedAt) >= SERVER_DECLARE_OFFLINE_AFTER_MS) {
    serverOnline = false;
    nextServerRetryAt = millis() + SERVER_OFFLINE_RETRY_MS;
    Serial.printf("[SERVER] OFFLINE (failures=%u)\n", serverFailCount);
    scheduleAutoArmIfNeeded("server_offline");
    if (wifiTxCharacteristic) {
      wifiTxCharacteristic->setValue("SERVER_OFFLINE");
      wifiTxCharacteristic->notify();
    }
  } else if (!serverOnline) {
    nextServerRetryAt = millis() + SERVER_OFFLINE_RETRY_MS;
  }
}

bool isValidStoredContactNumber(const char *value) {
  if (!value) return false;
  size_t len = strlen(value);
  if (len == 0) return false;

  int digits = 0;
  for (size_t i = 0; i < len; i++) {
    char c = value[i];
    if (c >= '0' && c <= '9') {
      digits++;
      continue;
    }
    if (c == '+' && i == 0) {
      continue;
    }
    return false;
  }
  return digits >= 10;
}

void sanitizeContactNumbers() {
  uint8_t oldSms = smsNumberCount;
  uint8_t oldCall = callNumberCount;

  // Compact SMS numbers.
  uint8_t writeIndex = 0;
  for (uint8_t i = 0; i < smsNumberCount; i++) {
    if (!isValidStoredContactNumber(smsNumbers[i])) {
      continue;
    }
    if (writeIndex != i) {
      snprintf(smsNumbers[writeIndex], CONTACT_NUMBER_LEN, "%s", smsNumbers[i]);
    }
    writeIndex++;
  }
  for (uint8_t i = writeIndex; i < smsNumberCount; i++) {
    smsNumbers[i][0] = '\0';
  }
  smsNumberCount = writeIndex;

  // Compact CALL numbers.
  writeIndex = 0;
  for (uint8_t i = 0; i < callNumberCount; i++) {
    if (!isValidStoredContactNumber(callNumbers[i])) {
      continue;
    }
    if (writeIndex != i) {
      snprintf(callNumbers[writeIndex], CONTACT_NUMBER_LEN, "%s", callNumbers[i]);
    }
    writeIndex++;
  }
  for (uint8_t i = writeIndex; i < callNumberCount; i++) {
    callNumbers[i][0] = '\0';
  }
  callNumberCount = writeIndex;

  if (oldSms != smsNumberCount || oldCall != callNumberCount) {
    Serial.printf("[CONTACTS] Sanitized cached contacts: SMS %u->%u CALL %u->%u\n", oldSms, smsNumberCount, oldCall, callNumberCount);
  }
}

bool copyContactNumber(char dest[CONTACT_NUMBER_LEN], const String &value) {
  String input = value;
  input.trim();
  if (input.length() == 0) {
    return false;
  }

  // Normalize: keep leading '+' (optional) and digits only. Reject letters.
  String normalized;
  normalized.reserve(input.length());
  int digitCount = 0;

  for (size_t i = 0; i < input.length(); i++) {
    char c = input[i];
    if (c >= '0' && c <= '9') {
      normalized += c;
      digitCount++;
      continue;
    }
    if (c == '+' && normalized.length() == 0) {
      normalized += c;
      continue;
    }
    // Ignore common separators.
    if (c == ' ' || c == '-' || c == '(' || c == ')' || c == '\t' || c == '\r' || c == '\n') {
      continue;
    }
    // Any other character (letters, underscores, etc.) makes it invalid.
    return false;
  }

  // Require at least 10 digits to avoid storing keys like "alarm_sound".
  if (digitCount < 10) {
    return false;
  }

  snprintf(dest, CONTACT_NUMBER_LEN, "%s", normalized.c_str());
  return true;
}

uint8_t parseJsonStringArray(const String &body, const char *key, char out[][CONTACT_NUMBER_LEN], uint8_t maxCount) {
  String pattern = "\"" + String(key) + "\"";
  int keyPos = body.indexOf(pattern);
  if (keyPos < 0) return 0;
  int arrayStart = body.indexOf('[', keyPos);
  int arrayEnd = body.indexOf(']', arrayStart + 1);
  if (arrayStart < 0 || arrayEnd < 0 || arrayEnd <= arrayStart) return 0;

  uint8_t count = 0;
  int cursor = arrayStart + 1;
  while (cursor < arrayEnd && count < maxCount) {
    int q1 = body.indexOf('"', cursor);
    if (q1 < 0 || q1 >= arrayEnd) break;
    int q2 = body.indexOf('"', q1 + 1);
    if (q2 < 0 || q2 > arrayEnd) break;
    String value = body.substring(q1 + 1, q2);
    if (copyContactNumber(out[count], value)) {
      count++;
    }
    cursor = q2 + 1;
  }
  return count;
}

uint8_t splitContactNumbersCsv(const String &csv, char out[][CONTACT_NUMBER_LEN], uint8_t maxCount) {
  uint8_t count = 0;
  int start = 0;
  while (start < csv.length() && count < maxCount) {
    int comma = csv.indexOf(',', start);
    String part = (comma < 0) ? csv.substring(start) : csv.substring(start, comma);
    part.trim();
    if (part.length() > 0) {
      copyContactNumber(out[count], part);
      if (out[count][0] != '\0') {
        count++;
      }
    }
    if (comma < 0) {
      break;
    }
    start = comma + 1;
  }
  return count;
}

uint8_t parseJsonContactNumbersFlexible(const String &body, const char *key, char out[][CONTACT_NUMBER_LEN], uint8_t maxCount) {
  uint8_t count = parseJsonStringArray(body, key, out, maxCount);
  if (count > 0) {
    return count;
  }

  // Also accept: "key": "+91..., +91..."
  String raw = extractJsonStringValue(body, key);
  if (raw.length() == 0) {
    return 0;
  }
  String decoded = unescapeJsonString(raw);
  decoded.trim();
  if (decoded.length() == 0) {
    return 0;
  }
  return splitContactNumbersCsv(decoded, out, maxCount);
}

String unescapeJsonString(const String &value) {
  String out;
  out.reserve(value.length());
  bool escape = false;
  for (size_t i = 0; i < value.length(); i++) {
    char c = value[i];
    if (escape) {
      switch (c) {
        case 'n': out += '\n'; break;
        case 'r': out += '\r'; break;
        case 't': out += '\t'; break;
        case '\\': out += '\\'; break;
        case '"': out += '"'; break;
        default: out += c; break;
      }
      escape = false;
    } else if (c == '\\') {
      escape = true;
    } else {
      out += c;
    }
  }
  return out;
}

String extractJsonObjectByKey(const String &body, const char *key) {
  String pattern = "\"" + String(key) + "\"";
  int keyPos = body.indexOf(pattern);
  if (keyPos < 0) return "";
  int start = body.indexOf('{', keyPos);
  if (start < 0) return "";
  int depth = 0;
  bool inString = false;
  bool escape = false;
  for (int i = start; i < body.length(); i++) {
    char c = body[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (c == '\\') {
      escape = true;
      continue;
    }
    if (c == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) {
        return body.substring(start, i + 1);
      }
    }
  }
  return "";
}

String extractJsonStringValue(const String &body, const char *key) {
  String pattern = "\"" + String(key) + "\"";
  int keyPos = body.indexOf(pattern);
  if (keyPos < 0) return "";
  int colon = body.indexOf(':', keyPos);
  int q1 = body.indexOf('"', colon + 1);
  int q2 = q1;
  bool escape = false;
  while (q1 >= 0 && ++q2 < body.length()) {
    char c = body[q2];
    if (escape) {
      escape = false;
      continue;
    }
    if (c == '\\') {
      escape = true;
      continue;
    }
    if (c == '"') {
      return body.substring(q1 + 1, q2);
    }
  }
  return "";
}

long extractJsonIntValue(const String &body, const char *key, long fallback) {
  String pattern = "\"" + String(key) + "\"";
  int keyPos = body.indexOf(pattern);
  if (keyPos < 0) return fallback;
  int colon = body.indexOf(':', keyPos);
  if (colon < 0) return fallback;
  int i = colon + 1;
  while (i < body.length() && body[i] == ' ') i++;
  String digits;
  if (i < body.length() && (body[i] == '-' || isDigit(body[i]))) {
    digits += body[i++];
  }
  while (i < body.length() && isDigit(body[i])) {
    digits += body[i++];
  }
  return digits.length() ? digits.toInt() : fallback;
}

bool extractJsonBoolValue(const String &body, const char *key, bool fallback) {
  String pattern = "\"" + String(key) + "\"";
  int keyPos = body.indexOf(pattern);
  if (keyPos < 0) return fallback;
  int colon = body.indexOf(':', keyPos);
  if (colon < 0) return fallback;
  String tail = body.substring(colon + 1);
  tail.trim();
  if (tail.startsWith("true")) return true;
  if (tail.startsWith("false")) return false;
  return fallback;
}

String resolveSettingsPayload(const String &body) {
  // We only accept settings from the server response field `settings_json`.
  // (Your server may source it from `settings_sync_log` or `device_registry`.)
  // Server can return it as:
  // 1) settings_json: { ... } (object)
  // 2) settings_json: "{\"exit_delay\":70,...}" (escaped string)
  String settingsObject = extractJsonObjectByKey(body, "settings_json");
  if (settingsObject.length() > 0) {
    Serial.println("[SETTINGS] Using settings_json (object)");
    return settingsObject;
  }

  String settingsJsonString = extractJsonStringValue(body, "settings_json");
  if (settingsJsonString.length() > 0) {
    String decoded = unescapeJsonString(settingsJsonString);
    decoded.trim();
    if (decoded.startsWith("{")) {
      Serial.println("[SETTINGS] Using settings_json (string)");
      return decoded;
    }
  }

  Serial.println("[SETTINGS] ERROR: settings_json missing; ignoring server response");
  return "";
}
void logSyncedSettings() {
  Serial.printf("[SETTINGS] entry_delay=%u exit_delay=%u alarm_duration=%u\n",
                settingEntryDelaySeconds,
                settingExitDelaySeconds,
                settingAlarmDurationMinutes);
  Serial.printf("[SETTINGS] alarm_sound=%s alarm_call=%s alarm_sms=%s tamper=%s\n",
                settingAlarmSound ? "true" : "false",
                settingAlarmCall ? "true" : "false",
                settingAlarmSms ? "true" : "false",
                settingTamperAlarm ? "true" : "false");
}

void applySettingsPayload(const String &settingsBody) {
  settingExitDelaySeconds = static_cast<uint16_t>(extractJsonIntValue(settingsBody, "exit_delay", settingExitDelaySeconds));
  settingEntryDelaySeconds = static_cast<uint16_t>(extractJsonIntValue(settingsBody, "entry_delay", settingEntryDelaySeconds));
  settingAlarmDurationMinutes = static_cast<uint16_t>(extractJsonIntValue(settingsBody, "alarm_duration", settingAlarmDurationMinutes));
  settingAlarmSound = extractJsonBoolValue(settingsBody, "alarm_sound", settingAlarmSound);
  settingAlarmCall = extractJsonBoolValue(settingsBody, "alarm_call", settingAlarmCall);
  settingAlarmSms = extractJsonBoolValue(settingsBody, "alarm_sms", settingAlarmSms);
  settingSensorLowBatteryAlarm = extractJsonBoolValue(settingsBody, "sensor_low_battery_alarm", settingSensorLowBatteryAlarm);
  settingAlarmNotification = extractJsonBoolValue(settingsBody, "alarm_notification", settingAlarmNotification);
  settingCountdownWithTickTone = extractJsonBoolValue(settingsBody, "countdown_with_tick_tone", settingCountdownWithTickTone);
  settingArmDisarmNotification = extractJsonBoolValue(settingsBody, "arm_disarm_notification", settingArmDisarmNotification);
  settingTamperAlarm = extractJsonBoolValue(settingsBody, "tamper_alarm", settingTamperAlarm);
  settingSensorLowBatteryNotification = extractJsonBoolValue(settingsBody, "sensor_low_battery_notification", settingSensorLowBatteryNotification);
  settingUnansweredPhoneRedialTimes = static_cast<uint8_t>(extractJsonIntValue(settingsBody, "unanswered_phone_redial_times", settingUnansweredPhoneRedialTimes));
  String lang = extractJsonStringValue(settingsBody, "hub_language");
  String vpass = extractJsonStringValue(settingsBody, "virtual_password");
  if (lang.length()) settingHubLanguage = lang;
  if (vpass.length()) settingVirtualPassword = vpass;
  logSyncedSettings();
}

void applyServerSettings(const String &body) {
  applySettingsPayload(resolveSettingsPayload(body));
}

void logContactNumbers() {
  Serial.printf("[CONTACTS] SMS=%u CALL=%u\n", smsNumberCount, callNumberCount);
  for (uint8_t i = 0; i < smsNumberCount; i++) {
    Serial.printf("[CONTACTS] SMS[%u]=%s\n", i, smsNumbers[i]);
  }
  for (uint8_t i = 0; i < callNumberCount; i++) {
    Serial.printf("[CONTACTS] CALL[%u]=%s\n", i, callNumbers[i]);
  }
}

void applyContactNumbersFromSettingsPayload(const String &settingsBody) {
  char newSms[MAX_CONTACT_NUMBERS][CONTACT_NUMBER_LEN] = {{0}};
  char newCall[MAX_CONTACT_NUMBERS][CONTACT_NUMBER_LEN] = {{0}};
  uint8_t newSmsCount = parseJsonContactNumbersFlexible(settingsBody, "alarm_sms_numbers", newSms, MAX_CONTACT_NUMBERS);
  uint8_t newCallCount = parseJsonContactNumbersFlexible(settingsBody, "alarm_call_numbers", newCall, MAX_CONTACT_NUMBERS);

  if (newSmsCount == 0 && newCallCount == 0) {
    uint8_t sharedCount = parseJsonContactNumbersFlexible(settingsBody, "contact_numbers", newSms, MAX_CONTACT_NUMBERS);
    for (uint8_t i = 0; i < sharedCount; i++) {
      snprintf(newCall[i], CONTACT_NUMBER_LEN, "%s", newSms[i]);
    }
    newSmsCount = sharedCount;
    newCallCount = sharedCount;
  }

  if (newSmsCount == 0 && newCallCount == 0) {
    // If the server didn't provide any numbers (or they are empty), keep the
    // current cached numbers instead of clearing them.
    Serial.println("[CONTACTS] No numbers in settings_json; keeping existing cached numbers");
    sanitizeContactNumbers();
    logContactNumbers();
    return;
  }

  clearContactNumbers();
  for (uint8_t i = 0; i < newSmsCount; i++) {
    snprintf(smsNumbers[i], CONTACT_NUMBER_LEN, "%s", newSms[i]);
  }
  for (uint8_t i = 0; i < newCallCount; i++) {
    snprintf(callNumbers[i], CONTACT_NUMBER_LEN, "%s", newCall[i]);
  }
  smsNumberCount = newSmsCount;
  callNumberCount = newCallCount;
  sanitizeContactNumbers();
  logContactNumbers();
}

void saveSettingsCacheIfChanged(const String &settingsBody) {
  String normalized = settingsBody;
  normalized.trim();
  if (normalized.length() == 0) {
    return;
  }
  if (normalized == cachedSettingsJson) {
    Serial.println("[SETTINGS] No settings change, EEPROM cache not updated");
    return;
  }

  prefs.begin(PREF_NAMESPACE, false);
  prefs.putString(PREF_SETTINGS_CACHE, normalized);
  prefs.end();
  cachedSettingsJson = normalized;
  Serial.println("[SETTINGS] Settings cache updated in EEPROM");
}

void loadCachedSettingsFromPreferences() {
  prefs.begin(PREF_NAMESPACE, true);
  cachedSettingsJson = prefs.getString(PREF_SETTINGS_CACHE, "");
  prefs.end();
  cachedSettingsJson.trim();

  if (cachedSettingsJson.length() == 0) {
    Serial.println("[SETTINGS] No cached settings found in EEPROM");
    return;
  }

  Serial.println("[SETTINGS] Loaded cached settings from EEPROM");
  applySettingsPayload(cachedSettingsJson);
  applyContactNumbersFromSettingsPayload(cachedSettingsJson);
  sanitizeContactNumbers();
}

void fetchSettingsFromServer() {
  if (!allowServerRequests()) {
    return;
  }

  HTTPClient http;
  http.setTimeout((currentMode == MODE_DISARMED) ? HTTP_TIMEOUT_DISARMED_MS : HTTP_TIMEOUT_ARMED_MS);
  String url = String(SETTINGS_URL_BASE) + deviceUuid() + "&device_name=" + deviceName();
  Serial.printf("[SETTINGS] GET %s\n", url.c_str());
  http.begin(url);
  int status = http.GET();
  String body = http.getString();
  Serial.printf("[SETTINGS] Status=%d body=%s\n", status, body.c_str());

  http.end();

  if (status != 200) {
    noteServerFail("settings", status);
    return;
  }
  noteServerOk();

  String settingsBody = resolveSettingsPayload(body);
  if (settingsBody.length() == 0) {
    return;
  }
  Serial.println("========== SETTINGS BODY ==========");
  Serial.println(settingsBody);
  Serial.println("===================================");
  settingsBody.trim();
  applySettingsPayload(settingsBody);
  applyContactNumbersFromSettingsPayload(settingsBody);
  saveSettingsCacheIfChanged(settingsBody);
  lastSettingsFetchAt = millis();
}

void sendAlarmEvent(String eventType, String zone, String message) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[EVENT] WiFi not connected");
    return;
  }

  HTTPClient http;
  http.setTimeout((currentMode == MODE_DISARMED) ? HTTP_TIMEOUT_DISARMED_MS : HTTP_TIMEOUT_ARMED_MS);
  String url = "http://monsow.in/alarm/index.php?action=alarm_event";

  http.begin(url);
  http.addHeader("Content-Type", "application/json");

  String payload = "{";
  payload += "\"device_uuid\":\"" + deviceUuid() + "\",";
  payload += "\"event_type\":\"" + eventType + "\",";
  payload += "\"zone\":\"" + zone + "\",";
  payload += "\"message\":\"" + message + "\"";
  payload += "}";

  int response = http.POST(payload);

  Serial.println("[EVENT] Sent: " + payload);
  Serial.println("[EVENT] Response: " + String(response));

  http.end();
}
bool bleProvisioningActive = false;
bool bleClientConnected = false;
bool wifiProvisioned = false;
bool deviceRegistered = false;
String provisionedSsid;
String provisionedPassword;
String bleJsonBuffer;
unsigned long bleJsonBufferStartedAt = 0;
bool rfPairingActive = false;
String rfPairType;
String rfPairName;
String rfPairZone;
String rfPairRemoteMode;
String rfPairingId;
unsigned long rfPairingStartedAt = 0;

bool isCompleteBleJson(const String &text) {
  int depth = 0;
  bool inString = false;
  bool escapeNext = false;
  bool sawOpen = false;

  for (size_t i = 0; i < text.length(); i++) {
    char c = text[i];

    if (escapeNext) {
      escapeNext = false;
      continue;
    }

    if (inString && c == '\\') {
      escapeNext = true;
      continue;
    }

    if (c == '"') {
      inString = !inString;
      continue;
    }

    if (inString) {
      continue;
    }

    if (c == '{') {
      depth++;
      sawOpen = true;
    } else if (c == '}') {
      depth--;
      if (depth < 0) {
        return false;
      }
    }
  }

  return sawOpen && !inString && depth == 0;
}

String collectBlePayload(const std::string &raw) {
  String chunk;
  chunk.reserve(raw.size());
  for (size_t i = 0; i < raw.size(); i++) {
    chunk += raw[i];
  }
  chunk.trim();

  if (chunk.length() == 0) {
    return "";
  }

  Serial.printf("[BLE] RX chunk: %s\n", chunk.c_str());

  const bool looksLikeJsonChunk =
      bleJsonBuffer.length() > 0 ||
      chunk.startsWith("{") ||
      chunk.indexOf("\"cmd\"") >= 0 ||
      chunk.indexOf("\"ssid\"") >= 0 ||
      chunk.indexOf("\"password\"") >= 0 ||
      chunk.indexOf("\"type\"") >= 0 ||
      chunk.indexOf("\"pairing_id\"") >= 0;

  if (!looksLikeJsonChunk) {
    return chunk;
  }

  if (bleJsonBuffer.length() == 0 || millis() - bleJsonBufferStartedAt > 5000) {
    if (bleJsonBuffer.length() > 0) {
      Serial.println("[BLE] Clearing stale BLE JSON buffer");
    }
    bleJsonBuffer = "";
    bleJsonBufferStartedAt = millis();
  }

  bleJsonBuffer += chunk;
  Serial.printf("[BLE] JSON buffer size=%u\n", static_cast<unsigned>(bleJsonBuffer.length()));

  if (!isCompleteBleJson(bleJsonBuffer)) {
    Serial.println("[BLE] Waiting for more BLE JSON chunks");
    return "";
  }

  String fullPayload = bleJsonBuffer;
  bleJsonBuffer = "";
  bleJsonBufferStartedAt = 0;
  fullPayload.trim();
  Serial.printf("[BLE] Reassembled JSON: %s\n", fullPayload.c_str());
  return fullPayload;
}

// -------------------------------------------------------------------
// BLE provisioning
// -------------------------------------------------------------------
class ProvisioningServerCallbacks : public BLEServerCallbacks {
 public:
  void onConnect(BLEServer *server) override {
    bleClientConnected = true;
    Serial.println("[BLE] Client connected");
  }

  void onDisconnect(BLEServer *server) override {
    bleClientConnected = false;
    Serial.println("[BLE] Client disconnected");
    delay(120);
    BLEAdvertising *advertising = BLEDevice::getAdvertising();
    advertising->addServiceUUID(BLE_SERVICE_UUID);
    advertising->start();
    Serial.println("[BLE] Advertising restarted after disconnect");
  }
};

class WifiProvisioningCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    std::string raw = characteristic->getValue();
    if (raw.empty()) {
      Serial.println("[BLE] Write received but payload is empty");
      return;
    }

    Serial.printf("[BLE] RX bytes=%u\n", static_cast<unsigned>(raw.size()));
    String payload = collectBlePayload(raw);
    if (payload.length() == 0) {
      return;
    }
    Serial.printf("[BLE] RX raw text: %s\n", payload.c_str());

    String cmd;
    String ssid;
    String password;
    String pairType;
    String pairName;
    String pairZone;
    String pairRemoteMode;
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
      int remoteModeKey = payload.indexOf("\"remote_mode\"");
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
      if (remoteModeKey >= 0) {
        int colon = payload.indexOf(':', remoteModeKey);
        int q1 = payload.indexOf('"', colon + 1);
        int q2 = payload.indexOf('"', q1 + 1);
        if (colon >= 0 && q1 >= 0 && q2 > q1) pairRemoteMode = payload.substring(q1 + 1, q2);
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
      Serial.printf("[BLE] Pair remote_mode=%s\n", pairRemoteMode.c_str());
      Serial.printf("[BLE] Pair pairing_id=%s\n", pairId.c_str());

      rfPairingActive = true;
      rfPairType = pairType;
      rfPairName = pairName.length() ? pairName : pairType;
      rfPairZone = pairZone.length() ? pairZone : "General";
      rfPairRemoteMode = pairRemoteMode;
      rfPairingId = pairId;
      rfPairingStartedAt = millis();
      Serial.println("[RF] Waiting for next RF signal for pairing");
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
  digitalWrite(BUZZER_PIN, (on && settingAlarmSound) ? HIGH : LOW);
}

void playCountdownTick() {
  if (!settingCountdownWithTickTone || !settingAlarmSound) {
    return;
  }
  unsigned long now = millis();
  if (now - lastCountdownTickAt < 900) {
    return;
  }
  lastCountdownTickAt = now;
  digitalWrite(BUZZER_PIN, HIGH);
  delay(35);
  digitalWrite(BUZZER_PIN, LOW);
}

void clearPendingAlarm() {
  entryDelayActive = false;
  entryDelayEndsAt = 0;
  pendingAlarmReason = "";
  pendingAlarmAllowCall = false;
}

void startEntryDelay(const String &reason, bool allowCall) {
  if (settingEntryDelaySeconds == 0) {
    return;
  }
  entryDelayActive = true;
  entryDelayEndsAt = millis() + (static_cast<unsigned long>(settingEntryDelaySeconds) * 1000UL);
  pendingAlarmReason = reason;
  pendingAlarmAllowCall = allowCall;
  lastCountdownTickAt = 0;
  Serial.printf("[DELAY] Entry delay started for %u sec: %s\n", settingEntryDelaySeconds, reason.c_str());
}

void startExitDelay() {
  if (settingExitDelaySeconds == 0) {
    exitDelayActive = false;
    exitDelayEndsAt = 0;
    return;
  }
  exitDelayActive = true;
  exitDelayEndsAt = millis() + (static_cast<unsigned long>(settingExitDelaySeconds) * 1000UL);
  lastCountdownTickAt = 0;
  Serial.printf("[DELAY] Exit delay started for %u sec\n", settingExitDelaySeconds);
}

void stopExitDelay() {
  exitDelayActive = false;
  exitDelayEndsAt = 0;
}

void sendPairingNotify(const String &status, uint32_t rfCode = 0) {
  if (!wifiTxCharacteristic || !bleProvisioningActive) {
    return;
  }

  String json = "{\"type\":\"sensor_ack\",\"status\":\"" + status + "\",\"pairing_id\":" +
                (rfPairingId.length() ? rfPairingId : "0") +
                ",\"pair_type\":\"" + rfPairType + "\",\"name\":\"" + rfPairName +
                "\",\"zone\":\"" + rfPairZone + "\"";
  if (rfCode != 0) {
    json += ",\"rf_code\":\"" + String(rfCode) + "\",\"mac\":\"" + String(rfCode) +
            "\",\"ble_name\":\"" + rfPairName + "\"";
  }
  json += "}";

  wifiTxCharacteristic->setValue(json.c_str());
  wifiTxCharacteristic->notify();
  Serial.printf("[BLE] TX notify: %s\n", json.c_str());
}

void clearRfPairingRequest() {
  rfPairingActive = false;
  rfPairType = "";
  rfPairName = "";
  rfPairZone = "";
  rfPairRemoteMode = "";
  rfPairingId = "";
  rfPairingStartedAt = 0;
}

const char *rfTypeToString(RfType type) {
  switch (type) {
    case RF_TYPE_DOOR: return "door";
    case RF_TYPE_REMOTE_ARM: return "remote_arm";
    case RF_TYPE_REMOTE_DISARM: return "remote_disarm";
    case RF_TYPE_PANIC: return "panic";
    case RF_TYPE_MOTION: return "motion";
    default: return "unknown";
  }
}

RfType rfTypeFromString(String value) {
  value.trim();
  value.toLowerCase();
  if (value == "door") return RF_TYPE_DOOR;
  if (value == "remote_arm" || value == "remote arm") return RF_TYPE_REMOTE_ARM;
  if (value == "remote_disarm" || value == "remote disarm") return RF_TYPE_REMOTE_DISARM;
  if (value == "panic") return RF_TYPE_PANIC;
  if (value == "motion" || value == "pir") return RF_TYPE_MOTION;
  return RF_TYPE_NONE;
}

RfType resolvePairingRfType(String pairType, String pairRemoteMode, String pairZone) {
  pairType.trim();
  pairRemoteMode.trim();
  pairZone.trim();
  pairType.toLowerCase();
  pairRemoteMode.toLowerCase();
  pairZone.toLowerCase();

  if (pairType == "remote") {
    if (pairRemoteMode == "disarm" || pairRemoteMode == "disarmed" || pairZone == "disarm") {
      return RF_TYPE_REMOTE_DISARM;
    }
    if (pairRemoteMode == "arm" || pairRemoteMode == "armed" || pairZone == "arm") {
      return RF_TYPE_REMOTE_ARM;
    }
  }

  RfType directType = rfTypeFromString(pairType);
  if (directType != RF_TYPE_NONE) {
    return directType;
  }
  return RF_TYPE_DOOR;
}

String learnedRfLabel(const LearnedRfItem &item) {
  String label = strlen(item.name) ? String(item.name) : String("LEARNED SENSOR");
  if (strlen(item.zone) > 0) {
    label += " - ";
    label += item.zone;
  }
  return label;
}

int findLearnedRfIndex(uint32_t code) {
  for (uint8_t i = 0; i < learnedRfItemCount; i++) {
    if (learnedRfItems[i].code == code) {
      return i;
    }
  }
  return -1;
}

void saveLearnedRfItems() {
  prefs.begin(PREF_NAMESPACE, false);
  prefs.putUChar(PREF_LEARNED_RF_COUNT, learnedRfItemCount);
  if (learnedRfItemCount == 0) {
    prefs.remove(PREF_LEARNED_RF_DATA);
  } else {
    prefs.putBytes(PREF_LEARNED_RF_DATA, learnedRfItems, learnedRfItemCount * sizeof(LearnedRfItem));
  }
  prefs.end();
  Serial.printf("[RF] Learned RF items saved=%u\n", learnedRfItemCount);
}

void loadLearnedRfItems() {
  memset(learnedRfItems, 0, sizeof(learnedRfItems));
  prefs.begin(PREF_NAMESPACE, true);
  learnedRfItemCount = prefs.getUChar(PREF_LEARNED_RF_COUNT, 0);
  if (learnedRfItemCount > MAX_LEARNED_RF_ITEMS) {
    learnedRfItemCount = MAX_LEARNED_RF_ITEMS;
  }
  size_t expected = learnedRfItemCount * sizeof(LearnedRfItem);
  size_t actual = 0;
  if (expected > 0) {
    actual = prefs.getBytes(PREF_LEARNED_RF_DATA, learnedRfItems, expected);
  }
  prefs.end();

  if (expected > 0 && actual != expected) {
    Serial.printf("[RF] Learned RF load mismatch expected=%u actual=%u\n", static_cast<unsigned>(expected), static_cast<unsigned>(actual));
    memset(learnedRfItems, 0, sizeof(learnedRfItems));
    learnedRfItemCount = 0;
  }

  Serial.printf("[RF] Learned RF items loaded=%u\n", learnedRfItemCount);
}

bool storeLearnedRfItem(uint32_t code, const String &pairType, const String &pairName, const String &pairZone, const String &pairRemoteMode) {
  RfType type = resolvePairingRfType(pairType, pairRemoteMode, pairZone);

  int index = findLearnedRfIndex(code);
  if (index < 0) {
    if (learnedRfItemCount >= MAX_LEARNED_RF_ITEMS) {
      Serial.println("[RF] Learned RF storage full");
      return false;
    }
    index = learnedRfItemCount++;
  }

  LearnedRfItem &item = learnedRfItems[index];
  memset(&item, 0, sizeof(item));
  item.code = code;
  item.type = static_cast<uint8_t>(type);

  String finalName = pairName.length() ? pairName : pairType;
  String finalZone = pairZone;
  finalName.trim();
  finalZone.trim();

  snprintf(item.name, sizeof(item.name), "%s", finalName.c_str());
  snprintf(item.zone, sizeof(item.zone), "%s", finalZone.c_str());

  saveLearnedRfItems();
  Serial.printf("[RF] Learned item stored idx=%d code=%lu type=%s name=%s zone=%s\n",
                index,
                static_cast<unsigned long>(code),
                rfTypeToString(type),
                item.name,
                item.zone);
  return true;
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
  bleServer->setCallbacks(new ProvisioningServerCallbacks());
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
  return String(BLE_DEVICE_NAME);
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

int parseRegState(const String &response) {
  int comma = response.indexOf(',');
  if (comma < 0) return -1;
  int i = comma + 1;
  while (i < response.length() && !isDigit(response[i])) {
    i++;
  }
  if (i >= response.length()) return -1;
  String digits;
  while (i < response.length() && isDigit(response[i])) {
    digits += response[i++];
  }
  return digits.length() ? digits.toInt() : -1;
}

const char *regStateText(int stat) {
  switch (stat) {
    case 0: return "not registered";
    case 1: return "registered(home)";
    case 2: return "searching";
    case 3: return "registration denied";
    case 4: return "unknown";
    case 5: return "registered(roaming)";
    case 6: return "registered(SMS only, home)";
    case 7: return "registered(SMS only, roaming)";
    case 8: return "emergency only";
    default: return "unparsed";
  }
}

bool isSmsRegistrationState(int stat) {
  return stat == 1 || stat == 5 || stat == 6 || stat == 7;
}

bool isVoiceRegistrationState(int stat) {
  return stat == 1 || stat == 5;
}

bool smsServiceReady() {
  int cregStat = parseRegState(queryAt("AT+CREG?", 700));
  int cgregStat = parseRegState(queryAt("AT+CGREG?", 700));
  int ceregStat = parseRegState(queryAt("AT+CEREG?", 700));
  return isSmsRegistrationState(cregStat) || isSmsRegistrationState(cgregStat) || isSmsRegistrationState(ceregStat);
}

bool voiceServiceReady() {
  int cregStat = parseRegState(queryAt("AT+CREG?", 700));
  int ceregStat = parseRegState(queryAt("AT+CEREG?", 700));
  return isVoiceRegistrationState(cregStat) || isVoiceRegistrationState(ceregStat);
}

void logGsmDiagnostics() {
  String cpin = queryAt("AT+CPIN?", 700);
  String creg = queryAt("AT+CREG?", 700);
  String cgreg = queryAt("AT+CGREG?", 700);
  String cereg = queryAt("AT+CEREG?", 700);
  String cops = queryAt("AT+COPS?", 1000);
  String csq = queryAt("AT+CSQ", 700);
  int cregStat = parseRegState(creg);
  int cgregStat = parseRegState(cgreg);
  int ceregStat = parseRegState(cereg);

  Serial.printf("[GSM] CPIN=%s\n", cpin.c_str());
  Serial.printf("[GSM] CSQ=%s\n", csq.c_str());
  Serial.printf("[GSM] CREG raw=%s\n", creg.c_str());
  Serial.printf("[GSM] CREG state=%s\n", regStateText(cregStat));
  Serial.printf("[GSM] CGREG raw=%s\n", cgreg.c_str());
  Serial.printf("[GSM] CGREG state=%s\n", regStateText(cgregStat));
  Serial.printf("[GSM] CEREG raw=%s\n", cereg.c_str());
  Serial.printf("[GSM] CEREG state=%s\n", regStateText(ceregStat));
  Serial.printf("[GSM] Operator=%s\n", cops.c_str());
  Serial.printf("[GSM] SMS ready=%s\n", smsServiceReady() ? "YES" : "NO");
  Serial.printf("[GSM] Voice ready=%s\n", voiceServiceReady() ? "YES" : "NO");
}

void logModemStatus() {
  String creg = queryAt("AT+CREG?", 700);
  String cgreg = queryAt("AT+CGREG?", 700);
  String cereg = queryAt("AT+CEREG?", 700);
  String cops = queryAt("AT+COPS?", 1000);
  int signal = modem.getSignalQuality();
  bool netConnected = modem.isNetworkConnected();

  Serial.printf("[MODEM] isNetworkConnected=%s\n", netConnected ? "YES" : "NO");
  Serial.printf("[MODEM] Signal quality=%d\n", signal);
  Serial.printf("[MODEM] CREG=%s\n", creg.c_str());
  Serial.printf("[MODEM] CGREG=%s\n", cgreg.c_str());
  Serial.printf("[MODEM] CEREG=%s\n", cereg.c_str());
  Serial.printf("[MODEM] COPS=%s\n", cops.c_str());
}

bool gsmLooksUsable() {
  int signal = modem.getSignalQuality();
  String cops = queryAt("AT+COPS?", 1000);
  return smsServiceReady() || voiceServiceReady() || (signal > 0 && signal != 99) || cops.indexOf("+COPS:") >= 0;
}

void registerDeviceToServer() {
  if (WiFi.status() != WL_CONNECTED) {
    return;
  }

  HTTPClient http;
  http.setTimeout((currentMode == MODE_DISARMED) ? HTTP_TIMEOUT_DISARMED_MS : HTTP_TIMEOUT_ARMED_MS);
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

void reportTriggeredSensorToSystemState(const String &triggeredSensor) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[STATE] WiFi not connected, trigger report skipped");
    return;
  }

  HTTPClient http;
  http.setTimeout((currentMode == MODE_DISARMED) ? HTTP_TIMEOUT_DISARMED_MS : HTTP_TIMEOUT_ARMED_MS);
  http.begin(SYSTEM_STATE_URL);
  http.addHeader("Content-Type", "application/json");

  String payload = "{";
  payload += "\"device_uuid\":\"" + jsonEscape(deviceUuid()) + "\",";
  payload += "\"state\":\"alarm\",";
  payload += "\"user\":\"HUB\",";
  payload += "\"triggered_sensor\":\"" + jsonEscape(triggeredSensor) + "\",";
  payload += "\"alarm_reason\":\"" + jsonEscape(triggeredSensor) + "\",";
  payload += "\"reason\":\"" + jsonEscape(triggeredSensor) + "\"";
  payload += "}";

  Serial.printf("[STATE] POST %s\n", SYSTEM_STATE_URL);
  Serial.printf("[STATE] Trigger payload: %s\n", payload.c_str());
  int status = http.POST(payload);
  String body = http.getString();
  Serial.printf("[STATE] Trigger status=%d body=%s\n", status, body.c_str());
  http.end();
}

void serviceAlarmPriorityTasks();

bool alarmCancelled() {
  return currentMode == MODE_DISARMED;
}

void cooperativeDelay(uint32_t durationMs) {
  unsigned long start = millis();
  while (millis() - start < durationMs) {
    serviceAlarmPriorityTasks();
    if (alarmCancelled()) {
      return;
    }
    delay(20);
  }
}

void sendSMS(const char *number, const String &message) {
  if (!number || strlen(number) < 10) return;
  if (alarmCancelled()) return;
  if (!smsServiceReady()) {
    Serial.println("[SMS] SMS service not ready, SMS not sent");
    logModemStatus();
    logGsmDiagnostics();
    return;
  }
  Serial.printf("[SMS] Sending to %s: %s\n", number, message.c_str());
  bool ok = modem.sendSMS(number, message);
  Serial.printf("[SMS] Result=%s\n", ok ? "OK" : "FAIL");
  if (!ok) {
    logModemStatus();
    logGsmDiagnostics();
  }
  cooperativeDelay(500);
}

void sendSmsToAll(const String &message) {
  if (smsNumberCount == 0) {
    Serial.println("[SMS] No synced SMS numbers available");
    return;
  }
  for (uint8_t i = 0; i < smsNumberCount; i++) {
    if (alarmCancelled()) {
      Serial.println("[ALARM] SMS sending stopped due to disarm");
      return;
    }
    sendSMS(smsNumbers[i], message);
  }
}

void callNumber(const char *number, uint32_t durationMs = 20000) {
  if (!number || strlen(number) < 10) return;
  if (alarmCancelled()) return;
  if (!voiceServiceReady()) {
    Serial.println("[CALL] Voice service not ready, call not started");
    logModemStatus();
    logGsmDiagnostics();
    return;
  }
  Serial.printf("[CALL] Calling %s\n", number);
  bool ok = modem.callNumber(number);
  Serial.printf("[CALL] Dial result=%s\n", ok ? "OK" : "FAIL");
  if (!ok) {
    logModemStatus();
    logGsmDiagnostics();
    return;
  }
  unsigned long start = millis();
  while (millis() - start < durationMs) {
    serviceAlarmPriorityTasks();
    if (alarmCancelled()) {
      Serial.println("[ALARM] Hanging up due to disarm priority");
      modem.callHangup();
      return;
    }
    delay(20);
  }
  modem.callHangup();
  cooperativeDelay(1500);
}

void callAll() {
  if (callNumberCount == 0) {
    Serial.println("[CALL] No synced call numbers available");
    return;
  }
  for (uint8_t i = 0; i < callNumberCount; i++) {
    if (alarmCancelled()) {
      Serial.println("[ALARM] Calling stopped due to disarm");
      return;
    }
    callNumber(callNumbers[i]);
  }
}

void sendAlert(const String &message, bool allowCall) {
  if (!settingAlarmNotification) {
    Serial.println("[ALERT] alarm_notification setting is disabled");
    return;
  }
  if (settingAlarmSms) {
    sendSmsToAll(message);
  } else {
    Serial.println("[SMS] alarm_sms setting is disabled");
  }
  if (allowCall && !alarmCancelled() && settingAlarmCall) {
    uint8_t attempts = settingUnansweredPhoneRedialTimes > 0 ? settingUnansweredPhoneRedialTimes : 1;
    for (uint8_t retry = 0; retry < attempts; retry++) {
      if (retry > 0) {
        Serial.printf("[CALL] Redial attempt %u/%u\n", retry + 1, attempts);
      }
      callAll();
      if (alarmCancelled()) {
        break;
      }
    }
  } else if (allowCall && !settingAlarmCall) {
    Serial.println("[CALL] alarm_call setting is disabled");
  }
}

void setMode(SystemMode mode, const char *reason) {
  currentMode = mode;
  switch (mode) {
    case MODE_ARMED:
      clearPendingAlarm();
      stopExitDelay();
      setAlarmOutputs(false);
      startExitDelay();
      beep(1);
      Serial.printf("[STATE] ARMED by %s\n", reason);
      if (shouldSendArmDisarmSms(reason)) {
        sendSmsToAll("SYSTEM ARMED");
      }
      break;
    case MODE_DISARMED:
      modem.callHangup();
      clearPendingAlarm();
      stopExitDelay();
      alarmEndsAt = 0;
      setAlarmOutputs(false);
      beep(2);
      Serial.printf("[STATE] DISARMED by %s\n", reason);
      if (shouldSendArmDisarmSms(reason)) {
        sendSmsToAll("SYSTEM DISARMED");
      }
      break;
    case MODE_STAY_ARM:
      clearPendingAlarm();
      stopExitDelay();
      setAlarmOutputs(false);
      startExitDelay();
      beep(3);
      Serial.printf("[STATE] STAY ARM by %s\n", reason);
      if (shouldSendArmDisarmSms(reason)) {
        sendSmsToAll("SYSTEM STAY ARM");
      }
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
  modeBeforeAlarm = currentMode;
  currentMode = MODE_ALARM;
  alarmEndsAt = settingAlarmDurationMinutes > 0 ? now + (static_cast<unsigned long>(settingAlarmDurationMinutes) * 60000UL) : 0;
  clearPendingAlarm();
  setAlarmOutputs(true);
  Serial.printf("[ALARM] %s\n", reason.c_str());
  sendAlarmEvent("ALARM_START", reason, reason);
  reportTriggeredSensorToSystemState(reason);
  sendAlert("ALERT: " + reason, allowCall);
}

void updateAlarmBuzzer();

void updateTimedAlarmState();

void serviceAlarmPriorityTasks() {
  pollRf();
  pollSystemState();
  updateTimedAlarmState();
  updateAlarmBuzzer();
}

void handleDoorTrigger(const char *zoneName) {
  if (currentMode == MODE_DISARMED) {
    return;
  }
  if (exitDelayActive) {
    // User requirement: do not ignore sensor triggers during exit delay.
    Serial.printf("[DELAY] Trigger during exit delay: %s\n", zoneName);
  }
  if (entryDelayActive) {
    Serial.printf("[DELAY] Entry delay already running, ignoring additional trigger: %s\n", zoneName);
    return;
  }
  bool allowCall = (currentMode != MODE_STAY_ARM);
  String reason = String(zoneName) + " OPEN";
  sendAlarmEvent("SENSOR_TRIGGER", String(zoneName), reason);
  if (settingEntryDelaySeconds > 0) {
    startEntryDelay(reason, allowCall);
    return;
  }
  triggerAlarm(reason, allowCall);
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
  if (!allowServerRequests()) {
    return;
  }

  unsigned long interval = (currentMode == MODE_DISARMED) ? STATE_POLL_DISARMED_MS : STATE_POLL_ARMED_MS;
  unsigned long now = millis();
  if (now - lastStatePollAt < interval) {
    return;
  }
  lastStatePollAt = now;

  HTTPClient http;
  http.setTimeout((currentMode == MODE_DISARMED) ? HTTP_TIMEOUT_DISARMED_MS : HTTP_TIMEOUT_ARMED_MS);
  String url = String(SYSTEM_STATE_URL) + "&device_uuid=" + deviceUuid();
  http.begin(url);
  int status = http.GET();
  if (status == 200) {
    noteServerOk();
    String body = http.getString();
    String state = extractJsonString(body, "state");
    if (state.length() > 0) {
      handleServerState(state);
    } else {
      Serial.printf("[SYNC] No state in response: %s\n", body.c_str());
    }
  } else {
    Serial.printf("[SYNC] HTTP GET failed status=%d\n", status);
    noteServerFail("system_state", status);
  }
  http.end();
}

void connectWiFi() {
  if (!wifiProvisioned) {
    Serial.println("[WIFI] No credentials stored");
    setOfflineMode(true, "no_credentials");
    return;
  }

  lastWiFiAttemptAt = millis();
  Serial.printf("[WIFI] Connecting to %s\n", provisionedSsid.c_str());
  WiFi.mode(WIFI_STA);
  WiFi.begin(provisionedSsid.c_str(), provisionedPassword.c_str());

  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < WIFI_CONNECT_TIMEOUT_MS) {
    // Keep sensor/RF processing alive while we're waiting on WiFi.
    pollRf();
    updateTimedAlarmState();
    pollDoorZones();
    updateAlarmBuzzer();
    delay(500);
    Serial.print(".");
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("[WIFI] Connected IP=%s\n", WiFi.localIP().toString().c_str());
    setOfflineMode(false, "wifi_connected");
    if (wifiTxCharacteristic) {
      wifiTxCharacteristic->setValue("WIFI_CONNECTED");
      wifiTxCharacteristic->notify();
    }
    registerDeviceToServer();
    fetchSettingsFromServer();
  } else {
    Serial.println("[WIFI] Connection failed");
    setOfflineMode(true, "wifi_failed");
    if (wifiTxCharacteristic) {
      wifiTxCharacteristic->setValue("WIFI_FAILED");
      wifiTxCharacteristic->notify();
    }
    if (START_BLE_PROVISIONING_ON_WIFI_FAIL) {
      startBleProvisioning();
    }
  }
}

void initModem() {
  Serial.println("[MODEM] Starting UART");
  SerialAT.begin(MODEM_BAUD, SERIAL_8N1, MODEM_RX, MODEM_TX);
  delay(3000);

  bool modemReady = false;
  Serial.println("[MODEM] Restarting modem");
  if (modem.restart()) {
    modemReady = true;
    Serial.println("[MODEM] Restart OK");
  } else {
    Serial.println("[MODEM] Restart failed, trying init");
    if (modem.init()) {
      modemReady = true;
      Serial.println("[MODEM] Init OK after restart failure");
    } else {
      String at = queryAt("AT", 700);
      if (at.indexOf("OK") >= 0) {
        modemReady = true;
        Serial.println("[MODEM] AT responded OK, continuing without restart/init");
      } else {
        Serial.println("[MODEM] Init failed and AT not responding cleanly");
      }
    }
  }

  Serial.println("[MODEM] Disabling command echo (ATE0)");
  String ate0 = queryAt("ATE0", 700);
  Serial.printf("[MODEM] ATE0 response=%s\n", ate0.c_str());
  Serial.println("[MODEM] Settling before network checks");
  delay(2000);

  logModemStatus();
  logGsmDiagnostics();
  if (!modemReady) {
    Serial.println("[MODEM] Continuing boot with limited modem availability");
  }

  Serial.println("[MODEM] Waiting for network");
  unsigned long start = millis();
  while (!modem.waitForNetwork()) {
    Serial.println("[MODEM] Network retry");
    if (millis() - start >= MODEM_NETWORK_TIMEOUT_MS) {
      Serial.printf("[MODEM] Network timeout after %lu ms\n", MODEM_NETWORK_TIMEOUT_MS);
      logModemStatus();
      logGsmDiagnostics();
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
  if (rfPairingActive) {
    Serial.printf("[RF] Pairing capture code=%lu type=%s\n", static_cast<unsigned long>(code), rfPairType.c_str());
    if (storeLearnedRfItem(code, rfPairType, rfPairName, rfPairZone, rfPairRemoteMode)) {
      sendPairingNotify("paired", code);
    } else {
      sendPairingNotify("pair_save_failed", code);
    }
    clearRfPairingRequest();
    return;
  }

  int learnedIndex = findLearnedRfIndex(code);
  if (learnedIndex >= 0) {
    const LearnedRfItem &item = learnedRfItems[learnedIndex];
    String label = learnedRfLabel(item);
    Serial.printf("[RF] Matched learned %s\n", label.c_str());
    switch (static_cast<RfType>(item.type)) {
      case RF_TYPE_DOOR:
        handleDoorTrigger(label.c_str());
        return;
      case RF_TYPE_MOTION:
        handleDoorTrigger(label.c_str());
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
        break;
    }
  }

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
    int state = -1;

    if (DOOR_ZONE_PINS[i] >= 0) {
      state = digitalRead(DOOR_ZONE_PINS[i]);
    } else if (mcpAvailable && i < MCP_WIRED_ZONE_COUNT) {
      // Read from MCP23017 for zones 1-10.
      state = mcp.digitalRead(MCP_WIRED_ZONE_PINS[i]) ? HIGH : LOW;
    } else {
      continue;
    }

    // Trigger only when the door changes from CLOSED to OPEN.
    if (currentMode != MODE_DISARMED && lastDoorZoneState[i] == DOOR_CLOSED_STATE && state == DOOR_OPEN_STATE) {
      handleDoorTrigger(DOOR_ZONE_NAMES[i]);
    }
    lastDoorZoneState[i] = state;
  }
}

void updateTimedAlarmState() {
  unsigned long now = millis();
  if (exitDelayActive) {
    if (now >= exitDelayEndsAt) {
      stopExitDelay();
      Serial.println("[DELAY] Exit delay completed");
    } else {
      playCountdownTick();
    }
  }
  if (entryDelayActive) {
    if (now >= entryDelayEndsAt) {
      String reason = pendingAlarmReason;
      bool allowCall = pendingAlarmAllowCall;
      clearPendingAlarm();
      triggerAlarm(reason, allowCall);
    } else {
      playCountdownTick();
    }
  }
  if (currentMode == MODE_ALARM && alarmEndsAt > 0 && now >= alarmEndsAt) {
    Serial.println("[ALARM] Alarm duration expired");
    SystemMode restoreMode = (modeBeforeAlarm == MODE_STAY_ARM) ? MODE_STAY_ARM : MODE_ARMED;
    setMode(restoreMode, "ALARM TIMEOUT");
    alarmEndsAt = 0;
  }
}

void updateAlarmBuzzer() {
  if (currentMode == MODE_ALARM) {
    bool on = ((millis() / 1000) % 2) == 0;
    digitalWrite(BUZZER_PIN, (settingAlarmSound && on) ? HIGH : LOW);
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

  // Keep NVS ("EEPROM") across power cycles, but wipe everything when the RESET/EN button is pressed.
  // Note: many ESP32 dev boards treat EN reset like a power-on reset. We use an RTC marker to detect it.
  esp_reset_reason_t resetReason = esp_reset_reason();
  const bool warmReset = (rtcWarmResetMarker == RTC_WARM_RESET_MAGIC);
  Serial.printf("[BOOT] Reset reason=%d warm_reset=%s\n",
                static_cast<int>(resetReason),
                warmReset ? "YES" : "NO");

  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(STATUS_LED_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);
  digitalWrite(STATUS_LED_PIN, LOW);

  // Init MCP23017 (wired door zones)
  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  if (mcp.begin_I2C(MCP23017_ADDR, &Wire)) {
    mcpAvailable = true;
    Serial.printf("[MCP] MCP23017 online addr=0x%02X SDA=%d SCL=%d\n", MCP23017_ADDR, I2C_SDA_PIN, I2C_SCL_PIN);
    for (uint8_t i = 0; i < MCP_WIRED_ZONE_COUNT; i++) {
      uint8_t pin = MCP_WIRED_ZONE_PINS[i];
      mcp.pinMode(pin, INPUT_PULLUP);
      lastDoorZoneState[i] = mcp.digitalRead(pin) ? HIGH : LOW;
      Serial.printf("[ZONE] %s on MCP pin %u initial=%d\n", DOOR_ZONE_NAMES[i], pin, lastDoorZoneState[i]);
    }
  } else {
    mcpAvailable = false;
    Serial.printf("[MCP] ERROR: MCP23017 not found at addr=0x%02X\n", MCP23017_ADDR);
  }

  for (uint8_t i = 0; i < DOOR_ZONE_COUNT; i++) {
    if (DOOR_ZONE_PINS[i] >= 0) {
      pinMode(DOOR_ZONE_PINS[i], INPUT_PULLUP);
      lastDoorZoneState[i] = digitalRead(DOOR_ZONE_PINS[i]);
      Serial.printf("[ZONE] %s on GPIO %d initial=%d\n", DOOR_ZONE_NAMES[i], DOOR_ZONE_PINS[i], lastDoorZoneState[i]);
    }
  }

  rf.enableReceive(digitalPinToInterrupt(RF_PIN));
  Serial.printf("[RF] Receiver enabled on GPIO %d\n", RF_PIN);

  if (ERASE_ALL_NVS_ON_RESET_BUTTON && warmReset && resetReason != ESP_RST_DEEPSLEEP) {
    Serial.println("[BOOT] RESET button (warm reset) detected, erasing ALL NVS data");
    clearAllStoredData();
  } else if (CLEAR_WIFI_ON_EVERY_BOOT) {
    clearAllStoredData();
  } else {
    loadWifiCredentials();
  }

  // Mark boot as "warm" for the next reset. This marker is cleared on power loss.
  rtcWarmResetMarker = RTC_WARM_RESET_MAGIC;

  loadLearnedRfItems();
  loadCachedSettingsFromPreferences();
  if (!wifiProvisioned) {
    startBleProvisioning();
  }
  connectWiFi();
  initModem();
  setMode(MODE_DISARMED, "BOOT");
}

void loop() {
  unsigned long wifiRetryMs = offlineMode ? WIFI_RETRY_OFFLINE_MS : WIFI_RETRY_ONLINE_MS;
  if (WiFi.status() != WL_CONNECTED && wifiProvisioned && millis() - lastWiFiAttemptAt > wifiRetryMs) {
    connectWiFi();
  }
  // Avoid long HTTP work while armed; keep RF/door handling responsive.
  if (WiFi.status() == WL_CONNECTED && currentMode == MODE_DISARMED && allowServerRequests() &&
      millis() - lastSettingsFetchAt > SETTINGS_FETCH_MS) {
    fetchSettingsFromServer();
  }
  pollRf();
  pollSystemState();
  serviceAutoArmSchedule();
  if (rfPairingActive && millis() - rfPairingStartedAt > RF_PAIR_WINDOW_MS) {
    Serial.println("[RF] Pairing window timed out");
    sendPairingNotify("timeout");
    clearRfPairingRequest();
  }
  updateTimedAlarmState();
  pollDoorZones();
  updateAlarmBuzzer();
  delay(50);
}
