#!/bin/bash

# Останавливать скрипт при любой ошибке (чтобы не перезапускать службу, если сборка упала)
set -e

# Папка самого скрипта (server/) — чтобы запуск работал из любой директории
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Подтягиваем изменения из Git..."
git pull

echo "==> Компилируем Go-сервер..."
go build -o oshinobu-server .

echo "==> Перезапускаем службу systemd..."
sudo systemctl restart oshinobu-server

echo "==> Проверяем статус службы..."
sudo systemctl status oshinobu-server --no-pager
