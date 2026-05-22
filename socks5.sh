#!/bin/bash
set -e

# ---------- Установка Docker (если отсутствует) ----------
if ! command -v docker &> /dev/null; then
    echo "Docker не найден. Устанавливаем..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

# ---------- Настройка домена для fake‑TLS ----------
read -p "Введите домен для поддельного TLS (по умолчанию: www.microsoft.com): " FAKE_DOMAIN
FAKE_DOMAIN=${FAKE_DOMAIN:-www.microsoft.com}

# ---------- Генерация секрета с префиксом dd ----------
# Используем od вместо xxd, чтобы не зависеть от vim-common
SECRET="dd$(echo -n "$FAKE_DOMAIN" | od -A n -t x1 | tr -d ' \n')"

# ---------- Рабочая директория для конфигурации ----------
DATA_DIR="/opt/mtproto-proxy"
mkdir -p "$DATA_DIR"

# ---------- Определяем внешний IP ----------
SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "YOUR_SERVER_IP")

# ---------- Удаляем старый контейнер, если есть ----------
if docker ps -a --format '{{.Names}}' | grep -q "^mtproto-proxy$"; then
    echo "Контейнер mtproto-proxy уже существует, удаляем..."
    docker rm -f mtproto-proxy
fi

# ---------- Запуск прокси в Docker ----------
docker run -d \
    --name mtproto-proxy \
    --restart unless-stopped \
    -p 443:443 \
    -v "$DATA_DIR:/etc/telegram" \
    -e SECRET="$SECRET" \
    telegrammessenger/proxy:latest

echo ""
echo "=============================================="
echo "MTProto‑прокси с Fake‑TLS успешно запущен!"
echo "Ссылка для подключения (скопируйте в Telegram):"
echo "https://t.me/proxy?server=${SERVER_IP}&port=443&secret=${SECRET}"
echo ""
echo "Конфигурация хранится в ${DATA_DIR} и будет автоматически"
echo "загружена при перезапуске контейнера."
echo "=============================================="