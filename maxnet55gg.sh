#!/usr/bin/env bash
# ==============================================================================
# Project: WG-MULTI | WireGuard Multi-Location Static Egress Manager
# Edition: Enterprise Production Hardened + Full Auto-Bootstrap (v3.2.0)
# Target OS: Ubuntu 20.04, 22.04, 24.04, 26.04 LTS
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

GITHUB_RAW_URL="${WG_MULTI_REPO_URL:-https://raw.githubusercontent.com/mohsenakbarinia/psiphon-installer/main/maxnet55gg.sh}"

readonly SCRIPT_VERSION="3.2.0-PROD"
readonly SELF_INSTALLED_PATH="/usr/local/sbin/wg-multi-manager.sh"
readonly BASE_DIR="/etc/wg-multi"
readonly CONFIGS_DIR="${BASE_DIR}/configs"
readonly GENERATED_DIR="${BASE_DIR}/generated"
readonly AUTH_DIR="${BASE_DIR}/auth"
readonly STATE_DIR="${BASE_DIR}/state"
readonly BACKUP_DIR="${BASE_DIR}/backups"
readonly SCRIPTS_DIR="${BASE_DIR}/scripts"
readonly BOT_DIR="${BASE_DIR}/bot"
readonly TURBO_DIR="${BASE_DIR}/turbo"
readonly LOG_DIR="/var/log/wg-multi"
readonly MAIN_LOG="${LOG_DIR}/wg-multi.log"
readonly HEALTH_LOG="${LOG_DIR}/healthcheck.log"
readonly AUDIT_LOG="${LOG_DIR}/audit.log"
readonly LOCK_FILE="/run/wg-multi.lock"

readonly MAPPING_JSON="${BASE_DIR}/mapping.json"
readonly MAPPING_TXT="${BASE_DIR}/mapping.txt"
readonly RT_TABLES_CONF="/etc/iproute2/rt_tables.d/wg-multi.conf"
readonly SYSCTL_TURBO_CONF="/etc/sysctl.d/99-wg-multi-turbo.conf"
readonly TURBO_BACKUP_FILE="${TURBO_DIR}/sysctl-original.backup"

readonly START_PORT=10801
readonly START_TABLE_ID=201
readonly START_RULE_PRIO=10100
readonly MAX_BACKUPS=10

DRY_RUN=0
ASSUME_YES=0
NON_INTERACTIVE=0
ACTION="install"
TARGET_ARG=""
CLI_BOT_TOKEN=""
CLI_BOT_ADMINS=""
ENABLE_TURBO_ON_INSTALL=1

readonly C_RESET='\033[0m'
readonly C_RED='\033[1;31m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_BLUE='\033[1;34m'
readonly C_CYAN='\033[1;36m'
readonly C_BOLD='\033[1m'

declare -a ROLLBACK_STACK=()
TRANSACTION_ACTIVE=0
CURRENT_SNAPSHOT=""

init_runtime_dirs() {
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    mkdir -p "$LOG_DIR" "$BASE_DIR" "$CONFIGS_DIR" "$GENERATED_DIR" \
             "$AUTH_DIR" "$STATE_DIR" "$BACKUP_DIR" "$SCRIPTS_DIR" \
             "$BOT_DIR" "$TURBO_DIR" "/etc/iproute2/rt_tables.d" "/usr/local/sbin"
    chmod 700 "$BASE_DIR" "$CONFIGS_DIR" "$GENERATED_DIR" "$AUTH_DIR" "$BACKUP_DIR" "$BOT_DIR"
    touch "$MAIN_LOG" "$HEALTH_LOG" "$AUDIT_LOG"
    chmod 600 "$MAIN_LOG" "$HEALTH_LOG" "$AUDIT_LOG"
}

sanitize_log_string() {
    echo "$1" | sed -E \
        -e 's/(PrivateKey\s*=\s*)[^ ]+/\1[REDACTED]/Ig' \
        -e 's/(PresharedKey\s*=\s*)[^ ]+/\1[REDACTED]/Ig' \
        -e 's/(-P\s+)[^ ]+/\1[REDACTED]/g' \
        -e 's/(SOCKS_PASS=)[^ ]+/\1[REDACTED]/g' \
        -e 's/([0-9]{8,10}:[a-zA-Z0-9_-]{35})/[BOT_TOKEN_REDACTED]/g'
}

log_raw() {
    local ts clean_msg
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    clean_msg="$(sanitize_log_string "$2")"
    if [[ "$DRY_RUN" -eq 0 && -d "$LOG_DIR" ]]; then
        printf "[%s] [%s] %s\n" "$ts" "$1" "$clean_msg" >> "$MAIN_LOG"
    fi
}

msg_info() { log_raw "INFO" "$1"; printf "${C_BLUE}[اطلاعات]${C_RESET} %s\n" "$1"; }
msg_ok()   { log_raw "OK" "$1";   printf "${C_GREEN}[موفق]${C_RESET} %s\n" "$1"; }
msg_warn() { log_raw "WARN" "$1"; printf "${C_YELLOW}[هشدار]${C_RESET} %s\n" "$1" >&2; }
msg_err()  { log_raw "ERROR" "$1";printf "${C_RED}[خطا]${C_RESET} %s\n" "$1" >&2; }
msg_dry()  { printf "${C_CYAN}[DRY-RUN]${C_RESET} شبیه‌سازی: %s\n" "$(sanitize_log_string "$*")"; }

run_cmd() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        msg_dry "$*"
        return 0
    fi
    log_raw "EXEC" "$*"
    "$@"
}

write_file_atomic() {
    local target_file="$1" mode="${2:-0600}" content="$3"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        msg_dry "نوشتن فایل ${target_file}"
        return 0
    fi
    local dir tmp_file
    dir="$(dirname "$target_file")"
    mkdir -p "$dir"
    tmp_file="$(mktemp "${dir}/.tmp.XXXXXX")"
    chmod "$mode" "$tmp_file"
    printf "%s\n" "$content" > "$tmp_file"
    sync "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$target_file"
}

acquire_lock() {
    local lock_path="${1:-$LOCK_FILE}"
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    exec 200>"$lock_path"
    if ! flock -n 200; then
        msg_err "یک نمونه دیگر از برنامه در حال اجراست."
        exit 1
    fi
    echo "$$" >&200
}

register_rollback_cmd() { ROLLBACK_STACK+=("$1"); }

execute_rollback_stack() {
    [[ "${#ROLLBACK_STACK[@]}" -eq 0 ]] && return 0
    local idx
    for (( idx=${#ROLLBACK_STACK[@]}-1 ; idx>=0 ; idx-- )) ; do
        [[ "$DRY_RUN" -eq 0 ]] && bash -c "${ROLLBACK_STACK[$idx]}" >/dev/null 2>&1 || true
    done
    ROLLBACK_STACK=()
}

on_error_trap() {
    local exit_code=$? line_no=$1
    msg_err "خطا در خط ${line_no} (کد: ${exit_code})."
    if [[ "$TRANSACTION_ACTIVE" -eq 1 ]]; then
        execute_rollback_stack
        [[ -n "$CURRENT_SNAPSHOT" && -d "$CURRENT_SNAPSHOT" && "$DRY_RUN" -eq 0 ]] && restore_snapshot_internal "$CURRENT_SNAPSHOT" || true
    fi
    exit "$exit_code"
}

trap 'on_error_trap $LINENO' ERR
trap 'execute_rollback_stack; exit 130' SIGINT SIGTERM

persist_self_binary() {
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    if [[ -f "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != /dev/fd/* && "${BASH_SOURCE[0]}" != "bash" ]]; then
        [[ "$(realpath "${BASH_SOURCE[0]}")" != "$SELF_INSTALLED_PATH" ]] && cp -f "${BASH_SOURCE[0]}" "$SELF_INSTALLED_PATH" && chmod 0700 "$SELF_INSTALLED_PATH"
        return 0
    fi
    local tmp_self
    tmp_self="$(mktemp /tmp/wg-multi-self.XXXXXX)"
    if curl -fsSL --max-time 20 "$GITHUB_RAW_URL" -o "$tmp_self" && grep -q "WG-MULTI" "$tmp_self"; then
        chmod 0700 "$tmp_self"
        mv -f "$tmp_self" "$SELF_INSTALLED_PATH"
    else
        rm -f "$tmp_self"
    fi
}

validate_country_code() {
    [[ "$1" =~ ^[A-Z]{2,4}$ ]] || { msg_err "کد کشور نامعتبر است: '$1'"; return 1; }
}

country_to_iface() {
    validate_country_code "$1"
    echo "wg$(echo "$1" | tr '[:upper:]' '[:lower:]')"
}

validate_ipv4_cidr() {
    local ip_cidr="$1"
    [[ "$ip_cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1
    local ip="${ip_cidr%/*}" mask="${ip_cidr#*/}"
    [[ "$ip" != "$mask" ]] && (( mask < 0 || mask > 32 )) && return 1
    local IFS='.'
    read -r -a octets <<< "$ip"
    for oct in "${octets[@]}"; do (( oct < 0 || oct > 255 )) && return 1; done
    return 0
}

validate_wg_key() {
    [[ ${#1} -eq 44 && "$1" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]
}

generate_secure_password() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 || true
}

check_system_compatibility() {
    msg_info "بررسی سازگاری سیستم‌عامل..."
    [[ "$EUID" -ne 0 && "$DRY_RUN" -eq 0 ]] && { msg_err "نیاز به دسترسی root است."; exit 1; }
    [[ ! -d /run/systemd/system ]] && { msg_err "systemd یافت نشد."; exit 1; }
    local os_id os_ver_id
    os_id="$(awk -F= '/^ID=/ {gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || echo "ubuntu")"
    os_ver_id="$(awk -F= '/^VERSION_ID=/ {gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || echo "24.04")"
    msg_ok "سیستم‌عامل شناسایی شد: ${os_id} ${os_ver_id} ($(uname -m))"
}

install_dependencies() {
    msg_info "نصب خودکار پیش‌نیازها..."
    local -a required_pkgs=(wireguard wireguard-tools iproute2 iptables curl jq ca-certificates netcat-openbsd psmisc uuid-runtime util-linux)
    local -a missing_pkgs=()
    for pkg in "${required_pkgs[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
    done

    local need_microsocks_build=0
    if ! command -v microsocks >/dev/null 2>&1; then
        if apt-cache show microsocks >/dev/null 2>&1; then
            missing_pkgs+=("microsocks")
        else
            need_microsocks_build=1
            missing_pkgs+=("build-essential" "git")
        fi
    fi

    if [[ "${#missing_pkgs[@]}" -gt 0 ]]; then
        run_cmd env DEBIAN_FRONTEND=noninteractive apt-get update -y
        run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_pkgs[@]}"
    fi

    if [[ "$need_microsocks_build" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
        local build_dir
        build_dir="$(mktemp -d /tmp/microsocks-build.XXXXXX)"
        git clone --depth 1 https://github.com/rofl0r/microsocks.git "$build_dir"
        make -C "$build_dir"
        install -m 0755 "${build_dir}/microsocks" /usr/local/bin/microsocks
        rm -rf "$build_dir"
    fi
}

# ==============================================================================
# AUTO-BOOTSTRAP CLOUDFLARE WARP IF NO CONFIG EXISTS (صفر تا صد خودکار)
# ==============================================================================
auto_bootstrap_warp_if_empty() {
    [[ "$DRY_RUN" -eq 1 ]] && return 0

    # Remove any empty 0-byte .conf files from previous aborted runs
    find "$CONFIGS_DIR" -maxdepth 1 -type f -name "*.conf" -size 0 -delete 2>/dev/null || true

    shopt -s nullglob
    local -a existing_confs=("${CONFIGS_DIR}"/*.conf)
    shopt -u nullglob

    if [[ "${#existing_confs[@]}" -gt 0 ]]; then
        return 0
    fi

    msg_info "هیچ کانفیگی وجود ندارد؛ شروع تولید کاملاً خودکار کانفیگ WireGuard از طریق Cloudflare WARP..."

    local arch wgcf_arch="amd64"
    arch="$(uname -m)"
    [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && wgcf_arch="arm64"

    if ! command -v wgcf >/dev/null 2>&1; then
        local wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${wgcf_arch}"
        msg_info "دانلود ابزار رسمی wgcf (${wgcf_arch})..."
        curl -fsSL --max-time 30 "$wgcf_url" -o /usr/local/bin/wgcf
        chmod 0755 /usr/local/bin/wgcf
    fi

    local work_dir
    work_dir="$(mktemp -d /tmp/wgcf-auto.XXXXXX)"
    (
        cd "$work_dir"
        wgcf register --accept-tos >/dev/null 2>&1
        wgcf generate >/dev/null 2>&1
        if [[ -f "wgcf-profile.conf" ]]; then
            cp -f "wgcf-profile.conf" "${CONFIGS_DIR}/CF.conf"
            chmod 0600 "${CONFIGS_DIR}/CF.conf"
        fi
    )
    rm -rf "$work_dir"

    if [[ -s "${CONFIGS_DIR}/CF.conf" ]]; then
        msg_ok "کانفیگ WireGuard اختصاصی (CF.conf) به‌طور خودکار تولید و آماده شد!"
    else
        msg_err "تولید خودکار کانفیگ WARP با خطا مواجه شد."
        return 1
    fi
}

validate_and_process_wg_config() {
    local cc="$1"
    local src_conf="${CONFIGS_DIR}/${cc}.conf"
    local dst_conf="${GENERATED_DIR}/${cc}.conf"

    validate_country_code "$cc"
    [[ ! -s "$src_conf" ]] && { msg_err "[${cc}] فایل کانفیگ خالی یا ناموجود است."; return 1; }
    [[ "$DRY_RUN" -eq 0 ]] && chmod 0600 "$src_conf"

    local has_interface=0 has_peer=0 current_section=""
    local priv_key="" address_ipv4="" pub_key="" endpoint="" endpoint_port="" allowed_ips=""
    local line_num=0 validation_failed=0

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line_num=$((line_num + 1))
        local line
        line="$(echo "$raw_line" | sed -E 's/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^\[([A-Za-z]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            [[ "$current_section" == "Interface" ]] && has_interface=1
            [[ "$current_section" == "Peer" ]] && has_peer=1
            continue
        fi

        if [[ "$line" =~ ^([A-Za-z]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
            if [[ "$current_section" == "Interface" ]]; then
                case "$key" in
                    PrivateKey) priv_key="$val"; validate_wg_key "$priv_key" || validation_failed=1 ;;
                    Address)
                        local IFS=','
                        read -r -a addr_parts <<< "$val"
                        for part in "${addr_parts[@]}"; do
                            part="$(echo "$part" | tr -d '[:space:]')"
                            if validate_ipv4_cidr "$part"; then address_ipv4="$part"; break; fi
                        done
                        [[ -z "$address_ipv4" ]] && validation_failed=1
                        ;;
                esac
            elif [[ "$current_section" == "Peer" ]]; then
                case "$key" in
                    PublicKey) pub_key="$val"; validate_wg_key "$pub_key" || validation_failed=1 ;;
                    Endpoint)
                        endpoint="$val"
                        if [[ "$endpoint" =~ ^\[?([a-zA-Z0-9._:-]+)\]?:([0-9]{1,5})$ ]]; then
                            endpoint_port="${BASH_REMATCH[2]}"
                            (( endpoint_port < 1 || endpoint_port > 65535 )) && validation_failed=1
                        else
                            validation_failed=1
                        fi
                        ;;
                    AllowedIPs) allowed_ips="$val" ;;
                esac
            fi
        fi
    done < "$src_conf"

    if [[ "$has_interface" -eq 0 || "$has_peer" -eq 0 || -z "$priv_key" || -z "$address_ipv4" || -z "$pub_key" || -z "$endpoint" || -z "$allowed_ips" || "$validation_failed" -ne 0 ]]; then
        msg_err "[${cc}] خطا در اعتبارسنجی ساختار فایل کانفیگ."
        return 1
    fi

    local generated_content
    generated_content="$(awk '
        BEGIN { in_peer=0; has_keepalive=0; }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[Interface\]/ { print "[Interface]\nTable = off"; in_peer=0; next }
        /^[[:space:]]*\[Peer\]/ { if (in_peer && !has_keepalive) print "PersistentKeepalive = 25"; print "\n[Peer]"; in_peer=1; has_keepalive=0; next }
        /^[[:space:]]*(DNS|Table|PreUp|PostUp|PreDown|PostDown)[[:space:]]*=/ { next }
        /^[[:space:]]*PersistentKeepalive[[:space:]]*=/ { has_keepalive=1; print $0; next }
        { print $0 }
        END { if (in_peer && !has_keepalive) print "PersistentKeepalive = 25" }
    ' "$src_conf")"

    write_file_atomic "$dst_conf" 0600 "$generated_content"
    msg_ok "[${cc}] کانفیگ اعتبارسنجی و ایزوله شد (IP: ${address_ipv4%/*} | Endpoint: ${endpoint})."
}

extract_config_metadata() {
    local cc="$1" conf_file="${GENERATED_DIR}/${1}.conf"
    [[ ! -f "$conf_file" ]] && conf_file="${CONFIGS_DIR}/${cc}.conf"
    local raw_addr
    raw_addr="$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$conf_file" | head -n1 | cut -d'=' -f2- | tr -d '[:space:]')"
    local first_ipv4="${raw_addr%%,*}"
    echo "${first_ipv4%/*}"
}

init_mapping_store() {
    [[ ! -f "$MAPPING_JSON" ]] && write_file_atomic "$MAPPING_JSON" 0600 '{"countries":{}}'
    [[ ! -f "$MAPPING_TXT" ]] && write_file_atomic "$MAPPING_TXT" 0600 "# COUNTRY|IFACE|PORT|TABLE_ID|RULE_PRIO|INTERNAL_IP|ENABLED"
}

is_port_in_use_by_other() {
    local port="$1" expected_cc="${2:-}"
    if [[ -f "$MAPPING_JSON" ]]; then
        local owner
        owner="$(jq -r --argjson p "$port" '.countries | to_entries[] | select(.value.port == $p) | .key' "$MAPPING_JSON" 2>/dev/null || true)"
        [[ -n "$owner" && "$owner" != "$expected_cc" ]] && return 0
    fi
    if ss -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(:|\\])${port}$"; then
        [[ -n "$expected_cc" ]] && systemctl is-active --quiet "wg-multi-socks@${expected_cc}.service" 2>/dev/null && return 1
        return 0
    fi
    return 1
}

allocate_or_update_country_mapping() {
    local cc="$1" enabled="${2:-true}"
    validate_country_code "$cc"
    init_mapping_store

    local iface internal_ip current_json="{}"
    iface="$(country_to_iface "$cc")"
    internal_ip="$(extract_config_metadata "$cc")"
    [[ -f "$MAPPING_JSON" ]] && current_json="$(cat "$MAPPING_JSON")"

    local assigned_port assigned_table assigned_prio
    assigned_port="$(echo "$current_json" | jq -r --arg cc "$cc" '.countries[$cc].port // empty')"
    assigned_table="$(echo "$current_json" | jq -r --arg cc "$cc" '.countries[$cc].table_id // empty')"
    assigned_prio="$(echo "$current_json" | jq -r --arg cc "$cc" '.countries[$cc].rule_prio // empty')"

    if [[ -z "$assigned_port" ]]; then
        local candidate_port="$START_PORT"
        while is_port_in_use_by_other "$candidate_port" "$cc"; do candidate_port=$((candidate_port + 1)); done
        assigned_port="$candidate_port"
    fi

    if [[ -z "$assigned_table" ]]; then
        local candidate_table="$START_TABLE_ID"
        while [[ -n "$(echo "$current_json" | jq -r --argjson t "$candidate_table" '.countries | to_entries[] | select(.value.table_id == $t) | .key')" ]]; do
            candidate_table=$((candidate_table + 1))
        done
        assigned_table="$candidate_table"
    fi

    if [[ -z "$assigned_prio" ]]; then
        local candidate_prio="$START_RULE_PRIO"
        while [[ -n "$(echo "$current_json" | jq -r --argjson pr "$candidate_prio" '.countries | to_entries[] | select(.value.rule_prio == $pr) | .key')" ]]; do
            candidate_prio=$((candidate_prio + 10))
        done
        assigned_prio="$candidate_prio"
    fi

    local auth_file="${AUTH_DIR}/${cc}.env"
    if [[ ! -f "$auth_file" ]]; then
        write_file_atomic "$auth_file" 0600 "SOCKS_USER=wg_${cc,,}"$'\n'"SOCKS_PASS=$(generate_secure_password)"
    fi

    local updated_json
    updated_json="$(echo "$current_json" | jq \
        --arg cc "$cc" --arg iface "$iface" --argjson port "$assigned_port" \
        --argjson table_id "$assigned_table" --argjson rule_prio "$assigned_prio" \
        --arg internal_ip "$internal_ip" --argjson enabled "$enabled" \
        --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '.countries[$cc] = {iface: $iface, port: $port, table_id: $table_id, rule_prio: $rule_prio, internal_ip: $internal_ip, enabled: $enabled, updated_at: $updated_at}')"

    write_file_atomic "$MAPPING_JSON" 0600 "$updated_json"

    local txt_content="# COUNTRY|IFACE|PORT|TABLE_ID|RULE_PRIO|INTERNAL_IP|ENABLED"
    while IFS= read -r line; do [[ -n "$line" ]] && txt_content+=$'\n'"$line"; done < <(echo "$updated_json" | jq -r '.countries | to_entries | sort_by(.value.port)[] | "\(.key)|\(.value.iface)|\(.value.port)|\(.value.table_id)|\(.value.rule_prio)|\(.value.internal_ip)|\(.value.enabled)"')
    write_file_atomic "$MAPPING_TXT" 0600 "$txt_content"

    local rt_content="# Managed by WG-MULTI"
    while IFS= read -r rline; do [[ -n "$rline" ]] && rt_content+=$'\n'"$rline"; done < <(echo "$updated_json" | jq -r '.countries | to_entries | sort_by(.value.table_id)[] | "\(.value.table_id)\t\(.value.iface)_rt"')
    write_file_atomic "$RT_TABLES_CONF" 0644 "$rt_content"
}

deploy_runtime_helper_scripts() {
    local tunnel_ctl="${SCRIPTS_DIR}/tunnel-ctl.sh"
    local tunnel_ctl_content
    read -r -d '' tunnel_ctl_content << 'EOF' || true
#!/usr/bin/env bash
set -Eeuo pipefail
ACTION="${1:-}" CC="${2:-}"
BASE_DIR="/etc/wg-multi"
MAPPING_JSON="${BASE_DIR}/mapping.json"
GENERATED_CONF="${BASE_DIR}/generated/${CC}.conf"
STATE_DIR="${BASE_DIR}/state"

IFACE="$(jq -r --arg cc "$CC" '.countries[$cc].iface // empty' "$MAPPING_JSON")"
TABLE_ID="$(jq -r --arg cc "$CC" '.countries[$cc].table_id // empty' "$MAPPING_JSON")"
RULE_PRIO="$(jq -r --arg cc "$CC" '.countries[$cc].rule_prio // empty' "$MAPPING_JSON")"

INTERNAL_CIDR="$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$GENERATED_CONF" | head -n1 | cut -d'=' -f2- | tr -d '[:space:]' | cut -d',' -f1)"
INTERNAL_IP="${INTERNAL_CIDR%/*}"
ENDPOINT_RAW="$(grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$GENERATED_CONF" | head -n1 | cut -d'=' -f2- | tr -d '[:space:]')"
ENDPOINT_HOST="${ENDPOINT_RAW%:*}"
ENDPOINT_HOST="${ENDPOINT_HOST#[}"
ENDPOINT_HOST="${ENDPOINT_HOST%]}"

resolve_endpoint_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$1"; return 0; }
    getent ahostsv4 "$1" | awk '{print $1; exit}'
}

ensure_firewall_chain() {
    iptables -N WG_MULTI_EGRESS 2>/dev/null || true
    iptables -C OUTPUT -j WG_MULTI_EGRESS 2>/dev/null || iptables -I OUTPUT 1 -j WG_MULTI_EGRESS
}

clean_country_network_state() {
    if iptables -L WG_MULTI_EGRESS -n >/dev/null 2>&1; then
        while iptables -D WG_MULTI_EGRESS -s "${INTERNAL_IP}/32" ! -o "${IFACE}" -j REJECT --reject-with icmp-net-unreachable 2>/dev/null; do :; done
        while iptables -D WG_MULTI_EGRESS -s "${INTERNAL_IP}/32" -o "${IFACE}" -m comment --comment "WG-MULTI:${CC}" -j ACCEPT 2>/dev/null; do :; done
    fi
    while iptables -t nat -D POSTROUTING -s "${INTERNAL_IP}/32" -o "${IFACE}" -m comment --comment "WG-MULTI:${CC}" -j MASQUERADE 2>/dev/null; do :; done
    while ip rule del pref "${RULE_PRIO}" 2>/dev/null; do :; done
    while ip rule del from "${INTERNAL_IP}/32" table "${TABLE_ID}" 2>/dev/null; do :; done
    ip route flush table "${TABLE_ID}" 2>/dev/null || true
    ip link show dev "${IFACE}" >/dev/null 2>&1 && ip link del dev "${IFACE}" 2>/dev/null || true
}

case "$ACTION" in
    up)
        ORIG_MAIN_DEF="$(ip -4 route show table main default | head -n1)"
        MAIN_GW="$(echo "$ORIG_MAIN_DEF" | awk '/via/ {for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')"
        MAIN_DEV="$(echo "$ORIG_MAIN_DEF" | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
        clean_country_network_state
        EP_IP="$(resolve_endpoint_ipv4 "$ENDPOINT_HOST" || true)"
        if [[ -n "$EP_IP" && -n "$MAIN_GW" && -n "$MAIN_DEV" ]]; then
            ip route replace "${EP_IP}/32" via "${MAIN_GW}" dev "${MAIN_DEV}" table main metric 50
            mkdir -p "$STATE_DIR" && echo "${EP_IP}" > "${STATE_DIR}/${CC}.endpoint_ip"
        fi
        ip link add dev "${IFACE}" type wireguard
        wg setconf "${IFACE}" <(grep -vE '^[[:space:]]*(Address|Table|DNS|MTU|PreUp|PostUp|PreDown|PostDown)[[:space:]]*=' "$GENERATED_CONF")
        ip -4 address add "${INTERNAL_CIDR}" dev "${IFACE}"
        ip link set mtu 1280 up dev "${IFACE}"

        ip route replace default dev "${IFACE}" table "${TABLE_ID}" metric 100
        ip route replace blackhole default table "${TABLE_ID}" metric 9999
        ip rule add pref "${RULE_PRIO}" from "${INTERNAL_IP}/32" table "${TABLE_ID}"

        ensure_firewall_chain
        iptables -A WG_MULTI_EGRESS -s "${INTERNAL_IP}/32" -o "${IFACE}" -m comment --comment "WG-MULTI:${CC}" -j ACCEPT
        iptables -A WG_MULTI_EGRESS -s "${INTERNAL_IP}/32" ! -o "${IFACE}" -j REJECT --reject-with icmp-net-unreachable
        iptables -t nat -A POSTROUTING -s "${INTERNAL_IP}/32" -o "${IFACE}" -m comment --comment "WG-MULTI:${CC}" -j MASQUERADE
        ;;
    down) clean_country_network_state ;;
esac
EOF
    write_file_atomic "$tunnel_ctl" 0700 "$tunnel_ctl_content"

    local socks_wrapper="${SCRIPTS_DIR}/socks-wrapper.sh"
    local socks_wrapper_content
    read -r -d '' socks_wrapper_content << 'EOF' || true
#!/usr/bin/env bash
set -Eeuo pipefail
CC="${1:-}"
BASE_DIR="/etc/wg-multi"
MAPPING_JSON="${BASE_DIR}/mapping.json"
AUTH_FILE="${BASE_DIR}/auth/${CC}.env"

IFACE="$(jq -r --arg cc "$CC" '.countries[$cc].iface // empty' "$MAPPING_JSON")"
PORT="$(jq -r --arg cc "$CC" '.countries[$cc].port // empty' "$MAPPING_JSON")"

for _ in {1..10}; do
    ip link show dev "$IFACE" 2>/dev/null | grep -q "UP" && break
    sleep 0.5
done

LIVE_IP="$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -n1 || true)"
[[ -z "$LIVE_IP" ]] && exit 1
ip rule show | grep -q "from ${LIVE_IP}" || exit 1

# shellcheck disable=SC1090
source "$AUTH_FILE"
exec "$(command -v microsocks)" -i 127.0.0.1 -p "$PORT" -b "$LIVE_IP" -u "$SOCKS_USER" -P "$SOCKS_PASS"
EOF
    write_file_atomic "$socks_wrapper" 0700 "$socks_wrapper_content"

    write_file_atomic "/etc/systemd/system/wg-multi-tunnel@.service" 0644 '[Unit]
Description=WG-MULTI Isolated WireGuard Tunnel (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/wg-multi/scripts/tunnel-ctl.sh up %i
ExecStop=/etc/wg-multi/scripts/tunnel-ctl.sh down %i

[Install]
WantedBy=multi-user.target'

    write_file_atomic "/etc/systemd/system/wg-multi-socks@.service" 0644 '[Unit]
Description=WG-MULTI Authenticated MicroSocks5 Service (%i)
BindsTo=wg-multi-tunnel@%i.service
After=wg-multi-tunnel@%i.service

[Service]
Type=simple
ExecStart=/etc/wg-multi/scripts/socks-wrapper.sh %i
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target'

    run_cmd systemctl daemon-reload
}

deploy_healthcheck_engine() {
    local hc_script="${SCRIPTS_DIR}/healthcheck.sh"
    local hc_content
    read -r -d '' hc_content << 'EOF' || true
#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="/etc/wg-multi"
MAPPING_JSON="${BASE_DIR}/mapping.json"
STATE_DIR="${BASE_DIR}/state"
AUTH_DIR="${BASE_DIR}/auth"
HEALTH_LOG="/var/log/wg-multi/healthcheck.log"
LOCK_FILE="/run/wg-multi-health.lock"

TARGET_CC="${1:-all}"
mkdir -p "$STATE_DIR" "/var/log/wg-multi"
exec 201>"$LOCK_FILE"
flock -n 201 || exit 0

check_single_country() {
    local cc="$1"
    local iface port enabled
    iface="$(jq -r --arg cc "$cc" '.countries[$cc].iface // empty' "$MAPPING_JSON")"
    port="$(jq -r --arg cc "$cc" '.countries[$cc].port // empty' "$MAPPING_JSON")"
    enabled="$(jq -r --arg cc "$cc" '.countries[$cc].enabled // false' "$MAPPING_JSON")"
    [[ "$enabled" != "true" ]] && return 0

    # shellcheck disable=SC1090
    source "${AUTH_DIR}/${cc}.env"
    ping -c 1 -W 2 -I "$iface" 1.1.1.1 >/dev/null 2>&1 || true

    local status="OFFLINE" public_ip="" detected_country="" detail="Checking..."
    local cf_trace
    cf_trace="$(curl -sS --max-time 10 --socks5-hostname "127.0.0.1:${port}" --proxy-user "${SOCKS_USER}:${SOCKS_PASS}" "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null || true)"
    public_ip="$(echo "$cf_trace" | awk -F= '/^ip=/ {print $2}')"
    detected_country="$(echo "$cf_trace" | awk -F= '/^loc=/ {print $2}')"

    if [[ -n "$public_ip" ]]; then
        status="ONLINE"
        detail="Verified Egress via ${iface}"
    else
        systemctl restart "wg-multi-tunnel@${cc}.service" "wg-multi-socks@${cc}.service" 2>/dev/null || true
    fi

    jq -n --arg cc "$cc" --arg status "$status" --arg public_ip "$public_ip" \
          --arg detected_country "$detected_country" --arg detail "$detail" \
          --arg last_check "$(date '+%Y-%m-%d %H:%M:%S')" \
          '{country:$cc, status:$status, public_ip:$public_ip, detected_country:$detected_country, detail:$detail, last_check:$last_check}' > "${STATE_DIR}/${cc}.json"
    printf "[%s] [%s] [%s] IP=%s Country=%s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$cc" "$status" "$public_ip" "$detected_country" >> "$HEALTH_LOG"
}

[[ ! -f "$MAPPING_JSON" ]] && exit 0
if [[ "$TARGET_CC" == "all" ]]; then
    mapfile -t COUNTRIES < <(jq -r '.countries | keys[]' "$MAPPING_JSON" 2>/dev/null || true)
    for c in "${COUNTRIES[@]}"; do check_single_country "$c" || true; done
else
    check_single_country "$TARGET_CC" || true
fi
EOF
    write_file_atomic "$hc_script" 0700 "$hc_content"
}

deploy_wg_ctl_cli() {
    local ctl_content
    read -r -d '' ctl_content << 'EOF' || true
#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="/etc/wg-multi"
MAPPING_JSON="${BASE_DIR}/mapping.json"
STATE_DIR="${BASE_DIR}/state"
MANAGER_BIN="/usr/local/sbin/wg-multi-manager.sh"

CMD="${1:-status}"
ARG1="${2:-}"

case "$CMD" in
    status)
        [[ ! -f "$MAPPING_JSON" ]] && { echo "هیچ کشوری ثبت نشده است."; exit 0; }
        printf "%-6s | %-10s | %-10s | %-15s | %-6s | %-15s | %-7s | %-19s\n" "CODE" "WG_STATE" "SOCKS5" "LOCAL_BIND" "PORT" "PUBLIC_IP" "GEO" "LAST_CHECK"
        printf "%s\n" "-------------------------------------------------------------------------------------------------------------"
        mapfile -t ccs < <(jq -r '.countries | to_entries | sort_by(.value.port)[] | .key' "$MAPPING_JSON")
        for cc in "${ccs[@]}"; do
            port="$(jq -r --arg c "$cc" '.countries[$c].port' "$MAPPING_JSON")"
            wg_st="INACTIVE"; systemctl is-active --quiet "wg-multi-tunnel@${cc}.service" && wg_st="ACTIVE"
            sk_st="INACTIVE"; systemctl is-active --quiet "wg-multi-socks@${cc}.service" && sk_st="ACTIVE"
            pub_ip="-"; geo="-"; lchk="-"
            if [[ -f "${STATE_DIR}/${cc}.json" ]]; then
                pub_ip="$(jq -r '.public_ip // "-"' "${STATE_DIR}/${cc}.json")"
                geo="$(jq -r '.detected_country // "-"' "${STATE_DIR}/${cc}.json")"
                lchk="$(jq -r '.last_check // "-"' "${STATE_DIR}/${cc}.json")"
            fi
            printf "%-6s | %-10s | %-10s | %-15s | %-6s | %-15s | %-7s | %-19s\n" "$cc" "$wg_st" "$sk_st" "127.0.0.1" "$port" "$pub_ip" "$geo" "$lchk"
        done
        ;;
    test)
        /etc/wg-multi/scripts/healthcheck.sh "${ARG1:-all}"
        "$0" status
        ;;
    add) exec "$MANAGER_BIN" --add "$ARG1" ;;
    remove) exec "$MANAGER_BIN" --remove "$ARG1" ;;
    restart)
        systemctl restart "wg-multi-tunnel@${ARG1}.service" "wg-multi-socks@${ARG1}.service"
        echo "[OK] سرویس ${ARG1} بازنشانی شد."
        ;;
    json) cat "${BASE_DIR}/3x-ui-outbounds.json" ;;
    *) echo "دستورات: wg-ctl [status|test|add CC|remove CC|restart CC|json]" ;;
esac
EOF
    write_file_atomic "/usr/local/bin/wg-ctl" 0755 "$ctl_content"
}

apply_turbo_optimization() {
    modprobe tcp_bbr 2>/dev/null || true
    write_file_atomic "$SYSCTL_TURBO_CONF" 0644 "net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr"
    run_cmd sysctl --system >/dev/null
    msg_ok "بهینه‌سازی شبکه BBR فعال شد."
}

generate_3xui_xray_outbounds() {
    [[ ! -f "$MAPPING_JSON" ]] && return 0
    local xray_file="${BASE_DIR}/3x-ui-outbounds.json"
    local outbounds_json="[]"

    mapfile -t ccs < <(jq -r '.countries | to_entries | sort_by(.value.port)[] | select(.value.enabled == true) | .key' "$MAPPING_JSON" 2>/dev/null || true)
    for cc in "${ccs[@]}"; do
        local port s_user="wg_${cc,,}" s_pass="REDACTED"
        port="$(jq -r --arg c "$cc" '.countries[$c].port' "$MAPPING_JSON")"
        if [[ -f "${AUTH_DIR}/${cc}.env" ]]; then
            # shellcheck disable=SC1090
            source "${AUTH_DIR}/${cc}.env"
            s_user="${SOCKS_USER}"; s_pass="${SOCKS_PASS}"
        fi
        outbounds_json="$(echo "$outbounds_json" | jq \
            --arg tag "wg-${cc,,}-out" --argjson port "$port" --arg user "$s_user" --arg pass "$s_pass" \
            '. + [{tag:$tag, protocol:"socks", settings:{servers:[{address:"127.0.0.1", port:$port, users:[{user:$user, pass:$pass}]}]}}]')"
    done

    write_file_atomic "$xray_file" 0600 "$outbounds_json"
    printf "\n${C_BOLD}${C_GREEN}==================== وضعیت نهایی لوکیشن‌ها ====================${C_RESET}\n"
    [[ "$DRY_RUN" -eq 0 ]] && /usr/local/bin/wg-ctl status || true
    printf "\n${C_BOLD}${C_CYAN}==================== خروجی JSON آماده برای بخش Outbounds پنل 3x-ui ====================${C_RESET}\n"
    echo "$outbounds_json" | jq .
    printf "\n"
}

activate_single_country() {
    local cc="$1"
    validate_and_process_wg_config "$cc"
    allocate_or_update_country_mapping "$cc" "true"
    run_cmd systemctl enable "wg-multi-tunnel@${cc}.service" "wg-multi-socks@${cc}.service"
    run_cmd systemctl restart "wg-multi-tunnel@${cc}.service"
    run_cmd systemctl restart "wg-multi-socks@${cc}.service"
    [[ "$DRY_RUN" -eq 0 ]] && /etc/wg-multi/scripts/healthcheck.sh "$cc" || true
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1; shift ;;
            --add) ACTION="add"; TARGET_ARG="${2:-}"; shift 2 ;;
            --remove) ACTION="remove"; TARGET_ARG="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    acquire_lock "$LOCK_FILE"
    init_runtime_dirs
    persist_self_binary

    case "$ACTION" in
        install)
            check_system_compatibility
            install_dependencies
            deploy_runtime_helper_scripts
            deploy_healthcheck_engine
            deploy_wg_ctl_cli
            auto_bootstrap_warp_if_empty

            shopt -s nullglob
            local -a conf_files=("${CONFIGS_DIR}"/*.conf)
            shopt -u nullglob
            for cfile in "${conf_files[@]}"; do
                activate_single_country "$(basename "$cfile" .conf)"
            done
            apply_turbo_optimization
            generate_3xui_xray_outbounds
            msg_ok "همه‌چیز به‌طور خودکار نصب و راه‌اندازی شد!"
            ;;
        add)
            activate_single_country "$TARGET_ARG"
            generate_3xui_xray_outbounds
            ;;
        remove)
            run_cmd systemctl disable --now "wg-multi-socks@${TARGET_ARG}.service" "wg-multi-tunnel@${TARGET_ARG}.service" 2>/dev/null || true
            msg_ok "کشور ${TARGET_ARG} متوقف شد."
            ;;
    esac
}

main "$@"
