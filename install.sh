#!/bin/bash
# ============================================
#   VEXHOST - VPS Full Setup Installer
#   Jalankan SEKALI di VPS host sebagai root
#   Usage: bash install.sh
# ============================================

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${GREEN}"
echo "============================================"
echo "   VEXHOST Web Hosting - VPS Installer"
echo "============================================"
echo -e "${NC}"

# Cek root
[ "$EUID" -ne 0 ] && echo -e "${RED}[ERROR] Jalankan sebagai root!${NC}" && exit 1

# Cek file server.js ada
[ ! -f "server.js" ] && echo -e "${RED}[ERROR] server.js tidak ditemukan! Jalankan dari folder yang benar.${NC}" && exit 1

# ===== INPUT KONFIGURASI =====
echo -e "${YELLOW}[CONFIG] Masukkan konfigurasi:${NC}"
read -p "MySQL root password (buat baru): " MYSQL_ROOT_PASS
read -p "Webhook secret key: " WEBHOOK_SECRET

# Simpan ke config file
cat > /opt/vexhost-webhook/.env << ENVEOF
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS}
WEBHOOK_SECRET=${WEBHOOK_SECRET}
ENVEOF

# Update server.js dengan values dari input
sed -i "s/VexHost#SecretKey2025!xK9mP2qL7nR4/${WEBHOOK_SECRET}/g" server.js
sed -i "s/VexHostMySQL2025!/${MYSQL_ROOT_PASS}/g" server.js

echo ""
echo -e "${GREEN}[1/7] Update sistem & install dependencies...${NC}"
apt-get update -qq
apt-get install -y -qq \
    nginx \
    certbot python3-certbot-nginx \
    curl wget git unzip \
    iptables-persistent \
    cron

# ===== NODE.JS =====
echo -e "${GREEN}[2/7] Install Node.js 20...${NC}"
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - -qq
    apt-get install -y -qq nodejs
fi
echo "Node.js: $(node -v)"

# ===== MYSQL =====
echo -e "${GREEN}[3/7] Install & setup MySQL...${NC}"
if ! command -v mysql &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-server
fi

# Aktifkan MySQL
systemctl enable mysql
systemctl start mysql

# Set root password & allow remote dari container
mysql -u root << SQLEOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1', '%');
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQLEOF

# Izinkan MySQL listen dari container network
sed -i 's/bind-address.*=.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl restart mysql
echo "MySQL: OK"

# ===== PHPMYADMIN =====
echo -e "${GREEN}[4/7] Install phpMyAdmin...${NC}"
apt-get install -y -qq php php-cli php-fpm php-mysql php-mbstring php-xml php-zip php-curl

PMA_DIR="/var/www/phpmyadmin"
if [ ! -d "$PMA_DIR" ]; then
    PMA_VER="5.2.1"
    wget -q "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VER}/phpMyAdmin-${PMA_VER}-all-languages.zip" -O /tmp/pma.zip
    unzip -q /tmp/pma.zip -d /var/www/
    mv /var/www/phpMyAdmin-${PMA_VER}-all-languages $PMA_DIR
    rm /tmp/pma.zip

    # Config phpMyAdmin
    cp $PMA_DIR/config.sample.inc.php $PMA_DIR/config.inc.php
    BLOWFISH=$(openssl rand -base64 32)
    sed -i "s/\$cfg\['blowfish_secret'\] = '';/\$cfg['blowfish_secret'] = '${BLOWFISH}';/" $PMA_DIR/config.inc.php
    echo "\$cfg['Servers'][\$i]['host'] = '127.0.0.1';" >> $PMA_DIR/config.inc.php
fi

# Buat Nginx config phpMyAdmin (port 8082)
cat > /etc/nginx/sites-available/phpmyadmin-vexhost << 'NGINXPMA'
server {
    listen 8082;
    root /var/www/phpmyadmin;
    index index.php;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
    }
}
NGINXPMA

# Detect PHP-FPM socket
PHP_FPM_SOCK=$(find /var/run/php/ -name "php*-fpm.sock" 2>/dev/null | head -1)
[ -n "$PHP_FPM_SOCK" ] && sed -i "s|unix:/var/run/php/php-fpm.sock|unix:${PHP_FPM_SOCK}|g" /etc/nginx/sites-available/phpmyadmin-vexhost

ln -sf /etc/nginx/sites-available/phpmyadmin-vexhost /etc/nginx/sites-enabled/phpmyadmin-vexhost
echo "phpMyAdmin: OK (port 8082)"

# ===== WEBHOOK SERVER =====
echo -e "${GREEN}[5/7] Setup VexHost Webhook Server...${NC}"
mkdir -p /opt/vexhost-webhook
cp server.js /opt/vexhost-webhook/server.js

cat > /etc/systemd/system/vexhost-webhook.service << 'SVCEOF'
[Unit]
Description=VexHost Domain & Database Webhook API
After=network.target mysql.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/vexhost-webhook
ExecStart=/usr/bin/node /opt/vexhost-webhook/server.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable vexhost-webhook
systemctl restart vexhost-webhook
echo "Webhook Server: OK (port 3500)"

# ===== IPTABLES =====
echo -e "${GREEN}[6/7] Setup firewall rules...${NC}"
# Izinkan container Pterodactyl akses webhook & MySQL
iptables -I INPUT -i pterodactyl0 -p tcp --dport 3500 -j ACCEPT
iptables -I INPUT -i pterodactyl0 -p tcp --dport 3306 -j ACCEPT
iptables -I DOCKER-USER -i pterodactyl0 -j ACCEPT 2>/dev/null || true
netfilter-persistent save
echo "Firewall: OK"

# ===== NGINX RELOAD =====
echo -e "${GREEN}[7/7] Reload Nginx...${NC}"
nginx -t && systemctl reload nginx
echo "Nginx: OK"

# ===== SELESAI =====
echo ""
echo -e "${GREEN}============================================"
echo " ✅ VexHost VPS Setup Selesai!"
echo "============================================${NC}"
echo ""
echo " Webhook Server : port 3500"
echo " phpMyAdmin     : port 8082 (internal)"
echo " MySQL          : port 3306"
echo " Log            : /var/log/vexhost-webhook.log"
echo ""
echo -e "${YELLOW} Cek status:${NC}"
echo "  systemctl status vexhost-webhook"
echo "  systemctl status mysql"
echo "  systemctl status nginx"
echo ""
echo -e "${YELLOW}⚠️  PENTING:${NC}"
echo " - Pastikan DNS domain user sudah pointing ke IP VPS ini"
echo " - Port 80 & 443 harus terbuka di firewall VPS"
echo -e "${GREEN}============================================${NC}"
