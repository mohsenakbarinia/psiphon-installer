#!/usr/bin/env bash
#===============================================================================
#  Psiphon Multi-Region Installer — v5.2
#  نصب ۲۰ نمونه سایفون + Xray روی یک سرور (Multi-Region)
#  ورژن: v5.2 (اصلاح سینتکس، امنیت شبکه و تفکیک دایرکتوری‌ها)
#===============================================================================

set -Eeuo pipefail

#--------------------------- متغیرهای کلی --------------------------------------
VERSION="v5.2"
LOG_FILE="/var/log/psiphon-installer.log"
INSTALL_DIR="/opt/psiphon-multi-region"
PSIPHON_USER="psiphon"
INSTANCE_COUNT=20
LOCAL_IP_BASE="127.20.0"        # آدرس‌ها: 127.20.0.1 تا 127.20.0.20
SOCKS_BASE_PORT=10800           # پورت SOCKS داخلی psiphon: 10800-10819
INBOUND_BASE_PORT=20000         # پورت ورودی Xray: 20000-20019
PSIPHON_BIN_URL="https://github.com/Psiphon-Labs/psiphon-tunnel-core/releases/latest/download/psiphon-tunnel-core-linux-amd64"
XRAY_BIN_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
LOCK_FILE="/var/run/psiphon-installer.lock"
SSH_PORT="${SSH_PORT:-22}"

#--------------------------- رنگ‌ها ---------------------------------------------
if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
    RED=$(tput setaf 1 2>/dev/null || true)
    GREEN=$(tput setaf 2 2>/dev/null || true)
    YELLOW=$(tput setaf 3 2>/dev/null || true)
    CYAN=$(tput setaf 6 2>/dev/null || true)
    BOLD=$(tput bold 2>/dev/null || true)
    RESET=$(tput sgr0 2>/dev/null || true)
else
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
fi

#--------------------------- لاگ‌گیری ------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/psiphon-installer.log"

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] ${msg}" >> "$LOG_FILE" 2>/dev/null || true
}

info()    { echo -e "${CYAN}${BOLD}[اطلاعات]${RESET} $*"; log "INFO" "$*"; }
success() { echo -e "${GREEN}${BOLD}[موفق]${RESET} $*"; log "INFO" "$*"; }
warn()    { echo -e "${YELLOW}${BOLD}[هشدار]${RESET} $*"; log "WARN" "$*"; }

err() {
    echo -e "${RED}${BOLD}[خطا]${RESET} $*" >&2
    log "ERROR" "$*"
    exit 1
}

trap 'err "اسکریپت در خط $LINENO با کد خروج $? متوقف شد. لاگ کامل: $LOG_FILE"' ERR

#--------------------------- قفل اجرا (flock) ----------------------------------
exec 200>"$LOCK_FILE" 2>/dev/null || true
if flock -n 200 2>/dev/null; then
    log "INFO" "قفل نصب با موفقیت گرفته شد."
else
    err "یک نمونه دیگر از این نصاب در حال اجراست. فایل قفل: $LOCK_FILE"
fi

#--------------------------- پیش‌نیازها ----------------------------------------
ROOT_CHECK() {
    [ "$(id -u)" -eq 0 ] || err "این اسکریپت باید با کاربر روت اجرا شود. (sudo bash $0)"
}

SSH_SAFETY_CHECK() {
    info "بررسی وضعیت سرویس SSH..."
    if ! systemctl is-active --quiet sshd && ! systemctl is-active --quiet ssh; then
        warn "سرویس SSH فعال نیست یا نام متفاوتی دارد. لطفاً دقت فرمایید."
    fi

    if command -v ss >/dev/null 2>&1; then
        if ! ss -tln | grep -qE "[:.]${SSH_PORT}[[:space:]]"; then
            warn "پورت SSH (${SSH_PORT}) در حالت Listen پیدا نشد؛ از پورت صحیح اطمینان حاصل کنید."
        else
            success "پورت SSH (${SSH_PORT}) در حال شنود است."
        fi
    fi
}

INSTALL_DEPS() {
    info "به‌روزرسانی مخازن و نصب پیش‌نیازها ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >> "$LOG_FILE" 2>&1 || warn "apt-get update با خطا مواجه شد؛ ادامه می‌دهیم."
    apt-get install -y curl unzip ca-certificates jq iproute2 ufw >> "$LOG_FILE" 2>&1 \
        || err "نصب پیش‌نیازها ناموفق بود. جزئیات در $LOG_FILE"
    success "پیش‌نیازها با موفقیت نصب شدند."
}

#--------------------------- دانلود باینری‌ها ----------------------------------
DOWNLOAD_PSIPHON() {
    info "بررسی و دانلود psiphon-tunnel-core..."
    mkdir -p "$INSTALL_DIR/bin"
    if [ -x "$INSTALL_DIR/bin/psiphon-tunnel-core" ]; then
        success "باینری psiphon-tunnel-core از قبل موجود است؛ از دانلود مجدد صرف‌نظر شد."
        return 0
    fi
    local tmpf="$INSTALL_DIR/bin/.psiphon-tunnel-core.tmp"
    for attempt in 1 2 3; do
        if curl -fL --connect-timeout 20 --retry 2 -o "$tmpf" "$PSIPHON_BIN_URL" >> "$LOG_FILE" 2>&1; then
            chmod +x "$tmpf" && mv -f "$tmpf" "$INSTALL_DIR/bin/psiphon-tunnel-core"
            success "psiphon-tunnel-core دانلود و مستقر شد."
            return 0
        fi
        warn "تلاش ${attempt}/3 برای دانلود psiphon-tunnel-core ناموفق بود."
        sleep 3
    done
    err "دانلود psiphon-tunnel-core پس از ۳ تلاش ناموفق بود."
}

DOWNLOAD_XRAY() {
    if [ "${WITH_XRAY:-0}" != "1" ]; then
        warn "نصب Xray غیرفعال است (در صورت نیاز از پارامتر --with-xray استفاده کنید)."
        XRAY_ENABLED=0
        return 0
    fi
    XRAY_ENABLED=1
    info "بررسی و دانلود Xray..."
    mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/xray-tmp"
    if [ -x "$INSTALL_DIR/bin/xray" ]; then
        success "باینری Xray از قبل موجود است."
        rm -rf "$INSTALL_DIR/xray-tmp"
        return 0
    fi
    local zipf="$INSTALL_DIR/xray-tmp/Xray.zip"
    for attempt in 1 2 3; do
        if curl -fL --connect-timeout 20 --retry 2 -o "$zipf" "$XRAY_BIN_URL" >> "$LOG_FILE" 2>&1; then
            unzip -o "$zipf" xray -d "$INSTALL_DIR/xray-tmp" >> "$LOG_FILE" 2>&1 \
                && mv -f "$INSTALL_DIR/xray-tmp/xray" "$INSTALL_DIR/bin/xray" \
                && chmod +x "$INSTALL_DIR/bin/xray"
            rm -rf "$INSTALL_DIR/xray-tmp"
            success "باینری Xray دانلود و نصب شد."
            return 0
        fi
        warn "تلاش ${attempt}/3 برای دانلود Xray ناموفق بود."
        sleep 3
    done
    err "دانلود Xray پس از ۳ تلاش ناموفق بود."
}

#--------------------------- کاربر سیستمی --------------------------------------
CREATE_USER() {
    if id "$PSIPHON_USER" &>/dev/null; then
        info "کاربر سیستمی '${PSIPHON_USER}' از قبل وجود دارد."
    else
        useradd --system --no-create-home --shell /usr/sbin/nologin "$PSIPHON_USER" \
            || err "ایجاد کاربر سیستمی '${PSIPHON_USER}' ناموفق بود."
        success "کاربر سیستمی '${PSIPHON_USER}' ساخته شد."
    fi
    chown -R "${PSIPHON_USER}:${PSIPHON_USER}" "$INSTALL_DIR" 2>/dev/null || true
}

#--------------------------- کانفیگ psiphon ------------------------------------
GEN_PSIPHON_CONFIGS() {
    info "تولید فایل‌های کانفیگ برای ${INSTANCE_COUNT} نمونه psiphon..."
    mkdir -p "$INSTALL_DIR/configs"

    for i in $(seq 1 "$INSTANCE_COUNT"); do
        local inst_data_dir="$INSTALL_DIR/data/instance-${i}"
        mkdir -p "$inst_data_dir"
        chown -R "${PSIPHON_USER}:${PSIPHON_USER}" "$inst_data_dir"

        local cp_id pc_id sp_id
        cp_id="CP$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
        pc_id="PC$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
        sp_id="SP$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
        local socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
        local cfg="$INSTALL_DIR/configs/psiphon-${i}.conf"

        cat <<EOF > "$cfg"
{
    "ClientPlatform": "${cp_id}",
    "PropagationChannelId": "${pc_id}",
    "SponsorId": "${sp_id}",
    "DataRootDirectory": "${inst_data_dir}",
    "LocalHttpProxyPort": $(( socks_port + 100 )),
    "LocalSocksProxyPort": ${socks_port},
    "EgressRegion": "",
    "EnableRemoteAPIList": true,
    "Parameters": {}
}
EOF
        chown "${PSIPHON_USER}:${PSIPHON_USER}" "$cfg"
        chmod 640 "$cfg"
    done
    success "کانفیگ‌های سایفون با پوشه دیتای مجزا تولید شدند."
}

#--------------------------- سرویس‌های systemd psiphon --------------------------
GEN_PSIPHON_SERVICES() {
    info "تولید فایل‌های سرویس systemd برای Psiphon..."
    mkdir -p /etc/systemd/system
    for i in $(seq 1 "$INSTANCE_COUNT"); do
        cat <<EOF > "/etc/systemd/system/psiphon-${i}.service"
[Unit]
Description=Psiphon Tunnel Core Instance ${i} (${VERSION})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PSIPHON_USER}
WorkingDirectory=${INSTALL_DIR}/data/instance-${i}
ExecStart=${INSTALL_DIR}/bin/psiphon-tunnel-core -config ${INSTALL_DIR}/configs/psiphon-${i}.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    done
    success "سرویس‌های systemd برای تمام نمونه‌های Psiphon ایجاد شدند."
}

#--------------------------- کانفیگ و سرویس Xray -------------------------------
GEN_XRAY_CONFIGS_SERVICES() {
    if [ "${XRAY_ENABLED:-0}" != "1" ]; then
        return 0
    fi
    info "تولید کانفیگ و سرویس‌های Xray..."
    mkdir -p "$INSTALL_DIR/xray"
    for i in $(seq 1 "$INSTANCE_COUNT"); do
        local listen_ip in_port socks_port
        listen_ip="${LOCAL_IP_BASE}.${i}"
        in_port=$(( INBOUND_BASE_PORT + i - 1 ))
        socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
        local xcfg="$INSTALL_DIR/xray/config-${i}.json"

        cat <<EOF > "$xcfg"
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "listen": "${listen_ip}",
        "port": ${in_port},
        "protocol": "socks",
        "settings": { "auth": "noauth", "udp": true },
        "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }],
    "outbounds": [{
        "protocol": "socks",
        "settings": { "servers": [{
            "address": "127.0.0.1",
            "port": ${socks_port}
        }] }
    }]
}
EOF
        chown "${PSIPHON_USER}:${PSIPHON_USER}" "$xcfg"

        cat <<EOF > "/etc/systemd/system/xray-${i}.service"
[Unit]
Description=Xray Instance ${i} -> Psiphon Instance ${i} (${VERSION})
After=psiphon-${i}.service
Requires=psiphon-${i}.service

[Service]
Type=simple
User=${PSIPHON_USER}
ExecStart=${INSTALL_DIR}/bin/xray run -config ${xcfg}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    done
    success "کانفیگ و سرویس‌های Xray ساخته شدند."
}

#--------------------------- افزودن IP به Loopback (روش ۱۰۰٪ امن) --------------
CONFIG_LOOPBACK_IPS() {
    info "پیکربندی آدرس‌های لوپ‌بک (${LOCAL_IP_BASE}.1 تا ${LOCAL_IP_BASE}.${INSTANCE_COUNT}) بدون خطر قطعی شبکه..."
    
    # فعال‌سازی آنی آی‌پی‌ها روی اینترفیس lo
    for i in $(seq 1 "$INSTANCE_COUNT"); do
        ip addr add "${LOCAL_IP_BASE}.${i}/32" dev lo 2>/dev/null || true
    done

    # ساخت سرویس دائمی برای بقا بعد از ریبوت (جایگزین امن Netplan)
    cat <<EOF > /etc/systemd/system/psiphon-loopback-ips.service
[Unit]
Description=Assign Loopback IP Aliases for Psiphon Multi-Region
DefaultDependencies=no
After=systemd-modules-load.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "for i in \$(seq 1 ${INSTANCE_COUNT}); do ip addr add ${LOCAL_IP_BASE}.\$i/32 dev lo 2>/dev/null || true; done"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now psiphon-loopback-ips.service >> "$LOG_FILE" 2>&1
    success "آدرس‌های لوپ‌بک به‌طور ایمن پیکربندی و دائمی شدند."
}

#--------------------------- UFW -----------------------------------------------
CONFIG_UFW() {
    if ! command -v ufw >/dev/null 2>&1; then
        warn "ufw فعال یا نصب نیست؛ از تنظیم فایروال صرف‌نظر شد."
        return 0
    fi
    info "بررسی قوانین فایروال UFW..."
    ufw allow "${SSH_PORT}/tcp" >> "$LOG_FILE" 2>&1 || true
    ufw allow "${INBOUND_BASE_PORT}:$(( INBOUND_BASE_PORT + INSTANCE_COUNT - 1 ))/tcp" >> "$LOG_FILE" 2>&1 || true
    ufw allow "${INBOUND_BASE_PORT}:$(( INBOUND_BASE_PORT + INSTANCE_COUNT - 1 ))/udp" >> "$LOG_FILE" 2>&1 || true
    success "پورت SSH (${SSH_PORT}) و بازه پورت‌های ورودی باز شدند."
}

#--------------------------- فعال‌سازی سرویس‌ها ---------------------------------
ENABLE_SERVICES() {
    info "اجرای systemctl daemon-reload و فعال‌سازی سرویس‌ها..."
    systemctl daemon-reload || err "systemctl daemon-reload ناموفق بود."

    for i in $(seq 1 "$INSTANCE_COUNT"); do
        systemctl enable --now "psiphon-${i}.service" >> "$LOG_FILE" 2>&1 \
            || warn "فعال‌سازی psiphon-${i} ناموفق بود."
        if [ "${XRAY_ENABLED:-0}" = "1" ]; then
            systemctl enable --now "xray-${i}.service" >> "$LOG_FILE" 2>&1 \
                || warn "فعال‌سازی xray-${i} ناموفق بود."
        fi
    done
    success "دستور فعال‌سازی تمام سرویس‌ها ارسال شد."
}

#--------------------------- راستی‌آزمایی --------------------------------------
VERIFY_SERVICES() {
    info "بررسی وضعیت راه‌اندازی (۱۰ تلاش، هر ۳ ثانیه)..."
    for attempt in $(seq 1 10); do
        local psiphon_failed=0 xray_failed=0
        for i in $(seq 1 "$INSTANCE_COUNT"); do
            systemctl is-active --quiet "psiphon-${i}" || psiphon_failed=$((psiphon_failed+1))
            if [ "${XRAY_ENABLED:-0}" = "1" ]; then
                systemctl is-active --quiet "xray-${i}" || xray_failed=$((xray_failed+1))
            fi
        done
        if [ "$psiphon_failed" -eq 0 ] && [ "$xray_failed" -eq 0 ]; then
            success "همه ${INSTANCE_COUNT} سرویس Psiphon $( [ "${XRAY_ENABLED:-0}" = "1" ] && echo "و Xray " )با موفقیت فعال شدند."
            return 0
        fi
        sleep 3
    done
    warn "برخی از سرویس‌ها هنوز بالا نیامده‌اند؛ لطفاً وضعیت را با 'systemctl status psiphon-*' بررسی کنید."
}

#--------------------------- خلاصه نهایی ---------------------------------------
FINAL_SUMMARY() {
    local server_ip
    server_ip="$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "YOUR_SERVER_IP")"

    echo ""
    echo -e "${BOLD}${CYAN}============================================================${RESET}"
    echo -e "${BOLD}${CYAN}  خلاصه نصب Psiphon Multi-Region ${VERSION}${RESET}"
    echo -e "${BOLD}${CYAN}============================================================${RESET}"
    printf "${BOLD}  %-3s | %-14s | %-10s | %-12s | %-8s${RESET}\n" "ردیف" "IP لوکال" "پورت ورودی" "SOCKS داخلی" "وضعیت"
    echo "  -------------------------------------------------------------"
    for i in $(seq 1 "$INSTANCE_COUNT"); do
        local ip in_port socks_port status
        ip="${LOCAL_IP_BASE}.${i}"
        in_port=$(( INBOUND_BASE_PORT + i - 1 ))
        socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
        if systemctl is-active --quiet "psiphon-${i}"; then
            status="${GREEN}فعال${RESET}"
        else
            status="${RED}غیرفعال${RESET}"
        fi
        printf "  %-4s | %-14s | %-10s | %-12s | %b\n" "$i" "$ip" "$in_port" "$socks_port" "$status"
    done
    echo -e "${BOLD}${CYAN}============================================================${RESET}"
    echo -e "  📌 اتصال نمونه ۱: socks5://${server_ip}:${SOCKS_BASE_PORT}"
    echo -e "  📂 مسیر نصب: ${INSTALL_DIR}"
    echo -e "  📋 فایل لاگ: ${LOG_FILE}"
    echo -e "${BOLD}${CYAN}============================================================${RESET}"
    success "نصب نسخه ${VERSION} به پایان رسید."
}

#--------------------------- پارامترهای ورودی ----------------------------------
XRAY_ENABLED=0
WITH_XRAY=0
for arg in "$@"; do
    case "$arg" in
        --with-xray) WITH_XRAY=1 ;;
        -h|--help)
            echo "نحوه استفاده: sudo bash $0 [--with-xray]"
            exit 0 ;;
        *) warn "پارامتر ناشناخته: $arg" ;;
    esac
done

#--------------------------- اجرا ----------------------------------------------
main() {
    log "INFO" "===== شروع نصب Psiphon Multi-Region ${VERSION} ====="
    info "شروع راه‌اندازی Psiphon Multi-Region ${VERSION}..."
    ROOT_CHECK
    SSH_SAFETY_CHECK
    INSTALL_DEPS
    mkdir -p "$INSTALL_DIR"
    DOWNLOAD_PSIPHON
    DOWNLOAD_XRAY
    CREATE_USER
    GEN_PSIPHON_CONFIGS
    GEN_PSIPHON_SERVICES
    GEN_XRAY_CONFIGS_SERVICES
    CONFIG_LOOPBACK_IPS
    CONFIG_UFW
    ENABLE_SERVICES
    VERIFY_SERVICES
    FINAL_SUMMARY
    log "INFO" "===== پایان نصب ${VERSION} ====="
}

main "$@"
