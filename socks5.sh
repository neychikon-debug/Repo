#!/usr/bin/env bash
# =============================================================================
#  socks5.sh — SOCKS5 прокси с аутентификацией (Dante in Docker)
#
#  При первом запуске создаёт рядом с собой Dockerfile и sockd.conf
#
#  Команды:
#    ./socks5.sh start              — создать файлы, собрать образ, запустить
#    ./socks5.sh stop               — остановить и удалить контейнер
#    ./socks5.sh restart            — перечитать sockd.conf, пересобрать, запустить
#    ./socks5.sh status             — статус контейнера + список юзеров
#    ./socks5.sh logs               — live tail логов
#    ./socks5.sh test [user] [pass] — проверить прокси (с/без авторизации)
#    ./socks5.sh config             — открыть sockd.conf в $EDITOR
#    ./socks5.sh user-add <user>    — добавить пользователя (спросит пароль)
#    ./socks5.sh user-del <user>    — удалить пользователя
#    ./socks5.sh user-list          — список всех пользователей прокси
#    ./socks5.sh user-passwd <user> — сменить пароль пользователя
#
#  Переменные окружения:
#    PROXY_PORT=1080   — порт на хосте (по умолчанию 1080)
#    BIND_ADDR=0.0.0.0 — адрес биндинга (0.0.0.0 = доступен снаружи)
# =============================================================================

set -euo pipefail

# ── Конфигурация ──────────────────────────────────────────────────────────────
CONTAINER_NAME="socks5-proxy"
IMAGE_NAME="socks5-dante"
PROXY_PORT="${PROXY_PORT:-1080}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"
SOCKD_CONF="$SCRIPT_DIR/sockd.conf"
USERS_FILE="$SCRIPT_DIR/.socks5_users"   # хранит логины (пароли — в контейнере)
# ─────────────────────────────────────────────────────────────────────────────

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

RUN apk add --no-cache dante-server shadow

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
# Dante SOCKS5 — конфиг с аутентификацией по логин/паролю
# После изменений: ./socks5.sh restart
# ============================================================

internal: 0.0.0.0 port = 1080
external: eth0

# Аутентификация клиента — без пароля на уровне TCP
clientmethod: none

# Аутентификация SOCKS5 — по логину/паролю
socksmethod: username

user.privileged:    root
user.notprivileged: nobody

# Разрешаем подключения от всех клиентов
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

# Разрешаем SOCKS5 только авторизованным
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: connect disconnect error
    socksmethod: username
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
    [[ ! -f "$USERS_FILE" ]] && touch "$USERS_FILE" && chmod 600 "$USERS_FILE"
    if [[ $created -eq 1 ]]; then
        divider
        warn "Файлы созданы. Добавь пользователя: ${BOLD}$0 user-add <имя>${RESET}"
        divider
    fi
}

# ── Проверки ──────────────────────────────────────────────────────────────────
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
    log "Запуск контейнера ${BOLD}${CONTAINER_NAME}${RESET} → ${BIND_ADDR}:${PROXY_PORT} ..."
    docker run -d \
        --name    "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p        "${BIND_ADDR}:${PROXY_PORT}:1080/tcp" \
        -p        "${BIND_ADDR}:${PROXY_PORT}:1080/udp" \
        --cap-add NET_BIND_SERVICE \
        -v        "${SOCKD_CONF}:/etc/sockd.conf:ro" \
        "$IMAGE_NAME"
    ok "Контейнер запущен → SOCKS5 доступен на ${BIND_ADDR}:${PROXY_PORT}"

    # Восстанавливаем всех пользователей из файла
    _restore_users_in_container
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

# ── Управление пользователями ─────────────────────────────────────────────────

# Сохраняем пароль в файл (зашифрован через openssl)
_save_user_passwd() {
    local username="$1" password="$2"
    # Хранить пароль в открытом виде небезопасно, но нужно для restore после restart.
    # Файл доступен только root (chmod 600).
    local encoded
    encoded=$(echo "$password" | openssl enc -aes-256-cbc -pbkdf2 -pass pass:"${CONTAINER_NAME}" -base64 2>/dev/null)
    # Удаляем старую запись если есть
    sed -i "/^${username}:/d" "$USERS_FILE" 2>/dev/null || true
    echo "${username}:${encoded}" >> "$USERS_FILE"
}

_get_user_passwd() {
    local username="$1"
    local encoded
    encoded=$(grep "^${username}:" "$USERS_FILE" 2>/dev/null | cut -d: -f2-)
    [[ -z "$encoded" ]] && return 1
    echo "$encoded" | openssl enc -aes-256-cbc -pbkdf2 -d -pass pass:"${CONTAINER_NAME}" -base64 2>/dev/null
}

# Добавить юзера в запущенный контейнер
_add_user_to_container() {
    local username="$1" password="$2"
    docker exec "$CONTAINER_NAME" sh -c "
        id '$username' &>/dev/null && userdel '$username' 2>/dev/null || true
        adduser -D -H -s /sbin/nologin '$username'
        echo '${username}:${password}' | chpasswd
    " 2>/dev/null
}

# Восстановить всех юзеров после рестарта контейнера
_restore_users_in_container() {
    [[ ! -f "$USERS_FILE" ]] && return
    local count=0
    while IFS=: read -r username _; do
        [[ -z "$username" ]] && continue
        local password
        password=$(_get_user_passwd "$username") || continue
        _add_user_to_container "$username" "$password"
        (( count++ )) || true
    done < "$USERS_FILE"
    [[ $count -gt 0 ]] && ok "Восстановлено пользователей в контейнере: ${count}"
}

cmd_user_add() {
    check_deps
    local username="${1:-}"
    [[ -z "$username" ]] && die "Укажи имя пользователя: $0 user-add <имя>"

    # Проверка допустимых символов
    [[ "$username" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Имя пользователя: только латиница, цифры, _ и -"

    local password password2
    read -rsp "$(echo -e "${CYAN}Пароль для ${BOLD}${username}${RESET}${CYAN}:${RESET} ")" password; echo
    [[ ${#password} -lt 6 ]] && die "Пароль должен быть минимум 6 символов"
    read -rsp "$(echo -e "${CYAN}Повтори пароль:${RESET} ")" password2; echo
    [[ "$password" != "$password2" ]] && die "Пароли не совпадают"

    # Сохраняем в файл
    _save_user_passwd "$username" "$password"
    ok "Пользователь ${BOLD}${username}${RESET} сохранён"

    # Добавляем в контейнер если запущен
    if container_running; then
        _add_user_to_container "$username" "$password"
        ok "Пользователь ${BOLD}${username}${RESET} добавлен в контейнер"
    else
        warn "Контейнер не запущен — пользователь будет добавлен при следующем start/restart"
    fi
}

cmd_user_del() {
    local username="${1:-}"
    [[ -z "$username" ]] && die "Укажи имя пользователя: $0 user-del <имя>"

    # Удаляем из файла
    sed -i "/^${username}:/d" "$USERS_FILE" 2>/dev/null || true
    ok "Пользователь ${BOLD}${username}${RESET} удалён из списка"

    # Удаляем из контейнера если запущен
    if container_running; then
        docker exec "$CONTAINER_NAME" sh -c "
            id '$username' &>/dev/null && deluser '$username' || true
        " 2>/dev/null
        ok "Пользователь ${BOLD}${username}${RESET} удалён из контейнера"
    fi
}

cmd_user_passwd() {
    check_deps
    local username="${1:-}"
    [[ -z "$username" ]] && die "Укажи имя пользователя: $0 user-passwd <имя>"
    grep -q "^${username}:" "$USERS_FILE" 2>/dev/null || die "Пользователь '${username}' не найден"

    local password password2
    read -rsp "$(echo -e "${CYAN}Новый пароль для ${BOLD}${username}${RESET}${CYAN}:${RESET} ")" password; echo
    [[ ${#password} -lt 6 ]] && die "Пароль должен быть минимум 6 символов"
    read -rsp "$(echo -e "${CYAN}Повтори пароль:${RESET} ")" password2; echo
    [[ "$password" != "$password2" ]] && die "Пароли не совпадают"

    _save_user_passwd "$username" "$password"
    ok "Пароль обновлён в файле"

    if container_running; then
        _add_user_to_container "$username" "$password"
        ok "Пароль обновлён в контейнере (без рестарта)"
    fi
}

cmd_user_list() {
    divider
    if [[ ! -f "$USERS_FILE" ]] || [[ ! -s "$USERS_FILE" ]]; then
        warn "Нет пользователей. Добавь: ${BOLD}$0 user-add <имя>${RESET}"
        divider
        return
    fi
    echo -e "  ${BOLD}Пользователи прокси:${RESET}"
    while IFS=: read -r username _; do
        [[ -z "$username" ]] && continue
        if container_running; then
            # Проверяем есть ли юзер в контейнере
            if docker exec "$CONTAINER_NAME" id "$username" &>/dev/null 2>&1; then
                echo -e "    ${GREEN}●${RESET} ${username} ${GREEN}(активен)${RESET}"
            else
                echo -e "    ${YELLOW}●${RESET} ${username} ${YELLOW}(не в контейнере)${RESET}"
            fi
        else
            echo -e "    ${CYAN}●${RESET} ${username}"
        fi
    done < "$USERS_FILE"
    divider
}

# ── Основные команды ──────────────────────────────────────────────────────────
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
    [[ -f "$SOCKD_CONF" ]] || die "sockd.conf не найден — запусти сначала: $0 start"
    log "Перезапуск — перечитываю ${BOLD}sockd.conf${RESET} + восстанавливаю юзеров ..."
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
    echo -e "  Port:    ${BIND_ADDR}:${PROXY_PORT}"
    divider
    cmd_user_list
}

cmd_logs() {
    check_deps
    container_exists || die "Контейнер ${CONTAINER_NAME} не найден"
    log "Логи (Ctrl+C для выхода) ..."
    docker logs -f --tail 50 "$CONTAINER_NAME"
}

cmd_test() {
    check_deps
    command -v curl &>/dev/null || die "curl не установлен"

    local user="${1:-}" pass="${2:-}"
    local proxy_url

    if [[ -n "$user" && -n "$pass" ]]; then
        proxy_url="socks5h://${user}:${pass}@127.0.0.1:${PROXY_PORT}"
        log "Тест с аутентификацией (${BOLD}${user}${RESET}) ..."
    else
        proxy_url="socks5h://127.0.0.1:${PROXY_PORT}"
        log "Тест без аутентификации ..."
    fi

    RESULT=$(curl -s --max-time 10 \
        --proxy "$proxy_url" \
        "https://api.ipify.org?format=json" 2>&1) || true

    if echo "$RESULT" | grep -q '"ip"'; then
        EXTERNAL_IP=$(echo "$RESULT" | grep -oP '"ip":"\K[^"]+')
        ok "Прокси работает! Внешний IP: ${BOLD}${EXTERNAL_IP}${RESET}"
    else
        err "Прокси не отвечает или ошибка авторизации."
        err "Ответ: $RESULT"
        exit 1
    fi
}

cmd_config() {
    [[ -f "$SOCKD_CONF" ]] || die "sockd.conf не найден — запусти сначала: $0 start"
    local editor="${EDITOR:-vi}"
    "$editor" "$SOCKD_CONF"
    log "После изменений запусти: ${BOLD}$0 restart${RESET}"
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    echo -e ""
    echo -e "${BOLD}  SOCKS5 Proxy Manager${RESET} — Dante in Docker (with auth)"
    echo -e ""
    echo -e "  ${CYAN}Команды:${RESET}"
    echo -e "    ${BOLD}start${RESET}                — собрать образ и запустить"
    echo -e "    ${BOLD}stop${RESET}                 — остановить и удалить контейнер"
    echo -e "    ${BOLD}restart${RESET}              — перечитать конфиг, перезапустить"
    echo -e "    ${BOLD}status${RESET}               — статус + список юзеров"
    echo -e "    ${BOLD}logs${RESET}                 — live tail логов"
    echo -e "    ${BOLD}test [user] [pass]${RESET}   — проверить прокси"
    echo -e "    ${BOLD}config${RESET}               — открыть sockd.conf в \$EDITOR"
    echo -e "    ${BOLD}user-add <user>${RESET}      — добавить пользователя"
    echo -e "    ${BOLD}user-del <user>${RESET}      — удалить пользователя"
    echo -e "    ${BOLD}user-passwd <user>${RESET}   — сменить пароль"
    echo -e "    ${BOLD}user-list${RESET}            — список пользователей"
    echo -e ""
    echo -e "  ${CYAN}Переменные окружения:${RESET}"
    echo -e "    PROXY_PORT=1080     — порт на хосте"
    echo -e "    BIND_ADDR=0.0.0.0  — адрес биндинга (0.0.0.0 = снаружи)"
    echo -e ""
    echo -e "  ${CYAN}Быстрый старт:${RESET}"
    echo -e "    chmod +x $0"
    echo -e "    $0 start"
    echo -e "    $0 user-add myphone"
    echo -e "    $0 test myphone mypassword"
    echo -e ""
}

# ── Точка входа ───────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

case "${1:-}" in
    start)       cmd_start              ;;
    stop)        cmd_stop               ;;
    restart)     cmd_restart            ;;
    status)      cmd_status             ;;
    logs)        cmd_logs               ;;
    test)        cmd_test "${2:-}" "${3:-}" ;;
    config)      cmd_config             ;;
    user-add)    cmd_user_add    "${2:-}" ;;
    user-del)    cmd_user_del    "${2:-}" ;;
    user-passwd) cmd_user_passwd "${2:-}" ;;
    user-list)   cmd_user_list          ;;
    *)           usage; exit 1          ;;
esac
