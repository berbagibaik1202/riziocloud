# Uji penerimaan PRD

Status awal seluruh skenario perangkat fisik: **belum dijalankan**. Isi tanggal, board, versi firmware, jaringan, dan bukti hasil saat menjalankan. Unit test/build tidak menggantikan UAT.

| PRD 53 | Skenario dan hasil yang diharapkan | Jenis |
| --- | --- | --- |
| 1 | Register, login, refresh, logout; refresh lama ditolak | API + UI |
| 2 | ESP tanpa Wi-Fi membuka AP, setup code salah ditolak, Wi-Fi valid tersimpan | Hardware + mobile |
| 3 | Scan QR URI dan JSON; QR invalid menampilkan error | Mobile kamera |
| 4–5 | Dua user claim bersamaan; tepat satu sukses, claim code tidak bisa dipakai lagi | DB integrasi |
| 6 | User B tidak dapat list/detail/status/control/token/unclaim device A | API keamanan |
| 7 | Boot ESP MQTT TLS; CA/password salah gagal | Broker + hardware |
| 8 | Cabut daya; LWT mengubah offline, last_seen tersedia | Broker + UI |
| 9 | Matikan LAN discovery, GPIO cloud mengubah output dan ACK | End-to-end |
| 10–11 | LAN tersedia dipilih otomatis; hilang LAN fallback cloud tanpa efek ganda | End-to-end |
| 12 | Dua client melihat state aktual setelah kontrol | End-to-end |
| 13–14 | Router/broker restart; ESP reconnect tanpa reset manual | Hardware |
| 15 | RSSI/heap/uptime/version diterima sekitar interval 60 detik | End-to-end |
| 16 | ACK sukses/gagal; tanpa ACK menjadi timeout; ACK device lain ditolak | API + broker |
| 17–18 | Tombol ditahan 10 detik; Wi-Fi hilang tetapi cloud owner tetap | Hardware + API |
| 19–20 | OTA cocok board berhasil dan versi baru dilaporkan; checksum salah ditolak | Hardware |

Tambahan: admin role guard, disable device, firmware model mismatch, unclaim mengeluarkan kode baru sekali, credential tidak muncul dalam respons/log, discovery tanpa secret, local token expired/wrong SN/salah signature ditolak, reboot tidak diulang melalui fallback.

## Pengukuran performa

Catat waktu dari interaksi pengguna sampai ACK state aktual; ukur minimal 100 perintah LAN dan 100 cloud dengan koneksi yang sama dan laporkan median/p95/max, kehilangan command, board dan lokasi server. Target PRD LAN <200 ms dan cloud <2 detik. Jangan menghitung respons API pending sebagai keberhasilan GPIO.

## Skala dan operasi

Simulasikan hingga 1.000 identitas MQTT unik dengan ACL individual, telemetry 60 detik, koneksi ulang bertahap dan burst. Amati pool database, latency, timeout, memori serta retensi logs/commands. Deployment tunggal adalah baseline; skalabilitas 1.000 perangkat belum dibuktikan sebelum load test. Uji backup/restore dan restart service dengan pending commands.
