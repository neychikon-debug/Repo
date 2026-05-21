#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║              MTProto Proxy — Docker Auto-Setup Script                   ║
# ║  Автоматически определяет IP, задаёт порт, разворачивает контейнер      ║
# ╚══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
#  ЦВЕТА
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()     { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}\n"; }

# ──────────────────────────────────────────────────────────────────────────────
#  КОНФИГУРАЦИЯ ПО УМОЛЧАНИЮ (можно переопределить переменными окружения)
# ──────────────────────────────────────────────────────────────────────────────
CONTAINER_NAME="${CONTAINER_NAME:-mtproto-proxy}"
IMAGE="${IMAGE:-telegrammessenger/proxy:latest}"
PROXY_PORT="${PROXY_PORT:-}"          # если пусто — спросим у пользователя
SECRET="${SECRET:-}"                  # если пусто — сгенерируем
TAG="${TAG:-dd}"                      # dd = защита от DPI (рекомендуется)
STATS_PORT="${STATS_PORT:-8888}"
RESTART_POLICY="${RESTART_POLICY:-unless-stopped}"

# ──────────────────────────────────────────────────────────────────────────────
#  ПРОВЕРКА ЗАВИСИМОСТЕЙ
# ──────────────────────────────────────────────────────────────────────────────
check_deps() {
  header "Проверка зависимостей"
  local missing=()

  for cmd in docker curl openssl; do
    if command -v "$cmd" &>/dev/null; then
      ok "$cmd найден: $(command -v "$cmd")"
    else
      missing+=("$cmd")
      warn "$cmd не найден"
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Установите отсутствующие зависимости: ${missing[*]}"
  fi

  # Проверяем, что Docker daemon запущен
  if ! docker info &>/dev/null; then
    error "Docker daemon не запущен. Запустите: sudo systemctl start docker"
  fi
  ok "Docker daemon активен"
}

# ──────────────────────────────────────────────────────────────────────────────
#  ОПРЕДЕЛЕНИЕ ПУБЛИЧНОГО IP
# ──────────────────────────────────────────────────────────────────────────────
detect_ip() {
  header "Определение публичного IP"

  local ip=""
  local services=(
    "https://api.ipify.org"
    "https://ipecho.net/plain"
    "https://checkip.amazonaws.com"
    "https://ifconfig.me/ip"
  )

  for svc in "${services[@]}"; do
    log "Пробуем: $svc"
    ip=$(curl -s --connect-timeout 5 "$svc" 2>/dev/null | tr -d '[:space:]') || true
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      ok "Публичный IP: ${BOLD}$ip${RESET}"
      PUBLIC_IP="$ip"
      return
    fi
  done

  # Fallback — локальный IP
  warn "Не удалось определить публичный IP, используем локальный"
  ip=$(hostname -I | awk '{print $1}')
  [[ -n "$ip" ]] || error "Не удалось определить IP-адрес сервера"
  warn "Локальный IP: $ip (убедитесь что порт проброшен через NAT/firewall)"
  PUBLIC_IP="$ip"
}

# ──────────────────────────────────────────────────────────────────────────────
#  ВЫБОР ПОРТА
# ──────────────────────────────────────────────────────────────────────────────
choose_port() {
  header "Настройка порта"

  if [[ -n "$PROXY_PORT" ]]; then
    log "Порт задан через переменную окружения: $PROXY_PORT"
  else
    echo -e "${YELLOW}Введите порт для MTProto прокси${RESET}"
    echo -e "  Рекомендуется: ${BOLD}443${RESET} (HTTPS), ${BOLD}8443${RESET}, ${BOLD}2053${RESET}, или любой свободный"
    read -rp "  Порт [по умолчанию: 443]: " input_port
    PROXY_PORT="${input_port:-443}"
  fi

  # Валидация
  if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || (( PROXY_PORT < 1 || PROXY_PORT > 65535 )); then
    error "Некорректный порт: $PROXY_PORT"
  fi

  # Проверка занятости порта
  if ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} " || \
     netstat -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
    warn "Порт $PROXY_PORT уже занят — убедитесь что конфликтов нет"
  else
    ok "Порт $PROXY_PORT свободен"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
#  ГЕНЕРАЦИЯ СЕКРЕТА
# ──────────────────────────────────────────────────────────────────────────────
generate_secret() {
  header "Генерация секрета"

  if [[ -n "$SECRET" ]]; then
    log "Секрет задан вручную"
  else
    SECRET=$(openssl rand -hex 16)
    ok "Секрет сгенерирован автоматически"
  fi

  # Для режима dd добавляем префикс
  if [[ "$TAG" == "dd" ]]; then
    FULL_SECRET="dd${SECRET}"
    log "Режим: ${BOLD}dd (защита от DPI)${RESET}"
  else
    FULL_SECRET="$SECRET"
    log "Режим: обычный"
  fi

  ok "Secret: ${BOLD}$SECRET${RESET}"
}

# ──────────────────────────────────────────────────────────────────────────────
#  ОСТАНОВКА СТАРОГО КОНТЕЙНЕРА
# ──────────────────────────────────────────────────────────────────────────────
cleanup_old() {
  header "Очистка старого контейнера"

  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    warn "Найден контейнер '$CONTAINER_NAME' — останавливаем и удаляем..."
    docker stop "$CONTAINER_NAME" &>/dev/null || true
    docker rm   "$CONTAINER_NAME" &>/dev/null || true
    ok "Старый контейнер удалён"
  else
    log "Старых контейнеров '$CONTAINER_NAME' не найдено"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
#  ЗАПУСК КОНТЕЙНЕРА
# ──────────────────────────────────────────────────────────────────────────────
run_container() {
  header "Запуск MTProto прокси"

  log "Скачиваем образ: $IMAGE"
  docker pull "$IMAGE"

  log "Запускаем контейнер..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart "$RESTART_POLICY" \
    -p "${PROXY_PORT}:443" \
    -p "${STATS_PORT}:${STATS_PORT}" \
    -v "${PWD}/mtproto-data:/data" \
    -e SECRET="$SECRET" \
    "$IMAGE"

  ok "Контейнер запущен: ${BOLD}$CONTAINER_NAME${RESET}"
}

# ──────────────────────────────────────────────────────────────────────────────
#  ПРОВЕРКА РАБОТОСПОСОБНОСТИ
# ──────────────────────────────────────────────────────────────────────────────
health_check() {
  header "Проверка состояния"

  local retries=5
  local delay=3

  for ((i=1; i<=retries; i++)); do
    local status
    status=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    if [[ "$status" == "running" ]]; then
      ok "Контейнер работает (статус: running)"
      return
    fi
    log "Попытка $i/$retries — статус: $status, ждём ${delay}с..."
    sleep "$delay"
  done

  warn "Контейнер не перешёл в статус running — проверьте логи:"
  echo "  docker logs $CONTAINER_NAME"
}

# ──────────────────────────────────────────────────────────────────────────────
#  ВЫВОД ИТОГОВОЙ ИНФОРМАЦИИ
# ──────────────────────────────────────────────────────────────────────────────
print_summary() {
  local tg_link="https://t.me/proxy?server=${PUBLIC_IP}&port=${PROXY_PORT}&secret=${FULL_SECRET}"

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║              MTProto Proxy — готов к работе!                ║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${BOLD}Сервер:${RESET}       $PUBLIC_IP"
  echo -e "  ${BOLD}Порт:${RESET}         $PROXY_PORT"
  echo -e "  ${BOLD}Secret:${RESET}       $FULL_SECRET"
  echo -e "  ${BOLD}Контейнер:${RESET}    $CONTAINER_NAME"
  echo -e "  ${BOLD}Статистика:${RESET}   http://${PUBLIC_IP}:${STATS_PORT}/stats"
  echo ""
  echo -e "  ${BOLD}${CYAN}Ссылка для Telegram:${RESET}"
  echo -e "  ${YELLOW}${tg_link}${RESET}"
  echo ""
  echo -e "  ${BOLD}Полезные команды:${RESET}"
  echo -e "    docker logs -f $CONTAINER_NAME      # логи"
  echo -e "    docker restart $CONTAINER_NAME      # перезапуск"
  echo -e "    docker stop $CONTAINER_NAME         # остановка"
  echo ""

  # Сохраняем данные в файл
  local info_file="mtproto-info.txt"
  {
    echo "MTProto Proxy Info"
    echo "=================="
    echo "Server:    $PUBLIC_IP"
    echo "Port:      $PROXY_PORT"
    echo "Secret:    $FULL_SECRET"
    echo "TG Link:   $tg_link"
    echo "Stats:     http://${PUBLIC_IP}:${STATS_PORT}/stats"
    echo "Generated: $(date)"
  } > "$info_file"
  ok "Данные сохранены в: ${BOLD}${info_file}${RESET}"
}

# ──────────────────────────────────────────────────────────────────────────────
#  ТОЧКА ВХОДА
# ──────────────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}${CYAN}"
  echo "  ███╗   ███╗████████╗██████╗ ██████╗  ██████╗ ████████╗ ██████╗ "
  echo "  ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗"
  echo "  ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║   ██║   ██║   ██║"
  echo "  ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║   ██║   ██║   ██║"
  echo "  ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝   ██║   ╚██████╔╝"
  echo "  ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝ "
  echo -e "${RESET}"
  echo -e "  ${BOLD}MTProto Proxy Docker Setup${RESET} — by auto-config script"
  echo ""

  check_deps
  detect_ip
  choose_port
  generate_secret
  cleanup_old
  run_container
  health_check
  print_summary
}

main "$@"
