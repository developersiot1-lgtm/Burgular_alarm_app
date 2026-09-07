#define TINY_GSM_MODEM_A7672X
// Keep TinyGSM debug disabled during normal run; raw modem bytes can pollute Serial logs.
// #define TINY_GSM_DEBUG Serial

#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <Wire.h>
#include <time.h>
#include <sys/time.h>
#include <TinyGsmClient.h>
#include <RCSwitch.h>
#include <nvs_flash.h>
#include <esp_system.h>
#include <esp_wifi.h>

#define ENABLE_BLE_PROVISIONING 1

#if ENABLE_BLE_PROVISIONING
#include <BLEDevice.h>
#include <BLE2902.h>
#else
class BLEServer {};
class BLECharacteristic {
 public:
  void setValue(const char *) {}
  void notify() {}
};
#endif

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
static const int MODEM_PWRKEY_PIN = -1;      // ADIY A7670C breakout has no PWRKEY pin exposed
static const int MODEM_PWRKEY_ON_STATE = LOW;
static const unsigned long MODEM_PWRKEY_PULSE_MS = 1200;
static const unsigned long MODEM_BOOT_SETTLE_MS = 8000;

// Schematic pin mapping
static const int LCD_I2C_SDA_PIN = 2;       // ARM net reused as LCD SDA
static const int LCD_I2C_SCL_PIN = 5;       // DISARM net reused as LCD SCL
static const int BUZZER_PIN = 4;            // BUZZER
static const int ARM_INDICATOR_PIN = 12;    // NETWORK net used as ARM indication LED
static const int PWR_SENSE_PIN = 13;        // Power circuit present sense
static const int DISARM_INDICATOR_PIN = 14; // ALARM net used as DISARM indication LED
static const int SIREN_PIN = 15;            // Siren output on sensor/alarm trigger
static const int MIC_REC_PIN = 18;          // Mic recording push button
static const int RF_PAIR_BUTTON_PIN = 19;   // Long press to pair RF sensors
static const int FW_RESET_PIN = 21;         // Firmware restart push button
static const int AUX_BUZZER_PIN = 26;       // BUZZER1
static const int BAT_SENSE_PIN = 33;        // Battery voltage sense ADC
static const int RF_PIN = 35;
static const uint8_t LCD_I2C_ADDRESS = 0x27;
static const uint8_t LCD_I2C_ALT_ADDRESS = 0x3F;
static const uint8_t LCD_COLUMNS = 16;
static const uint8_t LCD_ROWS = 4;

// Manual wired door zones. Set unused pins to -1.
static const int DOOR_ZONE_PINS[] = {
  22, 23
};
static const char *DOOR_ZONE_NAMES[] = {
  "DOOR 1",
  "DOOR 2"
};
static const uint8_t DOOR_ZONE_COUNT = sizeof(DOOR_ZONE_PINS) / sizeof(DOOR_ZONE_PINS[0]);

// -------------------------------------------------------------------
// App / server setup
// -------------------------------------------------------------------
static const char *DEFAULT_WIFI_SSID = "";
static const char *DEFAULT_WIFI_PASSWORD = "";
static const char *SYSTEM_STATE_URL = "http://monsow.in/alarm/index.php?action=system_state";

// -------------------------------------------------------------------
// App/server arm-disarm control
// Set false if you want ONLY RF remote to arm/disarm.
// -------------------------------------------------------------------
static const bool ALLOW_APP_ARM_DISARM_CONTROL = true;
static const char *DEVICE_REGISTER_URL = "http://monsow.in/alarm/index.php?action=device_register";
static const char *FIRMWARE_RESET_URL = "http://monsow.in/alarm/index.php?action=firmware_factory_reset";
static const char *SETTINGS_URL_BASE = "http://monsow.in/alarm/index.php?action=sync_settings_to_device&device_uuid=";
static const char *PREF_NAMESPACE = "alarmcfg";
static const char *PREF_WIFI_SSID = "wifi_ssid";
static const char *PREF_WIFI_PASS = "wifi_pass";
static const char *PREF_SETTINGS_CACHE = "set_cache";
static const char *PREF_PENDING_FW_CLEAN = "fw_clean_pend";
static const char *BLE_DEVICE_NAME = "MONSOW_072608";
static const char *BLE_SERVICE_UUID = "703DE63C-1C78-703D-E63C-1A42B93437E2";
static const char *BLE_RX_UUID = "703DE63C-1C78-703D-E63C-1A42B93437E3";
static const char *BLE_TX_UUID = "703DE63C-1C78-703D-E63C-1A42B93437E4";
static const bool CLEAR_WIFI_ON_EVERY_BOOT = false;
static const bool ERASE_ALL_NVS_ON_RESET_BUTTON = false;

// Stored WiFi/settings/RF data is kept across reset and power off/on.
// Set ERASE_ALL_NVS_ON_RESET_BUTTON true only if reset must wipe stored data.
RTC_DATA_ATTR uint32_t rtcWarmResetMarker = 0;
static const uint32_t RTC_WARM_RESET_MAGIC = 0xB16B00B5UL;

// Poll interval for app/server arm-disarm state.
static const unsigned long STATE_POLL_DISARMED_MS = 3000;
static const unsigned long STATE_POLL_ARMED_MS = 3000;
static const unsigned long MODEM_NETWORK_TIMEOUT_MS = 60000;
static const unsigned long GSM_POWER_FAULT_COOLDOWN_MS = 120000;
static const unsigned long RF_PAIR_WINDOW_MS = 120000;
static const unsigned long FW_RESET_HOLD_MS = 5000;
static const unsigned long LCD_UPDATE_INTERVAL_MS = 1000;
static const unsigned long LCD_EVENT_BACKLIGHT_MS = 15000;
static const uint8_t LCD_BACKLIGHT_BIT = 0x08;
static const unsigned long OUTPUT_PIN_LOG_INTERVAL_MS = 5000;
static const unsigned long WIFI_CONNECT_TIMEOUT_MS = 25000;
static const unsigned long WIFI_RETRY_ONLINE_MS = 5000;
static const unsigned long WIFI_RETRY_OFFLINE_MS = 15000;
static const uint16_t WIFI_SCAN_MAX_MS_PER_CHANNEL = 450;
static const unsigned long GSM_RETRY_INTERVAL_MS = 30000;
static const bool START_BLE_PROVISIONING_ON_WIFI_FAIL = false;
static const bool START_BLE_PROVISIONING_ON_BOOT = false;
static const unsigned long BLE_BOOT_ADVERTISING_MS = 120000;
static const unsigned long PAIRING_REQUEST_POLL_MS = 5000;
static const char *PAIRING_REQUEST_URL = "http://monsow.in/alarm/index.php?action=get_pairing_request&device_uuid=";
static const char *PAIRING_STATUS_URL = "http://monsow.in/alarm/index.php?action=update_pairing_status";
static const unsigned long HTTP_TIMEOUT_DISARMED_MS = 10000;
static const unsigned long HTTP_TIMEOUT_ARMED_MS = 6000;
static const uint8_t SERVER_OFFLINE_AFTER_FAILS = 6;
static const unsigned long SERVER_DECLARE_OFFLINE_AFTER_MS = 20000;
static const unsigned long SERVER_OFFLINE_RETRY_MS = 15000;
static const bool AUTO_ARM_ON_SERVER_OFFLINE = false;
static const unsigned long AUTO_ARM_DELAY_MS = 15000;
// Set true to enable GSM SMS/call features using UART2 on GPIO16/17.
static const bool ENABLE_GSM_FEATURES = true;
static const bool USE_TINYGSM_MODEM_RESTART = false;
static const bool WIFI_AUTO_RECONNECT = true;

// If your modem restarts when the siren/buzzer turns on (power dip),
// set this true to send SMS/call first, then enable alarm sound.
static const bool SUPPRESS_ALARM_SOUND_WHILE_ALERTING = false;

// Set true to completely disable buzzer/siren output from firmware (useful for debugging power resets).
static const bool FORCE_ALARM_SOUND_OFF = false;

// Short buzzer beep immediately when a sensor is triggered.
static const bool BEEP_ON_SENSOR_TRIGGER = true;
static const uint16_t SENSOR_TRIGGER_BEEP_MS = 250;

static const uint8_t SENSOR_TRIGGER_BEEP_COUNT = 1;
static const uint16_t TOUCH_BEEP_MS = 35;
static const unsigned long BUTTON_DEBOUNCE_MS = 50;
static const unsigned long RF_PAIR_LONG_PRESS_MS = 3000;
static const unsigned long BATTERY_LOG_INTERVAL_MS = 10000;
static const unsigned long TIME_SYNC_RETRY_MS = 60000;
static const float BATTERY_ADC_REF_VOLTAGE = 3.30f;
static const float BATTERY_DIVIDER_RATIO = 2.00f;
static const float BATTERY_EMPTY_VOLTAGE = 3.20f;
static const float BATTERY_FULL_VOLTAGE = 4.20f;
static const int BATTERY_PERCENT_OFFSET = 0;
static const uint8_t PANEL_LOW_BATTERY_PERCENT = 20;
static const unsigned long PANEL_LOW_BATTERY_NOTIFY_INTERVAL_MS = 30UL * 60UL * 1000UL;

// Arm/disarm SMS follows arm_disarm_notification setting.
static const bool ALWAYS_SEND_DISARM_SMS = true;
// With INPUT_PULLUP and a sensor to GND:
// normal state              -> pin HIGH
// triggered state           -> pin LOW
static const int DOOR_OPEN_STATE = LOW;
static const int DOOR_CLOSED_STATE = HIGH;

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
static const unsigned long SETTINGS_FETCH_DISARMED_MS = 60000;
static const unsigned long SETTINGS_FETCH_ARMED_MS = 60000;
String cachedSettingsJson;
long lastSettingsSyncLogId = -1;


// -------------------------------------------------------------------
// MANUAL_CONTACT_NUMBERS (fallback)
// If you do NOT use the app/server sync, put your numbers here.
// These numbers are used only when there are no cached/server numbers.
// -------------------------------------------------------------------
static const bool USE_MANUAL_CONTACT_NUMBERS = true;

// Example formats: "+919876543210" or "9876543210"
static const char *MANUAL_SMS_NUMBERS[] = {

};
static const char *MANUAL_CALL_NUMBERS[] = {
 
};

static const uint8_t MANUAL_SMS_NUMBER_COUNT = sizeof(MANUAL_SMS_NUMBERS) / sizeof(MANUAL_SMS_NUMBERS[0]);
static const uint8_t MANUAL_CALL_NUMBER_COUNT = sizeof(MANUAL_CALL_NUMBERS) / sizeof(MANUAL_CALL_NUMBERS[0]);
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
  RF_TYPE_MOTION = 5,
  RF_TYPE_TAMPER = 6
};

struct ManualRfItem {
  uint32_t code;
  RfType type;
  const char *name;
};

static const ManualRfItem RF_ITEMS[] = {
  {2437633UL, RF_TYPE_REMOTE_ARM, "REMOTE ARM"},
  {2437634UL, RF_TYPE_REMOTE_DISARM, "REMOTE DISARM"},
  {15191155UL, RF_TYPE_DOOR, "DOOR SENSOR TEST"},
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
uint8_t lastWifiDisconnectReason = 0;
unsigned long lastWifiDisconnectAt = 0;
uint8_t lastLoggedWifiDisconnectReason = 0;
unsigned long lastLoggedWifiDisconnectAt = 0;
int lastWifiScanChannel = 0;
uint8_t lastWifiScanBssid[6] = {0};
bool lastWifiScanHasBssid = false;
bool offlineMode = false;
unsigned long offlineModeSinceAt = 0;
bool serverOnline = true;
uint8_t serverFailCount = 0;
unsigned long serverFailWindowStartedAt = 0;
unsigned long lastServerOkAt = 0;
bool gsmCallActive = false;
unsigned long nextServerRetryAt = 0;
bool pendingServerFactoryResetCleanup = false;
bool autoArmScheduled = false;
bool autoArmDone = false;
unsigned long autoArmDueAt = 0;
bool alarmOutputsEnabled = false;
unsigned long lastPairingRequestPollAt = 0;
unsigned long lastPairingNoRequestLogAt = 0;
long lastServerPairingRequestId = -1;
unsigned long stopBleAfterPairingAt = 0;
uint32_t recentlyPairedRfCode = 0;
unsigned long recentlyPairedRfIgnoreUntil = 0;
long locallyCompletedPairingRequestId = -1;
unsigned long locallyCompletedPairingIgnoreUntil = 0;

bool suppressAlarmSound = false;
int lastDoorZoneState[DOOR_ZONE_COUNT];
int lastMicRecButtonState = HIGH;
int lastFwResetButtonState = HIGH;
int lastRfPairButtonState = HIGH;
int lastPowerSenseState = LOW;
unsigned long rfPairButtonPressedAt = 0;
bool rfPairLongPressHandled = false;
unsigned long fwResetButtonPressedAt = 0;
bool fwResetLongPressHandled = false;
unsigned long lastBatteryLogAt = 0;
unsigned long lastPanelLowBatteryNotifyAt = 0;
unsigned long lastLcdUpdateAt = 0;
unsigned long lastOutputPinLogAt = 0;
int lastLoggedBuzzerState = -1;
int lastLoggedAuxBuzzerState = -1;
int lastLoggedSirenState = -1;
bool lcdReady = false;
uint8_t activeLcdAddress = LCD_I2C_ADDRESS;
bool lcdBacklightEnabled = false;
unsigned long lcdBacklightOffAt = 0;
bool gsmNetworkOnline = false;
bool modemAtOnline = false;
uint32_t activeModemBaud = MODEM_BAUD;
unsigned long lastGsmReconnectAttemptAt = 0;
unsigned long gsmCooldownUntil = 0;
bool timeConfigured = false;
unsigned long lastTimeSyncAttemptAt = 0;
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

uint8_t readBatteryPercentage();
float readBatteryVoltage();
void serviceAlarmPriorityTasks();
void updateLcdStatus(bool force);
void serviceLcdBacklightTimeout();
void lcdBacklightForEvent(const char *reason);

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
  if (gsmCallActive) {
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


void applyManualContactNumbersIfEmpty() {
  if (!USE_MANUAL_CONTACT_NUMBERS) return;

  // Do not override cached/server numbers.
  if (smsNumberCount > 0 || callNumberCount > 0) {
    return;
  }

  clearContactNumbers();

  for (uint8_t i = 0; i < MANUAL_SMS_NUMBER_COUNT && smsNumberCount < MAX_CONTACT_NUMBERS; i++) {
    if (copyContactNumber(smsNumbers[smsNumberCount], String(MANUAL_SMS_NUMBERS[i]))) {
      smsNumberCount++;
    }
  }

  for (uint8_t i = 0; i < MANUAL_CALL_NUMBER_COUNT && callNumberCount < MAX_CONTACT_NUMBERS; i++) {
    if (copyContactNumber(callNumbers[callNumberCount], String(MANUAL_CALL_NUMBERS[i]))) {
      callNumberCount++;
    }
  }

  // If only one list is provided, mirror it into the other.
  if (smsNumberCount > 0 && callNumberCount == 0) {
    for (uint8_t i = 0; i < smsNumberCount; i++) {
      snprintf(callNumbers[i], CONTACT_NUMBER_LEN, "%s", smsNumbers[i]);
    }
    callNumberCount = smsNumberCount;
  } else if (callNumberCount > 0 && smsNumberCount == 0) {
    for (uint8_t i = 0; i < callNumberCount; i++) {
      snprintf(smsNumbers[i], CONTACT_NUMBER_LEN, "%s", callNumbers[i]);
    }
    smsNumberCount = callNumberCount;
  }

  sanitizeContactNumbers();
  if (smsNumberCount > 0 || callNumberCount > 0) {
    Serial.println("[CONTACTS] Loaded manual contact numbers");
    logContactNumbers();
  }
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

String decodeBleJsonString(String value) {
  String decoded;
  decoded.reserve(value.length());

  for (int i = 0; i < value.length(); i++) {
    char c = value[i];
    if (c != '\\' || i + 1 >= value.length()) {
      decoded += c;
      continue;
    }

    char next = value[++i];
    switch (next) {
      case 'n': decoded += '\n'; break;
      case 'r': decoded += '\r'; break;
      case 't': decoded += '\t'; break;
      case 'b': decoded += '\b'; break;
      case 'f': decoded += '\f'; break;
      default: decoded += next; break;
    }
  }

  return decoded;
}

String sanitizeBleWifiText(String value) {
  value.replace("\\@", "@");
  value.replace("\\_", "_");
  value.replace("\\ ", " ");
  value.trim();
  return value;
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

void prepareHttpRequest(HTTPClient &http) {
  http.useHTTP10(true);
  http.setReuse(false);
  http.addHeader("User-Agent", "MONSOW-ESP32/1.0");
  http.addHeader("Accept", "application/json");
}

void fetchSettingsFromServer() {
  if (!allowServerRequests()) {
    return;
  }

  const String baseUuid = deviceUuid();
  HTTPClient http;
  http.setTimeout((currentMode == MODE_DISARMED) ? HTTP_TIMEOUT_DISARMED_MS : HTTP_TIMEOUT_ARMED_MS);
  String url = String(SETTINGS_URL_BASE) + urlEncode(baseUuid) + "&device_name=" + urlEncode(deviceName());
  Serial.printf("[SETTINGS] GET %s\n", url.c_str());
  http.begin(url);
  prepareHttpRequest(http);
  int status = http.GET();
  String body = http.getString();
  http.end();

  if (status != 200) {
    Serial.printf("[SETTINGS] Status=%d (uuid=%s)\n", status, baseUuid.c_str());
    noteServerFail("settings", status);
    return;
  }

  noteServerOk();
  long syncId = extractJsonIntValue(body, "sync_log_id", -1);
  String settingsBody = resolveSettingsPayload(body);
  settingsBody.trim();
  Serial.printf("[SETTINGS] OK uuid=%s sync_log_id=%ld\n", baseUuid.c_str(), syncId);

  if (settingsBody.length() == 0) {
    return;
  }

  applySettingsPayload(settingsBody);
  applyContactNumbersFromSettingsPayload(settingsBody);
  saveSettingsCacheIfChanged(settingsBody);
  lastSettingsFetchAt = millis();
  if (syncId >= 0) {
    lastSettingsSyncLogId = syncId;
  }
}

void sendAlarmEvent(String eventType, String zone, String message) {
  if (!settingAlarmNotification &&
      (eventType == "ALARM_START" || eventType == "SENSOR_TRIGGER" || eventType == "ALARM_TRIGGER")) {
    Serial.printf("[EVENT] %s skipped because alarm_notification is disabled\n", eventType.c_str());
    return;
  }
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[EVENT] WiFi not connected");
    return;
  }

  HTTPClient http;
  http.setTimeout((currentMode == MODE_DISARMED) ? HTTP_TIMEOUT_DISARMED_MS : HTTP_TIMEOUT_ARMED_MS);
  String url = "http://monsow.in/alarm/index.php?action=alarm_event";

  http.begin(url);
  prepareHttpRequest(http);
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
unsigned long bleProvisioningStartedAt = 0;
bool wifiProvisioned = false;
bool deviceRegistered = false;
bool pendingInitialServerSync = false;
unsigned long pendingInitialServerSyncAt = 0;
String provisionedSsid;
String provisionedPassword;
String bleJsonBuffer;
unsigned long bleJsonBufferStartedAt = 0;
bool pendingWifiConnectAfterBleConfig = false;
unsigned long pendingWifiConnectAt = 0;
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
#if ENABLE_BLE_PROVISIONING
class ProvisioningServerCallbacks : public BLEServerCallbacks {
 public:
  void onConnect(BLEServer *server) override {
    bleClientConnected = true;
    Serial.println("[BLE] Client connected");
  }

  void onDisconnect(BLEServer *server) override {
    bleClientConnected = false;
    Serial.println("[BLE] Client disconnected");
    if (!bleProvisioningActive || pendingWifiConnectAfterBleConfig || stopBleAfterPairingAt != 0) {
      Serial.println("[BLE] Advertising restart skipped; BLE stop/WiFi connect pending");
      return;
    }
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
        cmd = decodeBleJsonString(cmd);
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
        if (colon >= 0 && q1 >= 0 && q2 > q1) pairType = decodeBleJsonString(payload.substring(q1 + 1, q2));
      }
      if (nameKey >= 0) {
        int colon = payload.indexOf(':', nameKey);
        int q1 = payload.indexOf('"', colon + 1);
        int q2 = payload.indexOf('"', q1 + 1);
        if (colon >= 0 && q1 >= 0 && q2 > q1) pairName = decodeBleJsonString(payload.substring(q1 + 1, q2));
      }
      if (zoneKey >= 0) {
        int colon = payload.indexOf(':', zoneKey);
        int q1 = payload.indexOf('"', colon + 1);
        int q2 = payload.indexOf('"', q1 + 1);
        if (colon >= 0 && q1 >= 0 && q2 > q1) pairZone = decodeBleJsonString(payload.substring(q1 + 1, q2));
      }
      if (remoteModeKey >= 0) {
        int colon = payload.indexOf(':', remoteModeKey);
        int q1 = payload.indexOf('"', colon + 1);
        int q2 = payload.indexOf('"', q1 + 1);
        if (colon >= 0 && q1 >= 0 && q2 > q1) pairRemoteMode = decodeBleJsonString(payload.substring(q1 + 1, q2));
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
      updateLcdStatus(true);
      beep(2, 80, 80);
      if (wifiTxCharacteristic) {
        wifiTxCharacteristic->setValue("PAIRING_STARTED");
        wifiTxCharacteristic->notify();
        Serial.println("[BLE] TX notify: PAIRING_STARTED");
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
        ssid = decodeBleJsonString(payload.substring(ssidQ1 + 1, ssidQ2));
      }
      if (passColon >= 0 && passQ1 >= 0 && passQ2 > passQ1) {
        password = decodeBleJsonString(payload.substring(passQ1 + 1, passQ2));
      }
    } else {
      int separator = payload.indexOf('|');
      if (separator > 0) {
        Serial.println("[BLE] Payload format detected: SSID|PASSWORD");
        ssid = payload.substring(0, separator);
        password = payload.substring(separator + 1);
      }
    }

    ssid = sanitizeBleWifiText(ssid);
    password = sanitizeBleWifiText(password);

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

    pendingWifiConnectAfterBleConfig = true;
    pendingWifiConnectAt = millis() + 1500;
    Serial.println("[BLE] WiFi connect scheduled after BLE notify");
  }
};
#endif

// -------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------
void beep(uint8_t count, uint16_t onMs = 120, uint16_t offMs = 120) {
  for (uint8_t i = 0; i < count; i++) {
    digitalWrite(BUZZER_PIN, HIGH);
    digitalWrite(AUX_BUZZER_PIN, HIGH);
    delay(onMs);
    if (currentMode == MODE_ALARM && alarmOutputsEnabled) {
      bool alarmSoundOn = settingAlarmSound && !suppressAlarmSound && !FORCE_ALARM_SOUND_OFF;
      digitalWrite(SIREN_PIN, alarmSoundOn ? HIGH : LOW);
      digitalWrite(BUZZER_PIN, alarmSoundOn ? HIGH : LOW);
      digitalWrite(AUX_BUZZER_PIN, alarmSoundOn ? HIGH : LOW);
      return;
    }
    digitalWrite(BUZZER_PIN, LOW);
    digitalWrite(AUX_BUZZER_PIN, LOW);
    delay(offMs);
  }
}

const char *pinLevelText(int state) {
  return state == HIGH ? "HIGH" : "LOW";
}

const char *pinLevelShortText(int state) {
  return state == HIGH ? "H" : "L";
}

const char *wifiStatusText(wl_status_t status) {
  switch (status) {
    case WL_IDLE_STATUS: return "IDLE";
    case WL_NO_SSID_AVAIL: return "NO_SSID";
    case WL_SCAN_COMPLETED: return "SCAN_DONE";
    case WL_CONNECTED: return "CONNECTED";
    case WL_CONNECT_FAILED: return "CONNECT_FAILED";
    case WL_CONNECTION_LOST: return "CONNECTION_LOST";
    case WL_DISCONNECTED: return "DISCONNECTED";
    default: return "UNKNOWN";
  }
}

const char *wifiDisconnectReasonText(uint8_t reason) {
  switch (reason) {
    case 2: return "AUTH_EXPIRE";
    case 8: return "ASSOC_LEAVE";
    case 4: return "ASSOC_EXPIRE";
    case 15: return "HANDSHAKE_TIMEOUT";
    case 201: return "NO_AP_FOUND";
    case 202: return "AUTH_FAIL";
    case 203: return "ASSOC_FAIL";
    case 204: return "HANDSHAKE_TIMEOUT";
    case 205: return "CONNECTION_FAIL";
    default: return "UNKNOWN";
  }
}

const char *wifiAuthText(wifi_auth_mode_t authMode) {
  switch (authMode) {
    case WIFI_AUTH_OPEN: return "OPEN";
    case WIFI_AUTH_WEP: return "WEP";
    case WIFI_AUTH_WPA_PSK: return "WPA";
    case WIFI_AUTH_WPA2_PSK: return "WPA2";
    case WIFI_AUTH_WPA_WPA2_PSK: return "WPA/WPA2";
    case WIFI_AUTH_WPA2_ENTERPRISE: return "WPA2_ENT";
    case WIFI_AUTH_WPA3_PSK: return "WPA3";
    case WIFI_AUTH_WPA2_WPA3_PSK: return "WPA2/WPA3";
    default: return "UNKNOWN";
  }
}

bool scanForProvisionedSsid() {
  Serial.printf("[WIFI] Scanning for SSID=%s\n", provisionedSsid.c_str());
  lastWifiScanChannel = 0;
  lastWifiScanHasBssid = false;
  int networkCount = WiFi.scanNetworks(false, true, false, WIFI_SCAN_MAX_MS_PER_CHANNEL);
  if (networkCount < 0) {
    Serial.printf("[WIFI] Scan failed code=%d, trying connect anyway\n", networkCount);
    return true;
  }

  bool found = false;
  int bestRssi = -127;
  wifi_auth_mode_t bestAuth = WIFI_AUTH_OPEN;
  for (int i = 0; i < networkCount; i++) {
    if (WiFi.SSID(i) == provisionedSsid) {
      found = true;
      if (WiFi.RSSI(i) <= bestRssi) {
        continue;
      }
      bestRssi = WiFi.RSSI(i);
      bestAuth = WiFi.encryptionType(i);
      lastWifiScanChannel = WiFi.channel(i);
      uint8_t *bssid = WiFi.BSSID(i);
      if (bssid != nullptr) {
        memcpy(lastWifiScanBssid, bssid, sizeof(lastWifiScanBssid));
        lastWifiScanHasBssid = true;
      }
    }
  }
  WiFi.scanDelete();

  if (!found) {
    Serial.println("[WIFI] Target SSID not visible to ESP32");
    Serial.println("[WIFI] Check 2.4GHz hotspot/router, SSID spelling, hidden SSID, and range");
  } else {
    Serial.printf("[WIFI] Best target RSSI=%d auth=%s channel=%d\n",
                  bestRssi,
                  wifiAuthText(bestAuth),
                  lastWifiScanChannel);
  }
  return found;
}

void pauseBleAdvertisingForWifiConnect() {
#if ENABLE_BLE_PROVISIONING
  if (!bleProvisioningActive) {
    return;
  }
  BLEDevice::getAdvertising()->stop();
  Serial.println("[BLE] Advertising paused for WiFi connect");
#endif
}

void resumeBleAdvertisingAfterWifiConnect() {
#if ENABLE_BLE_PROVISIONING
  if (pendingWifiConnectAfterBleConfig || WiFi.status() != WL_CONNECTED) {
    Serial.println("[BLE] Advertising resume skipped; WiFi connect/provisioning not settled");
    return;
  }
  if (!bleProvisioningActive || bleClientConnected) {
    return;
  }
  Serial.println("[BLE] Advertising resume skipped; BLE starts only on app pairing request/manual mode");
#endif
}

void handleWiFiEvent(WiFiEvent_t event, WiFiEventInfo_t info) {
  if (event == ARDUINO_EVENT_WIFI_STA_GOT_IP) {
    lastWifiDisconnectReason = 0;
    Serial.printf("[WIFI] Event GOT_IP IP=%s RSSI=%d\n",
                  WiFi.localIP().toString().c_str(),
                  WiFi.RSSI());
  } else if (event == ARDUINO_EVENT_WIFI_STA_DISCONNECTED) {
    lastWifiDisconnectReason = info.wifi_sta_disconnected.reason;
    lastWifiDisconnectAt = millis();
    if (wifiProvisioned) {
      setOfflineMode(true, wifiDisconnectReasonText(lastWifiDisconnectReason));
      lastWiFiAttemptAt = millis() - WIFI_RETRY_OFFLINE_MS + 1000;
    }
    if (lastWifiDisconnectReason != lastLoggedWifiDisconnectReason ||
        millis() - lastLoggedWifiDisconnectAt > 10000) {
      lastLoggedWifiDisconnectReason = lastWifiDisconnectReason;
      lastLoggedWifiDisconnectAt = millis();
      Serial.printf("[WIFI] Event DISCONNECTED reason=%u (%s)\n",
                    lastWifiDisconnectReason,
                    wifiDisconnectReasonText(lastWifiDisconnectReason));
    }
  }
}

void logOutputPinStates(bool force = false) {
  int buzzerState = digitalRead(BUZZER_PIN);
  int auxBuzzerState = digitalRead(AUX_BUZZER_PIN);
  int sirenState = digitalRead(SIREN_PIN);
  unsigned long now = millis();

  bool changed = buzzerState != lastLoggedBuzzerState ||
                 auxBuzzerState != lastLoggedAuxBuzzerState ||
                 sirenState != lastLoggedSirenState;

  if (!force && !changed && now - lastOutputPinLogAt < OUTPUT_PIN_LOG_INTERVAL_MS) {
    return;
  }

  lastOutputPinLogAt = now;
  lastLoggedBuzzerState = buzzerState;
  lastLoggedAuxBuzzerState = auxBuzzerState;
  lastLoggedSirenState = sirenState;

  Serial.printf("[OUTPUT] BUZZER GPIO%d=%s, BUZZER1 GPIO%d=%s, SIREN GPIO%d=%s\n",
                BUZZER_PIN, pinLevelText(buzzerState),
                AUX_BUZZER_PIN, pinLevelText(auxBuzzerState),
                SIREN_PIN, pinLevelText(sirenState));
}

const char *modeText() {
  switch (currentMode) {
    case MODE_ARMED:
      return "ARMED";
    case MODE_STAY_ARM:
      return "STAY";
    case MODE_ALARM:
      return "ALARM";
    case MODE_DISARMED:
    default:
      return "DISARMED";
  }
}

const char *armDisplayText() {
  switch (currentMode) {
    case MODE_ARMED:
      return "ARMED";
    case MODE_STAY_ARM:
      return "STAY ARM";
    case MODE_ALARM:
      return "ALARM";
    case MODE_DISARMED:
    default:
      return "DISARMED";
  }
}

String networkText() {
  if (bleProvisioningActive && !bleClientConnected) {
    return "BLE ON";
  }
  if (bleClientConnected) {
    return "BLE CONN";
  }
  if (WiFi.status() == WL_CONNECTED) {
    return "WIFI OK";
  }
  if (offlineMode) {
    return "OFFLINE";
  }
  if (wifiProvisioned) {
    return "WIFI TRY";
  }
  return "BLE SETUP";
}

const char *gsmDisplayText() {
  if (!ENABLE_GSM_FEATURES) {
    return "DISABLED";
  }
  return gsmNetworkOnline ? "ONLINE" : "OFFLINE";
}

String dateTimeDisplayText() {
  struct tm timeInfo;
  if (getLocalTime(&timeInfo, 50) && timeInfo.tm_year >= 124) {
    char buffer[17];
    snprintf(buffer, sizeof(buffer), "D:%02d-%02d T:%02d:%02d",
             timeInfo.tm_mday,
             timeInfo.tm_mon + 1,
             timeInfo.tm_hour,
             timeInfo.tm_min);
    return String(buffer);
  }

  return String("D:-- -- T:--:--");
}

String fitLcdLine(const String &text) {
  String line = text;
  if (line.length() > LCD_COLUMNS) {
    line.remove(LCD_COLUMNS);
  }
  while (line.length() < LCD_COLUMNS) {
    line += ' ';
  }
  return line;
}

bool lcdWriteExpander(uint8_t data) {
  Wire.beginTransmission(activeLcdAddress);
  Wire.write(lcdBacklightEnabled ? (data | LCD_BACKLIGHT_BIT) : (data & ~LCD_BACKLIGHT_BIT));
  byte error = Wire.endTransmission();
  if (error != 0) {
    lcdReady = false;
    Serial.printf("[LCD] I2C write failed err=%u; LCD disabled so app/system keeps running\n", error);
    return false;
  }
  return true;
}

bool lcdPulseEnable(uint8_t data) {
  if (!lcdWriteExpander(data | 0x04)) return false;
  delayMicroseconds(1);
  if (!lcdWriteExpander(data & ~0x04)) return false;
  delayMicroseconds(50);
  return true;
}

bool lcdWrite4Bits(uint8_t value) {
  if (!lcdWriteExpander(value)) return false;
  return lcdPulseEnable(value);
}

bool lcdSend(uint8_t value, uint8_t mode) {
  uint8_t highNibble = value & 0xF0;
  uint8_t lowNibble = (value << 4) & 0xF0;
  if (!lcdWrite4Bits(highNibble | mode)) return false;
  return lcdWrite4Bits(lowNibble | mode);
}

void lcdCommand(uint8_t value) {
  if (!lcdReady) return;
  lcdSend(value, 0);
}

void lcdWriteChar(char value) {
  if (!lcdReady) return;
  lcdSend(static_cast<uint8_t>(value), 0x01);
}

void lcdClearDisplay() {
  if (!lcdReady) {
    return;
  }
  lcdCommand(0x01);
  delay(2);
}

void lcdSetCursor(uint8_t column, uint8_t row) {
  static const uint8_t rowOffsets[] = {0x00, 0x40, 0x10, 0x50};
  if (row >= LCD_ROWS) {
    row = 0;
  }
  lcdCommand(0x80 | (column + rowOffsets[row]));
}

bool lcdBeginNative() {
  delay(50);
  if (!lcdWrite4Bits(0x30)) return false;
  delayMicroseconds(4500);
  if (!lcdWrite4Bits(0x30)) return false;
  delayMicroseconds(4500);
  if (!lcdWrite4Bits(0x30)) return false;
  delayMicroseconds(150);
  if (!lcdWrite4Bits(0x20)) return false;

  lcdCommand(0x28);
  lcdCommand(0x0C);
  lcdCommand(0x06);
  lcdCommand(0x01);
  delay(2);
  return lcdReady;
}

void lcdPrintLine(uint8_t row, const String &text) {
  if (!lcdReady || row >= LCD_ROWS) {
    return;
  }
  lcdSetCursor(0, row);
  String line = fitLcdLine(text);
  for (uint8_t i = 0; i < line.length(); i++) {
    lcdWriteChar(line[i]);
  }
}

void updateLcdStatus(bool force = false) {
  if (!lcdReady) {
    return;
  }

  unsigned long now = millis();
  if (!force && now - lastLcdUpdateAt < LCD_UPDATE_INTERVAL_MS) {
    return;
  }
  lastLcdUpdateAt = now;

  if (rfPairingActive) {
    lcdPrintLine(0, "PAIRING MODE");
    lcdPrintLine(1, "BLE ON - APP OK");
    lcdPrintLine(2, "PRESS RF SENSOR");
    lcdPrintLine(3, "WAITING SIGNAL...");
    return;
  }

  char line[21];
  snprintf(line, sizeof(line), "ALARM  BAT:%3u%%", readBatteryPercentage());
  lcdPrintLine(0, line);
  lcdPrintLine(1, "> ARM: " + String(armDisplayText()));
  lcdPrintLine(2, "GSM : " + String(gsmDisplayText()));
  lcdPrintLine(3, dateTimeDisplayText());
}


void beepTouchFeedback() {
  if (FORCE_ALARM_SOUND_OFF) return;
  if (currentMode == MODE_ALARM) return;

  beep(1, TOUCH_BEEP_MS, 0);
}


void beepSensorTrigger() {
  if (!BEEP_ON_SENSOR_TRIGGER) return;
  if (FORCE_ALARM_SOUND_OFF) return;

  // Short audible feedback right when a sensor triggers.
  beep(SENSOR_TRIGGER_BEEP_COUNT, SENSOR_TRIGGER_BEEP_MS, 80);
}

void setAlarmOutputs(bool on) {
  alarmOutputsEnabled = on;
  bool alarmSoundOn = on && currentMode == MODE_ALARM && settingAlarmSound && !suppressAlarmSound && !FORCE_ALARM_SOUND_OFF;
  if (alarmSoundOn) {
    WiFi.setSleep(false);
  }
  digitalWrite(SIREN_PIN, alarmSoundOn ? HIGH : LOW);
  digitalWrite(BUZZER_PIN, alarmSoundOn ? HIGH : LOW);
  digitalWrite(AUX_BUZZER_PIN, alarmSoundOn ? HIGH : LOW);
  logOutputPinStates(true);
  updateLcdStatus(true);
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
  digitalWrite(AUX_BUZZER_PIN, HIGH);
  delay(35);
  digitalWrite(BUZZER_PIN, LOW);
  digitalWrite(AUX_BUZZER_PIN, LOW);
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

void updateServerPairingStatus(const String &status, uint32_t rfCode = 0) {
  if (rfPairingId.length() == 0 || rfPairingId == "0") {
    return;
  }
  if (!allowServerRequests()) {
    Serial.printf("[PAIR] Server status update skipped; offline status=%s\n", status.c_str());
    return;
  }

  HTTPClient http;
  http.setTimeout(2500);
  http.begin(PAIRING_STATUS_URL);
  prepareHttpRequest(http);
  http.addHeader("Content-Type", "application/json");

  String payload = "{\"pairing_id\":" + rfPairingId +
                   ",\"status\":\"" + status + "\"";
  if (rfCode != 0) {
    payload += ",\"accessory_uuid\":\"" + String(rfCode) +
               "\",\"device_ble_name\":\"" + jsonEscape(rfPairName) + "\"";
  }
  payload += "}";

  int httpStatus = http.POST(payload);
  String body = http.getString();
  http.end();
  Serial.printf("[PAIR] Server status=%s HTTP=%d body=%s\n",
                status.c_str(),
                httpStatus,
                body.c_str());
  if (httpStatus == 200) {
    noteServerOk();
  } else {
    noteServerFail("pairing_status", httpStatus);
  }
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

void scheduleBleStopAfterPairing() {
  stopBleAfterPairingAt = millis() + 3000UL;
}

void serviceBleStopAfterPairing() {
  if (stopBleAfterPairingAt == 0 || millis() < stopBleAfterPairingAt) {
    return;
  }
  stopBleAfterPairingAt = 0;
  if (!rfPairingActive) {
    stopBleProvisioning();
  }
}

void startServerRequestedPairing(const String &body) {
  long pairingId = extractJsonIntValue(body, "pairing_id", -1);
  if (pairingId >= 0 &&
      pairingId == locallyCompletedPairingRequestId &&
      millis() < locallyCompletedPairingIgnoreUntil) {
    Serial.printf("[PAIR] Ignoring already captured pairing request id=%ld; waiting server/app to clear it\n", pairingId);
    return;
  }
  if (rfPairingActive) {
    Serial.printf("[PAIR] Pairing already active, ignoring new request id=%ld\n", pairingId);
    return;
  }
  bool repeatedRequest = pairingId >= 0 && pairingId == lastServerPairingRequestId;

  String pairType = extractJsonStringValue(body, "accessory_type");
  String pairName = extractJsonStringValue(body, "accessory_name");
  String pairZone = extractJsonStringValue(body, "zone_name");
  String remoteMode = extractJsonStringValue(body, "remote_mode");

  rfPairingActive = true;
  rfPairType = pairType.length() ? pairType : "door";
  rfPairName = pairName.length() ? pairName : rfPairType;
  rfPairZone = pairZone.length() ? pairZone : "General";
  rfPairRemoteMode = remoteMode;
  rfPairingId = pairingId >= 0 ? String(pairingId) : "0";
  rfPairingStartedAt = millis();
  lastServerPairingRequestId = pairingId;
  stopBleAfterPairingAt = 0;

  startBleProvisioning();
  Serial.printf("[RF] Server pairing request id=%s type=%s name=%s zone=%s; BLE enabled%s\n",
                rfPairingId.c_str(), rfPairType.c_str(), rfPairName.c_str(), rfPairZone.c_str(),
                repeatedRequest ? " (restarted)" : "");
  updateLcdStatus(true);
  beep(2, 80, 80);
}

void pollPairingRequestIfDue() {
  if (rfPairingActive) {
    if (!bleProvisioningActive) {
      Serial.println("[PAIR] Pairing active but BLE is OFF; restarting BLE advertising");
      startBleProvisioning();
    }
    return;
  }
  if (!allowServerRequests()) {
    return;
  }
  unsigned long now = millis();
  if (now - lastPairingRequestPollAt < PAIRING_REQUEST_POLL_MS) {
    return;
  }
  lastPairingRequestPollAt = now;

  bool requestFound = false;
  String candidates[2];
  uint8_t candidateCount = 0;
  if (settingHubLanguage.length() > 0) {
    candidates[candidateCount++] = settingHubLanguage;
  }
  String baseUuid = deviceUuid();
  if (candidateCount == 0 || baseUuid != candidates[0]) {
    candidates[candidateCount++] = baseUuid;
  }

  for (uint8_t i = 0; i < candidateCount; i++) {
    HTTPClient http;
    http.setTimeout(2500);
    String url = String(PAIRING_REQUEST_URL) + urlEncode(candidates[i]);
    http.begin(url);
    prepareHttpRequest(http);
    int status = http.GET();
    String body = http.getString();
    http.end();

    if (status == 200) {
      noteServerOk();
      if (extractJsonBoolValue(body, "has_request", false)) {
        long pairingId = extractJsonIntValue(body, "pairing_id", -1);
        if (pairingId >= 0 &&
            pairingId == locallyCompletedPairingRequestId &&
            millis() < locallyCompletedPairingIgnoreUntil) {
          Serial.printf("[PAIR] Ignoring already completed pairing request id=%ld (waiting for server to clear)\n", pairingId);
          continue;
        }
        Serial.printf("[PAIR] Server request body for uuid=%s: %s\n", candidates[i].c_str(), body.c_str());
        startServerRequestedPairing(body);
        requestFound = true;
        break;
      }
    } else {
      Serial.printf("[PAIR] Request poll failed HTTP=%d url=%s\n", status, url.c_str());
      noteServerFail("pairing_request", status);
    }
  }

  if (!requestFound && now - lastPairingNoRequestLogAt > 15000UL) {
    lastPairingNoRequestLogAt = now;
    Serial.printf("[PAIR] No server pairing request for uuid=%s%s%s\n",
                  candidates[0].c_str(),
                  candidateCount > 1 ? "/" : "",
                  candidateCount > 1 ? candidates[1].c_str() : "");
  }
}

void updateModeIndicatorLeds() {
  digitalWrite(ARM_INDICATOR_PIN, (currentMode == MODE_ARMED || currentMode == MODE_STAY_ARM || currentMode == MODE_ALARM) ? HIGH : LOW);
  digitalWrite(DISARM_INDICATOR_PIN, currentMode == MODE_DISARMED ? HIGH : LOW);
}

void startManualRfPairingMode() {
  startBleProvisioning();
  rfPairingActive = true;
  rfPairType = "door";
  rfPairName = "MANUAL RF SENSOR";
  rfPairZone = "General";
  rfPairRemoteMode = "";
  rfPairingId = "0";
  rfPairingStartedAt = millis();
  Serial.println("[RF] Manual pairing mode started from RF_M long press; BLE advertising enabled for app pairing");
  updateLcdStatus(true);
  beep(2, 120, 120);
}

uint8_t readBatteryPercentage() {
  float batteryVoltage = readBatteryVoltage();
  int percentage = static_cast<int>(((batteryVoltage - BATTERY_EMPTY_VOLTAGE) /
                                     (BATTERY_FULL_VOLTAGE - BATTERY_EMPTY_VOLTAGE)) * 100.0f);
  percentage += BATTERY_PERCENT_OFFSET;
  if (percentage < 0) percentage = 0;
  if (percentage > 100) percentage = 100;
  return static_cast<uint8_t>(percentage);
}

float readBatteryVoltage() {
  uint32_t totalRaw = 0;
  const uint8_t samples = 16;
  for (uint8_t i = 0; i < samples; i++) {
    totalRaw += analogRead(BAT_SENSE_PIN);
    delayMicroseconds(200);
  }
  float raw = totalRaw / static_cast<float>(samples);
  float adcVoltage = (raw / 4095.0f) * BATTERY_ADC_REF_VOLTAGE;
  return adcVoltage * BATTERY_DIVIDER_RATIO;
}

void pollPowerAndBatterySense() {
  int powerState = digitalRead(PWR_SENSE_PIN);
  if (powerState != lastPowerSenseState) {
  lastPowerSenseState = powerState;
    Serial.printf("[POWER] External power %s\n", powerState == HIGH ? "PRESENT" : "LOST");
    updateLcdStatus(true);
  }

  if (millis() - lastBatteryLogAt > BATTERY_LOG_INTERVAL_MS) {
    lastBatteryLogAt = millis();
    float batteryVoltage = readBatteryVoltage();
    uint8_t batteryPercent = readBatteryPercentage();
    Serial.printf("[BATTERY] %.2fV %u%%\n", batteryVoltage, batteryPercent);
    if (settingSensorLowBatteryNotification &&
        batteryPercent <= PANEL_LOW_BATTERY_PERCENT &&
        (lastPanelLowBatteryNotifyAt == 0 ||
         millis() - lastPanelLowBatteryNotifyAt > PANEL_LOW_BATTERY_NOTIFY_INTERVAL_MS)) {
      lastPanelLowBatteryNotifyAt = millis();
      sendAlarmEvent("PANEL_LOW_BATTERY", "PANEL", "PANEL BATTERY LOW " + String(batteryPercent) + "%");
    }
    updateLcdStatus(true);
  }
}

void handleMicRecordButtonPress() {
  Serial.println("[MIC] Recording start requested");
  beep(1, 80, 60);
}

bool notifyServerFirmwareFactoryReset() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[FW_RESET] Server cleanup skipped; WiFi not connected");
    return false;
  }

  HTTPClient http;
  http.setTimeout(8000);
  http.begin(FIRMWARE_RESET_URL);
  prepareHttpRequest(http);
  http.addHeader("Content-Type", "application/json");

  String payload = "{";
  payload += "\"device_uuid\":\"" + jsonEscape(deviceUuid()) + "\",";
  payload += "\"device_name\":\"" + jsonEscape(deviceName()) + "\",";
  payload += "\"mac_address\":\"" + jsonEscape(WiFi.macAddress()) + "\",";
  payload += "\"hub_language\":\"" + jsonEscape(settingHubLanguage) + "\",";
  payload += "\"reason\":\"firmware_reset_button_5s\"";
  payload += "}";

  Serial.printf("[FW_RESET] POST %s\n", FIRMWARE_RESET_URL);
  int status = http.POST(payload);
  String body = http.getString();
  Serial.printf("[FW_RESET] Server cleanup status=%d body=%s\n", status, body.c_str());
  http.end();

  bool success = (status == 200) &&
                 body.indexOf("\"success\":false") < 0 &&
                 body.indexOf("\"success\": false") < 0;
  if (success) {
    noteServerOk();
  } else {
    noteServerFail("firmware_factory_reset", status);
  }
  return success;
}

void setPendingServerFactoryResetCleanup(bool pending) {
  prefs.begin(PREF_NAMESPACE, false);
  prefs.putBool(PREF_PENDING_FW_CLEAN, pending);
  prefs.end();
  pendingServerFactoryResetCleanup = pending;
  Serial.printf("[FW_RESET] Pending server cleanup=%s\n", pending ? "YES" : "NO");
}

void servicePendingServerFactoryResetCleanup() {
  if (!pendingServerFactoryResetCleanup) {
    return;
  }
  if (WiFi.status() != WL_CONNECTED || !allowServerRequests()) {
    return;
  }
  Serial.println("[FW_RESET] Running pending server cleanup before register");
  if (notifyServerFirmwareFactoryReset()) {
    setPendingServerFactoryResetCleanup(false);
  } else {
    Serial.println("[FW_RESET] Pending cleanup failed; will retry before next register");
  }
}

void handleFirmwareResetButtonPress() {
  Serial.println("[FW_RESET] Factory reset requested");
  Serial.println("[FW_RESET] Erasing server users/admins plus local WiFi, sensors, contacts, settings");
  lcdPrintLine(0, "FACTORY RESET      ");
  lcdPrintLine(1, "SERVER CLEANUP...  ");
  lcdPrintLine(2, "PLEASE WAIT...     ");
  lcdPrintLine(3, "                    ");
  beep(2, 120, 80);
  bool serverCleaned = notifyServerFirmwareFactoryReset();
  lcdPrintLine(1, "ERASING LOCAL DATA ");
  clearAllStoredData();
  if (!serverCleaned) {
    setPendingServerFactoryResetCleanup(true);
  }
  delay(500);
  Serial.println("[FW_RESET] Erase complete, restarting");
  ESP.restart();
}

void pollBoardButtons() {
  int micState = digitalRead(MIC_REC_PIN);
  int fwState = digitalRead(FW_RESET_PIN);
  int rfState = digitalRead(RF_PAIR_BUTTON_PIN);

  if (lastMicRecButtonState == HIGH && micState == LOW) {
    delay(BUTTON_DEBOUNCE_MS);
    if (digitalRead(MIC_REC_PIN) == LOW) {
      handleMicRecordButtonPress();
    }
  }

  if (lastFwResetButtonState == HIGH && fwState == LOW) {
    delay(BUTTON_DEBOUNCE_MS);
    if (digitalRead(FW_RESET_PIN) == LOW) {
      fwResetButtonPressedAt = millis();
      fwResetLongPressHandled = false;
      Serial.println("[FW_RESET] Hold button for 5 seconds to factory reset");
    }
  } else if (fwState == LOW && !fwResetLongPressHandled &&
             fwResetButtonPressedAt > 0 &&
             millis() - fwResetButtonPressedAt >= FW_RESET_HOLD_MS) {
    fwResetLongPressHandled = true;
    handleFirmwareResetButtonPress();
  } else if (fwState == HIGH) {
    fwResetButtonPressedAt = 0;
    fwResetLongPressHandled = false;
  }

  if (lastRfPairButtonState == HIGH && rfState == LOW) {
    rfPairButtonPressedAt = millis();
    rfPairLongPressHandled = false;
  } else if (rfState == LOW && !rfPairLongPressHandled &&
             rfPairButtonPressedAt > 0 &&
             millis() - rfPairButtonPressedAt >= RF_PAIR_LONG_PRESS_MS) {
    rfPairLongPressHandled = true;
    startManualRfPairingMode();
  } else if (rfState == HIGH) {
    rfPairButtonPressedAt = 0;
    rfPairLongPressHandled = false;
  }

  lastMicRecButtonState = micState;
  lastFwResetButtonState = fwState;
  lastRfPairButtonState = rfState;
}

const char *rfTypeToString(RfType type) {
  switch (type) {
    case RF_TYPE_DOOR: return "door";
    case RF_TYPE_REMOTE_ARM: return "remote_arm";
    case RF_TYPE_REMOTE_DISARM: return "remote_disarm";
    case RF_TYPE_PANIC: return "panic";
    case RF_TYPE_MOTION: return "motion";
    case RF_TYPE_TAMPER: return "tamper";
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
  if (value == "tamper") return RF_TYPE_TAMPER;
  return RF_TYPE_NONE;
}

RfType resolvePairingRfType(String pairType, String pairRemoteMode, String pairZone, String pairName) {
  pairType.trim();
  pairRemoteMode.trim();
  pairZone.trim();
  pairName.trim();
  pairType.toLowerCase();
  pairRemoteMode.toLowerCase();
  pairZone.toLowerCase();
  pairName.toLowerCase();

  if (pairType == "remote") {
    if (pairRemoteMode == "disarm" || pairRemoteMode == "disarmed" ||
        pairZone == "disarm" || pairName == "disarm" || pairName == "disarmed") {
      return RF_TYPE_REMOTE_DISARM;
    }
    if (pairRemoteMode == "arm" || pairRemoteMode == "armed" ||
        pairZone == "arm" || pairName == "arm" || pairName == "armed") {
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
  RfType type = resolvePairingRfType(pairType, pairRemoteMode, pairZone, pairName);

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
  pendingServerFactoryResetCleanup = prefs.getBool(PREF_PENDING_FW_CLEAN, false);
  prefs.end();
  wifiProvisioned = provisionedSsid.length() > 0;
  Serial.printf("[WIFI] Stored SSID present=%s\n", wifiProvisioned ? "YES" : "NO");
  if (pendingServerFactoryResetCleanup) {
    Serial.println("[FW_RESET] Pending server cleanup loaded from NVS");
  }
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
  cachedSettingsJson = "";
  clearContactNumbers();
  learnedRfItemCount = 0;
  memset(learnedRfItems, 0, sizeof(learnedRfItems));
  clearRfPairingRequest();
  locallyCompletedPairingRequestId = -1;
  locallyCompletedPairingIgnoreUntil = 0;
  lastServerPairingRequestId = -1;
  settingExitDelaySeconds = 0;
  settingEntryDelaySeconds = 0;
  settingAlarmDurationMinutes = 3;
  settingAlarmSound = true;
  settingAlarmNotification = true;
  settingCountdownWithTickTone = true;
  settingArmDisarmNotification = true;
  settingTamperAlarm = true;
  settingSensorLowBatteryNotification = true;
  settingAlarmCall = false;
  settingAlarmSms = false;
  settingUnansweredPhoneRedialTimes = 1;
  settingVirtualPassword = "";
  settingHubLanguage = "";
  Serial.println("[BOOT] Local WiFi, RF sensors/remotes, contacts, and settings cleared");
}

void prepareWiFiForBleCoexistence() {
  if (WiFi.status() == WL_CONNECTED) {
    WiFi.setSleep(true);
    delay(50);
    Serial.println("[BLE] WiFi modem sleep enabled for BLE coexistence");
  }
}

void restoreWiFiAfterBleCoexistence() {
  if (WiFi.status() == WL_CONNECTED) {
    WiFi.setSleep(false);
    WiFi.setTxPower(WIFI_POWER_19_5dBm);
    Serial.println("[BLE] WiFi modem sleep disabled after BLE stop");
  }
}

void startBleProvisioning() {
#if !ENABLE_BLE_PROVISIONING
  Serial.println("[BLE] Provisioning disabled in build");
  return;
#else
  prepareWiFiForBleCoexistence();

  if (bleProvisioningActive) {
    BLEDevice::getAdvertising()->start();
    bleProvisioningStartedAt = millis();
    Serial.printf("[BLE] Advertising already active, republishing %s for %lu ms\n",
                  BLE_DEVICE_NAME, BLE_BOOT_ADVERTISING_MS);
    return;
  }

  Serial.printf("[BLE] Starting provisioning mode, publishing device %s\n", BLE_DEVICE_NAME);
  BLEDevice::init(BLE_DEVICE_NAME);
  BLEDevice::setPower(ESP_PWR_LVL_P9);
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
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMaxPreferred(0x12);
  advertising->start();

  bleProvisioningActive = true;
  bleProvisioningStartedAt = millis();
  Serial.printf("[BLE] Advertising started: name=%s service=%s duration=%lu ms\n",
                BLE_DEVICE_NAME, BLE_SERVICE_UUID, BLE_BOOT_ADVERTISING_MS);
  updateLcdStatus(true);
#endif
}

void stopBleProvisioning() {
#if !ENABLE_BLE_PROVISIONING
  bleProvisioningActive = false;
  return;
#else
  if (!bleProvisioningActive) {
    return;
  }
  bleProvisioningActive = false;
  bleProvisioningStartedAt = 0;
  bleClientConnected = false;
  BLEDevice::getAdvertising()->stop();
  BLEDevice::deinit(false);
  Serial.println("[BLE] Provisioning stopped");
  updateLcdStatus(true);
  restoreWiFiAfterBleCoexistence();
#endif
}

void serviceBleBootAdvertisingWindow() {
#if ENABLE_BLE_PROVISIONING
  if (BLE_BOOT_ADVERTISING_MS == 0) {
    return;
  }
  if (!START_BLE_PROVISIONING_ON_BOOT) {
    return;
  }
  if (!bleProvisioningActive || bleClientConnected || rfPairingActive || bleProvisioningStartedAt == 0) {
    return;
  }
  if (millis() - bleProvisioningStartedAt >= BLE_BOOT_ADVERTISING_MS) {
    Serial.println("[BLE] Boot advertising window ended");
    stopBleProvisioning();
  }
#endif
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

String urlEncode(const String &value) {
  const char *hex = "0123456789ABCDEF";
  String out;
  for (size_t i = 0; i < value.length(); i++) {
    uint8_t c = static_cast<uint8_t>(value[i]);
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
        c == '-' || c == '_' || c == '.' || c == '~') {
      out += static_cast<char>(c);
    } else {
      out += '%';
      out += hex[(c >> 4) & 0x0F];
      out += hex[c & 0x0F];
    }
  }
  return out;
}

String deviceUuid() {
  return WiFi.macAddress();
}

String deviceName() {
  return String(BLE_DEVICE_NAME);
}

String systemStateDeviceUuid() {
  String uuid = settingHubLanguage;
  uuid.trim();
  return uuid.length() > 0 ? uuid : deviceUuid();
}

void appendCleanAtChar(String &out, int byteValue) {
  if (byteValue < 0 || out.length() >= 512) {
    return;
  }
  char c = static_cast<char>(byteValue);
  if (c == '\b' || c == 0x7F) {
    return;
  }
  if (c == '\r' || c == '\n' || c == '\t' || (c >= 32 && c <= 126)) {
    out += c;
  }
}

void yieldToSystem(uint32_t delayMs = 1) {
  delay(delayMs);
  yield();
}

String readAtResponse(uint32_t timeoutMs = 1000) {
  String out;
  unsigned long start = millis();
  while (millis() - start < timeoutMs) {
    while (SerialAT.available()) {
      appendCleanAtChar(out, SerialAT.read());
    }
    yieldToSystem(2);
  }
  out.trim();
  return out;
}
String queryAt(const char *command, uint32_t timeoutMs = 1000) {
  while (SerialAT.available()) {
    SerialAT.read();
  }
  SerialAT.println(command);

  String out;
  unsigned long start = millis();
  while (millis() - start < timeoutMs) {
    while (SerialAT.available()) {
      appendCleanAtChar(out, SerialAT.read());
    }

    // Stop early when the modem finished replying.
    if (out.endsWith("OK") || out.indexOf("\nOK") >= 0) {
      break;
    }
    if (out.indexOf("ERROR") >= 0) {
      break;
    }
    yieldToSystem(2);
  }
  out.trim();
  return out;
}

String readAtFinalResponse(uint32_t timeoutMs) {
  String out;
  unsigned long start = millis();
  while (millis() - start < timeoutMs) {
    while (SerialAT.available()) {
      appendCleanAtChar(out, SerialAT.read());
    }
    if (out.indexOf("+CMGS:") >= 0 || out.indexOf("+CMS ERROR") >= 0 ||
        out.indexOf("\nOK") >= 0 || out.endsWith("OK") ||
        out.indexOf("ERROR") >= 0) {
      break;
    }
    yieldToSystem(5);
  }
  out.trim();
  return out;
}

bool systemTimeIsValid() {
  struct tm timeInfo;
  return getLocalTime(&timeInfo, 50) && timeInfo.tm_year >= 124;
}

void configureTimeFromWifi() {
  setenv("TZ", "IST-5:30", 1);
  tzset();
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");
  timeConfigured = true;
  lastTimeSyncAttemptAt = millis();
  Serial.println("[TIME] NTP configured for IST");
}

bool setSystemTimeFromGsmClock() {
  if (!ENABLE_GSM_FEATURES) {
    return false;
  }

  String response = queryAt("AT+CCLK?", 2000);
  int quoteStart = response.indexOf('"');
  int quoteEnd = response.indexOf('"', quoteStart + 1);
  if (quoteStart < 0 || quoteEnd <= quoteStart) {
    Serial.printf("[TIME] GSM CCLK missing: %s\n", response.c_str());
    return false;
  }

  String clockText = response.substring(quoteStart + 1, quoteEnd);
  if (clockText.length() < 17) {
    Serial.printf("[TIME] GSM CCLK invalid: %s\n", clockText.c_str());
    return false;
  }

  int year = clockText.substring(0, 2).toInt();
  int month = clockText.substring(3, 5).toInt();
  int day = clockText.substring(6, 8).toInt();
  int hour = clockText.substring(9, 11).toInt();
  int minute = clockText.substring(12, 14).toInt();
  int second = clockText.substring(15, 17).toInt();

  if (year < 24 || month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) {
    Serial.printf("[TIME] GSM CCLK out of range: %s\n", clockText.c_str());
    return false;
  }

  setenv("TZ", "IST-5:30", 1);
  tzset();

  struct tm timeInfo;
  memset(&timeInfo, 0, sizeof(timeInfo));
  timeInfo.tm_year = 2000 + year - 1900;
  timeInfo.tm_mon = month - 1;
  timeInfo.tm_mday = day;
  timeInfo.tm_hour = hour;
  timeInfo.tm_min = minute;
  timeInfo.tm_sec = second;
  timeInfo.tm_isdst = 0;

  time_t epoch = mktime(&timeInfo);
  if (epoch <= 0) {
    Serial.printf("[TIME] GSM CCLK mktime failed: %s\n", clockText.c_str());
    return false;
  }

  timeval now = {epoch, 0};
  settimeofday(&now, nullptr);
  timeConfigured = true;
  lastTimeSyncAttemptAt = millis();
  Serial.printf("[TIME] Set from GSM CCLK: %s\n", clockText.c_str());
  updateLcdStatus(true);
  return true;
}

void syncTimeIfDue() {
  if (systemTimeIsValid()) {
    return;
  }
  if (millis() - lastTimeSyncAttemptAt < TIME_SYNC_RETRY_MS) {
    return;
  }
  lastTimeSyncAttemptAt = millis();

  if (WiFi.status() == WL_CONNECTED) {
    configureTimeFromWifi();
    return;
  }

  setSystemTimeFromGsmClock();
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

String extractAtLine(const String &response, const char *prefix) {
  if (!prefix || !prefix[0]) return String();
  int pos = response.indexOf(prefix);
  if (pos < 0) return String();
  int end = response.indexOf('\n', pos);
  if (end < 0) end = response.length();
  String line = response.substring(pos, end);
  line.trim();
  return line;
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
  int cregStat = parseRegState(extractAtLine(queryAt("AT+CREG?", 1500), "+CREG:"));
  int cgregStat = parseRegState(extractAtLine(queryAt("AT+CGREG?", 1500), "+CGREG:"));
  int ceregStat = parseRegState(extractAtLine(queryAt("AT+CEREG?", 1500), "+CEREG:"));
  return isSmsRegistrationState(cregStat) || isSmsRegistrationState(cgregStat) || isSmsRegistrationState(ceregStat);
}

bool voiceServiceReady() {
  int cregStat = parseRegState(extractAtLine(queryAt("AT+CREG?", 1500), "+CREG:"));
  int ceregStat = parseRegState(extractAtLine(queryAt("AT+CEREG?", 1500), "+CEREG:"));
  return isVoiceRegistrationState(cregStat) || isVoiceRegistrationState(ceregStat);
}

void logGsmDiagnostics() {
  String cpin = extractAtLine(queryAt("AT+CPIN?", 1500), "+CPIN:");
  String creg = extractAtLine(queryAt("AT+CREG?", 1500), "+CREG:");
  String cgreg = extractAtLine(queryAt("AT+CGREG?", 1500), "+CGREG:");
  String cereg = extractAtLine(queryAt("AT+CEREG?", 1500), "+CEREG:");
  String cops = extractAtLine(queryAt("AT+COPS?", 2000), "+COPS:");
  String csq = extractAtLine(queryAt("AT+CSQ", 1500), "+CSQ:");
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
  String creg = extractAtLine(queryAt("AT+CREG?", 1500), "+CREG:");
  String cgreg = extractAtLine(queryAt("AT+CGREG?", 1500), "+CGREG:");
  String cereg = extractAtLine(queryAt("AT+CEREG?", 1500), "+CEREG:");
  String cops = extractAtLine(queryAt("AT+COPS?", 2000), "+COPS:");
  int signal = modem.getSignalQuality();
  bool netConnected = modem.isNetworkConnected();
  gsmNetworkOnline = netConnected || gsmLooksUsable();

  Serial.printf("[MODEM] isNetworkConnected=%s\n", netConnected ? "YES" : "NO");
  Serial.printf("[MODEM] Signal quality=%d\n", signal);
  Serial.printf("[MODEM] CREG=%s\n", creg.c_str());
  Serial.printf("[MODEM] CGREG=%s\n", cgreg.c_str());
  Serial.printf("[MODEM] CEREG=%s\n", cereg.c_str());
  Serial.printf("[MODEM] COPS=%s\n", cops.c_str());
}

bool gsmLooksUsable() {
  int signal = modem.getSignalQuality();
  String cops = extractAtLine(queryAt("AT+COPS?", 2000), "+COPS:");
  return smsServiceReady() || voiceServiceReady() || (signal > 0 && signal != 99) || cops.indexOf("+COPS:") >= 0;
}

bool waitForGsmAtOk(unsigned long totalWaitMs) {
  Serial.println("[MODEM] Waiting for AT");
  unsigned long waitStart = millis();
  while (millis() - waitStart < totalWaitMs) {
    String response = queryAt("AT", 1000);
    if (response.indexOf("OK") >= 0) {
      Serial.println("[MODEM] AT OK");
      return true;
    }
    Serial.printf("[MODEM] AT retry, response=%s\n", response.c_str());
    delay(500);
  }
  Serial.printf("[MODEM] AT not responding on RX=GPIO%d TX=GPIO%d baud=%d\n", MODEM_RX, MODEM_TX, MODEM_BAUD);
  return false;
}

bool waitForGsmAtOkFixedBaud(unsigned long totalWaitMs) {
  Serial.printf("[MODEM] Opening UART RX=GPIO%d TX=GPIO%d fixed baud=%d\n",
                MODEM_RX, MODEM_TX, MODEM_BAUD);
  SerialAT.end();
  delay(150);
  SerialAT.setRxBufferSize(1024);
  SerialAT.begin(MODEM_BAUD, SERIAL_8N1, MODEM_RX, MODEM_TX);
  delay(500);

  unsigned long waitStart = millis();
  while (millis() - waitStart < totalWaitMs) {
    while (SerialAT.available()) SerialAT.read();
    SerialAT.print("AT\r\n");
    String response = readAtResponse(800);
    if (response.indexOf("OK") >= 0) {
      activeModemBaud = MODEM_BAUD;
      modemAtOnline = true;
      Serial.printf("[MODEM] AT OK at fixed baud=%d\n", MODEM_BAUD);
      return true;
    }
    delay(300);
  }
  return false;
}

bool connectModemAt() {
  modemAtOnline = false;
  if (waitForGsmAtOkFixedBaud(3000)) {
    activeModemBaud = MODEM_BAUD;
    queryAt("ATE0", 2000);
    return true;
  }

  Serial.printf("[MODEM] AT not responding at fixed baud=%d on RX=GPIO%d TX=GPIO%d. Check GSM TX->ESP RX%d, GSM RX<-ESP TX%d, GND, 4V/2A, PWRKEY\n",
                MODEM_BAUD,
                MODEM_RX, MODEM_TX, MODEM_RX, MODEM_TX);
  return false;
}

bool configureGsmSmsMode() {
  bool ok = true;
  ok &= queryAt("ATE0", 2000).indexOf("OK") >= 0;
  queryAt("AT+CMEE=2", 2000);
  queryAt("AT+CSCLK=0", 2000);
  queryAt("AT+CREG=2", 2000);
  queryAt("AT+CGREG=2", 2000);
  queryAt("AT+CEREG=2", 2000);
  ok &= queryAt("AT+CMGF=1", 2000).indexOf("OK") >= 0;
  ok &= queryAt("AT+CSCS=\"GSM\"", 2000).indexOf("OK") >= 0;
  queryAt("AT+CPMS=\"SM\",\"SM\",\"SM\"", 3000);
  queryAt("AT+CSMP=17,167,0,0", 2000);
  queryAt("AT+CNMI=1,2,0,0,0", 2000);
  Serial.printf("[GSM] SMS text mode=%s\n", ok ? "OK" : "PARTIAL");
  return ok;
}

void wakeGsmModem() {
  queryAt("AT", 1200);
  queryAt("ATE0", 1200);
  queryAt("AT+CSCLK=0", 1500);
  queryAt("AT+CFUN=1", 5000);
}

bool ensureGsmReady(bool needVoice) {
  if (!ENABLE_GSM_FEATURES) {
    return false;
  }
  if (gsmCooldownUntil > 0 && millis() < gsmCooldownUntil) {
    Serial.println("[GSM] Cooldown active after AT/SIM failure; skipping modem command");
    return false;
  }
  lastGsmReconnectAttemptAt = millis();
  String at = queryAt("AT", 1200);
  if (at.indexOf("OK") < 0) {
    Serial.println("[MODEM] AT lost, rescanning UART baud");
    if (!connectModemAt()) {
      pulseModemPowerKey("AT lost");
      if (!connectModemAt()) {
        gsmNetworkOnline = false;
        modemAtOnline = false;
        gsmCooldownUntil = millis() + GSM_POWER_FAULT_COOLDOWN_MS;
        updateLcdStatus(true);
        return false;
      }
    }
  } else {
    modemAtOnline = true;
  }

  wakeGsmModem();
  configureGsmSmsMode();
  bool simReady = waitForSimReady(5000);
  if (!simReady) {
    gsmNetworkOnline = false;
    Serial.println("[GSM] SIM not ready after reconnect check");
    logGsmDiagnostics();
    gsmCooldownUntil = millis() + GSM_POWER_FAULT_COOLDOWN_MS;
    updateLcdStatus(true);
    return false;
  }

  gsmNetworkOnline = true;
  gsmCooldownUntil = 0;
  gsmFeaturesStarted = true;
  Serial.printf("[GSM] AT+SIM ready; direct %s allowed without extra network gate\n", needVoice ? "call" : "SMS");
  updateLcdStatus(true);
  return true;
}

void lcdSetBacklight(bool on) {
  lcdBacklightEnabled = on;
  if (!on) {
    lcdBacklightOffAt = 0;
  }
  if (lcdReady) {
    lcdWriteExpander(0);
  }
  Serial.printf("[LCD] Backlight %s\n", on ? "ON" : "OFF");
}

void lcdBacklightForEvent(const char *reason) {
  if (!lcdReady) {
    return;
  }
  lcdBacklightOffAt = millis() + LCD_EVENT_BACKLIGHT_MS;
  if (!lcdBacklightEnabled) {
    lcdSetBacklight(true);
  }
  Serial.printf("[LCD] Backlight event=%s duration=%lus\n",
                reason ? reason : "EVENT",
                LCD_EVENT_BACKLIGHT_MS / 1000UL);
  updateLcdStatus(true);
}

void serviceLcdBacklightTimeout() {
  if (!lcdReady || !lcdBacklightEnabled || lcdBacklightOffAt == 0) {
    return;
  }
  if (static_cast<long>(millis() - lcdBacklightOffAt) >= 0) {
    lcdSetBacklight(false);
  }
}

bool waitForSimReady(unsigned long totalWaitMs) {
  unsigned long start = millis();
  while (millis() - start < totalWaitMs) {
    String cpin = extractAtLine(queryAt("AT+CPIN?", 1500), "+CPIN:");
    Serial.printf("[GSM] SIM=%s\n", cpin.c_str());
    if (cpin.indexOf("READY") >= 0) {
      return true;
    }
    delay(1000);
  }
  Serial.println("[GSM] SIM not ready");
  return false;
}

bool waitForGsmNetwork(unsigned long totalWaitMs) {
  unsigned long start = millis();
  while (millis() - start < totalWaitMs) {
    logModemStatus();
    if (gsmLooksUsable()) {
      gsmNetworkOnline = true;
      Serial.println("[GSM] Network usable");
      updateLcdStatus(true);
      return true;
    }
    delay(2000);
  }
  gsmNetworkOnline = false;
  Serial.println("[GSM] Network not ready");
  updateLcdStatus(true);
  return false;
}

bool submitSmsByAt(const char *number, const String &message, const char *routeCommand, String &response) {
  Serial.printf("[SMS] Route %s\n", routeCommand);
  queryAt(routeCommand, 2000);

  while (SerialAT.available()) {
    SerialAT.read();
  }
  SerialAT.print("AT+CMGS=\"");
  SerialAT.print(number);
  SerialAT.println("\"");

  String prompt;
  unsigned long promptStart = millis();
  while (millis() - promptStart < 5000) {
    while (SerialAT.available()) {
      prompt += static_cast<char>(SerialAT.read());
    }
    if (prompt.indexOf('>') >= 0) {
      break;
    }
    yieldToSystem(10);
  }

  if (prompt.indexOf('>') < 0) {
    response = prompt;
    Serial.printf("[SMS] No CMGS prompt: %s\n", response.c_str());
    return false;
  }

  SerialAT.print(message);
  SerialAT.write(0x1A);

  Serial.println("[SMS] Waiting for modem submit result");
  response = readAtFinalResponse(15000);
  bool ok = response.indexOf("OK") >= 0 || response.indexOf("+CMGS:") >= 0;
  Serial.printf("[SMS] AT result=%s response=%s\n", ok ? "OK" : "FAIL", response.c_str());
  return ok;
}

bool sendSmsByAt(const char *number, const String &message) {
  Serial.printf("[SMS] AT sending to %s\n", number);
  queryAt("AT+CSMS=1", 2000);
  queryAt("AT+CMGF=1", 1000);
  queryAt("AT+CSCS=\"GSM\"", 1000);
  String smsc = queryAt("AT+CSCA?", 2000);
  String creg = queryAt("AT+CREG?", 2000);
  String cgreg = queryAt("AT+CGREG?", 2000);
  Serial.printf("[SMS] SMSC=%s\n", smsc.c_str());
  Serial.printf("[SMS] CREG=%s CGREG=%s\n", creg.c_str(), cgreg.c_str());

  String response;
  bool ok = submitSmsByAt(number, message, "AT+CGSMS=2", response);
  if (!ok && response.indexOf("+CMS ERROR") >= 0) {
    Serial.println("[SMS] Packet-domain SMS failed; trying circuit-preferred route");
    ok = submitSmsByAt(number, message, "AT+CGSMS=3", response);
  }
  if (!ok) {
    String ceer = queryAt("AT+CEER", 3000);
    Serial.printf("[SMS] CEER=%s\n", ceer.c_str());
  }
  return ok;
}

bool callNumberByAt(const char *number, uint32_t durationMs) {
  Serial.printf("[CALL] AT dialing %s\n", number);
  queryAt("AT+CLIR=0", 2000);
  queryAt("AT+COLP=1", 2000);
  String command = "ATD";
  command += number;
  command += ";";
  String response = queryAt(command.c_str(), 15000);
  bool ok = response.indexOf("OK") >= 0 || response.indexOf("CONNECT") >= 0 || response.length() == 0;
  Serial.printf("[CALL] AT dial result=%s response=%s\n", ok ? "OK" : "FAIL", response.c_str());
  if (!ok) {
    String ceer = queryAt("AT+CEER", 3000);
    Serial.printf("[CALL] CEER=%s\n", ceer.c_str());
    return false;
  }

  unsigned long start = millis();
  while (millis() - start < durationMs) {
    serviceAlarmPriorityTasks();
    if (alarmCancelled()) {
      Serial.println("[ALARM] Hanging up due to disarm priority");
      break;
    }
    yieldToSystem(20);
  }
  queryAt("ATH", 3000);
  return true;
}

void registerDeviceToServer() {
  if (WiFi.status() != WL_CONNECTED) {
    return;
  }

  HTTPClient http;
  http.setTimeout((currentMode == MODE_DISARMED) ? HTTP_TIMEOUT_DISARMED_MS : HTTP_TIMEOUT_ARMED_MS);
  http.begin(DEVICE_REGISTER_URL);
  prepareHttpRequest(http);
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
  prepareHttpRequest(http);
  http.addHeader("Content-Type", "application/json");

  String syncUuid = systemStateDeviceUuid();
  String payload = "{";
  payload += "\"device_uuid\":\"" + jsonEscape(syncUuid) + "\",";
  payload += "\"state\":\"alarm\",";
  payload += "\"user\":\"HUB\",";
  payload += "\"triggered_sensor\":\"" + jsonEscape(triggeredSensor) + "\",";
  payload += "\"alarm_reason\":\"" + jsonEscape(triggeredSensor) + "\",";
  payload += "\"reason\":\"" + jsonEscape(triggeredSensor) + "\"";
  payload += "}";

  Serial.printf("[STATE] POST %s uuid=%s\n", SYSTEM_STATE_URL, syncUuid.c_str());
  Serial.printf("[STATE] Trigger payload: %s\n", payload.c_str());
  int status = http.POST(payload);
  String body = http.getString();
  Serial.printf("[STATE] Trigger status=%d body=%s\n", status, body.c_str());
  http.end();
}

String modeToServerState(SystemMode mode) {
  switch (mode) {
    case MODE_ARMED:
      return "armed";
    case MODE_DISARMED:
      return "disarmed";
    case MODE_STAY_ARM:
      return "stay_arm";
    case MODE_ALARM:
      return "alarm";
  }
  return "";
}

void reportLocalModeToSystemState(SystemMode mode, const char *reason) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[STATE] WiFi not connected, local mode sync skipped");
    return;
  }
  if (reason && (strcmp(reason, "APP") == 0 || strcmp(reason, "BOOT") == 0)) {
    return;
  }

  String state = modeToServerState(mode);
  if (state.length() == 0 || state == "alarm") {
    return;
  }

  HTTPClient http;
  http.setTimeout((mode == MODE_DISARMED) ? HTTP_TIMEOUT_DISARMED_MS : HTTP_TIMEOUT_ARMED_MS);
  http.begin(SYSTEM_STATE_URL);
  prepareHttpRequest(http);
  http.addHeader("Content-Type", "application/json");

  String safeReason = reason ? String(reason) : "HUB";
  String syncUuid = systemStateDeviceUuid();
  String payload = "{";
  payload += "\"device_uuid\":\"" + jsonEscape(syncUuid) + "\",";
  payload += "\"device_name\":\"" + jsonEscape(deviceName()) + "\",";
  payload += "\"state\":\"" + state + "\",";
  payload += "\"user\":\"" + jsonEscape(safeReason) + "\",";
  payload += "\"reason\":\"" + jsonEscape(safeReason) + "\"";
  payload += "}";

  Serial.printf("[STATE] Sync local mode %s by %s uuid=%s\n", state.c_str(), safeReason.c_str(), syncUuid.c_str());
  int status = http.POST(payload);
  String body = http.getString();
  Serial.printf("[STATE] Local mode sync status=%d body=%s\n", status, body.c_str());
  if (status == 200) {
    lastServerState = state;
    noteServerOk();
  } else {
    noteServerFail("local_mode_sync", status);
  }
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

void sendSMS(const char *number, const String &message, bool allowWhenDisarmed = false) {
  if (!ENABLE_GSM_FEATURES) {
    Serial.println("[SMS] GSM disabled, SMS skipped");
    return;
  }
  if (!number || strlen(number) < 10) return;
  if (!allowWhenDisarmed && alarmCancelled()) return;
  if (!ensureGsmReady(false)) {
    Serial.println("[SMS] GSM AT/SIM not ready, SMS not sent");
    return;
  }
  Serial.printf("[SMS] Sending to %s: %s\n", number, message.c_str());
  wakeGsmModem();
  bool ok = sendSmsByAt(number, message);
  Serial.printf("[SMS] Result=%s\n", ok ? "OK" : "FAIL");
  if (!ok) {
    Serial.println("[SMS] One-shot SMS failed; alarm/app loop continues");
    logModemStatus();
    logGsmDiagnostics();
  }
  cooperativeDelay(500);
}

void sendSmsToAll(String message, bool allowWhenDisarmed = false) {
  if (smsNumberCount == 0) {
    Serial.println("[SMS] No numbers available");
    return;
  }

  for (uint8_t i = 0; i < smsNumberCount; i++) {
    sendSMS(smsNumbers[i], message, allowWhenDisarmed);
  }
}

void callNumber(const char *number, uint32_t durationMs = 20000, bool allowWhenDisarmed = false) {
  if (!ENABLE_GSM_FEATURES) {
    Serial.println("[CALL] GSM disabled, call skipped");
    return;
  }
  if (!number || strlen(number) < 10) return;
  if (!allowWhenDisarmed && alarmCancelled()) return;
  if (!ensureGsmReady(true)) {
    Serial.println("[CALL] GSM AT/SIM not ready, call not started");
    return;
  }
  gsmCallActive = true;
  WiFi.setSleep(false);
  Serial.printf("[CALL] Calling %s\n", number);
  wakeGsmModem();
  bool ok = callNumberByAt(number, durationMs);
  if (!ok) {
    Serial.println("[CALL] Direct AT dial failed; refreshing modem and retrying once");
    wakeGsmModem();
    ok = callNumberByAt(number, durationMs);
  }
  Serial.printf("[CALL] Dial result=%s\n", ok ? "OK" : "FAIL");
  if (!ok) {
    logModemStatus();
    logGsmDiagnostics();
    gsmCallActive = false;
    return;
  }
  cooperativeDelay(1500);
  gsmCallActive = false;
}

void callAll() {
  if (!ENABLE_GSM_FEATURES) {
    Serial.println("[CALL] GSM disabled, callAll skipped");
    return;
  }
  if (callNumberCount == 0) {
    Serial.println("[CALL] No synced call numbers available");
    return;
  }

  for (uint8_t i = 0; i < callNumberCount; i++) {

    if (alarmCancelled()) {
      Serial.println("[ALARM] Calling stopped due to disarm");
      return;
    }

    callNumber(callNumbers[i], 20000);  // duration already handled

    cooperativeDelay(3000);  // ✅ IMPORTANT: gap between calls
  }
}

void serviceSerialGsmCommands() {
  if (!Serial.available()) {
    return;
  }

  String command = Serial.readStringUntil('\n');
  command.trim();
  if (command.length() == 0) {
    return;
  }

  if (command == "gsm" || command == "gsmtest") {
    Serial.println("[GSM_TEST] Running modem diagnostic");
    ensureGsmReady(false);
    logGsmDiagnostics();
    return;
  }

  if (command == "modem_restart" || command == "gsm_restart") {
    Serial.println("[GSM_TEST] Hardware modem restart requested");
    pulseModemPowerKey("serial command");
    connectModemAt();
    logGsmDiagnostics();
    return;
  }

  if (command.startsWith("at:")) {
    String atCommand = command.substring(3);
    atCommand.trim();
    if (atCommand.length() == 0) {
      Serial.println("[GSM_TEST] Use at:AT+CPIN?");
      return;
    }
    String response = queryAt(atCommand.c_str(), 5000);
    Serial.printf("[GSM_TEST] %s => %s\n", atCommand.c_str(), response.c_str());
    return;
  }

  if (command.startsWith("sms:")) {
    int separator = command.indexOf(':', 4);
    if (separator < 0) {
      Serial.println("[GSM_TEST] Use sms:+919876543210:Test message");
      return;
    }
    String number = command.substring(4, separator);
    String message = command.substring(separator + 1);
    number.trim();
    message.trim();
    if (message.length() == 0) {
      message = "MONSOW GSM SMS TEST";
    }
    sendSMS(number.c_str(), message);
    return;
  }

  if (command.startsWith("call:")) {
    String number = command.substring(5);
    number.trim();
    Serial.printf("[GSM_TEST] Manual call test to %s\n", number.c_str());
    callNumber(number.c_str(), 20000, true);
    return;
  }
}

void sendAlert(const String &message, bool allowCall) {
  if (!ENABLE_GSM_FEATURES) {
    Serial.println("[ALERT] GSM disabled, alert notifications skipped");
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
  if (currentMode == MODE_ALARM && (mode == MODE_ARMED || mode == MODE_STAY_ARM)) {
    Serial.printf("[STATE] Ignored %s by %s; alarm is latched until DISARM\n",
                  mode == MODE_ARMED ? "ARMED" : "STAY",
                  reason ? reason : "");
    return;
  }
  SystemMode previousMode = currentMode;
  bool modeChanged = previousMode != mode;
  if (!modeChanged && (mode == MODE_ARMED || mode == MODE_DISARMED || mode == MODE_STAY_ARM)) {
    Serial.printf("[STATE] Duplicate %s by %s ignored\n",
                  mode == MODE_ARMED ? "ARMED" :
                  mode == MODE_STAY_ARM ? "STAY" : "DISARMED",
                  reason ? reason : "");
    return;
  }
  currentMode = mode;
  updateModeIndicatorLeds();
  if (modeChanged) {
    reportLocalModeToSystemState(mode, reason);
  }
  switch (mode) {
    case MODE_ARMED:
      lcdBacklightForEvent("ARMED");
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
    case MODE_DISARMED: {
      lcdBacklightForEvent("DISARMED");
      if (ENABLE_GSM_FEATURES && modemAtOnline && reason && strcmp(reason, "BOOT") != 0) {
        queryAt("ATH", 3000);
      } else if (ENABLE_GSM_FEATURES && !modemAtOnline) {
        Serial.println("[MODEM] Hangup skipped; AT offline");
      }
      clearPendingAlarm();
      stopExitDelay();
      alarmEndsAt = 0;
      setAlarmOutputs(false);
      beep(2);
      Serial.printf("[STATE] DISARMED by %s\n", reason);
      const bool wasArmed = previousMode == MODE_ARMED ||
                            previousMode == MODE_STAY_ARM ||
                            previousMode == MODE_ALARM;
      const bool shouldNotify = wasArmed &&
                                (shouldSendArmDisarmSms(reason) ||
                                 (ALWAYS_SEND_DISARM_SMS && reason &&
                                  strcmp(reason, "BOOT") != 0 &&
                                  strcmp(reason, "OFFLINE") != 0));
      if (shouldNotify) {
        sendSmsToAll("SYSTEM DISARMED", true);
      }
      break;
    }
    case MODE_STAY_ARM:
      lcdBacklightForEvent("STAY_ARM");
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
      lcdBacklightForEvent("ALARM");
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
  updateModeIndicatorLeds();
  lcdBacklightForEvent("ALARM");
  alarmEndsAt = settingAlarmDurationMinutes > 0 ? now + (static_cast<unsigned long>(settingAlarmDurationMinutes) * 60000UL) : 0;
  clearPendingAlarm();
  suppressAlarmSound = SUPPRESS_ALARM_SOUND_WHILE_ALERTING;
  setAlarmOutputs(true);
  Serial.printf("[ALARM] %s\n", reason.c_str());
  sendAlarmEvent("ALARM_START", reason, reason);
  reportTriggeredSensorToSystemState(reason);
  lastServerState = "alarm";
  sendAlert("ALERT: " + reason, allowCall);
  if (suppressAlarmSound) {
    suppressAlarmSound = false;
    setAlarmOutputs(true);
  }
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
    Serial.printf("[DELAY] Ignoring trigger during exit delay: %s\n", zoneName);
    return;
  }
  if (entryDelayActive) {
    Serial.printf("[DELAY] Entry delay already running, ignoring additional trigger: %s\n", zoneName);
    return;
  }

  bool allowCall = true;
  String reason = String(zoneName) + " OPEN";
  sendAlarmEvent("SENSOR_TRIGGER", String(zoneName), reason);
  if (settingEntryDelaySeconds > 0) {
    beepSensorTrigger();
    startEntryDelay(reason, allowCall);
    return;
  }
  triggerAlarm(reason, allowCall);
}

void handleServerState(const String &state) {
  if (!ALLOW_APP_ARM_DISARM_CONTROL) {
    return;
  }
  if (state.length() == 0) {
    return;
  }

  SystemMode desiredMode = currentMode;
  bool knownState = true;
  if (state == "armed") {
    desiredMode = MODE_ARMED;
  } else if (state == "disarmed") {
    desiredMode = MODE_DISARMED;
  } else if (state == "stay_arm" || state == "stay_armed" || state == "stayarmed") {
    desiredMode = MODE_STAY_ARM;
  } else if (state == "alarm") {
    desiredMode = MODE_ALARM;
  } else {
    knownState = false;
  }

  if (!knownState) {
    Serial.printf("[SYNC] Unknown server state: %s\n", state.c_str());
    return;
  }

  if (state == lastServerState && desiredMode == currentMode) {
    return;
  }

  if (currentMode == MODE_ALARM &&
      (desiredMode == MODE_ARMED || desiredMode == MODE_STAY_ARM)) {
    lastServerState = state;
    Serial.printf("[SYNC] Ignoring server %s while alarm is latched; wait for DISARM\n", state.c_str());
    return;
  }

  Serial.printf("[SYNC] Server state changed to %s\n", state.c_str());
  lastServerState = state;

  if (desiredMode == currentMode && state != "alarm") {
    return;
  }

  if (desiredMode == MODE_ARMED) {
    setMode(MODE_ARMED, "APP");
  } else if (desiredMode == MODE_DISARMED) {
    setMode(MODE_DISARMED, "APP");
  } else if (desiredMode == MODE_STAY_ARM) {
    setMode(MODE_STAY_ARM, "APP");
  } else if (desiredMode == MODE_ALARM) {
    if (currentMode != MODE_ALARM) {
      currentMode = MODE_ALARM;
      updateModeIndicatorLeds();
      setAlarmOutputs(false);
      Serial.println("[SYNC] Server alarm state received; siren kept OFF until local sensor trigger");
    } else if (alarmOutputsEnabled) {
      Serial.println("[SYNC] Server alarm state confirmed; keeping local siren ON");
    }
  }
}

void pollSystemState() {
  if (!ALLOW_APP_ARM_DISARM_CONTROL) {
    return;
  }
  if (!allowServerRequests()) {
    return;
  }

  unsigned long interval = (currentMode == MODE_DISARMED) ? STATE_POLL_DISARMED_MS : STATE_POLL_ARMED_MS;
  unsigned long now = millis();
  if (now - lastStatePollAt < interval) {
    return;
  }
  lastStatePollAt = now;

  String candidates[2];
  uint8_t candidateCount = 0;
  if (settingHubLanguage.length() > 0) {
    candidates[candidateCount++] = settingHubLanguage;
  }
  String baseUuid = deviceUuid();
  if (candidateCount == 0 || baseUuid != candidates[0]) {
    candidates[candidateCount++] = baseUuid;
  }

  bool gotResponse = false;
  int lastStatus = 0;
  for (uint8_t i = 0; i < candidateCount; i++) {
    HTTPClient http;
    http.setTimeout((currentMode == MODE_DISARMED) ? HTTP_TIMEOUT_DISARMED_MS : HTTP_TIMEOUT_ARMED_MS);
    String url = String(SYSTEM_STATE_URL) + "&device_uuid=" + urlEncode(candidates[i]) + "&source=hub";
    http.begin(url);
    prepareHttpRequest(http);
    int status = http.GET();
    lastStatus = status;
    if (status == 200) {
      noteServerOk();
      gotResponse = true;
      String body = http.getString();
      String state = extractJsonString(body, "state");
      if (state.length() > 0) {
        Serial.printf("[SYNC] State uuid=%s state=%s\n", candidates[i].c_str(), state.c_str());
        handleServerState(state);
        http.end();
        return;
      }
      Serial.printf("[SYNC] No state for uuid=%s response=%s\n", candidates[i].c_str(), body.c_str());
    }
    http.end();
  }

  if (!gotResponse) {
    Serial.printf("[SYNC] HTTP GET failed status=%d\n", lastStatus);
    noteServerFail("system_state", lastStatus);
  }
}

void connectWiFi() {
  if (!wifiProvisioned) {
    Serial.println("[WIFI] No credentials stored");
    setOfflineMode(true, "no_credentials");
    return;
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("[WIFI] Already connected IP=%s RSSI=%d\n",
                  WiFi.localIP().toString().c_str(),
                  WiFi.RSSI());
    setOfflineMode(false, "wifi_connected");
    return;
  }

  lastWiFiAttemptAt = millis();
  Serial.printf("[WIFI] Connecting to %s\n", provisionedSsid.c_str());
  if (bleProvisioningActive) {
    Serial.println("[WIFI] Stopping BLE before normal WiFi.begin");
    stopBleProvisioning();
    delay(300);
  }
  WiFi.mode(WIFI_STA);
  WiFi.persistent(false);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  WiFi.setTxPower(WIFI_POWER_19_5dBm);
  WiFi.disconnect(false, false);
  delay(250);
  Serial.println("[WIFI] Stable connect: STA, sleep OFF, TX max, fresh WiFi.begin");
  WiFi.begin(provisionedSsid.c_str(), provisionedPassword.c_str());

  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < WIFI_CONNECT_TIMEOUT_MS) {
    // Keep sensor/RF processing alive while we're waiting on WiFi.
    pollRf();
    pollBoardButtons();
    updateTimedAlarmState();
    pollDoorZones();
    updateAlarmBuzzer();
    delay(500);
    Serial.print(".");
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("[WIFI] Connected IP=%s RSSI=%d\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
    resumeBleAdvertisingAfterWifiConnect();
    if (!timeConfigured || !systemTimeIsValid()) {
      configureTimeFromWifi();
    }
    setOfflineMode(false, "wifi_connected");
    if (wifiTxCharacteristic) {
      wifiTxCharacteristic->setValue("WIFI_CONNECTED");
      wifiTxCharacteristic->notify();
    }
    pendingInitialServerSync = true;
    pendingInitialServerSyncAt = millis() + 1500;
    lastSettingsFetchAt = millis();
    Serial.println("[WIFI] Server register/settings scheduled after boot");
  } else {
    wl_status_t status = WiFi.status();
    const char *reason = wifiStatusText(status);
    if (lastWifiDisconnectReason != 0 && millis() - lastWifiDisconnectAt < WIFI_CONNECT_TIMEOUT_MS + 5000) {
      reason = wifiDisconnectReasonText(lastWifiDisconnectReason);
    }
    Serial.printf("[WIFI] Connection failed status=%d (%s)\n", static_cast<int>(status), reason);
    setOfflineMode(true, "wifi_failed");
    if (wifiTxCharacteristic) {
      String message = String("WIFI_FAILED:") + reason;
      wifiTxCharacteristic->setValue(message.c_str());
      wifiTxCharacteristic->notify();
    }
    if (START_BLE_PROVISIONING_ON_WIFI_FAIL) {
      startBleProvisioning();
    } else {
      resumeBleAdvertisingAfterWifiConnect();
    }
  }
}

void servicePendingWifiConnectAfterBleConfig() {
  if (!pendingWifiConnectAfterBleConfig) {
    return;
  }
  if (millis() < pendingWifiConnectAt) {
    return;
  }
  pendingWifiConnectAfterBleConfig = false;
  Serial.println("[BLE] WiFi config notify window complete; stopping BLE before WiFi connect");
  stopBleProvisioning();
  delay(300);
  Serial.println("[WIFI] Starting WiFi after BLE stopped");
  connectWiFi();
}

void pulseModemPowerKey(const char *reason) {
  if (MODEM_PWRKEY_PIN < 0) {
    Serial.println("[MODEM] PWRKEY not available on this A7670C breakout; hardware restart skipped");
    Serial.println("[MODEM] Power/reset the GSM board externally, or wire RESET to an ESP32 GPIO if needed");
    return;
  }

  Serial.printf("[MODEM] PWRKEY pulse GPIO%d reason=%s\n",
                MODEM_PWRKEY_PIN,
                reason ? reason : "manual");
  pinMode(MODEM_PWRKEY_PIN, OUTPUT);
  digitalWrite(MODEM_PWRKEY_PIN, MODEM_PWRKEY_ON_STATE);
  delay(MODEM_PWRKEY_PULSE_MS);
  digitalWrite(MODEM_PWRKEY_PIN, MODEM_PWRKEY_ON_STATE == LOW ? HIGH : LOW);
  delay(MODEM_BOOT_SETTLE_MS);
}

void initModem() {
  if (!ENABLE_GSM_FEATURES) {
    Serial.println("[MODEM] init skipped because GSM features are disabled");
    return;
  }
  Serial.printf("[MODEM] Starting UART RX=GPIO%d TX=GPIO%d baud=%d\n", MODEM_RX, MODEM_TX, MODEM_BAUD);
  SerialAT.end();
  delay(150);
  SerialAT.setRxBufferSize(1024);
  SerialAT.begin(MODEM_BAUD, SERIAL_8N1, MODEM_RX, MODEM_TX);
  delay(1000);

  auto waitForAtOk = [&](unsigned long totalWaitMs) -> bool {
    Serial.println("[MODEM] Waiting for AT");
    unsigned long waitStart = millis();
    while (millis() - waitStart < totalWaitMs) {
      String response = queryAt("AT", 1500);
      if (response.indexOf("OK") >= 0) {
        modemAtOnline = true;
        Serial.println("[MODEM] AT OK");
        return true;
      }
      delay(300);
    }
    modemAtOnline = false;
    Serial.println("[MODEM] AT not responding (check UART pins/level-shifter/power)");
    return false;
  };

  bool modemReady = false;
  if (USE_TINYGSM_MODEM_RESTART) {
    Serial.println("[MODEM] Restarting modem");
    modemReady = modem.restart();
    Serial.println(modemReady ? "[MODEM] Restart OK" : "[MODEM] Restart failed");
  } else {
    Serial.println("[MODEM] modem.restart skipped; using direct AT init");
  }

  if (!modemReady) {
    if (waitForAtOk(5000)) {
      modemReady = true;
      modemAtOnline = true;
      Serial.println("[MODEM] AT responded OK, continuing without restart");
    } else {
      pulseModemPowerKey("AT not responding");
      if (waitForAtOk(3000)) {
        modemReady = true;
        modemAtOnline = true;
        Serial.println("[MODEM] AT OK after PWRKEY pulse");
      }
    }
  }

  if (!modemReady) {
      gsmNetworkOnline = false;
      gsmCooldownUntil = millis() + GSM_POWER_FAULT_COOLDOWN_MS;
      updateLcdStatus(true);
      Serial.println("[MODEM] AT not responding cleanly");
      Serial.println("[MODEM] GSM soft-failed; retry paused for 120 seconds so app/alarm continues");
      Serial.println("[MODEM] Check A7670C power, GND common, ESP32 TX->GSM RX, ESP32 RX<-GSM TX, and level shifting");
      return;
  }

  waitForAtOk(5000);

  String ati = queryAt("ATI", 3000);
  Serial.printf("[MODEM] ATI=%s\n", ati.c_str());
  Serial.println("[MODEM] Disabling command echo (ATE0)");
  queryAt("ATE0", 2000);
  Serial.println("[MODEM] Settling before network checks");
  delay(2000);
  queryAt("AT+CFUN=1", 5000);
  configureGsmSmsMode();

  if (!waitForSimReady(20000)) {
    gsmNetworkOnline = false;
    gsmCooldownUntil = millis() + GSM_POWER_FAULT_COOLDOWN_MS;
    updateLcdStatus(true);
    Serial.println("[MODEM] Continuing boot; SIM not ready");
    return;
  }

  logGsmDiagnostics();
  setSystemTimeFromGsmClock();
  if (!modemReady) {
    Serial.println("[MODEM] Continuing boot with limited modem availability");
  }

  if (!waitForGsmNetwork(MODEM_NETWORK_TIMEOUT_MS)) {
    gsmCooldownUntil = millis() + GSM_POWER_FAULT_COOLDOWN_MS;
    Serial.println("[MODEM] Continuing boot without blocking WiFi/app control");
    return;
  }

  gsmNetworkOnline = true;
  gsmCooldownUntil = 0;
  Serial.println("[MODEM] Network connected");
  logModemStatus();
  logGsmDiagnostics();
  setSystemTimeFromGsmClock();
}

void handleRfCode(uint32_t code) {
  if (rfPairingActive) {
    Serial.printf("[RF] Pairing capture code=%lu type=%s\n", static_cast<unsigned long>(code), rfPairType.c_str());
    long capturedPairingId = rfPairingId.length() ? rfPairingId.toInt() : -1;
    if (storeLearnedRfItem(code, rfPairType, rfPairName, rfPairZone, rfPairRemoteMode)) {
      updateServerPairingStatus("paired", code);
      sendPairingNotify("paired", code);
      recentlyPairedRfCode = code;
      recentlyPairedRfIgnoreUntil = millis() + 2500UL;
      if (lcdReady) {
        lcdPrintLine(0, "RF SAVED");
        lcdPrintLine(1, "CODE: " + String(code));
        lcdPrintLine(2, "TYPE: " + String(rfTypeToString(resolvePairingRfType(rfPairType, rfPairRemoteMode, rfPairZone, rfPairName))));
        lcdPrintLine(3, "APP SAVE OK");
      }
    } else {
      updateServerPairingStatus("failed", code);
      sendPairingNotify("pair_save_failed", code);
    }
    if (capturedPairingId >= 0) {
      locallyCompletedPairingRequestId = capturedPairingId;
      locallyCompletedPairingIgnoreUntil = millis() + 300000UL;
    }
    clearRfPairingRequest();
    scheduleBleStopAfterPairing();
    return;
  }

  if (recentlyPairedRfCode == code && millis() < recentlyPairedRfIgnoreUntil) {
    Serial.printf("[RF] Ignoring freshly paired repeat code=%lu\n", static_cast<unsigned long>(code));
    return;
  }
  if (millis() >= recentlyPairedRfIgnoreUntil) {
    recentlyPairedRfCode = 0;
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
      case RF_TYPE_TAMPER:
        if (settingTamperAlarm) {
          triggerAlarm(label + " TAMPER", true);
        } else {
          Serial.println("[TAMPER] tamper_alarm setting is disabled");
        }
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
      case RF_TYPE_TAMPER:
        if (settingTamperAlarm) {
          triggerAlarm(String(RF_ITEMS[i].name) + " TAMPER", true);
        } else {
          Serial.println("[TAMPER] tamper_alarm setting is disabled");
        }
        return;
      default:
        return;
    }
  }

  Serial.printf("[RF] Unlearned code ignored=%lu%s\n",
                static_cast<unsigned long>(code),
                isArmedLikeMode(currentMode) ? " (pair this sensor first)" : "");
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
  if (exitDelayActive) {
    // Do not consume door transitions during exit delay.
    // If a door is opened during countdown and remains open,
    // it will be processed after exit delay completes.
    return;
  }
  if (entryDelayActive) {
    // Entry countdown already has one pending alarm.
    // Ignore additional door transitions until countdown finishes.
    return;
  }

  for (uint8_t i = 0; i < DOOR_ZONE_COUNT; i++) {
    int state = -1;

    if (DOOR_ZONE_PINS[i] < 0) {
      continue;
    }
    state = digitalRead(DOOR_ZONE_PINS[i]);

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
    Serial.println("[ALARM] Alarm duration reached. Siren OFF, but system stays in ALARM until disarmed.");
    alarmEndsAt = 0;
    setAlarmOutputs(false);
    sendAlarmEvent("ALARM_SIREN_STOP", "SYSTEM", "Alarm duration expired, siren stopped.");
  }
}

void updateAlarmBuzzer() {
  if (currentMode == MODE_ALARM && alarmOutputsEnabled) {
    // Keep buzzer continuously ON during alarm.
    bool alarmSoundOn = settingAlarmSound && !suppressAlarmSound && !FORCE_ALARM_SOUND_OFF;
    digitalWrite(BUZZER_PIN, alarmSoundOn ? HIGH : LOW);
    digitalWrite(AUX_BUZZER_PIN, alarmSoundOn ? HIGH : LOW);
    digitalWrite(SIREN_PIN, alarmSoundOn ? HIGH : LOW);
  } else {
    digitalWrite(BUZZER_PIN, LOW);
    digitalWrite(AUX_BUZZER_PIN, LOW);
    digitalWrite(SIREN_PIN, LOW);
  }
}

void initSerialInterfaces() {
  Serial.begin(115200);
  delay(500);
}

void printBootBanner() {
  Serial.println();
  Serial.println("================================");
  Serial.println("[BOOT] APP ARM/DISARM ONLY SKETCH");
  Serial.println("================================");
}

bool isWarmResetBoot() {
  return rtcWarmResetMarker == RTC_WARM_RESET_MAGIC;
}

void logResetReason(esp_reset_reason_t resetReason, bool warmReset) {
  Serial.printf("[BOOT] Reset reason=%d warm_reset=%s\n",
                static_cast<int>(resetReason),
                warmReset ? "YES" : "NO");
}

void initAlarmOutputPins() {
  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(AUX_BUZZER_PIN, OUTPUT);
  pinMode(SIREN_PIN, OUTPUT);
  pinMode(ARM_INDICATOR_PIN, OUTPUT);
  pinMode(DISARM_INDICATOR_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);
  digitalWrite(AUX_BUZZER_PIN, LOW);
  digitalWrite(SIREN_PIN, LOW);
  digitalWrite(ARM_INDICATOR_PIN, LOW);
  digitalWrite(DISARM_INDICATOR_PIN, LOW);
  logOutputPinStates(true);
}

void initLcdI2cBus() {
  Wire.begin(LCD_I2C_SDA_PIN, LCD_I2C_SCL_PIN);
  Wire.setClock(50000);
  Wire.setTimeOut(100);
  Serial.printf("[I2C] LCD 16x4 bus SDA=GPIO%d SCL=GPIO%d checking 0x%02X/0x%02X\n",
                LCD_I2C_SDA_PIN, LCD_I2C_SCL_PIN, LCD_I2C_ADDRESS, LCD_I2C_ALT_ADDRESS);

  Wire.beginTransmission(LCD_I2C_ADDRESS);
  byte error = Wire.endTransmission();
  uint8_t detectedAddress = LCD_I2C_ADDRESS;

  if (error != 0) {
    Wire.beginTransmission(LCD_I2C_ALT_ADDRESS);
    error = Wire.endTransmission();
    detectedAddress = LCD_I2C_ALT_ADDRESS;
  }

  if (error == 0) {
    activeLcdAddress = detectedAddress;
    lcdReady = true;
    if (!lcdBeginNative()) {
      lcdReady = false;
      Serial.println("[LCD] Init failed; LCD disabled so app/system keeps running");
      return;
    }
    lcdClearDisplay();
    lcdPrintLine(0, "ALARM BOOTING");
    lcdPrintLine(1, "LCD: GPIO2/5");
    lcdPrintLine(2, "WIFI READY");
    lcdPrintLine(3, "WAIT...");
    Serial.printf("[LCD] 16x4 display initialized at 0x%02X\n", detectedAddress);
  } else {
    lcdReady = false;
    Serial.printf("[LCD] Not detected at 0x%02X or 0x%02X. Check VCC/GND/SDA/SCL/address.\n",
                  LCD_I2C_ADDRESS, LCD_I2C_ALT_ADDRESS);
  }
}

void initBoardInputs() {
  pinMode(MIC_REC_PIN, INPUT_PULLUP);
  pinMode(RF_PAIR_BUTTON_PIN, INPUT_PULLUP);
  pinMode(FW_RESET_PIN, INPUT_PULLUP);
  pinMode(PWR_SENSE_PIN, INPUT);
  pinMode(BAT_SENSE_PIN, INPUT);
  analogReadResolution(12);
  analogSetPinAttenuation(BAT_SENSE_PIN, ADC_11db);

  lastMicRecButtonState = digitalRead(MIC_REC_PIN);
  lastRfPairButtonState = digitalRead(RF_PAIR_BUTTON_PIN);
  lastFwResetButtonState = digitalRead(FW_RESET_PIN);
  lastPowerSenseState = digitalRead(PWR_SENSE_PIN);
  Serial.printf("[POWER] External power initial=%s\n", lastPowerSenseState == HIGH ? "PRESENT" : "LOST");
  Serial.printf("[BATTERY] Calibration divider=%.2f empty=%.2fV full=%.2fV initial=%.2fV %u%%\n",
                BATTERY_DIVIDER_RATIO,
                BATTERY_EMPTY_VOLTAGE,
                BATTERY_FULL_VOLTAGE,
                readBatteryVoltage(),
                readBatteryPercentage());
}

void initDoorZoneInputs() {
  for (uint8_t i = 0; i < DOOR_ZONE_COUNT; i++) {
    if (DOOR_ZONE_PINS[i] >= 0) {
      pinMode(DOOR_ZONE_PINS[i], INPUT_PULLUP);
      lastDoorZoneState[i] = digitalRead(DOOR_ZONE_PINS[i]);
      Serial.printf("[ZONE] %s on GPIO %d initial=%d\n", DOOR_ZONE_NAMES[i], DOOR_ZONE_PINS[i], lastDoorZoneState[i]);
    }
  }
}

void initRfReceiver() {
  rf.enableReceive(digitalPinToInterrupt(RF_PIN));
  Serial.printf("[RF] Receiver enabled on GPIO %d\n", RF_PIN);
}

void loadBootStorage(esp_reset_reason_t resetReason, bool warmReset) {
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
}

void loadBootConfiguration() {
  loadLearnedRfItems();
  loadCachedSettingsFromPreferences();
  applyManualContactNumbersIfEmpty();
}

void startNetworkProvisioning() {
  Serial.printf("[BLE] Provisioning compile switch=%s, boot_start=%s, device=%s\n",
                ENABLE_BLE_PROVISIONING ? "ON" : "OFF",
                START_BLE_PROVISIONING_ON_BOOT ? "YES" : "NO",
                BLE_DEVICE_NAME);

  if (START_BLE_PROVISIONING_ON_BOOT) {
    startBleProvisioning();
  }

  if (wifiProvisioned) {
    connectWiFi();
  } else if (!START_BLE_PROVISIONING_ON_BOOT) {
    startBleProvisioning();
  }
}

void startGsmFeatures() {
  if (ENABLE_GSM_FEATURES) {
    initModem();
  } else {
    Serial.println("[MODEM] GSM disabled for app-only mode");
  }
}

void reconnectWiFiIfDue() {
  if (pendingWifiConnectAfterBleConfig || bleProvisioningActive) {
    return;
  }
  unsigned long wifiRetryMs = offlineMode ? WIFI_RETRY_OFFLINE_MS : WIFI_RETRY_ONLINE_MS;
  if (WIFI_AUTO_RECONNECT &&
      WiFi.status() != WL_CONNECTED &&
      wifiProvisioned &&
      millis() - lastWiFiAttemptAt > wifiRetryMs) {
    connectWiFi();
  }
}

void fetchSettingsIfDue() {
  unsigned long settingsIntervalMs = (currentMode == MODE_DISARMED) ? SETTINGS_FETCH_DISARMED_MS : SETTINGS_FETCH_ARMED_MS;
  if (WiFi.status() == WL_CONNECTED && allowServerRequests() && millis() - lastSettingsFetchAt > settingsIntervalMs) {
    fetchSettingsFromServer();
  }
}

void serviceInitialServerSync() {
  if (!pendingInitialServerSync) {
    return;
  }
  if (WiFi.status() != WL_CONNECTED || !allowServerRequests()) {
    return;
  }
  if (millis() < pendingInitialServerSyncAt) {
    return;
  }

  pendingInitialServerSync = false;
  Serial.println("[WIFI] Running delayed server register/settings sync");
  servicePendingServerFactoryResetCleanup();
  if (pendingServerFactoryResetCleanup) {
    pendingInitialServerSync = true;
    pendingInitialServerSyncAt = millis() + 10000;
    Serial.println("[FW_RESET] Register/settings sync postponed until server cleanup succeeds");
    return;
  }
  registerDeviceToServer();
  fetchSettingsFromServer();
}

void serviceRfPairingTimeout() {
  if (rfPairingActive && millis() - rfPairingStartedAt > RF_PAIR_WINDOW_MS) {
    Serial.println("[RF] Pairing window timed out");
    updateServerPairingStatus("timeout");
    sendPairingNotify("timeout");
    clearRfPairingRequest();
    scheduleBleStopAfterPairing();
  }
}

void setup() {
  initSerialInterfaces();
  printBootBanner();
  WiFi.onEvent(handleWiFiEvent);

  esp_reset_reason_t resetReason = esp_reset_reason();
  bool warmReset = isWarmResetBoot();
  logResetReason(resetReason, warmReset);

  initAlarmOutputPins();
  initBoardInputs();
  initDoorZoneInputs();
  initRfReceiver();

  loadBootStorage(resetReason, warmReset);
  loadBootConfiguration();
  startNetworkProvisioning();
  startGsmFeatures();
  initLcdI2cBus();

  setMode(MODE_DISARMED, "BOOT");
}

void loop() {
  reconnectWiFiIfDue();
  syncTimeIfDue();
  serviceInitialServerSync();
  fetchSettingsIfDue();
  pollPairingRequestIfDue();
  pollRf();
  pollSystemState();
  serviceAutoArmSchedule();
  serviceBleBootAdvertisingWindow();
  servicePendingWifiConnectAfterBleConfig();
  serviceRfPairingTimeout();
  serviceBleStopAfterPairing();
  updateTimedAlarmState();
  pollDoorZones();
  pollBoardButtons();
  serviceSerialGsmCommands();
  pollPowerAndBatterySense();
  updateAlarmBuzzer();
  logOutputPinStates();
  updateLcdStatus();
  serviceLcdBacklightTimeout();
  delay(50);
}
