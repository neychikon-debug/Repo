

#!/usr/bin/env bash
set -e
# =========================================================
# MTProto Proxy + FakeTLS in Docker
# Автоустановка на 443 порт
# Автосоздание persistent-конфига
# После рестарта Docker контейнер автоматически поднимется
# =========================================================
# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo "Запусти скрипт от root"
  exit 1
fi
# =========================
# Настройки
# =========================
CONTAINER_NAME="mtproto-proxy"
DATA_DIR="/opt/mtproto-proxy"
PORT="443"
# Можно заменить на любой домен CDN
FAKETLS_DOMAIN="www.cloudflare.com"
# =========================
# Установка Docker
# =========================
echo "[+] Установка Docker..."
if ! command -v docker >/dev/null 2>&1; then
    apt update
    apt install -y curl ca-certificates gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    systemctl start docker
else
    echo "[+] Docker уже установлен"
fi
# =========================
# Подготовка директорий
# =========================
echo "[+] Создание директорий..."
mkdir -p ${DATA_DIR}
mkdir -p ${DATA_DIR}/proxy-secret
# =========================
# Генерация secret
# =========================
echo "[+] Генерация secret..."
SECRET=$(openssl rand -hex 16)
echo "$SECRET" > ${DATA_DIR}/proxy-secret/secret
# =========================
# Очистка старого контейнера
# =========================
if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
    echo "[+] Удаление старого контейнера..."
    docker rm -f ${CONTAINER_NAME}
fi
# =========================
# Загрузка образа
# =========================
echo "[+] Загрузка MTProto Proxy образа..."
docker pull telegrammessenger/proxy:latest
# =========================
# Запуск контейнера
# =========================
echo "[+] Запуск контейнера..."
docker run -d \
  --name ${CONTAINER_NAME} \
  --restart unless-stopped \
  -p ${PORT}:443 \
  -v ${DATA_DIR}/proxy-secret:/data \
  -e SECRET=${SECRET} \
  -e TAG=$(openssl rand -hex 16) \
  telegrammessenger/proxy:latest
# =========================
# Получение TAG
# =========================
sleep 5
TAG=$(docker logs ${CONTAINER_NAME} 2>&1 | grep -oP 'tg://proxy\?server=.*?secret=ee.*')
# =========================
# Генерация FakeTLS secret
# =========================
HEX_DOMAIN=$(echo -n ${FAKETLS_DOMAIN} | xxd -ps)
FAKETLS_SECRET="ee${SECRET}${HEX_DOMAIN}"
SERVER_IP=$(curl -4 -s ifconfig.me)
# =========================
# Создание docker-compose
# =========================
echo "[+] Создание docker-compose.yml..."
cat > ${DATA_DIR}/docker-compose.yml <<EOF
version: '3'
services:
  mtproto:
    image: telegrammessenger/proxy:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${PORT}:443"
    environment:
      SECRET: ${SECRET}
      TAG: $(openssl rand -hex 16)
    volumes:
      - ./proxy-secret:/data
EOF
# =========================
# Создание helper scripts
# =========================
cat > /usr/local/bin/mtproto-restart <<EOF
#!/bin/bash
cd ${DATA_DIR}
docker compose down
docker compose up -d
EOF
chmod +x /usr/local/bin/mtproto-restart
# =========================
# Вывод информации
# =========================
echo ""
echo "========================================="
echo " MTProto Proxy установлен"
echo "========================================="
echo ""
echo "IP: ${SERVER_IP}"
echo "PORT: ${PORT}"
echo "SECRET: ${SECRET}"
echo ""
echo "FakeTLS Domain: ${FAKETLS_DOMAIN}"
echo ""
echo "FakeTLS SECRET:"
echo "${FAKETLS_SECRET}"
echo ""
echo "Telegram URL:"
echo "tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${FAKETLS_SECRET}"
echo ""
echo "Docker compose файл: ${DATA_DIR}/docker-compose.yml"
echo ""
echo "Контейнер автоматически стартует после reboot"
echo ""
echo "Команда рестарта:"
echo "mtproto-restart"
echo ""
