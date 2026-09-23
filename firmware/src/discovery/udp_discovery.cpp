#include "runtime.h"
static WiFiUDP udp; static uint32_t lastReply=0;
static constexpr char DISCOVERY_REQUEST[] = "ESPCTRL_DISCOVER";
void beginDiscovery() { udp.begin(4210); }
void tickDiscovery() {
  int count = udp.parsePacket(); if (!count) return;
  char buf[32]; int n=udp.read(buf,sizeof(buf)-1); if(n<0) return; buf[n]=0;
  if (count != sizeof(DISCOVERY_REQUEST)-1 || String(buf) != DISCOVERY_REQUEST || millis()-lastReply<100) return;
  lastReply=millis();
  localBusyUntil=millis()+2000;
  StaticJsonDocument<1024> doc;
  doc["type"]="esp-cloud-device"; doc["sn"]=identity["sn"]; doc["model"]=identity["model"];
  doc["channels"] = identity["channels"];
  doc["ip"]=(provisioning ? WiFi.softAPIP() : WiFi.localIP()).toString(); doc["port"]=80;
  udp.beginPacket(udp.remoteIP(),udp.remotePort()); udp.print(jsonText(doc.as<JsonVariantConst>()));
  int sent = udp.endPacket();
  Serial.printf("[Discovery] Reply to %s: %s\n", udp.remoteIP().toString().c_str(), sent ? "sent" : "failed");
}
