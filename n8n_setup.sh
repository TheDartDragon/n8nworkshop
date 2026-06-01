#!/bin/bash
# ============================================================
#  n8n Workshop Setup Script
#  Встановлює: Docker, n8n, Caddy (авто SSL reverse proxy)
#  ОС: Ubuntu 22.04 / 24.04 або Debian 12
#  Використання: sudo bash n8n_setup.sh
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
    error "Запустіть від імені root: sudo bash n8n_setup.sh"
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
echo "  Налаштування VPS для воркшопу — n8n + Caddy + Docker"
echo ""

# ---------- Gather input ----------
step "Налаштування"

read -rp "  Введіть ваш домен (напр. yourname.duckdns.org): " DOMAIN
if [ -z "$DOMAIN" ]; then
    error "Домен не може бути порожнім"
fi

read -rp "  Введіть email для SSL-сертифіката: " EMAIL
if [ -z "$EMAIL" ]; then
    error "Email не може бути порожнім"
fi

read -rp "  Логін адміністратора n8n (Enter = admin): " N8N_USER
N8N_USER=${N8N_USER:-admin}

read -rsp "  Пароль адміністратора n8n: " N8N_PASS
echo ""
if [ -z "$N8N_PASS" ]; then
    error "Пароль не може бути порожнім"
fi

echo ""
info "Домен:        $DOMAIN"
info "Email:        $EMAIL"
info "Користувач:   $N8N_USER"
echo ""
read -rp "  Продовжити встановлення? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Скасовано."
    exit 0
fi

# ---------- System update ----------
step "Оновлення системи"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git ufw
info "Систему оновлено"

# ---------- Swap (important for 2GB RAM) ----------
step "Файл підкачки"
if [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    info "Створено файл підкачки 1GB"
else
    warn "Файл підкачки вже існує, пропускаємо"
fi

# ---------- Firewall ----------
step "Брандмауер (UFW)"
ufw --force reset > /dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment "SSH"
ufw allow 80/tcp    comment "HTTP (Caddy redirect)"
ufw allow 443/tcp   comment "HTTPS (n8n)"
ufw --force enable
info "Брандмауер налаштовано (порти: 22, 80, 443)"

# ---------- Docker ----------
step "Встановлення Docker"
if command -v docker &> /dev/null; then
    warn "Docker вже встановлено, пропускаємо"
else
    curl -fsSL https://get.docker.com | sh
    info "Docker встановлено"
fi

systemctl enable docker --quiet
systemctl start docker
info "Сервіс Docker запущено"

# ---------- Create n8n directory ----------
step "Конфігурація n8n"
N8N_DIR=/opt/n8n
mkdir -p "$N8N_DIR"
cd "$N8N_DIR"
info "Робоча директорія: $N8N_DIR"

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

info "Файл docker-compose.yml створено"

# ---------- Caddyfile ----------
cat > Caddyfile << EOF
${DOMAIN} {
    # Автоматичний HTTPS через Let's Encrypt
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

info "Caddyfile створено"

# ---------- Launch ----------
step "Запуск сервісів"
docker compose pull --quiet
docker compose up -d
info "Контейнери запущено"

# ---------- Wait for n8n to be ready ----------
step "Очікування запуску n8n"
echo -n "  Перевірка стану n8n"
for i in {1..30}; do
    if docker compose exec -T n8n wget -q --spider http://localhost:5678/healthz 2>/dev/null; then
        echo ""
        info "n8n працює"
        break
    fi
    echo -n "."
    sleep 2
done

# ---------- Done ----------
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Встановлення завершено!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Адреса:       ${CYAN}https://${DOMAIN}${NC}"
echo -e "  Користувач:   ${CYAN}${N8N_USER}${NC}"
echo -e "  Пароль:       ${CYAN}(той, що ввели)${NC}"
echo ""
echo -e "  ${YELLOW}Примітка: SSL-сертифікат може видаватися 1-2 хвилини${NC}"
echo -e "  ${YELLOW}Якщо сторінка не відкривається одразу — зачекайте і оновіть${NC}"
echo ""
echo "  Корисні команди:"
echo "    cd /opt/n8n"
echo "    docker compose logs -f        # переглянути логи"
echo "    docker compose restart        # перезапустити сервіси"
echo "    docker compose down           # зупинити все"
echo ""
