#!/usr/bin/env bash
#===============================================================================
# psiphon-multi-region / Psiphon Multi-Region Auto-Installer v5.2
# Installs multiple Psiphon tunnel-core instances with per-instance
# EgressRegion, systemd services, loopback aliases and optional Xray.
# Supports: Ubuntu 24.04 x86_64 (root required)
#===============================================================================

set -Eeuo pipefail

VERSION="5.2"
PROJECT_NAME="psiphon-multi-region"

#------------------------------------------------------------------------------
# تنظیمات پیش‌فرض
#------------------------------------------------------------------------------
PSIPHON_INSTANCES="${PSIPHON_INSTANCES:-20}"
SOCKS_BASE_PORT="${SOCKS_BASE_PORT:-10800}"
LOCAL_IP_BASE="${LOCAL_IP_BASE:-127.20.0}"
INBOUND_BASE_PORT="${INBOUND_BASE_PORT:-20000}"
EGRESS_REGIONS="${EGRESS_REGIONS:-}"
SSH_PORT="${SSH_PORT:-22}"

INSTALL_DIR="${INSTALL_DIR:-/opt/psiphon-multi-region}"
BIN_DIR="${INSTALL_DIR}/bin"
CONF_DIR="${INSTALL_DIR}/config"
DATA_DIR="${INSTALL_DIR}/data"
LOG_DIR="${INSTALL_DIR}/logs"
SERVICE_USER="${SERVICE_USER:-psiphon}"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/var/run/${PROJECT_NAME}.lock"

PSIPHON_BIN_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
XRAY_BIN_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"

VALID_REGIONS="AF AL DZ AS AD AO AI AG AR AM AW AU AT AZ BS BH BD BB BY BE BZ BJ BM BT BO BA BW BR BN BG BF BI KH CM CA CV KY CF TD CL CN CO KM CG CD CR CI HR CU CY CZ DK DJ DM DO EC EG SV GQ ER EE ET FK FJ FI FR PF GA GM GE DE GH GI GR GL GD GP GU GT GN GW GY HT HN HK HU IS IN ID IQ IE IL IT JM JP JO KZ KE KI KW KG LA LV LB LS LR LY LI LT LU MO MG MW MY MV ML MT MH MQ MR MU MX FM MD MC MN ME MS MA MZ MM NA NP NL NZ NI NG MP NO OM PK PW PS PA PG PY PE PH PL PT PR QA RO RU RW KN LC VC WS SM ST SA RS SC SL SG SK SI SB SO ZA KR ES LK SD SR SE SZ CH SY TW TJ TZ TH TL TG TO TT TN TR TM TV UG UA AE GB US UY UZ VU VE VN VG VI YE ZM ZW"

#------------------------------------------------------------------------------
# رنگ‌ها و چاپ پیام‌ها
#------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_RESET=''
fi

log()  { echo -e "${C_BLUE}[psiphon]${C_RESET} $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
ok()   { echo -e "${C_GREEN}[  OK  ]${C_RESET} $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
warn() { echo -e "${C_YELLOW}[ WARN ]${C_RESET} $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
info() { echo -e "${C_CYAN}[ INFO ]${C_RESET} $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
die()  { echo -e "${C_RED}[ FAIL ]${C_RESET} $*" | tee -a "$LOG_FILE" 2>/dev/null >&2; exit 1; }

on_error() {
    local exit_code=$?
    local line_no=$1
    echo -e "${C_RED}[FAIL] Error at line ${line_no} (exit code: ${exit_code}). Command: ${BASH_COMMAND}${C_RESET}" >&2
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

#------------------------------------------------------------------------------
# بررسی پیش‌نیازها و محیط
#------------------------------------------------------------------------------
check_root() {
    [[ "$(id -u)" -eq 0 ]] || die "این اسکریپت باید با دسترسی روت اجرا شود: sudo bash $0"
}

check_ssh() {
    info "بررسی وضعیت پورت SSH..."
    if command -v ss >/dev/null 2>&1; then
        if ss -tln | grep -qE "[:.]${SSH_PORT}[[:space:]]"; then
            ok "پورت SSH (${SSH_PORT}) فعال است."
        else
            warn "پورت SSH (${SSH_PORT}) در حالت Listen مشاهده نشد!"
        fi
    fi
}

install_dependencies() {
    info "نصب بسته‌های پیش‌نیاز..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >> "$LOG_FILE" 2>&1 || warn "خطا در آپدیت پکیج‌ها، ادامه می‌دهیم..."
    apt-get install -y curl unzip ca-certificates jq iproute2 ufw procps >> "$LOG_FILE" 2>&1 \
        || die "نصب وابستگی‌ها با شکست مواجه شد. لاگ را بررسی کنید: $LOG_FILE"
    ok "وابستگی‌ها با موفقیت نصب شدند."
}

create_user_and_dirs() {
    info "ایجاد پوشه‌ها و کاربر سیستمی..."
    mkdir -p "${BIN_DIR}" "${CONF_DIR}" "${DATA_DIR}" "${LOG_DIR}"
    
    if ! id "${SERVICE_USER}" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}" \
            || die "ایجاد کاربر ${SERVICE_USER} ناموفق بود."
        ok "کاربر سیستمی ${SERVICE_USER} ایجاد شد."
    fi
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"
}

#------------------------------------------------------------------------------
# دانلود باینری‌ها
#------------------------------------------------------------------------------
download_binaries() {
    mkdir -p "${BIN_DIR}"
    
    # 1. Psiphon Tunnel Core
    if [[ ! -x "${BIN_DIR}/psiphon-tunnel-core" ]]; then
        info "دانلود باینری Psiphon Tunnel Core..."
        local tmp_psi="${BIN_DIR}/psiphon.tmp"
        curl -fL --connect-timeout 20 --retry 3 -o "$tmp_psi" "$PSIPHON_BIN_URL" >> "$LOG_FILE" 2>&1 \
            || die "دانلود psiphon-tunnel-core ناموفق بود."
        chmod +x "$tmp_psi"
        mv -f "$tmp_psi" "${BIN_DIR}/psiphon-tunnel-core"
        ok "باینری psiphon-tunnel-core آماده شد."
    else
        ok "باینری psiphon-tunnel-core از قبل موجود است."
    fi

    # 2. Xray Core (در صورت فعال بودن)
    if [[ "${WITH_XRAY:-0}" == "1" ]]; then
        if [[ ! -x "${BIN_DIR}/xray" ]]; then
            info "دانلود و استخراج باینری Xray..."
            local tmp_zip="${INSTALL_DIR}/xray.zip"
            local tmp_dir="${INSTALL_DIR}/xray-extract"
            mkdir -p "$tmp_dir"
            curl -fL --connect-timeout 20 --retry 3 -o "$tmp_zip" "$XRAY_BIN_URL" >> "$LOG_FILE" 2>&1 \
                || die "دانلود Xray ناموفق بود."
            unzip -o "$tmp_zip" xray -d "$tmp_dir" >> "$LOG_FILE" 2>&1
            chmod +x "$tmp_dir/xray"
            mv -f "$tmp_dir/xray" "${BIN_DIR}/xray"
            rm -rf "$tmp_zip" "$tmp_dir"
            ok "باینری Xray آماده شد."
        else
            ok "باینری Xray از قبل موجود است."
        fi
    fi
}

#------------------------------------------------------------------------------
# تولید فایل‌های کانفیگ و سرویس‌های سیستمی
#------------------------------------------------------------------------------
generate_configs() {
    info "تولید فایل‌های پیکربندی برای ${PSIPHON_INSTANCES} نمونه..."
    
    for i in $(seq 1 "$PSIPHON_INSTANCES"); do
        local inst_dir="${DATA_DIR}/instance-${i}"
        mkdir -p "$inst_dir"
        chown -R "${SERVICE_USER}:${SERVICE_USER}" "$inst_dir"

        local socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
        local http_port=$(( socks_port + 1000 ))
        local cfg_file="${CONF_DIR}/psiphon-${i}.conf"

        local cp_id pc_id sp_id
        cp_id="CP$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
        pc_id="PC$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
        sp_id="SP$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"

        cat <<EOF > "$cfg_file"
{
    "ClientPlatform": "${cp_id}",
    "PropagationChannelId": "${pc_id}",
    "SponsorId": "${sp_id}",
    "DataRootDirectory": "${inst_dir}",
    "LocalHttpProxyPort": ${http_port},
    "LocalSocksProxyPort": ${socks_port},
    "EgressRegion": "",
    "EnableRemoteAPIList": true
}
EOF
        chown "${SERVICE_USER}:${SERVICE_USER}" "$cfg_file"
        chmod 640 "$cfg_file"

        # سرویس systemd برای Psiphon
        cat <<EOF > "/etc/systemd/system/psiphon-${i}.service"
[Unit]
Description=Psiphon Instance ${i} (v${VERSION})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${inst_dir}
ExecStart=${BIN_DIR}/psiphon-tunnel-core -config ${cfg_file}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

        # کانفیگ و سرویس Xray در صورت انتخاب
        if [[ "${WITH_XRAY:-0}" == "1" ]]; then
            local xray_in_port=$(( INBOUND_BASE_PORT + i - 1 ))
            local xray_ip="${LOCAL_IP_BASE}.${i}"
            local xray_cfg="${CONF_DIR}/xray-${i}.json"

            cat <<EOF > "$xray_cfg"
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "listen": "${xray_ip}",
        "port": ${xray_in_port},
        "protocol": "socks",
        "settings": { "auth": "noauth", "udp": true }
    }],
    "outbounds": [{
        "protocol": "socks",
        "settings": { "servers": [{ "address": "127.0.0.1", "port": ${socks_port} }] }
    }]
}
EOF
            chown "${SERVICE_USER}:${SERVICE_USER}" "$xray_cfg"

            cat <<EOF > "/etc/systemd/system/xray-${i}.service"
[Unit]
Description=Xray Bridge Instance ${i}
After=psiphon-${i}.service
Requires=psiphon-${i}.service

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=${BIN_DIR}/xray run -config ${xray_cfg}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        fi
    done
    ok "تمام کانفیگ‌ها و فایل‌های سرویس ایجاد شدند."
}

#------------------------------------------------------------------------------
# شبکه لوپ‌بک ۱۰۰٪ امن (بدون خطر قطعی SSH)
#------------------------------------------------------------------------------
configure_network() {
    info "پیکربندی آدرس‌های لوپ‌بک ${LOCAL_IP_BASE}.1 تا ${LOCAL_IP_BASE}.${PSIPHON_INSTANCES}..."
    
    for i in $(seq 1 "$PSIPHON_INSTANCES"); do
        ip addr add "${LOCAL_IP_BASE}.${i}/32" dev lo 2>/dev/null || true
    done

    # ثبت در systemd جهت حفظ آی‌پی‌ها بعد از ریبوت سرور
    cat <<EOF > /etc/systemd/system/psiphon-loopback-ips.service
[Unit]
Description=Psiphon Multi-Region Loopback Alias Setup
DefaultDependencies=no
After=systemd-modules-load.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "for i in \$(seq 1 ${PSIPHON_INSTANCES}); do ip addr add ${LOCAL_IP_BASE}.\$i/32 dev lo 2>/dev/null || true; done"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable psiphon-loopback-ips.service >> "$LOG_FILE" 2>&1
    ok "تنظیمات شبکه بدون دستکاری Netplan و بدون ریسک اعمال شد."
}

#------------------------------------------------------------------------------
# فایروال
#------------------------------------------------------------------------------
configure_ufw() {
    if command -v ufw >/dev/null 2>&1; then
        info "تنظیم UFW..."
        ufw allow "${SSH_PORT}/tcp" >> "$LOG_FILE" 2>&1 || true
        ok "دسترسی SSH روی پورت ${SSH_PORT} تأیید شد."
    fi
}

#------------------------------------------------------------------------------
# استارت و راه‌اندازی
#------------------------------------------------------------------------------
start_services() {
    info "راه‌اندازی سرویس‌ها در systemd..."
    systemctl daemon-reload

    for i in $(seq 1 "$PSIPHON_INSTANCES"); do
        systemctl enable --now "psiphon-${i}.service" >> "$LOG_FILE" 2>&1
        if [[ "${WITH_XRAY:-0}" == "1" ]]; then
            systemctl enable --now "xray-${i}.service" >> "$LOG_FILE" 2>&1
        fi
    done
    ok "دستور استارت برای تمام سرویس‌ها فرستاده شد."
}

show_summary() {
    local srv_ip
    srv_ip="$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "127.0.0.1")"

    echo ""
    echo -e "${C_CYAN}============================================================${C_RESET}"
    echo -e "${C_CYAN}    نصب Psiphon Multi-Region نسخه ${VERSION} با موفقیت انجام شد    ${C_RESET}"
    echo -e "${C_CYAN}============================================================${C_RESET}"
    printf "  %-4s | %-15s | %-12s | %-10s\n" "ردیف" "IP اینترفیس" "SOCKS پورت" "وضعیت"
    echo "  ----------------------------------------------------------"
    for i in $(seq 1 "$PSIPHON_INSTANCES"); do
        local socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
        local st="${C_GREEN}"
    echo -e "  📋 فایل گزارش لاگ: ${LOG_FILE}"
    echo -e "${            st="${C_RED}غیرفعال${C_RESET}"
        fi
        printf "  %-4s | %-15s | %-12s | %b\n" "$i" "${LOCAL_IP_BASE}.${i}" "$socks_port" "$st"
    done
    echo -e "${C_CYAN}============================================================${C_RESET}"
    echo -e "  📂 مسیر نصب: ${INSTALL_DIR}"
    echo -e "  📋 فایل گزارش لاگ: ${LOG_FILE}"
    echo -e "${C_CYAN}============================================================${C_RESET}"
}

#------------------------------------------------------------------------------
# ورودی اصلی
#------------------------------------------------------------------------------
WITH_XRAY=0
for arg in "$@"; do
    case "$arg" in
        --with-xray) WITH_XRAY=1 ;;
        -h|--help)
            echo "راهنمای استفاده: sudo bash $0 [--with-xray]"
            exit 0 ;;
    esac
done

main() {
    check_root
    check_ssh
    mkdir -p "${LOG_DIR}"
    install_dependencies
    create_user_and_dirs
    download_binaries
    generate_configs
    configure_network
    configure_ufw
    start_services
    show_summary
}

main "$@"
