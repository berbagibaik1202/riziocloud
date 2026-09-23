# Upload Firmware ESP8266

Panduan ini untuk board ESP8266 NodeMCU v2 dengan environment PlatformIO `esp8266`.

## Prasyarat

- Python 3 dan PlatformIO:

```powershell
py -m pip install platformio
```

- Kabel USB data, bukan kabel charge-only.
- Driver USB-to-serial sesuai chip board, biasanya CH340 atau CP210x.
- Folder repository RizIO sudah di-clone.
- Perangkat sudah diinventaris melalui API admin.
- `identity.json` dan `ca.pem` sudah dibuat untuk unit yang akan di-flash.

Masuk ke folder firmware:

```powershell
cd D:\APLIKASI\rizio\firmware
```

Pada Linux/macOS, gunakan path repository Anda sendiri.

## Alur lokal dan VPS

Perintah PlatformIO dan flash ESP8266 dijalankan di **komputer lokal** yang terhubung melalui USB. Jangan menjalankan perintah flash dari VPS. VPS hanya menjalankan backend, database, EMQX, dan dashboard web.

Alur produksi:

1. Buat inventory perangkat dari menu administrator.
2. Download `identity.json` dari hasil pembuatan inventory.
3. Salin `identity.json` ke `firmware/data/identity.json`.
4. Siapkan `firmware/data/ca.pem`.
5. Build dan flash firmware dari komputer lokal.
6. Provisioning Wi-Fi melalui AP ESP8266.
7. Claim perangkat melalui aplikasi RizIO.

## Membuat ca.pem di komputer lokal

Untuk broker MQTT dengan sertifikat Let’s Encrypt, download root CA Let’s Encrypt dari root repository Windows:

```powershell
cd D:\APLIKASI\rizio
New-Item -ItemType Directory -Force firmware\data | Out-Null
Invoke-WebRequest `
  -Uri https://letsencrypt.org/certs/isrgrootx1.pem `
  -OutFile firmware\data\ca.pem
```

Validasi file:

```powershell
Get-Content firmware\data\ca.pem -First 2
```

Baris pertama harus `-----BEGIN CERTIFICATE-----`. Jangan menyalin `privkey.pem` ke ESP8266. File `fullchain.pem` dan `privkey.pem` digunakan oleh EMQX/Nginx Proxy Manager di server.

## Siapkan identity dan CA

Setiap unit harus memiliki identity sendiri. Jangan memakai identity contoh atau identity milik unit lain.

1. Simpan respons inventory admin sebagai `production/inventory-response.json`.
2. Jalankan converter dari root repository:

```powershell
node tools/prepare-device.mjs `
  production/inventory-response.json `
  mqtt.rizbill.my.id `
  production/ESP-A7F9C231
```

3. Salin hasil identity dan CA MQTT ke filesystem firmware:

```powershell
New-Item -ItemType Directory -Force data | Out-Null
Copy-Item production/ESP-A7F9C231/identity.json data/identity.json
Copy-Item path\ke\ca.pem data/ca.pem
```

`identity.json` harus berisi SN, device key, setup code, model, hardware version, hostname MQTT, port `8883`, reset pin, dan channel sesuai wiring. CA harus merupakan CA yang memvalidasi sertifikat `mqtt.rizbill.my.id`.

Password AP provisioning default adalah `rizio123456` untuk SSID `RIZIO-XXXXXXXX`. Password ini hanya dipakai pada tahap setup awal. Perangkat diklaim otomatis berdasarkan SN setelah provisioning berhasil. Field `setup_code` tetap disimpan di identity untuk kompatibilitas produksi lama, tetapi pelanggan menggunakan password default ini.

Jangan commit atau membagikan `data/identity.json`, `data/ca.pem`, device key, setup code, atau respons inventory. File sensitif tersebut sudah diabaikan Git, tetapi tetap periksa status Git sebelum push.

## Cek port serial

Sambungkan ESP8266 melalui USB, lalu cari port serial:

```powershell
pio device list
```

Contoh hasil:

```text
COM3
```

Pada komputer yang digunakan untuk produksi, ESP8266 NodeMCU dengan USB-serial CH340 dapat muncul sebagai `COM7`. Gunakan port yang dilaporkan oleh `pio device list`; angka COM tidak selalu sama di setiap komputer.

Jika port tidak muncul, ganti kabel USB, pasang driver CH340/CP210x, atau periksa Device Manager.

## Build firmware ESP8266

Build tanpa menghapus filesystem perangkat:

```powershell
py -m platformio run -e esp8266
```

Atau jika perintah `pio` tersedia:

```powershell
pio run -e esp8266
```

Build berhasil jika muncul pesan `SUCCESS` dan tidak ada error kompilasi.

## Upload firmware dan filesystem

Ganti `COM7` sesuai hasil `pio device list`. Contoh berikut memakai port ESP8266 yang terdeteksi pada komputer produksi.

### Unit baru atau filesystem belum pernah diprogram

Upload firmware:

```powershell
py -m platformio run -e esp8266 -t upload --upload-port COM7
```

Upload filesystem yang berisi identity dan CA:

```powershell
py -m platformio run -e esp8266 -t uploadfs --upload-port COM7
```

Urutan ini penting. Tanpa filesystem yang benar, firmware berhenti saat boot dengan pesan `Identity or CA unavailable; device halted.`

### Update firmware rutin

Jika identity dan Wi-Fi harus dipertahankan, cukup upload firmware:

```powershell
py -m platformio run -e esp8266 -t upload --upload-port COM7
```

Jangan menjalankan `uploadfs` pada unit aktif kecuali memang ingin mengganti seluruh filesystem dan sudah memiliki backup identity yang benar. `uploadfs` dapat mengganti identity dan data Wi-Fi.

## Monitor serial

### LED internal NodeMCU (GPIO2)

Untuk mengontrol LED internal melalui RizIO, gunakan channel `{"id":1,"pin":2,"name":"LED internal","type":"switch","active_low":true}` pada inventory dan identity perangkat. Firmware mengizinkan GPIO2; logical ON mengeluarkan LOW dan logical OFF mengeluarkan HIGH. LED diinisialisasi OFF saat firmware mulai berjalan. GPIO2 harus tetap HIGH saat boot; konfigurasi ini ditujukan untuk LED internal NodeMCU.

Update firmware saja cukup jika identity yang sudah tersimpan menggunakan channel tersebut. Jangan upload filesystem hanya untuk memperbarui firmware.

Buka monitor pada baud rate 115200:

```powershell
py -m platformio device monitor --port COM7 --baud 115200
```

Atau:

```powershell
pio device monitor -p COM3 -b 115200
```

Boot normal diharapkan menampilkan proses koneksi Wi-Fi dan MQTT. Untuk keluar dari monitor PlatformIO, tekan `Ctrl+C`.

Jika muncul:

```text
Identity or CA unavailable; device halted.
```

Periksa `data/identity.json`, `data/ca.pem`, lalu jalankan `uploadfs` ulang hanya dengan file unit yang benar.

## Provisioning Wi-Fi

Setelah firmware dan filesystem terpasang:

1. Nyalakan ESP8266 tanpa konfigurasi Wi-Fi.
2. Hubungkan ponsel ke AP `RIZIO-<8 karakter akhir SN>`.
3. Gunakan `setup_code` sebagai password AP.
4. Di aplikasi RizIO, pilih perangkat hasil discovery.
5. Hubungkan ponsel ke AP RIZIO dan kirim SSID, password Wi-Fi, serta setup code melalui provisioning.
6. Kembali ke Wi-Fi rumah.
7. Pastikan ESP8266 tersambung ke broker `mqtt.rizbill.my.id:8883` melalui TLS.

Saat masih berada di AP provisioning, ESP tetap menjawab discovery lokal dan mengirim SN, model, alamat `192.168.4.1`, serta port API lokal. Discovery ini tidak mengirim `device_key`, `setup_code`, atau credential rahasia.

Catatan koneksi: selama HP terhubung ke AP ESP, internet biasanya tidak tersedia sehingga request claim ke cloud belum dapat dikirim. Aplikasi dapat menyimpan SN hasil discovery sebagai pending, lalu mengirim `POST /v1/devices/claim` setelah HP kembali ke internet. Provisioning lokal tetap dapat dilakukan sebelum claim cloud.

Reset Wi-Fi dilakukan dengan menahan tombol reset selama 10 detik saat firmware sedang berjalan. Reset fisik tidak menghapus SN, device key, CA, channel, atau ownership cloud.

## Verifikasi setelah upload

Di serial monitor, pastikan tidak ada error boot atau TLS. Dari aplikasi:

- perangkat muncul sebagai online;
- status dan IP perangkat terbaca;
- channel relay sesuai wiring;
- perintah GPIO mendapat ACK;
- state GPIO berubah setelah relay dikontrol;
- restart perangkat tetap mempertahankan identity dan Wi-Fi.

Dari backend VPS:

```bash
cd /opt/rizio/infrastructure
curl https://rizio.rizbill.my.id/health
sudo docker compose logs --no-color backend --tail=50
```

Health yang benar:

```json
{"status":"success","data":{"healthy":true,"database":true,"mqtt":true}}
```

## Catatan keselamatan

- GPIO ESP8266 hanya logika 3.3 V. Gunakan relay driver atau modul relay yang sesuai.
- Jangan menghubungkan beban listrik AC langsung ke GPIO.
- Uji dengan LED atau beban tegangan rendah terlebih dahulu.
- Pastikan relay berada pada kondisi OFF selama boot dan reset.
- Jangan memakai `mqtt.rizbill.my.id` dengan CA yang tidak sesuai.
- Jangan menonaktifkan verifikasi TLS atau mengganti ke MQTT plaintext.
- Simpan device key dan setup code sebagai credential produksi rahasia.
