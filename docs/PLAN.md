# Rencana implementasi RizIO

Sumber kebutuhan: `prd.md` v1.3. Repositori awal hanya berisi PRD; implementasi kini mencakup backend, firmware, Flutter, admin, dan infrastruktur. Status per 24 September 2026: backend build/test, Flutter test, migration histori sensor, build APK debug split ABI, dan verifikasi pada perangkat Android telah dijalankan. UAT hardware penuh tetap perlu dijalankan pada lingkungan produksi.

## Pembagian kepemilikan

| Pelaksana | Area | Dokumen tugas |
| --- | --- | --- |
| Agen 1 | Backend, database, API, MQTT, OTA server | [Backend](tasks/01-backend.md) |
| Agen 2 | Firmware ESP8266/ESP32, provisioning, LAN, OTA device | [Firmware](tasks/02-firmware.md) |
| Agen 3 | Flutter dan dashboard admin web | [Aplikasi](tasks/03-applications.md) |
| Koordinator | Kontrak, Docker Compose, nginx/EMQX, README, integrasi | Dokumen ini |

## Urutan dan aturan integrasi

1. Sepakati kontrak di `CONTRACT.md` sebelum implementasi.
2. Masing-masing agen hanya mengedit area miliknya serta dokumen tugasnya.
3. Perubahan kontrak harus dikomunikasikan kepada koordinator.
4. Jalankan pemeriksaan yang tersedia, catat perintah dan hasil sebenarnya.
5. Bedakan kode yang selesai, build yang lulus, dan UAT perangkat fisik yang belum dijalankan.

## Penerimaan

PRD 53 menjadi daftar UAT akhir: autentikasi; provisioning; scan QR; claim sekali pakai; isolasi owner; MQTT TLS; availability; GPIO cloud/LAN; perpindahan otomatis; sinkronisasi state; reconnect; telemetry; ACK; reset tanpa mengubah ownership; OTA dengan checksum dan pelaporan versi. Target LAN <200 ms dan cloud <2 detik harus diukur pada hardware/jaringan nyata, bukan diklaim dari unit test.

Deployment produksi sudah mendukung migration `004_sensor_readings.sql` melalui service `migrate`. Secret, domain TLS, identitas perangkat produksi, signing/build firmware dan pengujian hardware tetap memerlukan lingkungan yang sesuai. Grafik histori sensor telah diverifikasi dengan data telemetry yang tersimpan di backend.
