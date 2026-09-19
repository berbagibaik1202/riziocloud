#include "runtime.h"
bool provisioning = false;
static String ssid, password;
static uint32_t lastAttempt = 0;
static constexpr const char *DEFAULT_AP_PASSWORD = "rizio123456";
void beginWifi() {
  WiFi.persistent(false);
  StaticJsonDocument<256> doc;
  File f = LittleFS.open("/wifi.json", "r");
  if (f && !deserializeJson(doc, f)) { ssid = doc["ssid"].as<String>(); password = doc["password"].as<String>(); }
  if (!ssid.length()) {
    provisioning = true;
    WiFi.mode(WIFI_AP);
    String sn = identity["sn"].as<String>();
    WiFi.softAPConfig(IPAddress(192,168,4,1), IPAddress(192,168,4,1), IPAddress(255,255,255,0));
    WiFi.softAP(("RIZIO-" + sn.substring(sn.length() > 8 ? sn.length()-8 : 0)).c_str(), DEFAULT_AP_PASSWORD);
  } else {
    WiFi.mode(WIFI_STA); WiFi.begin(ssid.c_str(), password.c_str());
    configTime(0, 0, "pool.ntp.org", "time.google.com");
  }
}
void tickWifi() {
  if (!provisioning && WiFi.status() != WL_CONNECTED && millis() - lastAttempt > 15000) {
    lastAttempt = millis(); WiFi.reconnect();
  }
}
