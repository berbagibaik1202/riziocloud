#!/bin/sh
set -e

# Ensure storage directories exist and are owned by node user even when volumes are mounted from host/named volumes
mkdir -p /app/storage/firmware /app/storage/apps
chown -R node:node /app/storage 2>/dev/null || true

# If running as root, drop privileges to node user
if [ "$(id -u)" = "0" ]; then
  exec su-exec node "$@"
fi

exec "$@"
