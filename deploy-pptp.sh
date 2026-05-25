#!/usr/bin/env bash
# =============================================================================
#  PPTP VPN Server — Auto-deployment for Debian / Ubuntu
#  Tested on: Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()   { echo -e "${GREEN}[✔]${RESET} $*"; }
info()  { echo -e "${CYAN}[•]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
error() { echo -e "${RED}[✘]${RESET} $*" >&2; exit 1; }
banner(){
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║          PPTP VPN Server — Deployer              ║"
  echo "║      Debian / Ubuntu  •  Auto-Setup Script       ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

# ─── Root check ──────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Запустите скрипт с правами root: sudo $0"

# ─── Defaults ────────────────────────────────────────────────────────────────
VPN_USER="${VPN_USER:-vpnuser}"
VPN_PASS="${VPN_PASS:-}"                      # будет сгенерирован если пусто
LOCAL_IP="192.168.240.1"
REMOTE_IP_RANGE="192.168.240.10-50"
DNS1="8.8.8.8"
DNS2="1.1.1.1"
PPTPD_CONF="/etc/pptpd.conf"
PPTPD_OPT="/etc/ppp/pptpd-options"
CHAP_SECRETS="/etc/ppp/chap-secrets"
SYSCTL_CONF="/etc/sysctl.d/99-pptp-vpn.conf"

# ─── Parse args ──────────────────────────────────────────────────────────────
usage(){
  echo -e "Использование: $0 [OPTIONS]"
  echo -e "  -u <user>    Имя VPN-пользователя  (по умолч.: ${VPN_USER})"
  echo -e "  -p <pass>    Пароль VPN             (по умолч.: генерируется)"
  echo -e "  -d <dns>     Основной DNS           (по умолч.: ${DNS1})"
  echo -e "  -h           Справка"
  exit 0
}

while getopts ":u:p:d:h" opt; do
  case $opt in
    u) VPN_USER="$OPTARG" ;;
    p) VPN_PASS="$OPTARG" ;;
    d) DNS1="$OPTARG" ;;
    h) usage ;;
    *) error "Неизвестный флаг -${OPTARG}. Используйте -h для справки." ;;
  esac
done

# ─── Detect public IP ────────────────────────────────────────────────────────
detect_public_ip(){
  local ip
  ip=$(curl -4fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
    || curl -4fsSL --max-time 5 https://api4.my-ip.io/ip 2>/dev/null \
    || ip route get 1.1.1.1 | awk '{print $7; exit}')
  echo "$ip"
}

# ─── Detect default network interface ───────────────────────────────────────
detect_iface(){
  ip route | awk '/^default/{print $5; exit}'
}

# ─── Generate password ───────────────────────────────────────────────────────
gen_pass(){
  tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom | head -c 20
}

# ─── OS compatibility check ──────────────────────────────────────────────────
check_os(){
  if [[ ! -f /etc/os-release ]]; then
    error "Не удалось определить ОС"
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID}" in
    ubuntu|debian|raspbian) ;;
    *) warn "Протестировано только на Ubuntu/Debian. Продолжаем на свой страх и риск." ;;
  esac
}

# ─── Install pptpd ───────────────────────────────────────────────────────────
install_pptpd(){
  info "Обновление индекса пакетов..."
  apt-get update -qq

  info "Установка pptpd и iptables..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    pptpd iptables iptables-persistent curl net-tools \
    2>/dev/null
  log "pptpd установлен"
}

# ─── Configure pptpd.conf ────────────────────────────────────────────────────
configure_pptpd(){
  info "Настройка ${PPTPD_CONF}..."
  cat > "${PPTPD_CONF}" <<EOF
# pptpd.conf — управляется deploy-pptp.sh
option ${PPTPD_OPT}
localip ${LOCAL_IP}
remoteip ${REMOTE_IP_RANGE}
EOF
  log "pptpd.conf записан"
}

# ─── Configure PPP options ───────────────────────────────────────────────────
configure_ppp_options(){
  info "Настройка PPP-опций ${PPTPD_OPT}..."
  cat > "${PPTPD_OPT}" <<EOF
# pptpd-options — управляется deploy-pptp.sh
name pptpd
refuse-pap
refuse-chap
refuse-mschap
require-mschap-v2
require-mppe-128
ms-dns ${DNS1}
ms-dns ${DNS2}
proxyarp
lock
nobsdcomp
novj
novjccomp
nologfd
EOF
  log "PPP-опции записаны"
}

# ─── Add VPN user ────────────────────────────────────────────────────────────
add_vpn_user(){
  info "Добавление пользователя '${VPN_USER}'..."

  # Удаляем старую запись если есть
  sed -i "/^${VPN_USER}\s/d" "${CHAP_SECRETS}" 2>/dev/null || true

  echo "${VPN_USER}  pptpd  ${VPN_PASS}  *" >> "${CHAP_SECRETS}"
  chmod 600 "${CHAP_SECRETS}"
  log "Пользователь добавлен"
}

# ─── Enable IP forwarding ─────────────────────────────────────────────────────
enable_ip_forwarding(){
  info "Включение IP-forwarding..."
  cat > "${SYSCTL_CONF}" <<EOF
# Включено deploy-pptp.sh
net.ipv4.ip_forward = 1
net.ipv4.tcp_syncookies = 1
EOF
  sysctl -p "${SYSCTL_CONF}" >/dev/null
  log "IP-forwarding активен"
}

# ─── Configure iptables / NAT ─────────────────────────────────────────────────
configure_iptables(){
  local iface
  iface=$(detect_iface)
  info "Настройка NAT на интерфейсе ${iface}..."

  # Сбрасываем дублирующие правила если есть
  iptables -t nat -D POSTROUTING -s "${LOCAL_IP%.*}.0/24" \
    -o "${iface}" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -p tcp --syn -s "${LOCAL_IP%.*}.0/24" \
    -j TCPMSS --set-mss 1356 2>/dev/null || true

  # Добавляем правила
  iptables -t nat -A POSTROUTING -s "${LOCAL_IP%.*}.0/24" \
    -o "${iface}" -j MASQUERADE
  iptables -A FORWARD -p tcp --syn -s "${LOCAL_IP%.*}.0/24" \
    -j TCPMSS --set-mss 1356

  # Сохраняем
  netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4
  log "NAT настроен (интерфейс: ${iface})"
}

# ─── Firewall: open PPTP port ─────────────────────────────────────────────────
open_firewall(){
  info "Открытие порта 1723/TCP и GRE..."
  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 1723/tcp  >/dev/null
    ufw allow proto gre >/dev/null
    log "UFW: порт 1723 и GRE разрешены"
  else
    iptables -I INPUT -p tcp --dport 1723 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p gre -j ACCEPT             2>/dev/null || true
    log "iptables: порт 1723 и GRE разрешены"
  fi
}

# ─── Start & enable service ───────────────────────────────────────────────────
enable_service(){
  info "Запуск и активация pptpd..."
  systemctl enable pptpd >/dev/null 2>&1
  systemctl restart pptpd
  sleep 1
  if systemctl is-active --quiet pptpd; then
    log "pptpd запущен и работает"
  else
    error "pptpd не запустился. Проверьте: journalctl -u pptpd -n 50"
  fi
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary(){
  local pub_ip
  pub_ip=$(detect_public_ip)
  echo
  echo -e "${BOLD}${GREEN}══════════════ PPTP VPN ГОТОВ ════════════════${RESET}"
  echo -e "  ${BOLD}Сервер (публичный IP):${RESET}  ${pub_ip}"
  echo -e "  ${BOLD}Тип VPN:${RESET}               PPTP / MPPE-128"
  echo -e "  ${BOLD}Пользователь:${RESET}          ${VPN_USER}"
  echo -e "  ${BOLD}Пароль:${RESET}                ${VPN_PASS}"
  echo -e "  ${BOLD}DNS:${RESET}                   ${DNS1}  /  ${DNS2}"
  echo -e "  ${BOLD}Пул адресов клиентов:${RESET}  ${REMOTE_IP_RANGE}"
  echo -e "${BOLD}${GREEN}══════════════════════════════════════════════${RESET}"
  echo
  echo -e "${YELLOW}⚠  PPTP считается устаревшим протоколом.${RESET}"
  echo -e "${YELLOW}   Для продакшена рекомендуйте WireGuard или OpenVPN.${RESET}"
  echo
  echo -e "  Управление сервисом:"
  echo -e "    systemctl status  pptpd"
  echo -e "    systemctl restart pptpd"
  echo -e "    journalctl -u pptpd -f"
  echo
  echo -e "  Добавить пользователя вручную:"
  echo -e "    echo \"<user>  pptpd  <pass>  *\" >> /etc/ppp/chap-secrets"
  echo
}

# ─── Main ────────────────────────────────────────────────────────────────────
main(){
  banner
  check_os

  [[ -z "${VPN_PASS}" ]] && VPN_PASS=$(gen_pass)

  info "Пользователь:  ${VPN_USER}"
  info "Пароль:        ${VPN_PASS}"
  echo

  install_pptpd
  configure_pptpd
  configure_ppp_options
  add_vpn_user
  enable_ip_forwarding
  configure_iptables
  open_firewall
  enable_service
  print_summary
}

main "$@"
