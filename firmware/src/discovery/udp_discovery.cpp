#include "runtime.h"
static WiFiUDP udp; static uint32_t lastReply=0;
void beginDiscovery() { udp.begin(4210); }
void tickDiscovery() {
  int count = udp.parsePacket(); if (!count) return;
  char buf[32]; int n=udp.read(buf,sizeof(buf)-1); if(n<0) return; buf[n]=0;
  if (count != 16 || String(buf) != "ESPCTRL_DISCOVER" || millis()-lastReply<100) return;
  lastReply=millis();
  StaticJsonDocument<384> doc;
  doc["type"]="esp-cloud-device"; doc["sn"]=identity["sn"]; doc["model"]=identity["model"];
  doc["ip"]=(provisioning ? WiFi.softAPIP() : WiFi.localIP()).toString(); doc["port"]=80;
  udp.beginPacket(udp.remoteIP(),udp.remotePort()); udp.print(jsonText(doc.as<JsonVariantConst>())); udp.endPacket();
}
