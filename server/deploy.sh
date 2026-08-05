#!/bin/bash

# Останавливать скрипт при любой ошибке (чтобы не перезапускать службу, если сборка упала)
set -e

echo "==> Подтягиваем изменения из Git..."
git pull

echo "==> Компилируем Go-сервер..."
go build -o oshinobu-server .

echo "==> Перезапускаем службу systemd..."
sudo systemctl restart oshinobu-server

echo "==> Проверяем статус службы..."
sudo systemctl status oshinobu-server --no-pager
