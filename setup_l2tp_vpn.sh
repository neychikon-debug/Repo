cat > /root/setup_l2tp_vpn.sh << 'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${CYAN}[*]${RESET} $*"; }
success() { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
            echo -e "${BOLD}${CYAN}  $*${RESET}"
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

[[ $EUID -ne 0 ]] && error "Запусти от root: sudo bash $0"

gen_secret() {
    local len="${1:-24}"
    local result=""
    while [[ ${#result} -lt $len ]]; do
        result+=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9@#%^*_+' 2>/dev/null)
    done
    echo "${result:0:$len}"
}

detect_os() {
    [[ -f /etc/os-release ]] || error "Не удалось определить ОС."
    source /etc/os-release
    OS_ID="${ID}"; OS_VER="${VERSION_ID}"
    case "$OS_ID" in ubuntu|debian) ;; *) error "Только Ubuntu/Debian. ОС: $OS_ID" ;; esac
    success "Обнаружена ОС: $PRETTY_NAME"
}

get_public_ip() {
    PUBLIC_IP=$(curl -4 -s --max-time 10 https://api.ipify.org 2>/dev/null || \
                curl -4 -s --max-time 10 https://ifconfig.me 2>/dev/null || \
                ip route get 1 | awk '{print $7; exit}')
    [[ -z "$PUBLIC_IP" ]] && error "Не удалось определить публичный IP."
    success "Публичный IP: $PUBLIC_IP"
}

prompt_config() {
    section "Конфигурация VPN"

    DEFAULT_PSK=$(gen_secret 32)
    echo -e "${YELLOW}IPsec Pre-Shared Key${RESET} (Enter = случайный):"
    read -r -p "  PSK: " INPUT_PSK
    VPN_IPSEC_PSK="${INPUT_PSK:-$DEFAULT_PSK}"

    echo -e "\n${YELLOW}VPN-пользователь${RESET} (Enter = 'vpnuser'):"
    read -r -p "  Логин: " INPUT_USER
    VPN_USER="${INPUT_USER:-vpnuser}"

    DEFAULT_PASS=$(gen_secret 20)
    echo -e "\n${YELLOW}Пароль${RESET} (Enter = случайный):"
    read -r -p "  Пароль: " INPUT_PASS
    VPN_PASSWORD="${INPUT_PASS:-$DEFAULT_PASS}"

    echo -e "\n${YELLOW}Подсеть для клиентов${RESET} (Enter = 192.168.42.0/24):"
    read -r -p "  Подсеть: " INPUT_SUBNET
    VPN_SUBNET="${INPUT_SUBNET:-192.168.42.0/24}"
    VPN_LOCAL_IP=$(echo "$VPN_SUBNET" | sed 's|\.[0-9]*/.*|.1|')
    VPN_POOL_START=$(echo "$VPN_SUBNET" | sed 's|\.[0-9]*/.*|.10|')
    VPN_POOL_END=$(echo "$VPN_SUBNET" | sed 's|\.[0-9]*/.*|.200|')

    echo ""
    warn "DNS клиентов → 8.8.8.8 и 1.1.1.1"
}

install_packages() {
    section "Установка пакетов"
    log "apt-get update..."
    apt-get update -qq
    log "Установка xl2tpd strongswan ppp iptables-persistent..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        xl2tpd strongswan strongswan-pki \
        libstrongswan-standard-plugins \
        ppp iptables-persistent net-tools curl
    success "Пакеты установлены."
}

detect_interface() {
    NET_IFACE=$(ip route get 1 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$NET_IFACE" ]] && NET_IFACE=$(ip -o link show | awk -F': ' '$2 !~ "lo" {print $2; exit}')
    success "Интерфейс: $NET_IFACE"
}

configure_ipsec() {
    section "Настройка IPsec / strongSwan"
    [[ -f /etc/ipsec.conf ]] && cp /etc/ipsec.conf /etc/ipsec.conf.bak.$(date +%s)
    cat > /etc/ipsec.conf <<EOF
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
    printf '%%any %%any : PSK "%s"\n' "$VPN_IPSEC_PSK" > /etc/ipsec.secrets
    chmod 600 /etc/ipsec.secrets
    success "IPsec настроен."
}

configure_xl2tpd() {
    section "Настройка xl2tpd"
    mkdir -p /etc/xl2tpd
    cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
ipsec saref = yes

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

configure_ppp() {
    section "Настройка PPP"
    cat > /etc/ppp/options.xl2tpd <<EOF
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
name L2TP-VPN
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
mtu 1400
mru 1400
connect-delay 5000
EOF
    if grep -qE "^\"?${VPN_USER}\"?" /etc/ppp/chap-secrets 2>/dev/null; then
        sed -i "/^\"\\?${VPN_USER}\"\\?/d" /etc/ppp/chap-secrets
        warn "Пользователь '${VPN_USER}' перезаписан."
    fi
    printf '"%s"  L2TP-VPN  "%s"  *\n' "$VPN_USER" "$VPN_PASSWORD" >> /etc/ppp/chap-secrets
    chmod 600 /etc/ppp/chap-secrets
    success "PPP настроен. Пользователь '${VPN_USER}' добавлен."
}

configure_kernel() {
    section "Параметры ядра"
    cat > /etc/sysctl.d/99-vpn-l2tp.conf <<EOF
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
    sysctl -q -p /etc/sysctl.d/99-vpn-l2tp.conf
    success "IP-форвардинг включён."
}

configure_iptables() {
    section "Настройка iptables / NAT"
    iptables -F; iptables -t nat -F; iptables -t mangle -F
    iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
    iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT  -i lo -j ACCEPT
    iptables -A INPUT  -p tcp --dport 22 -m state --state NEW -j ACCEPT
    iptables -A INPUT  -p udp --dport 500  -j ACCEPT
    iptables -A INPUT  -p udp --dport 4500 -j ACCEPT
    iptables -A INPUT  -p udp --dport 1701 -j ACCEPT
    iptables -A INPUT  -p 50 -j ACCEPT
    iptables -A INPUT  -p 51 -j ACCEPT
    iptables -t nat -A POSTROUTING -s "${VPN_SUBNET}" -o "${NET_IFACE}" -j MASQUERADE
    iptables -A FORWARD -s "${VPN_SUBNET}" -j ACCEPT
    iptables -A FORWARD -d "${VPN_SUBNET}" -j ACCEPT
    netfilter-persistent save >/dev/null 2>&1
    success "iptables настроены."
}

start_services() {
    section "Запуск служб"
    for svc in strongswan-starter xl2tpd; do
        systemctl enable  "$svc" >/dev/null 2>&1 || true
        systemctl restart "$svc"
        if systemctl is-active --quiet "$svc"; then
            success "Служба '$svc' запущена."
        else
            warn "'$svc' не запустилась. Проверь: journalctl -u $svc"
        fi
    done
}

print_summary() {
    section "Готово! Данные для подключения"
    echo ""
    echo -e "  ${BOLD}Тип VPN:${RESET}       L2TP/IPsec с PSK"
    echo -e "  ${BOLD}Сервер:${RESET}        ${GREEN}${PUBLIC_IP}${RESET}"
    echo -e "  ${BOLD}IPsec PSK:${RESET}     ${GREEN}${VPN_IPSEC_PSK}${RESET}"
    echo -e "  ${BOLD}Пользователь:${RESET}  ${GREEN}${VPN_USER}${RESET}"
    echo -e "  ${BOLD}Пароль:${RESET}        ${GREEN}${VPN_PASSWORD}${RESET}"
    echo ""
    echo -e "  ${YELLOW}Порты:${RESET} UDP 500, UDP 4500, UDP 1701, ESP(50), AH(51)"
    echo ""

    CRED_FILE="/root/vpn-credentials.txt"
    cat > "$CRED_FILE" <<EOF
=== L2TP/IPsec VPN ($(date)) ===
Server:   ${PUBLIC_IP}
PSK:      ${VPN_IPSEC_PSK}
User:     ${VPN_USER}
Password: ${VPN_PASSWORD}
Subnet:   ${VPN_SUBNET}
EOF
    chmod 600 "$CRED_FILE"
    success "Credentials → ${CRED_FILE}"
}

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
SCRIPT

chmod +x /root/setup_l2tp_vpn.sh && bash /root/setup_l2tp_vpn.sh
