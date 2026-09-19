# MQTT RizIO

Backend hanya menerima `mqtts://` dengan verifikasi sertifikat CA; gunakan `MQTT_CA_PATH` untuk CA privat. Username device SN, password device key, client ID SN. Username/client ID service backend sama dengan `MQTT_USERNAME` dan password `MQTT_PASSWORD`; SN inventaris tidak boleh sama dengan username service.

Broker EMQX memanggil `POST /internal/mqtt/auth` body `{username,password,clientid}` dan `/internal/mqtt/acl` body `{username,topic,action}` (`publish`/`subscribe`), header `x-internal-secret: INTERNAL_SECRET`. Respons broker `{result:"allow"|"deny",is_superuser:false}` untuk auth, `{result:...}` untuk ACL. Callback internal wajib dibatasi jaringan; jangan membuka route internal melalui proxy publik. Atur authorization no-match deny, hilangkan anonymous/default allow ACL, dan nonaktifkan cache authorization agar disable perangkat segera dicek ulang. Backend HTTP hidup sebelum koneksi MQTT service dilakukan.

| Topic | Device | Service | Retained |
| --- | --- | --- | --- |
| `devices/{SN}/command` | Subscribe | Publish | Tidak |
| `devices/{SN}/response` | Publish | Subscribe `devices/+/response` | Tidak |
| `devices/{SN}/state` | Publish | Subscribe `devices/+/state` | Ya |
| `devices/{SN}/telemetry` | Publish | Subscribe `devices/+/telemetry` | Tidak |
| `devices/{SN}/availability` | Publish/LWT | Subscribe `devices/+/availability` | Ya |

Device dilarang wildcard, topic perangkat lain, publish command atau subscribe telemetry. Akun service hanya boleh publish command ke SN valid dan subscribe empat wildcard di tabel. Credential device dinonaktifkan saat `disabled=true`; ingest juga menolak pesan perangkat disabled. Backend menggunakan QoS1, sesi clean, reconnect 2 detik. Broker menyimpan retained state/LWT, bukan command.

Command maksimum 2048 byte:

```json
{"request_id":"ebd43f1e-64f1-4058-b203-a00f7773f519","cmd":"gpio.set","pin":5,"state":true,"timestamp":1789232000}
```

OTA menambahkan `firmware_id,model,hardware_version,version,url,checksum,file_size`; release_notes tidak dikirim. Default timeout normal 15 detik, OTA 300 detik. Firmware perlu menjaga koneksi MQTT sepanjang download panjang agar ACK dapat dikirim; periksa reported firmware setelah reboot jika ACK timeout. Tidak ada penjadwalan retry otomatis untuk command persisten setelah crash, karena aksi mungkin sudah berjalan.

ACK:

```json
{"request_id":"ebd43f1e-64f1-4058-b203-a00f7773f519","success":true,"state":{"pin":5,"value":true}}
```

ACK negatif menghasilkan `DEVICE_REJECTED` tanpa menyimpan error mentah yang mungkin mengandung secret. ACK terikat device_id/request_id dan tidak mengubah status terminal. Actual GPIO diproses dari topic `state`, sehingga firmware wajib publish state setelah GPIO berubah, boot, reconnect. Contoh `{ "gpio":{"5":true}, "uptime":83122 }`. Hanya pin yang tercatat di channel inventaris diterima. Telemetry `{rssi,uptime,free_heap,firmware_version,ip_address}` setiap 60 detik; alias `firmware`/`ip` juga diterima dan dinormalisasi. Merge telemetry tidak menghapus GPIO yang sudah tersimpan. Tidak ada nomor urut state pada kontrak v1, sehingga ordered delivery satu publisher diandalkan.

Availability `{online:true}` saat connect; retained LWT `{online:false}`. `last_seen` diperbarui pada pesan valid. Sweep 1 detik membuat offline jika tidak ada pesan selama 180 detik sebagai fallback LWT. Saat broker putus, `/health` menunjukkan MQTT false; stale device ditandai offline setelah ambang tersebut. Reconnect/online/offline disimpan dalam audit log.

Pengujian otomatis memeriksa callback auth/ACL dan transisi ACK/timeout memakai publisher/DB tes. Verifikasi TLS, aturan broker EMQX aktual, disconnect/reconnect, retained/LWT, dan latency perlu dijalankan pada deployment/hardware; belum dibuktikan oleh tes adapter.
