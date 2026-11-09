#include "runtime.h"

bool installOta(JsonObjectConst command, String &error) {
  Serial.println("\n[OTA] Processing firmware.update command...");
  if(command["model"].as<String>() != identity["model"].as<String>() ||
     command["hardware_version"].as<String>() != identity["hardware_version"].as<String>()) {
    error="OTA_HARDWARE_MISMATCH";
    Serial.printf("[OTA] ERROR: Hardware mismatch! Device is %s/%s, Target is %s/%s\n",
                  identity["model"].as<const char*>(), identity["hardware_version"].as<const char*>(),
                  command["model"].as<const char*>(), command["hardware_version"].as<const char*>());
    return false;
  }
  String url=command["url"] | "", checksum=command["checksum"] | "";
  size_t expected=command["file_size"] | size_t(0);
  if(!url.startsWith("https://") || checksum.length()!=64 || expected==0 || expected>0x300000) {
    error="OTA_INVALID_METADATA";
    Serial.printf("[OTA] ERROR: Invalid metadata. URL=%s, Size=%u, Checksum=%s\n", url.c_str(), expected, checksum.c_str());
    return false;
  }
  for(size_t i=0;i<checksum.length();++i) if(!isxdigit(checksum[i])) {error="OTA_INVALID_CHECKSUM";return false;}

  Serial.printf("[OTA] Downloading binary from: %s (%u bytes)\n", url.c_str(), expected);

  // Release the broker TLS buffers before creating HTTPS buffers on small ESP8266 heaps.
  mqtt.publish(topic("availability").c_str(),"{\"online\":false}",true);
  mqtt.disconnect(); tls.stop();

  // Withhold the last byte until SHA succeeds: failed images remain incomplete.
#ifdef ESP8266
  UpdaterClass updater;
#else
  UpdateClass updater;
#endif
  SecureClient download; configureTls(download); HTTPClient http;
  if(!http.begin(download,url)) {
    error="OTA_HTTPS_FAILED";
    Serial.println("[OTA] ERROR: HTTPClient begin failed (TLS/Network error).");
    return false;
  }
  http.setTimeout(15000);
  int status=http.GET();
  if(status!=HTTP_CODE_OK || http.getSize()!=int(expected)) {
    http.end();
    error="OTA_DOWNLOAD_FAILED";
    Serial.printf("[OTA] ERROR: Download failed! HTTP code=%d, size=%d (expected %u)\n", status, http.getSize(), expected);
    return false;
  }
  if(!updater.begin(expected,U_FLASH)) {
    http.end();
    error="OTA_NO_SPACE";
    Serial.println("[OTA] ERROR: Flash space insufficient for OTA image.");
    return false;
  }
  SHA256 hash; hash.reset(); uint8_t buffer[1024], finalByte=0; size_t received=0; uint32_t progress=millis(), started=millis();
  auto *stream=http.getStreamPtr();
  while(received<expected && millis()-progress<15000 && millis()-started<120000) {
    size_t available=stream->available();
    if(!available) {delay(1);continue;}
    size_t wanted=available<sizeof(buffer)?available:sizeof(buffer); if(wanted>expected-received) wanted=expected-received;
    int n=stream->readBytes(buffer,wanted); if(n<=0) continue;
    hash.update(buffer,n);
    size_t toWrite=n;
    if(received+size_t(n)==expected) {finalByte=buffer[n-1]; --toWrite;}
    if(toWrite && updater.write(buffer,toWrite)!=toWrite) {
      error="OTA_WRITE_FAILED";
      Serial.println("[OTA] ERROR: Flash write failed.");
      break;
    }
    received+=n;progress=millis();yield();
  }
  uint8_t digest[32];char hex[65];hash.finalize(digest,32);
  for(int i=0;i<32;++i) snprintf(hex+i*2,3,"%02x",digest[i]);
  checksum.toLowerCase();
  if(received!=expected || !constantEqual(checksum,String(hex))) {
    error="OTA_CHECKSUM_FAILED";
    Serial.printf("[OTA] ERROR: Checksum mismatch! Computed=%s, Expected=%s\n", hex, checksum.c_str());
  }
  http.end();
  if(error.length()) {
#ifdef ESP8266
    updater.end(false); // Incomplete (last byte withheld), always resets without eboot activation.
#else
    updater.abort();
#endif
    return false;
  }
  if(updater.write(&finalByte,1)!=1 || !updater.end()) {
    error="OTA_ACTIVATION_FAILED";
    Serial.println("[OTA] ERROR: Final flash write or activation failed.");
    return false;
  }
  Serial.println("[OTA] SUCCESS! Firmware flashed and verified successfully. Restarting...");
  return true;
}
