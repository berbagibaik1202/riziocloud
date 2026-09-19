# Agen 3 — Flutter dan admin web

## Ruang lingkup
Milik: `mobile/**`, `admin/**`, `docs/APPLICATIONS.md`, dokumen ini. Baca PRD 3, 4, 6–14, 30–34, 40–42, 46, 50 serta `docs/CONTRACT.md`.

## Hasil wajib
Flutter Android/iOS: splash, register/login/logout/refresh, secure token storage, dashboard perangkat, QR URI/JSON, claim, provisioning setup code, UDP discovery, local GPIO otomatis dengan fallback cloud request_id konsisten, state setelah ACK, informasi/settings/unclaim/reboot/account. Admin web: login, summary, users/devices, disable, telemetry, firmware register/upload sesuai endpoint backend, OTA, commands/logs, error/loading states. UI Bahasa Indonesia dengan konfigurasi API base URL, tidak menampilkan device credential.

## Penerimaan dan verifikasi
Build/typecheck admin, Flutter analyze/test bila SDK tersedia; tes QR parser dan fallback/ACK jika memungkinkan. Tidak menampilkan status sukses sebelum konfirmasi perangkat. Dokumentasikan konfigurasi native Android/iOS untuk kamera, LAN/provisioning HTTP dan izin jaringan. Daftar halaman dan alur manual. Hubungi koordinator jika kontrak perlu diperluas.

## Catatan hasil
Status: ditugaskan; agen mengisi hasil, pemeriksaan, keterbatasan di sini.
