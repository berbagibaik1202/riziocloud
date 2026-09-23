#include "runtime.h"
#ifdef ESP8266
extern "C" {
#include <user_interface.h>
}
#else
#include <esp_system.h>
#endif

static String accessKey, challenge;
static uint32_t challengeAt = 0;
static bool validKey(const String &key) {
  if (key.length() != 64) return false;
  for (size_t i = 0; i < key.length(); ++i)
    if (!isxdigit(static_cast<unsigned char>(key[i]))) return false;
  return true;
}
void loadLocalAccess() {
  File f = LittleFS.open("/local-access", "r");
  if (f) { String key = f.readString(); if (validKey(key)) accessKey = key; }
}
String localAccessKey() { return accessKey; }
bool saveLocalAccess(const String &key) {
  if (!validKey(key)) return false;
  File f = LittleFS.open("/local-access.tmp", "w");
  if (!f) return false;
  bool ok = f.print(key) == key.length(); f.close();
  if (!ok || !LittleFS.rename("/local-access.tmp", "/local-access")) return false;
  accessKey = key; challenge = ""; return true;
}
void clearLocalAccess() {
  accessKey = ""; challenge = "";
  LittleFS.remove("/local-access"); LittleFS.remove("/local-access.tmp");
}
String issueLocalChallenge() {
  uint8_t bytes[32];
#ifdef ESP8266
  if (os_get_random(bytes, sizeof(bytes)) != 0) return "";
#else
  esp_fill_random(bytes, sizeof(bytes));
#endif
  char hex[65];
  for (size_t i=0; i<sizeof(bytes); ++i) snprintf(hex+i*2, 3, "%02x", bytes[i]);
  challenge = hex; challengeAt = millis(); return challenge;
}
bool verifyLocalRequest(const String &authorization, const String &method, const String &path, const String &body) {
  if (!accessKey.length() || !challenge.length() || millis()-challengeAt > 15000) return false;
  if (!authorization.startsWith("Local ")) return false;
  String proof = authorization.substring(6);
  int separator = proof.indexOf(':');
  if (separator != 64 || proof.length() != 129 || proof.substring(0, separator) != challenge) return false;
  String message = identity["sn"].as<String>() + "\n" + challenge + "\n" + method + "\n" + path + "\n" + body;
  SHA256 hash; uint8_t digest[32]; char hex[65];
  hash.resetHMAC(accessKey.c_str(), accessKey.length());
  hash.update(message.c_str(), message.length());
  hash.finalizeHMAC(accessKey.c_str(), accessKey.length(), digest, sizeof(digest));
  for (size_t i=0; i<sizeof(digest); ++i) snprintf(hex+i*2, 3, "%02x", digest[i]);
  if (!constantEqual(proof.substring(separator+1), String(hex))) return false;
  challenge = ""; // A valid proof can be used only once, including for reads.
  return true;
}
