# RizIO ESP Cloud Controller

Implementasi monorepo berdasarkan [PRD v1.1](prd.md): backend Express/TypeScript/MySQL, firmware Arduino ESP8266/ESP32, aplikasi Flutter Android/iOS, dashboard admin web, serta konfigurasi Docker Compose/nginx/EMQX.

Dokumentasi tugas dibuat sebelum tiga agen implementasi dijalankan. Pembagian tugas, kontrak integrasi, dan hasil setiap agen tersedia di:

- [Rencana dan pembagian pekerjaan](docs/PLAN.md)
- [Agen backend](docs/tasks/01-backend.md)
- [Agen firmware](docs/tasks/02-firmware.md)
- [Agen aplikasi](docs/tasks/03-applications.md)
- [Kontrak antarkomponen](docs/CONTRACT.md)

## Menjalankan

Stack lengkap membutuhkan Docker Engine/Compose, sertifikat, dan identitas perangkat. Ikuti [panduan infrastruktur](infrastructure/README.md) untuk generator secret, migrasi, bootstrap admin, dan menjalankan stack. Admin disajikan pada origin yang sama dengan API melalui HTTPS.

Untuk mengembangkan komponen secara terpisah:

```powershell
cd backend
npm ci
npm run build
npm test
```

Konfigurasi `.env` dari `backend/.env.example` dengan credential milik lingkungan Anda, jalankan `npm run migrate`, lalu `npm run dev`. Backend runtime memerlukan MySQL dan broker TLS yang terkonfigurasi; unit test memakai adapter database/publisher pengujian.

```powershell
cd admin/web
npm ci
npm run dev
```

```powershell
cd mobile/flutter
flutter pub get
flutter run --dart-define=API_BASE_URL=https://api.example.com/v1
```

```powershell
cd firmware
py -m platformio run -e esp8266 -e esp32
```

Jalankan setiap blok dari root proyek. Untuk perangkat fisik, siapkan identitas/CA/Wi-Fi mengikuti [provisioning](docs/PROVISIONING.md) dan [alat produksi](tools/README.md). QR claim tidak berisi DEVICE_KEY. Domain contoh bukan server yang telah dideploy.

## Dokumentasi teknis

| Area | Panduan |
| --- | --- |
| Endpoint, auth, inventory dan OTA | [API](docs/API.md) |
| MQTT dan ACL | [MQTT](docs/MQTT.md) |
| Firmware dan LAN | [Device protocol](docs/DEVICE-PROTOCOL.md) |
| Wi-Fi, flash dan recovery | [Provisioning](docs/PROVISIONING.md) |
| Upload firmware ESP8266 | [ESP8266 upload](docs/ESP8266-UPLOAD.md) |
| Flutter dan admin | [Applications](docs/APPLICATIONS.md) |
| Build Android Flutter | [Flutter README](mobile/flutter/README.md) |
| Batas keamanan | [Security](docs/SECURITY.md) |
| Penerimaan dan performa | [UAT](docs/UAT.md) |
| Bukti pemeriksaan dan pekerjaan tersisa | [Verification](docs/VERIFICATION.md) |

## Batas penerimaan

Kode/build/test yang tersedia tidak membuktikan seluruh PRD lulus UAT. GPIO fisik, kamera QR, jaringan LAN, reconnect, OTA/pemadaman daya, latensi LAN <200 ms/cloud <2 detik dan skala 1.000 perangkat perlu diuji pada lingkungan nyata. Docker tidak tersedia di mesin awal, sehingga startup stack penuh perlu diverifikasi terpisah.

Local token berlaku 60 detik dan membutuhkan cloud untuk pembaruan; ini belum merupakan kontrol LAN offline tanpa batas. Sinkronisasi aplikasi menggunakan polling dan ACK, bukan stream push. Firmware baseline mengeksekusi channel `switch` dan mengirim telemetry DHT11 setiap 60 detik bila sensor dikonfigurasi. Histori suhu/kelembapan disimpan backend dan ditampilkan mobile sebagai grafik 30 menit/1 jam dengan tooltip nilai titik. Rollback OTA otomatis belum tersedia pada semua target. Rincian batasan per komponen ada di dokumentasi tugas dan keamanan.
