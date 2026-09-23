#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <WiFiUdp.h>
#include <PubSubClient.h>
#include <DHT.h>
#include <SHA256.h>
#include <time.h>
#ifdef ESP8266
#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266HTTPClient.h>
#include <WiFiClientSecureBearSSL.h>
#include <Updater.h>
using WebServerType = ESP8266WebServer;
using SecureClient = BearSSL::WiFiClientSecure;
#else
#include <WiFi.h>
#include <WebServer.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <Update.h>
using WebServerType = WebServer;
using SecureClient = WiFiClientSecure;
#endif
