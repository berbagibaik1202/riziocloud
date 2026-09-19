#include "runtime.h"
DynamicJsonDocument identity(4096);
static String ca;
#ifdef ESP8266
static BearSSL::X509List *trust = nullptr;
#endif
String jsonText(JsonVariantConst value) { String out; serializeJson(value, out); return out; }
String topic(const char *suffix) { return "devices/" + identity["sn"].as<String>() + "/" + suffix; }
bool loadIdentity() {
  if (!LittleFS.begin()) return false; // Never format identity on mount failure.
  File file = LittleFS.open("/identity.json", "r");
  if (!file || deserializeJson(identity, file)) return false;
  if (identity["sn"].as<String>().length() < 4 || identity["device_key"].as<String>().length() < 32 ||
      identity["setup_code"].as<String>().length() < 12 || identity["setup_code"].as<String>().length() > 63 || !identity["mqtt_host"].is<const char *>() ||
      !identity["model"].is<const char *>() || !identity["hardware_version"].is<const char *>()) return false;
  File cert = LittleFS.open("/ca.pem", "r");
  if (!cert) return false;
  ca = cert.readString();
  if (ca.indexOf("BEGIN CERTIFICATE") < 0) return false;
#ifdef ESP8266
  trust = new BearSSL::X509List(ca.c_str());
#endif
  return true;
}
void configureTls(SecureClient &client) {
#ifdef ESP8266
  client.setTrustAnchors(trust);
#else
  client.setCACert(ca.c_str());
#endif
  client.setTimeout(10000);
}
bool saveWifi(const String &ssid, const String &password) {
  File f = LittleFS.open("/wifi.tmp", "w");
  if (!f) return false;
  StaticJsonDocument<256> doc; doc["ssid"] = ssid; doc["password"] = password;
  const bool ok = serializeJson(doc, f) > 0; f.close();
  return ok && LittleFS.rename("/wifi.tmp", "/wifi.json");
}
void resetLocal() {
  LittleFS.remove("/wifi.json"); LittleFS.remove("/wifi.tmp");
  // WiFi.persistent(false) prevents SDK credential persistence; preserve connection until ACK.
  restartAt = millis() + 300;
}
