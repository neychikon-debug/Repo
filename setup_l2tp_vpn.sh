#!/usr/bin/env bash
# =============================================================================
#  L2TP/IPsec VPN Server — Auto Setup Script
#  Поддерживаемые ОС: Ubuntu 20.04/22.04/24.04, Debian 10/11/12
#  Запуск: sudo bash setup_l2tp_vpn.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Вспомогательные функции ──────────────────────────────────────────────────
log()     { echo -e "${CYAN}[*]${RESET} $*"; }
success() { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}${CYAN}  $*${RESET}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

# ─── Проверка прав ────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Скрипт необходимо запустить от root: sudo bash $0"

# ─── Определение ОС ───────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID}"
        OS_VER="${VERSION_ID}"
    else
        error "Не удалось определить операционную систему."
    fi

    case "$OS_ID" in
        ubuntu|debian) ;;
        *) error "Поддерживаются только Ubuntu и Debian. Текущая ОС: $OS_ID" ;;
    esac
    success "Обнаружена ОС: $PRETTY_NAME"
}

# ─── Определение внешнего IP ──────────────────────────────────────────────────
get_public_ip() {
    PUBLIC_IP=$(curl -4 -s --max-time 10 https://api.ipify.org \
             || curl -4 -s --max-time 10 https://ifconfig.me \
             || ip route get 1 | awk '{print $7; exit}')
    [[ -z "$PUBLIC_IP" ]] && error "Не удалось определить публичный IP-адрес."
    success "Публичный IP: $PUBLIC_IP"
}

# ─── Генерация случайных строк ────────────────────────────────────────────────
gen_secret() { head -c 512 /dev/urandom | tr -dc 'A-Za-z0-9@#$%^&*_+' | head -c "${1:-24}" || true; }


# ─── Запрос параметров у пользователя ────────────────────────────────────────
prompt_config() {
    section "Конфигурация VPN"

    # IPsec PSK
    DEFAULT_PSK=$(gen_secret 32)
    echo -e "${YELLOW}IPsec Pre-Shared Key${RESET} (Enter = случайный):"
    read -r -p "  PSK: " INPUT_PSK
    VPN_IPSEC_PSK="${INPUT_PSK:-$DEFAULT_PSK}"

    # Пользователь
    echo -e "\n${YELLOW}VPN-пользователь${RESET} (Enter = 'vpnuser'):"
    read -r -p "  Логин: " INPUT_USER
    VPN_USER="${INPUT_USER:-vpnuser}"

    # Пароль
    DEFAULT_PASS=$(gen_secret 20)
    echo -e "\n${YELLOW}Пароль для пользователя '$VPN_USER'${RESET} (Enter = случайный):"
    read -r -p "  Пароль: " INPUT_PASS
    VPN_PASSWORD="${INPUT_PASS:-$DEFAULT_PASS}"

    # IP-пул для клиентов
    echo -e "\n${YELLOW}Подсеть для VPN-клиентов${RESET} (Enter = 192.168.42.0/24):"
    read -r -p "  Подсеть: " INPUT_SUBNET
    VPN_SUBNET="${INPUT_SUBNET:-192.168.42.0/24}"
    VPN_LOCAL_IP=$(echo "$VPN_SUBNET" | sed 's|\.[0-9]*/.*|.1|')
    VPN_POOL_START=$(echo "$VPN_SUBNET" | sed 's|\.[0-9]*/.*|.10|')
    VPN_POOL_END=$(echo "$VPN_SUBNET" | sed 's|\.[0-9]*/.*|.200|')

    echo ""
    warn "Внимание: DNS-трафик клиентов будет перенаправляться через 8.8.8.8 и 1.1.1.1"
}

# ─── Установка пакетов ────────────────────────────────────────────────────────
install_packages() {
    section "Установка пакетов"
    log "Обновление индекса пакетов..."
    apt-get update -qq

    log "Установка: xl2tpd, strongswan, ppp, iptables-persistent..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        xl2tpd \
        strongswan \
        strongswan-pki \
        libstrongswan-standard-plugins \
        ppp \
        iptables-persistent \
        net-tools \
        curl \
        2>/dev/null
    success "Все пакеты установлены."
}

# ─── Определение сетевого интерфейса ─────────────────────────────────────────
detect_interface() {
    NET_IFACE=$(ip route get 1 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$NET_IFACE" ]] && NET_IFACE=$(ip -o link show | awk -F': ' '$2 !~ "lo" {print $2; exit}')
    success "Сетевой интерфейс: $NET_IFACE"
}

# ─── Конфигурация IPsec (strongSwan) ─────────────────────────────────────────
configure_ipsec() {
    section "Настройка IPsec / strongSwan"

    # Резервная копия оригинального конфига
    [[ -f /etc/ipsec.conf ]] && cp /etc/ipsec.conf /etc/ipsec.conf.bak.$(date +%s)

    cat > /etc/ipsec.conf <<EOF
# Сгенерировано setup_l2tp_vpn.sh — $(date)
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no

conn %default
    ikelifetime=60m
    keylife=20m
    rekeymargin=3m
    keyingtries=1
    keyexchange=ikev1
    authby=secret

conn L2TP-PSK-NAT
    rightsubnet=vhost:%priv
    also=L2TP-PSK-noNAT

conn L2TP-PSK-noNAT
    authby=secret
    auto=add
    keyingtries=3
    rekey=no
    ikelifetime=8h
    keylife=1h
    type=transport
    left=%defaultroute
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    dpddelay=30
    dpdtimeout=120
    dpdaction=clear
EOF

    # IPsec PSK
    cat > /etc/ipsec.secrets <<EOF
# Сгенерировано setup_l2tp_vpn.sh — $(date)
%any %any : PSK "${VPN_IPSEC_PSK}"
EOF

    chmod 600 /etc/ipsec.secrets
    success "IPsec настроен."
}

# ─── Конфигурация xl2tpd ──────────────────────────────────────────────────────
configure_xl2tpd() {
    section "Настройка xl2tpd (L2TP)"

    mkdir -p /etc/xl2tpd

    cat > /etc/xl2tpd/xl2tpd.conf <<EOF
; Сгенерировано setup_l2tp_vpn.sh — $(date)
[global]
ipsec saref = yes
saref refinfo = 30

[lns default]
ip range = ${VPN_POOL_START}-${VPN_POOL_END}
local ip = ${VPN_LOCAL_IP}
require chap = yes
refuse pap = yes
require authentication = yes
name = L2TP-VPN
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

    success "xl2tpd настроен."
}

# ─── Конфигурация PPP ─────────────────────────────────────────────────────────
configure_ppp() {
    section "Настройка PPP"

    cat > /etc/ppp/options.xl2tpd <<EOF
# Сгенерировано setup_l2tp_vpn.sh — $(date)
ipcp-accept-local
ipcp-accept-remote
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 1.1.1.1
asyncmap 0
auth
crtscts
lock
hide-password
modem
debug
name L2TP-VPN
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
mtu 1400
mru 1400
connect-delay 5000
EOF

    # Добавляем/обновляем пользователя в /etc/ppp/chap-secrets
    # Формат: username  server  password  IP-addresses
    if grep -qE "^\"?${VPN_USER}\"?" /etc/ppp/chap-secrets 2>/dev/null; then
        # Заменяем существующую запись
        sed -i "/^\"\\?${VPN_USER}\"\\?/d" /etc/ppp/chap-secrets
        warn "Пользователь '${VPN_USER}' уже существовал — перезаписан."
    fi

    echo "\"${VPN_USER}\"  L2TP-VPN  \"${VPN_PASSWORD}\"  *" >> /etc/ppp/chap-secrets
    chmod 600 /etc/ppp/chap-secrets
    success "PPP настроен. Пользователь '${VPN_USER}' добавлен."
}

# ─── Настройка ядра (IP forwarding) ──────────────────────────────────────────
configure_kernel() {
    section "Настройка параметров ядра"

    SYSCTL_CONF="/etc/sysctl.d/99-vpn-l2tp.conf"
    cat > "$SYSCTL_CONF" <<EOF
# VPN L2TP/IPsec — setup_l2tp_vpn.sh
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.${NET_IFACE}.accept_redirects = 0
net.ipv4.conf.${NET_IFACE}.send_redirects = 0
net.ipv4.conf.${NET_IFACE}.rp_filter = 0
EOF

    sysctl -q -p "$SYSCTL_CONF"
    success "IP-форвардинг и параметры ядра применены."
}

# ─── Настройка iptables / NAT ─────────────────────────────────────────────────
configure_iptables() {
    section "Настройка iptables / NAT"

    # Сбрасываем старые правила для чистоты
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F

    # Базовая политика
    iptables -P INPUT   ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT  ACCEPT

    # Разрешаем установленные соединения
    iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Loopback
    iptables -A INPUT -i lo -j ACCEPT

    # SSH (защита от самоизоляции)
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW -j ACCEPT

    # IPsec / L2TP порты
    iptables -A INPUT -p udp --dport 500  -j ACCEPT   # IKE
    iptables -A INPUT -p udp --dport 4500 -j ACCEPT   # NAT-T
    iptables -A INPUT -p udp --dport 1701 -j ACCEPT   # L2TP
    iptables -A INPUT -p 50  -j ACCEPT                # ESP
    iptables -A INPUT -p 51  -j ACCEPT                # AH

    # NAT — маскируем трафик VPN-клиентов
    iptables -t nat -A POSTROUTING -s "${VPN_SUBNET}" -o "${NET_IFACE}" -j MASQUERADE

    # Forward для VPN-подсети
    iptables -A FORWARD -s "${VPN_SUBNET}" -j ACCEPT
    iptables -A FORWARD -d "${VPN_SUBNET}" -j ACCEPT

    # Сохраняем правила
    netfilter-persistent save >/dev/null 2>&1
    success "iptables настроены и сохранены."
}

# ─── Запуск и включение служб ────────────────────────────────────────────────
start_services() {
    section "Запуск служб"

    for svc in strongswan-starter xl2tpd; do
        systemctl enable  "$svc" >/dev/null 2>&1 || true
        systemctl restart "$svc"
        if systemctl is-active --quiet "$svc"; then
            success "Служба '$svc' запущена."
        else
            warn "Служба '$svc' не запустилась. Проверьте: journalctl -u $svc"
        fi
    done
}

# ─── Вывод итоговой информации ────────────────────────────────────────────────
print_summary() {
    section "Готово! Данные для подключения"

    echo ""
    echo -e "  ${BOLD}Тип VPN:${RESET}       L2TP/IPsec с PSK"
    echo -e "  ${BOLD}Сервер:${RESET}        ${GREEN}${PUBLIC_IP}${RESET}"
    echo -e "  ${BOLD}IPsec PSK:${RESET}     ${GREEN}${VPN_IPSEC_PSK}${RESET}"
    echo -e "  ${BOLD}Пользователь:${RESET}  ${GREEN}${VPN_USER}${RESET}"
    echo -e "  ${BOLD}Пароль:${RESET}        ${GREEN}${VPN_PASSWORD}${RESET}"
    echo ""
    echo -e "  ${YELLOW}Порты (открой в файрволе/облаке если нужно):${RESET}"
    echo -e "    UDP 500   (IKE)"
    echo -e "    UDP 4500  (NAT Traversal)"
    echo -e "    UDP 1701  (L2TP)"
    echo -e "    Протоколы ESP (50) и AH (51)"
    echo ""
    echo -e "  ${YELLOW}Управление пользователями:${RESET}"
    echo -e "    Добавить пользователя: edit /etc/ppp/chap-secrets"
    echo -e "    Формат строки: \"user\"  L2TP-VPN  \"password\"  *"
    echo ""
    echo -e "  ${YELLOW}Полезные команды:${RESET}"
    echo -e "    Статус IPsec:   ${CYAN}ipsec statusall${RESET}"
    echo -e "    Статус L2TP:    ${CYAN}systemctl status xl2tpd${RESET}"
    echo -e "    Логи IPsec:     ${CYAN}journalctl -u strongswan-starter -f${RESET}"
    echo -e "    Логи L2TP:      ${CYAN}journalctl -u xl2tpd -f${RESET}"
    echo ""

    # Сохраняем credentials в файл
    CRED_FILE="/root/vpn-credentials.txt"
    cat > "$CRED_FILE" <<EOF
=== L2TP/IPsec VPN Credentials ($(date)) ===
Server IP:    ${PUBLIC_IP}
IPsec PSK:    ${VPN_IPSEC_PSK}
Username:     ${VPN_USER}
Password:     ${VPN_PASSWORD}
VPN Subnet:   ${VPN_SUBNET}
EOF
    chmod 600 "$CRED_FILE"
    success "Credentials сохранены в ${CRED_FILE} (chmod 600)"
}

# ─── Точка входа ──────────────────────────────────────────────────────────────
main() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ██╗     ██████╗ ████████╗██████╗     ██╗   ██╗██████╗ ███╗   ██╗"
    echo "  ██║     ╚════██╗╚══██╔══╝██╔══██╗    ██║   ██║██╔══██╗████╗  ██║"
    echo "  ██║      █████╔╝   ██║   ██████╔╝    ██║   ██║██████╔╝██╔██╗ ██║"
    echo "  ██║     ██╔═══╝    ██║   ██╔═══╝     ╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║"
    echo "  ███████╗███████╗   ██║   ██║          ╚████╔╝ ██║     ██║ ╚████║"
    echo "  ╚══════╝╚══════╝   ╚═╝   ╚═╝           ╚═══╝  ╚═╝     ╚═╝  ╚═══╝"
    echo -e "${RESET}"
    echo -e "  ${BOLD}L2TP/IPsec VPN Server Setup${RESET}  |  Ubuntu/Debian"
    echo ""

    detect_os
    get_public_ip
    prompt_config
    install_packages
    detect_interface
    configure_ipsec
    configure_xl2tpd
    configure_ppp
    configure_kernel
    configure_iptables
    start_services
    print_summary
}

main "$@"

