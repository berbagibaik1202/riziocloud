#include "runtime.h"
bool constantEqual(const String &a, const String &b) {
  if (a.length() != b.length()) return false;
  uint8_t diff = 0; for (size_t i=0; i<a.length(); ++i) diff |= a[i] ^ b[i]; return diff == 0;
}
static String decode64(const String &input) {
  const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  String result; unsigned acc=0; int bits=0;
  for (size_t i=0; i<input.length(); ++i) {
    const char *p = strchr(alphabet, input[i]); if (!p) return "";
    acc = (acc << 6) | (p-alphabet); bits += 6;
    if (bits >= 8) { bits -= 8; result += char((acc >> bits)&255); }
  }
  return result;
}
bool verifyToken(const String &token) {
  time_t now = time(nullptr);
  if (now < 1700000000 || token.length() > 512) return false;
  int dot = token.indexOf('.'); if (dot <= 0 || token.length()-dot-1 != 64) return false;
  String payload = token.substring(0,dot), signature = token.substring(dot+1);
  String key = identity["device_key"].as<String>();
  SHA256 hash; uint8_t digest[32];
  hash.resetHMAC(key.c_str(), key.length()); hash.update(payload.c_str(), payload.length()); hash.finalizeHMAC(key.c_str(), key.length(), digest, sizeof(digest));
  char hex[65]; for (int i=0;i<32;++i) snprintf(hex+i*2,3,"%02x",digest[i]);
  if (!constantEqual(signature, String(hex))) return false;
  StaticJsonDocument<256> doc;
  if (deserializeJson(doc, decode64(payload))) return false;
  int64_t expiry = doc["exp"] | int64_t(0);
  return doc["sn"].as<String>() == identity["sn"].as<String>() && doc["scope"].as<String>() == "local" && expiry > now && expiry <= int64_t(now)+60;
}
