#include "runtime.h"
Channel channels[16]; size_t channelCount = 0;
static bool safePin(int pin) {
#ifdef ESP8266
  // GPIO2 is the NodeMCU onboard LED; configure its channel as active_low.
  return pin == 2 || pin == 4 || pin == 5 || pin == 12 || pin == 13 || pin == 14;
#else
  return pin == 4 || pin == 13 || pin == 14 || pin == 16 || pin == 17 || pin == 18 || pin == 19 || pin == 21 || pin == 22 || pin == 23 || pin == 25 || pin == 26 || pin == 27 || pin == 32 || pin == 33;
#endif
}
void beginGpio() {
  for (JsonObject c : identity["channels"].as<JsonArray>()) {
    int pin = c["pin"] | -1; bool duplicate = false;
    for (size_t i=0; i<channelCount; ++i) if (channels[i].pin == pin) duplicate = true;
    if (channelCount == 16 || !safePin(pin) || duplicate || pin == (identity["reset_pin"] | 0) || String(c["type"] | "") != "switch") continue;
    bool low = c["active_low"] | false;
    digitalWrite(pin, low ? HIGH : LOW); pinMode(pin, OUTPUT);
    channels[channelCount++] = {pin, low, false};
    Serial.printf("[GPIO] Channel ready: pin=%d active_low=%d\n", pin, low);
  }
}
bool setGpio(int pin, bool state) {
  for (size_t i=0; i<channelCount; ++i) if (channels[i].pin == pin) {
    channels[i].state = state; digitalWrite(pin, state != channels[i].activeLow ? HIGH : LOW); return true;
  }
  Serial.printf("[GPIO] Rejected pin=%d; configured channels=%u\n", pin, static_cast<unsigned>(channelCount));
  return false;
}
void addState(JsonObject state) {
  JsonObject gpio = state.createNestedObject("gpio");
  JsonObject channelState = state.createNestedObject("channels");
  for (size_t i=0; i<channelCount; ++i) {
    gpio[String(channels[i].pin)] = channels[i].state;
    for (JsonObject c : identity["channels"].as<JsonArray>()) if ((c["pin"] | -1) == channels[i].pin) { channelState[String(c["id"] | 0)] = channels[i].state; break; }
  }
  state["rssi"] = WiFi.RSSI(); state["ip_address"] = WiFi.localIP().toString();
  state["uptime"] = millis()/1000; state["free_heap"] = ESP.getFreeHeap(); state["firmware_version"] = FIRMWARE_VERSION;
  addTemperatureState(state);
}
