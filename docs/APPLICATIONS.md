# Aplikasi RizIO (Web Dashboard & Mobile Flutter)

Dokumen ini menjelaskan arsitektur, navigasi, dan panduan penggunaan aplikasi RizIO, meliputi **Admin Web Dashboard (SaaS & Web Flasher)** dan **Mobile Flutter App**.

---

## 1. Admin Web Dashboard (`admin/web`)

Dashboard Admin Web dibangun menggunakan **Vite + TypeScript** dengan antarmuka responsif dan modern.

### 1.1 Halaman Publik & Landing Page (`/`)
- **Hero Section**: Menampilkan nilai jual utama RizIO — Kontrol Dual-Mode (Cloud MQTT + Local LAN Offline), Telemetri Suhu/Kelembaban DHT11, Multi-Channel Relay, serta Keamanan Enterprise (AES-256 & TLS 1.3).
- **Interactive Mockup**: Pratinjau interaktif saklar relay multi-channel dan indikator sensor real-time langsung di browser.
- **Sektor Solusi**: Solusi siap pakai untuk Otomasi Industri, Smart Office & Gedung, serta Agrikultur & Green House.
- **Paket Berlangganan SaaS**: Pilihan paket Starter (Personal), Professional (Bisnis/Tenant), dan Enterprise.
- **Modal Login Terpadu**: Akses login cepat untuk Superadmin dan Tenant Admin.

### 1.2 Portal Superadmin
- **Manajemen Tenant**:
  - Pendaftaran tenant baru (nama, slug unik, nama admin, email, password, kuota `max_devices`).
  - Pemantauan penggunaan kuota perangkat tiap tenant.
  - Penangguhan (*suspend*) dan reaktivasi akun tenant.
- **Manajemen Pengguna & Perangkat Global**:
  - Inventarisasi perangkat baru (SN, model, pin, sensor).
  - Alokasi kepemilikan perangkat ke tenant tertentu.
  - Akses kontrol firmware OTA global dan audit log.

### 1.3 Portal Tenant Admin
- **Dashboard Ringkasan**:
  - Kuota perangkat terpakai vs kuota maksimal paket.
  - Status online/offline armada perangkat dalam organisasi tenant.
- **Klaim & Kelola Perangkat**:
  - Klaim perangkat ke tenant menggunakan Serial Number (SN).
  - Monitoring telemetri suhu & kelembaban (DHT11) serta kontrol saklar relay.
- **Manajemen Operator Tenant**:
  - Mengundang dan mengelola akun operator/teknisi dalam lingkup tenant yang sama.
- **Web Serial Flasher (`⚡ Flash Web`)**:
  - Fitur flashing firmware langsung dari browser via Web Serial API (tanpa instalasi Python/PlatformIO).

---

## 2. Fitur Web Serial Flasher & Injeksi Identitas Otomatis (`esptool-js`)

Fitur Web Flasher dapat diakses langsung sebagai **Popup Modal** dari tombol **⚡ Flash** di setiap baris tabel perangkat pada menu **Perangkat** (atau melalui menu mandiri **Flash Web**):

```
[ Klik Tombol ⚡ Flash pada Baris Perangkat ]
                       │
                       ▼
    [ Popup Modal Flasher Terbuka Otomatis ]
  - Backend memuat identity.json spesifik perangkat (terdekripsi)
  - Otomatis mencocokkan model firmware resmi server (atau upload .bin)
                       │
                       ▼
          [ Hubungkan Kabel USB Serial ]
                       │
                       ▼
[ Klik Tombol 🚀 Flash & Injeksi Identitas Otomatis ]
  1. Menulis firmware binary ke ROM ESP (0x00000 atau 0x10000)
  2. Mereset chip ESP
  3. Mengirim payload identity.json via USB Serial (SET_IDENTITY:...)
  4. ESP otomatis menyimpan ke LittleFS dan me-reboot ke mode operasional
```

1. **Popup Modal Langsung di Tabel Perangkat**: Tenant Admin tidak perlu berpindah halaman atau mencari SN perangkat secara manual. Cukup klik tombol `⚡ Flash` di baris perangkat yang diinginkan.
2. **Injeksi Serial Tanpa Partisi Biner**: Menghilangkan kebutuhan membuat file `littlefs.bin` secara terpisah. Kredensial identitas (`sn`, `device_key`, `channels`, dll.) disuntikkan secara otomatis melalui koneksi USB serial yang sedang aktif.
3. **Fallback Root CA**: Firmware secara otomatis menyertakan sertifikat ISRG Root X1 (Let's Encrypt) bawaan sehingga perangkat langsung dapat melakukan TLS handshake dengan broker MQTT tanpa perlu flash file sertifikat manual.
4. **Unduh Backup Manual**: Tetap disediakan tombol unduh `identity.json` dan `ca.pem` jika sewaktu-waktu operator ingin mem-flash via PlatformIO lokal.

---

## 3. Aplikasi Mobile Flutter (`mobile/flutter`)

Aplikasi mobile dirancang untuk pengguna akhir dan teknisi lapangan:
- **Autentikasi & Penyimpanan Aman**: Menggunakan Flutter Secure Storage untuk access token dan refresh token.
- **Discovery LAN & Dual Mode**: Mendeteksi perangkat di jaringan Wi-Fi lokal menggunakan protokol UDP broadcast untuk kontrol sub-10ms tanpa internet, serta otomatis beralih ke Cloud MQTT saat di luar jangkauan LAN.
- **Klaim & Provisioning**: Pindai QR Code atau masukkan SN dan setup code untuk menghubungkan perangkat baru ke Wi-Fi dan akun pengguna.
- **Kontrol Relay & Telemetri**: Kontrol on/off relay multi-channel dengan konfirmasi ACK dan visualisasi data suhu/kelembaban DHT11.

