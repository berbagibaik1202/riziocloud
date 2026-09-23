#include "runtime.h"

static DHT *sensor = nullptr;
static int sensorPin = -1;
static float temperatureC = NAN;
static float humidityPercent = NAN;
static uint32_t lastRead = 0;

void beginTemperatureSensor() {
  sensorPin = identity["dht11_pin"] | -1;
  if (sensorPin < 0 || sensorPin > 39 || sensorPin == (identity["reset_pin"] | 0)) {
    Serial.println("[DHT11] Disabled: set a valid, unused dht11_pin in identity.json.");
    return;
  }
  for (size_t i = 0; i < channelCount; ++i) {
    if (channels[i].pin == sensorPin) {
      Serial.printf("[DHT11] Disabled: GPIO %d is already used by a relay.\n", sensorPin);
      sensorPin = -1;
      return;
    }
  }
  sensor = new DHT(sensorPin, DHT11);
  sensor->begin();
  Serial.printf("[DHT11] Ready on GPIO %d.\n", sensorPin);
}

void tickTemperatureSensor() {
  if (!sensor || millis() - lastRead < 2500) return;
  lastRead = millis();
  const float nextTemperature = sensor->readTemperature();
  const float nextHumidity = sensor->readHumidity();
  if (isnan(nextTemperature) || isnan(nextHumidity)) {
    Serial.println("[DHT11] Read failed; keeping the last valid value.");
    return;
  }
  temperatureC = nextTemperature;
  humidityPercent = nextHumidity;
}

void addTemperatureState(JsonObject state) {
  if (!sensor || isnan(temperatureC)) return;
  state["temperature_c"] = temperatureC;
  state["humidity_percent"] = humidityPercent;
}
