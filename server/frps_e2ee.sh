#!/usr/bin/env bash
set -euo pipefail

# Запускать на машине, играющей роль сервера (сейчас — ноутбук, в проде — московский сервер).
# Этот скрипт лежит в репозитории (server/), поэтому переменные окружения
# берём из уже существующего server/.env — того же файла, где лежит DATABASE_URL.
# Просто добавь туда ещё две строки:
#   FRP_TOKEN=тот-же-токен-что-и-на-стороне-frpc
#   FRPS_PORT=7000
#
# server/.env уже в .gitignore — ничего дополнительно настраивать не нужно.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "${ENV_FILE}" ]; then
  set -a
  source "${ENV_FILE}"
  set +a
fi

: "${FRP_TOKEN:?Установи FRP_TOKEN в ${ENV_FILE}}"
FRPS_PORT="${FRPS_PORT:-7000}"

CONFIG_DIR="${SCRIPT_DIR}/frps-config"
mkdir -p "${CONFIG_DIR}"

cat > "${CONFIG_DIR}/frps.toml" <<EOF
bindPort = ${FRPS_PORT}

auth.method = "token"
auth.token = "${FRP_TOKEN}"
EOF

docker rm -f frps-e2ee 2>/dev/null || true

docker run -d \
  --name frps-e2ee \
  --restart unless-stopped \
  --network host \
  -v "${CONFIG_DIR}/frps.toml:/etc/frp/frps.toml" \
  fatedier/frps:v0.70.0 \
  -c /etc/frp/frps.toml

echo "frps-e2ee запущен и слушает порт ${FRPS_PORT}."
echo "После того как подключится frpc с NAS, MinIO станет доступен ЗДЕСЬ, на этой машине,"
echo "по адресу http://127.0.0.1:9000 — как будто MinIO работает локально."
