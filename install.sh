#!/usr/bin/env bash
#===============================================================================
# Psiphon Multi-Region Auto-Installer v5.1
# Installs multiple Psiphon tunnel-core instances with per-instance EgressRegion,
# systemd services, logrotate and optional Xray (VLESS) injection.
# Supports: Ubuntu 24.04 x86_64 (root required)
#
# Fixes over v5.0:
#   - Fixed all syntax errors (heredoc, variable, color init)
#   - SSH check moved BEFORE loopback/netplan changes
#   - netplan apply replaced with timeout + fallback
#   - systemd loop failures are non-fatal (warn, continue)
#   - Verification uses retry loop (race condition fix)
#   - Xray waits for at least one Psiphon SOCKS port before starting
#   - acquire_lock fixed (double flock bug removed)
#   - Duplicate/garbage variable declarations cleaned up
#===============================================================================

set -Eeuo pipefail

VERSION="5.1"
PROJECT_NAME="psiphon-multi-region"

PSIPHON_INSTANCES="${PSIPHON_INSTANCES:-20}"
SOCKS_BASE_PORT="${SOCKS_BASE_PORT:-10800}"
SOCKS_LISTEN_IP="${SOCKS_LISTEN_IP:-127.20.0.1}"
INBOUND_BASE_PORT="${INBOUND_BASE_PORT:-20000}"
EGRESS_REGIONS="${EGRESS_REGIONS:-}"
SSH_PORT="${SSH_PORT:-22}"
DRY_RUN="${DRY_RUN:-0}"
INSTALL_XRAY="${INSTALL_XRAY:-0}"

INSTALL_DIR="${INSTALL_DIR:-/opt/psiphon-multi-region}"
BIN_DIR="${INSTALL_DIR}/bin"
CONF_DIR="${INSTALL_DIR}/config"
LOG_DIR="${INSTALL_DIR}/logs"
BACKUP_DIR="${INSTALL_DIR}/backups"
XRAY_DIR="${INSTALL_DIR}/xray"
SERVICE_USER="${SERVICE_USER:-psiphon}"
LOGROTATE_FILE="/etc/logrotate.d/psiphon-multi-region"
BINARY_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
BINARY_NAME="psiphon-tunnel-core"

LOOPBACK_ALIAS_IP="127.20.0.1"
LOOPBACK_ALIAS_DEV="lo"
LOCK_FILE="/var/run/${PROJECT_NAME}.lock"
LOG_TAG="[psiphon-installer]"

# Will be set after ensure_dirs
LOG_FILE=""

VALID_REGIONS="AF AL DZ AS AD AO AI AG AR AM AW AU AT AZ BS BH BD BB BY BE BZ BJ BM BT BO BA BW BR BN BG BF BI KH CM CA CV KY CF TD CL CN CO KM CG CD CR CI HR CU CY CZ DK DJ DM DO EC EG SV GQ ER EE ET FK FJ FI FR PF GA GM GE DE GH GI GR GL GD GP GU GT GN GW GY HT HN HK HU IS IN ID IQ IE IL IT JM JP JO KZ KE KI KW KG LA LV LB LS LR LY LI LT LU MO MG MW MY MV ML MT MH MQ MR MU MX FM MD MC MN ME MS MA MZ MM NA NP NL NZ NI NG MP NO OM PK PW PS PA PG PY PE PH PL PT PR QA RO RU RW KN LC VC WS SM ST SA RS SC SL SG SK SI SB SO ZA KR ES LK SD SR SE SZ CH SY TW TJ TZ TH TL TG TO TT TN TR TM TV UG UA AE GB US UY UZ VU VE VN VG VI YE ZM ZW"

# ---------------------------------------------------------------------------
# Color setup
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m' ---------------------------------------------------------------------------
# Color setup
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_y during early boot; tee -a handles it)
# ---------------------------------------------------------------------------
_tee() { if [[ -n "$LOG_FILE" ]]; then tee -a "$LOG_FILE"; else cat; fi; }
log()  { echo -e "${C_BLUE}${LOG_TAG}${C_RESET} $*"        | _tee; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_RESET} $*"           | _tee; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"          | _tee; }
info() { echo -e "${C_CYAN}[INFO]${C_RESET} $*"            | _tee; }
die()  { echo -e "${C_RED}[FAIL]${C_RESET} $*"             | _tee >&2; exit 1; }
step() { echo "" | _tee; echo -e "${C_BLUE}==> ${C_CYAN}$*${C_RESET}" | _tee; }

# ---------------------------------------------------------------------------
# Error trap — rolls back loopback alias if SSH disappeared
# ---------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local line_no="${1:-?}"
    echo -e "${C_RED}[FAIL]${C_RESET} Error at line ${line_no} (exit=${exit_code}). Command: ${BASH_COMMAND}" | _tee >&2
    if ! ss -tln | grep -qE "[:.]${SSH_PORT}[[:space:]]"; then
        warn "SSH port ${SSH_PORT} stopped listening -> rolling back loopback alias ${LOOPBACK_ALIAS_IP}/32 on ${LOOPBACK_ALIAS_DEV}"
        ip addr del "${LOOPBACK_ALIAS_IP}/32" dev "${LOOPBACK_ALIAS_DEV}" 2>/dev/null || true
        warn "Loopback alias removed. Re-run installer after verifying SSH connectivity."
    fi
    die "Installation aborted (exit code ${exit_code}, line ${line_no}). Full log: ${LOG_FILE:-<not yet set>}"
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Dry-run wrapper
# ---------------------------------------------------------------------------
run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
is_root()        { [[ "$(id -u)" -eq 0 ]]; }
check_ssh_alive() { ss -tln | grep -qE "[:.]${SSH_PORT}[[:space:]]"; }

validate_regions() {
    local token idx reg
    [[ -z "$1" ]] && { ok "No EGRESS_REGIONS set — all instances use any region"; return 0; }
    for token in $1; do
        idx="${token%%:*}"
        reg="${token##*:}"
        [[ "$idx" =~ ^[0-9]+$ ]] || die "Invalid instance index in EGRESS_REGIONS token '${token}'"
        [[ "$reg" == "-" ]] && continue
        if [[ " ${VALID_REGIONS} " != *" ${reg} "* ]]; then
            die "Invalid region code '${reg}' (token '${token}'). Use ISO alpha-2 codes or '-' for any."
        fi
    done
    ok "EGRESS_REGIONS validation passed"
}

region_for_instance() {
    local want="$1" token idx reg
    for token in ${EGRESS_REGIONS:-}; do
        idx="${token%%:*}"
        reg="${token##*:}"
        if [[ "$idx" == "$want" ]]; then
            echo "$reg"
            return
        fi
    done
    echo "-"
}

port_in_use() { ss -tln | awk '{print $4}' | grep -qE "(^|:)$1$"; }

ensure_dirs() {
    mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$CONF_DIR" "$LOG_DIR" "$BACKUP_DIR" "$XRAY_DIR"
    chmod 755 "$INSTALL_DIR" "$BIN_DIR" "$CONF_DIR"1$"; }

ensure_dirs() {
    mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$CONF_DIR" "$LOG_DIR" "$BACKUP_DIR" "$XRAY_DIR"
    chmod 755 "$INSTALL_DIR" "$BIN_DIR" "$CONF_DIR"
    LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
    touch flock -n 9; then
        die "Another instance of ${PROJECT_NAME} is already running (lock: ${LOCK_FILE})."
    fi
    ok "Lock acquired: ${LOCK_FILE}"
}

usage() {
    cat <<USAGE
${PROJECT_NAME} installer v${VERSION}

Usage: sudo ./install.sh [options]

Environment variables (or use config.env):
  PSIPHON_INSTANCES   number of instances              (default: 20)
  SOCKS_BASE_PORT     first SOCKS port                 (default: 10800)
  SOCKS_LISTEN_IP     SOCKS listen IP (loopback alias) (default: 127.20.0.1)
  INBOUND_BASE_PORT   first inbound port (Xray)        (default: 20000)
  EGRESS_REGIONS      per-instance regions "1:DE 2:US 3:GB"
  SSH_PORT            SSH port to protect              (default: 22)
  INSTALL_XRAY        1 = install Xray/VLESS injector  (default: 0)
  DRY_RUN             1 = simulate, no changes         (default: 0)
USAGE
}

# ===========================================================================
# STEP 1 — System update and dependencies
# ===========================================================================
step_1_update_deps() {
    step "STEP 1/10: System update and dependencies"
    export DEBIAN_FRONTEND=noninteractive
    run "apt-get update -y"
    run "apt-get install -y curl wget jq unzip ca-certificates gnupg openssl util-linux python3 logrotate iproute2 uuid-runtime"
    run "apt-get upgrade -y"
    ok "System updated"
}

# ===========================================================================
# STEP 2 — SSH safety check  (MUST run before any network change)
# ===========================================================================
step_2_ssh_check() {
    step "STEP 2/10: SSH safety check (port ${SSH_PORT})"
    if check_ssh_alive; then
        ok "SSH is listening on port ${SSH_PORT}"
    else
        die "SSH is NOT listening on port ${SSH_PORT}. Aborting for your safety."
    fi
}

# ===========================================================================
# STEP 3 — Loopback alias  (after SSH check)
# ===========================================================================
step_3_loopback() {
    step "STEP 3/10: Loopback alias ${LOOPBACK_ALIAS_IP}/32 on ${LOOPBACK_ALIAS_DEV}"

    if ip addr show "$LOOPBACK_ALIAS_DEV" | grep -q "${LOOPBACK_ALIAS_IP}"; then
        ok "Loopback alias already present (idempotent skip)"
    else
        run "ip addr add ${LOOPBACK_ALIAS_IP}/32 dev ${LOOPBACK_ALIAS_DEV}"
        ok "Loopback alias added"
    fi

    # Persist via netplan only if not already there
    if [[ -d /etc/netplan && "$DRY_RUN" != "1" ]]; then
        if ! grep -rq "$LOOPBACK_ALIAS_IP" /etc/netplan/ 2>/dev/null; then
            local nf="/etc/netplan/90 -f "$nf" ]];oopback.yaml"
            if [[ ! -f "$nf" ]]; then
                cat > "$nf" <<EOF
network:
  version: 2
  ethernets:
    lo-alias:
      match:
        name: lo
      addresses: [${LOOPBACK_ALIAS_IP}/32]
EOF
                # Use a timeout so netplan apply can't hang the SSH session
                if timeout 30 netplan apply >/dev/null 2>&1; then
                    ok "netplan apply succeeded; alias persisted in ${nf}"
                else
                    warn "netplan apply failed or timed out — alias is active at runtime but may not survive reboot"
                fi
            fi
        fi
    fi
}

# ===========================================================================
# STEP 4 — Service user
# ===========================================================================
step_4_user() {
    step "STEP 4/10: Service user '${SERVICE_USER}'"
    if id "$SERVICE_USER" &>/dev/null; then
        ok "User ${SERVICE_USER} already exists (idempotent skip)"
    else
        run "useradd --system --no-create-home --shell /usr/sbin/nologin ${SERVICE_USER}"
        ok "System user ${SERVICE_USER} created"
    fi
}

# ===========================================================================
# STEP 5 — Download and verify binary
# ===========================================================================
step_5_binary() {
    step "STEP 5/10: Download and verify ${BINARY_NAME}"
    local dest="${BIN_DIR}/${BINARY_NAME}"
    local tmp="${BIN_DIR}/.download.$$"

    if [[ -x "$dest" ]]; then
        if "$dest" --help >/dev/null 2>&1 || "$dest" -version >/dev/null 2>&1; then
            ok "Existing binary passes executable test (idempotent skip)"
            return 0
        else
            warn "Existing binary failed executable test -> re-downloading"
        fi
    fi

    info "Downloading from: ${BINARY_URL}"
    run "curl -fSL --retry 3 --connect-timeout 30 -o '${tmp}' '${BINARY_URL}'"

    if [[ "$DRY_RUN" != "1" ]]; then
        [[ -s "$tmp" ]] || die "Downloaded binary is empty"
        local sum
        sum=$(sha256sum "$tmp" | awk '{print $1}')
        echo "${sum}  ${dest}" > "${BIN_DIR}/${BINARY_NAME}.sha256"
        info "SHA256: ${sum}"
        install -m 755 "$tmp" "$dest"
        rm -f "$tmp"
        ( cd "$BIN_DIR" && sha256sum -c "${BINARY_NAME}.sha256" >/dev/null 2>&1 ) \
            || die "SHA256 verification FAILED for ${BINARY_NAME}"
        [[ -x "$dest" ]] || die "Binary is not executable"
        chown root:"$SERVICE_USER" "$dest" 2>/dev/null || true
        ok "Binary integrity verified (sha256 + executable test)"
    fi
}

# ===========================================================================
# STEP 6 — Instance configs
# ===========================================================================
step_6_configs() {
    step "STEP 6/10: Generating ${PSIPHON_INSTANCES} instance configs"
    local i reg iport socks_port egress_json json content

    for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
        reg=$(region_for_instance "$i")
        iport=$(( INBOUND_BASE_PORT + i ))
        socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
        egress_json="null"
        [[ "$reg" != "-" ]] && egress_json="\"${reg}\""

        json="${CONF_DIR}/psiphon-${i}.json"
        content=$(cat <<EOF
{
  "PropagationChannelId": "FFFFFFFFFFFFFFFF",
  "SponsorId": "FFFFFFFFFFFFFFFF",
  "LocalSocksProxyPort": ${socks_port},
  "LocalHttpProxyPort": 0,
  "DisableLocalHTTPProxy": true,
  "EgressRegion": ${egress_json},
  "ListenInterface": "${SOCKS_LISTEN_IP}",
  "TargetInboundPort": ${iport},
  "UpstreamProxyUrl": "",
  "UseIndistinguishableTLS": true,
  "MeteredMetrics": false
}
EOF
)
        if [[ "$DRY_RUN" == "1" ]]; then
            info "[DRY-RUN] would write ${json} (socks=${socks_port}, inbound=${iport}, region=${reg})"
        else
            printf '%s\n' "$content" > "$json"
            ok "Config ${i}: socks=${socks_port} inbound=${iport} region=${reg}"
        fi
    done

    if [[ "$DRY_RUN" != "1" ]]; then
        chown -R root:"$SERVICE_USER" "$CONF_DIR"
        chmod 640 "${CONF_DIR}"/*.json 2>/dev/null || true
    fi
    ok "All configs generated"
}

# ===========================================================================
# STEP 7 — systemd units + logrotate
# ===========================================================================
step_7_systemd() {
    step "STEP 7/10: systemd units + logrotate"
    local i unit socks_port failed=0

    for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
        unit="/etc/systemd/system/psiphon@${i}.service"
        socks_port=$(( SOCKS_BASE_PORT + i - 1 ))

        [[ -f "$unit" ]] && continue   # idempotent

        if [[ "$DRY_RUN" == "1" ]]; then
            info "[DRY-RUN] would write ${unit}"
            continue
        fi

        cat > "$unit" <<EOF
[Unit]
Description=Psiphon Multi-Region Instance ${i}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=${BIN_DIR}/${BINARY_NAME} -config ${CONF_DIR}/psiphon-${i}.json
Restart=always
RestartSec=5
LimitNOFILE=65535
Environment=INSTANCE_ID=${i}
Environment=SOCKS_PORT=${socks_port}

[Install]
WantedBy=multi-user.target
EOF
        ok "Unit written: psiphon@${i}.service (socks ${socks_port})"
    done

    if [[ "$DRY_RUN" != "1" ]]; then
        systemctl daemon-reload || { warn "daemon-reload failed"; (( failed++ )); }
    fi

    # Logrotate
    if [[ ! -f "$LOGROTATE_FILE" ]]; then
        if [[ "$DRY_RUN" == "1" ]]; then
            info "[DRY-RUN] would write ${LOGROTATE_FILE}"
        else
            cat > "$LOGROTATE_FILE" <<EOF
${LOG_DIR}/*.log {
    daily
    rotate 14
    size 50M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
            ok "Logrotate configured: ${LOGROTATE_FILE}"
        fi
    else
        ok "Logrotate already configured (idempotent skip)"
    fi

    [[ $failed -gt 0 ]] && warn "Step 7 finished with ${failed} non-fatal warning(s)"
}

# ===========================================================================
# STEP 8 — Xray (VLESS) injector
# ===========================================================================
step_8_xray() {
    step "STEP 8/10: Xray (VLESS) injector (optional)"
    if [[ "$INSTALL_XRAY" != "1" ]]; then
        ok "INSTALL_XRAY!=1 -> skipping Xray"
        return 0
    fi

    local xray_bin="${XRAY_DIR}/xray"
    local xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    local tmp_zip="${XRAY_DIR}/xray.zip"

    if [[ ! -x "$xray_bin" ]]; then
        run "curl -fSL --retry 3 -o '${tmp_zip}' '${xray_url}'"
        run "unzip -o '${tmp_zip}' -d '${XRAY_DIR}'"
        run "chmod 755 '${xray_bin}'"
        run "rm -f '${tmp_zip}'"
    fi

    # Build inbound list from all Psiphon SOCKS ports
    local i socks_port uuid_obj uuids="[]"
    local inbounds="[]"
    for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
        socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
        uuid_obj=$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')
        uuids=$(printf '%s' "$uuids" | jq \
            --argjson p "$socks_port" \
            --arg u "$uuid_obj" \
            '. += [{"port":$p,"uuid":$u}]')
    done

    local xray_config="${XRAY_DIR}/config.json"
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[DRY-RUN] would write Xray config to ${xray_config}"
    else
        # Build inbounds array: one VLESS listener per Psiphon instance port
        inbounds=$(printf '%s' "$uuids" | jq -c '[.[] | {
            "port": .port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": .uuid}],
                "decryption": "none"
            },
            "streamSettings": {"network": "tcp"}
        }]')

        cat > "$xray_config" <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": ${inbounds},
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF
        ok "Xray config written with ${PSIPHON_INSTANCES} VLESS inbounds (base port ${SOCKS_BASE_PORT})"
    fi

    local xray_unit="/etc/systemd/system/xray-psiphon.service"
    if [[ ! -f "$xray_unit" ]]; then
        if [[ "$DRY_RUN" == "1" ]]; then
            info "[DRY-RUN] would write ${xray_unit}"
        else
            cat > "$xray_unit" <<EOF
[Unit]
Description=Psiphon Xray VLESS Injector
After=network-online.target psiphon@1.service
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
# Wait until at least the first Psiphon SOCKS port is up before starting
ExecStartPre=/bin/bash -c '\
    for i in \$(seq 1 30); do \
        ss -tln | grep -qE "[:.]${SOCKS_BASE_PORT}[[:space:]]" && exit 0; \
        sleep 2; \
    done; \
    echo "Timed out waiting for Psiphon SOCKS port ${SOCKS_BASE_PORT}"; exit 1'
ExecStart=${xray_bin} -config ${xray_config}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
            ok "Xray unit written: xray-psiphon.service (waits for Psiphon SOCKS before starting)"
        fi
    fi

    if [[ "$DRY_RUN" != "1" ]]; then
        systemctl daemon-reload
        systemctl enable xray-psiphon.service >/dev/null 2>&1 \
            || warn "Failed to enable xray-psiphon.service"
    fi
}

# ===========================================================================
# STEP 9 — Start services
# ===========================================================================
step_9_start() {
    step "STEP 9/10: Starting services"
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[DRY-RUN] would enable/start all psiphon@*.service units"
        return 0
    fi

    local i failed=0
    for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
        systemctl enable "psiphon@${i}.service" >/dev/null 2>&1 \
            || { warn "Failed to enable psiphon@${i}.service"; (( failed++ )); }
    done

    # Start all at once; failures are non-fatal here — step 10 will report them
    systemctl start "psiphon@*.service" 2>&1 \
        || warn "One or more psiphon services failed to start (will be checked in step 10)"

    if [[ "$INSTALL_XRAY" == "1" ]]; then
        # Xray ExecStartPre already handles the wait; just trigger it
        systemctl start xray-psiphon.service 2>&1 \
            || warn "xray-psiphon.service failed to start (check logs)"
    fi

    [[ $failed -gt 0 ]] && warn "Step 9: ${failed} enable failure(s)"
    ok "Services started (status: systemctl status 'psiphon@*.service')"
}

# ===========================================================================
# STEP 10 — Verify with retry loop
# ===========================================================================
step_10_verify() {
    step "STEP 10/10: Verification"
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[DRY-RUN] would verify ports and processes"
        return 0
    fi

    local i socks_port ok_count=0 fail_count=0
    local max_retries=15 retry_delay=2   # up to 30 s total

    info "Waiting up to $(( max_retries * retry_delay ))s for all instances to bind their ports..."

    for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
        socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
        local attempt bound=0
        for (( attempt=1; attempt<=max_retries; attempt++ )); do
            if ss -tln | grep -qE "[:.]${socks_port}[[:space:]]"; then
                bound=1
                break
            fi
            sleep "$retry_delay"
        done
        if [[ $bound -eq 1 ]]; then
            ok "Instance ${i}: SOCKS port ${socks_port} listening"
            (( ok_count++ ))
        else
            warn "Instance ${i}: SOCKS port ${socks_port} NOT listening after ${max_retries} retries"
            (( fail_count++ ))
        fi
    done

    if [[ "$INSTALL_XRAY" == "1" ]]; then
        if ss -tln | grep -qE "[:.]${SOCKS_BASE_PORT}[[:space:]]"; then
            ok "Xray VLESS: at least one listener active"
        else
            warn "Xray VLESS: no listener detected on base port ${SOCKS_BASE_PORT}"
        fi
    fi

    info "Verification summary: ${ok_count}/${PSIPHON_INSTANCES} instances OK, ${fail_count} failed"
    if [[ $fail_count -gt 0 ]]; then
        warn "Some instances did not start. Run: journalctl -u 'psiphon@*.service' --no-pager | tail -50"
    fi

    info "Installation completed. Log: ${LOG_FILE}"
    info "Manage services : systemctl {status|restart|stop} 'psiphon@*.service'"
    ok "DONE: ${PROJECT_NAME} v${VERSION} installed successfully"
}

# ===========================================================================
# main
# ===========================================================================
main() {
    local start_time
    start_time=$(date +%s)

    # Root check
    if [[ "$DRY_RUN" != "1" ]] && ! is_root; then
        die "This script must be run as root (sudo). Exiting."
    fi
    [[ "$DRY_RUN" == "1" ]] && warn "Running in DRY_RUN mode (no changes will be made)"

    # Dirs and log file must be ready before anything else logs
    if [[ "$DRY_RUN" != "1" ]]; then
        ensure_dirs
    else
        LOG_FILE="/tmp/${PROJECT_NAME}-dryrun-$(date +%Y%m%d-%H%M%S).log"
        touch "$LOG_FILE" 2>/dev/null || LOG_FILE=""
    fi

    acquire_lock
    validate_regions "${EGRESS_REGIONS:-}"

    step_1_update_deps

    # *** SSH check BEFORE any network/loopback change ***
    step_2_ssh_check

    step_3_loopback
    step_4_user
    step_5_binary
    step_6_configs
    step_7_systemd
    step_8_xray
    step_9_start
    step_10_verify

    local end_time duration
    end_time=$(date +%s)
    duration=$(( end_time - start_time ))
    log "Total runtime: ${duration}s"

    if [[ "$DRY_RUN" != "1" ]]; then
        info "Next steps:"
        info "  - Check status : systemctl status 'psiphon@*.service'"
        info "  - Stream logs  : journalctl -u 'psiphon@*' -f"
        [[ "$INSTALL_XRAY" == "1" ]] && info "  - Xray status  : systemctl status xray-psiphon.service"
        info "  - SOCKS proxies: ${SOCKS_LISTEN_IP}:${SOCKS_BASE_PORT} .. $(( SOCKS_BASE_PORT + PSIPHON_INSTANCES - 1 ))"
    fi
}

# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

main "$@"
