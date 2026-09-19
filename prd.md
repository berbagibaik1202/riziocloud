# PRODUCT REQUIREMENT DOCUMENT

## RizIO ESP Cloud Controller v1.1

**Tanggal:** 12 September 2026
**Status:** Development Blueprint
**Target:** ESP8266 / ESP32
**Platform:** Web/Mobile + Cloud + Local Network
**Backend:** Node.js + Express + TypeScript
**Database:** MySQL / MariaDB
**IoT Protocol:** MQTT over TLS
**Mobile:** Flutter
**MQTT Broker:** EMQX

---

# 1. GAMBARAN PRODUK

RizIO ESP Cloud Controller adalah platform IoT untuk menghubungkan perangkat berbasis ESP8266/ESP32 dengan aplikasi pengguna melalui jaringan lokal maupun internet.

Platform harus memungkinkan pengguna:

1. Registrasi dan login.
2. Menambahkan perangkat dengan scan QR.
3. Melakukan provisioning Wi-Fi tanpa komputer.
4. Mengontrol GPIO.
5. Melihat status GPIO secara realtime.
6. Mengontrol perangkat melalui LAN ketika berada di jaringan yang sama.
7. Mengontrol perangkat melalui Cloud ketika berada di luar jaringan.
8. Melihat status online/offline.
9. Mengganti nama perangkat.
10. Menghapus/unclaim perangkat.
11. Memantau RSSI dan informasi perangkat.
12. Melakukan firmware OTA.
13. Memastikan setiap user hanya dapat mengakses perangkat miliknya.

Sistem dirancang agar nantinya dapat berkembang dari beberapa perangkat menjadi ribuan perangkat.

---

# 2. TUJUAN PRODUK

Tujuan utama sistem adalah membuat pengalaman penggunaan perangkat IoT sesederhana:

```text
Beli Device
     ↓
Nyalakan
     ↓
Scan QR
     ↓
Hubungkan Wi-Fi
     ↓
Device Online
     ↓
Kontrol dari HP
```

User tidak perlu mengetahui:

* IP address ESP
* MQTT
* Port
* Broker
* konfigurasi server
* konfigurasi firmware

Semua proses teknis harus ditangani otomatis oleh sistem.

---

# 3. USER ROLE

## 3.1 User

User dapat:

* register
* login
* logout
* claim device
* provisioning device
* melihat device miliknya
* mengontrol GPIO
* melihat status GPIO
* melihat status online
* mengganti nama device
* melihat informasi device
* melakukan reboot
* melakukan factory reset jika diizinkan
* menghapus device dari akun

User tidak boleh mengakses device milik user lain.

## 3.2 Administrator

Administrator memiliki dashboard khusus.

Admin dapat:

* melihat semua user
* melihat semua device
* melihat device online/offline
* melihat firmware version
* melihat RSSI
* melihat last seen
* melihat ownership
* melihat log
* melihat telemetry
* mengelola firmware
* melakukan OTA
* melakukan disable device
* melakukan troubleshooting device

---

# 4. ALUR PENGGUNA

## 4.1 Registrasi

```text
User
 ↓
Register
 ↓
Email + Password
 ↓
Backend
 ↓
Password Hash
 ↓
Database
 ↓
Account Created
```

---

# 5. DEVICE IDENTITY

Setiap ESP memiliki identitas permanen dari proses produksi.

Contoh:

```text
SN          : ESP-A7F9C231
DEVICE_KEY  : random-secret-256-bit
CLAIM_CODE  : H8KF-92MA
MODEL       : ESP-RELAY-8CH
HW_VERSION  : 1.0
```

`DEVICE_KEY` tidak ditampilkan pada QR publik.

DEVICE_KEY hanya diketahui oleh:

```text
ESP <------> Cloud
```

---

# 6. QR CODE

QR tidak lagi berisi DEVICE_KEY.

Format:

```text
ESPCTRL://claim?sn=ESP-A7F9C231&code=H8KF92MA
```

atau menggunakan JSON:

```json
{
  "type": "esp-cloud",
  "sn": "ESP-A7F9C231",
  "claim_code": "H8KF92MA"
}
```

QR hanya digunakan untuk claim.

---

# 7. DEVICE CLAIM

Flow:

```text
User Scan QR
      ↓
SN + CLAIM_CODE
      ↓
POST /devices/claim
      ↓
Server mencari device
      ↓
Validasi claim_code
      ↓
Apakah sudah memiliki owner?
      ↓
      NO
      ↓
owner_user_id = USER
      ↓
claim_code invalid
      ↓
Device berhasil ditambahkan
```

Claim code bersifat sekali pakai.

DEVICE_KEY tidak pernah dikirim ke aplikasi user.

---

# 8. DEVICE UNCLAIM

Jika user menghapus device:

```text
User
 ↓
Remove Device
 ↓
Server validasi owner
 ↓
owner_user_id = NULL
 ↓
Generate CLAIM_CODE baru
 ↓
Device dapat digunakan user baru
```

Untuk keamanan, proses ini dapat meminta password user atau konfirmasi tambahan.

---

# 9. PROVISIONING WIFI

ESP harus dapat dikonfigurasi tanpa komputer.

Jika ESP belum memiliki Wi-Fi:

```text
ESP Boot
 ↓
WiFi Config?
 ↓
NO
 ↓
AP MODE
```

Contoh SSID:

```text
ESPCTRL-A7F9C231
```

IP:

```text
192.168.4.1
```

User membuka aplikasi.

App mendeteksi ESP provisioning.

User memilih:

```text
WiFi SSID
Password
```

Kemudian:

```text
App
 ↓
ESP Setup API
 ↓
ESP Save WiFi
 ↓
Restart
 ↓
Connect Router
 ↓
Connect Cloud MQTT
```

Credential Wi-Fi disimpan menggunakan mekanisme penyimpanan aman yang tersedia pada platform.

---

# 10. ARSITEKTUR SISTEM

```text
                     INTERNET
                         │
                         ▼
                ┌────────────────┐
                │ Reverse Proxy  │
                │ HTTPS / TLS    │
                └───────┬────────┘
                        │
              ┌─────────▼─────────┐
              │   Backend API     │
              │ Node.js/Express   │
              │ TypeScript        │
              └─────┬────────┬────┘
                    │        │
                  MySQL     EMQX
                             │
                         MQTT TLS
                         Port 8883
                             │
                       ┌─────▼─────┐
                       │ ESP8266 / │
                       │ ESP32     │
                       └─────┬─────┘
                             │
                           GPIO
                             │
                         Relay/IoT
```

---

# 11. HYBRID LOCAL + CLOUD CONTROL

Sistem memiliki dua jalur komunikasi.

## LOCAL

Jika HP dan ESP berada di LAN yang sama:

```text
Mobile App
    │
UDP Discovery
    ↓
ESP
    │
Local API
    ↓
GPIO
```

Target latency:

```text
< 200 ms
```

## CLOUD

Jika perangkat tidak ditemukan di LAN:

```text
Mobile App
 ↓
HTTPS
 ↓
Backend
 ↓
MQTT
 ↓
ESP
 ↓
GPIO
```

Target latency normal:

```text
< 2 detik
```

---

# 12. AUTOMATIC CONNECTION MODE

User tidak perlu memilih:

```text
LOCAL
CLOUD
```

App menentukan jalur secara otomatis.

Flow:

```text
Control GPIO
     ↓
Device ditemukan di LAN?
     │
 YES ├────> LOCAL API
     │
 NO
     ↓
 CLOUD API
     ↓
 MQTT
```

UI dapat menampilkan:

```text
● Online — Local
```

atau:

```text
● Online — Cloud
```

---

# 13. LAN DISCOVERY

ESP menggunakan UDP.

Port:

```text
4210
```

App mengirim:

```text
ESPCTRL_DISCOVER
```

ESP menjawab:

```json
{
  "type": "esp-cloud-device",
  "sn": "ESP-A7F9C231",
  "ip": "192.168.1.20",
  "port": 80,
  "model": "ESP-RELAY-8CH"
}
```

Informasi sensitif seperti:

```text
DEVICE_KEY
CLAIM_CODE
WiFi Password
MQTT Password
```

tidak boleh dikirim melalui discovery.

---

# 14. LOCAL DEVICE AUTHENTICATION

Local API tidak boleh dapat dikontrol sembarang perangkat di Wi-Fi.

Contoh request:

```http
POST /api/v1/gpio
Authorization: Bearer <LOCAL_TOKEN>
Content-Type: application/json
```

Payload:

```json
{
  "pin": 5,
  "state": true
}
```

Token lokal hanya diberikan kepada aplikasi yang memiliki hak terhadap device.

Untuk versi lanjutan dapat menggunakan HMAC:

```text
signature =
HMAC-SHA256(
    local_secret,
    timestamp + nonce + payload
)
```

Gunakan nonce/timestamp untuk mengurangi replay attack.

---

# 15. MQTT

Broker:

```text
EMQX
```

Production:

```text
mqtt.domain.com
Port 8883
TLS
```

Authentication:

```text
username = DEVICE_SN
password = DEVICE_CREDENTIAL
```

Setiap device hanya memiliki permission ke topic miliknya.

---

# 16. MQTT ACL

ESP:

```text
SUBSCRIBE
devices/{SN}/command

PUBLISH
devices/{SN}/state
devices/{SN}/telemetry
devices/{SN}/availability
devices/{SN}/response
```

ESP tidak boleh:

```text
devices/+/command
devices/#
```

Device A tidak boleh membaca atau menulis topic Device B.

---

# 17. MQTT TOPIC

Struktur:

```text
devices/{SN}/command
devices/{SN}/response
devices/{SN}/state
devices/{SN}/telemetry
devices/{SN}/availability
```

---

# 18. DEVICE COMMAND

Contoh:

```json
{
  "request_id": "01K5ABC123",
  "cmd": "gpio.set",
  "pin": 5,
  "state": true,
  "timestamp": 1789232000
}
```

---

# 19. COMMAND ACKNOWLEDGEMENT

Setelah command dieksekusi ESP:

```json
{
  "request_id": "01K5ABC123",
  "success": true,
  "state": {
    "pin": 5,
    "value": true
  }
}
```

Dengan mekanisme ini server mengetahui:

```text
Command dikirim
       ↓
ESP menerima
       ↓
ESP menjalankan
       ↓
ESP ACK
       ↓
UI diperbarui
```

---

# 20. DEVICE STATE

ESP mengirim state setelah:

* boot
* reconnect
* GPIO berubah
* command dijalankan

Contoh:

```json
{
  "gpio": {
    "D1": true,
    "D2": false,
    "D3": false,
    "D4": true
  },
  "uptime": 83122
}
```

---

# 21. TELEMETRY

ESP mengirim telemetry berkala.

Contoh:

```json
{
  "rssi": -62,
  "uptime": 83122,
  "free_heap": 31240,
  "firmware": "1.0.3",
  "ip": "192.168.1.20"
}
```

Interval default:

```text
60 detik
```

Interval dapat dikonfigurasi.

---

# 22. ONLINE/OFFLINE DETECTION

Gunakan MQTT Last Will and Testament.

Topic:

```text
devices/{SN}/availability
```

Saat connect:

```json
{
  "online": true
}
```

LWT:

```json
{
  "online": false
}
```

Server juga menyimpan:

```text
last_seen
```

sebagai mekanisme tambahan.

---

# 23. DATABASE

Database:

```text
MySQL 8 / MariaDB
```

---

# 24. TABLE USERS

```text
users

id
email
password_hash
name
role
status
created_at
updated_at
```

---

# 25. TABLE DEVICES

```text
devices

id
sn
device_key_hash / encrypted_device_credential
claim_code_hash
owner_user_id
name
model
hardware_version
firmware_version
status
last_seen
created_at
updated_at
```

Index:

```text
UNIQUE(sn)
INDEX(owner_user_id)
INDEX(status)
```

---

# 26. TABLE DEVICE_STATES

```text
device_states

device_id
gpio_state JSON
rssi
ip_address
uptime
free_heap
firmware_version
updated_at
```

Satu device hanya memiliki satu current state.

---

# 27. TABLE DEVICE_LOGS

```text
device_logs

id
device_id
event_type
command
payload JSON
created_at
```

Contoh event:

```text
gpio_change
reboot
online
offline
firmware_update
factory_reset
error
```

---

# 28. TABLE DEVICE_COMMANDS

```text
device_commands

id
request_id
device_id
user_id
command
payload
status
created_at
sent_at
ack_at
```

Status:

```text
pending
sent
success
failed
timeout
```

---

# 29. TABLE FIRMWARE

```text
firmwares

id
model
version
url
checksum
file_size
release_notes
is_active
created_at
```

---

# 30. API

Base URL:

```text
https://api.domain.com/v1
```

Authentication:

```text
Authorization: Bearer JWT
```

---

# 31. AUTH API

```text
POST /auth/register
POST /auth/login
POST /auth/refresh
POST /auth/logout
GET  /auth/me
```

---

# 32. DEVICE API

```text
GET    /devices
GET    /devices/:sn
POST   /devices/claim
DELETE /devices/:sn
PATCH  /devices/:sn
GET    /devices/:sn/status
```

---

# 33. CONTROL API

```text
POST /devices/:sn/commands
```

Payload:

```json
{
  "command": "gpio.set",
  "pin": 5,
  "state": true
}
```

Backend wajib melakukan:

```text
JWT validation
      ↓
Find device
      ↓
owner_user_id == current user?
      ↓
YES
      ↓
Publish MQTT
```

---

# 34. COMMAND RESPONSE

API dapat memberikan:

```json
{
  "status": "success",
  "data": {
    "request_id": "01K5ABC123",
    "device": "ESP-A7F9C231",
    "command_status": "pending"
  }
}
```

Status kemudian berubah setelah MQTT ACK diterima.

---

# 35. FIRMWARE OTA

ESP harus mendukung OTA.

Server menyimpan firmware berdasarkan:

```text
MODEL
HW VERSION
FIRMWARE VERSION
```

ESP dapat mengecek:

```text
GET /v1/device/firmware/latest
```

atau menerima MQTT:

```json
{
  "cmd": "firmware.update",
  "version": "1.0.4",
  "url": "https://firmware.domain.com/ESP-RELAY-8CH/1.0.4.bin",
  "checksum": "SHA256..."
}
```

ESP wajib memverifikasi checksum sebelum menjalankan firmware baru.

---

# 36. OTA FLOW

```text
Admin Upload Firmware
        ↓
Cloud
        ↓
Assign Firmware
        ↓
MQTT Command
        ↓
ESP Download HTTPS
        ↓
Verify SHA256
        ↓
Install
        ↓
Restart
        ↓
Report Version
```

---

# 37. FIRMWARE ESP8266

Framework:

```text
Arduino Framework
```

Library:

```text
ESP8266WiFi
WiFiManager
PubSubClient
ArduinoJson
ESP8266WebServer
WiFiUDP
LittleFS
ESP8266HTTPClient
ESP8266httpUpdate
```

---

# 38. FIRMWARE MODULE

Firmware sebaiknya modular:

```text
/src

main.cpp

wifi/
  wifi_manager.cpp

mqtt/
  mqtt_client.cpp

gpio/
  gpio_manager.cpp

discovery/
  udp_discovery.cpp

web/
  local_api.cpp

storage/
  config.cpp

ota/
  ota_manager.cpp

security/
  auth.cpp
```

Tujuannya agar firmware mudah dikembangkan ke ESP32 nantinya.

---

# 39. GPIO CONFIGURATION

Jangan hard-code semua fungsi hanya sebagai relay.

Gunakan konfigurasi:

```json
{
  "channels": [
    {
      "id": 1,
      "pin": 5,
      "name": "Relay 1",
      "type": "switch",
      "active_low": true
    }
  ]
}
```

Dengan demikian hardware berbeda dapat menggunakan firmware yang sama.

---

# 40. MOBILE APPLICATION

Framework:

```text
Flutter
```

Target:

```text
Android
iOS
```

Halaman:

```text
Splash
Login
Register
Dashboard
Add Device
Provision Device
Device Control
Device Information
Device Settings
Account
```

---

# 41. DASHBOARD

Contoh:

```text
My Devices

┌─────────────────────────┐
│ Lampu Ruang Tamu        │
│ ● Online — Local        │
│ ESP-RELAY-8CH           │
│                         │
│ Relay 1       [ ON ]    │
│ Relay 2       [ OFF ]   │
└─────────────────────────┘

┌─────────────────────────┐
│ Pompa Air               │
│ ● Online — Cloud        │
│                         │
│ Pump          [ OFF ]   │
└─────────────────────────┘
```

---

# 42. DEVICE INFORMATION

Tampilkan:

```text
Name
Serial Number
Model
Hardware Version
Firmware Version

Connection
Online / Offline
Local / Cloud

WiFi
RSSI
IP Address

System
Uptime
Free Heap
Last Seen
```

---

# 43. SECURITY

Wajib:

1. HTTPS untuk API.
2. MQTTS untuk device.
3. bcrypt/Argon2 untuk password user.
4. JWT access token berumur pendek.
5. Refresh token.
6. MQTT ACL per-device.
7. DEVICE_KEY tidak ditampilkan ke user.
8. QR tidak mengandung DEVICE_KEY.
9. Claim code sekali pakai.
10. Ownership diverifikasi server.
11. Local API membutuhkan authentication.
12. Rate limiting API.
13. Brute-force protection.
14. OTA checksum validation.
15. Input validation.
16. Audit log untuk command sensitif.

---

# 44. FACTORY RESET

Physical button:

```text
Hold 10 seconds
```

ESP:

```text
Detect Button
 ↓
Clear WiFi
 ↓
Clear local configuration
 ↓
Restart
 ↓
Provisioning Mode
```

Factory reset tidak otomatis menghapus ownership cloud.

Unclaim harus dilakukan melalui akun atau mekanisme recovery resmi.

Ini mencegah pihak yang hanya memiliki akses fisik ke device mengambil ownership cukup dengan menekan tombol reset.

---

# 45. REBOOT

Command:

```json
{
  "cmd": "system.reboot"
}
```

Harus divalidasi ownership oleh backend.

---

# 46. ADMIN DASHBOARD

Dashboard admin berbasis web.

Menu:

```text
Dashboard
Users
Devices
Online Devices
Offline Devices
Firmware
OTA Deployment
Commands
Logs
System
```

Dashboard summary:

```text
Total Devices
Online
Offline
Total Users
Firmware Distribution
MQTT Connections
Command Success Rate
```

---

# 47. CLOUD DEPLOYMENT

Recommended:

```text
Ubuntu Server
       │
Docker Compose
       │
├── nginx
├── backend
├── mysql/mariadb
├── emqx
└── optional redis
```

Domain:

```text
api.domain.com
mqtt.domain.com
firmware.domain.com
admin.domain.com
```

---

# 48. SCALABILITY

MVP:

```text
1 Backend
1 Database
1 EMQX
```

Target awal:

```text
1 – 1,000 devices
```

Tahap selanjutnya:

```text
Load Balancer
      │
 ┌────┴─────┐
Backend   Backend
      │
    Redis
      │
   Database
      │
 EMQX Cluster
```

Dengan demikian arsitektur awal tidak perlu dirombak ketika jumlah device bertambah.

---

# 49. DEVICE ABSTRACTION

Sistem tidak boleh dirancang hanya untuk ESP8266.

Device memiliki:

```text
model
capabilities
channels
hardware_version
firmware_version
```

Contoh capabilities:

```json
{
  "switch": 4,
  "sensor": ["temperature", "humidity"],
  "pwm": 2
}
```

Dengan konsep ini platform nantinya dapat mendukung:

```text
ESP8266
ESP32
Smart Relay
Smart Plug
Temperature Sensor
Water Pump Controller
Lamp Controller
Energy Meter
Custom IoT Device
```

tanpa membuat platform baru.

---

# 50. ERROR HANDLING

Contoh error API:

```json
{
  "status": "error",
  "code": "DEVICE_NOT_OWNED",
  "message": "Device bukan milik akun ini."
}
```

Kode standar:

```text
AUTH_INVALID
DEVICE_NOT_FOUND
DEVICE_NOT_OWNED
DEVICE_OFFLINE
DEVICE_ALREADY_CLAIMED
INVALID_CLAIM_CODE
COMMAND_TIMEOUT
MQTT_ERROR
OTA_FAILED
```

---

# 51. MONITORING

Backend harus memiliki monitoring untuk:

```text
API health
Database health
MQTT health
Connected devices
Command latency
Command timeout
Device reconnect
Firmware update failure
```

Endpoint:

```text
GET /health
```

---

# 52. LOGGING

Gunakan structured logging.

Contoh:

```json
{
  "level": "info",
  "event": "device_command",
  "sn": "ESP-A7F9C231",
  "request_id": "01K5ABC123",
  "command": "gpio.set",
  "latency_ms": 124
}
```

Jangan pernah mencatat:

```text
password
DEVICE_KEY
WiFi password
JWT
refresh token
```

ke log.

---

# 53. UAT / ACCEPTANCE CRITERIA

Sistem dianggap memenuhi MVP jika:

1. User dapat register/login.
2. ESP dapat provisioning tanpa PC.
3. User dapat scan QR.
4. Device dapat di-claim.
5. Satu device hanya memiliki satu owner.
6. User lain tidak dapat mengakses device tersebut.
7. ESP otomatis connect MQTT.
8. App mengetahui online/offline device.
9. GPIO dapat dikontrol melalui Cloud.
10. GPIO dapat dikontrol melalui LAN.
11. App otomatis memilih Local/Cloud.
12. State GPIO sinkron.
13. MQTT reconnect otomatis.
14. Wi-Fi reconnect otomatis.
15. Server menerima telemetry.
16. Command memiliki ACK.
17. Factory reset bekerja.
18. Ownership tetap aman setelah factory reset.
19. OTA firmware dapat dilakukan.
20. Device melaporkan firmware baru setelah OTA.

Target performa:

```text
LAN Control
< 200 ms

Cloud Control
< 2 seconds

MQTT reconnect
automatic

WiFi reconnect
automatic
```

---

# 54. DEVELOPMENT PHASE

## PHASE 1 — Backend Core

Bangun:

```text
Database
Authentication
User
Device
Claim
Ownership
MQTT integration
Command
State
Telemetry
```

## PHASE 2 — ESP Firmware

Bangun:

```text
Device Identity
WiFi Provisioning
MQTT
GPIO
State
Telemetry
UDP Discovery
Local API
Factory Reset
```

## PHASE 3 — Mobile Application

Bangun:

```text
Authentication
Dashboard
QR Scanner
Provisioning
LAN Discovery
Cloud Control
Local Control
Device Settings
```

## PHASE 4 — OTA

Bangun:

```text
Firmware Repository
Firmware API
OTA Manager
Deployment
Firmware Status
Rollback strategy
```

## PHASE 5 — Admin Dashboard

Bangun:

```text
Users
Devices
Monitoring
Firmware
OTA
Logs
Commands
```

---

# 55. REPOSITORY STRUCTURE

Direkomendasikan menggunakan monorepo:

```text
esp-cloud-controller/

├── backend/
│   ├── src/
│   ├── migrations/
│   ├── tests/
│   └── Dockerfile
│
├── firmware/
│   ├── esp8266/
│   └── esp32/
│
├── mobile/
│   └── flutter/
│
├── admin/
│   └── web/
│
├── infrastructure/
│   ├── docker-compose.yml
│   ├── nginx/
│   └── emqx/
│
├── docs/
│   ├── API.md
│   ├── MQTT.md
│   ├── DEVICE-PROTOCOL.md
│   ├── PROVISIONING.md
│   └── SECURITY.md
│
└── README.md
```

---

# 56. PRINSIP DESAIN UTAMA

Arsitektur harus mengikuti prinsip:

```text
Cloud First
+
Local Fast Control
+
Secure Device Identity
+
Automatic LAN/WAN Switching
+
MQTT Realtime
+
OTA Ready
+
Multi User
+
Multi Device
+
Multi Hardware
```

Firmware ESP tidak boleh bergantung langsung pada struktur UI aplikasi.

Mobile tidak boleh mengetahui DEVICE_KEY.

Device tidak boleh mempercayai user hanya berdasarkan SN.

Backend adalah sumber kebenaran untuk:

```text
User
Ownership
Device
Authorization
Firmware
```

ESP adalah sumber kebenaran untuk:

```text
Actual GPIO State
Hardware Status
Runtime Telemetry
```

---

# 57. TARGET AKHIR

Platform harus memungkinkan pengalaman:

```text
         ESP CLOUD CONTROLLER

                 CLOUD
                   │
            ┌──────┴──────┐
            │             │
          MOBILE        ADMIN
            │
       ┌────┴────┐
       │         │
     LOCAL     CLOUD
       │         │
       └────┬────┘
            │
          DEVICE
            │
    ┌───────┼────────┐
    │       │        │
  Relay   Sensor    PWM
```

Satu platform nantinya dapat menjadi **IoT Device Cloud**, bukan hanya aplikasi kontrol ESP8266.

Dengan demikian produk dapat berkembang menjadi platform untuk berbagai perangkat IoT tanpa mengubah fondasi backend.
