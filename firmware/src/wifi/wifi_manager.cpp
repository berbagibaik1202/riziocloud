#include "runtime.h"
bool provisioning = false;
static String ssid, password;
static uint32_t lastAttempt = 0;
static uint32_t stationFailureSince = 0;
static int lastStatus = -1;
static constexpr const char *DEFAULT_AP_PASSWORD = "rizio123456";
static constexpr uint32_t STATION_PROVISIONING_TIMEOUT = 120000;
static const char *wifiStatusName(int status) {
  switch (status) {
    case WL_IDLE_STATUS: return "IDLE (waiting for connection)";
    case WL_NO_SSID_AVAIL: return "NO_SSID_AVAIL (SSID not found)";
    case WL_SCAN_COMPLETED: return "SCAN_COMPLETED";
    case WL_CONNECTED: return "CONNECTED";
    case WL_CONNECT_FAILED: return "CONNECT_FAILED";
    case WL_CONNECTION_LOST: return "CONNECTION_LOST";
    case WL_DISCONNECTED: return "DISCONNECTED";
    default: return "UNKNOWN";
  }
}
void beginWifi() {
  WiFi.persistent(false);
  StaticJsonDocument<256> doc;
  File f = LittleFS.open("/wifi.json", "r");
  if (f && !deserializeJson(doc, f)) { ssid = doc["ssid"].as<String>(); password = doc["password"].as<String>(); }
  if (!ssid.length()) {
    Serial.println("[WiFi] No saved SSID; starting provisioning AP.");
    provisioning = true;
    WiFi.mode(WIFI_AP);
    String sn = identity["sn"].as<String>();
    WiFi.softAPConfig(IPAddress(192,168,4,1), IPAddress(192,168,4,1), IPAddress(255,255,255,0));
    String apSsid = "RIZIO-" + sn.substring(sn.length() > 8 ? sn.length()-8 : 0);
    bool started = WiFi.softAP(apSsid.c_str(), DEFAULT_AP_PASSWORD);
    Serial.printf("[WiFi] Provisioning AP %s: SSID=\"%s\", IP=%s\n",
                  started ? "started" : "failed", apSsid.c_str(), WiFi.softAPIP().toString().c_str());
  } else {
    Serial.printf("[WiFi] Connecting to SSID=\"%s\"...\n", ssid.c_str());
    WiFi.mode(WIFI_STA); WiFi.begin(ssid.c_str(), password.c_str());
    lastAttempt = millis();
    stationFailureSince = lastAttempt;
    lastStatus = -1;
    configTime(0, 0, "pool.ntp.org", "time.google.com");
  }
}
void tickWifi() {
  if (provisioning) return;
  int status = WiFi.status();
  if (status != lastStatus) {
    Serial.printf("[WiFi] SSID=\"%s\", status=%s (%d)\n", ssid.c_str(), wifiStatusName(status), status);
    if (status == WL_CONNECTED) {
      stationFailureSince = 0;
      Serial.printf("[WiFi] Connected successfully: SSID=\"%s\", IP=%s, RSSI=%ld dBm\n",
                    WiFi.SSID().c_str(), WiFi.localIP().toString().c_str(), static_cast<long>(WiFi.RSSI()));
    } else if (lastStatus == WL_CONNECTED) {
      stationFailureSince = millis();
      Serial.println("[WiFi] Connection lost; waiting to reconnect.");
    }
    lastStatus = status;
  }
  if (status != WL_CONNECTED) {
    if (!stationFailureSince) stationFailureSince = millis();
    if (millis() - stationFailureSince >= STATION_PROVISIONING_TIMEOUT && !restartAt) {
      Serial.printf("[WiFi] SSID=\"%s\" unavailable for 120 seconds; clearing Wi-Fi and entering provisioning AP.\n", ssid.c_str());
      resetLocal();
      return;
    }
  }
  if (status != WL_CONNECTED && millis() - lastAttempt > 15000) {
    Serial.printf("[WiFi] Retrying SSID=\"%s\"; status=%s (%d)\n", ssid.c_str(), wifiStatusName(status), status);
    lastAttempt = millis(); WiFi.reconnect();
  }
}
