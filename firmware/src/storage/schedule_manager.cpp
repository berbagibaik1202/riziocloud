#include "runtime.h"

static StaticJsonDocument<4096> scheduleDoc;
static uint32_t lastScheduleTick = 0;

static bool saveSchedules() {
  File file = LittleFS.open("/schedules.tmp", "w");
  if (!file) return false;
  const bool ok = serializeJson(scheduleDoc, file) > 0;
  file.close();
  return ok && LittleFS.rename("/schedules.tmp", "/schedules.json");
}

static bool runAlready(const String &runId) {
  JsonObject runs = scheduleDoc["runs"].as<JsonObject>();
  return runs[runId].is<bool>() && runs[runId].as<bool>();
}
static void rememberRun(const String &runId) {
  JsonObject runs = scheduleDoc["runs"].as<JsonObject>();
  if (runs.size() >= 64) runs.clear();
  runs[runId] = true;
}

static bool applyActions(JsonArrayConst actions) {
  bool ok = true;
  for (JsonObjectConst action : actions) {
    int pin = action["pin"] | -1;
    if (pin < 0 || !action["state"].is<bool>() || !setGpio(pin, action["state"].as<bool>())) ok = false;
  }
  return ok;
}

void beginSchedules() {
  File file = LittleFS.open("/schedules.json", "r");
  if (!file || deserializeJson(scheduleDoc, file)) {
    scheduleDoc.clear();
    scheduleDoc.createNestedArray("schedules");
    scheduleDoc.createNestedObject("runs");
  }
  if (!scheduleDoc["schedules"].is<JsonArray>()) scheduleDoc.createNestedArray("schedules");
  if (!scheduleDoc["runs"].is<JsonObject>()) scheduleDoc.createNestedObject("runs");
  if (file) file.close();
}

bool syncSchedules(JsonObjectConst input) {
  JsonArrayConst incoming = input["schedules"].as<JsonArrayConst>();
  if (incoming.isNull()) return false;
  static StaticJsonDocument<4096> next;
  next.clear();
  JsonArray saved = next.createNestedArray("schedules");
  for (JsonObjectConst item : incoming) {
    if (!item["id"].is<const char *>() || !item["time_local"].is<const char *>() || !item["actions"].is<JsonArray>()) continue;
    saved.add(item);
  }
  JsonObject runs = next.createNestedObject("runs");
  for (JsonPairConst item : scheduleDoc["runs"].as<JsonObjectConst>()) runs[item.key()] = item.value();
  scheduleDoc = next;
  return saveSchedules();
}

bool applyScheduledScene(JsonObjectConst input) {
  const String runId = input["run_id"] | "";
  if (runId.length() < 8 || runAlready(runId)) return runId.length() >= 8;
  JsonArrayConst actions = input["actions"].as<JsonArrayConst>();
  if (actions.isNull() || !applyActions(actions)) return false;
  rememberRun(runId);
  return saveSchedules();
}

void tickSchedules() {
  if (millis() - lastScheduleTick < 1000 || time(nullptr) < 1700000000) return;
  lastScheduleTick = millis();
  time_t now = time(nullptr);
  JsonArray schedules = scheduleDoc["schedules"].as<JsonArray>();
  bool changed = false;
  for (JsonObject schedule : schedules) {
    if (!(schedule["enabled"] | false)) continue;
    int offset = schedule["tz_offset_minutes"] | 0;
    time_t localEpoch = now + offset * 60;
    struct tm localTime;
#ifdef ESP8266
    gmtime_r(&localEpoch, &localTime);
#else
    gmtime_r(&localEpoch, &localTime);
#endif
    char dateKey[64];
    snprintf(dateKey, sizeof(dateKey), "%04d-%02d-%02dT%02d:%02d", localTime.tm_year + 1900, localTime.tm_mon + 1, localTime.tm_mday, localTime.tm_hour, localTime.tm_min);
    String wanted = schedule["time_local"] | "";
    char current[6]; snprintf(current, sizeof(current), "%02d:%02d", localTime.tm_hour, localTime.tm_min);
    if (wanted != current) continue;
    bool weekday = false;
    for (int day : schedule["weekdays"].as<JsonArrayConst>()) if (day == localTime.tm_wday) weekday = true;
    if (!weekday) continue;
    String runId = String(schedule["id"] | "") + ":" + dateKey;
    if (runAlready(runId)) continue;
    if (applyActions(schedule["actions"].as<JsonArrayConst>())) {
      rememberRun(runId);
      changed = true;
      Serial.printf("[Schedule] Executed %s\n", runId.c_str());
    }
  }
  if (changed) saveSchedules();
}
