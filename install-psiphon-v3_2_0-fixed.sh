#!/usr/bin/env bash
# ==============================================================================
#  Psiphon Core Lightweight Installer for Sanaei (3X-UI) Outbounds
#  Optimized for High Stability, Anti-Hang Watchdog, Low Latency & High Speed
# ==============================================================================

set -euo pipefail

# ----------------- Constants & Paths -----------------
INSTALL_DIR="/opt/psiphon"
BIN_PATH="${INSTALL_DIR}/bin/psiphon-tunnel-core"
CONF_DIR="/etc/psiphon"
DATA_DIR="/var/lib/psiphon"
WATCHDOG_SCRIPT="${INSTALL_DIR}/bin/psiphon-watchdog.sh"
LOG_DIR="/var/log"
PSIPHON_USER="psiphon"

# Psiphon Core Network Credentials
PROPAGATION_CHANNEL_ID="FFFFFFFFFFFFFFFF"
SPONSOR_ID="FFFFFFFFFFFFFFFF"
REMOTE_SERVER_LIST_URL="https://s3.amazonaws.com//psiphon/web/mjr4-p23r-puwl/server_list_compressed"
REMOTE_SERVER_LIST_KEY="MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM="

# Binary Mirrors
BIN_AMD64_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
BIN_AMD64_FALLBACK="https://github.com/ehsanecc/psiphon-builder/releases/latest/download/psiphon-tunnel-core-linux-x86_64"
BIN_ARM64_URL="https://github.com/ehsanecc/psiphon-builder/releases/latest/download/psiphon-tunnel-core-linux-arm64"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ----------------- Helper Functions -----------------
msg_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
msg_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
msg_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
msg_err()   { echo -e "${RED}[ERROR]${NC} $*"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_err "این اسکریپت باید با دسترسی روت اجرا شود: sudo -i"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_info "در حال نصب ابزارهای پیش‌نیاز (${missing[*]})..."
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}"
        msg_ok "پیش‌نیازها نصب شدند."
    fi
}

setup_system() {
    id -u "$PSIPHON_USER" &>/dev/null || useradd -r -s /usr/sbin/nologin "$PSIPHON_USER"
    mkdir -p "${INSTALL_DIR}/bin" "$CONF_DIR" "$DATA_DIR"
    chown -R "$PSIPHON_USER:$PSIPHON_USER" "$DATA_DIR" "$CONF_DIR"
    chmod 750 "$CONF_DIR" "$DATA_DIR"
}

download_binary() {
    if [[ -x "$BIN_PATH" ]]; then
        return 0
    fi

    setup_system
    local arch
    arch=$(uname -m)
    local target_url=""
    local fallback_url=""

    case "$arch" in
        x86_64|amd64)
            target_url="$BIN_AMD64_URL"
            fallback_url="$BIN_AMD64_FALLBACK"
            ;;
        aarch64|arm64)
            target_url="$BIN_ARM64_URL"
            fallback_url=""
            ;;
        *)
            msg_err "معماری پردازنده ($arch) پشتیبانی نمی‌شود."
            exit 1
            ;;
    esac

    msg_info "در حال دانلود هسته سایفون (${arch})..."
    local tmp_bin
    tmp_bin=$(mktemp)

    if ! curl -fL --connect-timeout 15 --max-time 180 -sS -o "$tmp_bin" "$target_url"; then
        if [[ -n "$fallback_url" ]]; then
            msg_warn "دانلود از سرور اصلی ناموفق بود، تلاش از سرور کمکی..."
            curl -fL --connect-timeout 15 --max-time 180 -sS -o "$tmp_bin" "$fallback_url"
        else
            msg_err "خطا در دانلود باینری سایفون!"
            rm -f "$tmp_bin"
            exit 1
        fi
    fi

    # Verify ELF binary
    if ! head -c 4 "$tmp_bin" | grep -q "ELF"; then
        msg_err "فایل دانلود شده یک فایل اجرایی معتبر لینوکس نیست."
        rm -f "$tmp_bin"
        exit 1
    fi

    mv "$tmp_bin" "$BIN_PATH"
    chmod 755 "$BIN_PATH"
    msg_ok "هسته سایفون با موفقیت نصب شد."
}

# ----------------- Systemd Template & Watchdog -----------------
install_systemd_template() {
    local service_file="/etc/systemd/system/psiphon@.service"
    cat <<EOF > "$service_file"
[Unit]
Description=Psiphon Tunnel Core for Region %i
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PSIPHON_USER}
Group=${PSIPHON_USER}
ExecStart=${BIN_PATH} -config ${CONF_DIR}/%i.json
Restart=always
RestartSec=3

# بهینه‌سازی کانکشن‌ها برای پنل ثنایی (جلوگیری از خطای Too Many Open Files)
LimitNOFILE=1048576
LimitNPROC=51200
TasksMax=infinity

# امن‌سازی سرویس بدون درگیر کردن فایروال
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${DATA_DIR}/%i

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

install_watchdog() {
    cat <<'EOF' > "$WATCHDOG_SCRIPT"
#!/usr/bin/env bash
# Psiphon Auto-Heal & Watchdog: Restarts frozen tunnels automatically
set -u

CONF_DIR="/etc/psiphon"
LOG_FILE="/var/log/psiphon-watchdog.log"

[[ -d "$CONF_DIR" ]] || exit 0

for conf in "$CONF_DIR"/*.json; do
    [[ -f "$conf" ]] || continue
    region=$(basename "$conf" .json)
    port=$(jq -r '.LocalSocksProxyPort // empty' "$conf" 2>/dev/null)
    [[ -n "$port" ]] || continue

    # تست سلامت پورت لوکال با حداکثر ۵ ثانیه مهلت
    status=$(curl -s -o /dev/null -w "%{http_code}" --socks5 "127.0.0.1:${port}" --connect-timeout 5 --max-time 7 "https://1.1.1.1" 2>/dev/null || echo "000")

    if [[ "$status" == "000" ]]; then
        # تلاش مجدد جهت جلوگیری از ریست اشتباه در نوسانات لحظه‌ای
        sleep 2
        status_retry=$(curl -s -o /dev/null -w "%{http_code}" --socks5 "127.0.0.1:${port}" --connect-timeout 5 --max-time 7 "https://1.1.1.1" 2>/dev/null || echo "000")
        if [[ "$status_retry" == "000" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tunnel $region on port $port is DEAD. Restarting..." >> "$LOG_FILE"
            systemctl restart "psiphon@${region}.service" 2>&1 | tee -a "$LOG_FILE"
        fi
    fi
done
EOF
    chmod 755 "$WATCHDOG_SCRIPT"

    # Watchdog Service & Timer
    cat <<EOF > /etc/systemd/system/psiphon-watchdog.service
[Unit]
Description=Psiphon Health Monitor & Watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_SCRIPT}
EOF

    cat <<EOF > /etc/systemd/system/psiphon-watchdog.timer
[Unit]
Description=Run Psiphon Watchdog every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now psiphon-watchdog.timer &>/dev/null
    msg_ok "سیستم مانیتورینگ خودکار (Watchdog) فعال شد."
}

# ----------------- TCP & BBR Speed Tuning -----------------
apply_network_tuning() {
    msg_info "در حال فعال‌سازی الگوریتم BBR و بهینه‌سازی بافر TCP..."
    cat <<'EOF' > /etc/sysctl.d/99-psiphon-tuning.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 2097152
EOF
    sysctl --system &>/dev/null || true
    msg_ok "BBR و تنظیمات بهینه‌سازی شبکه با موفقیت اعمال شدند."
}

# ----------------- Config Generator -----------------
create_instance_config() {
    local region="$1"
    local socks_port="$2"
    local http_port="$3"
    local conf_file="${CONF_DIR}/${region}.json"
    local instance_data_dir="${DATA_DIR}/${region}"

    mkdir -p "$instance_data_dir"
    chown -R "$PSIPHON_USER:$PSIPHON_USER" "$instance_data_dir"

    # آماده‌سازی متغیر EgressRegion (در حالت AUTO بدون ریجن اجباری)
    local region_arg
    if [[ "$region" == "AUTO" ]]; then
        region_arg="null"
    else
        region_arg="\"$region\""
    fi

    # ایجاد فایل کانفیگ بهینه شده
    cat <<EOF > "$conf_file"
{
  "PropagationChannelId": "${PROPAGATION_CHANNEL_ID}",
  "SponsorId": "${SPONSOR_ID}",
  "RemoteServerListUrl": "${REMOTE_SERVER_LIST_URL}",
  "RemoteServerListSignaturePublicKey": "${REMOTE_SERVER_LIST_KEY}",
  "EgressRegion": ${region_arg},
  "DataRootDirectory": "${instance_data_dir}",
  "ListenInterface": "127.0.0.1",
  "LocalSocksProxyPort": ${socks_port},
  "LocalHttpProxyPort": ${http_port},
  "DisableLocalSocksProxy": false,
  "DisableLocalHTTPProxy": false,
  "EstablishTunnelTimeoutSeconds": 15,
  "EmitDiagnosticNotices": false
}
EOF

    chown "$PSIPHON_USER:$PSIPHON_USER" "$conf_file"
    chmod 640 "$conf_file"
}

# ----------------- Management Actions -----------------
add_location() {
    download_binary
    install_systemd_template
    install_watchdog

    echo ""
    echo -e "${BOLD}${CYAN}لوکیشن‌های پیشنهادی با کمترین پینگ و بالاترین سرعت:${NC}"
    echo -e "  ${GREEN}DE${NC} (آلمان - بهترین پینگ به ایران)"
    echo -e "  ${GREEN}NL${NC} (هلند - پایداری و سرعت فوق‌العاده)"
    echo -e "  ${GREEN}TR${NC} (ترکیه - نزدیک‌ترین لوکیشن فیزیکی)"
    echo -e "  ${GREEN}FR${NC} (فرانسه)  |  ${GREEN}GB${NC} (انگلستان)  |  ${GREEN}FI${NC} (فنلاند)"
    echo -e "  ${GREEN}US${NC} (آمریکا - برای دسترسی به هوش مصنوعی و سرویس‌های خاص)"
    echo -e "  ${GREEN}AUTO${NC} (انتخاب خودکار کمترین پینگ توسط سایفون)"
    echo ""

    read -rp "کد کشور مورد نظر را وارد کنید (پیش‌فرض: DE): " input_region
    local region
    region=$(echo "${input_region:-DE}" | tr '[:lower:]' '[:upper:]')

    # بررسی و پیشنهاد پورت خالی
    local default_socks=2080
    local default_http=2081
    while ss -tln | grep -qE ":(${default_socks}|${default_http})\b"; do
        default_socks=$((default_socks + 2))
        default_http=$((default_http + 2))
    done

    read -rp "پورت SOCKS5 برای ثنایی (پیش‌فرض: $default_socks): " input_socks
    local socks_port="${input_socks:-$default_socks}"

    read -rp "پورت HTTP (پیش‌فرض: $default_http): " input_http
    local http_port="${input_http:-$default_http}"

    if ss -tln | grep -qE ":(${socks_port}|${http_port})\b"; then
        msg_err "یک یا هر دو پورت انتخابی هم‌اکنون توسط پردازه دیگری در حال استفاده است!"
        return 1
    fi

    msg_info "در حال ساخت کانفیگ و استارت لوکیشن $region..."
    create_instance_config "$region" "$socks_port" "$http_port"

    systemctl enable --now "psiphon@${region}.service"
    msg_ok "سرویس psiphon@${region} با موفقیت راه‌اندازی شد."

    echo ""
    msg_info "در حال اتصال به سرورهای سایفون (صبر کنید)..."
    local connected=false
    for ((i=1; i<=15; i++)); do
        sleep 2
        local out_ip
        out_ip=$(curl -s --socks5 "127.0.0.1:${socks_port}" --connect-timeout 4 "https://api.ipify.org" 2>/dev/null || echo "")
        if [[ -n "$out_ip" ]]; then
            connected=true
            echo ""
            echo -e "${GREEN}=====================================================${NC}"
            echo -e "${BOLD}${GREEN}✔ لوکیشن ${region} با موفقیت آنلاین شد!${NC}"
            echo -e "  • آی‌پی خارجی متصل شده: ${CYAN}${out_ip}${NC}"
            echo -e "  • آدرس SOCKS5 لوکال:     ${YELLOW}127.0.0.1:${socks_port}${NC}"
            echo -e "  • آدرس HTTP لوکال:       ${YELLOW}127.0.0.1:${http_port}${NC}"
            echo -e "${GREEN}=====================================================${NC}"
            break
        fi
        echo -n "."
    done

    if [[ "$connected" != "true" ]]; then
        echo ""
        msg_warn "سایفون هنوز در حال استقرار تونل است. وضعیت تا چند لحظه دیگر پایدار خواهد شد."
    fi

    print_sanaei_outbound "$region" "$socks_port"
}

print_sanaei_outbound() {
    local region="$1"
    local port="$2"
    echo ""
    echo -e "${BOLD}${CYAN}تنظیمات Outbound برای پنل سنایی (3X-UI):${NC}"
    echo -e "در پنل ثنایی به بخش ${BOLD}تنظیمات پنل > تنظیمات Xray > Outbounds (خروجی‌ها)${NC} بروید و خروجی زیر را اضافه کنید:"
    echo ""
    cat <<EOF
{
  "tag": "psiphon-${region}",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": ${port}
      }
    ]
  }
}
EOF
    echo ""
    echo -e "${CYAN}سپس در بخش Routing (مسیریابی)، می‌توانید ترافیک دلخواه خود را به این تگ ارسال کنید.${NC}"
}

list_instances() {
    echo ""
    echo -e "${BOLD}${CYAN}================== لیست لوکیشن‌های فعال سایفون ==================${NC}"
    printf "%-10s %-12s %-10s %-18s %-10s\n" "لوکیشن" "پورت SOCKS" "پورت HTTP" "آی‌پی متصل" "وضعیت"
    echo "------------------------------------------------------------------"

    local count=0
    for conf in "$CONF_DIR"/*.json; do
        [[ -f "$conf" ]] || continue
        count=$((count + 1))
        local region
        region=$(basename "$conf" .json)
        local socks_p
        socks_p=$(jq -r '.LocalSocksProxyPort' "$conf")
        local http_p
        http_p=$(jq -r '.LocalHttpProxyPort' "$conf")

        local status_icon="${RED}خاموش${NC}"
        local pub_ip="---"

        if systemctl is-active --quiet "psiphon@${region}.service"; then
            pub_ip=$(curl -s --socks5 "127.0.0.1:${socks_p}" --connect-timeout 3 --max-time 5 "https://api.ipify.org" 2>/dev/null || echo "در حال اتصال...")
            if [[ "$pub_ip" != "در حال اتصال..." && -n "$pub_ip" ]]; then
                status_icon="${GREEN}فعال ✔${NC}"
            else
                status_icon="${YELLOW}متصل‌نشده ⌛${NC}"
            fi
        fi

        printf "%-10s %-12s %-10s %-18s " "$region" "$socks_p" "$http_p" "$pub_ip"
        echo -e "$status_icon"
    done

    if [[ $count -eq 0 ]]; then
        echo -e "${YELLOW}هیچ لوکیشنی هنوز نصب نشده است.${NC}"
    fi
    echo -e "${CYAN}=================================================================${NC}"
}

test_latency() {
    echo ""
    msg_info "در حال سنجش پینگ و سرعت لوکیشن‌های فعال..."
    for conf in "$CONF_DIR"/*.json; do
        [[ -f "$conf" ]] || continue
        local region
        region=$(basename "$conf" .json)
        local socks_p
        socks_p=$(jq -r '.LocalSocksProxyPort' "$conf")

        echo -n -e "تست ${BOLD}${region}${NC} (Port: ${socks_p}) -> "
        local res
        res=$(curl -o /dev/null -s -w "%{time_total}|%{http_code}" --socks5 "127.0.0.1:${socks_p}" --connect-timeout 5 --max-time 8 "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null || echo "0|000")
        local latency
        latency=$(echo "$res" | cut -d'|' -f1)
        local code
        code=$(echo "$res" | cut -d'|' -f2)

        if [[ "$code" == "200" ]]; then
            local ms
            ms=$(awk "BEGIN {printf \"%.0f\", $latency * 1000}")
            echo -e "${GREEN}پاسخ داد (${ms}ms) - وضعیت: عالی${NC}"
        else
            echo -e "${RED}پاسخ نداد (Timeout یا قطع بودن تونل)${NC}"
        fi
    done
}

restart_all() {
    msg_info "در حال راه‌اندازی مجدد تمام سرویس‌های سایفون..."
    for conf in "$CONF_DIR"/*.json; do
        [[ -f "$conf" ]] || continue
        local region
        region=$(basename "$conf" .json)
        systemctl restart "psiphon@${region}.service"
        msg_ok "سرویس $region ریستارت شد."
    done
    msg_ok "تمام سرویس‌ها با موفقیت بازنشانی شدند."
}

remove_location() {
    list_instances
    read -rp "نام لوکیشن مورد نظر برای حذف را وارد کنید (مثال: DE): " del_region
    del_region=$(echo "$del_region" | tr '[:lower:]' '[:upper:]')

    if [[ -f "${CONF_DIR}/${del_region}.json" ]]; then
        systemctl stop "psiphon@${del_region}.service" || true
        systemctl disable "psiphon@${del_region}.service" || true
        rm -f "${CONF_DIR}/${del_region}.json"
        rm -rf "${DATA_DIR}/${del_region}"
        msg_ok "لوکیشن $del_region با موفقیت حذف شد."
    else
        msg_err "لوکیشن $del_region پیدا نشد."
    fi
}

uninstall_all() {
    read -rp "آیا از حذف کامل سایفون و تمام لوکیشن‌ها اطمینان دارید؟ (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        msg_info "در حال حذف کامل..."
        systemctl stop 'psiphon@*.service' 2>/dev/null || true
        systemctl disable 'psiphon@*.service' 2>/dev/null || true
        systemctl stop psiphon-watchdog.timer 2>/dev/null || true
        systemctl disable psiphon-watchdog.timer 2>/dev/null || true

        rm -f /etc/systemd/system/psiphon@.service
        rm -f /etc/systemd/system/psiphon-watchdog.*
        rm -rf "$INSTALL_DIR" "$CONF_DIR" "$DATA_DIR"
        rm -f /var/log/psiphon-watchdog.log
        systemctl daemon-reload
        msg_ok "سایفون به طور کامل از روی سرور حذف شد."
        exit 0
    fi
}

# ----------------- Interactive Menu -----------------
show_menu() {
    clear
    echo -e "${BOLD}${CYAN}======================================================${NC}"
    echo -e "${BOLD}${CYAN}   نصب‌کننده بهینه سایفون مخصوص پنل ثنایی (3X-UI)   ${NC}"
    echo -e "${BOLD}${CYAN}   سبک، بدون ابزارهای اضافی، با واچ‌داگ ضدقطعی و BBR   ${NC}"
    echo -e "${BOLD}${CYAN}======================================================${NC}"
    echo -e " ${GREEN}1)${NC} افزودن / نصب لوکیشن جدید (آلمان، هلند، ترکیه و...)"
    echo -e " ${GREEN}2)${NC} مشاهده لوکیشن‌ها و پورت‌های فعال (SOCKS5 / HTTP)"
    echo -e " ${GREEN}3)${NC} تست زنده پینگ و پایداری لوکیشن‌ها"
    echo -e " ${GREEN}4)${NC} ریستارت تمام سرویس‌های سایفون"
    echo -e " ${GREEN}5)${NC} حذف یک لوکیشن"
    echo -e " ${GREEN}6)${NC} اعمال بهینه‌سازی شبکه و فعال‌سازی BBR"
    echo -e " ${GREEN}7)${NC} مشاهده لاگ مانیتورینگ ضدقطعی (Watchdog)"
    echo -e " ${RED}8)${NC} حذف کامل سایفون از سرور"
    echo -e " ${YELLOW}0)${NC} خروج"
    echo -e "${CYAN}------------------------------------------------------${NC}"
    read -rp "لطفاً یک گزینه را انتخاب کنید [0-8]: " choice

    case "$choice" in
        1) add_location ;;
        2) list_instances ;;
        3) test_latency ;;
        4) restart_all ;;
        5) remove_location ;;
        6) apply_network_tuning ;;
        7) [[ -f /var/log/psiphon-watchdog.log ]] && tail -n 25 /var/log/psiphon-watchdog.log || msg_info "هنوز لاگی ثبت نشده است." ;;
        8) uninstall_all ;;
        0) exit 0 ;;
        *) msg_err "گزینه نامعتبر است." ;;
    esac

    echo ""
    read -rp "برای بازگشت به منو دکمه Enter را بزنید..." _
    show_menu
}

# ----------------- Main Entrypoint -----------------
main() {
    check_root
    check_dependencies

    if [[ $# -gt 0 ]]; then
        case "$1" in
            --add)
                add_location
                ;;
            --list)
                list_instances
                ;;
            --test)
                test_latency
                ;;
            --restart)
                restart_all
                ;;
            --bbr)
                apply_network_tuning
                ;;
            *)
                echo "Usage: $0 [--add | --list | --test | --restart | --bbr]"
                exit 1
                ;;
        esac
    else
        show_menu
    fi
}

main "$@"
