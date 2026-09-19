# Agen 2 — Firmware perangkat

## Ruang lingkup
Milik: `firmware/**`, `docs/DEVICE-PROTOCOL.md`, `docs/PROVISIONING.md`, dokumen ini. Baca PRD 5, 9, 11–22, 35–39, 43–45, 49 serta `docs/CONTRACT.md`.

## Hasil wajib
PlatformIO Arduino target ESP8266 dan ESP32 dengan modul portable. Identitas produksi terpisah config Wi-Fi; AP provisioning authenticated setup code; reconnect; MQTT TLS/ACL topics/LWT; GPIO configurable safe defaults; command dedup/ACK; telemetry/state; UDP discovery tanpa secret; local token verification; reset physical 10 detik mempertahankan identity/ownership; OTA HTTPS SHA256 sebelum aktivasi. Jelaskan rollback dan keterbatasan penyimpanan aman masing-masing platform.

## Penerimaan dan verifikasi
Coba build kedua target bila toolchain tersedia. Tes host untuk parsing/security bila relevan. Dokumentasikan wiring aman, provisioning identitas/CA/setup code, flashing, konfigurasi channel, recovery, UAT LAN/cloud dan OTA. Jangan klaim hardware teruji tanpa device fisik. Laporkan dependensi dan bukti kegagalan build jika lingkungan menghalangi.

## Catatan hasil
Status: ditugaskan; agen mengisi hasil, pemeriksaan, keterbatasan di sini.
