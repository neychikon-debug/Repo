#!/usr/bin/env bash
# =============================================================================
#  socks5.sh — всё в одном файле: SOCKS5 прокси (Dante in Docker)
#
#  При первом запуске автоматически создаёт рядом с собой:
#    • Dockerfile   — образ Alpine + dante-server
#    • sockd.conf   — конфиг Dante (редактируй под себя)
#
#  Команды:
#    ./socks5.sh start    — создать файлы (если нет), собрать образ, запустить
#    ./socks5.sh stop     — остановить и удалить контейнер
#    ./socks5.sh restart  — перечитать sockd.conf и перезапустить
#    ./socks5.sh status   — статус контейнера
#    ./socks5.sh logs     — live tail логов
#    ./socks5.sh test     — проверить что прокси работает (показывает внешний IP)
#    ./socks5.sh config   — открыть sockd.conf в $EDITOR
#
#  Переменные окружения:
#    PROXY_PORT=1080      — порт на хосте (по умолчанию 1080)
# =============================================================================

set -euo pipefail

# ── Конфигурация ──────────────────────────────────────────────────────────────
CONTAINER_NAME="socks5-proxy"
IMAGE_NAME="socks5-dante"
PROXY_PORT="${PROXY_PORT:-1080}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"
SOCKD_CONF="$SCRIPT_DIR/sockd.conf"
# ─────────────────────────────────────────────────────────────────────────────

# ANSI цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()     { echo -e "${CYAN}[proxy]${RESET} $*"; }
ok()      { echo -e "${GREEN}[✔]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
err()     { echo -e "${RED}[✘]${RESET} $*" >&2; }
die()     { err "$*"; exit 1; }
divider() { echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

# ── Генерация файлов ──────────────────────────────────────────────────────────
write_dockerfile() {
    cat > "$DOCKERFILE" <<'DOCKERFILE'
FROM alpine:3.19

RUN apk add --no-cache dante-server

COPY sockd.conf /etc/sockd.conf

EXPOSE 1080/tcp
EXPOSE 1080/udp

CMD ["sockd", "-f", "/etc/sockd.conf", "-N", "1"]
DOCKERFILE
    ok "Создан: $DOCKERFILE"
}

write_sockd_conf() {
    cat > "$SOCKD_CONF" <<'SOCKD'
# ============================================================
# Dante SOCKS5 Server Configuration
# Редактируй этот файл, затем запускай: ./socks5.sh restart
# ============================================================

# Интерфейс на котором слушать входящие подключения
internal: 0.0.0.0 port = 1080

# Интерфейс для исходящих подключений (eth0 внутри контейнера)
external: eth0

# Метод аутентификации: none (без пароля) или username
clientmethod: none
socksmethod: none

# Для аутентификации по логин/паролю — раскомментируй:
# socksmethod: username
# user.privileged: root
# user.notprivileged: nobody

# Разрешаем всем клиентам подключаться
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

# Разрешаем SOCKS5 запросы ко всем адресам
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: connect disconnect error
    socksmethod: none
}
SOCKD
    ok "Создан: $SOCKD_CONF"
}

ensure_files() {
    local created=0
    if [[ ! -f "$DOCKERFILE" ]]; then
        log "Dockerfile не найден — создаю ..."
        write_dockerfile
        created=1
    fi
    if [[ ! -f "$SOCKD_CONF" ]]; then
        log "sockd.conf не найден — создаю ..."
        write_sockd_conf
        created=1
    fi
    if [[ $created -eq 1 ]]; then
        divider
        warn "Файлы созданы. Можешь отредактировать ${BOLD}sockd.conf${RESET} перед стартом."
        divider
    fi
}

# ── Проверки окружения ────────────────────────────────────────────────────────
check_deps() {
    command -v docker &>/dev/null || die "Docker не установлен или не в PATH"
    docker info &>/dev/null 2>&1  || die "Docker daemon не запущен"
}

# ── Хелперы контейнера ────────────────────────────────────────────────────────
container_exists()  { docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; }
container_running() { docker ps    --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; }

build_image() {
    log "Сборка Docker-образа ${BOLD}${IMAGE_NAME}${RESET} ..."
    docker build \
        --tag  "$IMAGE_NAME" \
        --file "$DOCKERFILE" \
        "$SCRIPT_DIR"
    ok "Образ собран: ${IMAGE_NAME}"
}

start_container() {
    log "Запуск контейнера ${BOLD}${CONTAINER_NAME}${RESET} на порту ${PROXY_PORT} ..."
    docker run -d \
        --name    "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p        "${PROXY_PORT}:1080/tcp" \
        -p        "${PROXY_PORT}:1080/udp" \
        --cap-add NET_BIND_SERVICE \
        -v        "${SOCKD_CONF}:/etc/sockd.conf:ro" \
        "$IMAGE_NAME"
    ok "Контейнер запущен → SOCKS5 доступен на 127.0.0.1:${PROXY_PORT}"
}

stop_container() {
    if container_exists; then
        log "Остановка контейнера ${BOLD}${CONTAINER_NAME}${RESET} ..."
        docker stop "$CONTAINER_NAME" &>/dev/null && ok "Контейнер остановлен"
        docker rm   "$CONTAINER_NAME" &>/dev/null && ok "Контейнер удалён"
    else
        warn "Контейнер ${CONTAINER_NAME} не существует — нечего останавливать"
    fi
}

# ── Команды ───────────────────────────────────────────────────────────────────
cmd_start() {
    check_deps
    ensure_files

    if container_running; then
        warn "Контейнер уже запущен. Используй: $0 restart"
        exit 0
    fi
    if container_exists; then
        log "Старый остановленный контейнер найден — удаляю ..."
        docker rm "$CONTAINER_NAME" &>/dev/null
    fi

    build_image
    start_container
    divider
    cmd_status
}

cmd_stop() {
    check_deps
    stop_container
}

cmd_restart() {
    check_deps
    [[ -f "$SOCKD_CONF" ]] || die "sockd.conf не найден: $SOCKD_CONF — запусти сначала: $0 start"

    log "Перезапуск — перечитываю ${BOLD}sockd.conf${RESET} ..."
    divider
    stop_container
    divider
    build_image
    start_container
    divider
    cmd_status
}

cmd_status() {
    check_deps
    divider
    if container_running; then
        echo -e "${GREEN}${BOLD}● RUNNING${RESET}"
        docker ps --filter "name=^${CONTAINER_NAME}$" \
                  --format "  ID:      {{.ID}}\n  Image:   {{.Image}}\n  Status:  {{.Status}}\n  Ports:   {{.Ports}}"
    elif container_exists; then
        echo -e "${YELLOW}${BOLD}● STOPPED${RESET} (контейнер существует, но не запущен)"
        docker ps -a --filter "name=^${CONTAINER_NAME}$" \
                     --format "  ID:      {{.ID}}\n  Status:  {{.Status}}"
    else
        echo -e "${RED}${BOLD}● NOT FOUND${RESET} (контейнер не существует)"
    fi
    divider
    echo -e "  Config:  ${SOCKD_CONF}"
    echo -e "  Port:    ${PROXY_PORT}"
    divider
}

cmd_logs() {
    check_deps
    container_exists || die "Контейнер ${CONTAINER_NAME} не найден"
    log "Логи контейнера ${BOLD}${CONTAINER_NAME}${RESET} (Ctrl+C для выхода) ..."
    docker logs -f --tail 50 "$CONTAINER_NAME"
}

cmd_test() {
    check_deps
    command -v curl &>/dev/null || die "curl не установлен — невозможно выполнить тест"
    log "Тестирую прокси на 127.0.0.1:${PROXY_PORT} ..."

    RESULT=$(curl -s --max-time 10 \
        --proxy "socks5h://127.0.0.1:${PROXY_PORT}" \
        "https://api.ipify.org?format=json" 2>&1) || true

    if echo "$RESULT" | grep -q '"ip"'; then
        EXTERNAL_IP=$(echo "$RESULT" | grep -oP '"ip":"\K[^"]+')
        ok "Прокси работает! Внешний IP: ${BOLD}${EXTERNAL_IP}${RESET}"
    else
        err "Прокси не отвечает или ошибка подключения."
        err "Ответ: $RESULT"
        exit 1
    fi
}

cmd_config() {
    [[ -f "$SOCKD_CONF" ]] || die "sockd.conf не найден — запусти сначала: $0 start"
    local editor="${EDITOR:-vi}"
    log "Открываю ${BOLD}sockd.conf${RESET} в $editor ..."
    "$editor" "$SOCKD_CONF"
    log "После изменений запусти: ${BOLD}$0 restart${RESET}"
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    echo -e ""
    echo -e "${BOLD}  SOCKS5 Proxy Manager${RESET} — Dante in Docker (all-in-one)"
    echo -e ""
    echo -e "  ${CYAN}Использование:${RESET}"
    echo -e "    $0 <команда>"
    echo -e ""
    echo -e "  ${CYAN}Команды:${RESET}"
    echo -e "    ${BOLD}start${RESET}     — создать файлы (если нет), собрать образ, запустить"
    echo -e "    ${BOLD}stop${RESET}      — остановить и удалить контейнер"
    echo -e "    ${BOLD}restart${RESET}   — перечитать sockd.conf и перезапустить"
    echo -e "    ${BOLD}status${RESET}    — показать статус"
    echo -e "    ${BOLD}logs${RESET}      — live tail логов"
    echo -e "    ${BOLD}test${RESET}      — проверить прокси (покажет внешний IP)"
    echo -e "    ${BOLD}config${RESET}    — открыть sockd.conf в \$EDITOR"
    echo -e ""
    echo -e "  ${CYAN}Переменные окружения:${RESET}"
    echo -e "    PROXY_PORT=1080    — порт на хосте (по умолчанию 1080)"
    echo -e "    EDITOR=nano        — редактор для команды config"
    echo -e ""
    echo -e "  ${CYAN}Быстрый старт:${RESET}"
    echo -e "    chmod +x $0 && $0 start"
    echo -e ""
}

# ── Точка входа ───────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

case "${1:-}" in
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    restart) cmd_restart ;;
    status)  cmd_status  ;;
    logs)    cmd_logs    ;;
    test)    cmd_test    ;;
    config)  cmd_config  ;;
    *)       usage; exit 1 ;;
esac
