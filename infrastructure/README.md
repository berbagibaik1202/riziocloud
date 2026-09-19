# Menjalankan stack RizIO

Prasyarat: Docker Engine + Compose v2, Bash, OpenSSL, dan Nginx Proxy Manager yang sudah berjalan. Jalankan `bash deploy.sh` dari direktori `infrastructure` pada VPS. Docker tidak perlu membuka port aplikasi ke internet: HTTP aplikasi hanya bind ke `127.0.0.1:18080`, MQTT TLS ke `127.0.0.1:18883`, dan dashboard EMQX ke `127.0.0.1:18083`.

Stack memakai nama Compose `rizio`, volume bernama `rizio_*`, network `private` internal, dan network external `proxy-net` yang sudah dipakai Nginx Proxy Manager. Tidak ada `down -v` pada skrip deploy, sehingga data stack lain tidak disentuh dan data RizIO tetap persisten.

## Persiapan lokal

Dari root repositori:

```bash
bash infrastructure/deploy.sh
```

Pada deployment produksi, isi `PUBLIC_ORIGIN` dan `FIRMWARE_BASE_URL` di `.env`. Sertifikat MQTT dapat memakai file lokal atau langsung file sertifikat NPM melalui `MQTT_CA_FILE`, `MQTT_SERVER_CERT_FILE`, dan `MQTT_SERVER_KEY_FILE`. Skrip tidak mengganti sertifikat atau `.env` yang sudah ada.

Generator `.env` membuat secret acak hanya bila file belum ada, lalu membuat `emqx/generated.conf`. Di VPS, `deploy.sh` melakukan hal yang sama tanpa membutuhkan Node.js. Tidak mencetak secret. File ini diabaikan Git. Jangan menjalankan `docker compose config` ke log publik karena output dapat berisi secret. Untuk memeriksa konfigurasi tanpa menampilkan nilainya:

```powershell
docker compose --project-directory infrastructure --env-file infrastructure/.env -f infrastructure/docker-compose.yml config --quiet
docker compose --project-directory infrastructure --env-file infrastructure/.env -f infrastructure/docker-compose.yml up --build -d
```

MySQL siap dahulu, service `migrate` menjalankan migrasi, backend membuka HTTP dan tersambung ke broker dengan retry. EMQX menghubungi callback backend untuk autentikasi; karena itu backend tidak menunggu MQTT sebelum membuka HTTP.

NPM meneruskan HTTPS ke `http://rizio-nginx:80`; URL publiknya menjadi `https://domain-anda`. Health publik berada di `https://domain-anda/health`. Dashboard EMQX hanya dapat dibuka dari VPS melalui `http://127.0.0.1:18083` atau melalui Proxy Host NPM yang dibatasi akses admin. Jangan membuat port-port tersebut listen pada `0.0.0.0`.

Untuk perangkat, buat **Stream** TCP di NPM dari port publik MQTT (umumnya `8883`) ke `rizio-emqx:8883`. Stream meneruskan TLS tanpa terminasi. Buat sertifikat Let’s Encrypt untuk hostname MQTT di NPM, lalu arahkan `.env` ke file sertifikat NPM, misalnya:

```env
MQTT_CA_FILE=/var/lib/docker/volumes/npm_letsencrypt/_data/live/5/fullchain.pem
MQTT_SERVER_CERT_FILE=/var/lib/docker/volumes/npm_letsencrypt/_data/live/5/fullchain.pem
MQTT_SERVER_KEY_FILE=/var/lib/docker/volumes/npm_letsencrypt/_data/live/5/privkey.pem
```

Ganti `5` dengan ID certificate NPM yang benar. Backend memakai trust store CA publik bawaan container ketika `MQTT_CA_PATH` kosong. Saat NPM memperbarui sertifikat, jalankan `bash deploy.sh` kembali untuk me-recreate container EMQX dengan file terbaru. Jangan membuat Proxy Host HTTP untuk MQTT.

Untuk administrator awal, gunakan environment sementara agar password tidak ditulis sebagai argumen proses:

```powershell
$env:ADMIN_EMAIL = 'admin@example.com'
$rizioAdminSecret = Read-Host 'Password admin minimal 12 karakter' -AsSecureString
$env:ADMIN_PASSWORD = [System.Net.NetworkCredential]::new('', $rizioAdminSecret).Password
docker compose --project-directory infrastructure --env-file infrastructure/.env -f infrastructure/docker-compose.yml run --rm -e ADMIN_EMAIL -e ADMIN_PASSWORD backend node dist/bootstrap.js
Remove-Item Env:ADMIN_EMAIL, Env:ADMIN_PASSWORD
```

Inventaris perangkat dibuat lewat API admin sebelum QR dapat di-claim; lihat `../docs/API.md`. DEVICE_KEY dan setup code dibuat pada produksi perangkat; jangan masukkan DEVICE_KEY ke QR claim.

## Domain produksi

Gunakan sertifikat NPM yang valid untuk hostname MQTT dan sesuaikan hostname pada firmware. TLS HTTP diterminasi oleh NPM. Sampel menyatukan admin/API/firmware pada satu origin HTTPS. Ubah `PUBLIC_ORIGIN` dan `FIRMWARE_BASE_URL` di `.env` jika menggunakan domain nyata; firmware URL harus mengarah ke `/firmware`. Untuk beberapa domain, buat Proxy Host NPM terpisah.

API internal tetap tertutup dari nginx. MySQL tidak dipublikasikan. Broker hanya membuka MQTT TLS 8883; koneksi plaintext dinonaktifkan. Kunci privat server yang dimount harus dapat dibaca user service dalam container namun tidak world-writable. Jangan gunakan sertifikat development untuk produksi.

Volume `mysql-data` menyimpan data, `firmware-data` menyimpan binary OTA, dan volume EMQX menyimpan state/log. Jangan gunakan `down -v` jika ingin mempertahankan data. Jadwalkan backup database dan firmware serta uji restore. Migrasi awal idempotent; perubahan skema berikutnya perlu migrasi bernomor baru. Deployment ini satu instance backend; dukungan 1.000 perangkat harus dibuktikan lewat load test.

## Verifikasi yang masih diperlukan

- `docker compose config --quiet`, build image, startup, migrasi ulang, bootstrap admin.
- Login admin, health DB/MQTT, upload/download firmware melalui nginx.
- MQTT device credential benar/salah, ACL cross-device dan wildcard ditolak.
- CA/hostname invalid gagal, callback internal tidak bisa diakses dari publik.
- Restart broker/backend dan proses ACK/timeout tetap konsisten.

Konfigurasi callback mengacu pada [HTTP authentication EMQX](https://docs.emqx.com/en/emqx/latest/access-control/authn/http.html) dan [HTTP authorization EMQX](https://docs.emqx.com/en/emqx/latest/access-control/authz/http.html). Validasi runtime diperlukan terhadap image EMQX 5.8.8 yang dipin di Compose.
