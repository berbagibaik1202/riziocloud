#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
umask 077

command -v docker >/dev/null || { echo 'Docker tidak ditemukan.' >&2; exit 1; }
docker compose version >/dev/null || { echo 'Docker Compose v2 tidak ditemukan.' >&2; exit 1; }
command -v openssl >/dev/null || { echo 'OpenSSL tidak ditemukan.' >&2; exit 1; }

if [[ ! -f .env ]]; then
  random_secret() { openssl rand -hex 32; }
  cat > .env <<EOF
DB_NAME=rizio
DB_USER=rizio
DB_PASSWORD=$(random_secret)
DB_ROOT_PASSWORD=$(random_secret)
JWT_SECRET=$(random_secret)
CREDENTIAL_ENCRYPTION_KEY=$(random_secret)
INTERNAL_SECRET=$(random_secret)
MQTT_USERNAME=rizio-backend
MQTT_PASSWORD=$(random_secret)
EMQX_DASHBOARD_PASSWORD=$(random_secret)
PUBLIC_ORIGIN=https://change-me.example.com
FIRMWARE_BASE_URL=https://change-me.example.com/firmware
MQTT_CA_FILE=./certs/ca.crt
MQTT_SERVER_CERT_FILE=./certs/server.crt
MQTT_SERVER_KEY_FILE=./certs/server.key
RIZIO_HTTP_PORT=18080
RIZIO_MQTT_PORT=18883
RIZIO_EMQX_DASHBOARD_PORT=18083
EOF
  chmod 600 .env
  echo 'Dibuat infrastructure/.env dengan kredensial acak.'
fi

if grep -qE '^PUBLIC_ORIGIN=https://change-me\.example\.com$|^FIRMWARE_BASE_URL=https://change-me\.example\.com/firmware$' .env; then
  echo 'Ubah PUBLIC_ORIGIN dan FIRMWARE_BASE_URL di infrastructure/.env sebelum deploy.' >&2
  exit 1
fi

required_files=(MQTT_CA_FILE MQTT_SERVER_CERT_FILE MQTT_SERVER_KEY_FILE)
for variable in "${required_files[@]}"; do
  file_path="$(awk -F= -v key="$variable" '$1 == key {print substr($0, index($0,"=")+1)}' .env)"
  if [[ -z "$file_path" || ! -f "$file_path" ]]; then
    echo "$variable menunjuk file yang tidak ditemukan: $file_path" >&2
    exit 1
  fi
done

internal_secret="$(awk -F= '$1 == "INTERNAL_SECRET" {print substr($0, index($0,"=")+1)}' .env)"
node_cookie="$(openssl rand -hex 32)"
sed -e "s/__INTERNAL_SECRET__/${internal_secret}/g" -e "s/__NODE_COOKIE__/${node_cookie}/g" \
  emqx/emqx.conf.template > emqx/generated.conf
chmod 600 emqx/generated.conf

docker compose --env-file .env config --quiet
docker compose --env-file .env up --build -d
echo 'Stack RizIO aktif. Migrasi database dijalankan otomatis oleh service migrate.'
echo 'HTTP lokal: 127.0.0.1:'"$(awk -F= '$1 == "RIZIO_HTTP_PORT" {print $2}' .env)"
echo 'MQTT lokal: 127.0.0.1:'"$(awk -F= '$1 == "RIZIO_MQTT_PORT" {print $2}' .env)"