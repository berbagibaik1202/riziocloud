# Agen 1 — Backend dan database

## Ruang lingkup
Milik: `backend/**`, `docs/API.md`, `docs/MQTT.md`, dokumen ini. Baca PRD terutama 3–8, 15–35, 43, 46, 50–52 dan `docs/CONTRACT.md`.

## Hasil wajib
Node.js Express TypeScript; migrasi MySQL; password hash; JWT dan refresh token berotasi/logout; claim atomik sekali pakai; ownership seluruh endpoint; validasi dan rate limit; command persisten/ACK/timeout; MQTT state/telemetry/LWT; local token; audit redaksi secret; admin inventory/users/device/firmware/OTA; health dependency; Dockerfile dan contoh env. Implementasikan upload firmware bila memungkinkan, verifikasi metadata dan file.

## Penerimaan dan verifikasi
Build TypeScript lulus. Tes bermakna mencakup auth, isolasi owner, claim concurrency/sekali pakai, ACL cross-device, ACK/timeout dan OTA validation. Gunakan dependency injection atau adapter untuk tes tanpa MySQL/MQTT; jangan menyamarkan tes mock sebagai integrasi nyata. Dokumentasikan migrasi, bootstrap admin/inventaris, endpoint dan command menjalankan.

## Catatan hasil
Status: ditugaskan; agen mengisi hasil, pemeriksaan, keterbatasan di sini.
