#!/bin/bash
cd /home/container

# ============================================
#   VEXHOST WEB HOSTING - start.sh
#   Full Featured: PHP, Python, Node, Next.js,
#   React, Vue, Nuxt, Static, Laravel, WordPress
#   + FileBrowser, Cronjob, Monitor, Backup
# ============================================

echo "============================================"
echo "   VEXHOST WEB HOSTING"
echo "   Powered by VexHost.id"
echo "============================================"
[ -n "${CUSTOM_DOMAIN}" ] && echo " Domain   : https://${CUSTOM_DOMAIN}" || echo " Domain   : http://$(hostname -i | awk '{print $1}'):${SERVER_PORT}"
echo " Port     : ${SERVER_PORT}"
echo " Framework: ${WEB_TYPE:-auto}"
echo "============================================"

# ===== SETUP DIREKTORI =====
mkdir -p /home/container/public
mkdir -p /home/container/backups
mkdir -p /home/container/logs
mkdir -p /home/container/.vexhost

# ===== AUTO UPDATE GIT =====
if [ "${AUTO_UPDATE}" = "1" ] && [ -n "${GIT_URL}" ]; then
    echo "[*] Auto update: git pull..."
    git pull 2>/dev/null || true
fi

# ===== WEBHOOK: SETUP DOMAIN + DATABASE =====
if [ -n "${CUSTOM_DOMAIN}" ] && [ -n "${WEBHOOK_SECRET}" ]; then
    echo "[*] Menghubungkan domain & database untuk ${CUSTOM_DOMAIN}..."
    RESULT=$(curl -s --max-time 20 -X POST http://172.18.0.1:3500 \
        -H "Content-Type: application/json" \
        -d "{
            \"secret\":\"${WEBHOOK_SECRET}\",
            \"action\":\"setup\",
            \"domain\":\"${CUSTOM_DOMAIN}\",
            \"port\":${SERVER_PORT},
            \"fb_port\":${FB_PORT:-4000},
            \"enable_db\":\"${ENABLE_DATABASE:-1}\",
            \"enable_fb\":\"${ENABLE_FILEMANAGER:-1}\"
        }" 2>/dev/null)

    echo "[*] Webhook response: $RESULT"

    # Parse credentials dari response
    DB_NAME=$(echo $RESULT | grep -o '"db_name":"[^"]*"' | cut -d'"' -f4)
    DB_USER=$(echo $RESULT | grep -o '"db_user":"[^"]*"' | cut -d'"' -f4)
    DB_PASS=$(echo $RESULT | grep -o '"db_pass":"[^"]*"' | cut -d'"' -f4)
    DB_HOST=$(echo $RESULT | grep -o '"db_host":"[^"]*"' | cut -d'"' -f4 || echo "172.18.0.1")

    if [ -n "$DB_NAME" ]; then
        echo ""
        echo "============================================"
        echo " DATABASE CREDENTIALS"
        echo "============================================"
        echo " DB Host     : ${DB_HOST}"
        echo " DB Name     : ${DB_NAME}"
        echo " DB Username : ${DB_USER}"
        echo " DB Password : ${DB_PASS}"
        echo " phpMyAdmin  : https://db.${CUSTOM_DOMAIN}"
        echo " File Manager: https://files.${CUSTOM_DOMAIN}"
        echo "============================================"
        echo ""

        # Auto-generate .env file dengan credentials
        cat > /home/container/.env << ENVEOF
# VexHost Auto-Generated - $(date)
DB_HOST=${DB_HOST}
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}

# App
APP_URL=https://${CUSTOM_DOMAIN}
APP_PORT=${SERVER_PORT}
ENVEOF

        # Simpan credentials ke file terpisah juga
        cat > /home/container/.vexhost/db.json << DBJSON
{
    "host": "${DB_HOST}",
    "name": "${DB_NAME}",
    "user": "${DB_USER}",
    "pass": "${DB_PASS}",
    "pma_url": "https://db.${CUSTOM_DOMAIN}"
}
DBJSON

        echo "[*] .env & credentials berhasil dibuat!"
    fi
else
    echo "[*] Mode IP:Port (domain belum diset)"
fi

# ===== AUTO INSTALL RUNTIME =====
_install_php() {
    if ! command -v php &>/dev/null; then
        echo "[*] Installing PHP runtime..."
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq php-cli php-curl php-mbstring php-xml php-mysql php-zip php-gd 2>/dev/null || true
    fi
}

_install_python() {
    if ! command -v python3 &>/dev/null; then
        echo "[*] Installing Python runtime..."
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq python3 python3-pip 2>/dev/null || true
        pip3 install flask fastapi uvicorn gunicorn django -q 2>/dev/null || true
    fi
}

# ===== DETECT FRAMEWORK =====
FW="${WEB_TYPE:-auto}"

if [ "${FW}" = "auto" ]; then
    echo "[*] Detecting framework..."
    if ls public/*.php 2>/dev/null | head -1 | grep -q '.php' || [ -f "index.php" ] || [ -f "public/index.php" ]; then
        FW="php"
    elif [ -f "wp-config.php" ] || [ -f "wp-login.php" ]; then
        FW="wordpress"
    elif [ -f "artisan" ] && [ -f "composer.json" ]; then
        FW="laravel"
    elif [ -f "composer.json" ] && [ -f "index.php" ]; then
        FW="php"
    elif [ -f "manage.py" ]; then
        FW="django"
    elif [ -f "app.py" ] || [ -f "main.py" ]; then
        FW="python"
    elif [ -f "next.config.js" ] || [ -f "next.config.mjs" ] || [ -f "next.config.ts" ]; then
        FW="nextjs"
    elif [ -f "nuxt.config.js" ] || [ -f "nuxt.config.ts" ]; then
        FW="nuxt"
    elif [ -f "vite.config.js" ] || [ -f "vite.config.ts" ]; then
        grep -q '"vue"' package.json 2>/dev/null && FW="vue" || FW="react-vite"
    elif [ -f "package.json" ]; then
        if   grep -q '"next"'         package.json 2>/dev/null; then FW="nextjs"
        elif grep -q '"nuxt"'         package.json 2>/dev/null; then FW="nuxt"
        elif grep -q '"express"'      package.json 2>/dev/null; then FW="express"
        elif grep -q '"react-scripts"' package.json 2>/dev/null; then FW="react-cra"
        else FW="node"; fi
    elif [ -f "index.html" ] || [ -f "public/index.html" ]; then
        FW="static"
    else
        FW="static"
    fi
fi

echo "[*] Framework: ${FW}"

# ===== HELPER FUNCTIONS =====
_pm() {
    corepack enable >/dev/null 2>&1 || true
    if   [ -f pnpm-lock.yaml ]; then echo pnpm
    elif [ -f yarn.lock ];      then echo yarn
    else echo npm; fi
}

_install() {
    local PM=$(_pm)
    echo "[*] Installing Node deps ($PM)..."
    if   [ "$PM" = "pnpm" ]; then pnpm install
    elif [ "$PM" = "yarn" ]; then yarn install
    else npm install; fi
}

_run() {
    local PM=$(_pm)
    if   [ "$PM" = "pnpm" ]; then pnpm run "$1"
    elif [ "$PM" = "yarn" ]; then yarn "$1"
    else npm run "$1"; fi
}

_pip_install() {
    if [ -f "requirements.txt" ]; then
        echo "[*] Installing Python requirements..."
        pip3 install -r requirements.txt -q 2>/dev/null || true
    fi
}

# ===== FILEBROWSER =====
_start_filebrowser() {
    if [ "${ENABLE_FILEMANAGER:-1}" = "1" ]; then
        FB_PORT="${FB_PORT:-4000}"
        FB_PASS="${FB_PASSWORD:-vexhost123}"

        # Install filebrowser kalau belum ada
        if ! command -v filebrowser &>/dev/null; then
            echo "[*] Installing FileBrowser..."
            curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash >/dev/null 2>&1 || \
            curl -sL https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz | tar xz -C /usr/local/bin filebrowser 2>/dev/null || true
        fi

        if command -v filebrowser &>/dev/null; then
            echo "[*] Starting FileBrowser di port ${FB_PORT}..."
            FB_DB="/home/container/.vexhost/fb.db"
            rm -f ${FB_DB}
            filebrowser -d ${FB_DB} config init >/dev/null 2>&1 || true
            filebrowser -d ${FB_DB} config set --address 0.0.0.0 --port ${FB_PORT} --root /home/container >/dev/null 2>&1 || true
            filebrowser -d ${FB_DB} users add admin "${FB_PASS}" --perm.admin >/dev/null 2>&1 || true
            filebrowser -d ${FB_DB} >> /home/container/logs/filebrowser.log 2>&1 &
            FB_PID=$!
            sleep 2
            if kill -0 $FB_PID 2>/dev/null; then
                echo "[*] FileBrowser jalan di port ${FB_PORT}"
                [ -n "${CUSTOM_DOMAIN}" ] && echo "[*] File Manager: https://files.${CUSTOM_DOMAIN}"
            else
                echo "[*] FileBrowser gagal start!"
            fi
        else
            echo "[*] FileBrowser tidak ditemukan!"
        fi
    fi
}

# ===== CRONJOB =====
_setup_cron() {
    if [ -n "${CRONJOB_1}" ] || [ -n "${CRONJOB_2}" ] || [ -n "${CRONJOB_3}" ]; then
        echo "[*] Setting up cronjobs..."
        CRONTAB_CONTENT=""
        [ -n "${CRONJOB_1}" ] && CRONTAB_CONTENT="${CRONTAB_CONTENT}${CRONJOB_1}\n"
        [ -n "${CRONJOB_2}" ] && CRONTAB_CONTENT="${CRONTAB_CONTENT}${CRONJOB_2}\n"
        [ -n "${CRONJOB_3}" ] && CRONTAB_CONTENT="${CRONTAB_CONTENT}${CRONJOB_3}\n"
        echo -e "$CRONTAB_CONTENT" | crontab - 2>/dev/null || true
        service cron start >/dev/null 2>&1 || crond 2>/dev/null || true
        echo "[*] Cronjob aktif!"
    fi
}

# ===== AUTO BACKUP =====
_start_backup() {
    if [ "${ENABLE_BACKUP:-1}" = "1" ]; then
        BACKUP_INTERVAL="${BACKUP_INTERVAL_HOURS:-24}"
        echo "[*] Auto backup aktif (tiap ${BACKUP_INTERVAL} jam)"
        (
            while true; do
                sleep $((BACKUP_INTERVAL * 3600))
                TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                BACKUP_NAME="backup_${TIMESTAMP}.tar.gz"
                echo "[BACKUP] Membuat backup ${BACKUP_NAME}..."
                tar -czf /home/container/backups/${BACKUP_NAME} \
                    --exclude=/home/container/backups \
                    --exclude=/home/container/.vexhost \
                    --exclude=/home/container/node_modules \
                    --exclude=/home/container/.git \
                    /home/container/ 2>/dev/null || true

                # Hapus backup lebih dari 7 hari
                find /home/container/backups -name "backup_*.tar.gz" -mtime +7 -delete 2>/dev/null || true
                echo "[BACKUP] ✅ ${BACKUP_NAME} selesai!"
            done
        ) &
    fi
}

# ===== MONITORING =====
_start_monitor() {
    if [ "${ENABLE_MONITOR:-1}" = "1" ]; then
        echo "[*] Monitoring aktif..."
        (
            FAIL_COUNT=0
            while true; do
                sleep 60
                # Cek apakah port masih aktif
                if command -v nc &>/dev/null; then
                    if nc -z 127.0.0.1 ${SERVER_PORT} 2>/dev/null; then
                        FAIL_COUNT=0
                        echo "[MONITOR] ✅ $(date '+%H:%M:%S') - Website UP di port ${SERVER_PORT}"
                    else
                        FAIL_COUNT=$((FAIL_COUNT + 1))
                        echo "[MONITOR] ⚠️  $(date '+%H:%M:%S') - Website DOWN (attempt ${FAIL_COUNT})"
                        [ "$FAIL_COUNT" -ge 3 ] && echo "[MONITOR] ❌ Website down 3x berturut-turut, periksa log!" && FAIL_COUNT=0
                    fi
                fi
                # Log CPU & RAM
                CPU=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo "N/A")
                MEM=$(free -m 2>/dev/null | awk 'NR==2{printf "%.0f%%", $3*100/$2}' || echo "N/A")
                echo "[MONITOR] CPU: ${CPU}% | RAM: ${MEM}" >> /home/container/logs/monitor.log 2>/dev/null || true
            done
        ) &
    fi
}

# ===== COMPOSER / LARAVEL SETUP =====
_composer_install() {
    if [ -f "composer.json" ]; then
        if ! command -v composer &>/dev/null; then
            echo "[*] Installing Composer..."
            curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer >/dev/null 2>&1 || true
        fi
        if command -v composer &>/dev/null; then
            echo "[*] Running composer install..."
            composer install --no-dev --optimize-autoloader --no-interaction -q 2>/dev/null || \
            composer install --no-interaction -q 2>/dev/null || true
        fi
    fi
}

# ===== JALANKAN SERVICES =====
_start_filebrowser
_setup_cron
_start_backup
_start_monitor

echo "============================================"
echo "[*] Menjalankan website..."
echo "============================================"

# ===== RUN FRAMEWORK =====
case "${FW}" in

    # PHP
    php)
        _install_php
        _composer_install
        DOCROOT="."
        [ -d "public" ] && DOCROOT="public"
        echo "[*] PHP server di port ${SERVER_PORT} (docroot: ${DOCROOT})"
        php -S 0.0.0.0:${SERVER_PORT} -t ${DOCROOT}
        ;;

    # LARAVEL
    laravel)
        _install_php
        _composer_install
        [ ! -f ".env" ] && cp .env.example .env 2>/dev/null || true
        php artisan key:generate --force 2>/dev/null || true
        php artisan config:cache 2>/dev/null || true
        php artisan migrate --force 2>/dev/null || true
        echo "[*] Laravel di port ${SERVER_PORT}"
        php artisan serve --host=0.0.0.0 --port=${SERVER_PORT}
        ;;

    # WORDPRESS
    wordpress)
        _install_php
        echo "[*] WordPress mode - PHP server di port ${SERVER_PORT}"
        php -S 0.0.0.0:${SERVER_PORT} -t .
        ;;

    # PYTHON
    python)
        _install_python
        _pip_install
        ENTRY="app.py"
        [ -f "main.py" ] && ENTRY="main.py"
        if grep -q "flask\|Flask" requirements.txt 2>/dev/null || grep -q "from flask\|import flask" "${ENTRY}" 2>/dev/null; then
            echo "[*] Flask di port ${SERVER_PORT}"
            FLASK_APP="${ENTRY}" FLASK_RUN_PORT="${SERVER_PORT}" FLASK_RUN_HOST="0.0.0.0" flask run
        elif grep -q "fastapi\|uvicorn" requirements.txt 2>/dev/null; then
            echo "[*] FastAPI (uvicorn) di port ${SERVER_PORT}"
            APP_MOD=$(grep -o 'app\|application' "${ENTRY}" | head -1 || echo "app")
            uvicorn "${ENTRY%.py}:${APP_MOD}" --host 0.0.0.0 --port "${SERVER_PORT}" --reload
        else
            echo "[*] Python di port ${SERVER_PORT}"
            PORT="${SERVER_PORT}" python3 "${ENTRY}"
        fi
        ;;

    # DJANGO
    django)
        _install_python
        _pip_install
        echo "[*] Django di port ${SERVER_PORT}"
        python3 manage.py migrate --run-syncdb 2>/dev/null || true
        python3 manage.py collectstatic --noinput 2>/dev/null || true
        python3 manage.py runserver 0.0.0.0:${SERVER_PORT}
        ;;

    # NEXT.JS
    nextjs)
        _install
        if [ "${NODE_RUN_ENV}" = "start" ]; then
            echo "[*] Next.js production build..."
            _run build
            $(_pm) run start -- -p ${SERVER_PORT}
        else
            $(_pm) run dev -- -p ${SERVER_PORT}
        fi
        ;;

    # NUXT
    nuxt)
        _install
        if [ "${NODE_RUN_ENV}" = "start" ]; then
            NITRO_PORT=${SERVER_PORT} _run build
            node .output/server/index.mjs
        else
            $(_pm) run dev -- --port ${SERVER_PORT}
        fi
        ;;

    # REACT (Vite) / VUE
    react-vite|vue)
        _install
        if [ "${NODE_RUN_ENV}" = "start" ]; then
            _run build
            npx --yes serve dist -l ${SERVER_PORT} -s
        else
            $(_pm) run dev -- --port ${SERVER_PORT} --host
        fi
        ;;

    # REACT CRA
    react-cra)
        _install
        if [ "${NODE_RUN_ENV}" = "start" ]; then
            _run build
            npx --yes serve build -l ${SERVER_PORT} -s
        else
            PORT=${SERVER_PORT} $(_pm) start
        fi
        ;;

    # EXPRESS / NODE
    express|node)
        _install
        START_FILE="index.js"
        [ -f "server.js" ] && START_FILE="server.js"
        [ -f "app.js" ]    && START_FILE="app.js"
        if [ -f "package.json" ]; then
            MAIN=$(node -e "try{console.log(require('./package.json').main||'')}catch(e){}" 2>/dev/null || true)
            [ -n "$MAIN" ] && [ -f "$MAIN" ] && START_FILE="$MAIN"
        fi
        if grep -q '"start"' package.json 2>/dev/null; then
            PORT=${SERVER_PORT} npm start
        else
            echo "[*] Node.js: ${START_FILE} di port ${SERVER_PORT}"
            PORT=${SERVER_PORT} node ${START_FILE}
        fi
        ;;

    # STATIC HTML
    static)
        echo "[*] Static server di port ${SERVER_PORT}"
        if [ -d "public" ]; then
            npx --yes serve public -l ${SERVER_PORT} -s
        else
            npx --yes serve . -l ${SERVER_PORT} -s
        fi
        ;;

    # PHP + NODE.JS (jalanin keduanya sekaligus)
    php+node|phpnode)
        _install_php
        _composer_install

        # ===== Jalanin Node.js backend dulu di background =====
        NODE_DIR="node"
        [ -d "backend" ] && NODE_DIR="backend"
        [ -d "api" ] && NODE_DIR="api"
        # Pastikan cari di root container
        [ -d "/home/container/node" ] && NODE_DIR="/home/container/node"

        NODE_PORT="${SERVER_PORT_2:-19111}"

        if [ -d "${NODE_DIR}" ] && [ -f "${NODE_DIR}/package.json" ]; then
            echo "[*] Installing Node.js deps di folder ${NODE_DIR}..."
            cd ${NODE_DIR}
            npm install --quiet 2>/dev/null || true

            # Update .env port kalau ada
            [ -f ".env" ] && sed -i "s/^PORT=.*/PORT=${NODE_PORT}/" .env || echo "PORT=${NODE_PORT}" >> .env

            echo "[*] Starting Node.js backend di port ${NODE_PORT}..."
            PORT=${NODE_PORT} npm start >> /home/container/logs/node.log 2>&1 &
            NODE_PID=$!
            sleep 3
            if kill -0 $NODE_PID 2>/dev/null; then
                echo "[*] Node.js backend jalan di port ${NODE_PORT} (PID: ${NODE_PID})"
            else
                echo "[*] Node.js backend gagal start, cek logs/node.log"
            fi
            cd /home/container
        else
            echo "[*] Folder node/backend/api tidak ditemukan, skip Node.js"
        fi

        # ===== Jalanin PHP frontend =====
        DOCROOT="."
        [ -d "php" ] && DOCROOT="php"
        [ -d "public" ] && DOCROOT="public"
        # php/ lebih prioritas dari public/
        [ -d "php" ] && DOCROOT="php"
        echo "[*] PHP frontend di port ${SERVER_PORT} (docroot: ${DOCROOT})"
        php -S 0.0.0.0:${SERVER_PORT} -t ${DOCROOT}
        ;;

    *)
        echo "[ERROR] WEB_TYPE '${FW}' tidak dikenali!"
        echo "Pilihan: auto, static, php, php+node, laravel, wordpress, python, django, node, express, nextjs, nuxt, react-vite, vue, react-cra"
        exit 1
        ;;
esac
