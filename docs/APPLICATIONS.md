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

## 2. Fitur Web Serial Flasher (`esptool-js`)

Fitur Web Flasher diakses melalui menu **Flash Web** atau tombol **⚡ Flash** pada tabel perangkat:

```
[ Pilih Perangkat (SN) ] ──> [ Muat identity.json & Unduh CA ]
          │
          ▼
[ Pilih Firmware (.bin) ] ──> [ Hubungkan Port Serial USB ]
          │
          ▼
[ Klik Mulai Flash ] ───> [ Visual Progress Bar & Log Real-Time ]
```

1. **Pemilihan Perangkat**: Memilih perangkat yang terdaftar di tenant. Sistem mengambil data `identity.json` terdekripsi melalui `GET /v1/devices/:sn/identity`.
2. **Download File Konfigurasi**: Tersedia tombol satu-klik untuk mengunduh `identity.json` dan root `ca.pem`.
3. **Pemilihan Firmware**: Menggunakan firmware resmi dari katalog OTA server atau unggah berkas `.bin` kustom dari komputer.
4. **Koneksi Serial USB**: Menggunakan `navigator.serial` untuk berkomunikasi langsung dengan bootloader ROM ESP8266/ESP32.
5. **Flashing & Verifikasi**: Otomatis mendeteksi arsitektur chip, MAC address, flash size, menghapus sector yang diperlukan, menulis binary pada offset yang tepat, dan memvalidasi checksum MD5.

---

## 3. Aplikasi Mobile Flutter (`mobile/flutter`)

Aplikasi mobile dirancang untuk pengguna akhir dan teknisi lapangan:
- **Autentikasi & Penyimpanan Aman**: Menggunakan Flutter Secure Storage untuk access token dan refresh token.
- **Discovery LAN & Dual Mode**: Mendeteksi perangkat di jaringan Wi-Fi lokal menggunakan protokol UDP broadcast untuk kontrol sub-10ms tanpa internet, serta otomatis beralih ke Cloud MQTT saat di luar jangkauan LAN.
- **Klaim & Provisioning**: Pindai QR Code atau masukkan SN dan setup code untuk menghubungkan perangkat baru ke Wi-Fi dan akun pengguna.
- **Kontrol Relay & Telemetri**: Kontrol on/off relay multi-channel dengan konfirmasi ACK dan visualisasi data suhu/kelembaban DHT11.

