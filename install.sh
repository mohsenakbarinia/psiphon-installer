#!/usr/bin/env bash
# ==============================================================================
# MAXNET5G - Psiphon Multi-Region & Web Management Dashboard
# Developer: mohsenakbarinia
# ==============================================================================

set -Eeuo pipefail

readonly VERSION="7.2"
readonly INSTALL_DIR="/opt/psiphon-panel"
readonly PSIPHON_USER="psiphon"
readonly INSTANCE_COUNT=20
readonly SOCKS_BASE_PORT=10800
readonly LOG_FILE="/var/log/maxnet-installer.log"

# Colors
BOLD_RED='\033[1;31m'
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD_GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] [INFO]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] [WARN]${NC} $*" | tee -a "$LOG_FILE"; }
err() { echo -e "${RED}[$(date '+%H:%M:%S')] [ERROR]${NC} $*" | tee -a "$LOG_FILE"; }

show_banner() {
    clear
    echo -e "${BOLD_RED}"
    cat << "EOF"
  __  __     __     __  _   _ ______ _______   _____ _____ 
 |  \/  |   /\ \   / / | \ | |  ____|__   __| | ____/ ____|
 | شده یا کاراکتر اشتباه در خطوط میانی وارد شده بود.

برای حل کامل و قطعی موضوع، این اسکریپت تمیز و یکپارچه را مستقیماً جایگزین فایل `install.sh` در مخزن گیت‌هاب کنید:
```bash
#!/usr/bin/env bash
# ==============================================================================
# MAXNET5G - Psiphon Multi-Region & Web Management Dashboard
# Developer: mohsenakbarinia
# ==============================================================================

set -Eeuo pipefail

readonly VERSION="7.2"
readonly INSTALL_DIR="/opt/psiphon-panel"
readonly PSIPHON_USER="psiphon"
readonly INSTANCE_COUNT=20
readonly SOCKS_BASE_PORT=10800
readonly LOG_FILE="/var/log/maxnet-installer.log"

# Colors
BOLD_RED='\033[1;31m'
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD_GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] [INFO]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] [WARN]${NC} $*" | tee -a "$LOG_FILE"; }
err() { echo -e "${RED}[$(date '+%H:%M:%S')] [ERROR]${NC} $*" | tee -a "$LOG_FILE"; }

show_banner() {
clear
echo -e "${BOLD_RED}"
cat << "EOF"
  __  __     __     __  _   _ ______ _______   _____ _____ 
 |  \/  |   /\ \   / / | \ | |  ____|__   __| | ____/ ____|
 | \  / |  /  \ \_/ /  |  \| | |__     | |    | |END=noninteractive
apt-get update -y
apt-get install -y curl wget jq socat nginx-light certbot python3 python3-pip python3-venv ufw fail2ban file
}

setup_directories() {
log "ساخت کاربر سیستمی و پوشه‌های پروژه..."
id -u "$PSIPHON_USER" &>/dev/null || useradd -r -s /bin/false -d "$INSTALL_DIR" "$PSIPHON_USER"
mkdir -p "$INSTALL_DIR"/{bin,config,data/instances,web/templates,logs}
chown -R "$PSIPHON_USER":"$PSIPHON_USER" "$INSTALL_DIR"
}

download_psiphon_binary() {
local bin_path="$INSTALL_DIR/bin/psiphon-tunnel-core"
local url="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"

log "بررسی و دریافت باینری Psiphon..."
if [ -s "/opt/psiphon-multi-region/bin/psiphon-tunnel-core" ] && file "/opt/psiphon-multi-region/bin/psiphon-tunnel-core" | grep -q "ELF"; then
cp -f "/opt/psiphon-multi-region/bin/psiphon-tunnel-core" "$bin_path"
else
curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "$bin_path"
fi

if ! file "$bin_path" | grep -q "ELF 64-bit"; then
err "فایل دانلود شده باینری معتبر لینوکس نیست!"
exit 1
fi
chmod +x "$bin_path"
log "باینری سایفون با موفقیت مستقر شد."
}

generate_configs() {
log "تولید کانفیگ برای ${INSTANCE_COUNT} اینستنس سایفون..."
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
}

create_services() {
log "ساخت سرویس systemd سایفون..."
cat << EOF > /etc/systemd/system/psiphon@.service
[Unit]
Description=MAXNET Psiphon Instance %i
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
}

setup_web_panel() {
log "راه‌اندازی بک‌اند FastAPI و قالب داشبورد..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip -q
"$INSTALL_DIR/venv/bin/pip" install fastapi uvicorn[standard] jinja2 requests psutil websockets -q

cat << 'PYEOF' > "$INSTALL_DIR/web/app.py"
import os
import asyncio
import subprocess
import requests
import psutil
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, Form
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates

app = FastAPI(title="MAXNET5G Dashboard")
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
return JSONResponse({"status": "success", ", "ip": ip, "country": country}

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
proc = subprocess.run(f"/usr/local/bin/maxnet-ssl {domain}", shell=True, capture_output=True, text=True)
if proc.returncode == 0:
return JSONResponse({"status": "success", "message": f"دامنه {domain} متصل شد."})
return JSONResponse({"status": "error", "message": f"خطا در SSL: {proc.stderr}"}, status_code=500)

@app.websocket("/ws/logs/{service_name}")
async def stream_logs(websocket: WebSocket, service_name: str):
await websocket.accept()
proc = await asyncio.create.0">
<title>MAXNET5G | پنل مدیریت سایفون چند لوکیشن</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.rtl.min.css">
<style>
body { background: #0a0e17; color: #cbd5e1; font-family: system-ui, sans-serif; padding-bottom: 50px; }
.navbar { background: #131b2e; border-bottom: 2px solid #ef4444; }
.card { background: #131b2e; border: 1px solid #1f293d; border-radius: 10px; }
.badge-active { background: #10b981; }
.badge-inactive { background: #ef4444; }
.log-box { background: #030712; color: #10b981; font-family: monospace; font-size: 13px; height: 280px; overflow-y: scroll; padding: 15px; border-radius: 8px; border: 1px solid #1f2937; }
.btn-action { font-size: 12px; padding: 2px 8px; }
</style>
</head>
<body>
<nav class="navbar navbar-dark px-4 py-3 mb-4">
<span class="navbar-brand mb-0 h1 text-danger fw-bold">⚡ MAXNET5G PANEL <small class="text-secondary fs-6">by mohsenakbarinia</small></span>
<div>
<span class="badge bg-dark border border-secondary me-2">CPU: {{ cpu }}%</span>
<span class="badge bg-dark border border-secondary">RAM: {{ ram }}%</span>
</div>
</nav>
<div class="container-fluid px-4">
<div class="row mb-4">
<div class="col-md-5 mb-3">
<div class="card p-3">
<h5 class="text-white mb-3">🌐 اتصال سریع دامنه و SSL</h5>
<div class="input-group">
<input type="text" id="domainInput" class="form-control bg-dark text-white border-secondary" placeholder="sub.domain.com">
<button class="btn btn-danger" onclick="setDomain()">ثبت دامنه</button>
</div>
<div id="domainMsg" class="mt-2 text-info small"></div>
</div>
</div>
<div class="col-md-7">
<div class="card p-3">
<div class="d-flex justify-content-between align-items-center mb-2">
<h5 class="text-white mb-0">📜 لاگ زنده اینستنس‌ها</h5>
<select id="logSelector" class="form-select form-select-sm bg-dark text-white border-secondary w-auto" onchange="changeLogStream()">
<option value="psiphon@1">سایفون ۱</option>
<option value="psiphon-panel">پنل وب</option>
<option value="nginx">Nginx</option>
</select>
</div>
<div id="logContent" class="log-box">در حال اتصال...</div>
</div>
</div>
</div>
<div class="card p-3">
<h5 class="text-white mb-3">📋 اینستنس‌های سایفون (SOCKS5 Outbounds)</h5>
<div class="table-responsive">
<table class="table table-dark table-hover align-middle">
<thead>
<tr>
<th>#</th>
<th>پورت لوکال</th>
<th>وضعیت</th>
<th>IP خروجی</th>
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
<button class="btn btn-sm btn-outline-warning btn-action" onclick="controlInstance({{ item.id }}, 'restart')">ریست</button>
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
connectLog(document.getElementById("logSelector").value);
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
if (!domain) return alert("لطفاً دامنه را وارد کنید.");
const msg = document.getElementById("domainMsg");
msg.innerText = "در حال صدور SSL و اعمال روی Nginx...";
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

cat << 'SSLEOF' > /usr/local/bin/maxnet-ssl
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
chmod +x /usr/local/bin/maxnet-ssl

cat << EOF > /etc/systemd/system/psiphon-panel.service
[Unit]
Description=MAXNET5G Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/web
ExecStart=$INSTALL_DIR/venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

start_all_services() {
log "راه‌اندازی و فعال‌سازی سرویس‌ها..."
systemctl daemon-reload
systemctl enable --now psiphon-panel

for i in 1 2 3; do
systemctl enable --now psiphon@$i 2>/dev/null || true
done

ufw allow 8000/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true

IP=$(curl -s https://api.ipify.org || echo "IP_SERVER")
echo -e "\n${BOLD_GREEN}========================================================================${NC}"
echo -e "${BOLD_GREEN}✓ نصب MAXNET5G با موفقیت به اتمام رسید!${NC}"
echo -e "${CYAN}آدرس ورود به پنل: http://${IP}:8000${NC}"
echo -e "${BOLD_GREEN}========================================================================${NC}\n"
}

uninstall_all() {
warn "در حال پاکسازی کامل فایل‌ها و سرویس‌ها..."
systemctl stop psiphon-panel || true
systemctl disable psiphon-panel || true
for i in $(seq 1 $INSTANCE_COUNT); do
systemctl stop psiphon@$i || true
systemctl disable psiphon@$i || true
done
rm -rf "$INSTALL_DIR" /etc/systemd/system/psiphon@.service /etc/systemd/system/psiphon-panel.service /usr/local/bin/maxnet-ssl
systemctl daemon-reload
log "حذف با موفقیت کامل شد."
}

main_menu() {
show_banner
echo -e "${BOLD_GREEN}1)${NC} نصب و راه‌اندازی کامل MAXNET5G (Install)"
echo -e "${BOLD_GREEN}2)${NC} ری‌استارت سرویس‌ها (Restart All)"
echo -e "${BOLD_GREEN}3)${NC} حذف کامل اسکریپت (Uninstall)"
echo -e "${BOLD_GREEN}0)${NC} خروج (Exit)"
echo -e "${CYAN}========================================================================${NC}"
read -rp "لطفاً یک گزینه را انتخاب کنید [0-3]: " choice

case "$choice" in
1)
check_root
install_dependencies
setup_directories
download_psiphon_binary
generate_configs
create_services
setup_web_panel
start_all_services
;;
2)
log "ری‌استارت پنل..."
systemctl restart psiphon-panel
for i in 1 2 3; do systemctl restart psiphon@$i || true; done
log "ری‌استارت انجام شد."
;;
3)
uninstall_all
;;
0)
echo -e "${GREEN}خروج موفقیت‌آمیز.${NC}"
exit 0
;;
*)
err "گزینه نامعتبر است."
exit 1
;;
esac
}

main_menu
