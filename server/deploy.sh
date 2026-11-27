#!/bin/bash

# Останавливать скрипт при любой ошибке (чтобы не перезапускать службу, если сборка упала)
set -e

# Папка самого скрипта (server/) — чтобы запуск работал из любой директории
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Подтягиваем изменения из Git..."
git pull

echo "==> Компилируем Go-сервер..."
# Временные файлы сборки — на диск, а не в /tmp: на сервере /tmp — tmpfs в памяти
# (478 МБ), и сборка с пустым кэшем (после его чистки) упиралась в "no space left on device"
export GOTMPDIR="${HOME}/.cache/go-tmp"
mkdir -p "$GOTMPDIR"
go build -o oshinobu-server .

echo "==> Перезапускаем службу systemd..."
sudo systemctl restart oshinobu-server

echo "==> Проверяем статус службы..."
sudo systemctl status oshinobu-server --no-pager
