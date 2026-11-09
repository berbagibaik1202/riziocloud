#include "runtime.h"
DynamicJsonDocument identity(4096);
static String ca;
#ifdef ESP8266
static BearSSL::X509List *trust = nullptr;
#endif

static const char DEFAULT_ROOT_CA[] PROGMEM =
"-----BEGIN CERTIFICATE-----\n"
"MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw\n"
"TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh\n"
"cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4\n"
"WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu\n"
"ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY\n"
"MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc\n"
"h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+\n"
"0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U\n"
"A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW\n"
"T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH\n"
"B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC\n"
"B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv\n"
"KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn\n"
"OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn\n"
"jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw\n"
"qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI\n"
"rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV\n"
"HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq\n"
"hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL\n"
"ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ\n"
"3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK\n"
"NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5\n"
"ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur\n"
"TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC\n"
"jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc\n"
"oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq\n"
"4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA\n"
"mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d\n"
"emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=\n"
"-----END CERTIFICATE-----\n";

String jsonText(JsonVariantConst value) { String out; serializeJson(value, out); return out; }
String topic(const char *suffix) { return "devices/" + identity["sn"].as<String>() + "/" + suffix; }

bool saveIdentityFromSerial(const String &jsonText) {
  if (!LittleFS.begin()) {
    LittleFS.format();
    if (!LittleFS.begin()) return false;
  }
  DynamicJsonDocument doc(4096);
  DeserializationError err = deserializeJson(doc, jsonText);
  if (err) {
    Serial.printf("[RizIO] JSON deserialization failed: %s\n", err.c_str());
    return false;
  }
  if (doc["sn"].as<String>().length() < 4 || doc["device_key"].as<String>().length() < 32 ||
      !doc["mqtt_host"].is<const char *>() || !doc["model"].is<const char *>()) {
    Serial.println(F("[RizIO] Missing required fields in identity payload."));
    return false;
  }
  if (!doc["setup_code"].is<const char *>()) {
    doc["setup_code"] = "rizio123456";
  }
  if (!doc["hardware_version"].is<const char *>()) {
    doc["hardware_version"] = "1.0";
  }

  File f = LittleFS.open("/identity.json", "w");
  if (!f) return false;
  serializeJson(doc, f);
  f.close();

  if (!LittleFS.exists("/ca.pem")) {
    File cert = LittleFS.open("/ca.pem", "w");
    if (cert) {
      cert.print(DEFAULT_ROOT_CA);
      cert.close();
    }
  }

  return true;
}

bool loadIdentity() {
  if (!LittleFS.begin()) return false; // Never format identity on mount failure.
  File file = LittleFS.open("/identity.json", "r");
  if (!file || deserializeJson(identity, file)) return false;
  if (identity["sn"].as<String>().length() < 4 || identity["device_key"].as<String>().length() < 32 ||
      identity["setup_code"].as<String>().length() < 12 || identity["setup_code"].as<String>().length() > 63 || !identity["mqtt_host"].is<const char *>() ||
      !identity["model"].is<const char *>() || !identity["hardware_version"].is<const char *>()) return false;
  
  if (!LittleFS.exists("/ca.pem")) {
    File cert = LittleFS.open("/ca.pem", "w");
    if (cert) {
      cert.print(DEFAULT_ROOT_CA);
      cert.close();
    }
  }

  File cert = LittleFS.open("/ca.pem", "r");
  if (cert) {
    ca = cert.readString();
  }
  if (ca.indexOf("BEGIN CERTIFICATE") < 0) {
    ca = String(DEFAULT_ROOT_CA);
  }

#ifdef ESP8266
  trust = new BearSSL::X509List(ca.c_str());
  // X509List owns the parsed trust anchors; do not retain a second PEM copy.
  ca = String();
#endif
  identity.shrinkToFit();
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
  if (!ok) { LittleFS.remove("/wifi.tmp"); return false; }
  // LittleFS may reject rename() when the destination already exists.
  // Remove the old credentials only after the new temporary file is complete.
  LittleFS.remove("/wifi.json");
  return LittleFS.rename("/wifi.tmp", "/wifi.json");
}
void resetLocal() {
  clearLocalAccess();
  LittleFS.remove("/wifi.json"); LittleFS.remove("/wifi.tmp");
  // WiFi.persistent(false) prevents SDK credential persistence; preserve connection until ACK.
  restartAt = millis() + 300;
}
