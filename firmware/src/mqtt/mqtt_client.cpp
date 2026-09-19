#include "runtime.h"
SecureClient tls; PubSubClient mqtt(tls);
static uint32_t lastConnect=0,lastTelemetry=0;
static String pendingAck;
struct Cached { String id, fingerprint, ack; }; static Cached cache[24]; static uint8_t cursor=0;
void publishState() { DynamicJsonDocument doc(2048); addState(doc.to<JsonObject>()); mqtt.publish(topic("state").c_str(),jsonText(doc.as<JsonVariantConst>()).c_str(),true); }
String executeCommand(JsonObjectConst input, bool local) {
  String id=input["request_id"] | "", cmd=input["cmd"] | "";
  String fingerprint=cmd+":"+String(input["pin"] | -1)+":"+String(input["state"] | false)+":"+String(input["url"] | "")+":"+String(input["checksum"] | "")+":"+String(input["file_size"] | 0)+":"+String(input["version"] | "");
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
    if(cmd=="gpio.set") {
      if(!input["pin"].is<int>() || !input["state"].is<bool>() || !setGpio(input["pin"],input["state"])) error="INVALID_GPIO";
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
  mqtt.setBufferSize(4096); mqtt.setKeepAlive(30); mqtt.setSocketTimeout(5);
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
  if(provisioning || WiFi.status()!=WL_CONNECTED || time(nullptr)<1700000000) return;
  if(!mqtt.connected() && millis()-lastConnect>5000) {
    lastConnect=millis(); const char *sn=identity["sn"];
    if(mqtt.connect(sn,sn,identity["device_key"].as<const char *>(),topic("availability").c_str(),1,true,"{\"online\":false}")) {
      mqtt.subscribe(topic("command").c_str(),1); mqtt.publish(topic("availability").c_str(),"{\"online\":true}",true); publishState();
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
  }
}

