#include "runtime.h"
uint32_t restartAt=0;
uint32_t localBusyUntil=0;
static bool ready=false,pressed=false;
static uint32_t pressedAt=0;

void awaitSerialIdentity() {
  Serial.println(F("[RizIO] READY_FOR_IDENTITY"));
  uint32_t lastPrompt = millis();
  String buffer = "";
  buffer.reserve(2048);
  while (true) {
    if (millis() - lastPrompt >= 2000) {
      Serial.println(F("[RizIO] READY_FOR_IDENTITY"));
      lastPrompt = millis();
    }
    while (Serial.available()) {
      char c = (char)Serial.read();
      if (c == '\n' || c == '\r') {
        if (buffer.length() > 0) {
          buffer.trim();
          if (buffer.startsWith("SET_IDENTITY:")) {
            String payload = buffer.substring(13);
            if (saveIdentityFromSerial(payload)) {
              Serial.println(F("[RizIO] IDENTITY_SAVED_RESTARTING"));
              delay(300);
              ESP.restart();
            } else {
              Serial.println(F("[RizIO] ERROR_INVALID_IDENTITY"));
            }
          }
          buffer = "";
          buffer.reserve(2048);
        }
      } else {
        if (buffer.length() < 3000) buffer += c;
      }
    }
    yield();
    delay(1);
  }
}

void checkSerialCommands() {
  static String serialBuf = "";
  static bool serialBufReserved = false;
  if (!serialBufReserved) {
    serialBuf.reserve(2048);
    serialBufReserved = true;
  }
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (serialBuf.length() > 0) {
        serialBuf.trim();
        if (serialBuf.startsWith("SET_IDENTITY:")) {
          if (saveIdentityFromSerial(serialBuf.substring(13))) {
            Serial.println(F("[RizIO] IDENTITY_SAVED_RESTARTING"));
            delay(300);
            ESP.restart();
          } else {
            Serial.println(F("[RizIO] ERROR_INVALID_IDENTITY"));
          }
        }
        serialBuf = "";
        serialBuf.reserve(2048);
      }
    } else {
      if (serialBuf.length() < 3000) serialBuf += c;
    }
  }
}

void setup() {
  Serial.begin(115200);
#ifdef ESP8266
  Serial.printf("\n[Boot] Reset reason: %s\n", ESP.getResetReason().c_str());
  Serial.printf("[Boot] Reset details: %s\n", ESP.getResetInfo().c_str());
  Serial.printf("[Boot] CPU: %u MHz\n", ESP.getCpuFreqMHz());
#endif
  if(!loadIdentity()) {
    Serial.println(F("[RizIO] Identity unavailable; entering serial injection mode."));
    awaitSerialIdentity();
    return;
  }
  pinMode(identity["reset_pin"] | 0,INPUT_PULLUP);
  beginGpio(); beginSchedules(); beginTemperatureSensor(); beginPowerSensor(); beginGasSensor(); beginWifi(); beginWeb(); beginDiscovery(); beginMqtt(); ready=true;
}
void loop() {
  checkSerialCommands();
  if(!ready) {delay(100);return;}
  bool down=digitalRead(identity["reset_pin"] | 0)==LOW;
  if(down && !pressed) {pressed=true;pressedAt=millis();}
  if(!down) pressed=false;
  if(pressed && millis()-pressedAt>=10000 && !restartAt) resetLocal();
  if(restartAt && int32_t(millis()-restartAt)>=0) ESP.restart();
  tickWifi(); tickTemperatureSensor(); tickPowerSensor(); tickGasSensor(); tickSchedules(); web.handleClient(); tickDiscovery(); tickMqtt(); delay(1);
}
