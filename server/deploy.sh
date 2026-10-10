#!/bin/bash

# Останавливать скрипт при любой ошибке (чтобы не перезапускать службу, если сборка упала)
set -e

# Папка самого скрипта (server/) — чтобы запуск работал из любой директории
SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SERVER_DIR"

# APK для установок не из Google Play: файл oshinobu.apk последнего релиза
# на GitHub → папка, которую сервер раздаёт по /app/apk (APP_APK_DIR в .env).
APK_URL="https://github.com/Nevillested/e2ee-oshino/releases/latest/download/oshinobu.apk"
APK_DIR="$(cd "$SERVER_DIR/.." && pwd)/apk"

echo "==> Подтягиваем изменения из Git..."
git pull

echo "==> Компилируем Go-сервер..."
go build -o oshinobu-server .

# Не удалось скачать APK — не повод не обновлять сервер: прежний APK
# остаётся на месте, деплой продолжается.
echo "==> Обновляем APK из последнего релиза GitHub..."
mkdir -p "$APK_DIR"
APK_TMP="$(mktemp "$APK_DIR/.oshinobu.apk.XXXXXX")"
if curl -fsSL --retry 3 -o "$APK_TMP" "$APK_URL" && [ "$(head -c 2 "$APK_TMP")" = "PK" ]; then
    chmod 644 "$APK_TMP"
    # mv в пределах одной папки атомарен: клиент никогда не скачает недописанный файл
    mv -f "$APK_TMP" "$APK_DIR/oshinobu.apk"
    echo "    APK обновлён: $APK_DIR/oshinobu.apk ($(du -h "$APK_DIR/oshinobu.apk" | cut -f1))"
else
    rm -f "$APK_TMP"
    echo "    ВНИМАНИЕ: APK скачать не удалось (нет релиза с файлом oshinobu.apk?) — оставлен прежний"
fi

echo "==> Перезапускаем службу systemd..."
sudo systemctl restart oshinobu-server

echo "==> Проверяем статус службы..."
sudo systemctl status oshinobu-server --no-pager
