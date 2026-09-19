#include "runtime.h"
bool installOta(JsonObjectConst command, String &error) {
  if(command["model"].as<String>() != identity["model"].as<String>() ||
     command["hardware_version"].as<String>() != identity["hardware_version"].as<String>()) {
    error="OTA_HARDWARE_MISMATCH"; return false;
  }
  String url=command["url"] | "", checksum=command["checksum"] | "";
  size_t expected=command["file_size"] | size_t(0);
  if(!url.startsWith("https://") || checksum.length()!=64 || expected==0 || expected>0x300000) {error="OTA_INVALID_METADATA";return false;}
  for(size_t i=0;i<checksum.length();++i) if(!isxdigit(checksum[i])) {error="OTA_INVALID_CHECKSUM";return false;}
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
  if(!http.begin(download,url)) {error="OTA_HTTPS_FAILED";return false;}
  http.setTimeout(10000);
  int status=http.GET();
  if(status!=HTTP_CODE_OK || http.getSize()!=int(expected)) {http.end();error="OTA_DOWNLOAD_FAILED";return false;}
  if(!updater.begin(expected,U_FLASH)) {http.end();error="OTA_NO_SPACE";return false;}
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
    if(toWrite && updater.write(buffer,toWrite)!=toWrite) {error="OTA_WRITE_FAILED";break;}
    received+=n;progress=millis();yield();
  }
  uint8_t digest[32];char hex[65];hash.finalize(digest,32);
  for(int i=0;i<32;++i) snprintf(hex+i*2,3,"%02x",digest[i]);
  checksum.toLowerCase();
  if(received!=expected || !constantEqual(checksum,String(hex))) error="OTA_CHECKSUM_FAILED";
  http.end();
  if(error.length()) {
#ifdef ESP8266
    updater.end(false); // Incomplete (last byte withheld), always resets without eboot activation.
#else
    updater.abort();
#endif
    return false;
  }
  if(updater.write(&finalByte,1)!=1 || !updater.end()) {error="OTA_ACTIVATION_FAILED";return false;}
  return true;
}
