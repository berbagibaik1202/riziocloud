#include "runtime.h"
WebServerType web(80);
static uint32_t failedAt=0; static uint8_t failures=0;
static constexpr const char *DEFAULT_AP_PASSWORD = "rizio123456";
static void error(int status, const char *code) {
  StaticJsonDocument<192> doc; doc["status"]="error"; doc["code"]=code; doc["message"]=code;
  web.send(status,"application/json",jsonText(doc.as<JsonVariantConst>()));
}
static bool auth() {
  String header=web.header("Authorization");
  if (provisioning || !header.startsWith("Bearer ") || !verifyToken(header.substring(7))) { error(401,"AUTH_INVALID"); return false; }
  return true;
}
static bool provisionAuth() {
  String header=web.header("Authorization");
  if (!header.startsWith("Bearer ") || !verifyToken(header.substring(7))) { error(401,"AUTH_INVALID"); return false; }
  return true;
}
void beginWeb() {
#ifdef ESP8266
  web.collectHeaders("Authorization");
#else
  const char *headers[]={"Authorization"}; web.collectHeaders(headers,1);
#endif
  web.on("/api/v1/info",HTTP_GET,[](){
    StaticJsonDocument<512> doc; doc["status"]="success"; JsonObject d=doc.createNestedObject("data");
    d["sn"]=identity["sn"]; d["model"]=identity["model"]; d["hardware_version"]=identity["hardware_version"]; d["firmware_version"]=FIRMWARE_VERSION;
    web.send(200,"application/json",jsonText(doc.as<JsonVariantConst>()));
  });
  web.on("/api/v1/provision",HTTP_POST,[](){
    if (!provisioning && !provisionAuth()) return;
    if (failures>=5 && millis()-failedAt<60000) { error(429,"RATE_LIMITED"); return; }
    if (millis()-failedAt>=60000) failures=0;
    StaticJsonDocument<512> doc;
    if (web.arg("plain").length()>512 || deserializeJson(doc,web.arg("plain"))) { error(400,"INVALID_INPUT"); return; }
    if (provisioning) {
      const String setupCode=doc["setup_code"].as<String>();
      if (!constantEqual(setupCode,DEFAULT_AP_PASSWORD) && !constantEqual(setupCode,identity["setup_code"].as<String>())) { failures++; failedAt=millis(); error(401,"AUTH_INVALID"); return; }
    }
    String ssid=doc["ssid"].as<String>(), pass=doc["password"].as<String>();
    if (!doc["ssid"].is<const char *>() || !doc["password"].is<const char *>() || ssid.length()<1 || ssid.length()>32 || pass.length()>63 || (pass.length()>0 && pass.length()<8)) { error(400,"INVALID_INPUT"); return; }
    if (!saveWifi(ssid,pass)) { error(500,"STORAGE_ERROR"); return; }
    web.send(200,"application/json","{\"status\":\"success\",\"data\":{\"restarting\":true}}"); restartAt=millis()+500;
  });
  web.on("/api/v1/status",HTTP_GET,[](){
    if (!auth()) return;
    DynamicJsonDocument doc(2048); doc["status"]="success"; addState(doc.createNestedObject("data"));
    web.send(200,"application/json",jsonText(doc.as<JsonVariantConst>()));
  });
  web.on("/api/v1/gpio",HTTP_POST,[](){
    if (!auth()) return;
    StaticJsonDocument<512> input;
    if(web.arg("plain").length()>512 || deserializeJson(input,web.arg("plain"))) {error(400,"INVALID_INPUT");return;}
    input["cmd"]="gpio.set";
    String ack=executeCommand(input.as<JsonObjectConst>(),true);
    DynamicJsonDocument result(2048); deserializeJson(result,ack);
    if (!(result["success"] | false)) { error(400,result["error"] | "INVALID_INPUT"); return; }
    String out="{\"status\":\"success\",\"data\":"+ack+"}";
    web.send(200,"application/json",out);
  });
  web.onNotFound([](){error(404,"NOT_FOUND");}); web.begin();
}

