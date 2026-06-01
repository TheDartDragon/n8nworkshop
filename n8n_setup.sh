#!/bin/bash
# ============================================================
#  n8n Workshop Setup Script
#  Installs: Docker, n8n, Caddy (auto SSL reverse proxy)
#  OS: Ubuntu 22.04 / 24.04 or Debian 12
#  Usage: sudo bash n8n_setup.sh
# ============================================================

set -e

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ---------- Root check ----------
if [ "$EUID" -ne 0 ]; then
    error "Run as root: sudo bash n8n_setup.sh"
fi

# ---------- Banner ----------
echo -e "${CYAN}"
echo "  ███╗   ██╗ █████╗ ███╗   ██╗    ███████╗███████╗████████╗██╗   ██╗██████╗ "
echo "  ████╗  ██║██╔══██╗████╗  ██║    ██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗"
echo "  ██╔██╗ ██║╚█████╔╝██╔██╗ ██║    ███████╗█████╗     ██║   ██║   ██║██████╔╝"
echo "  ██║╚██╗██║██╔══██╗██║╚██╗██║    ╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝ "
echo "  ██║ ╚████║╚█████╔╝██║ ╚████║    ███████║███████╗   ██║   ╚██████╔╝██║     "
echo "  ╚═╝  ╚═══╝ ╚════╝ ╚═╝  ╚═══╝    ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝     "
echo -e "${NC}"
echo "  Workshop VPS Setup — n8n + Caddy + Docker"
echo ""

# ---------- Gather input ----------
step "Configuration"

read -rp "  Enter your domain (e.g. n8n.yourdomain.com or yourname.duckdns.org): " DOMAIN
if [ -z "$DOMAIN" ]; then
    error "Domain cannot be empty"
fi

read -rp "  Enter your email for SSL certificate: " EMAIL
if [ -z "$EMAIL" ]; then
    error "Email cannot be empty"
fi

read -rp "  Set n8n admin username: " N8N_USER
N8N_USER=${N8N_USER:-admin}

read -rsp "  Set n8n admin password: " N8N_PASS
echo ""
if [ -z "$N8N_PASS" ]; then
    error "Password cannot be empty"
fi

echo ""
info "Domain:   $DOMAIN"
info "Email:    $EMAIL"
info "n8n user: $N8N_USER"
echo ""
read -rp "  Proceed with installation? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ---------- System update ----------
step "System Update"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git ufw
info "System updated"

# ---------- Swap (important for 2GB RAM) ----------
step "Swap File"
if [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    info "1GB swap created"
else
    warn "Swap already exists, skipping"
fi

# ---------- Firewall ----------
step "Firewall (UFW)"
ufw --force reset > /dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment "SSH"
ufw allow 80/tcp    comment "HTTP (Caddy redirect)"
ufw allow 443/tcp   comment "HTTPS (n8n)"
ufw --force enable
info "Firewall configured (22, 80, 443)"

# ---------- Docker ----------
step "Docker Installation"
if command -v docker &> /dev/null; then
    warn "Docker already installed, skipping"
else
    curl -fsSL https://get.docker.com | sh
    info "Docker installed"
fi

# Enable Docker service
systemctl enable docker --quiet
systemctl start docker
info "Docker service started"

# ---------- Create n8n directory ----------
step "n8n Configuration"
N8N_DIR=/opt/n8n
mkdir -p "$N8N_DIR"
cd "$N8N_DIR"
info "Working directory: $N8N_DIR"

# ---------- docker-compose.yml ----------
cat > docker-compose.yml << EOF
version: '3.8'

services:

  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - n8n

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${DOMAIN}/
      - GENERIC_TIMEZONE=Europe/Kyiv
      - TZ=Europe/Kyiv
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_PASS}
      - N8N_RUNNERS_ENABLED=true
    volumes:
      - n8n_data:/home/node/.n8n
    expose:
      - "5678"

volumes:
  caddy_data:
  caddy_config:
  n8n_data:
EOF

info "docker-compose.yml created"

# ---------- Caddyfile ----------
cat > Caddyfile << EOF
${DOMAIN} {
    # Automatic HTTPS via Let's Encrypt
    tls ${EMAIL}

    reverse_proxy n8n:5678 {
        flush_interval -1
    }

    # Security headers
    header {
        X-Frame-Options SAMEORIGIN
        X-Content-Type-Options nosniff
        Referrer-Policy no-referrer-when-downgrade
    }
}
EOF

info "Caddyfile created"

# ---------- Launch ----------
step "Starting Services"
docker compose pull --quiet
docker compose up -d
info "Containers started"

# ---------- Wait for n8n to be ready ----------
step "Waiting for n8n"
echo -n "  Checking n8n health"
for i in {1..30}; do
    if docker compose exec -T n8n wget -q --spider http://localhost:5678/healthz 2>/dev/null; then
        echo ""
        info "n8n is up"
        break
    fi
    echo -n "."
    sleep 2
done

# ---------- Done ----------
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  URL:      ${CYAN}https://${DOMAIN}${NC}"
echo -e "  User:     ${CYAN}${N8N_USER}${NC}"
echo -e "  Password: ${CYAN}(what you entered)${NC}"
echo ""
echo -e "  ${YELLOW}Note: SSL certificate may take 1-2 minutes to provision${NC}"
echo -e "  ${YELLOW}If the page doesn't load immediately, wait and refresh${NC}"
echo ""
echo "  Useful commands:"
echo "    cd /opt/n8n"
echo "    docker compose logs -f        # view logs"
echo "    docker compose restart        # restart services"
echo "    docker compose down           # stop everything"
echo ""
