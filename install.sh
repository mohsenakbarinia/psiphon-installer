#!/usr/bin/env bash
# ==============================================================================
# Psiphon Multi-Region & Web Management Dashboard Installer
# Repository: https://github.com/mohsenakbarinia/psiphon-installer
# ==============================================================================

set -Eeuo pipefail

readonly VERSION="6.1"
readonly INSTALL_DIR="/opt/psiphon-panel"
readonly PSIPHON_USER="psiphon"
readonly INSTANCE_COUNT=20
readonly SOCKS_BASE_PORT=10800
readonly LOG_FILE="/var/log/psiphon-installer.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]${NC} $*" | tee -a "$LOG_FILE"; }
err() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR]${NC} $*" | tee -a "$LOG_FILE"; }

if [ "$EUID" -ne 0 ]; then
    err "این اسکریپت حتما باید با دسترسی root اجرا شود."
    exit 1
fi

clear
echo -e "${CYAN}==============================================================${NC}"
echo -e "${GREEN}    نصب‌کننده خودکار سایفون چند لوکیشن + پنل وب مدیریتی جامع v${VERSION}${NC}"
echo -e "${CYAN}    https://github.com/mohsenakbarinia/psiphon-installer       ${NC}"
echo -e "${CYAN}==============================================================${NC}"
sleep 1

# 1. Package Installation
log "نصب پکیج‌های پیش‌نیاز سیستم..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget jq socat nginx-light certbot python3 python3-pip python3-venv ufw fail2ban

# 2. Directories & User Setup
log "آماده‌سازی دایرکتوری‌ها و کاربر سیستمی..."
id -u "$PSIPHON_USER" &>/dev/null || useradd -r -s /bin/false -d "$INSTALL_DIR" "$PSIPHON_USER"

mkdir -p "$INSTALL_DIR"/{bin,config,data,logs,web,web/templates}
mkdir -p "$INSTALL_DIR/data/instances"

# 3. Psiphon Core Binary Setup (بررسی هوشمند باینری)
log "بررسی و دانلود فایل اجرایی psiphon-tunnel-core..."
if [ -f "/opt/psiphon-multi-region/bin/psiphon-tunnel-core" ]; then
    log "استفاده از باینری موجود در سرور..."
    cp -f "/opt/psiphon-multi-region/bin/psiphon-tunnel-core" "$INSTALL_DIR/bin/psiphon-tunnel-core"
elif [ -f "/usr/local/bin/psiphon-tunnel-core" ]; then
    cp -f "/usr/local/bin/psiphon-tunnel-core" "$INSTALL_DIR/bin/psiphon-tunnel-core"
else
    log "دانلود مستقیم باینری رسمی سایفون..."
    curl -fsSL "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64" -o "$INSTALL_DIR/bin/psiphon-tunnel-core"
fi

chmod +x "$INSTALL_DIR/bin/psiphon-tunnel-core"

# 4. Configuration Generation
log "تولید فایل‌های کانفیگ برای ${INSTANCE_COUNT} اینستنس..."
for i in $(seq 1 $INSTANCE_COUNT); do
    cat << EOF > "$INSTALL_DIR/config/psi-$i.conf"
{
  "LocalSocksProxyPort": $((SOCKS_BASE_PORT + i - 1)),
  "LocalHttpProxyPort": 0,
  "DataRootDirectory": "$INSTALL_DIR/data/instances/psi-$i",
  "EmitBytesTransferred": true,
  "EmitDiagnosticInfo": true
}
EOF
    mkdir -p "$INSTALL_DIR/data/instances/psi-$i"
done
chown -R "$PSIPHON_USER":"$PSIPHON_USER" "$INSTALL_DIR"

# 5. Systemd Service Template for Psiphon Instances
cat << EOF > /etc/systemd/system/psiphon@.service
[Unit]
Description=Psiphon Core Instance %i
After=network.target
Wants=network.target

[Service]
Type=simple
User=$PSIPHON_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/bin/psiphon-tunnel-core --config $INSTALL_DIR/config/psi-%i.conf
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# 6. Python Web Panel Backend
log "راه‌اندازی محیط پایتون و پنل وب..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip -q
"$INSTALL_DIR/venv/bin/pip" install fastapi uvicorn[standard] jinja2 requests psutil websockets -q

cat << 'PYEOF' > "$INSTALL_DIR/web/app.py"
import os
import json
import asyncio
import subprocess
import requests
import psutil
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, Form
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates

app = FastAPI(title="Psiphon Web Dashboard")
BASE_DIR = "/opt/psiphon-panel"
templates = Jinja2Templates(directory=f"{BASE_DIR}/web/templates")

def get_instance_status(idx: int):
    socks_port = 10800 + idx - 1
    active = subprocess.run(["systemctl", "is-active", f"psiphon@{idx}"], capture_output=True, text=True).stdout.strip() == "active"
    ip = "-"
    country = "-"
    if active:
        try:
            r = requests.get("https://ipwho.is/", proxies={"http": f"socks5h://127.0.0.1:{socks_port}", "https": f"socks5h://127.0.0.1:{socks_port}"}, timeout=1.5)
            if r.status_code == 200:
                data = r.json()
                if data.get("success"):
                    ip = data.get("ip", "-")
                    country = data.get("country", "-")
        except Exception:
            pass
    return {"id": idx, "port": socks_port, "active": active, "ip": ip, "country": country}

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    cpu = psutil.cpu_percent(interval=None)
    ram = psutil.virtual_memory().percent
    instances = [get_instance_status(i) for i in range(1, 21)]
    return templates.TemplateResponse("dashboard.html", {"request": request, "instances": instances, "cpu": cpu, "ram": ram})

@app.post("/api/instance/{idx}/action")
async def instance_action(idx: int, action: str = Form(...)):
    if action in ["start", "stop", "restart"]:
        subprocess.run(["systemctl", action, f"psiphon@{idx}"])
        return JSONResponse({"status": "success", "message": f"اینستنس {idx} با موفقیت {action} شد."})
    return JSONResponse({"status": "error", "message": "دستور نامعتبر است."}, status_code=400)

@app.post("/api/domain")
async def setup_domain(domain: str = Form(...)):
    if not domain:
        return JSONResponse({"status": "error", "message": "دامنه نباید خالی باشد."}, status_code=400)
    cmd = f"/usr/local/bin/psi-panel-ssl {domain}"
    proc = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if proc.returncode == 0:
        return JSONResponse({"status": "success", "message": f"دامنه {domain} با موفقیت متصل و گواهی SSL صادر شد."})
    return JSONResponse({"status": "error", "message": f"خطا در صدور SSL: {proc.stderr}"}, status_code=500)

@app.websocket("/ws/logs/{service_name}")
async def stream_logs(websocket: WebSocket, service_name: str):
    await websocket.accept()
    proc = await asyncio.create_subprocess_exec(
        "journalctl", "-u", service_name, "-f", "-n", "30",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT
    )
    try:
        while True:
            line = await proc.stdout.readline()
            if not line:
                break
            await websocket.send_text(line.decode("utf-8", errors="replace"))
    except WebSocketDisconnect:
        proc.kill()
    except Exception:
        proc.kill()
PYEOF

# ساخت فایل HTML داشبورد
cat << 'HTMLEOF' > "$INSTALL_DIR/web/templates/dashboard.html"
<!DOCTYPE html>
<html dir="rtl" lang="fa">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>مدیریت لوکیشن‌های سایفون | پنل ادمین</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.rtl.min.css">
    <style>
        body { background: #0b0f19; color: #cbd5e1; font-family: system-ui, -apple-system, sans-serif; padding-bottom: 50px; }
        .navbar { background: #111827; border-bottom: 1px solid #1f2937; }
        .card { background: #111827; border: 1px solid #1f2937; border-radius: 10px; }
        .badge-active { background: #10b981; }
        .badge-inactive { background: #ef4444; }
        .log-box { background: #030712; color: #10b981; font-family: monospace; font-size: 13px; height: 320px; overflow-y: scroll; padding: 15px; border-radius: 8px; border: 1px solid #1f2937; }
        .btn-action { font-size: 12px; padding: 2px 8px; }
    </style>
</head>
<body>
    <nav class="navbar navbar-dark px-4 py-3 mb-4">
        <span class="navbar-brand mb-0 h1">⚡ پنل مدیریت سایفون چند لوکیشن</span>
        <div>
            <span class="badge bg-secondary me-2">پردازنده: {{ cpu }}%</span>
            <span class="badge bg-secondary">رم: {{ ram }}%</span>
        </div>
    </nav>

    <div class="container-fluid px-4">
        <div class="row mb-4">
            <div class="col-md-5 mb-3">
                <div class="card p-3">
                    <h5 class="text-white mb-3">🌐 تنظیم دامنه و گواهی SSL</h5>
                    <div class="input-group">
                        <input type="text" id="domainInput" class="form-control bg-dark text-white border-secondary" placeholder="sub.domain.com">
                        <button class="btn btn-primary" onclick="setDomain()">ثبت و صدور SSL</button>
                    </div>
                    <div id="domainMsg" class="mt-2 text-info small"></div>
                </div>
            </div>
            <div class="col-md-7">
                <div class="card p-3">
                    <div class="d-flex justify-content-between align-items-center mb-2">
                        <h5 class="text-white mb-0">📜 لاگ زنده (Realtime Log)</h5>
                        <select id="logSelector" class="form-select form-select-sm bg-dark text-white border-secondary w-auto" onchange="changeLogStream()">
                            <option value="psiphon@1">سایفون ۱</option>
                            <option value="psiphon-panel">پنل وب</option>
                            <option value="nginx">Nginx</option>
                        </select>
                    </div>
                    <div id="logContent" class="log-box">در حال بارگذاری جریان لاگ...</div>
                </div>
            </div>
        </div>

        <div class="card p-3">
            <h5 class="text-white mb-3">📋 وضعیت اینستنس‌های سایفون (SOCKS5 Outbounds)</h5>
            <div class="table-responsive">
                <table class="table table-dark table-hover align-middle">
                    <thead>
                        <tr>
                            <th>#</th>
                            <th>پورت SOCKS</th>
                            <th>وضعیت</th>
                            <th>IP لوکیشن</th>
                            <th>کشور</th>
                            <th>عملیات</th>
                        </tr>
                    </thead>
                    <tbody>
                        {% for item in instances %}
                        <tr>
                            <td>{{ item.id }}</td>
                            <td><code>127.0.0.1:{{ item.port }}</code></td>
                            <td>
                                {% if item.active %}
                                    <span class="badge badge-active">فعال</span>
                                {% else %}
                                    <span class="badge badge-inactive">غیرفعال</span>
                                {% endif %}
                            </td>
                            <td>{{ item.ip }}</td>
                            <td>{{ item.country }}</td>
                            <td>
                                <button class="btn btn-sm btn-outline-success btn-action" onclick="controlInstance({{ item.id }}, 'start')">شروع</button>
                                <button class="btn btn-sm btn-outline-danger btn-action" onclick="controlInstance({{ item.id }}, 'stop')">توقف</button>
                                <button class="btn btn-sm btn-outline-warning btn-action" onclick="controlInstance({{ item.id }}, 'restart')">ری‌استارت</button>
                            </td>
                        </tr>
                        {% endfor %}
                    </tbody>
                </table>
            </div>
        </div>
    </div>

    <script>
        let ws;
        function connectLog(service) {
            if (ws) ws.close();
            const logBox = document.getElementById("logContent");
            logBox.innerHTML = "";
            const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
            ws = new WebSocket(`${proto}//${window.location.host}/ws/logs/${service}`);
            ws.onmessage = (event) => {
                logBox.innerHTML += event.data + "\n";
                logBox.scrollTop = logBox.scrollHeight;
            };
        }

        function changeLogStream() {
            const val = document.getElementById("logSelector").value;
            connectLog(val);
        }

        async function controlInstance(id, action) {
            const fd = new FormData();
            fd.append("action", action);
            const res = await fetch(`/api/instance/${id}/action`, { method: "POST", body: fd });
            const data = await res.json();
            alert(data.message);
            location.reload();
        }

        async function setDomain() {
            const domain = document.getElementById("domainInput").value.trim();
            if (!domain) return alert("لطفا نام دامنه را وارد کنید.");
            const msg = document.getElementById("domainMsg");
            msg.innerText = "در حال صدور گواهی SSL و اعمال تنظیمات Nginx (لطفا صبر کنید)...";
            const fd = new FormData();
            fd.append("domain", domain);
            const res = await fetch("/api/domain", { method: "POST", body: fd });
            const data = await res.json();
            msg.innerText = data.message;
            if (data.status === "success") {
                setTimeout(() => window.location.href = `https://${domain}`, 3000);
            }
        }

        window.onload = () => connectLog("psiphon@1");
    </script>
</body>
</html>
HTMLEOF

# 7. اسکریپت SSL و Nginx
cat << 'SSLEOF' > /usr/local/bin/psi-panel-ssl
#!/usr/bin/env bash
set -e
DOMAIN="$1"
systemctl stop nginx || true
certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email

cat << NGINXCONF > /etc/nginx/sites-available/psiphon-panel
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINXCONF

ln -sf /etc/nginx/sites-available/psiphon-panel /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx
SSLEOF
chmod +x /usr/local/bin/psi-panel-ssl

# 8. Service Systemd برای پنل وب
cat << EOF > /etc/systemd/system/psiphon-panel.service
[Unit]
Description=Psiphon Multi-Region Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/web
ExecStart=$INSTALL_DIR/venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 9. فعال‌سازی سرویس‌ها
log "بارگذاری و راه‌اندازی سرویس‌های سیستمی..."
systemctl daemon-reload
systemctl enable --now psiphon-panel

# فعال‌سازی اولیه ۳ اینستنس
for i in 1 2 3; do
    systemctl enable --now psiphon@$i 2>/dev/null || true
done

ufw allow 80/tcp || true
ufw allow 443/tcp || true
ufw allow 22/tcp || true

log "نصب با موفقیت انجام شد!"
IP=$(curl -s https://api.ipify.org || echo "SERVER_IP")
echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}✓ پنل مدیریت تحت وب با موفقیت فعال شد.${NC}"
echo -e "${CYAN}آدرس موقت: http://${IP}:8000${NC}"
echo -e "${YELLOW}از داخل پنل می‌توانید دامنه خود را برای دریافت SSL متصل کنید.${NC}"
echo -e "${GREEN}==============================================================${NC}"
