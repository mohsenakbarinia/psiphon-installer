#!/usr/bin/env bash
# ==============================================================================
# Project: WG-MULTI | WireGuard Multi-Location Static Egress Manager
# Edition: Enterprise Production Hardened + Zero-Touch One-Liner Installer (v3.1.0)
# Target OS: Ubuntu 20.04, 22.04, 24.04, 26.04 LTS
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# ==============================================================================
# GITHUB RAW SOURCE URL (برای آپدیت و نصب خودکار در سیستم)
# نام کاربری و مخزن خود را در خط زیر قرار دهید تا دستور wg-ctl همیشه به آن متصل باشد
# ==============================================================================
GITHUB_RAW_URL="${WG_MULTI_REPO_URL:-https://raw.githubusercontent.com/mohsenakbarinia/wg-multi/main/wg-multi-manager.sh}"

# ==============================================================================
# GLOBAL CONSTANTS & PATHS
# ==============================================================================
readonly VERSION="3.1.0-PROD"
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

# Runtime Flags
DRY_RUN=0
ASSUME_YES=0
NON_INTERACTIVE=0
ACTION="install"
TARGET_ARG=""
CLI_BOT_TOKEN=""
CLI_BOT_ADMINS=""
ENABLE_TURBO_ON_INSTALL=0

# ANSI Colors
readonly C_RESET='\033[0m'
readonly C_RED='\033[1;31m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_BLUE='\033[1;34m'
readonly C_CYAN='\033[1;36m'
readonly C_BOLD='\033[1m'

# Rollback Tracking Stack
declare -a ROLLBACK_STACK=()
TRANSACTION_ACTIVE=0
CURRENT_SNAPSHOT=""

# ==============================================================================
# LOGGING & OUTPUT FUNCTIONS
# ==============================================================================
init_runtime_dirs() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi
    mkdir -p "$LOG_DIR" "$BASE_DIR" "$CONFIGS_DIR" "$GENERATED_DIR" \
             "$AUTH_DIR" "$STATE_DIR" "$BACKUP_DIR" "$SCRIPTS_DIR" \
             "$BOT_DIR" "$TURBO_DIR" "/etc/iproute2/rt_tables.d" "/usr/local/sbin"
    chmod 700 "$BASE_DIR" "$CONFIGS_DIR" "$GENERATED_DIR" "$AUTH_DIR" "$BACKUP_DIR" "$BOT_DIR"
    touch "$MAIN_LOG" "$HEALTH_LOG" "$AUDIT_LOG"
    chmod 600 "$MAIN_LOG" "$HEALTH_LOG" "$AUDIT_LOG"
}

sanitize_log_string() {
    local input="$1"
    echo "$input" | sed -E \
        -e 's/(PrivateKey\s*=\s*)[^ ]+/\1[REDACTED]/Ig' \
        -e 's/(PresharedKey\s*=\s*)[^ ]+/\1[REDACTED]/Ig' \
        -e 's/(-P\s+)[^ ]+/\1[REDACTED]/g' \
        -e 's/(SOCKS_PASS=)[^ ]+/\1[REDACTED]/g' \
        -e 's/([0-9]{8,10}:[a-zA-Z0-9_-]{35})/[BOT_TOKEN_REDACTED]/g'
}

log_raw() {
    local level="$1"
    local msg="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local clean_msg
    clean_msg="$(sanitize_log_string "$msg")"
    if [[ "$DRY_RUN" -eq 0 && -d "$LOG_DIR" ]]; then
        printf "[%s] [%s] %s\n" "$ts" "$level" "$clean_msg" >> "$MAIN_LOG"
    fi
}

msg_info() {
    log_raw "INFO" "$1"
    printf "${C_BLUE}[اطلاعات]${C_RESET} %s\n" "$1"
}

msg_ok() {
    log_raw "OK" "$1"
    printf "${C_GREEN}[موفق]${C_RESET} %s\n" "$1"
}

msg_warn() {
    log_raw "WARN" "$1"
    printf "${C_YELLOW}[هشدار]${C_RESET} %s\n" "$1" >&2
}

msg_err() {
    log_raw "ERROR" "$1"
    printf "${C_RED}[خطا]${C_RESET} %s\n" "$1" >&2
}

msg_dry() {
    printf "${C_CYAN}[DRY-RUN]${C_RESET} شبیه‌سازی دستور: %s\n" "$(sanitize_log_string "$*")"
}

# ==============================================================================
# CENTRALIZED EXECUTION LAYER (Strict Dry-Run Enforcement)
# ==============================================================================
run_cmd() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        msg_dry "$*"
        return 0
    fi
    log_raw "EXEC" "$*"
    "$@"
}

write_file_atomic() {
    local target_file="$1"
    local mode="${2:-0600}"
    local content="$3"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        msg_dry "نوشتن فایل اتمیک در مسیر ${target_file} با دسترسی ${mode}"
        return 0
    fi

    local dir
    dir="$(dirname "$target_file")"
    mkdir -p "$dir"
    local tmp_file
    tmp_file="$(mktemp "${dir}/.tmp.XXXXXX")"
    chmod "$mode" "$tmp_file"
    printf "%s\n" "$content" > "$tmp_file"
    sync "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$target_file"
    log_raw "FILE_WRITE" "Wrote ${target_file} (mode ${mode})"
}

# ==============================================================================
# LOCKING, SIGNALS & TRANSACTIONAL ERROR HANDLING
# ==============================================================================
acquire_lock() {
    local lock_path="${1:-$LOCK_FILE}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        msg_dry "دریافت قفل اجرایی روی ${lock_path}"
        return 0
    fi
    exec 200>"$lock_path"
    if ! flock -n 200; then
        msg_err "یک نمونه دیگر از برنامه در حال اجراست (فایل قفل: ${lock_path}). عملیات متوقف شد."
        exit 1
    fi
    echo "$$" >&200
}

register_rollback_cmd() {
    ROLLBACK_STACK+=("$1")
}

execute_rollback_stack() {
    if [[ "${#ROLLBACK_STACK[@]}" -eq 0 ]]; then
        return 0
    fi
    msg_warn "در حال بازگردانی تغییرات ناتمام (Rollback Stack)..."
    local idx
    for (( idx=${#ROLLBACK_STACK[@]}-1 ; idx>=0 ; idx-- )) ; do
        local rcmd="${ROLLBACK_STACK[$idx]}"
        log_raw "ROLLBACK_EXEC" "$rcmd"
        if [[ "$DRY_RUN" -eq 0 ]]; then
            bash -c "$rcmd" >/dev/null 2>&1 || true
        else
            msg_dry "Rollback: $rcmd"
        fi
    done
    ROLLBACK_STACK=()
}

on_error_trap() {
    local exit_code=$?
    local line_no=$1
    msg_err "خطای غیرمنتظره در خط ${line_no} (کد خروجی: ${exit_code})."
    if [[ "$TRANSACTION_ACTIVE" -eq 1 ]]; then
        msg_warn "تراکنش فعال دچار خطا شد. شروع عملیات بازگردانی خودکار (Auto-Rollback)..."
        execute_rollback_stack
        if [[ -n "$CURRENT_SNAPSHOT" && -d "$CURRENT_SNAPSHOT" && "$DRY_RUN" -eq 0 ]]; then
            msg_warn "بازگردانی Snapshot سیستم از مسیر: ${CURRENT_SNAPSHOT}"
            restore_snapshot_internal "$CURRENT_SNAPSHOT" || true
        fi
    fi
    exit "$exit_code"
}

on_signal_trap() {
    msg_warn "سیگنال توقف (SIGINT/SIGTERM) دریافت شد. در حال پاکسازی ایمن..."
    if [[ "$TRANSACTION_ACTIVE" -eq 1 ]]; then
        execute_rollback_stack
    fi
    exit 130
}

trap 'on_error_trap $LINENO' ERR
trap 'on_signal_trap' SIGINT SIGTERM

# ==============================================================================
# SELF-PERSISTENCE FOR ONE-LINER CURL EXECUTION
# ==============================================================================
persist_self_binary() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        msg_dry "ذخیره دائمی اسکریپت در ${SELF_INSTALLED_PATH}"
        return 0
    fi

    # If executed as a regular file on disk, copy directly
    if [[ -f "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != /dev/fd/* && "${BASH_SOURCE[0]}" != "bash" ]]; then
        if [[ "$(realpath "${BASH_SOURCE[0]}")" != "$SELF_INSTALLED_PATH" ]]; then
            cp -f "${BASH_SOURCE[0]}" "$SELF_INSTALLED_PATH"
            chmod 0700 "$SELF_INSTALLED_PATH"
        fi
        return 0
    fi

    # If executed via curl | bash or process substitution, fetch cleanly from GitHub Raw URL
    if [[ ! -f "$SELF_INSTALLED_PATH" ]] || [[ "$ACTION" == "update" ]]; then
        msg_info "در حال دریافت و ثبت نسخه دائمی اسکریپت در ${SELF_INSTALLED_PATH} ..."
        local tmp_self
        tmp_self="$(mktemp /tmp/wg-multi-self.XXXXXX)"
        if curl -fsSL --max-time 20 "$GITHUB_RAW_URL" -o "$tmp_self" && grep -q "WG-MULTI" "$tmp_self"; then
            chmod 0700 "$tmp_self"
            mv -f "$tmp_self" "$SELF_INSTALLED_PATH"
            msg_ok "فایل اجرایی اصلی در ${SELF_INSTALLED_PATH} ثبت شد."
        else
            rm -f "$tmp_self"
            msg_warn "امکان دانلود مجدد از ${GITHUB_RAW_URL} نبود؛ مطمئن شوید آدرس مخزن گیت‌هاب در ابتدای اسکریپت صحیح است."
        fi
    fi
}

# ==============================================================================
# INPUT VALIDATION & SECURITY HELPERS
# ==============================================================================
validate_country_code() {
    local cc="$1"
    if [[ ! "$cc" =~ ^[A-Z]{2,4}$ ]]; then
        msg_err "کد کشور نامعتبر است: '${cc}'. فقط ۲ تا ۴ حرف بزرگ انگلیسی مجاز است (مثال: US, NL, JP)."
        return 1
    fi
    return 0
}

country_to_iface() {
    local cc="$1"
    validate_country_code "$cc"
    echo "wg$(echo "$cc" | tr '[:upper:]' '[:lower:]')"
}

validate_ipv4_cidr() {
    local ip_cidr="$1"
    if [[ ! "$ip_cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        return 1
    fi
    local ip="${ip_cidr%/*}"
    local mask="${ip_cidr#*/}"
    if [[ "$ip" != "$mask" ]]; then
        if (( mask < 0 || mask > 32 )); then return 1; fi
    fi
    local IFS='.'
    read -r -a octets <<< "$ip"
    for oct in "${octets[@]}"; do
        if (( oct < 0 || oct > 255 )); then return 1; fi
    done
    return 0
}

validate_wg_key() {
    local key="$1"
    if [[ ${#key} -ne 44 ]]; then
        return 1
    fi
    if [[ ! "$key" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
        return 1
    fi
    return 0
}

generate_secure_password() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 || true
}

# ==============================================================================
# UBUNTU & ENVIRONMENT COMPATIBILITY AUDIT
# ==============================================================================
check_system_compatibility() {
    msg_info "در حال بررسی پیش‌نیازها و سازگاری سیستم‌عامل..."

    if [[ "$EUID" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
        msg_err "این اسکریپت باید با دسترسی root اجرا شود."
        exit 1
    fi

    if [[ ! -d /run/systemd/system ]]; then
        msg_err "سیستم مدیریت سرویس systemd شناسایی نشد."
        exit 1
    fi

    if [[ ! -f /etc/os-release ]]; then
        msg_err "فایل /etc/os-release یافت نشد."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]]; then
        case "${VERSION_ID:-}" in
            20.04|22.04|24.04|26.04)
                msg_ok "نسخه سیستم‌عامل تایید شد: Ubuntu ${VERSION_ID} (${VERSION_CODENAME:-})"
                ;;
            *)
                msg_warn "نسخه Ubuntu (${VERSION_ID:-}) خارج از لیست LTS استاندارد است، ادامه می‌دهیم."
                ;;
        esac
    else
        msg_warn "سیستم‌عامل '${ID:-unknown}' شناسایی شد (پیشنهادی: Ubuntu LTS)."
    fi

    msg_info "معماری پردازنده: $(uname -m) | نسخه کرنل: $(uname -r)"
}

install_dependencies() {
    msg_info "بررسی و نصب خودکار پکیج‌های موردنیاز از مخازن رسمی Ubuntu..."

    local -a required_pkgs=(
        wireguard
        wireguard-tools
        iproute2
        iptables
        curl
        jq
        ca-certificates
        netcat-openbsd
        psmisc
        uuid-runtime
        util-linux
    )

    local -a missing_pkgs=()
    for pkg in "${required_pkgs[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing_pkgs+=("$pkg")
        fi
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
        msg_info "نصب خودکار پکیج‌ها: ${missing_pkgs[*]}"
        run_cmd env DEBIAN_FRONTEND=noninteractive apt-get update -y
        run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_pkgs[@]}"
    else
        msg_ok "تمامی پکیج‌های پایه نصب هستند."
    fi

    if [[ "$need_microsocks_build" -eq 1 ]]; then
        msg_info "کامپایل خودکار MicroSocks از سورس رسمی (rofl0r/microsocks)..."
        if [[ "$DRY_RUN" -eq 1 ]]; then
            msg_dry "git clone https://github.com/rofl0r/microsocks && make && install -m 0755 microsocks /usr/local/bin/microsocks"
        else
            local build_dir
            build_dir="$(mktemp -d /tmp/microsocks-build.XXXXXX)"
            git clone --depth 1 https://github.com/rofl0r/microsocks.git "$build_dir"
            make -C "$build_dir"
            install -m 0755 "${build_dir}/microsocks" /usr/local/bin/microsocks
            rm -rf "$build_dir"
            msg_ok "باینری microsocks کامپایل و نصب شد."
        fi
    fi
}

# ==============================================================================
# INTELLIGENT WIREGUARD CONFIG VALIDATION & SANITIZATION
# ==============================================================================
validate_and_process_wg_config() {
    local cc="$1"
    local src_conf="${CONFIGS_DIR}/${cc}.conf"
    local dst_conf="${GENERATED_DIR}/${cc}.conf"

    validate_country_code "$cc"

    if [[ ! -f "$src_conf" ]]; then
        msg_err "[${cc}] فایل کانفیگ اصلی در مسیر ${src_conf} یافت نشد."
        return 1
    fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        chmod 0600 "$src_conf"
    fi

    local has_interface=0 has_peer=0 current_section=""
    local priv_key="" address_raw="" address_ipv4=""
    local pub_key="" endpoint="" endpoint_port="" allowed_ips=""
    local line_num=0 validation_failed=0

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line_num=$((line_num + 1))
        local line
        line="$(echo "$raw_line" | sed -E 's/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^\[([A-Za-z]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            if [[ "$current_section" == "Interface" ]]; then
                has_interface=1
            elif [[ "$current_section" == "Peer" ]]; then
                has_peer=1
            else
                msg_err "[${cc}] خط ${line_num}: بخش ناشناخته [${current_section}]."
                validation_failed=1
            fi
            continue
        fi

        if [[ "$line" =~ ^([A-Za-z]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"

            if [[ "$current_section" == "Interface" ]]; then
                case "$key" in
                    PrivateKey)
                        priv_key="$val"
                        if ! validate_wg_key "$priv_key"; then
                            msg_err "[${cc}] خط ${line_num}: PrivateKey نامعتبر است."
                            validation_failed=1
                        fi
                        ;;
                    Address)
                        address_raw="$val"
                        local IFS=','
                        read -r -a addr_parts <<< "$address_raw"
                        for part in "${addr_parts[@]}"; do
                            part="$(echo "$part" | tr -d '[:space:]')"
                            if validate_ipv4_cidr "$part"; then
                                address_ipv4="$part"
                                break
                            fi
                        done
                        if [[ -z "$address_ipv4" ]]; then
                            msg_err "[${cc}] خط ${line_num}: آدرس IPv4 معتبر در Address یافت نشد (${address_raw})."
                            validation_failed=1
                        fi
                        ;;
                    DNS|Table|PreUp|PostUp|PreDown|PostDown|MTU|ListenPort|FwMark) ;;
                esac
            elif [[ "$current_section" == "Peer" ]]; then
                case "$key" in
                    PublicKey)
                        pub_key="$val"
                        if ! validate_wg_key "$pub_key"; then
                            msg_err "[${cc}] خط ${line_num}: PublicKey نامعتبر است."
                            validation_failed=1
                        fi
                        ;;
                    Endpoint)
                        endpoint="$val"
                        if [[ "$endpoint" =~ ^\[?([a-zA-Z0-9._:-]+)\]?:([0-9]{1,5})$ ]]; then
                            endpoint_port="${BASH_REMATCH[2]}"
                            if (( endpoint_port < 1 || endpoint_port > 65535 )); then
                                msg_err "[${cc}] خط ${line_num}: پورت Endpoint نامعتبر است: ${endpoint_port}"
                                validation_failed=1
                            fi
                        else
                            msg_err "[${cc}] خط ${line_num}: فرمت Endpoint نامعتبر است (${endpoint})."
                            validation_failed=1
                        fi
                        ;;
                    AllowedIPs)
                        allowed_ips="$val"
                        ;;
                    PresharedKey)
                        if ! validate_wg_key "$val"; then
                            msg_err "[${cc}] خط ${line_num}: PresharedKey نامعتبر است."
                            validation_failed=1
                        fi
                        ;;
                esac
            fi
        else
            msg_err "[${cc}] خط ${line_num}: خطای نحوی در '${line}'."
            validation_failed=1
        fi
    done < "$src_conf"

    [[ "$has_interface" -eq 0 ]] && { msg_err "[${cc}] بخش [Interface] یافت نشد."; validation_failed=1; }
    [[ "$has_peer" -eq 0 ]] && { msg_err "[${cc}] بخش [Peer] یافت نشد."; validation_failed=1; }
    [[ -z "$priv_key" ]] && { msg_err "[${cc}] کلید PrivateKey یافت نشد."; validation_failed=1; }
    [[ -z "$address_ipv4" ]] && { msg_err "[${cc}] کلید Address یافت نشد."; validation_failed=1; }
    [[ -z "$pub_key" ]] && { msg_err "[${cc}] کلید PublicKey یافت نشد."; validation_failed=1; }
    [[ -z "$endpoint" ]] && { msg_err "[${cc}] کلید Endpoint یافت نشد."; validation_failed=1; }
    [[ -z "$allowed_ips" ]] && { msg_err "[${cc}] کلید AllowedIPs یافت نشد."; validation_failed=1; }

    [[ "$validation_failed" -ne 0 ]] && return 1

    # Check IP & Config collisions across existing countries
    local internal_ip_only="${address_ipv4%/*}"
    local other_conf
    shopt -s nullglob
    for other_conf in "${CONFIGS_DIR}"/*.conf; do
        local other_cc
        other_cc="$(basename "$other_conf" .conf)"
        [[ "$other_cc" == "$cc" ]] && continue

        local other_addr other_ip other_ep other_priv
        other_addr="$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$other_conf" | head -n1 | cut -d'=' -f2- | tr -d '[:space:]' || true)"
        other_ip="${other_addr%%/*}"
        other_ip="${other_ip%%,*}"

        if [[ "$other_ip" == "$internal_ip_only" ]]; then
            msg_err "[${cc}] تداخل IP داخلی (${internal_ip_only}) با کشور '${other_cc}'!"
            return 1
        fi

        other_ep="$(grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$other_conf" | head -n1 | cut -d'=' -f2- | tr -d '[:space:]' || true)"
        other_priv="$(grep -E '^[[:space:]]*PrivateKey[[:space:]]*=' "$other_conf" | head -n1 | cut -d'=' -f2- | tr -d '[:space:]' || true)"
        if [[ "$other_ep" == "$endpoint" && "$other_priv" == "$priv_key" ]]; then
            msg_err "[${cc}] کانفیگ تکراری با کشور '${other_cc}'!"
            return 1
        fi
    done
    shopt -u nullglob

    local generated_content
    generated_content="$(awk '
        BEGIN { in_peer=0; has_keepalive=0; }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[Interface\]/ {
            print "[Interface]"
            print "Table = off"
            in_peer=0
            next
        }
        /^[[:space:]]*\[Peer\]/ {
            if (in_peer && !has_keepalive) {
                print "PersistentKeepalive = 25"
            }
            print "\n[Peer]"
            in_peer=1
            has_keepalive=0
            next
        }
        /^[[:space:]]*(DNS|Table|PreUp|PostUp|PreDown|PostDown)[[:space:]]*=/ { next }
        /^[[:space:]]*PersistentKeepalive[[:space:]]*=/ {
            has_keepalive=1
            print $0
            next
        }
        { print $0 }
        END {
            if (in_peer && !has_keepalive) {
                print "PersistentKeepalive = 25"
            }
        }
    ' "$src_conf")"

    write_file_atomic "$dst_conf" 0600 "$generated_content"
    msg_ok "[${cc}] اعتبارسنجی موفق بود (IP داخلی: ${internal_ip_only} | Endpoint: ${endpoint})."
}

extract_config_metadata() {
    local cc="$1"
    local field="$2"
    local conf_file="${GENERATED_DIR}/${cc}.conf"
    [[ ! -f "$conf_file" ]] && conf_file="${CONFIGS_DIR}/${cc}.conf"
    [[ ! -f "$conf_file" ]] && return 1

    case "$field" in
        internal_ip)
            local raw_addr
            raw_addr="$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$conf_file" | head -n1 | cut -d'=' -f2- | tr -d '[:space:]')"
            local first_ipv4="${raw_addr%%,*}"
            echo "${first_ipv4%/*}"
            ;;
    esac
}

# ==============================================================================
# INTELLIGENT ATOMIC PORT & MAPPING MANAGER
# ==============================================================================
init_mapping_store() {
    if [[ ! -f "$MAPPING_JSON" ]]; then
        write_file_atomic "$MAPPING_JSON" 0600 '{"countries":{}}'
    fi
    if [[ ! -f "$MAPPING_TXT" ]]; then
        write_file_atomic "$MAPPING_TXT" 0600 "# COUNTRY|IFACE|PORT|TABLE_ID|RULE_PRIO|INTERNAL_IP|ENABLED"
    fi
}

is_port_in_use_by_other() {
    local port="$1"
    local expected_cc="${2:-}"

    if [[ -f "$MAPPING_JSON" ]]; then
        local owner
        owner="$(jq -r --argjson p "$port" '.countries | to_entries[] | select(.value.port == $p) | .key' "$MAPPING_JSON" 2>/dev/null || true)"
        if [[ -n "$owner" && "$owner" != "$expected_cc" ]]; then
            return 0
        fi
    fi

    if ss -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(:|\\])${port}$"; then
        if [[ -n "$expected_cc" ]] && systemctl is-active --quiet "wg-multi-socks@${expected_cc}.service" 2>/dev/null; then
            return 1
        fi
        return 0
    fi
    return 1
}

allocate_or_update_country_mapping() {
    local cc="$1"
    local enabled="${2:-true}"
    validate_country_code "$cc"
    init_mapping_store

    local iface internal_ip
    iface="$(country_to_iface "$cc")"
    internal_ip="$(extract_config_metadata "$cc" "internal_ip")"

    local current_json="{}"
    [[ -f "$MAPPING_JSON" ]] && current_json="$(cat "$MAPPING_JSON")"

    local assigned_port assigned_table assigned_prio
    assigned_port="$(echo "$current_json" | jq -r --arg cc "$cc" '.countries[$cc].port // empty')"
    assigned_table="$(echo "$current_json" | jq -r --arg cc "$cc" '.countries[$cc].table_id // empty')"
    assigned_prio="$(echo "$current_json" | jq -r --arg cc "$cc" '.countries[$cc].rule_prio // empty')"

    if [[ -z "$assigned_port" ]]; then
        local candidate_port="$START_PORT"
        while is_port_in_use_by_other "$candidate_port" "$cc"; do
            candidate_port=$((candidate_port + 1))
            (( candidate_port > 65000 )) && { msg_err "هیچ پورت آزادی یافت نشد!"; return 1; }
        done
        assigned_port="$candidate_port"
    fi

    if [[ -z "$assigned_table" ]]; then
        local candidate_table="$START_TABLE_ID"
        while true; do
            local used_in_json used_in_sys=""
            used_in_json="$(echo "$current_json" | jq -r --argjson t "$candidate_table" '.countries | to_entries[] | select(.value.table_id == $t) | .key')"
            [[ -f /etc/iproute2/rt_tables ]] && used_in_sys="$(awk -v t="$candidate_table" '$1 == t {print $2}' /etc/iproute2/rt_tables || true)"
            [[ -z "$used_in_json" && -z "$used_in_sys" ]] && break
            candidate_table=$((candidate_table + 1))
        done
        assigned_table="$candidate_table"
    fi

    if [[ -z "$assigned_prio" ]]; then
        local candidate_prio="$START_RULE_PRIO"
        while true; do
            local used_prio
            used_prio="$(echo "$current_json" | jq -r --argjson pr "$candidate_prio" '.countries | to_entries[] | select(.value.rule_prio == $pr) | .key')"
            [[ -z "$used_prio" ]] && break
            candidate_prio=$((candidate_prio + 10))
        done
        assigned_prio="$candidate_prio"
    fi

    local auth_file="${AUTH_DIR}/${cc}.env"
    if [[ ! -f "$auth_file" ]]; then
        local socks_user="wg_${cc,,}"
        local socks_pass
        socks_pass="$(generate_secure_password)"
        write_file_atomic "$auth_file" 0600 "SOCKS_USER=${socks_user}"$'\n'"SOCKS_PASS=${socks_pass}"
    fi

    local updated_json
    updated_json="$(echo "$current_json" | jq \
        --arg cc "$cc" \
        --arg iface "$iface" \
        --argjson port "$assigned_port" \
        --argjson table_id "$assigned_table" \
        --argjson rule_prio "$assigned_prio" \
        --arg internal_ip "$internal_ip" \
        --argjson enabled "$enabled" \
        --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '.countries[$cc] = {
            iface: $iface,
            port: $port,
            table_id: $table_id,
            rule_prio: $rule_prio,
            internal_ip: $internal_ip,
            enabled: $enabled,
            updated_at: $updated_at
        }')"

    write_file_atomic "$MAPPING_JSON" 0600 "$updated_json"

    local txt_content="# COUNTRY|IFACE|PORT|TABLE_ID|RULE_PRIO|INTERNAL_IP|ENABLED"
    while IFS= read -r line; do
        [[ -n "$line" ]] && txt_content+=$'\n'"$line"
    done < <(echo "$updated_json" | jq -r '.countries | to_entries | sort_by(.value.port)[] | "\(.key)|\(.value.iface)|\(.value.port)|\(.value.table_id)|\(.value.rule_prio)|\(.value.internal_ip)|\(.value.enabled)"')
    write_file_atomic "$MAPPING_TXT" 0600 "$txt_content"

    local rt_content="# Managed by WG-MULTI - Do not edit manually"
    while IFS= read -r rline; do
        [[ -n "$rline" ]] && rt_content+=$'\n'"$rline"
    done < <(echo "$updated_json" | jq -r '.countries | to_entries | sort_by(.value.table_id)[] | "\(.value.table_id)\t\(.value.iface)_rt"')
    write_file_atomic "$RT_TABLES_CONF" 0644 "$rt_content"

    msg_ok "[${cc}] تخصیص منابع: اینترفیس ${iface} | پورت ${assigned_port} | جدول ${assigned_table}"
}

set_country_enabled_state() {
    local cc="$1"
    local state_bool="$2"
    [[ ! -f "$MAPPING_JSON" ]] && return 0
    local updated_json
    updated_json="$(jq --arg cc "$cc" --argjson en "$state_bool" '
        if .countries[$cc] then .countries[$cc].enabled = $en else . end
    ' "$MAPPING_JSON")"
    write_file_atomic "$MAPPING_JSON" 0600 "$updated_json"
}

# ==============================================================================
# ROUTING, ANTI-LEAK FIREWALL, MICROSOCKS & SYSTEMD UNITS
# ==============================================================================
deploy_runtime_helper_scripts() {
    msg_info "ایجاد اسکریپت‌های اجرایی مدیریت تونل، مسیریابی، فایروال و MicroSocks..."

    local tunnel_ctl="${SCRIPTS_DIR}/tunnel-ctl.sh"
    local tunnel_ctl_content
    read -r -d '' tunnel_ctl_content << 'EOF' || true
#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-}"
CC="${2:-}"
BASE_DIR="/etc/wg-multi"
MAPPING_JSON="${BASE_DIR}/mapping.json"
GENERATED_CONF="${BASE_DIR}/generated/${CC}.conf"
STATE_DIR="${BASE_DIR}/state"

if [[ -z "$ACTION" || -z "$CC" || ! -f "$MAPPING_JSON" ]]; then
    echo "Usage: $0 <up|down> <COUNTRY_CODE>" >&2
    exit 1
fi

IFACE="$(jq -r --arg cc "$CC" '.countries[$cc].iface // empty' "$MAPPING_JSON")"
TABLE_ID="$(jq -r --arg cc "$CC" '.countries[$cc].table_id // empty' "$MAPPING_JSON")"
RULE_PRIO="$(jq -r --arg cc "$CC" '.countries[$cc].rule_prio // empty' "$MAPPING_JSON")"

if [[ -z "$IFACE" || -z "$TABLE_ID" || -z "$RULE_PRIO" ]]; then
    echo "[ERROR] Missing mapping metadata for ${CC}" >&2
    exit 1
fi

INTERNAL_CIDR="$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$GENERATED_CONF" | head -n1 | cut -d'=' -f2- | tr -d '[:space:]' | cut -d',' -f1)"
INTERNAL_IP="${INTERNAL_CIDR%/*}"
ENDPOINT_RAW="$(grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$GENERATED_CONF" | head -n1 | cut -d'=' -f2- | tr -d '[:space:]')"
ENDPOINT_HOST="${ENDPOINT_RAW%:*}"
ENDPOINT_HOST="${ENDPOINT_HOST#[}"
ENDPOINT_HOST="${ENDPOINT_HOST%]}"

resolve_endpoint_ipv4() {
    local host="$1"
    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$host"
        return 0
    fi
    getent ahostsv4 "$host" | awk '{print $1; exit}'
}

ensure_firewall_chain() {
    iptables -N WG_MULTI_EGRESS 2>/dev/null || true
    if ! iptables -C OUTPUT -j WG_MULTI_EGRESS 2>/dev/null; then
        iptables -I OUTPUT 1 -j WG_MULTI_EGRESS
    fi
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

    if ip link show dev "${IFACE}" >/dev/null 2>&1; then
        ip link del dev "${IFACE}" 2>/dev/null || true
    fi
}

case "$ACTION" in
    up)
        ORIG_MAIN_DEF="$(ip -4 route show table main default | head -n1)"
        if [[ -z "$ORIG_MAIN_DEF" ]]; then
            echo "[ERROR] Server has no primary default route in table main!" >&2
            exit 1
        fi
        MAIN_GW="$(echo "$ORIG_MAIN_DEF" | awk '/via/ {for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')"
        MAIN_DEV="$(echo "$ORIG_MAIN_DEF" | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"

        clean_country_network_state

        EP_IP="$(resolve_endpoint_ipv4 "$ENDPOINT_HOST" || true)"
        if [[ -n "$EP_IP" && -n "$MAIN_GW" && -n "$MAIN_DEV" ]]; then
            ip route replace "${EP_IP}/32" via "${MAIN_GW}" dev "${MAIN_DEV}" table main metric 50
            mkdir -p "$STATE_DIR"
            echo "${EP_IP}" > "${STATE_DIR}/${CC}.endpoint_ip"
        fi

        ip link add dev "${IFACE}" type wireguard
        wg setconf "${IFACE}" <(grep -vE '^[[:space:]]*(Address|Table|DNS|MTU|PreUp|PostUp|PreDown|PostDown)[[:space:]]*=' "$GENERATED_CONF")
        ip -4 address add "${INTERNAL_CIDR}" dev "${IFACE}"

        CONF_MTU="$(grep -E '^[[:space:]]*MTU[[:space:]]*=' "$GENERATED_CONF" | head -n1 | cut -d'=' -f2- | tr -d '[:space:]' || true)"
        if [[ -n "$CONF_MTU" ]]; then
            ip link set mtu "$CONF_MTU" up dev "${IFACE}"
        else
            ip link set mtu 1420 up dev "${IFACE}"
        fi

        ip route replace default dev "${IFACE}" table "${TABLE_ID}" metric 100
        ip route replace blackhole default table "${TABLE_ID}" metric 9999

        ip rule add pref "${RULE_PRIO}" from "${INTERNAL_IP}/32" table "${TABLE_ID}"

        ensure_firewall_chain
        iptables -A WG_MULTI_EGRESS -s "${INTERNAL_IP}/32" -o "${IFACE}" -m comment --comment "WG-MULTI:${CC}" -j ACCEPT
        iptables -A WG_MULTI_EGRESS -s "${INTERNAL_IP}/32" ! -o "${IFACE}" -j REJECT --reject-with icmp-net-unreachable
        iptables -t nat -A POSTROUTING -s "${INTERNAL_IP}/32" -o "${IFACE}" -m comment --comment "WG-MULTI:${CC}" -j MASQUERADE

        NEW_MAIN_DEF="$(ip -4 route show table main default | head -n1)"
        if [[ "$ORIG_MAIN_DEF" != "$NEW_MAIN_DEF" ]]; then
            echo "[CRITICAL] Main default route changed unexpectedly! Restoring immediately..." >&2
            clean_country_network_state
            exit 1
        fi
        ;;
    down)
        clean_country_network_state
        ;;
    *)
        echo "Invalid action: $ACTION" >&2
        exit 1
        ;;
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
GENERATED_CONF="${BASE_DIR}/generated/${CC}.conf"
AUTH_FILE="${BASE_DIR}/auth/${CC}.env"

if [[ -z "$CC" || ! -f "$MAPPING_JSON" || ! -f "$GENERATED_CONF" || ! -f "$AUTH_FILE" ]]; then
    echo "[ERROR] Missing configuration or auth files for ${CC}" >&2
    exit 1
fi

IFACE="$(jq -r --arg cc "$CC" '.countries[$cc].iface // empty' "$MAPPING_JSON")"
PORT="$(jq -r --arg cc "$CC" '.countries[$cc].port // empty' "$MAPPING_JSON")"

for _ in {1..10}; do
    if ip link show dev "$IFACE" 2>/dev/null | grep -q "UP"; then
        break
    fi
    sleep 0.5
done

LIVE_IP="$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -n1 || true)"

if [[ -z "$LIVE_IP" ]]; then
    echo "[ERROR] Interface ${IFACE} has no active IPv4 address! Refusing to start MicroSocks." >&2
    exit 1
fi

if ! ip rule show | grep -q "from ${LIVE_IP}"; then
    echo "[ERROR] Policy routing rule for ${LIVE_IP} is missing! Refusing to start MicroSocks (Fail-Closed)." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$AUTH_FILE"

if [[ -z "${SOCKS_USER:-}" || -z "${SOCKS_PASS:-}" ]]; then
    echo "[ERROR] Invalid credentials in ${AUTH_FILE}" >&2
    exit 1
fi

MICROSOCKS_BIN="$(command -v microsocks)"
exec "$MICROSOCKS_BIN" -i 127.0.0.1 -p "$PORT" -b "$LIVE_IP" -u "$SOCKS_USER" -P "$SOCKS_PASS"
EOF
    write_file_atomic "$socks_wrapper" 0700 "$socks_wrapper_content"

    local tunnel_unit="/etc/systemd/system/wg-multi-tunnel@.service"
    local tunnel_unit_content
    read -r -d '' tunnel_unit_content << 'EOF' || true
[Unit]
Description=WG-MULTI Isolated WireGuard Tunnel (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/wg-multi/scripts/tunnel-ctl.sh up %i
ExecStop=/etc/wg-multi/scripts/tunnel-ctl.sh down %i
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wg-tunnel-%i

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
ReadWritePaths=/etc/wg-multi /run /var/log/wg-multi
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_MODULE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_MODULE

[Install]
WantedBy=multi-user.target
EOF
    write_file_atomic "$tunnel_unit" 0644 "$tunnel_unit_content"

    local socks_unit="/etc/systemd/system/wg-multi-socks@.service"
    local socks_unit_content
    read -r -d '' socks_unit_content << 'EOF' || true
[Unit]
Description=WG-MULTI Authenticated MicroSocks5 Service (%i)
BindsTo=wg-multi-tunnel@%i.service
After=wg-multi-tunnel@%i.service

[Service]
Type=simple
ExecStart=/etc/wg-multi/scripts/socks-wrapper.sh %i
Restart=on-failure
RestartSec=3s
StartLimitIntervalSec=60
StartLimitBurst=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wg-socks-%i

LimitNOFILE=65535
MemoryMax=64M
CPUQuota=50%
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadOnlyPaths=/etc/wg-multi
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF
    write_file_atomic "$socks_unit" 0644 "$socks_unit_content"

    run_cmd systemctl daemon-reload
}

# ==============================================================================
# MULTI-STAGE HEALTHCHECK & AUTO-RECOVERY ENGINE
# ==============================================================================
deploy_healthcheck_engine() {
    msg_info "پیاده‌سازی موتور پایش ۶ مرحله‌ای (Healthcheck) و بازیابی خودکار..."

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
if ! flock -n 201; then
    exit 0
fi

log_hc() {
    printf "[%s] [%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" "$3" >> "$HEALTH_LOG"
}

save_state() {
    local cc="$1" st="$2" fc="$3" rc="$4" lrt="$5" pip="$6" dco="$7" det="$8"
    local sfile="${STATE_DIR}/${cc}.json"
    local tmp="${sfile}.tmp.$$"

    jq -n \
        --arg cc "$cc" \
        --arg status "$st" \
        --argjson fail_count "$fc" \
        --argjson recovery_count "$rc" \
        --argjson last_recovery_ts "$lrt" \
        --arg public_ip "$pip" \
        --arg detected_country "$dco" \
        --arg detail "$det" \
        --arg last_check "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{
            country: $cc,
            status: $status,
            fail_count: $fail_count,
            recovery_count: $recovery_count,
            last_recovery_ts: $last_recovery_ts,
            public_ip: $public_ip,
            detected_country: $detected_country,
            detail: $detail,
            last_check: $last_check
        }' > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$sfile"
}

check_single_country() {
    local cc="$1"
    local iface port internal_ip enabled
    iface="$(jq -r --arg cc "$cc" '.countries[$cc].iface // empty' "$MAPPING_JSON")"
    port="$(jq -r --arg cc "$cc" '.countries[$cc].port // empty' "$MAPPING_JSON")"
    internal_ip="$(jq -r --arg cc "$cc" '.countries[$cc].internal_ip // empty' "$MAPPING_JSON")"
    enabled="$(jq -r --arg cc "$cc" '.countries[$cc].enabled // false' "$MAPPING_JSON")"

    [[ "$enabled" != "true" ]] && return 0

    local state_file="${STATE_DIR}/${cc}.json"
    local prev_fail_count=0 prev_recovery_count=0 last_recovery_ts=0 prev_public_ip="" prev_country=""

    if [[ -f "$state_file" ]]; then
        prev_fail_count="$(jq -r '.fail_count // 0' "$state_file" 2>/dev/null || echo 0)"
        prev_recovery_count="$(jq -r '.recovery_count // 0' "$state_file" 2>/dev/null || echo 0)"
        last_recovery_ts="$(jq -r '.last_recovery_ts // 0' "$state_file" 2>/dev/null || echo 0)"
        prev_public_ip="$(jq -r '.public_ip // ""' "$state_file" 2>/dev/null || echo "")"
        prev_country="$(jq -r '.detected_country // ""' "$state_file" 2>/dev/null || echo "")"
    fi

    local gen_conf="${BASE_DIR}/generated/${cc}.conf"
    local auth_file="${AUTH_DIR}/${cc}.env"
    if [[ ! -f "$gen_conf" || ! -f "$auth_file" ]]; then
        save_state "$cc" "CONFIG_ERROR" "$prev_fail_count" "$prev_recovery_count" "$last_recovery_ts" "" "" "Missing config/auth"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$auth_file"

    local status="ONLINE" detail="All 6 stages passed" public_ip="" detected_country="" stage_failed=0

    # Stage 1: Interface & Live IP
    local live_ip=""
    if ! ip link show dev "$iface" >/dev/null 2>&1; then
        status="OFFLINE"
        detail="Stage 1 Failed: Interface ${iface} missing"
        stage_failed=1
    else
        live_ip="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -n1 || true)"
        if [[ -z "$live_ip" ]]; then
            status="OFFLINE"
            detail="Stage 1 Failed: No IPv4 on ${iface}"
            stage_failed=1
        elif [[ "$live_ip" != "$internal_ip" ]]; then
            systemctl restart "wg-multi-socks@${cc}.service" 2>/dev/null || true
        fi
    fi

    # Stage 2: Handshake
    if [[ "$stage_failed" -eq 0 ]]; then
        local latest_hs hs_age
        latest_hs="$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2}' | head -n1 || echo 0)"
        hs_age=$(( $(date +%s) - latest_hs ))
        if [[ "$latest_hs" -eq 0 || "$hs_age" -gt 240 ]]; then
            ping -c 1 -W 2 -I "$iface" 1.1.1.1 >/dev/null 2>&1 || true
            latest_hs="$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2}' | head -n1 || echo 0)"
            hs_age=$(( $(date +%s) - latest_hs ))
        fi
        if [[ "$latest_hs" -eq 0 || "$hs_age" -gt 300 ]]; then
            status="DEGRADED"
            detail="Stage 2 Warning: Handshake stale (${hs_age}s)"
        fi
    fi

    # Stage 3, 4 & 5: SOCKS5 Egress & Public IP/Country
    if [[ "$stage_failed" -eq 0 ]]; then
        if ! systemctl is-active --quiet "wg-multi-socks@${cc}.service"; then
            status="OFFLINE"
            detail="Stage 4 Failed: SOCKS5 service inactive"
            stage_failed=4
        else
            local curl_out http_code json_body
            curl_out="$(curl -sS --max-time 10 \
                --socks5-hostname "127.0.0.1:${port}" \
                --proxy-user "${SOCKS_USER}:${SOCKS_PASS}" \
                -w "\n%{http_code}" \
                "https://ipinfo.io/json" 2>&1 || true)"

            http_code="$(echo "$curl_out" | tail -n1)"
            json_body="$(echo "$curl_out" | sed '$d')"

            if [[ "$http_code" == "407" ]] || echo "$curl_out" | grep -qi "authentication"; then
                status="AUTH_ERROR"
                detail="Stage 4 Failed: SOCKS5 Auth error"
                stage_failed=4
            elif [[ "$http_code" == "200" ]] && echo "$json_body" | jq -e . >/dev/null 2>&1; then
                public_ip="$(echo "$json_body" | jq -r '.ip // empty')"
                detected_country="$(echo "$json_body" | jq -r '.country // empty')"
            else
                # Cloudflare fallback
                local cf_trace
                cf_trace="$(curl -sS --max-time 8 --socks5-hostname "127.0.0.1:${port}" --proxy-user "${SOCKS_USER}:${SOCKS_PASS}" "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null || true)"
                public_ip="$(echo "$cf_trace" | awk -F= '/^ip=/ {print $2}')"
                detected_country="$(echo "$cf_trace" | awk -F= '/^loc=/ {print $2}')"
                if [[ -z "$public_ip" ]]; then
                    status="OFFLINE"
                    detail="Stage 4/5 Failed: Egress unreachable"
                    stage_failed=5
                fi
            fi
        fi
    fi

    # Stage 6: Consistency Check
    if [[ "$stage_failed" -eq 0 && -n "$public_ip" ]]; then
        if [[ -n "$prev_country" && -n "$detected_country" && "$prev_country" != "$detected_country" ]]; then
            status="IP_MISMATCH"
            detail="Stage 6 Alert: Country changed (${prev_country} -> ${detected_country})"
        fi
    fi

    if [[ "$stage_failed" -gt 0 ]]; then
        prev_fail_count=$((prev_fail_count + 1))
        log_hc "$cc" "$status" "${detail} (Failures: ${prev_fail_count})"

        if (( prev_fail_count >= 3 )); then
            local now_epoch cooldown_elapsed
            now_epoch="$(date +%s)"
            cooldown_elapsed=$(( now_epoch - last_recovery_ts ))

            if (( cooldown_elapsed >= 300 && prev_recovery_count < 5 )); then
                status="RECOVERING"
                prev_recovery_count=$((prev_recovery_count + 1))
                last_recovery_ts="$now_epoch"

                if [[ "$stage_failed" -eq 4 ]]; then
                    systemctl restart "wg-multi-socks@${cc}.service" 2>/dev/null || true
                else
                    systemctl restart "wg-multi-tunnel@${cc}.service" 2>/dev/null || true
                    systemctl restart "wg-multi-socks@${cc}.service" 2>/dev/null || true
                fi

                sleep 2
                local retest_ip
                retest_ip="$(curl -sS --max-time 8 --socks5-hostname "127.0.0.1:${port}" --proxy-user "${SOCKS_USER}:${SOCKS_PASS}" "https://ipinfo.io/ip" 2>/dev/null | tr -d '[:space:]' || true)"
                if [[ "$retest_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                    status="ONLINE"
                    public_ip="$retest_ip"
                    prev_fail_count=0
                    detail="Recovered on attempt #${prev_recovery_count}"
                    log_hc "$cc" "ONLINE" "$detail (IP: ${public_ip})"
                else
                    status="OFFLINE"
                    detail="Recovery attempt #${prev_recovery_count} failed"
                fi
            fi
        fi
    else
        prev_fail_count=0
        prev_recovery_count=0
        log_hc "$cc" "$status" "${detail} | IP=${public_ip} | Geo=${detected_country}"
    fi

    save_state "$cc" "$status" "$prev_fail_count" "$prev_recovery_count" "$last_recovery_ts" "$public_ip" "$detected_country" "$detail"
}

[[ ! -f "$MAPPING_JSON" ]] && exit 0

if [[ "$TARGET_CC" == "all" ]]; then
    mapfile -t COUNTRIES < <(jq -r '.countries | keys[]' "$MAPPING_JSON" 2>/dev/null || true)
    for c in "${COUNTRIES[@]}"; do
        check_single_country "$c" || true
    done
else
    check_single_country "$TARGET_CC" || true
fi
EOF
    write_file_atomic "$hc_script" 0700 "$hc_content"

    local hc_service="/etc/systemd/system/wg-multi-healthcheck.service"
    local hc_service_content
    read -r -d '' hc_service_content << 'EOF' || true
[Unit]
Description=WG-MULTI Multi-Stage Healthcheck & Auto-Recovery Runner
After=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/wg-multi/scripts/healthcheck.sh all
NoNewPrivileges=yes
PrivateTmp=yes
EOF
    write_file_atomic "$hc_service" 0644 "$hc_service_content"

    local hc_timer="/etc/systemd/system/wg-multi-healthcheck.timer"
    local hc_timer_content
    read -r -d '' hc_timer_content << 'EOF' || true
[Unit]
Description=Run WG-MULTI Healthcheck every 2 minutes

[Timer]
OnBootSec=45s
OnUnitActiveSec=2min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF
    write_file_atomic "$hc_timer" 0644 "$hc_timer_content"

    run_cmd systemctl daemon-reload
    run_cmd systemctl enable --now wg-multi-healthcheck.timer
}

# ==============================================================================
# TRANSACTIONAL BACKUP, SNAPSHOT & ROLLBACK SYSTEM
# ==============================================================================
create_system_snapshot() {
    local label="${1:-auto}"
    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    local snap_dir="${BACKUP_DIR}/snap_${ts}_${label}"

    msg_info "تهیه نسخه پشتیبان (Snapshot): $(basename "$snap_dir") ..."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        msg_dry "ایجاد Snapshot در ${snap_dir}"
        CURRENT_SNAPSHOT="$snap_dir"
        return 0
    fi

    mkdir -p "${snap_dir}/etc_wg_multi" "${snap_dir}/systemd" "${snap_dir}/network"
    chmod 0700 "$snap_dir"

    for item in configs generated auth state scripts bot turbo mapping.json mapping.txt; do
        [[ -e "${BASE_DIR}/${item}" ]] && cp -a "${BASE_DIR}/${item}" "${snap_dir}/etc_wg_multi/"
    done

    ip -4 rule show > "${snap_dir}/network/ip_rules.txt" 2>/dev/null || true
    ip -4 route show table all > "${snap_dir}/network/ip_routes_all.txt" 2>/dev/null || true
    [[ -f "$RT_TABLES_CONF" ]] && cp -a "$RT_TABLES_CONF" "${snap_dir}/network/wg-multi.rt_tables.conf"
    iptables-save > "${snap_dir}/network/iptables.rules" 2>/dev/null || true
    [[ -f "$SYSCTL_TURBO_CONF" ]] && cp -a "$SYSCTL_TURBO_CONF" "${snap_dir}/network/"

    for unit in /etc/systemd/system/wg-multi*; do
        [[ -e "$unit" ]] && cp -a "$unit" "${snap_dir}/systemd/"
    done

    (cd "$snap_dir" && find . -type f -exec sha256sum {} + > "${snap_dir}/MANIFEST.sha256")
    CURRENT_SNAPSHOT="$snap_dir"

    local -a snaps=()
    mapfile -t snaps < <(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -name "snap_*" | sort -r)
    if (( ${#snaps[@]} > MAX_BACKUPS )); then
        local i
        for (( i=MAX_BACKUPS; i<${#snaps[@]}; i++ )); do
            rm -rf "${snaps[$i]}"
        done
    fi
}

restore_snapshot_internal() {
    local snap_dir="$1"
    if [[ -z "$snap_dir" ]]; then
        snap_dir="$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -name "snap_*" | sort -r | head -n1 || true)"
    fi

    if [[ -z "$snap_dir" || ! -d "$snap_dir" ]]; then
        msg_err "نسخه پشتیبانی یافت نشد."
        return 1
    fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        if ! (cd "$snap_dir" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1); then
            msg_err "اعتبارسنجی Checksum نسخه پشتیبان ناموفق بود!"
            return 1
        fi
    else
        msg_dry "بازگردانی Snapshot از ${snap_dir}"
        return 0
    fi

    if [[ -f "$MAPPING_JSON" ]]; then
        mapfile -t active_ccs < <(jq -r '.countries | keys[]' "$MAPPING_JSON" 2>/dev/null || true)
        for cc in "${active_ccs[@]}"; do
            systemctl stop "wg-multi-socks@${cc}.service" 2>/dev/null || true
            systemctl stop "wg-multi-tunnel@${cc}.service" 2>/dev/null || true
        done
    fi

    for item in configs generated auth state scripts bot turbo mapping.json mapping.txt; do
        rm -rf "${BASE_DIR:?}/${item}"
        [[ -e "${snap_dir}/etc_wg_multi/${item}" ]] && cp -a "${snap_dir}/etc_wg_multi/${item}" "${BASE_DIR}/"
    done

    [[ -f "${snap_dir}/network/wg-multi.rt_tables.conf" ]] && cp -a "${snap_dir}/network/wg-multi.rt_tables.conf" "$RT_TABLES_CONF"
    if [[ -d "${snap_dir}/systemd" ]]; then
        cp -a "${snap_dir}/systemd/"* /etc/systemd/system/ 2>/dev/null || true
        systemctl daemon-reload
    fi

    if [[ -f "$MAPPING_JSON" ]]; then
        mapfile -t restored_ccs < <(jq -r '.countries | to_entries[] | select(.value.enabled == true) | .key' "$MAPPING_JSON" 2>/dev/null || true)
        for cc in "${restored_ccs[@]}"; do
            systemctl start "wg-multi-tunnel@${cc}.service" 2>/dev/null || true
            systemctl start "wg-multi-socks@${cc}.service" 2>/dev/null || true
        done
    fi
    msg_ok "بازگردانی $(basename "$snap_dir") با موفقیت انجام شد."
}

# ==============================================================================
# REVERTIBLE TURBO KERNEL OPTIMIZATION MODULE
# ==============================================================================
apply_turbo_optimization() {
    msg_info "اجرای ماژول بهینه‌سازی شبکه (Turbo Mode)..."

    local -a keys_to_track=(
        "net.core.default_qdisc"
        "net.ipv4.tcp_congestion_control"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.core.netdev_max_backlog"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.ipv4.udp_rmem_min"
        "net.ipv4.udp_wmem_min"
    )

    if [[ ! -f "$TURBO_BACKUP_FILE" ]]; then
        local backup_data="# Original sysctl values saved before WG-MULTI Turbo"
        for k in "${keys_to_track[@]}"; do
            local val
            val="$(sysctl -n "$k" 2>/dev/null | tr '\t' ' ' || true)"
            [[ -n "$val" ]] && backup_data+=$'\n'"${k} = ${val}"
        done
        write_file_atomic "$TURBO_BACKUP_FILE" 0600 "$backup_data"
    fi

    local mem_kb max_buf=16777216 backlog=16384
    mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    if (( mem_kb > 8000000 )); then
        max_buf=67108864; backlog=65536
    elif (( mem_kb > 2000000 )); then
        max_buf=33554432; backlog=32768
    fi

    local bbr_supported=0
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "bbr" && bbr_supported=1

    local turbo_conf="# Managed by WG-MULTI Turbo Optimizer"
    if [[ "$bbr_supported" -eq 1 ]]; then
        turbo_conf+=$'\n'"net.core.default_qdisc = fq"
        turbo_conf+=$'\n'"net.ipv4.tcp_congestion_control = bbr"
    fi

    turbo_conf+=$'\n'"net.core.rmem_max = ${max_buf}"
    turbo_conf+=$'\n'"net.core.wmem_max = ${max_buf}"
    turbo_conf+=$'\n'"net.core.netdev_max_backlog = ${backlog}"
    turbo_conf+=$'\n'"net.ipv4.tcp_rmem = 4096 87380 ${max_buf}"
    turbo_conf+=$'\n'"net.ipv4.tcp_wmem = 4096 65536 ${max_buf}"
    turbo_conf+=$'\n'"net.ipv4.udp_rmem_min = 16384"
    turbo_conf+=$'\n'"net.ipv4.udp_wmem_min = 16384"

    write_file_atomic "$SYSCTL_TURBO_CONF" 0644 "$turbo_conf"
    run_cmd sysctl --system >/dev/null
    msg_ok "تنظیمات Turbo با موفقیت اعمال شد (BBR=${bbr_supported})."
}

revert_turbo_optimization() {
    msg_info "بازگردانی تنظیمات کرنل (--turbo-revert)..."
    [[ ! -f "$TURBO_BACKUP_FILE" ]] && { msg_warn "فایل پشتیبان Turbo یافت نشد."; return 0; }
    run_cmd rm -f "$SYSCTL_TURBO_CONF"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        sysctl -p "$TURBO_BACKUP_FILE" >/dev/null 2>&1 || true
        rm -f "$TURBO_BACKUP_FILE"
    else
        msg_dry "sysctl -p ${TURBO_BACKUP_FILE}"
    fi
    msg_ok "تنظیمات کرنل دقیقاً به حالت اولیه بازگردانده شد."
}

# ==============================================================================
# ADVANCED READ-ONLY NET DOCTOR
# ==============================================================================
run_net_doctor() {
    printf "\n${C_BOLD}${C_CYAN}==================== گزارش تشخیصی WG-MULTI NET DOCTOR ====================${C_RESET}\n"
    printf "%-34s | %-10s | %-10s | %s\n" "TEST NAME" "RESULT" "DURATION" "DETAILS"
    printf "%s\n" "--------------------------------------------------------------------------------------------------------"

    run_diag_step() {
        local name="$1" cmd_fn="$2" start_ms end_ms dur_ms out rc=0
        start_ms="$(date +%s%3N)"
        out="$($cmd_fn 2>&1)" || rc=$?
        end_ms="$(date +%s%3N)"
        dur_ms=$(( end_ms - start_ms ))
        local badge="${C_GREEN}PASS${C_RESET}"
        [[ "$rc" -ne 0 ]] && badge="${C_RED}FAIL${C_RESET}"
        printf "%-34s | %b       | %-8s | %s\n" "$name" "$badge" "${dur_ms}ms" "$out"
    }

    diag_default_gw() { local gw; gw="$(ip -4 route show table main default | awk '/via/ {print $3; exit}')"; [[ -n "$gw" ]] && echo "Gateway: ${gw}" || return 1; }
    diag_default_route() { local rt; rt="$(ip -4 route show table main default | head -n1)"; [[ -n "$rt" ]] && echo "$rt" || return 1; }
    diag_time_sync() { timedatectl status 2>/dev/null | grep -qi "synchronized: yes" && echo "NTP Synchronized" || echo "NTP Unsynced"; }
    diag_dns() { local ip; ip="$(getent ahostsv4 ipinfo.io | awk '{print $1; exit}' || true)"; [[ -n "$ip" ]] && echo "ipinfo.io -> ${ip}" || return 1; }
    diag_tcp() { nc -z -w 3 1.1.1.1 443 >/dev/null 2>&1 && echo "TCP 1.1.1.1:443 OK" || return 1; }
    diag_https_tls() { local c; c="$(curl -sS --max-time 6 -o /dev/null -w "%{http_code}" https://ipinfo.io/json || true)"; [[ "$c" == "200" || "$c" == "429" ]] && echo "TLS Valid (HTTP ${c})" || return 1; }
    diag_mtu() { ping -c 1 -W 2 -M do -s 1472 1.1.1.1 >/dev/null 2>&1 && echo "MTU 1500 OK (WG: 1420)" || echo "Restricted MTU (Rec WG: 1360)"; }
    diag_pkt_loss() { local l; l="$(ping -c 4 -i 0.2 -W 2 1.1.1.1 2>/dev/null | awk -F',' '/packet loss/ {print $3}' | tr -d ' ' || echo "100%")"; [[ "$l" == "0%packetloss" ]] && echo "0% loss" || { echo "$l"; return 1; }; }
    diag_server_pub_ip() { local ip; ip="$(curl -sS --max-time 5 https://ipinfo.io/ip 2>/dev/null | tr -d '[:space:]' || true)"; [[ -n "$ip" ]] && echo "VPS IP: ${ip}" || return 1; }

    run_diag_step "1. Default Gateway" diag_default_gw
    run_diag_step "2. Default Route" diag_default_route
    run_diag_step "3. System Time Sync" diag_time_sync
    run_diag_step "4. DNS Resolution" diag_dns
    run_diag_step "5. TCP Connectivity" diag_tcp
    run_diag_step "6. HTTPS & TLS Validation" diag_https_tls
    run_diag_step "7. Path MTU Discovery" diag_mtu
    run_diag_step "8. Packet Loss Check" diag_pkt_loss
    run_diag_step "9. Primary Server Public IP" diag_server_pub_ip

    if [[ -f "$MAPPING_JSON" ]]; then
        mapfile -t ccs < <(jq -r '.countries | keys[]' "$MAPPING_JSON" 2>/dev/null || true)
        for cc in "${ccs[@]}"; do
            diag_country_full() {
                local iface port table_id internal_ip
                iface="$(jq -r --arg c "$cc" '.countries[$c].iface' "$MAPPING_JSON")"
                port="$(jq -r --arg c "$cc" '.countries[$c].port' "$MAPPING_JSON")"
                table_id="$(jq -r --arg c "$cc" '.countries[$c].table_id' "$MAPPING_JSON")"
                internal_ip="$(jq -r --arg c "$cc" '.countries[$c].internal_ip' "$MAPPING_JSON")"
                ip rule show | grep -q "from ${internal_ip}" || { echo "Missing IP Rule"; return 1; }
                # shellcheck disable=SC1090
                source "${AUTH_DIR}/${cc}.env" 2>/dev/null || return 1
                local out_ip
                out_ip="$(curl -sS --max-time 7 --socks5-hostname "127.0.0.1:${port}" --proxy-user "${SOCKS_USER}:${SOCKS_PASS}" https://ipinfo.io/ip 2>/dev/null | tr -d '[:space:]' || true)"
                [[ -n "$out_ip" ]] && echo "IF=${iface} Port=${port} Table=${table_id} EgressIP=${out_ip}" || { echo "SOCKS5 Unreachable"; return 1; }
            }
            run_diag_step "10. Tunnel [${cc}] Policy & SOCKS5" diag_country_full
        done
    fi
    printf "%s\n\n" "--------------------------------------------------------------------------------------------------------"
}

# ==============================================================================
# OPTIONAL TELEGRAM BOT MODULE
# ==============================================================================
deploy_telegram_bot_module() {
    local bot_token="${1:-}"
    local admin_ids="${2:-}"

    [[ -z "$bot_token" || -z "$admin_ids" ]] && return 0

    if [[ ! "$bot_token" =~ ^[0-9]{8,10}:[a-zA-Z0-9_-]{35}$ ]]; then
        msg_err "فرمت توکن ربات تلگرام نامعتبر است."
        return 1
    fi
    if [[ ! "$admin_ids" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        msg_err "شناسه‌های مدیران باید اعداد جداشده با ویرگول باشند."
        return 1
    fi

    write_file_atomic "${BOT_DIR}/bot.env" 0600 "TG_BOT_TOKEN=${bot_token}"$'\n'"TG_ADMIN_IDS=${admin_ids}"

    local bot_daemon="${BOT_DIR}/tg-bot-daemon.sh"
    local bot_daemon_content
    read -r -d '' bot_daemon_content << 'EOF' || true
#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/etc/wg-multi"
BOT_ENV="${BASE_DIR}/bot/bot.env"
MAPPING_JSON="${BASE_DIR}/mapping.json"
STATE_DIR="${BASE_DIR}/state"
HEALTH_LOG="/var/log/wg-multi/healthcheck.log"

[[ ! -f "$BOT_ENV" ]] && exit 0
# shellcheck disable=SC1090
source "$BOT_ENV"
API_URL="https://api.telegram.org/bot${TG_BOT_TOKEN}"
OFFSET=0
LAST_DAILY_DATE=""
declare -A RATE_LIMIT_TS=()
declare -A PENDING_CONFIRM=()

is_admin_authorized() {
    local chat_id="$1"
    [[ "$chat_id" =~ ^[0-9]+$ ]] || return 1
    IFS=',' read -r -a admins <<< "$TG_ADMIN_IDS"
    for adm in "${admins[@]}"; do
        [[ "$adm" == "$chat_id" ]] && return 0
    done
    return 1
}

send_tg_message() {
    local chat_id="$1" text="$2"
    local keyboard='{"keyboard":[[{"text":"وضعیت تمام کشورها"},{"text":"تست IP"}],[{"text":"مشاهده Ping"},{"text":"وضعیت سرور اصلی"}],[{"text":"آخرین خطاها"},{"text":"گزارش روزانه"}]],"resize_keyboard":true}'
    curl -sS --max-time 10 -X POST "${API_URL}/sendMessage" \
        -d "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "reply_markup=${keyboard}" >/dev/null 2>&1 || true
}

build_summary_report() {
    local report="📊 گزارش وضعیت WG-MULTI"$'\n'"------------------------"$'\n'
    [[ ! -f "$MAPPING_JSON" ]] && { echo "هیچ کشوری ثبت نشده است."; return; }
    mapfile -t ccs < <(jq -r '.countries | keys[]' "$MAPPING_JSON" 2>/dev/null || true)
    for cc in "${ccs[@]}"; do
        local port st="UNKNOWN" ip="-" dco="-"
        port="$(jq -r --arg c "$cc" '.countries[$c].port' "$MAPPING_JSON")"
        if [[ -f "${STATE_DIR}/${cc}.json" ]]; then
            st="$(jq -r '.status // "UNKNOWN"' "${STATE_DIR}/${cc}.json")"
            ip="$(jq -r '.public_ip // "-"' "${STATE_DIR}/${cc}.json")"
            dco="$(jq -r '.detected_country // "-"' "${STATE_DIR}/${cc}.json")"
        fi
        report+="🔹 [${cc}] | Port: ${port} | Status: ${st} | IP: ${ip} (${dco})"$'\n'
    done
    echo "$report"
}

while true; do
    CUR_HR="$(date '+%H')"
    CUR_DT="$(date '+%Y-%m-%d')"
    if [[ "$CUR_HR" == "09" && "$LAST_DAILY_DATE" != "$CUR_DT" ]]; then
        LAST_DAILY_DATE="$CUR_DT"
        IFS=',' read -r -a admins <<< "$TG_ADMIN_IDS"
        for adm in "${admins[@]}"; do
            send_tg_message "$adm" "📅 گزارش روزانه خودکار:"$'\n'"$(build_summary_report)"
        done
    fi

    UPDATES="$(curl -sS --max-time 25 "${API_URL}/getUpdates?offset=${OFFSET}&timeout=20" 2>/dev/null || true)"
    if [[ -z "$UPDATES" ]] || ! echo "$UPDATES" | jq -e '.ok == true' >/dev/null 2>&1; then
        sleep 5
        continue
    fi

    COUNT="$(echo "$UPDATES" | jq '.result | length')"
    for (( i=0; i<COUNT; i++ )); do
        UPD_ID="$(echo "$UPDATES" | jq -r ".result[$i].update_id")"
        OFFSET=$((UPD_ID + 1))
        CHAT_ID="$(echo "$UPDATES" | jq -r ".result[$i].message.chat.id // empty")"
        TEXT="$(echo "$UPDATES" | jq -r ".result[$i].message.text // empty")"

        [[ -z "$CHAT_ID" || -z "$TEXT" ]] && continue
        is_admin_authorized "$CHAT_ID" || continue

        NOW_S="$(date +%s)"
        LAST_S="${RATE_LIMIT_TS[$CHAT_ID]:-0}"
        (( NOW_S - LAST_S < 2 )) && continue
        RATE_LIMIT_TS[$CHAT_ID]="$NOW_S"

        case "$TEXT" in
            "/start"|"وضعیت تمام کشورها"|"گزارش روزانه")
                send_tg_message "$CHAT_ID" "$(build_summary_report)"
                ;;
            "تست IP")
                /etc/wg-multi/scripts/healthcheck.sh all || true
                send_tg_message "$CHAT_ID" "✅ تست زنده انجام شد:"$'\n'"$(build_summary_report)"
                ;;
            "مشاهده Ping")
                PING_MSG="📡 وضعیت پینگ تونل‌ها به 1.1.1.1:"$'\n'
                mapfile -t ccs < <(jq -r '.countries | keys[]' "$MAPPING_JSON" 2>/dev/null || true)
                for cc in "${ccs[@]}"; do
                    IFACE="$(jq -r --arg c "$cc" '.countries[$c].iface' "$MAPPING_JSON")"
                    P_RES="$(ping -c 2 -W 2 -I "$IFACE" 1.1.1.1 2>/dev/null | awk -F'/' 'END{ if(/^rtt/) print $5" ms"; else print "Timeout" }')"
                    PING_MSG+="🔸 ${cc} (${IFACE}): ${P_RES}"$'\n'
                done
                send_tg_message "$CHAT_ID" "$PING_MSG"
                ;;
            "وضعیت سرور اصلی")
                send_tg_message "$CHAT_ID" "🖥 وضعیت سرور:"$'\n'"Uptime: $(uptime -p)"$'\n'"Load: $(awk '{print $1,$2,$3}' /proc/loadavg)"$'\n'"RAM: $(free -m | awk '/Mem:/ {printf "%d/%d MB", $3, $2}')"
                ;;
            "آخرین خطاها")
                ERRS="$(grep -E '\[(OFFLINE|AUTH_ERROR|CONFIG_ERROR|IP_MISMATCH|RECOVERING)\]' "$HEALTH_LOG" 2>/dev/null | tail -n 10 || echo "خطایی ثبت نشده است.")"
                send_tg_message "$CHAT_ID" "⚠️ آخرین خطاها:"$'\n'"${ERRS}"
                ;;
            /restart_*)
                TARGET_CC="${TEXT#/restart_}"
                if [[ "$TARGET_CC" =~ ^[A-Z]{2,4}$ ]] && jq -e --arg c "$TARGET_CC" '.countries[$c]' "$MAPPING_JSON" >/dev/null 2>&1; then
                    PENDING_CONFIRM[$CHAT_ID]="$TARGET_CC"
                    send_tg_message "$CHAT_ID" "❓ برای تأیید Restart کشور ${TARGET_CC} بفرستید:"$'\n'"/confirm_restart_${TARGET_CC}"
                fi
                ;;
            /confirm_restart_*)
                TARGET_CC="${TEXT#/confirm_restart_}"
                if [[ "${PENDING_CONFIRM[$CHAT_ID]:-}" == "$TARGET_CC" ]]; then
                    unset 'PENDING_CONFIRM[$CHAT_ID]'
                    systemctl restart "wg-multi-tunnel@${TARGET_CC}.service" "wg-multi-socks@${TARGET_CC}.service" 2>/dev/null || true
                    send_tg_message "$CHAT_ID" "✅ سرویس کشور ${TARGET_CC} Restart شد."
                fi
                ;;
        esac
    done
done
EOF
    write_file_atomic "$bot_daemon" 0700 "$bot_daemon_content"

    local bot_unit="/etc/systemd/system/wg-multi-bot.service"
    local bot_unit_content
    read -r -d '' bot_unit_content << 'EOF' || true
[Unit]
Description=WG-MULTI Standalone Telegram Bot Service
After=network-online.target

[Service]
Type=simple
ExecStart=/etc/wg-multi/bot/tg-bot-daemon.sh
Restart=always
RestartSec=10s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
    write_file_atomic "$bot_unit" 0644 "$bot_unit_content"
    run_cmd systemctl daemon-reload
    run_cmd systemctl enable --now wg-multi-bot.service
    msg_ok "ربات تلگرام با موفقیت فعال شد."
}

# ==============================================================================
# WG-CTL CLI MANAGEMENT UTILITY DEPLOYMENT
# ==============================================================================
deploy_wg_ctl_cli() {
    msg_info "نصب ابزار خط فرمان /usr/local/bin/wg-ctl ..."

    local ctl_path="/usr/local/bin/wg-ctl"
    local ctl_content
    read -r -d '' ctl_content << 'EOF' || true
#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/etc/wg-multi"
MAPPING_JSON="${BASE_DIR}/mapping.json"
STATE_DIR="${BASE_DIR}/state"
MANAGER_BIN="/usr/local/sbin/wg-multi-manager.sh"

CMD="${1:-help}"
ARG1="${2:-}"
ARG2="${3:-}"

validate_cc() {
    local cc="$1"
    if [[ ! "$cc" =~ ^[A-Z]{2,4}$ ]]; then
        echo "خطا: کد کشور '${cc}' نامعتبر است (مثال: US, NL, JP)." >&2
        exit 1
    fi
}

case "$CMD" in
    list)
        [[ ! -f "$MAPPING_JSON" ]] && { echo "هیچ کشوری ثبت نشده است."; exit 0; }
        printf "%-8s | %-8s | %-8s | %-8s | %-15s | %-8s\n" "COUNTRY" "IFACE" "PORT" "TABLE" "INTERNAL_IP" "ENABLED"
        printf "%s\n" "----------------------------------------------------------------------"
        jq -r '.countries | to_entries | sort_by(.value.port)[] | "\(.key)|\(.value.iface)|\(.value.port)|\(.value.table_id)|\(.value.internal_ip)|\(.value.enabled)"' "$MAPPING_JSON" | \
        while IFS='|' read -r cc iface port tbl iip en; do
            printf "%-8s | %-8s | %-8s | %-8s | %-15s | %-8s\n" "$cc" "$iface" "$port" "$tbl" "$iip" "$en"
        done
        ;;
    status)
        [[ ! -f "$MAPPING_JSON" ]] && { echo "هیچ کشوری ثبت نشده است."; exit 0; }
        printf "%-6s | %-10s | %-10s | %-15s | %-6s | %-15s | %-7s | %-19s\n" \
            "CODE" "WG_STATE" "SOCKS5" "LOCAL_BIND" "PORT" "PUBLIC_IP" "GEO" "LAST_CHECK"
        printf "%s\n" "-------------------------------------------------------------------------------------------------------------"
        mapfile -t ccs < <(jq -r '.countries | to_entries | sort_by(.value.port)[] | .key' "$MAPPING_JSON")
        for cc in "${ccs[@]}"; do
            port="$(jq -r --arg c "$cc" '.countries[$c].port' "$MAPPING_JSON")"
            wg_st="INACTIVE"
            systemctl is-active --quiet "wg-multi-tunnel@${cc}.service" && wg_st="ACTIVE"
            sk_st="INACTIVE"
            systemctl is-active --quiet "wg-multi-socks@${cc}.service" && sk_st="ACTIVE"
            pub_ip="-"; geo="-"; lchk="-"
            if [[ -f "${STATE_DIR}/${cc}.json" ]]; then
                pub_ip="$(jq -r '.public_ip // "-"' "${STATE_DIR}/${cc}.json")"
                geo="$(jq -r '.detected_country // "-"' "${STATE_DIR}/${cc}.json")"
                lchk="$(jq -r '.last_check // "-"' "${STATE_DIR}/${cc}.json")"
            fi
            printf "%-6s | %-10s | %-10s | %-15s | %-6s | %-15s | %-7s | %-19s\n" \
                "$cc" "$wg_st" "$sk_st" "127.0.0.1" "$port" "$pub_ip" "$geo" "$lchk"
        done
        ;;
    test)
        if [[ -z "$ARG1" || "$ARG1" == "all" ]]; then
            /etc/wg-multi/scripts/healthcheck.sh all
            "$0" status
        else
            validate_cc "$ARG1"
            /etc/wg-multi/scripts/healthcheck.sh "$ARG1"
            jq . "${STATE_DIR}/${ARG1}.json" 2>/dev/null || true
        fi
        ;;
    restart)
        if [[ "$ARG1" == "all" ]]; then
            mapfile -t ccs < <(jq -r '.countries | to_entries[] | select(.value.enabled == true) | .key' "$MAPPING_JSON")
            for cc in "${ccs[@]}"; do
                systemctl restart "wg-multi-tunnel@${cc}.service" "wg-multi-socks@${cc}.service"
                echo "[OK] سرویس کشور ${cc} بازنشانی شد."
            done
        else
            validate_cc "$ARG1"
            systemctl restart "wg-multi-tunnel@${ARG1}.service" "wg-multi-socks@${ARG1}.service"
            echo "[OK] سرویس کشور ${ARG1} بازنشانی شد."
        fi
        ;;
    logs)
        validate_cc "$ARG1"
        if [[ "$ARG2" == "-f" ]]; then
            journalctl -u "wg-multi-tunnel@${ARG1}.service" -u "wg-multi-socks@${ARG1}.service" -f
        else
            journalctl -u "wg-multi-tunnel@${ARG1}.service" -u "wg-multi-socks@${ARG1}.service" -n 50 --no-pager
        fi
        ;;
    healthcheck)
        /etc/wg-multi/scripts/healthcheck.sh all
        tail -n 30 /var/log/wg-multi/healthcheck.log
        ;;
    add)
        validate_cc "$ARG1"
        exec "$MANAGER_BIN" --add "$ARG1"
        ;;
    remove)
        validate_cc "$ARG1"
        exec "$MANAGER_BIN" --remove "$ARG1"
        ;;
    inspect)
        validate_cc "$ARG1"
        iface="$(jq -r --arg c "$ARG1" '.countries[$c].iface // empty' "$MAPPING_JSON")"
        table_id="$(jq -r --arg c "$ARG1" '.countries[$c].table_id // empty' "$MAPPING_JSON")"
        echo "=== Mapping Info (${ARG1}) ==="
        jq --arg c "$ARG1" '.countries[$c]' "$MAPPING_JSON"
        echo "=== WireGuard Interface (${iface}) ==="
        wg show "$iface" 2>/dev/null || echo "Interface down"
        echo "=== Dedicated Routing Table (${table_id}) ==="
        ip route show table "$table_id" 2>/dev/null || true
        echo "=== Latest Health State ==="
        jq . "${STATE_DIR}/${ARG1}.json" 2>/dev/null || true
        ;;
    backup) exec "$MANAGER_BIN" --backup ;;
    restore) exec "$MANAGER_BIN" --restore "$ARG1" ;;
    doctor) exec "$MANAGER_BIN" --net-doctor ;;
    firewall)
        echo "=== WG-MULTI Egress Anti-Leak Chain ==="
        iptables -L WG_MULTI_EGRESS -n -v --line-numbers 2>/dev/null || echo "Chain not initialized."
        echo "=== WG-MULTI NAT Rules ==="
        iptables -t nat -L POSTROUTING -n -v | grep "WG-MULTI" || echo "No NAT rules."
        ;;
    version) exec "$MANAGER_BIN" --version ;;
    help|*)
        cat << 'EOH'
ابزار مدیریت خط فرمان WG-MULTI (wg-ctl)
دستورات:
  wg-ctl list               نمایش لیست کشورها، پورت‌ها و جداول مسیریابی
  wg-ctl status             نمایش وضعیت لحظه‌ای WireGuard، SOCKS5 و IP خروجی
  wg-ctl test <CC|all>      تست زنده ۶ مرحله‌ای برای یک کشور یا همه کشورها
  wg-ctl restart <CC|all>   راه‌اندازی مجدد تونل و SOCKS5
  wg-ctl logs <CC> [-f]     مشاهده لاگ‌های اختصاصی کشور
  wg-ctl healthcheck        اجرای پایش سلامت و نمایش لاگ
  wg-ctl add <CC>           افزودن کشور جدید (از /etc/wg-multi/configs/<CC>.conf)
  wg-ctl remove <CC>        غیرفعال‌سازی ایمن یک کشور بدون آسیب به سایرین
  wg-ctl inspect <CC>       نمایش جزئیات فنی و جدول مسیریابی
  wg-ctl backup             ایجاد Snapshot کامل از سیستم
  wg-ctl restore [path]     بازگردانی آخرین نسخه پشتیبان
  wg-ctl doctor             اجرای ابزار تشخیصی Net Doctor
  wg-ctl firewall           نمایش قوانین فایروال ضد نشت ترافیک
  wg-ctl version            نمایش نسخه سیستم
EOH
        ;;
esac
EOF
    write_file_atomic "$ctl_path" 0755 "$ctl_content"
}

# ==============================================================================
# ZERO-TOUCH INTERACTIVE WIZARD (هنگام اجرای تک‌خطی بدون کانفیگ اولیه)
# ==============================================================================
run_zero_touch_wizard() {
    # Skip if non-interactive flag passed or not attached to a terminal
    if [[ "$NON_INTERACTIVE" -eq 1 || "$DRY_RUN" -eq 1 || ! -t 0 ]]; then
        return 0
    fi

    shopt -s nullglob
    local -a existing_confs=("${CONFIGS_DIR}"/*.conf)
    shopt -u nullglob

    printf "\n${C_BOLD}${C_CYAN}==================== راه‌انداز خودکار WG-MULTI (Zero-Touch Setup) ====================${C_RESET}\n"

    # Step 1: Ask to paste WireGuard configs directly if none exist
    if [[ "${#existing_confs[@]}" -eq 0 ]]; then
        printf "هیچ فایل کانفیگی در سیستم یافت نشد. می‌توانید همین الان کانفیگ کشورها را وارد کنید:\n"
        while true; do
            read -r -p "کد کشور را وارد کنید (مثلاً US یا NL) و برای پایان کلید Enter بزنید: " wiz_cc </dev/tty || break
            wiz_cc="$(echo "$wiz_cc" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
            [[ -z "$wiz_cc" ]] && break

            if ! validate_country_code "$wiz_cc"; then
                continue
            fi

            printf "${C_YELLOW}متن کامل کانفیگ WireGuard کشور ${wiz_cc} را Paste کنید و در پایان یک خط خالی بزنید و Ctrl+D را فشار دهید:${C_RESET}\n"
            local cfg_body=""
            cfg_body="$(cat </dev/tty)"
            if [[ -n "$cfg_body" ]]; then
                write_file_atomic "${CONFIGS_DIR}/${wiz_cc}.conf" 0600 "$cfg_body"
                msg_ok "فایل ${CONFIGS_DIR}/${wiz_cc}.conf ذخیره شد."
            fi
        done
    fi

    # Step 2: Ask for Turbo Optimization
    if [[ "$ENABLE_TURBO_ON_INSTALL" -eq 0 ]]; then
        read -r -p "آیا بهینه‌سازی شبکه کرنل (BBR + FQ + Socket Buffers) فعال شود؟ [Y/n]: " ans_turbo </dev/tty || ans_turbo="y"
        if [[ ! "$ans_turbo" =~ ^[Nn]$ ]]; then
            ENABLE_TURBO_ON_INSTALL=1
        fi
    fi

    # Step 3: Ask for Optional Telegram Bot
    if [[ -z "$CLI_BOT_TOKEN" ]]; then
        read -r -p "آیا مایل به فعال‌سازی ربات تلگرام مدیریتی هستید؟ [y/N]: " ans_bot </dev/tty || ans_bot="n"
        if [[ "$ans_bot" =~ ^[Yy]$ ]]; then
            read -r -p "توکن ربات تلگرام (Bot Token): " CLI_BOT_TOKEN </dev/tty || true
            read -r -p "آیدی عددی مدیران مجاز (با ویرگول جدا کنید، مثال 12345678): " CLI_BOT_ADMINS </dev/tty || true
        fi
    fi
}

# ==============================================================================
# 3X-UI / XRAY-CORE READY OUTBOUNDS JSON & FINAL SUMMARY REPORT
# ==============================================================================
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
            s_user="${SOCKS_USER}"
            s_pass="${SOCKS_PASS}"
        fi

        outbounds_json="$(echo "$outbounds_json" | jq \
            --arg tag "wg-${cc,,}-out" \
            --argjson port "$port" \
            --arg user "$s_user" \
            --arg pass "$s_pass" \
            '. + [{
                tag: $tag,
                protocol: "socks",
                settings: {
                    servers: [{
                        address: "127.0.0.1",
                        port: $port,
                        users: [{
                            user: $user,
                            pass: $pass
                        }]
                    }]
                }
            }]')"
    done

    write_file_atomic "$xray_file" 0600 "$outbounds_json"

    printf "\n${C_BOLD}${C_GREEN}==================== جدول نهایی وضعیت لوکیشن‌ها (WG-MULTI) ====================${C_RESET}\n"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        /usr/local/bin/wg-ctl status || true
    fi

    printf "\n${C_BOLD}${C_CYAN}==================== خروجی JSON آماده برای بخش Outbounds پنل 3x-ui ====================${C_RESET}\n"
    printf "مسیر فایل: ${C_BOLD}%s${C_RESET}\n\n" "$xray_file"
    echo "$outbounds_json" | jq .
    printf "\n"
}

# ==============================================================================
# CORE LIFECYCLE OPERATIONS
# ==============================================================================
activate_single_country() {
    local cc="$1"
    validate_country_code "$cc"

    validate_and_process_wg_config "$cc"
    allocate_or_update_country_mapping "$cc" "true"

    register_rollback_cmd "systemctl stop wg-multi-socks@${cc}.service wg-multi-tunnel@${cc}.service"

    run_cmd systemctl enable "wg-multi-tunnel@${cc}.service" "wg-multi-socks@${cc}.service"
    run_cmd systemctl restart "wg-multi-tunnel@${cc}.service"
    run_cmd systemctl restart "wg-multi-socks@${cc}.service"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        /etc/wg-multi/scripts/healthcheck.sh "$cc" || true
    fi
}

remove_single_country() {
    local cc="$1"
    validate_country_code "$cc"
    msg_info "غیرفعال‌سازی ایمن کشور ${cc}..."
    run_cmd systemctl disable --now "wg-multi-socks@${cc}.service" 2>/dev/null || true
    run_cmd systemctl disable --now "wg-multi-tunnel@${cc}.service" 2>/dev/null || true
    run_cmd rm -f "${GENERATED_DIR}/${cc}.conf"
    set_country_enabled_state "$cc" "false"
    msg_ok "کشور ${cc} غیرفعال شد و پورت آن در Mapping محفوظ ماند."
}

run_full_install_or_update() {
    local mode="$1"
    TRANSACTION_ACTIVE=1

    check_system_compatibility
    init_runtime_dirs
    persist_self_binary
    create_system_snapshot "pre_${mode}"
    install_dependencies
    deploy_runtime_helper_scripts
    deploy_healthcheck_engine
    deploy_wg_ctl_cli

    if [[ "$mode" == "install" ]]; then
        run_zero_touch_wizard
    fi

    shopt -s nullglob
    local -a conf_files=("${CONFIGS_DIR}"/*.conf)
    shopt -u nullglob

    if [[ "${#conf_files[@]}" -eq 0 ]]; then
        msg_warn "هنوز فایل کانفیگی در ${CONFIGS_DIR} قرار نگرفته است."
        msg_info "بعد از قرار دادن فایل‌هایی مثل US.conf در ${CONFIGS_DIR}، فقط دستور 'wg-ctl add US' را بزنید."
    else
        for cfile in "${conf_files[@]}"; do
            local cc
            cc="$(basename "$cfile" .conf)"
            msg_info "راه‌اندازی خودکار کشور: ${cc} ..."
            activate_single_country "$cc"
        done
    fi

    if [[ "$ENABLE_TURBO_ON_INSTALL" -eq 1 ]]; then
        apply_turbo_optimization
    fi

    if [[ -n "$CLI_BOT_TOKEN" && -n "$CLI_BOT_ADMINS" ]]; then
        deploy_telegram_bot_module "$CLI_BOT_TOKEN" "$CLI_BOT_ADMINS"
    fi

    if [[ "$mode" == "update" && "$DRY_RUN" -eq 0 && -f "$MAPPING_JSON" ]]; then
        mapfile -t enabled_ccs < <(jq -r '.countries | to_entries[] | select(.value.enabled == true) | .key' "$MAPPING_JSON" 2>/dev/null || true)
        for cc in "${enabled_ccs[@]}"; do
            if ! systemctl is-active --quiet "wg-multi-tunnel@${cc}.service" || ! systemctl is-active --quiet "wg-multi-socks@${cc}.service"; then
                msg_err "سرویس کشور ${cc} پس از Update فعال نشد! آغاز Rollback خودکار..."
                return 1
            fi
        done
    fi

    TRANSACTION_ACTIVE=0
    ROLLBACK_STACK=()
    generate_3xui_xray_outbounds
    msg_ok "نصب و پیکربندی WG-MULTI با موفقیت کامل انجام شد! دستور مدیریت: wg-ctl help"
}

run_safe_uninstall() {
    msg_warn "حذف ایمن سرویس‌ها و قوانین شبکه WG-MULTI..."
    if [[ "$ASSUME_YES" -eq 0 && "$DRY_RUN" -eq 0 && -t 0 ]]; then
        read -r -p "آیا از حذف سرویس‌های WG-MULTI اطمینان دارید؟ [y/N]: " ans </dev/tty
        [[ ! "$ans" =~ ^[Yy]$ ]] && exit 0
    fi

    create_system_snapshot "pre_uninstall"

    if [[ -f "$MAPPING_JSON" ]]; then
        mapfile -t all_ccs < <(jq -r '.countries | keys[]' "$MAPPING_JSON" 2>/dev/null || true)
        for cc in "${all_ccs[@]}"; do
            run_cmd systemctl disable --now "wg-multi-socks@${cc}.service" 2>/dev/null || true
            run_cmd systemctl disable --now "wg-multi-tunnel@${cc}.service" 2>/dev/null || true
        done
    fi

    run_cmd systemctl disable --now wg-multi-healthcheck.timer 2>/dev/null || true
    run_cmd systemctl disable --now wg-multi-bot.service 2>/dev/null || true

    if [[ "$DRY_RUN" -eq 0 ]]; then
        while iptables -D OUTPUT -j WG_MULTI_EGRESS 2>/dev/null; do :; done
        iptables -F WG_MULTI_EGRESS 2>/dev/null || true
        iptables -X WG_MULTI_EGRESS 2>/dev/null || true
    fi

    revert_turbo_optimization || true

    run_cmd rm -f /etc/systemd/system/wg-multi-tunnel@.service \
                  /etc/systemd/system/wg-multi-socks@.service \
                  /etc/systemd/system/wg-multi-healthcheck.service \
                  /etc/systemd/system/wg-multi-healthcheck.timer \
                  /etc/systemd/system/wg-multi-bot.service \
                  "$RT_TABLES_CONF" \
                  /usr/local/bin/wg-ctl \
                  "$SELF_INSTALLED_PATH"
    run_cmd systemctl daemon-reload
    msg_ok "سرویس‌ها حذف شدند. بکاپ‌ها و کانفیگ‌ها در ${BASE_DIR} حفظ شدند."
}

# ==============================================================================
# CLI ARGUMENT PARSER & ENTRYPOINT
# ==============================================================================
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1; shift ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            --non-interactive) NON_INTERACTIVE=1; shift ;;
            --turbo)
                if [[ "$ACTION" == "install" && $# -gt 1 ]]; then
                    ENABLE_TURBO_ON_INSTALL=1
                else
                    ACTION="turbo"
                fi
                shift
                ;;
            --turbo-revert) ACTION="turbo-revert"; shift ;;
            --install) ACTION="install"; shift ;;
            --update) ACTION="update"; shift ;;
            --add) ACTION="add"; TARGET_ARG="${2:-}"; shift 2 ;;
            --remove) ACTION="remove"; TARGET_ARG="${2:-}"; shift 2 ;;
            --backup) ACTION="backup"; shift ;;
            --restore) ACTION="restore"; TARGET_ARG="${2:-}"; shift 2 || shift 1 ;;
            --net-doctor) ACTION="net-doctor"; shift ;;
            --setup-bot)
                if [[ "$ACTION" == "install" ]]; then
                    CLI_BOT_TOKEN="${2:-}"
                    CLI_BOT_ADMINS="${3:-}"
                else
                    ACTION="setup-bot"
                    CLI_BOT_TOKEN="${2:-}"
                    CLI_BOT_ADMINS="${3:-}"
                fi
                shift 3
                ;;
            --uninstall) ACTION="uninstall"; shift ;;
            --version|-v) echo "WG-MULTI version ${VERSION}"; exit 0 ;;
            --help|-h)
                echo "Usage: wg-multi-manager.sh [--install|--update|--add CC|--remove CC|--turbo|--turbo-revert|--net-doctor|--backup|--restore|--uninstall|--dry-run|--non-interactive]"
                exit 0
                ;;
            *) msg_err "آرگومان ناشناخته: $1"; exit 1 ;;
        esac
    done

    acquire_lock "$LOCK_FILE"
    init_runtime_dirs

    case "$ACTION" in
        install) run_full_install_or_update "install" ;;
        update) run_full_install_or_update "update" ;;
        add)
            validate_country_code "$TARGET_ARG"
            TRANSACTION_ACTIVE=1
            create_system_snapshot "pre_add_${TARGET_ARG}"
            activate_single_country "$TARGET_ARG"
            TRANSACTION_ACTIVE=0
            generate_3xui_xray_outbounds
            ;;
        remove)
            validate_country_code "$TARGET_ARG"
            create_system_snapshot "pre_remove_${TARGET_ARG}"
            remove_single_country "$TARGET_ARG"
            generate_3xui_xray_outbounds
            ;;
        backup) create_system_snapshot "manual" ;;
        restore) restore_snapshot_internal "$TARGET_ARG" ;;
        turbo)
            create_system_snapshot "pre_turbo"
            apply_turbo_optimization
            ;;
        turbo-revert) revert_turbo_optimization ;;
        net-doctor) run_net_doctor ;;
        setup-bot) deploy_telegram_bot_module "$CLI_BOT_TOKEN" "$CLI_BOT_ADMINS" ;;
        uninstall) run_safe_uninstall ;;
    esac
}

main "$@"
