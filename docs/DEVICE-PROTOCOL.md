# Device protocol v1

Implementasi berada di `firmware/src`, memakai Arduino/PlatformIO untuk NodeMCU ESP8266 dan ESP32 DevKit. Kontrak lintas aplikasi berada di `CONTRACT.md`.

## Identitas dan transport

`/identity.json` berisi SN, device_key, setup_code, model, hardware_version, endpoint MQTT, reset_pin, channels. `/ca.pem` berisi CA PEM broker dan host unduhan HTTPS (boleh bundle). `/wifi.json` terpisah, satu-satunya konfigurasi runtime yang dihapus factory reset. Kegagalan mount/identitas/CA menghentikan boot tanpa autoformat dan tanpa membuka AP tidak aman. Jangan sertakan claim code di flash: ownership adalah sumber kebenaran server.

MQTT TLS memvalidasi CA dan hostname, menunggu waktu NTP valid. Client ID dan username adalah SN; password adalah string device_key. Firmware subscribe hanya `devices/{sn}/command` QoS 1. State dan availability retained; LWT QoS 1 `{"online":false}`; availability connect `{"online":true}`. PubSubClient publish state/telemetry/response QoS 0 sehingga ACK tetap dapat hilang saat putus koneksi; backend harus timeout dan membolehkan retry aman. Reconnect MQTT dicoba tiap 5 detik, Wi-Fi tiap 15 detik. Telemetry tiap 60 detik. ACL wajib ditegakkan broker, bukan dianggap aman hanya karena client menggunakan topic benar.

## Commands dan state

Command JSON `{"request_id":"UUID","cmd":"gpio.set","pin":5,"state":true,"timestamp":1789232000}`. Timestamp epoch detik harus berada antara now-120 dan now+30. Jenis tersedia: gpio.set, system.reboot, system.factory_reset, firmware.update. Respons `{"request_id":"UUID","success":true,"state":{"gpio":{"5":true},...}}` atau `success:false,error:"CODE"`. State dilengkapi rssi, ip_address, uptime detik sejak boot, free_heap, firmware_version.

Cache RAM 24 request terakhir dipakai bersama LAN/MQTT; ID sama dan operasi sama mengembalikan ACK lama, ID sama dengan operasi berbeda ditolak. Cache hilang saat reboot dan eviksi; jangan menganggap exactly-once lintas restart. Retry otomatis lintas transport hanya gpio.set (idempotent). Output selalu OFF saat boot; state ON tidak dipulihkan dari flash.

Channel konfigurasi mendukung `type:"switch"`; channel duplikat, tidak aman, reset_pin, atau tidak didukung tidak diaktifkan. ESP8266 allowlist GPIO 4,5,12,13,14. ESP32 DevKit allowlist 4,13,14,16,17,18,19,21,22,23,25,26,27,32,33. Board/modul dengan PSRAM atau periferal lain perlu audit wiring ulang. Sensor/PWM adalah ekstensi, belum diimplementasikan driver fisiknya.

## LAN

UDP 4210 request tepat `ESPCTRL_DISCOVER` (16 byte), respons publik `{"type":"esp-cloud-device","sn":"...","ip":"...","port":80,"model":"..."}`. Dibatasi 10 respons/detik global. Tidak ada secret di discovery.

GET `/api/v1/info` hanya identitas publik memakai envelope sukses. GET `/api/v1/status` dan POST `/api/v1/gpio` membutuhkan Authorization Bearer local token, tidak aktif pada AP provisioning. POST gpio menerima `{pin,state,request_id}`. Token `base64url(payload).hex(HMAC-SHA256(device_key,payloadBase64))`; key dipakai sebagai byte UTF-8 string sebagaimana tersimpan, bukan decode hex. Payload `{sn,exp,scope:"local"}`. Firmware menolak sebelum NTP valid, setelah exp, scope/SN salah, signature salah, atau exp lebih dari 60 detik di depan clock perangkat.

Transport LAN HTTP mengikuti kontrak, sehingga token berumur singkat dapat disadap/dipakai ulang oleh pihak yang mampu mengamati LAN. Gunakan LAN terpercaya; produk dengan threat model LAN bermusuhan memerlukan HTTPS atau request signing tambahan. Revokasi cloud/unclaim dapat menyisakan token valid maksimal 60 detik. Ketidaktersediaan NTP setelah cold boot membuat LAN auth dan MQTT fail closed.

## OTA dan recovery

Command firmware.update membutuhkan url HTTPS, checksum SHA256 hex 64, version, file_size byte, model, hardware_version. Firmware menolak model/hardware berbeda dari identitas produksi. Firmware unduh HTTP 200 dengan Content-Length tepat, tanpa redirect, melalui CA tepercaya. SHA256 dihitung sambil menulis staging/inactive flash. `Update.end()` hanya dipanggil setelah ukuran dan checksum benar; Byte terakhir ditahan sampai hash cocok; mismatch membatalkan update ESP32 atau menutup staging yang belum lengkap pada ESP8266, sehingga firmware lama tetap aktif. Ubah FIRMWARE_VERSION saat membuat release agar setelah restart versi baru dilaporkan. Implementasi memakai push MQTT; endpoint latest tersedia di server untuk tooling, firmware tidak melakukan polling otomatis.

SHA256 mengikat konten ke metadata MQTT terautentikasi, bukan pengganti secure boot atau tanda tangan firmware. Untuk menjaga heap ESP8266, koneksi MQTT ditutup selama download HTTPS, lalu dibuka kembali untuk mengirim ACK tertunda. Download sinkron juga menunda polling tombol. Jangan update saat output mengendalikan proses yang membutuhkan respons real-time. Satu ACK tertunda disimpan di RAM dan dicoba setelah reconnect, dengan penundaan reboot maksimal 15 detik. Gangguan lebih lama atau hilang daya masih dapat menyebabkan ACK hilang; konfirmasi hasil lewat versi setelah reconnect.

ESP8266 memakai staging dan eboot; tidak menyediakan rollback otomatis sesudah image baru berhasil diaktifkan. ESP32 memakai slot OTA dari min_spiffs tetapi build Arduino standar ini tidak mengaktifkan bootloader rollback atau health confirmation. Recovery firmware buruk melalui flashing serial; jangan klaim rollback otomatis. Untuk produksi ESP32 aktifkan secure boot, flash/NVS encryption dan bootloader rollback dalam pipeline ESP-IDF yang sesuai, serta UAT crash/power-loss.


