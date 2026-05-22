#!/bin/bash

set -e

CONTAINER_NAME="mtproto"
CONFIG_DIR="/opt/mtproto"
CONFIG_FILE="$CONFIG_DIR/config.json"
IMAGE="telegrammessenger/proxy:latest"

echo "[1] Создаю директорию для конфига..."
mkdir -p $CONFIG_DIR

echo "[2] Генерирую секрет..."
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
FAKETLS_DOMAIN="www.cloudflare.com"

echo "[3] Создаю config.json..."
cat > $CONFIG_FILE <<EOF
{
  "port": 443,
  "secret": "$SECRET",
  "tag": "",
  "fake_tls_domain": "$FAKETLS_DOMAIN"
}
EOF

echo "[4] Останавливаю старый контейнер (если есть)..."
docker rm -f $CONTAINER_NAME 2>/dev/null || true

echo "[5] Запускаю MTProto Proxy в Docker..."
docker run -d \
  --name $CONTAINER_NAME \
  --restart=always \
  -p 443:443 \
  -v $CONFIG_DIR:/data \
  $IMAGE

echo ""
echo "=========================================="
echo " MTProto Proxy установлен и запущен!"
echo " Порт: 443"
echo " FakeTLS: $FAKETLS_DOMAIN"
echo " Secret: $SECRET"
echo ""
echo " Клиентская ссылка:"
echo " tg://proxy?server=$(curl -s ifconfig.me)&port=443&secret=ee$SECRET"
echo "=========================================="
