# API RizIO v1

Base `/v1`, JSON. Sukses `{ "status":"success", "data": ... }`; gagal `{ "status":"error", "code":"...", "message":"..." }`. Semua endpoint user/admin memakai `Authorization: Bearer <access_token>` kecuali register/login/refresh/logout. Respons sensitif memakai `Cache-Control: no-store`. HTTPS diterminasi reverse proxy; backend tidak boleh diekspos langsung ke internet.

## Menjalankan backend

1. Dari `backend`, jalankan `npm ci`, salin `.env.example` ke `.env`, isi secret acak serta koneksi MySQL/MQTT TLS.
2. `npm run migrate` membuat tabel dengan migrasi restart-safe; akun DB harus memiliki izin DDL ketika menjalankan migrasi. MySQL DDL implicit commit, bukan migrasi transaksi penuh.
3. Isi environment `ADMIN_EMAIL` dan `ADMIN_PASSWORD` (minimal 12 karakter), jalankan `npm run bootstrap` sekali. Email yang sudah ada ditolak; tidak ada default admin/password.
4. `npm run dev`; produksi `npm run build` dan `npm start`. Container menjalankan `node dist/server.js`; migrasi/bootstrap produksi memakai `node dist/migrate.js` / `node dist/bootstrap.js`.
5. `npm test` menjalankan pengujian service/HTTP dengan adapter SQL in-memory khusus tes. Ini bukan bukti integrasi MySQL/EMQX atau uji hardware. `npm run build` memeriksa TypeScript produksi.

Semua timestamp database memakai UTC. HTTP listening sebelum MQTT connect agar callback broker tidak deadlock. `GET /health` tanpa autentikasi mengembalikan data `{healthy,database,mqtt}`, HTTP 503 ketika salah satu dependency belum siap.

Telemetry DHT11 disimpan di state perangkat sebagai `temperature_c` (Celsius) dan `humidity_percent` (persen). Field sensor dapat absen pada perangkat yang tidak memiliki DHT11.

## Akun

| Method dan path | Body / hasil data |
| --- | --- |
| POST `/auth/register` | `{email,name,password}` → `{user,access_token,refresh_token}`, HTTP 201 |
| POST `/auth/login` | `{email,password}` → token pair dan user |
| POST `/auth/refresh` | `{refresh_token}` → token pair baru; token lama habis pakai |
| POST `/auth/logout` | `{refresh_token}` → `{logged_out:true}` |
| GET `/auth/me` | `{id,email,name,role,status}` |

Password bcrypt cost 12, minimal 12 maksimal 72 karakter. Access JWT HS256 berlaku 15 menit, issuer `rizio`, audience `rizio-api`. Refresh token random 256-bit berlaku 30 hari dan hanya hash SHA256 disimpan. Penggunaan ulang refresh yang sudah dicabut mencabut seluruh family. Logout mencabut refresh family; access JWT yang sudah terbit tetap valid sampai 15 menit. Disable user segera ditolak karena setiap autentikasi membaca status akun database.

Rate limit berbasis IP: `/v1` 300/menit, `/auth` 20/15 menit, claim dan unclaim masing-masing 10/15 menit, commands 120/menit. Penyimpanan limiter lokal proses: jalankan satu instance MVP; gunakan shared store sebelum scaling. Atur `TRUST_PROXY` sesuai jumlah proxy terpercaya, jangan expose port API langsung.

## Perangkat user

| Method dan path | Body / hasil data |
| --- | --- |
| GET `/devices` | Array perangkat milik akun |
| POST `/devices/claim` | `{sn}` → perangkat; claim atomik transaksi `SELECT ... FOR UPDATE` dan conditional update |
| GET `/devices/:sn` | Perangkat lengkap, credential tidak pernah disertakan |
| PATCH `/devices/:sn` | `{name}` → perangkat |
| DELETE `/devices/:sn` | `{password}` → `{sn,unclaimed:true}` |
| GET `/devices/:sn/status` | `{sn,online,last_seen,gpio,rssi,ip_address,uptime,free_heap,firmware_version,temperature_c,humidity_percent}`; field sensor dapat absen |
| GET `/devices/:sn/local-token` | `{token,expires_at}` berlaku 60 detik |
| POST `/devices/:sn/commands` | `{command,pin?,state?,firmware_id?,request_id?}` → `{request_id,device,command_status}`, HTTP 202 |
| GET `/devices/:sn/commands/:request_id` | `{request_id,device,command_status,status,error,created_at,sent_at,ack_at}` |

Perangkat: `{sn,name,model,device_type,relay_type,dht11_pin,hardware_version,firmware_version,online,disabled,last_seen,capabilities,channels,state}`. `device_type` mendukung `relay`, `switch`, `sensor`, dan `other`; perangkat `sensor` memakai `dht11_pin` serta channel bertipe `sensor`. `state.gpio` memakai nomor pin string. Channel `{id,pin,name,type,active_low}`. Perangkat disabled tetap tampak di daftar dengan offline; kontrol/detail/token ditolak. Unclaim tetap dapat dilakukan oleh pemilik dengan password.

Command `gpio.set` wajib `pin` kanal `switch` terdaftar dan `state` boolean. `system.reboot` tidak menerima pin/state. `system.factory_reset` membutuhkan `capabilities.factory_reset=true`; ownership cloud tidak berubah. `firmware.update` membutuhkan ID firmware aktif dengan model/hardware cocok. Request ID UUID optional dipakai deduplikasi; reuse payload berbeda/akun/perangkat berbeda ditolak. Simpan UUID yang sama untuk retry GPIO dari LAN ke cloud. Tidak ada retry otomatis command reboot/reset/OTA.

Command disimpan sebelum publish QoS1, lalu menjadi `sent`, `success`, `failed`, atau `timeout`. Timeout default 15 detik, OTA 300 detik (`COMMAND_TIMEOUT_SECONDS`, `OTA_TIMEOUT_SECONDS`). Sweep persisten tiap detik menutup pending/sent setelah restart. ACK hanya boleh mengubah command perangkat asal yang belum terminal dan belum kedaluwarsa. Timeout/publish error tidak membuktikan command tidak pernah dieksekusi; verifikasi actual state/firmware sebelum mencoba ulang aksi sensitif. Command sudah terkirim tidak dapat ditarik kembali oleh unclaim/disable.

Local token format `base64url(JSON {sn,exp,scope:"local"}).hex(HMAC-SHA256(device_key,payloadBase64))`. Device key tetap di server/perangkat. Token yang terbit sebelum unclaim/disable masih dapat dipakai maksimal 60 detik. Token lokal membutuhkan cloud saat diterbitkan/diperbarui; kontrol LAN offline jangka panjang bukan cakupan versi ini.

## Admin

Role admin wajib. Daftar memakai batas tetap untuk MVP (users/devices 1000, commands/logs/firmwares 500), terbaru lebih dahulu; pagination belum tersedia.

| Method dan path | Body / hasil |
| --- | --- |
| GET `/admin/summary` | `total_devices,online_devices,offline_devices,total_users,total_commands,successful_commands,timeout_commands,command_latency_ms,command_success_rate,mqtt_connected,mqtt_connections,firmware_distribution` |
| GET `/admin/users` | Array user publik |
| PATCH `/admin/users/:id` | `{status:"active"|"disabled"}`; akun sendiri tidak dapat diubah |
| GET `/admin/devices` | Array perangkat beserta `owner_user_id` dan state telemetry |
| POST `/admin/devices` | Inventaris produksi; detail di bawah |
| PATCH `/admin/devices/:sn` | `{name?:string,disabled?:boolean}`; minimal satu field. `disabled:true` adalah soft-delete/nonaktifkan perangkat dan membatalkan command yang masih berjalan. Data device tidak dihapus permanen agar audit, command, dan ownership tetap konsisten. |
| GET `/admin/commands` | Array `{request_id,command,command_status,error,created_at,sent_at,ack_at,sn,user_id}` |
| GET `/admin/logs` | Array audit/availability log, secret disunting |
| GET `/admin/firmwares` | Array metadata firmware |
| POST `/admin/firmwares` | `{model,hardware_version,version,url,checksum,file_size,release_notes}` |
| POST `/admin/firmwares/upload` | Multipart `file`, `model`, `hardware_version`, `version`, optional `release_notes` |
| POST `/admin/devices/:sn/ota` | `{firmware_id}` → command response |

`command_success_rate` rasio 0..1 seluruh command. `mqtt_connections` estimasi jumlah perangkat online dari telemetry/LWT, bukan broker metric presisi. `command_latency_ms` rata-rata created→ACK untuk command ber-ACK. Current telemetry disimpan; riwayat time-series belum disimpan.

CRUD inventory admin tersedia melalui `GET`/`POST`/`PATCH` pada `/admin/devices`. Operasi delete menggunakan soft-delete melalui `PATCH {"disabled":true}`; perangkat dapat dipulihkan dengan `PATCH {"disabled":false}`. Penghapusan fisik tidak disediakan karena perangkat direferensikan oleh command dan audit log.

Inventaris body:

```json
{"sn":"ESP-A7F9C231","name":"Relay ruang tamu","model":"ESP-RELAY-1CH","hardware_version":"1.0","firmware_version":"1.0.0","capabilities":{"switch":1,"factory_reset":true},"channels":[{"id":1,"pin":5,"name":"Relay 1","type":"switch","active_low":true}]}
```

Hasil `{device,production_credentials:{sn,device_key,setup_code}}`. Credential ini hanya respons admin produksi, harus langsung disimpan ke media produksi aman; tidak ada endpoint mengambil ulang. Device key AES-256-GCM dienkripsi dengan `CREDENTIAL_ENCRYPTION_KEY` (hex 32 byte), setup code tidak disimpan backend. Default setup code 48 karakter kompatibel passphrase AP. Body boleh memuat device_key 64 hex lowercase dan setup_code 16..63 karakter dari generator produksi; keduanya wajib berbeda. Jangan gunakan respons produksi dalam aplikasi user atau QR publik. Channel pin/id wajib unik.

Firmware URL HTTPS maksimal 1024 karakter, checksum SHA256 64 hex, version `x.y.z` optional prerelease, ukuran maksimal 16 MiB. Metadata eksternal tidak di-download server (mencegah SSRF); ukuran/checksum untuk URL eksternal menjadi pernyataan operator dan diverifikasi perangkat ketika OTA. Upload binary memeriksa magic ESP `0xE9`, ukuran, menghitung SHA256 dan menulis file content-addressed; ini bukan verifikasi tanda tangan atau jaminan binary cocok hardware. File disajikan `/firmware/<sha256>.bin`, URL publik dari `FIRMWARE_PUBLIC_URL`; pasang volume persisten pada `FIRMWARE_DIR`. Upload ulang checksum sama memakai file lama. Gagal insert metadata dapat meninggalkan file orphan, aman tetapi perlu pembersihan operator.

`GET /v1/device/firmware/latest` memakai HTTP Basic `SN:DEVICE_KEY`, mengembalikan metadata aktif terbaru menurut waktu publikasi yang cocok model/hardware atau `null`. Operator bertanggung jawab urutan versi; endpoint tidak melakukan semver downgrade prevention. Pengiriman OTA admin tetap memeriksa kecocokan perangkat.

## Error

`AUTH_INVALID`, `ADMIN_REQUIRED`, `DEVICE_NOT_FOUND`, `DEVICE_NOT_OWNED`, `DEVICE_DISABLED`, `DEVICE_OFFLINE`, `DEVICE_ALREADY_CLAIMED`, `INVALID_GPIO`, `COMMAND_NOT_ALLOWED`, `REQUEST_ID_CONFLICT`, `COMMAND_NOT_FOUND`, `COMMAND_TIMEOUT`, `MQTT_ERROR`, `FIRMWARE_INCOMPATIBLE`, `INVALID_FIRMWARE_BINARY`, `VALIDATION_ERROR`, `RATE_LIMITED`. Invalid JSON tidak membeberkan body/error stack. Audit payload dibatasi field aman dan redaksi rekursif; raw MQTT error, password, JWT/refresh, setup/device secret tidak dicatat.
