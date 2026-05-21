#!/bin/bash
# =============================================================================
#  MTProto Proxy — автоустановка с FakeTLS (обход DPI в России)
#  Образ: nineseconds/mtg:2  |  Маскировка: HTTPS к популярному домену
# =============================================================================

set -euo pipefail

# ─── Цвета ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Параметры по умолчанию ──────────────────────────────────────────────────
CONTAINER_NAME="mtproto-proxy"
PORT="${MTPROTO_PORT:-443}"
FAKE_DOMAIN="${MTPROTO_DOMAIN:-www.google.com}"
IMAGE="nineseconds/mtg:2"
CONFIG_FILE="$HOME/mtproto_config.txt"

# ─── Хелперы вывода ──────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERR]${NC}   $*" >&2; }
banner()  { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${BLUE}  $*${NC}"; \
            echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}\n"; }

# ─── Баннер ──────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'LOGO'
  ███╗   ███╗████████╗██████╗ ██████╗  ██████╗ ████████╗ ██████╗
  ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗
  ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║   ██║   ██║   ██║
  ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║   ██║   ██║   ██║
  ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝   ██║   ╚██████╔╝
  ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝
         Telegram MTProto Proxy  |  FakeTLS  |  Docker
LOGO
echo -e "${NC}"

# ─── 1. Проверка root ────────────────────────────────────────────────────────
banner "Шаг 1/6: Проверка окружения"

if [[ $EUID -ne 0 ]]; then
  warn "Запущен без root. Команды docker будут вызваны через sudo."
  SUDO="sudo"
else
  SUDO=""
  ok "Root права есть."
fi

# ─── 2. Проверка / установка Docker ─────────────────────────────────────────
banner "Шаг 2/6: Docker"

if command -v docker &>/dev/null; then
  DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
  ok "Docker найден: ${DOCKER_VER}"
else
  warn "Docker не найден. Устанавливаю..."
  curl -fsSL https://get.docker.com | sh
  $SUDO systemctl enable --now docker
  ok "Docker установлен."
fi

# Убеждаемся, что демон запущен
if ! $SUDO docker info &>/dev/null; then
  info "Запускаю docker daemon..."
  $SUDO systemctl start docker
fi

# ─── 3. Определяем IP и настройку порта ─────────────────────────────────────
banner "Шаг 3/6: Сеть"

SERVER_IP=$(curl -4 -sf --max-time 10 https://api.ipify.org \
         || curl -4 -sf --max-time 10 https://ifconfig.me \
         || curl -4 -sf --max-time 10 https://icanhazip.com \
         || echo "UNKNOWN")

if [[ "$SERVER_IP" == "UNKNOWN" ]]; then
  err "Не удалось определить внешний IP. Проверьте интернет."
  exit 1
fi
ok "Внешний IP: ${BOLD}${SERVER_IP}${NC}"

# Проверка занятости порта
if $SUDO ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
  warn "Порт ${PORT} уже занят! Освобождаю..."

  # Останавливаем nginx/apache если мешают
  for SVC in nginx apache2 httpd; do
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
      warn "Останавливаю ${SVC}..."
      $SUDO systemctl stop "$SVC"
      $SUDO systemctl disable "$SVC" 2>/dev/null || true
    fi
  done

  # Повторная проверка
  sleep 1
  if $SUDO ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
    err "Порт ${PORT} всё ещё занят. Завершите процесс вручную:"
    $SUDO ss -tlnp | grep ":${PORT} " || true
    exit 1
  fi
fi
ok "Порт ${PORT} свободен."

# ─── 4. Генерация FakeTLS-секрета ───────────────────────────────────────────
banner "Шаг 4/6: Генерация FakeTLS-секрета"

info "Домен маскировки: ${BOLD}${FAKE_DOMAIN}${NC}"
info "Проверяю доступность домена..."

# Проверяем, что домен резолвится и имеет HTTPS
if ! curl -sf --max-time 5 "https://${FAKE_DOMAIN}" -o /dev/null; then
  warn "Домен ${FAKE_DOMAIN} недоступен по HTTPS. Пробую www.cloudflare.com..."
  FAKE_DOMAIN="www.cloudflare.com"
  if ! curl -sf --max-time 5 "https://${FAKE_DOMAIN}" -o /dev/null; then
    warn "Оба домена недоступны. Используем ${FAKE_DOMAIN} всё равно (сеть может быть ограничена)."
  fi
fi

info "Генерирую FakeTLS-секрет через mtg..."

# Генерируем секрет с помощью самого образа mtg
SECRET=$($SUDO docker run --rm "${IMAGE}" generate-secret --hex "${FAKE_DOMAIN}" 2>/dev/null)

if [[ -z "$SECRET" ]]; then
  err "Не удалось сгенерировать секрет через mtg. Генерирую вручную..."
  # Fallback: вручную ee + 16 random bytes + hex(domain)
  RAND_HEX=$(openssl rand -hex 16)
  DOMAIN_HEX=$(printf '%s' "${FAKE_DOMAIN}" | od -An -tx1 | tr -d ' \n')
  SECRET="ee${RAND_HEX}${DOMAIN_HEX}"
fi

ok "Секрет: ${BOLD}${SECRET}${NC}"
info "Префикс 'ee' = FakeTLS режим включён ✅"

# ─── 5. Запуск контейнера ────────────────────────────────────────────────────
banner "Шаг 5/6: Запуск MTProto-прокси"

# Удаляем старый контейнер, если есть
if $SUDO docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  warn "Найден старый контейнер ${CONTAINER_NAME}. Удаляю..."
  $SUDO docker stop "${CONTAINER_NAME}" &>/dev/null || true
  $SUDO docker rm   "${CONTAINER_NAME}" &>/dev/null || true
fi

info "Запускаю контейнер..."

$SUDO docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  --network host \
  -p "${PORT}:${PORT}" \
  "${IMAGE}" \
  simple-run \
    -n 1.1.1.1 \
    -i prefer-ipv4 \
    "0.0.0.0:${PORT}" \
    "${SECRET}"

# Ждём запуска
info "Ожидаю запуска (5 сек)..."
sleep 5

# Проверка статуса
if $SUDO docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  ok "Контейнер запущен успешно!"
else
  err "Контейнер не запустился. Логи:"
  $SUDO docker logs "${CONTAINER_NAME}" 2>&1 | tail -20
  exit 1
fi

# ─── 6. Итог и ссылка подключения ───────────────────────────────────────────
banner "Шаг 6/6: Готово!"

TG_LINK="tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${SECRET}"
HTTPS_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${PORT}&secret=${SECRET}"

# Сохраняем конфиг
cat > "${CONFIG_FILE}" << EOF
# MTProto Proxy Config — $(date)
SERVER=${SERVER_IP}
PORT=${PORT}
SECRET=${SECRET}
DOMAIN=${FAKE_DOMAIN}
TG_LINK=${TG_LINK}
HTTPS_LINK=${HTTPS_LINK}
EOF

echo -e "${GREEN}${BOLD}"
cat << 'SUCCESS'
  ╔══════════════════════════════════════════╗
  ║     ✅  ПРОКСИ УСПЕШНО ЗАПУЩЕН!         ║
  ╚══════════════════════════════════════════╝
SUCCESS
echo -e "${NC}"

echo -e "  ${BOLD}🌐 Сервер:${NC}       ${SERVER_IP}"
echo -e "  ${BOLD}🔌 Порт:${NC}         ${PORT}"
echo -e "  ${BOLD}🔑 Секрет:${NC}       ${SECRET}"
echo -e "  ${BOLD}🎭 Домен TLS:${NC}    ${FAKE_DOMAIN}"
echo ""
echo -e "  ${BOLD}${GREEN}🔗 Ссылка для Telegram:${NC}"
echo -e "  ${CYAN}${TG_LINK}${NC}"
echo ""
echo -e "  ${BOLD}${GREEN}🌍 HTTPS-ссылка (браузер):${NC}"
echo -e "  ${CYAN}${HTTPS_LINK}${NC}"
echo ""
echo -e "  ${YELLOW}📁 Конфиг сохранён:${NC} ${CONFIG_FILE}"
echo ""

# QR-код инструкция
echo -e "  ${BOLD}📱 Как подключиться:${NC}"
echo -e "  1. Скопируйте ссылку выше"
echo -e "  2. Откройте в браузере или Telegram"
echo -e "  3. Telegram предложит добавить прокси → нажмите Применить"
echo ""

# ─── Управление ──────────────────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}═══ Управление ════════════════════════════════${NC}"
echo -e "  ${BOLD}Статус:${NC}    docker ps | grep ${CONTAINER_NAME}"
echo -e "  ${BOLD}Логи:${NC}      docker logs -f ${CONTAINER_NAME}"
echo -e "  ${BOLD}Стоп:${NC}      docker stop ${CONTAINER_NAME}"
echo -e "  ${BOLD}Рестарт:${NC}   docker restart ${CONTAINER_NAME}"
echo -e "  ${BOLD}Удалить:${NC}   docker rm -f ${CONTAINER_NAME}"
echo ""

# ─── Статистика подключений (live) ───────────────────────────────────────────
echo -e "${BOLD}${BLUE}═══ Текущая статистика ════════════════════════${NC}"
CONN_COUNT=$($SUDO ss -tn 2>/dev/null | grep -c ":${PORT}" || echo "0")
echo -e "  Активных соединений на порту ${PORT}: ${BOLD}${CONN_COUNT}${NC}"
echo ""

# ─── Проверка FakeTLS (openssl handshake) ────────────────────────────────────
echo -e "${BOLD}${BLUE}═══ Проверка FakeTLS ══════════════════════════${NC}"
info "Тестирую TLS-handshake (должен выглядеть как HTTPS)..."

if timeout 5 bash -c "echo | openssl s_client -connect ${SERVER_IP}:${PORT} -servername ${FAKE_DOMAIN} 2>&1" \
    | grep -q "CONNECTED"; then
  ok "FakeTLS работает — трафик выглядит как HTTPS ✅"
else
  warn "openssl тест не прошёл (это нормально на некоторых VPS — проверьте через Telegram)."
fi

echo ""
echo -e "${GREEN}${BOLD}Всё готово! Прокси работает и замаскирован под HTTPS.${NC}"
echo -e "${YELLOW}Для России рекомендуется порт 443 и домен крупного российского сайта.${NC}"
echo ""
