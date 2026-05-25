#!/usr/bin/env bash

# ======================================================
# L2TP/IPsec VPN Server Deployment Script (Docker)
# Ubuntu / Debian compatible
# ======================================================
# Usage:
#   chmod +x deploy-l2tp-vpn.sh
#   sudo ./deploy-l2tp-vpn.sh
# ======================================================

set -e

# -----------------------------
# CONFIGURATION
# -----------------------------
VPN_IPSEC_PSK="MyStrongPSK123"
VPN_USER="vpnuser"
VPN_PASSWORD="StrongPassword123"
VPN_DOCKER_NAME="l2tp-vpn-server"
VPN_DATA_DIR="/opt/l2tp-vpn"

# -----------------------------
# COLORS
# -----------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# -----------------------------
# ROOT CHECK
# -----------------------------
if [ "$EUID" -ne 0 ]; then
  error "Run this script as root"
  exit 1
fi

# -----------------------------
# INSTALL DOCKER
# -----------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "Docker already installed"
    return
  fi

  info "Installing Docker..."

  apt update
  apt install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt update

  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  info "Docker installed successfully"
}

# -----------------------------
# OPEN FIREWALL PORTS
# -----------------------------
configure_firewall() {
  info "Configuring firewall..."

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 500/udp
    ufw allow 4500/udp
    ufw allow 1701/udp

    warn "If UFW is inactive, ports were still added"
  else
    warn "UFW not installed. Skipping firewall configuration"
  fi
}

# -----------------------------
# ENABLE KERNEL OPTIONS
# -----------------------------
configure_kernel() {
  info "Configuring kernel networking parameters..."

  cat <<EOF >/etc/sysctl.d/99-l2tp-vpn.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.all.rp_filter=0
EOF

  sysctl --system
}

# -----------------------------
# DEPLOY VPN CONTAINER
# -----------------------------
deploy_vpn() {
  info "Creating VPN data directory..."

  mkdir -p "$VPN_DATA_DIR"

  info "Pulling Docker image..."

  docker pull hwdsl2/ipsec-vpn-server

  if docker ps -a --format '{{.Names}}' | grep -q "^${VPN_DOCKER_NAME}$"; then
    warn "Existing container found. Removing..."
    docker rm -f "$VPN_DOCKER_NAME"
  fi

  info "Starting L2TP/IPsec VPN server..."

  docker run -d \
    --name "$VPN_DOCKER_NAME" \
    --restart=always \
    --privileged \
    -p 500:500/udp \
    -p 4500:4500/udp \
    -p 1701:1701/udp \
    -e VPN_IPSEC_PSK="$VPN_IPSEC_PSK" \
    -e VPN_USER="$VPN_USER" \
    -e VPN_PASSWORD="$VPN_PASSWORD" \
    -v "$VPN_DATA_DIR":/etc/ipsec.d \
    hwdsl2/ipsec-vpn-server

  info "VPN container started"
}

# -----------------------------
# SHOW CONNECTION INFO
# -----------------------------
show_info() {
  SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')

  echo
  echo "======================================================"
  echo " L2TP/IPsec VPN Server Successfully Installed"
  echo "======================================================"
  echo
  echo "Server IP:      $SERVER_IP"
  echo "IPsec PSK:      $VPN_IPSEC_PSK"
  echo "VPN Username:   $VPN_USER"
  echo "VPN Password:   $VPN_PASSWORD"
  echo
  echo "Docker container: $VPN_DOCKER_NAME"
  echo
  echo "Required ports:"
  echo "  UDP 500"
  echo "  UDP 4500"
  echo "  UDP 1701"
  echo
  echo "Check logs:"
  echo "  docker logs -f $VPN_DOCKER_NAME"
  echo
  echo "Stop VPN:"
  echo "  docker stop $VPN_DOCKER_NAME"
  echo
  echo "Start VPN:"
  echo "  docker start $VPN_DOCKER_NAME"
  echo
  echo "======================================================"
}

# -----------------------------
# MAIN
# -----------------------------
main() {
  info "Starting L2TP/IPsec VPN deployment"

  install_docker
  configure_firewall
  configure_kernel
  deploy_vpn
  show_info
}

main
