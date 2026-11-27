#include "runtime.h"
#include <math.h>

static float thresholdA = 0;
static String source = "auto";
static bool tripped = false;
static float tripCurrentA = NAN;
static String tripSource;
static uint32_t tripId = 0;
static float pzemCurrentA = NAN;
static float acsCurrentA = NAN;
static uint32_t pzemSampleAt = 0;
static uint32_t acsSampleAt = 0;

static bool saveProtection() {
  DynamicJsonDocument doc(384);
  doc["threshold_a"] = thresholdA;
  doc["source"] = source;
  doc["tripped"] = tripped;
  if (!isnan(tripCurrentA)) doc["trip_current_a"] = tripCurrentA;
  doc["trip_source"] = tripSource;
  doc["trip_id"] = tripId;
  File file = LittleFS.open("/protection.tmp", "w");
  if (!file) return false;
  const bool written = serializeJson(doc, file) > 0;
  file.close();
  if (!written) { LittleFS.remove("/protection.tmp"); return false; }
  LittleFS.remove("/protection.json");
  return LittleFS.rename("/protection.tmp", "/protection.json");
}

void beginOvercurrentProtection() {
  File file = LittleFS.open("/protection.json", "r");
  if (!file) return;
  DynamicJsonDocument doc(384);
  if (!deserializeJson(doc, file)) {
    const float configured = doc["threshold_a"] | 0.0f;
    const String configuredSource = doc["source"] | "auto";
    if (configured >= 0 && configured <= 500 &&
        (configuredSource == "auto" || configuredSource == "pzem" || configuredSource == "acs712")) {
      thresholdA = configured;
      source = configuredSource;
    }
    tripped = doc["tripped"] | false;
    tripCurrentA = doc["trip_current_a"] | NAN;
    tripSource = doc["trip_source"] | "";
    tripId = doc["trip_id"] | uint32_t(0);
  }
  file.close();
  Serial.printf("[Protection] %s; threshold=%.2f A, source=%s\n",
                tripped ? "LATCHED TRIP" : (thresholdA > 0 ? "armed" : "disabled"),
                thresholdA, source.c_str());
}

bool overcurrentIsTripped() { return tripped; }

bool configureOvercurrentProtection(float requestedThreshold, const String &requestedSource) {
  if (!isfinite(requestedThreshold) || requestedThreshold < 0 || requestedThreshold > 100 || (requestedThreshold > 0 && requestedThreshold < 0.1f)) return false;
  if (requestedSource != "auto" && requestedSource != "pzem" && requestedSource != "acs712") return false;
  if (requestedSource == "pzem" && (identity["pzem_rx_pin"].isNull() || identity["pzem_tx_pin"].isNull())) return false;
  if (requestedSource == "acs712" && identity["acs712_pin"].isNull()) return false;
  const bool hasPzem = !identity["pzem_rx_pin"].isNull() && !identity["pzem_tx_pin"].isNull();
  const bool hasAcs712 = !identity["acs712_pin"].isNull();
  const float maximum = requestedSource == "pzem" || (requestedSource == "auto" && hasPzem && !hasAcs712) ? 100.0f : 30.0f;
  if (requestedThreshold > maximum) return false;
  const float oldThreshold = thresholdA;
  const String oldSource = source;
  thresholdA = requestedThreshold;
  source = requestedSource;
  const bool saved = saveProtection();
  if (!saved) { thresholdA = oldThreshold; source = oldSource; return false; }
  Serial.printf("[Protection] %s threshold %.2f A on %s\n", thresholdA > 0 ? "Configured" : "Disabled", thresholdA, source.c_str());
  markStateChanged();
  return saved;
}

void reportCurrentSample(float current, const char *sensorSource) {
  if (!isfinite(current) || current < 0) return;
  const String sampleSource(sensorSource);
  if (sampleSource == "pzem") { pzemCurrentA = current; pzemSampleAt = millis(); }
  else if (sampleSource == "acs712") { acsCurrentA = current; acsSampleAt = millis(); }
  if (thresholdA <= 0 || tripped || (source != "auto" && source != sampleSource) || current <= thresholdA) return;

  tripped = true;
  tripCurrentA = current;
  tripSource = sampleSource;
  ++tripId;
  for (size_t i = 0; i < channelCount; ++i) setGpio(channels[i].pin, false);
  saveProtection();
  Serial.printf("[Protection] OVERCURRENT %.3f A > %.3f A (%s); all relays OFF and trip latched.\n",
                current, thresholdA, sampleSource.c_str());
  markStateChanged();
}

bool resetOvercurrentProtection(String &error) {
  if (!tripped) { error = "NO_ACTIVE_TRIP"; return false; }
  if (thresholdA <= 0) { error = "PROTECTION_DISABLED"; return false; }
  const bool trippedByPzem = tripSource == "pzem";
  const float latestTripCurrent = trippedByPzem ? pzemCurrentA : acsCurrentA;
  const uint32_t latestTripAt = trippedByPzem ? pzemSampleAt : acsSampleAt;
  const uint32_t maxAge = trippedByPzem ? 10000 : 5000;
  if (tripSource != "pzem" && tripSource != "acs712") {
    error = "CURRENT_UNAVAILABLE"; return false;
  }
  if (isnan(latestTripCurrent) || millis() - latestTripAt > maxAge) {
    error = "CURRENT_UNAVAILABLE"; return false;
  }
  if (latestTripCurrent > thresholdA) {
    error = "OVERCURRENT_STILL_PRESENT"; return false;
  }
  tripped = false;
  if (!saveProtection()) { tripped = true; error = "STORAGE_ERROR"; return false; }
  Serial.println(F("[Protection] Trip manually reset; relays remain OFF."));
  markStateChanged();
  return true;
}

void addOvercurrentState(JsonObject state) {
  state["overcurrent_limit_a"] = thresholdA;
  state["overcurrent_source"] = source;
  state["overcurrent_tripped"] = tripped;
  state["overcurrent_trip_id"] = tripId;
  if (!isnan(tripCurrentA) && tripId > 0) {
    state["overcurrent_trip_current_a"] = tripCurrentA;
    state["overcurrent_trip_source"] = tripSource;
  }
}

void tickOvercurrentProtection() {
  // Sensor drivers evaluate each fresh, valid sample directly; this keeps the
  // trip decision local and independent of Wi-Fi, MQTT, or the cloud.
}
