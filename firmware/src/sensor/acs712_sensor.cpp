#include "runtime.h"
#include <math.h>

static int acsPin = -1;
static float sensitivityMvPerA = 185.0f;
static float zeroMv = NAN;
static float currentA = NAN;
static uint32_t lastRead = 0;

void beginCurrentSensor() {
  acsPin = identity["acs712_pin"] | -1;
  sensitivityMvPerA = identity["acs712_sensitivity_mv_per_a"] | 185.0f;
  zeroMv = identity["acs712_zero_mv"] | NAN;
  if (acsPin < 0 || acsPin > 39 || sensitivityMvPerA <= 0) {
    acsPin = -1;
    Serial.println(F("[ACS712] Disabled: configure a valid acs712_pin and sensitivity."));
    return;
  }
  const int resetPin = identity["reset_pin"] | 0;
  if (acsPin == resetPin) { acsPin = -1; Serial.println(F("[ACS712] Disabled: pin conflicts with reset_pin.")); return; }
  for (size_t i = 0; i < channelCount; i++) if (channels[i].pin == acsPin) {
    acsPin = -1; Serial.println(F("[ACS712] Disabled: pin conflicts with a channel.")); return;
  }
  pinMode(acsPin, INPUT);
#ifdef ESP32
  analogReadResolution(12);
#endif
  Serial.printf("[ACS712] Ready on GPIO %d, sensitivity %.1f mV/A.\n", acsPin, sensitivityMvPerA);
}

void tickCurrentSensor() {
  if (acsPin < 0 || millis() - lastRead < 1000) return;
  lastRead = millis();
#ifdef ESP32
  const float adcMax = 4095.0f;
  const float referenceMv = 3300.0f;
  const int samplePin = acsPin;
#else
  const float adcMax = 1023.0f;
  const float referenceMv = 1000.0f; // ESP8266 A0 input range; use a board divider as required.
  if (acsPin != 17 && acsPin != 0) return; // A0 is the only ADC input on ESP8266.
  const int samplePin = A0;
#endif
  double sum = 0;
  double sumSquares = 0;
  uint16_t samples = 256;
  for (uint16_t i = 0; i < samples; i++) {
    const float sample = analogRead(samplePin);
    sum += sample;
    sumSquares += (double)sample * sample;
    delayMicroseconds(150);
  }
  // Remove the measured ADC midpoint. ACS712 output is biased around VCC/2,
  // but the actual midpoint varies by sensor and board; assuming exactly half
  // scale can erase or distort the AC RMS signal.
  const float meanRaw = sum / samples;
  const float calibratedZeroRaw = isnan(zeroMv)
      ? meanRaw
      : zeroMv * adcMax / referenceMv;
  const float varianceRaw = fmaxf(0.0f,
      (sumSquares / samples) - (meanRaw * meanRaw));
  const float rmsDeltaRaw = sqrt(varianceRaw +
      (meanRaw - calibratedZeroRaw) * (meanRaw - calibratedZeroRaw));
  const float rmsDeltaMv = rmsDeltaRaw * referenceMv / adcMax;
  currentA = rmsDeltaMv / sensitivityMvPerA;
  if (currentA < 0.03f) currentA = 0;
  reportCurrentSample(currentA, "acs712");
}

void addCurrentSensorState(JsonObject state) {
  if (acsPin < 0 || isnan(currentA)) return;
  state["current_a"] = currentA;
}
