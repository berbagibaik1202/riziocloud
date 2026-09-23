# Keamanan dan batas kepercayaan

Backend memutuskan ownership dan akses admin; firmware menentukan state GPIO aktual. DEVICE_KEY hanya berada dalam identitas perangkat produksi dan penyimpanan credential backend terenkripsi. Password akun di-hash, refresh token disimpan sebagai hash dan dapat dicabut. Jangan memasukkan secret ke log, QR claim, atau respons discovery.

## Local control

Token pemilik lokal ditandatangani HMAC dengan device key, berumur maksimum 60 detik. Aplikasi tidak menerima device key. Firmware memeriksa SN, scope, signature dan kedaluwarsa menggunakan waktu valid. Token ini dapat dipakai sekali untuk enrollment kontrol offline dengan kunci acak terpisah, tersimpan di LittleFS dan FlutterSecureStorage. Permintaan offline memakai challenge acak sekali pakai (15 detik berdasarkan uptime), HMAC-SHA256 yang mengikat SN, nonce, metode, path dan body; tidak membutuhkan internet/NTP. Enrollment HTTP harus pada LAN tepercaya karena token dan kunci pairing dapat diamati. Respons HTTP belum ditandatangani/dienkripsi. Lihat DEVICE-PROTOCOL.md untuk format tepat.

Kunci offline berlaku sampai dicabut melalui DELETE /api/v1/local-access atau factory reset. Aplikasi mencabut di ESP sebelum unclaim dan menghapus cache ponsel ketika logout/perangkat dilepas. Unclaim/disable dari admin/API saat ESP offline tidak mencabut kunci pada flash: lakukan reset fisik sebelum menyerahkan perangkat kepada pemilik baru. Pembatasan ini berbeda dari token singkat yang kedaluwarsa maksimal 60 detik.

Provisioning menggunakan setup code unik yang dicetak terpisah dari QR claim, berlaku pada AP perangkat. Wi-Fi credential hanya dikirim ke perangkat selama setup; kemampuan enkripsi flash ESP8266/ESP32 berbeda. Factory reset membersihkan konfigurasi operasional tanpa menghapus identitas permanen atau ownership server.

## Infrastruktur

Hanya HTTPS 443 dan MQTTS 8883 diekspos ke jaringan. Dashboard EMQX dibatasi loopback host. MySQL dan backend tidak menerbitkan port host. nginx memblokir `/internal/`; callback broker membutuhkan secret tambahan. ACL default deny tanpa fallback file allow-all, dan cache ACL dinonaktifkan agar disable diperiksa ulang pada operasi berikutnya. Implementasi callback mengikuti format JSON resmi [autentikasi EMQX](https://docs.emqx.com/en/emqx/latest/access-control/authn/http.html) dan [otorisasi EMQX](https://docs.emqx.com/en/emqx/latest/access-control/authz/http.html).

Sertifikat development dibuat lokal dan harus dipercaya eksplisit oleh perangkat pengujian. Produksi memakai sertifikat domain yang valid dan SAN yang cocok, serta mount kunci dengan izin terbatas. Jangan menonaktifkan validasi sertifikat. Image/tag, pembaruan keamanan, retensi log, backup MySQL, rotasi credential, dan pemulihan restore harus ditinjau sebelum deployment produksi.

## OTA

Firmware harus cocok model dan hardware, diambil melalui HTTPS dan diverifikasi SHA256 sebelum aktivasi. Checksum mendeteksi korupsi; keaslian metadata bergantung pada backend/MQTT/TLS. Firmware signing dan secure boot memberi perlindungan tambahan bila hardware mendukung. Uji kegagalan listrik, ruang flash, checksum salah, sertifikat salah, recovery fisik dan pelaporan versi pada perangkat nyata.
