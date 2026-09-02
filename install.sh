Output: #!/usr/bin/env bash
#===============================================================================
# psiphon-multi-region / Psiphon Multi-Region Auto-Installer v5.0
# Installs multiple Psiphon tunnel-core instances with per-instance
# EgressRegion, systemd services, logrotate and optional Xray (VLESS) injection.
# Supports: Ubuntu 24.04 x86_64 (root required)
#===============================================================================

set -Eeuo pipefail

VERSION="5.0"
PROJECT_NAME="psiphon-multi-region"

#------------------------------------------------------------------------------
# Defaults (overridable via environment / config.env)
#------------------------------------------------------------------------------
PSIPHON_INSTANCES="${PSIPHON_INSTANCES:-20}"
SOCKS_BASE_PORT="${SOCKS_BASE_PORT:-10800}"
SOCKS_LISTEN_IP="${SOCKS_LISTEN_IP:-127.20.0.1}"
INBOUND_BASE_PORT="${INBOUND_BASE_PORT:-20000}"
EGRESS_REGIONS="${EGRESS_REGIONS:-}"
SSH_PORT="${SSH_PORT:-22}"
DRY_RUN="${DRY_RUN:-0}"

INSTALL_DIR="${INSTALL_DIR:-/opt/psiphon-multi-region}"
BIN_DIR="${INSTALL_DIR}/bin"
CONF_DIR="${INSTALL_DIR}/config"
LOG_DIR="${INSTALL_DIR}/logs"
BACKUP_DIR="${INSTALL_DIR}/backups"
SERVICE_USER="${SERVICE_USER:-psiphon}"
LOGROTATE_FILE="/etc/logrotate.d/psiphon-multi-region"
BINARY_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
BINARY_NAME="psiphon-tunnel-core"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

# Region whitelist (ISO 3166-1 alpha-2, EMPTY means "best/any")
VALID_REGIONS="AF AL DZ AS AD AO AI AG AR AM AW AU AT AZ BS BH BD BB BY BE BZ BJ BM BT BO BA BW BR BN BG BF BI KH CM CA CV KY CF TD CL CN CO KM CG CD CR CI HR CU CY CZ DK DJ DM DO EC EG SV GQ ER EE ET FK FJ FI FR PF GA GM GE DE GH GI GR GL GD GP GU GT GN GW GY HT HN HK HU IS IN ID IQ IE IL IT JM JP JO KZ KE KI KW KG LA LV LB LS LR LY LI LT LU MO MG MW MY MV ML MT MH MQ MR MU MX FM MD MC MN ME MS MA MZ MM NA NP NL NZ NI NG MP NO OM PK PW PS PA PG PY PE PH PL PT PR QA RO RU RW KN LC VC WS SM ST SA RS SC SL SG SK SI SB SO ZA KR ES LK SD SR SE SZ CH SY TW TJ TZ TH TL TG TO TT TN TR TM TV UG UA AE GB US UY UZ VU VE VN VG VI YE ZM ZW"

LOOPBACK_ALIAS_IP="127.20.0.1"
LOOPBACK_ALIAS_DEV="lo"

LOCK_FILE="/var/run/${PROJECT_NAME}.lock"
LOG_TAG="[psiphon-multi-region]"

#------------------------------------------------------------------------------
# Colorful logging helpers
#------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_RESET=''
fi

log()  { echo -e "${C_BLUE}${LOG_TAG}${C_RESET} $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_RESET} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${C_CYAN}[INFO]${C_RESET} $*" | tee -a "$LOG_FILE"; }
die()  { echo -e "${C_RED}[FAIL]${C_RESET} $*" | tee -a "$LOG_FILE" >&2; exit 1; }

step() { echo -e "" | tee -a "$LOG_FILE"; echo -e "${C_BLUE}==> ${C_CYAN}$*${C_RESET}" | tee -a "$LOG_FILE"; }

#------------------------------------------------------------------------------
# Error trap: full logging + SSH protection (rollback loopback alias)
#------------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local line_no=$1
    echo -e "${C_RED}[FAIL]${C_RESET} Error at line ${line_no} (exit=${exit_code}). Command: ${BASH_COMMAND}" | tee -a "$LOG_FILE" >&2
    # SSH protection: if SSH is no longer listening, restore loopback alias so
    # the operator can reconnect, then abort before further damage.
    if ! ss -tln | grep -qE "[:.]${SSH_PORT}[[:space:]]"; then
        warn "SSH port ${SSH_PORT} stopped listening -> rolling back loopback alias ${LOOPBACK_ALIAS_IP}/32 on ${LOOPBACK_ALIAS_DEV}"
        ip addr del "${LOOPBACK_ALIAS_IP}/32" dev "${LOOPBACK_ALIAS_DEV}" 2>/dev/null || true
        warn "Loopback alias removed. Re-run the installer after verifying SSH connectivity."
    fi
    die "Installation aborted (exit code ${exit_code}, line ${line_no}). Full log: ${LOG_FILE}"
}
trap 'on_error $LINENO' ERR

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------
run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

is_root() { [[ "$(id -u)" -eq 0 ]]; }

check_ssh_alive() {
    ss -tln | grep -qE "[:.]${SSH_PORT}[[:space:]]"
}

validate_regions() {
    # $1 = egress regions string "1:DE 2:US 3:GB"
    local idx reg
    for token in $1; do
        idx="${token%%:*}"
        reg="${token##*:}"
        [[ "$idx" =~ ^[0-9]+$ ]] || die "Invalid instance index in EGRESS_REGIONS token '${token}'"
        [[ "$reg" == "-" ]] && continue # '-' = any region
        if ! [[ " ${VALID_REGIONS} " == *" ${reg} "* ]]; then
            die "Invalid region code '${reg}' (token '${token}'). Use ISO alpha-2 codes or '-' for any."
        fi
    done
    ok "EGRESS_REGIONS validation passed"
}

region_for_instance() {
    # echo region for instance $1 or "-" if not set
    local want="$1" token idx reg
    for token in ${EGRESS_REGIONS}; do
        idx="${token%%:*}"
        reg="${token##*:}"
        [[ "$idx" == "$want" ]] && { echo "$reg"; return; }
    done
    echo "-"
}

port_in_use() {
    ss -tln | awk '{print $4}' | grep -qE "(^|:)$1$"
}

ensure_dirs() {
    mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$CONF_DIR" "$LOG_DIR" "$BACKUP_DIR"
    chmod 755 "$INSTALL_DIR" "$BIN_DIR" "$CONF_DIR"
}

#------------------------------------------------------------------------------
# flock: prevent concurrent runs
#------------------------------------------------------------------------------
acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        die "Another instance of ${PROJECT_NAME} is already running (lock: ${LOCK_FILE})."
    fi
    ok "Acquired run lock"
}

usage() {
    cat <<USAGE
${PROJECT_NAME} installer v${VERSION}

Usage: sudo ./install.sh [options]

Environment variables (or use config.env):
  PSIPHON_INSTANCES   number of instances            (default: 20)
  SOCKS_BASE_PORT     first SOCKS port               (default: 10800)
  SOCKS_LISTEN_IP     SOCKS listen IP (loopback alias) (default: 127.20.0.1)
  INBOUND_BASE_PORT   first inbound port (Xray)      (default: 20000)
  EGRESS_REGIONS      per-instance regions "1:DE 2:US 3:GB"
  SSH_PORT            SSH port to protect            (default: 22)
  DRY_RUN             1 = simulate, no changes       (default: 0)
USAGE
}

#------------------------------------------------------------------------------
# STEP 1: update / dependencies (safe apt upgrade, NOT dist-upgrade)
#------------------------------------------------------------------------------
step_1_update_deps() {
    step "STEP 1/9: System update and dependencies"
    export DEBIAN_FRONTEND=noninteractive
    run "apt-get update -y"
    run "apt-get install -y curl wget jq unzip ca-certificates gnupg openssl util-linux python3 logrotate iproute2"
    # Safe upgrade only: never dist-upgrade (protects kernel / boot config)
    run "apt-get upgrade -y"
    ok "System updated (safe upgrade, no dist-upgrade)"
}

#------------------------------------------------------------------------------
# STEP 2: loopback alias
#------------------------------------------------------------------------------
step_2_loopback() {
    step "STEP 2/9: Loopback alias ${LOOPBACK_ALIAS_IP}/32 on ${LOOPBACK_ALIAS_DEV}"
    if ip addr show "$LOOPBACK_ALIAS_DEV" | grep -q "$LOOPBACK_ALIAS_IP"; then
        ok "Loopback alias already present (idempotent skip)"
    else
        run "ip addr add ${LOOPBACK_ALIAS_IP}/32 dev ${LOOPBACK_ALIAS_DEV}"
        ok "Loopback alias added"
    fi
    # Persist via netplan if possible
    if [[ -d /etc/netplan && "$DRY_RUN" != "1" ]] && ! grep -rq "$LOOPBACK_ALIAS_IP" /etc/netplan/ 2>/dev/null; then
        local nf="/etc/netplan/90-psiphon-loopback.yaml"
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
            netplan apply >/dev/null 2>&1 || warn "netplan apply failed (alias applied at runtime)"
            ok "Loopback alias persisted in ${nf}"
        fi
    fi
}

#------------------------------------------------------------------------------
# STEP 3: SSH check (must be listening BEFORE and we verify again later)
#------------------------------------------------------------------------------
step_3_ssh_check() {
    step "STEP 3/9: SSH safety check (port ${SSH_PORT})"
    if check_ssh_alive; then
        ok "SSH is listening on port ${SSH_PORT}"
    else
        die "SSH is NOT listening on port ${SSH_PORT}. Aborting for your safety."
    fi
}

#------------------------------------------------------------------------------
# STEP 4: service user
#------------------------------------------------------------------------------
step_4_user() {
    step "STEP 4/9: Service user '${SERVICE_USER}'"
    if id "$SERVICE_USER" &>/dev/null; then
        ok "User ${SERVICE_USER} already exists (idempotent skip)"
    else
        run "useradd --system --no-create-home --shell /usr/sbin/nologin ${SERVICE_USER}"
        ok "System user ${SERVICE_USER} created"
    fi
}

#------------------------------------------------------------------------------
# STEP 5: download binary + integrity verification (sha256 + executable test)
#------------------------------------------------------------------------------
step_5_binary() {
    step "STEP 5/9: Download and verify ${BINARY_NAME}"
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
    run "curl -fSL --retry 3 --connect-timeout 30 -o ${tmp} ${BINARY_URL}"
    [[ -s "$tmp" ]] || die "Downloaded binary is empty"

    local sum
    sum=$(sha256sum "$tmp" | awk '{print $1}')
    echo "${sum}  ${dest}" > "${BIN_DIR}/${BINARY_NAME}.sha256"
    info "SHA256: ${sum}"

    if ! echo "${sum}  ${dest}" | sha256sum -c --quiet >/dev/null 2>&1; then
        # first install: dest not there yet; copy then verify
        run "install -m 755 ${tmp} ${dest}"
    else
        run "install -m 755 ${tmp} ${dest}"
    fi
    run "rm -f ${tmp}"

    # Integrity verification
    ( cd "$BIN_DIR" && sha256sum -c "${BINARY_NAME}.sha256" >/dev/null 2>&1 ) \
        || die "SHA256 verification FAILED for ${BINARY_NAME}"
    [[ -x "$dest" ]] || die "Binary is not executable"
    if ! ("$dest" -version >/dev/null 2>&1 || "$dest" --help >/dev/null 2>&1); then
        warn "Binary did not answer -version/--help; continuing (some builds need config on stdin)"
    fi
    chown root:"$SERVICE_USER" "$dest" 2>/dev/null || true
    ok "Binary integrity verified (sha256 + executable test)"
}

#------------------------------------------------------------------------------
# STEP 6: generate per-instance configs
#------------------------------------------------------------------------------
step_6_configs() {
    step "STEP 6/9: Generating ${PSIPHON_INSTANCES} instance configs"
    local i reg json iport
    for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
        reg=$(region_for_instance "$i")
        iport=$(( INBOUND_BASE_PORT + i ))
        json="${CONF_DIR}/psiphon-${i}.json"

        if [[ "$reg" == "-" ]]; then
            local egress_json="null"
        else
            local egress_json="\"$reg\""
        fi

        if [[ -f "$json" && "$DRY_RUN" != "1" ]]; then
            # idempotent: regenerate only if region or ports changed
            local cur_region
            cur_region=$(jq -r 'if .EgressRegion then .EgressRegion else "-" end' "$json" 2>/dev/null || echo "CHANGED")
            if [[ "$cur_region" == "$reg" ]]; then
                continue
            fi
        fi

        local content
        content=$(cat <<EOF
{
  "PropagationChannelId": "FFFFFFFFFFFFFFFF",
  "SponsorId": "FFFFFFFFFFFFFFFF",
  "LocalSocksProxyPort": ${SOCKS_BASE_PORT},
  "LocalHttpProxyPort": 0,
  "DisableLocalHTTPProxy": true,
  "EgressRegion": ${egress_json},
  "EgressRegionCombo": ${egress_json},
  "ListenInterface": "${SOCKS_LISTEN_IP}",
  "TargetInboundPort": ${iport},
  "UpstreamProxyUrl": "",
  "UseIndistinguishableTLS": true,
  "MeteredMetrics": false
}
EOF
)
        # Per-instance ports: rewrite LocalSocksProxyPort correctly
        local socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
        content=$(printf '%s' "$content" | python3 - "$i" "$socks_port" "$iport" <<'PYEOF'
import json, sys
i, socks, inbound = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
cfg = json.load(sys.stdin)
cfg["LocalSocksProxyPort"] = socks
cfg["TargetInboundPort"] = inbound
cfg["_instance"] = i
print(json.dumps(cfg, indent=2))
PYEOF
)
        if [[ "$DRY_RUN" == "1" ]]; then
            info "[DRY-RUN] would write ${json} (socks=${socks_port}, inbound=${iport}, region=${reg})"
        else
            printf '%s\n' "$content" > "$json"
        fi
        ok "Config ${i}: socks=${socks_port} inbound=${iport} region=${reg}"
    done
    if [[ "$DRY_RUN" != "1" ]]; then
        chown -R root:"$SERVICE_USER" "$CONF_DIR"
        chmod 640 "${CONF_DIR}"/*.json 2>/dev/null || true
    fi
    ok "All configs generated"
}

#------------------------------------------------------------------------------
# STEP 7: systemd units + logrotate
#------------------------------------------------------------------------------
step_7_systemd() {
    step "STEP 7/9: systemd units + logrotate"
    local i unit
    for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
        unit="/etc/systemd/system/psiphon@${i}.service"
        local socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
        if [[ -f "$unit" ]]; then
            continue  # idempotent
        fi
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
        systemctl daemon-reload
    fi

    # logrotate
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
}

#------------------------------------------------------------------------------
# STEP 8: start instances
#------------------------------------------------------------------------------
step_8_start() {
    step "STEP 8/9: Starting ${PSIPHON_INSTANCES} instances"
    local i
    for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
        run "systemctl enable psiphon@${i}.service"
        run "systemctl restart psiphon@${i}.service"
    done
    if [[ "$DRY_RUN" != "1" ]]; then
        sleep 3
        local running=0
        for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
            if systemctl is-active --quiet "psiphon@${i}.service"; then
                running=$(( running + 1 ))
            else
                warn "psiphon@${i}.service is not active"
            fi
        done
        ok "${running}/${PSIPHON_INSTANCES} instances active"
    fi
}

#------------------------------------------------------------------------------
# STEP 9: Xray injection + summary
#------------------------------------------------------------------------------
find_xray_config() {
    local candidates=(
        "/usr/local/x-ui/bin/config.json"
        "/etc/x-ui/config.json"
        "/etc/xray/config.json"
        "/usr/local/etc/xray/config.json"
        "/opt/3x-ui/bin/config.json"
        "/etc/3x-ui/config.json"
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -f "$c" ]] && { echo "$c"; return; }
    done
    # search for any 3x-ui style db-managed config
    find /usr/local /etc /opt -maxdepth 4 -name "config.json" 2>/dev/null \
        | grep -iE "(xray|x-ui|3x-ui)" | head -n1 || true
}

restart_panel() {
    local svc
    for svc in 3x-ui x-ui xray; do
        if systemctl list-unit-files | grep -q "^${svc}\.service"; then
            run "systemctl restart ${svc}"
            ok "Restarted panel service: ${svc}"
            return 0
        fi
    done
    warn "No panel service found to restart (3x-ui / x-ui / xray)"
}

step_9_xray() {
    step "STEP 9/9: Xray inbound injection (ports ${INBOUND_BASE_PORT}+1 .. +${PSIPHON_INSTANCES})"

    # Port collision detection BEFORE injection
    local i port conflicts=0
    for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
        port=$(( INBOUND_BASE_PORT + i ))
        if port_in_use "$port"; then
            if systemctl is-active --quiet "psiphon@${i}.service" 2>/dev/null; then
                info "Port ${port} used by our own psiphon@${i} (expected)"
            else
                warn "Port ${port} is already in use by another process!"
                conflicts=$(( conflicts + 1 ))
            fi
        fi
    done
    if (( conflicts > 0 )); then
        die "${conflicts} inbound port collision(s) detected. Free the ports or change INBOUND_BASE_PORT."
    fi
    ok "No unexpected port collisions on ${INBOUND_BASE_PORT}+1..+${PSIPHON_INSTANCES}"

    local xcfg
    xcfg=$(find_xray_config || true)
    if [[ -z "$xcfg" ]]; then
        warn "No Xray/x-ui config found in common panel paths - skipping injection"
        return 0
    fi
    info "Found Xray config: ${xcfg}"

    local backup="${BACKUP_DIR}/$(basename "$xcfg").$(date +%Y%m%d-%H%M%S).bak"
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[DRY-RUN] would backup ${xcfg} -> ${backup} and inject inbounds"
    else
        cp -a "$xcfg" "$backup"
        ok "Backup created: ${backup}"

        python3 - "$xcfg" "$INBOUND_BASE_PORT" "$PSIPHON_INSTANCES" "$SOCKS_BASE_PORT" "$SOCKS_LISTEN_IP" <<'PYEOF'
import json, sys

path = sys.argv[1]
base = int(sys.argv[2]); count = int(sys.argv[3])
socks_base = int(sys.argv[4]); lip = sys.argv[5]

with open(path) as f:
    cfg = json.load(f)

cfg.setdefault("inbounds", [])
cfg.setdefault("outbounds", [])
cfg.setdefault("routing", {}).setdefault("rules", [])

existing_ports = {ib.get("port") for ib in cfg["inbounds"]}
for i in range(1, count + 1):
    in_port = base + i
    socks_port = socks_base + i - 1
    tag_in = f"psiphon-in-{i}"
    tag_out = f"psiphon-socks-{i}"
    if in_port not in existing_ports:
        cfg["inbounds"].append({
            "listen": "0.0.0.0", "port": in_port, "protocol": "vless",
            "settings": {"clients": [], "decryption": "none"},
            "tag": tag_in,
            "streamSettings": {"network": "tcp", "security": "none"}
        })
    if not any(ob.get("tag") == tag_out for ob in cfg["outbounds"]):
        cfg["outbounds"].append({
            "tag": tag_out, "protocol": "socks",
            "settings": {"servers": [{"address": lip, "port": socks_port}]}
        })
    if not any(r.get("inboundTag") == [tag_in] for r in cfg["routing"]["rules"]):
        cfg["routing"]["rules"].append({
            "type": "field", "inboundTag": [tag_in], "outboundTag": tag_out
        })

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("Xray config updated OK")
PYEOF
        restart_panel
    fi
    ok "Xray injection step complete"
}

print_summary() {
    step "SUMMARY"
    local i reg iport socks_port status
    printf '%-8s | %-13s | %-11s | %-7s | %s\n' "Instance" "Inbound Port" "SOCKS Port" "Region" "Status"
    printf -- '---------+---------------+------------+--------+--------\n'
    for (( i=1; i<=PSIPHON_INSTANCES; i++ )); do
        reg=$(region_for_instance "$i")
        iport=$(( INBOUND_BASE_PORT + i ))
        socks_port=$(( SOCKS_BASE_PORT + i - 1 ))
        if [[ "$DRY_RUN" == "1" ]]; then
            status="(dry-run)"
        elif systemctl is-active --quiet "psiphon@${i}.service" 2>/dev/null; then
            status="active"
        else
            status="inactive"
        fi
        printf '%-8s | %-13s | %-11s | %-7s | %s\n' "$i" "$iport" "$socks_port" "$reg" "$status"
    done | tee -a "$LOG_FILE"
    echo -e "" | tee -a "$LOG_FILE"
    ok "Installation v${VERSION} finished. Log: ${LOG_FILE}"
    info "Test example:  curl --socks5 ${SOCKS_LISTEN_IP}:${SOCKS_BASE_PORT} https://ipinfo.io"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage; exit 0
    fi
    # Load config.env if present next to script
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [[ -f "${script_dir}/config.env" ]]; then
        # shellcheck disable=SC1091
        set -a; source "${script_dir}/config.env"; set +a
        info "Loaded config from ${script_dir}/config.env"
    fi
    # Re-apply defaults for any vars left empty
    PSIPHON_INSTANCES="${PSIPHON_INSTANCES:-20}"
    SOCKS_BASE_PORT="${SOCKS_BASE_PORT:-10800}"
    SOCKS_LISTEN_IP="${SOCKS_LISTEN_IP:-127.20.0.1}"
    INBOUND_BASE_PORT="${INBOUND_BASE_PORT:-20000}"
    SSH_PORT="${SSH_PORT:-22}"
    DRY_RUN="${DRY_RUN:-0}"

    is_root || die "This installer must run as root (try: sudo ./install.sh)"
    mkdir -p "$LOG_DIR"
    acquire_lock
    log "===== ${PROJECT_NAME} installer v${VERSION} started $(date -Is) ====="
    log "Instances=${PSIPHON_INSTANCES} SOCKS_BASE=${SOCKS_BASE_PORT} LISTEN=${SOCKS_LISTEN_IP} INBOUND_BASE=${INBOUND_BASE_PORT} SSH_PORT=${SSH_PORT} DRY_RUN=${DRY_RUN}"

    validate_regions "${EGRESS_REGIONS:-}"

    step_1_update_deps
    step_2_loopback
    step_3_ssh_check
    step_4_user
    step_5_binary
    step_6_configs
    step_7_systemd
    step_8_start
    step_9_xray

    # Final SSH safety verification after network changes
    if [[ "$DRY_RUN" != "1" ]] && ! check_ssh_alive; then
        ip addr del "${LOOPBACK_ALIAS_IP}/32" dev "$LOOPBACK_ALIAS_DEV" 2>/dev/null || true
        die "SSH stopped listening after changes! Loopback alias rolled back."
    fi

    print_summary
    log "===== installer finished $(date -Is) ====="
    return 0
}

main "$@"

--- 623 lines
