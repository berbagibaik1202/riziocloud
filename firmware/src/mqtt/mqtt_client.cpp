#include "runtime.h"
SecureClient tls; PubSubClient mqtt(tls);
static uint32_t lastConnect=0,lastTelemetry=0;
static uint32_t retryDelay=5000;
static uint32_t lastTimeLog=0;
static bool waitingForTime=false;
#ifdef ESP8266
static bool fragmentProbed=false;
static constexpr uint16_t MQTT_TLS_FRAGMENT=4096;
static uint16_t tlsReceiveSize=16384;
static void logHeap(const char *stage) {
  Serial.printf("[Memory] %s: free=%u, largest=%u, fragmentation=%u%%, uptime=%lu s\n",
                stage, ESP.getFreeHeap(), ESP.getMaxFreeBlockSize(), ESP.getHeapFragmentation(), millis()/1000);
}
static bool prepareMqttTls() {
  logHeap("before TLS");
  if (!fragmentProbed) {
    // Shrink receive records only after the broker confirms MFLN support.
    bool supported=SecureClient::probeMaxFragmentLength(identity["mqtt_host"].as<const char *>(), identity["mqtt_port"] | 8883, MQTT_TLS_FRAGMENT);
    tlsReceiveSize=supported ? MQTT_TLS_FRAGMENT : 16384;
    tls.setBufferSizes(tlsReceiveSize, 512);
    fragmentProbed=true;
    Serial.printf("[MQTT] MFLN %u: %s; TLS buffers RX=%u TX=512\n", MQTT_TLS_FRAGMENT, supported ? "supported" : "not confirmed", tlsReceiveSize);
    logHeap("after MFLN probe");
  }
  // Leave headroom for TLS handshake allocations and the Wi-Fi SDK.
  // Keep enough headroom for the TLS handshake without blocking cloud
  // reconnects after normal heap fragmentation during long local operation.
  if (ESP.getFreeHeap()<uint32_t(tlsReceiveSize)+8192 || ESP.getMaxFreeBlockSize()<uint32_t(tlsReceiveSize)+512) {
    Serial.println("[MQTT] TLS deferred: insufficient heap headroom; local control remains available.");
    fragmentProbed=false;
    return false;
  }
  return true;
}
#endif
static String pendingAck;
struct Cached { String id, fingerprint, ack; }; static Cached cache[24]; static uint8_t cursor=0;
void publishState() { if (!mqtt.connected()) return; DynamicJsonDocument doc(2048); addState(doc.to<JsonObject>()); mqtt.publish(topic("state").c_str(),jsonText(doc.as<JsonVariantConst>()).c_str(),true); }
String executeCommand(JsonObjectConst input, bool local) {
  String id=input["request_id"] | "", cmd=input["cmd"] | "";
  String fingerprint=cmd+":"+String(input["channel_id"] | -1)+":"+String(input["pin"] | -1)+":"+String(input["state"] | false)+":"+String(input["url"] | "")+":"+String(input["checksum"] | "")+":"+String(input["file_size"] | 0)+":"+String(input["version"] | "");
  DynamicJsonDocument result(2048); result["request_id"]=id;
  String error;
  if(id.length()<8 || id.length()>64) error="INVALID_REQUEST_ID";
  if(!error.length()) for(auto &entry:cache) if(entry.id==id) {
    if(entry.fingerprint==fingerprint) return entry.ack;
    error="REQUEST_ID_CONFLICT"; break;
  }
  if(!error.length() && !local) {
    int64_t stamp=input["timestamp"] | int64_t(0), now=time(nullptr);
    if(now<1700000000 || stamp<now-120 || stamp>now+30) error="COMMAND_EXPIRED";
  }
  if(!error.length()) {
    if(cmd=="schedule.sync") {
      if(!syncSchedules(input)) error="INVALID_SCHEDULE";
    } else if(cmd=="scene.apply") {
      if(!applyScheduledScene(input)) error="INVALID_SCENE";
    } else if(cmd=="gpio.set") {
      int pin=input["pin"] | -1; int channelId=input["channel_id"] | -1;
      if(channelId>0) { for(JsonObject c : identity["channels"].as<JsonArray>()) if((c["id"] | -1)==channelId) { int configured=c["pin"] | -1; if(pin>=0 && pin!=configured) error="INVALID_GPIO"; pin=configured; break; } }
      if(!error.length() && (!input["state"].is<bool>() || pin<0 || !setGpio(pin,input["state"]))) error="INVALID_GPIO";
    } else if(local) error="COMMAND_NOT_ALLOWED";
    else if(cmd=="system.reboot") restartAt=millis()+500;
    else if(cmd=="system.factory_reset") resetLocal();
    else if(cmd=="firmware.update") { if(installOta(input,error)) restartAt=millis()+1000; }
    else error="UNKNOWN_COMMAND";
  }
  result["success"]=!error.length();
  if(error.length()) result["error"]=error; else addState(result.createNestedObject("state"));
  String out=jsonText(result.as<JsonVariantConst>());
  if(id.length()>=8 && error!="REQUEST_ID_CONFLICT") {cache[cursor]={id,fingerprint,out};cursor=(cursor+1)%24;}
  publishState(); return out;
}
void beginMqtt() {
  configureTls(tls); mqtt.setServer(identity["mqtt_host"].as<const char *>(),identity["mqtt_port"] | 8883);
  // Maximum accepted command is 2048 bytes, plus topic and MQTT header.
  if (!mqtt.setBufferSize(2560)) Serial.println("[MQTT] Packet buffer allocation failed.");
  mqtt.setKeepAlive(30); mqtt.setSocketTimeout(5);
  mqtt.setCallback([](char *incoming, byte *payload, unsigned length){
    if(String(incoming)!=topic("command") || length>2048) return;
    DynamicJsonDocument doc(3072); if(deserializeJson(doc,payload,length)) return;
    String response=executeCommand(doc.as<JsonObjectConst>(),false);
    if(!mqtt.publish(topic("response").c_str(),response.c_str())) {
      pendingAck=response;
      if(restartAt) restartAt=millis()+15000;
    }
  });
}
void tickMqtt() {
  if(provisioning || WiFi.status()!=WL_CONNECTED) return;
  if(time(nullptr)<1700000000) {
    if(!waitingForTime || millis()-lastTimeLog>=15000) {
      Serial.println("[MQTT] Waiting for NTP time synchronization before TLS connection.");
      lastTimeLog=millis(); waitingForTime=true;
    }
    return;
  }
  if(waitingForTime) { Serial.println("[MQTT] Time synchronized."); waitingForTime=false; }
  if(!mqtt.connected() && millis()-lastConnect>retryDelay &&
      (!localBusyUntil || int32_t(millis()-localBusyUntil)>=0)) {
    lastConnect=millis(); const char *sn=identity["sn"];
#ifdef ESP8266
    if (!prepareMqttTls()) { lastConnect=millis(); retryDelay=60000; return; }
#endif
    Serial.printf("[MQTT] Connecting to %s:%d...\n", identity["mqtt_host"].as<const char *>(), identity["mqtt_port"] | 8883);
    if(mqtt.connect(sn,sn,identity["device_key"].as<const char *>(),topic("availability").c_str(),1,true,"{\"online\":false}")) {
      mqtt.subscribe(topic("command").c_str(),1); mqtt.publish(topic("availability").c_str(),"{\"online\":true}",true); publishState();
      Serial.println("[MQTT] Connected; online availability and state publish attempted.");
      retryDelay=5000;
#ifdef ESP8266
      Serial.printf("[MQTT] Negotiated MFLN: %s\n", tls.getMFLNStatus() ? "yes" : "no");
      logHeap("MQTT connected");
#endif
    } else {
      Serial.printf("[MQTT] Connection failed: state=%d\n", mqtt.state());
#ifdef ESP8266
      char tlsError[160] = {};
      int tlsCode = tls.getLastSSLError(tlsError, sizeof(tlsError));
      Serial.printf("[MQTT] TLS error=%d: %s\n", tlsCode, tlsError);
      tls.stop();
      logHeap("connection failed");
#endif
      retryDelay = retryDelay < 60000 ? retryDelay * 2 : 60000;
      if (retryDelay > 60000) retryDelay=60000;
      lastConnect=millis();
    }
  }
  mqtt.loop();
  if(mqtt.connected() && pendingAck.length() && mqtt.publish(topic("response").c_str(),pendingAck.c_str())) {
    pendingAck="";
    if(restartAt) restartAt=millis()+500;
  }
  if(mqtt.connected() && millis()-lastTelemetry>=60000) {
    lastTelemetry=millis(); DynamicJsonDocument doc(2048); addState(doc.to<JsonObject>());
    mqtt.publish(topic("telemetry").c_str(),jsonText(doc.as<JsonVariantConst>()).c_str());
#ifdef ESP8266
    logHeap("MQTT heartbeat");
#endif
  }
}

