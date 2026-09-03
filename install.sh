cat << 'EOF' > install.sh
#!/usr/bin/env bash
# psiphon-multi-region / Psiphon Multi-Region Auto-Installer v5.2
# Supports: Ubuntu 24.04 x86_64 (root required)

set -Eeuo pipefail

PROJECT_NAME="psiphon-multi-region"
VERSION="v5.2"

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
LOG_FILE="/tmp/psiphon-install.log"

PSIPHON_BIN_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
XRAY_BIN_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"

VALID_REGIONS="AF AL DZ AS AD AO AI AG AR AM AW AU AT AZ BS BH BD BB BY BE BZ BJ BM BT BO BA BW BR BN BG BF BI KH CM CA CV KY CF TD CL CN CO KM CG CD CR CI HR CU CY CZ DK DJ DM DO EC EG SV GQ ER EE ET FK FJ FI FR PF GA GM GE DE GH GI GR GL GD GP GU GT GN GW GY HT HN HK HU IS IN ID IQ IE IL IT JM JP JO KZ KE KI KW KG LA LV LB LS LR LY LI LT LU MO MG MW MY MV ML MT MH MQ MR MU MX FM MD MC MN ME MS MA MZ MM NA NP NL NZ NI NG MP NO OM PK PW PS PA PG PY PE PH PL PT PR QA RO RU RW KN LC VC WS SM ST SA RS SC SL SG SK SI SB SO ZA KR ES LK SD SR SE SZ CH SY TW TJ TZ TH TL TG TO TT TN TR TM TV UG UA AE GB US UY UZ VU VE VN VG VI YE ZM ZW"

if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_RESET=''
fi

log()  { echo -e "${C_BLUE}[psiphon]${C_RESET} $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_RESET} $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
warn() { echo -e "${C_YELLOW}[ WARN ]${C_RESET} $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
info() { echo -e "${C_CYAN}[ INFO ]${C_RESET} $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
die()  { echo -e "${C_RED}[ FAIL ]${C_RESET} $*" | tee -a "$LOG_FILE" 2>/dev/null >&2; exit 1; }

on_error() {
    local exit_code=$?
    local line_no=$1
    echo -e "${C_RED}[FAIL] خطا در خط ${line_no} رخ داد (کد خروج: ${exit_code}). دستور: ${BASH_COMMAND}${C_RESET}" >&2
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

check_root() {
    [[ "$(id -u)" -eq 0 ]] || die "این اسکریپت باید با روت اجرا شود: sudo bash $0"
}

check_ssh() {
    info "بررسی پورت SSH..."
    if command -v ss >/dev/null 2>&1; then
        if ss -tln | grep -qE "[:.]${SSH_PORT}[[:space:]]"; then
            ok "پورت SSH (${SSH_PORT}) فعال است."
        else
            warn "پورت SSH (${SSH_PORT}) در حالت Listen مشاهده نشد!"
        fi
    fi
}

install_dependencies() {
    info "نصب پیش‌نیازها..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y 2>&1 | tee -a "$LOG_FILE" || true
    apt-get install -y curl unzip ca-certificates jq iproute2 procps 2>&1 | tee -a "$LOG_FILE" || die "نصب پکیج‌ها ناموفق بود."
    ok "تمام پکیج‌ها نصب شدند."
}

create_user_and_dirs() {
    info "ایجاد پوشه‌ها و کاربر سیستمی psiphon..."
    mkdir -p "${BIN_DIR}" "${CONF_DIR}" "${DATA_DIR}" "${LOG_DIR}"
    LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
    touch "$LOG_FILE"
    
    if ! id "${SERVICE_USER}" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}" || die "ایجاد کاربر ${SERVICE_USER} ناموفق بود."
        ok "کاربر ${SERVICE_USER} ایجاد شد."
    fi
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"
}

download_binaries() {
    mkdir -p "${BIN_DIR}"
    if [[ ! -x "${BIN_DIR}/psiphon-tunnel-core" ]]; then
        info "در حال دانلود psiphon-tunnel-core..."
        local tmp_psi="${BIN_DIR}/psiphon.tmp"
        curl -# -fL --connect-timeout 20 --retry 3 -o "$tmp_psi" "$PSIPHON_BIN_URL" 2>&1 | tee -a "$LOG_FILE" || die "دانلود psiphon-tunnel-core ناموفق بود."
        chmod +x "$tmp_psi"
        mv -f "$tmp_psi" "${BIN_DIR}/psiphon-tunnel-core"
        ok "هسته psiphon-tunnel-core آماده شد."
    else
        ok "هسته psiphon از قبل موجود است."
    fi

    if [[ "${WITH_XRAY:-0}" == "1" ]]; then
        if [[ ! -x "${BIN_DIR}/xray" ]]; then
            info "در حال دانلود هسته Xray..."
            local tmp_zip="${INSTALL_DIR}/xray.zip"
            local tmp_dir="${INSTALL_DIR}/xray-extract"
            mkdir -p "$tmp_dir"
            curl -# -fL --connect-timeout 20 --retry 3 -o "$tmp_zip" "$XRAY_BIN_URL" 2>&1 | tee -a "$LOG_FILE" || die "دانلود Xray ناموفق بود."
            unzip -o "$tmp_zip" xray -d "$tmp_dir" 2>&1 | tee -a "$LOG_FILE"
            chmod +x "$tmp_dir/xray"
            mv -f "$tmp_dir/xray" "${BIN_DIR}/xray"
            rm -rf "$tmp_zip" "$tmp_dir"
            ok "هسته Xray آماده شد."
        else
            ok "هسته Xray از قبل موجود است."
        fi
    fi
}

setup_loopback_service() {
    info "پیکربندی آی‌پی‌های لوکال..."
    local script_path="${INSTALL_DIR}/bin/setup-loopback.sh"
    
    cat << 'SUBEOF' > "$script_path"
#!/usr/bin/env bash
set -e
BASE_IP="${1:-127.20.0}"
COUNT="${2:-20}"
for i in $(seq 1 "$COUNT"); do
    ip addr add "${BASE_IP}.${i}/32" dev lo label "lo:psi${i}" 2>/dev/null || true
done
SUBEOF
    chmod +x "$script_path"

    cat << SUBEOF > /etc/systemd/system/psiphon-loopback.service
[Unit]
Description=Psiphon Multi-Region Loopback Aliases Setup
DefaultDependencies=no
After=local-fs.target
Before=network.target

[Service]
Type=oneshot
ExecStart=${script_path} ${LOCAL_IP_BASE} ${PSIPHON_INSTANCES}
RemainAfterExit=yes

[Install]
WantedBy=network.target
SUBEOF

    systemctl daemon-reload
    systemctl enable --now psiphon-loopback.service 2>&1 | tee -a "$LOG_FILE"
    ok "آی‌پی‌های لوکال ۱۲۷.۲۰.۰.۱ تا ۱۲۷.۲۰.۰.${PSIPHON_INSTANCES} فعال شدند."
}

generate_configs() {
    info "تولید فایل‌های کانفیگ برای ${PSIPHON_INSTANCES} اینستنس..."
    
    IFS=',' read -r -a REGION_ARRAY <<< "$EGRESS_REGIONS"
    local reg_len=${#REGION_ARRAY[@]}

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

        local target_region=""
        if [[ $reg_len -gt 0 ]]; then
            local idx=$(( (i - 1) % reg_len ))
            local candidate="${REGION_ARRAY[$idx]}"
            candidate="$(echo "$candidate" | xargs | tr '[:lower:]' '[:upper:]')"
            if [[ " $VALID_REGIONS " =~ [[:space:]]${candidate}[[:space:]] ]]; then
                target_region="$candidate"
            fi
        fi

        cat << SUBEOF > "$cfg_file"
{
  "ClientPlatform": "${cp_id}",
  "PropagationChannelId": "${pc_id}",
  "SponsorId": "${sp_id}",
  "DataRootDirectory": "${inst_dir}",
  "LocalHttpProxyPort": ${http_port},
  "LocalSocksProxyPort": ${socks_port},
  "EgressRegion": "${target_region}",
  "EnableRemoteAPIList": true
}
SUBEOF
        chown "${SERVICE_USER}:${SERVICE_USER}" "$cfg_file"
        chmod 640 "$cfg_file"

        cat << SUBEOF > "/etc/systemd/system/psiphon@${i}.service"
[Unit]
Description=Psiphon Multi-Region Service - Instance %i
After=network.target psiphon-loopback.service
Wants=psiphon-loopback.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${DATA_DIR}/instance-%i
ExecStart=${BIN_DIR}/psiphon-tunnel-core --config ${CONF_DIR}/psiphon-%i.conf --dataRootDirectory ${DATA_DIR}/instance-%i
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SUBEOF
        echo -e "  » کانفیگ و سرویس اینستنس [${i}/${PSIPHON_INSTANCES}] آماده شد."
    done

    systemctl daemon-reload
    ok "تمام کانفیگ‌ها و سرویس‌ها ایجاد شدند."
}

start_services() {
    info "راه‌اندازی سرویس‌های سایفون..."
    for i in $(seq 1 "$PSIPHON_INSTANCES"); do
        echo -n "  » فعال‌سازی psiphon@${i}... "
        if systemctl enable --now "psiphon@${i}.service" >> "$LOG_FILE" 2>&1; then
            echo -e "${C_GREEN}[OK]${C_RESET}"
        else
            echo -e "${C_YELLOW}[WARN]${C_RESET}"
        fi
    done
    ok "سرویس‌ها با موفقیت راه‌اندازی شدند."
}

show_summary() {
    echo ""
    echo -e "${C_GREEN}====================================================${C_RESET}"
    echo -e "${C_GREEN}      نصب Psiphon Multi-Region با موفقیت به اتمام رسید  ${C_RESET}"
    echo -e "${C_GREEN}====================================================${C_RESET}"
    echo -e " تعداد نمونه‌ها: ${C_CYAN}${PSIPHON_INSTANCES}${C_RESET}"
    echo -e " پورت‌های SOCKS: ${C_CYAN}${SOCKS_BASE_PORT} تا $(( SOCKS_BASE_PORT + PSIPHON_INSTANCES - 1 ))${C_RESET}"
    echo -e " پورت‌های HTTP:  ${C_CYAN}$(( SOCKS_BASE_PORT + 1000 )) تا $(( SOCKS_BASE_PORT + 1000 + PSIPHON_INSTANCES - 1 ))${C_RESET}"
    echo -e " آی‌پی‌های لوکال: ${C_CYAN}${LOCAL_IP_BASE}.1 تا ${LOCAL_IP_BASE}.${PSIPHON_INSTANCES}${C_RESET}"
    echo -e "${C_GREEN}====================================================${C_RESET}"
}

main() {
    for arg in "$@"; do
        case "$arg" in
            --with-xray) WITH_XRAY=1 ;;
        esac
    done

    log "شروع عملیات نصب Psiphon Multi-Region (${VERSION})..."
    check_root
    check_ssh
    install_dependencies
    create_user_and_dirs
    download_binaries
    setup_loopback_service
    generate_configs
    start_services
    show_summary
}

main "$@"
EOF
