# Menyiapkan identitas perangkat

1. Operator produksi membuat inventaris melalui `POST /v1/admin/devices` memakai akun admin; lihat `docs/API.md` untuk body.
2. Simpan respons sekali pakai pada `production/inventory-response.json`, di luar log aplikasi. Folder `production/` diabaikan Git.
3. Jalankan converter dengan direktori output baru:

```powershell
node tools/prepare-device.mjs production/inventory-response.json mqtt.example.com production/ESP-A7F9C231
```

Hasil: `identity.json` untuk flash, `claim-qr.txt` untuk konten generator QR/label, dan `setup-label.txt` untuk password AP/provisioning. Converter tidak menghasilkan gambar QR. DEVICE_KEY hanya masuk identity; tidak masuk kedua label. Respons input tetap sensitif dan harus disimpan dengan kontrol akses produksi.

Periksa model, hardware, channels dan reset_pin (default 0) terhadap wiring board. Salin `identity.json` dan CA broker sebagai `ca.pem` ke `firmware/data`, lalu ikuti `docs/PROVISIONING.md`. Jangan menimpa filesystem saat OTA rutin karena identitas dan Wi-Fi ada di sana. Converter menolak menimpa direktori output yang sudah ada.

Verifikasi:

```powershell
node --test tools/prepare-device.test.mjs
```

Tes memakai credential palsu dan memeriksa pemisahan secret/QR serta perlindungan overwrite identitas.
