/**
 * ============================================
 *   VEXHOST - Domain & Database Webhook Server
 *   Jalankan di VPS host sebagai root
 *   Lokasi: /opt/vexhost-webhook/server.js
 * ============================================
 */

const http     = require("http");
const { execSync, exec } = require("child_process");
const fs       = require("fs");
const crypto   = require("crypto");
const path     = require("path");

// ============================================
//   KONFIGURASI — SESUAIKAN SEBELUM INSTALL
// ============================================
const CONFIG = {
    SECRET_KEY     : "VexHost#SecretKey2025!xK9mP2qL7nR4",  // ⚠️ Ganti ini!
    PORT           : 3500,
    CERTBOT_EMAIL  : "vexhost@gmail.com",
    MYSQL_ROOT_PASS: "VexHostMySQL2025!",                    // ⚠️ Ganti ini!
    LOG_FILE       : "/var/log/vexhost-webhook.log",
    NGINX_AVAILABLE: "/etc/nginx/sites-available",
    NGINX_ENABLED  : "/etc/nginx/sites-enabled",
    DB_RECORD_FILE : "/opt/vexhost-webhook/databases.json",
};
// ============================================

// ===== LOGGER =====
function log(msg) {
    const time = new Date().toISOString();
    const line = `[${time}] ${msg}`;
    console.log(line);
    try { fs.appendFileSync(CONFIG.LOG_FILE, line + "\n"); } catch(e) {}
}

// ===== RANDOM STRING =====
function rand(len = 12) {
    return crypto.randomBytes(len).toString("base64").replace(/[^a-zA-Z0-9]/g, "").slice(0, len);
}

// ===== VALIDASI =====
function isValidDomain(d) {
    return /^[a-zA-Z0-9][a-zA-Z0-9\-\.]{1,253}[a-zA-Z0-9]$/.test(d);
}
function isValidPort(p) {
    const n = parseInt(p);
    return n >= 1024 && n <= 65535;
}

// ===== DB RECORDS =====
function loadDbRecords() {
    try {
        if (fs.existsSync(CONFIG.DB_RECORD_FILE)) {
            return JSON.parse(fs.readFileSync(CONFIG.DB_RECORD_FILE, "utf8"));
        }
    } catch(e) {}
    return {};
}
function saveDbRecords(records) {
    fs.writeFileSync(CONFIG.DB_RECORD_FILE, JSON.stringify(records, null, 2));
}

// ===== MYSQL FUNCTIONS =====
function mysqlExec(sql) {
    execSync(`mysql -u root -p'${CONFIG.MYSQL_ROOT_PASS}' -e "${sql.replace(/"/g, '\\"')}"`, { stdio: "pipe" });
}

function createDatabase(domain) {
    const records = loadDbRecords();
    if (records[domain]) {
        log(`[DB] Database untuk ${domain} sudah ada, skip.`);
        return records[domain];
    }

    const suffix   = rand(8).toLowerCase();
    const db_name  = `vex_${suffix}`;
    const db_user  = `u_${suffix}`;
    const db_pass  = rand(16);
    const db_host  = "172.18.0.1";

    log(`[DB] Membuat database ${db_name} untuk ${domain}...`);
    mysqlExec(`CREATE DATABASE IF NOT EXISTS \`${db_name}\`;`);
    // MariaDB compatible: GRANT otomatis create user
    mysqlExec(`GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'%' IDENTIFIED BY '${db_pass}';`);
    mysqlExec(`FLUSH PRIVILEGES;`);

    const creds = { db_name, db_user, db_pass, db_host };
    records[domain] = creds;
    saveDbRecords(records);

    log(`[DB] ✅ Database ${db_name} berhasil dibuat untuk ${domain}`);
    return creds;
}

function dropDatabase(domain) {
    const records = loadDbRecords();
    if (!records[domain]) {
        log(`[DB] Tidak ada database untuk ${domain}, skip.`);
        return;
    }
    const { db_name, db_user } = records[domain];
    try {
        mysqlExec(`DROP DATABASE IF EXISTS \`${db_name}\`;`);
        mysqlExec(`DROP USER IF EXISTS '${db_user}'@'%';`);
        mysqlExec(`FLUSH PRIVILEGES;`);
        log(`[DB] ✅ Database ${db_name} berhasil dihapus`);
    } catch(e) {
        log(`[DB] Error drop database: ${e.message}`);
    }
    delete records[domain];
    saveDbRecords(records);
}

// ===== NGINX CONFIG =====
function writeNginxConfig(domain, appPort, fbPort) {
    const fbBlock = fbPort ? `
    # File Manager
    location /vex-files/ {
        proxy_pass http://127.0.0.1:${fbPort}/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
    }` : "";

    const config = `# VexHost - ${domain}
# Generated: ${new Date().toISOString()}

server {
    listen 80;
    server_name ${domain} www.${domain};

    # Main App
    location / {
        proxy_pass http://127.0.0.1:${appPort};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        client_max_body_size 100M;
    }
    ${fbBlock}
}

# phpMyAdmin subdomain
server {
    listen 80;
    server_name db.${domain};

    location / {
        proxy_pass http://127.0.0.1:8082;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 100M;
    }
}

# File Manager subdomain
server {
    listen 80;
    server_name files.${domain};

    location / {
        proxy_pass http://127.0.0.1:${fbPort || 4000};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        client_max_body_size 500M;
    }
}
`;
    fs.writeFileSync(`${CONFIG.NGINX_AVAILABLE}/${domain}`, config);
    if (!fs.existsSync(`${CONFIG.NGINX_ENABLED}/${domain}`)) {
        execSync(`ln -sf ${CONFIG.NGINX_AVAILABLE}/${domain} ${CONFIG.NGINX_ENABLED}/${domain}`);
    }
    execSync("nginx -t", { stdio: "pipe" });
    execSync("systemctl reload nginx");
    log(`[NGINX] Config untuk ${domain} berhasil dibuat`);
}

// ===== CERTBOT SSL =====
function generateSSL(domain) {
    log(`[SSL] Generating SSL untuk ${domain}, db.${domain}, files.${domain}...`);
    try {
        execSync(
            `certbot --nginx \
            -d ${domain} \
            -d www.${domain} \
            -d db.${domain} \
            -d files.${domain} \
            --non-interactive --agree-tos \
            -m ${CONFIG.CERTBOT_EMAIL} \
            --redirect`,
            { stdio: "pipe" }
        );
        log(`[SSL] ✅ SSL aktif untuk ${domain} dan subdomainnya`);
    } catch(e) {
        log(`[SSL] ⚠️  Certbot error (mungkin DNS belum propagate): ${e.message}`);
        throw new Error("SSL gagal — pastikan DNS domain sudah pointing ke IP VPS ini");
    }
}

// ===== REMOVE DOMAIN =====
function removeDomain(domain) {
    log(`[REMOVE] Menghapus semua config untuk ${domain}...`);

    // Drop database
    dropDatabase(domain);

    // Hapus SSL
    try {
        execSync(`certbot delete --cert-name ${domain} --non-interactive`, { stdio: "pipe" });
        log(`[REMOVE] SSL cert ${domain} dihapus`);
    } catch(e) {
        log(`[REMOVE] Tidak ada SSL cert untuk ${domain}`);
    }

    // Hapus nginx
    const enabled  = `${CONFIG.NGINX_ENABLED}/${domain}`;
    const available = `${CONFIG.NGINX_AVAILABLE}/${domain}`;
    if (fs.existsSync(enabled))   fs.unlinkSync(enabled);
    if (fs.existsSync(available)) fs.unlinkSync(available);

    try {
        execSync("nginx -t", { stdio: "pipe" });
        execSync("systemctl reload nginx");
    } catch(e) {}

    log(`[REMOVE] ✅ ${domain} berhasil dihapus semua`);
}

// ===== MAIN SETUP =====
function setupDomain(domain, appPort, fbPort, enableDb, enableFb) {
    log(`[SETUP] Memulai setup untuk ${domain}...`);

    let creds = null;

    // Setup database
    if (enableDb) {
        creds = createDatabase(domain);
    }

    // Buat nginx config
    writeNginxConfig(domain, appPort, enableFb ? fbPort : null);

    // Generate SSL
    generateSSL(domain);

    log(`[SETUP] ✅ Setup selesai untuk ${domain}`);
    return creds;
}

// ===== HTTP SERVER =====
const server = http.createServer((req, res) => {
    res.setHeader("Content-Type", "application/json");

    if (req.method !== "POST") {
        res.writeHead(405);
        return res.end(JSON.stringify({ error: "Method not allowed" }));
    }

    let body = "";
    req.on("data", chunk => body += chunk);
    req.on("end", () => {
        try {
            const data = JSON.parse(body);
            const { secret, action, domain, port, fb_port, enable_db, enable_fb } = data;

            // Auth
            if (secret !== CONFIG.SECRET_KEY) {
                log(`[AUTH] Unauthorized dari ${req.socket.remoteAddress}`);
                res.writeHead(401);
                return res.end(JSON.stringify({ error: "Unauthorized" }));
            }

            // Validasi domain
            if (!domain || !isValidDomain(domain)) {
                res.writeHead(400);
                return res.end(JSON.stringify({ error: "Domain tidak valid" }));
            }

            // ===== ACTION: SETUP =====
            if (action === "setup") {
                if (!port || !isValidPort(port)) {
                    res.writeHead(400);
                    return res.end(JSON.stringify({ error: "Port tidak valid" }));
                }

                const fbPort   = parseInt(fb_port) || 4000;
                const doDb     = enable_db !== "0";
                const doFb     = enable_fb !== "0";

                log(`[REQUEST] SETUP ${domain} → app:${port} fb:${fbPort} db:${doDb} fm:${doFb}`);

                const creds = setupDomain(domain, port, fbPort, doDb, doFb);

                res.writeHead(200);
                return res.end(JSON.stringify({
                    success    : true,
                    message    : `${domain} berhasil disetup oleh VexHost`,
                    website    : `https://${domain}`,
                    pma_url    : `https://db.${domain}`,
                    files_url  : `https://files.${domain}`,
                    db_name    : creds?.db_name    || null,
                    db_user    : creds?.db_user    || null,
                    db_pass    : creds?.db_pass    || null,
                    db_host    : creds?.db_host    || null,
                }));

            // ===== ACTION: REMOVE =====
            } else if (action === "remove") {
                log(`[REQUEST] REMOVE ${domain}`);
                removeDomain(domain);
                res.writeHead(200);
                return res.end(JSON.stringify({
                    success: true,
                    message: `${domain} berhasil dihapus dari VexHost`
                }));

            // ===== ACTION: STATUS =====
            } else if (action === "status") {
                const records = loadDbRecords();
                res.writeHead(200);
                return res.end(JSON.stringify({
                    success: true,
                    domains: Object.keys(records).length,
                    uptime : process.uptime(),
                }));

            } else {
                res.writeHead(400);
                return res.end(JSON.stringify({ error: "Action tidak valid: setup / remove / status" }));
            }

        } catch(err) {
            log(`[ERROR] ${err.message}`);
            res.writeHead(500);
            return res.end(JSON.stringify({ error: err.message }));
        }
    });
});

// Pastikan record file ada
if (!fs.existsSync(path.dirname(CONFIG.DB_RECORD_FILE))) {
    fs.mkdirSync(path.dirname(CONFIG.DB_RECORD_FILE), { recursive: true });
}
if (!fs.existsSync(CONFIG.DB_RECORD_FILE)) {
    fs.writeFileSync(CONFIG.DB_RECORD_FILE, "{}");
}

server.listen(CONFIG.PORT, "0.0.0.0", () => {
    log(`🚀 VexHost Webhook Server berjalan di port ${CONFIG.PORT}`);
    log(`📦 MySQL Root: dikonfigurasi`);
    log(`📁 DB Records: ${CONFIG.DB_RECORD_FILE}`);
});
