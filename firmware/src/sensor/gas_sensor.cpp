#include "runtime.h"

static int gasPin = -1;
static bool gasActiveLow = true;
static bool gasDetected = false;
static float gasPpm = 0.0f;
static int gasRaw = 0;
static uint32_t lastGasRead = 0;
static bool gasInitialized = false;

void beginGasSensor() {
  gasPin = identity["gas_pin"] | -1;
  if (gasPin < 0 || gasPin > 39 || gasPin == (identity["reset_pin"] | 0)) {
    Serial.println("[Gas] Disabled: set a valid gas_pin in identity.json.");
    return;
  }
  for (size_t i = 0; i < channelCount; ++i) {
    if (channels[i].pin == gasPin) {
      Serial.printf("[Gas] Disabled: GPIO %d is already used by a relay.\n", gasPin);
      gasPin = -1;
      return;
    }
  }
  gasActiveLow = identity.containsKey("gas_active_low") ? (identity["gas_active_low"] | true) : true;
  pinMode(gasPin, INPUT_PULLUP);
  gasInitialized = true;
  Serial.printf("[Gas] Ready on GPIO %d (active_low=%d).\n", gasPin, gasActiveLow);
}

void tickGasSensor() {
  if (!gasInitialized || millis() - lastGasRead < 1000) return;
  lastGasRead = millis();

  // Digital reading from DO pin (Active LOW comparator on standard MQ modules)
  int pinVal = digitalRead(gasPin);
  gasDetected = gasActiveLow ? (pinVal == LOW) : (pinVal == HIGH);

  // Read analog value if available
#ifdef ESP8266
  gasRaw = analogRead(A0);
#else
  if (gasPin >= 32 && gasPin <= 39) {
    gasRaw = analogRead(gasPin);
  } else {
    gasRaw = gasDetected ? 800 : 150;
  }
#endif

  if (gasRaw > 0) {
    gasPpm = (float)gasRaw * 1.5f;
  } else {
    gasPpm = gasDetected ? 500.0f : 50.0f;
  }
}

void addGasSensorState(JsonObject state) {
  if (!gasInitialized) return;
  state["gas_detected"] = gasDetected;
  state["gas_raw"] = gasRaw;
  state["gas_ppm"] = gasPpm;
}
