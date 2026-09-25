#include "runtime.h"
uint32_t restartAt=0;
uint32_t localBusyUntil=0;
static bool ready=false,pressed=false;
static uint32_t pressedAt=0;
void setup() {
  Serial.begin(115200);
#ifdef ESP8266
  Serial.printf("\n[Boot] Reset reason: %s\n", ESP.getResetReason().c_str());
  Serial.printf("[Boot] Reset details: %s\n", ESP.getResetInfo().c_str());
  Serial.printf("[Boot] CPU: %u MHz\n", ESP.getCpuFreqMHz());
#endif
  if(!loadIdentity()) {Serial.println("Identity or CA unavailable; device halted.");return;}
  pinMode(identity["reset_pin"] | 0,INPUT_PULLUP);
  beginGpio(); beginSchedules(); beginTemperatureSensor(); beginWifi(); beginWeb(); beginDiscovery(); beginMqtt(); ready=true;
}
void loop() {
  if(!ready) {delay(100);return;}
  bool down=digitalRead(identity["reset_pin"] | 0)==LOW;
  if(down && !pressed) {pressed=true;pressedAt=millis();}
  if(!down) pressed=false;
  if(pressed && millis()-pressedAt>=10000 && !restartAt) resetLocal();
  if(restartAt && int32_t(millis()-restartAt)>=0) ESP.restart();
  tickWifi(); tickTemperatureSensor(); tickSchedules(); web.handleClient(); tickDiscovery(); tickMqtt(); delay(1);
}
