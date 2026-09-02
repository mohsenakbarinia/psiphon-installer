#!/usr/bin/env bash
# =============================================================================
# Psiphon Multi-Region Installer v5.1
# Ubuntu 24.04 x86_64 | /opt/psiphon-multi-region
# =============================================================================
set -euo pipefail

# ─── رنگ‌ها ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { err "$*"; exit 1; }

# ─── تنظیمات پایه ─────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/psiphon-multi-region"
SYS_USER="psiphon"
INSTANCES=20
BASE_SOCKS_PORT=10800
BASE_INBOUND_PORT=20000
LOCAL_IP="127.20.0.1"

PSIPHON_BIN_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"

# ─── بررسی root ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "این اسکریپت باید با root اجرا شود."

# ─── رفع قفل dpkg ─────────────────────────────────────────────────────────────
release_dpkg_locks() {
    info "بررسی و رفع قفل‌های dpkg/apt..."
    # کشتن پروسه‌های apt/dpkg در حال اجرا
    local pids
    pids=$(lsof /var/lib/dpkg/lock-frontend 2>/dev/null | awk 'NR>1{print $2}' || true)
    [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null || true

    pids=$(lsof /var/lib/apt/lists/lock 2>/dev/null | awk 'NR>1{print $2}' || true)
    [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null || true

    # حذف فایل‌های قفل
    rm -f /var/lib/dpkg/lock-frontend \
          /var/lib/dpkg/lock \
          /var/cache/apt/archives/lock \
          /var/lib/apt/lists/lock

    # رفع مشکل dpkg نیمه‌کاره
    dpkg --configure -a --force-confdef --force-confold 2>/dev/null || true
    ok "قفل‌های dpkg برطرف شد."
}

# ─── نصب پیش‌نیازها ──────────────────────────────────────────────────────────
install_deps() {
    info "نصب پیش‌نیازها..."
    release_dpkg_locks

    # صبر برای اتمام apt خودکار سیستم
    local max_wait=60
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if (( waited >= max_wait )); then
            release_dpkg_locks
            break
        fi
        warn "منتظر آزاد شدن dpkg ($waited/$max_wait ثانیه)..."
        sleep 2
        (( waited+=2 ))
    done

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        curl wget unzip jq \
        iptables iproute2 \
        ca-certificates \
        systemd \
        2>/dev/null
    ok "پیش‌نیازها نصب شدند."
}

# ─── ساخت کاربر سیستمی ───────────────────────────────────────────────────────
create_user() {
    if id "$SYS_USER" &>/dev/null; then
        ok "کاربر $SYS_USER از قبل وجود دارد."
        return
    fi
    info "ساخت کاربر سیستمی $SYS_USER..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SYS_USER"
    ok "کاربر $SYS_USER ساخته شد."
}

# ─── ساخت ساختار دایرکتوری ───────────────────────────────────────────────────
create_dirs() {
    info "ساخت ساختار دایرکتوری..."
    mkdir -p \
        "${INSTALL_DIR}/bin" \
        "${INSTALL_DIR}/config" \
        "${INSTALL_DIR}/logs" \
        "${INSTALL_DIR}/data"
    chown -R "${SYS_USER}:${SYS_USER}" "${INSTALL_DIR}"
    chmod 755 "${INSTALL_DIR}"
    ok "دایرکتوری‌ها ساخته شدند."
}

# ─── دانلود باینری Psiphon ────────────────────────────────────────────────────
download_psiphon() {
    local bin_path="${INSTALL_DIR}/bin/psiphon-tunnel-core"

    if [[ -x "$bin_path" ]]; then
        ok "باینری psiphon-tunnel-core از قبل موجود است."
        return
    fi

    info "دانلود psiphon-tunnel-core..."
    if ! curl -fsSL --retry 3 --retry-delay 2 \
        "$PSIPHON_BIN_URL" \
        -o "$bin_path"; then
        die "دانلود باینری Psiphon ناموفق بود. اتصال اینترنت را بررسی کنید."
    fi

    chmod +x "$bin_path"
    chown "${SYS_USER}:${SYS_USER}" "$bin_path"
    ok "باینری Psiphon دانلود و نصب شد."
}

# ─── دانلود Xray ─────────────────────────────────────────────────────────────
download_xray() {
    local bin_path="${INSTALL_DIR}/bin/xray"

    if [[ -x "$bin_path" ]]; then
        ok "باینری xray از قبل موجود است."
        return
    fi

    info "دانلود Xray..."
    local xray_version
    xray_version=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | jq -r '.tag_name' 2>/dev/null || echo "v24.12.31")

    local xray_url="https://github.com/XTLS/Xray-core/releases/download/${xray_version}/Xray-linux-64.zip"
    local tmp_zip="/tmp/xray.zip"

    if ! curl -fsSL --retry 3 --retry-delay 2 "$xray_url" -o "$tmp_zip"; then
        warn "دانلود Xray با نسخه $xray_version ناموفق، تلاش با نسخه پیش‌فرض..."
        xray_url="https://github.com/XTLS/Xray-core/releases/download/v24.12.31/Xray-linux-64.zip"
        curl -fsSL --retry 3 "$xray_url" -o "$tmp_zip" || die "دانلود Xray کاملاً ناموفق بود."
    fi

    unzip -o -q "$tmp_zip" xray -d "${INSTALL_DIR}/bin/"
    rm -f "$tmp_zip"
    chmod +x "$bin_path"
    chown "${SYS_USER}:${SYS_USER}" "$bin_path"
    ok "Xray دانلود و نصب شد (نسخه: $xray_version)."
}

# ─── تنظیم آی‌پی لوکال ───────────────────────────────────────────────────────
setup_local_ip() {
    info "تنظیم آی‌پی لوکال $LOCAL_IP..."

    if ip addr show lo | grep -q "$LOCAL_IP"; then
        ok "آی‌پی $LOCAL_IP از قبل روی lo تنظیم است."
    else
        ip addr add "${LOCAL_IP}/8" dev lo 2>/dev/null || true
        ok "آی‌پی $LOCAL_IP به lo اضافه شد."
    fi

    # پایدارسازی در ریبوت
    local netplan_file="/etc/networkd-dispatcher/configured.d/psiphon-loopback"
    if [[ ! -f "$netplan_file" ]]; then
        mkdir -p "$(dirname "$netplan_file")"
        cat > "$netplan_file" <<EOF
#!/bin/sh
ip addr add ${LOCAL_IP}/8 dev lo 2>/dev/null || true
EOF
        chmod +x "$netplan_file"
    fi
    ok "آی‌پی لوکال تنظیم شد."
}

# ─── تولید کانفیگ Psiphon ────────────────────────────────────────────────────
generate_psiphon_config() {
    local instance=$1
    local socks_port=$(( BASE_SOCKS_PORT + instance ))
    local config_file="${INSTALL_DIR}/config/psiphon-${instance}.json"

    cat > "$config_file" <<EOF
{
    "PropagationChannelId": "FFFFFFFFFFFFFFFF",
    "SponsorId": "FFFFFFFFFFFFFFFF",
    "LocalSocksProxyPort": ${socks_port},
    "LocalHttpProxyPort": 0,
    "DisableLocalSocksProxy": false,
    "DisableLocalHTTPProxy": true,
    "DataStoreDirectory": "${INSTALL_DIR}/data/instance-${instance}",
    "RemoteServerListDownloadFilename": "${INSTALL_DIR}/data/instance-${instance}/remote_server_list",
    "UpstreamProxyUrl": "",
    "EmitDiagnosticNoticesToFiles": false,
    "UseIndistinguishableTLS": true,
    "ConnectionWorkerPoolSize": 10,
    "TunnelPoolSize": 1,
    "EstablishTunnelTimeoutSeconds": 60
}
EOF

    mkdir -p "${INSTALL_DIR}/data/instance-${instance}"
    chown -R "${SYS_USER}:${SYS_USER}" \
        "$config_file" \
        "${INSTALL_DIR}/data/instance-${instance}"
}

# ─── تولید کانفیگ Xray ──────────────────────────────────────────────────────
generate_xray_config() {
    local instance=$1
    local socks_port=$(( BASE_SOCKS_PORT + instance ))
    local inbound_port=$(( BASE_INBOUND_PORT + instance ))
    local config_file="${INSTALL_DIR}/config/xray-${instance}.json"

    cat > "$config_file" <<EOF
{
    "log": {
        "loglevel": "warning",
        "access": "${INSTALL_DIR}/logs/xray-${instance}-access.log",
        "error": "${INSTALL_DIR}/logs/xray-${instance}-error.log"
    },
    "inbounds": [
        {
            "port": ${inbound_port},
            "listen": "0.0.0.0",
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "udp": true
            },
            "tag": "socks-in-${instance}"
        }
    ],
    "outbounds": [
        {
            "protocol": "socks",
            "settings": {
                "servers": [
                    {
                        "address": "${LOCAL_IP}",
                        "port": ${socks_port}
                    }
                ]
            },
            "tag": "psiphon-${instance}"
        },
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ],
    "routing": {
        "rules": [
            {
                "type": "field",
                "outboundTag": "psiphon-${instance}",
                "inboundTag": ["socks-in-${instance}"]
            }
        ]
    }
}
EOF

    chown "${SYS_USER}:${SYS_USER}" "$config_file"
}

# ─── ساخت سرویس systemd برای Psiphon ────────────────────────────────────────
create_psiphon_service() {
    local instance=$1
    local svc_name="psiphon-instance-${instance}"

    cat > "/etc/systemd/system/${svc_name}.service" <<EOF
[Unit]
Description=Psiphon Tunnel Core - Instance ${instance}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SYS_USER}
Group=${SYS_USER}
ExecStart=${INSTALL_DIR}/bin/psiphon-tunnel-core -config ${INSTALL_DIR}/config/psiphon-${instance}.json
Restart=always
RestartSec=5
StandardOutput=append:${INSTALL_DIR}/logs/psiphon-${instance}.log
StandardError=append:${INSTALL_DIR}/logs/psiphon-${instance}-error.log
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF
}

# ─── ساخت سرویس systemd برای Xray ───────────────────────────────────────────
create_xray_service() {
    local instance=$1
    local svc_name="psiphon-xray-${instance}"

    cat > "/etc/systemd/system/${svc_name}.service" <<EOF
[Unit]
Description=Xray Proxy - Psiphon Instance ${instance}
After=psiphon-instance-${instance}.service
Requires=psiphon-instance-${instance}.service

[Service]
Type=simple
User=${SYS_USER}
Group=${SYS_USER}
ExecStart=${INSTALL_DIR}/bin/xray run -config ${INSTALL_DIR}/config/xray-${instance}.json
Restart=always
RestartSec=5
StandardOutput=append:${INSTALL_DIR}/logs/xray-${instance}.log
StandardError=append:${INSTALL_DIR}/logs/xray-${instance}-error.log
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF
}

# ─── تولید تمام کانفیگ‌ها و سرویس‌ها ────────────────────────────────────────
generate_all() {
    info "تولید کانفیگ‌ها و سرویس‌های systemd برای $INSTANCES اینستنس..."
    for (( i=0; i<INSTANCES; i++ )); do
        generate_psiphon_config "$i"
        generate_xray_config "$i"
        create_psiphon_service "$i"
        create_xray_service "$i"
    done
    ok "تمام کانفیگ‌ها و سرویس‌ها تولید شدند."
}

# ─── فعال‌سازی و راه‌اندازی سرویس‌ها ─────────────────────────────────────────
enable_and_start() {
    info "فعال‌سازی و راه‌اندازی سرویس‌ها..."
    systemctl daemon-reload

    for (( i=0; i<INSTANCES; i++ )); do
        systemctl enable --quiet "psiphon-instance-${i}.service"
        systemctl enable --quiet "psiphon-xray-${i}.service"
        systemctl start "psiphon-instance-${i}.service" || warn "اینستنس $i (psiphon) راه‌اندازی نشد."
        sleep 1
        systemctl start "psiphon-xray-${i}.service" || warn "اینستنس $i (xray) راه‌اندازی نشد."
    done
    ok "سرویس‌ها فعال شدند."
}

# ─── نمایش وضعیت ─────────────────────────────────────────────────────────────
show_status() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   Psiphon Multi-Region v5.1 - نصب کامل شد${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}اینستنس‌ها:${NC} $INSTANCES عدد"
    echo -e "${CYAN}SOCKS پورت‌ها:${NC} ${BASE_SOCKS_PORT} تا $(( BASE_SOCKS_PORT + INSTANCES - 1 ))"
    echo -e "${CYAN}اینباند پورت‌ها:${NC} ${BASE_INBOUND_PORT} تا $(( BASE_INBOUND_PORT + INSTANCES - 1 ))"
    echo -e "${CYAN}آی‌پی لوکال:${NC} $LOCAL_IP"
    echo ""
    echo -e "${YELLOW}نمونه استفاده:${NC}"
    echo "  curl --socks5 127.0.0.1:20000 https://api.ipify.org"
    echo "  curl --socks5 127.0.0.1:20001 https://api.ipify.org"
    echo ""
    echo -e "${YELLOW}مدیریت:${NC}"
    echo "  systemctl status psiphon-instance-0"
    echo "  systemctl status psiphon-xray-0"
    echo "  journalctl -u psiphon-instance-0 -f"
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
}

# ─── اجرای اصلی ──────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║     Psiphon Multi-Region Installer v5.1               ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    install_deps
    create_user
    create_dirs
    download_psiphon
    download_xray
    setup_local_ip
    generate_all
    enable_and_start
    show_status
}

main "$@"
