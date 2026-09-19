# Produksi, provisioning dan verifikasi perangkat

Untuk langkah upload firmware ESP8266 melalui USB/PlatformIO, lihat [catatan upload ESP8266](ESP8266-UPLOAD.md).

## Produksi sebelum pengiriman

1. Install Python dan PlatformIO (`py -m pip install platformio`), lalu buka folder firmware.
2. Salin identity.example.json ke data/identity.json. Buat SN unik; device_key acak kriptografis 32 byte yang dikode hex 64 karakter; setup_code acak unik minimal 12 dan maksimal 63 karakter ASCII. Kedua secret harus berbeda. Registrasikan SN/key/model/hardware/channels melalui inventaris admin. Claim code server sekali pakai dicetak dalam QR publik. Setup code dicetak pada label privat perangkat, berbeda dari claim code.
3. Simpan trust anchor PEM yang benar ke data/ca.pem. Broker certificate harus memiliki SAN cocok mqtt_host. CA host OTA juga harus dipercaya. Jangan memakai setInsecure. Atur MQTT TLS port 8883.
4. Konfigurasi channels dan reset_pin sesuai PCB. Default tombol GPIO0 ke GND dengan pull-up internal; tekan hanya setelah boot (GPIO0 LOW saat power-on dapat memasuki bootloader). ESP8266 dan ESP32 memakai nomor GPIO, bukan tulisan D1 pada board.
5. Build `py -m platformio run -e esp8266` atau `-e esp32`; flash firmware `py -m platformio run -e esp8266 -t upload --upload-port COM3`; provisioning filesystem sekali produksi `py -m platformio run -e esp8266 -t uploadfs --upload-port COM3` (ganti environment untuk ESP32). Direktori data berisi rahasia unit itu saja. Jangan uploadfs ke unit aktif tanpa backup: operasi ini mengganti filesystem termasuk identitas/Wi-Fi.

File secret di data diabaikan Git. Arsip image filesystem dan workstation produksi harus dilindungi. LittleFS default tidak mengenkripsi secret pada ESP8266 maupun build Arduino ESP32 ini. Pemisahan file menjaga semantik reset, bukan perlindungan terhadap pembacaan fisik flash. ESP8266 tidak memiliki secure storage setara secure element; gunakan hardware secure element jika threat model memerlukan. ESP32 produksi membutuhkan konfigurasi flash encryption/secure boot khusus di luar default build ini.

## Pengguna akhir

1. Nyalakan perangkat tanpa kredensial Wi-Fi. Hubungkan ponsel ke WPA2 AP `ESPCTRL-<8 karakter akhir SN>` memakai setup code sebagai password AP.
2. Aplikasi membaca `http://192.168.4.1/api/v1/info` untuk memeriksa SN yang sesuai QR/claim. Internet mungkin tidak tersedia saat ponsel di AP ini.
3. POST `/api/v1/provision` dengan JSON `{ssid,password,setup_code}`. SSID 1–32 byte, WPA password 8–63 byte atau kosong untuk jaringan terbuka. Setelah lima kode salah, endpoint menolak selama 60 detik. Sukses disimpan dan restart.
4. Kembali ke Wi-Fi router; perangkat menghubungkan Wi-Fi, mengambil waktu NTP, lalu MQTT TLS. Aplikasi memperoleh local token dari backend jika user sudah memiliki perangkat. SSID/password salah memerlukan reset fisik dan provisioning ulang; firmware tidak membuka kembali AP otomatis pada gangguan router.

Tahan tombol reset 10 detik saat firmware berjalan untuk menghapus Wi-Fi dan restart ke AP. SN, key, CA, channel produksi, dan ownership cloud tetap. Untuk pindah pemilik, lakukan unclaim terautentikasi di aplikasi; reset fisik saja tidak cukup.

## Wiring dan UAT wajib sebelum produksi

GPIO logika 3.3 V; gunakan relay driver/isolasi dan suplai sesuai modul. Jangan sambungkan beban listrik AC langsung ke GPIO. Active-low diinisialisasi HIGH sebelum mode OUTPUT, sehingga logical OFF. Pull-up/down eksternal dan relay driver harus menjamin OFF selama reset/boot sebelum firmware berjalan. Uji memakai LED/beban tegangan rendah terlebih dahulu.

| Uji | Hasil yang harus diamati |
| --- | --- |
| Boot tanpa identity/CA | Halt, tidak membuka AP publik, flash tidak terformat |
| Setup code salah/benar | 401/rate limit; kode benar menyimpan Wi-Fi lalu restart |
| Broker CA/hostname salah | TLS gagal, tidak fallback plaintext |
| LAN discovery | SN/IP/model saja, tanpa secret |
| Token invalid/expired/SN lain, clock belum valid | 401 dan GPIO tidak berubah |
| LAN GPIO lalu retry MQTT ID sama | ACK konsisten dan output tidak toggle ulang |
| Cloud GPIO | ACK request_id dan state memakai key nomor pin |
| Router/broker mati-hidup | Reconnect, retained state baru dan online true |
| Putus daya | Broker LWT offline; GPIO aman ketika restart |
| Reset tahan 9 detik / 10 detik | Tidak reset / Wi-Fi hilang; identitas dan ownership tetap |
| OTA SHA salah/size salah/HTTPS gagal | Tidak aktivasi firmware baru |
| OTA valid | Reboot, versi baru, identity dan Wi-Fi tetap |
| Putus daya saat staging/boot firmware buruk | Catat pemulihan aktual per board; siapkan serial recovery |
| Latensi | Ukur LAN <200 ms dan cloud <2 s pada jaringan normal |

Belum ada pengujian hardware fisik, koneksi broker sungguhan, relay, atau OTA power-loss dalam sesi implementasi. Bukti compile dicatat dalam docs/tasks/02-firmware.md; compile tidak menggantikan UAT di tabel ini.
