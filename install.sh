#!/usr/bin/env bash
# =============================================================================
# Psiphon Multi-Region Auto-Installer v4.5 (Full System Update First)
# =============================================================================
set -Eeuo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PSIPHON_INSTANCES="${PSIPHON_INSTANCES:-20}"
PSIPHON_USER="psiphon"
PSIPHON_DIR="/opt/psiphon"
PSIPHON_BIN="$PSIPHON_DIR/psiphon-tunnel-core"
SOCKS_BASE_PORT=10800          # Instance N -> Port 10800+N (10801–10820)
SOCKS_LISTEN_IP="127.20.0.1"   # Dedicated Loopback IP
INBOUND_BASE_PORT=20000        # Instance N -> Port 20000+N (20001–20020)
XRAY_TAG_IN_PREFIX="psiphon-in-"
XRAY_TAG_OUT_PREFIX="psiphon-out-"
LOG_DIR="/var/log/psiphon"
BACKUP_DIR="$PSIPHON_DIR/backups"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "This script must be run as root."

# ── Step 1: Update & Upgrade Entire System First ──────────────────────────────
update_and_install_deps() {
    log "Step 1/8: Updating package indices & upgrading entire system packages..."
    export DEBIAN_FRONTEND=noninteractive

    # Refresh repositories
    apt-get update -qq -y || warn "apt-get update showed minor warnings, continuing..."

    # Full system upgrade
    log "Performing full system upgrade (dist-upgrade)..."
    apt-get dist-upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || \
        apt-get upgrade -y -qq || warn "Some packages could not be upgraded, proceeding..."

    log "Installing mandatory system dependencies..."
    local PKGS=(
        curl
        wget
        jq
        python3
        python3-pip
        ca-certificates
        iproute2
        net-tools
        tar
        gzip
        unzip
        systemd
    )

    apt-get install -y -qq "${PKGS[@]}" || die "Failed to install required system packages."
    ok "Entire system updated & all dependencies installed successfully."
}

# ── Step 2: Setup Loopback IP Alias ───────────────────────────────────────────
setup_loopback_alias() {
    log "Step 2/8: Configuring persistent loopback IP alias ($SOCKS_LISTEN_IP)..."
    
    # Assign immediately
    ip addr add "$SOCKS_LISTEN_IP/32" dev lo 2>/dev/null || true

    # Systemd persistence service
    cat > /etc/systemd/system/psiphon-ip-alias.service <<EOF
[Unit]
Description=Psiphon Loopback IP Alias Setup
Before=network.target psiphon@.service
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/sbin/ip addr add $SOCKS_LISTEN_IP/32 dev lo
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

    systemctl daemon-reload
    systemctl enable --now psiphon-ip-alias.service 2>/dev/null || true

    if ip addr show lo | grep -q "$SOCKS_LISTEN_IP"; then
        ok "Loopback IP alias $SOCKS_LISTEN_IP is active and configured."
    else
        die "Failed to assign loopback alias $SOCKS_LISTEN_IP"
    fi
}

# ── Step 3: Create Dedicated System User ──────────────────────────────────────
create_user() {
    log "Step 3/8: Checking system user..."
    if ! id "$PSIPHON_USER" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$PSIPHON_USER"
        ok "User $PSIPHON_USER created."
    else
        ok "User $PSIPHON_USER already exists."
    fi
}

# ── Step 4: Download Core Binary ──────────────────────────────────────────────
download_psiphon() {
    log "Step 4/8: Checking Psiphon Core executable..."
    mkdir -p "$PSIPHON_DIR" "$LOG_DIR" "$BACKUP_DIR"

    if [[ -x "$PSIPHON_BIN" ]]; then
        ok "Psiphon binary already present."
        return
    fi

    log "Downloading Psiphon Core binary..."
    local BINARY_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"

    if ! curl -fsSL -o "$PSIPHON_BIN" "$BINARY_URL"; then
        wget -q -O "$PSIPHON_BIN" "$BINARY_URL" || die "Failed to download Psiphon binary."
    fi

    chmod 755 "$PSIPHON_BIN"
    ok "Psiphon Core installed successfully."
}

# ── Step 5: Generate Configurations ───────────────────────────────────────────
generate_configs() {
    log "Step 5/8: Generating configuration files for $PSIPHON_INSTANCES instances..."
    for n in $(seq 1 "$PSIPHON_INSTANCES"); do
        local socks_port=$(( SOCKS_BASE_PORT + n ))
        local cfg="$PSIPHON_DIR/config-${n}.json"

        if [[ ! -f "$cfg" ]]; then
            python3 - <<PYEOF
import json
config = {
    "PropagationChannelId":       "FFFFFFFFFFFFFFFF",
    "SponsorId":                  "FFFFFFFFFFFFFFFF",
    "LocalSocksProxyPort":        ${socks_port},
    "LocalHttpProxyPort":         0,
    "ListenInterface":            "${SOCKS_LISTEN_IP}",
    "EgressRegion":               "",
    "DisableLocalSocksProxy":     False,
    "DisableLocalHTTPProxy":      True,
    "EmitDiagnosticNotices":      True,
    "DataRootDirectory":          "${PSIPHON_DIR}/data-${n}",
    "MigrateDataStoreDirectory":  "${PSIPHON_DIR}/data-${n}",
}
with open("${cfg}", "w") as f:
    json.dump(config, f, indent=2)
PYEOF
            mkdir -p "$PSIPHON_DIR/data-${n}"
        fi
    done
    ok "Instance configs generated."
}

# ── Step 6: Systemd Template Setup ───────────────────────────────────────────
setup_systemd() {
    log "Step 6/8: Setting up Systemd service templates..."
    cat > /etc/systemd/system/psiphon@.service <<EOF
[Unit]
Description=Psiphon Tunnel Instance %i
Requires=psiphon-ip-alias.service
After=network-online.target psiphon-ip-alias.service
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${PSIPHON_USER}
Group=${PSIPHON_USER}
ExecStart=${PSIPHON_BIN} -config ${PSIPHON_DIR}/config-%i.json
Restart=on-failure
RestartSec=3s
StandardOutput=append:${LOG_DIR}/psiphon-%i.log
StandardError=append:${LOG_DIR}/psiphon-%i.log

# Security Hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${PSIPHON_DIR} ${LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ok "Systemd template updated."
}

# ── Step 7: Start Services ────────────────────────────────────────────────────
start_instances() {
    log "Step 7/8: Launching $PSIPHON_INSTANCES Psiphon instances..."
    for n in $(seq 1 "$PSIPHON_INSTANCES"); do
        systemctl enable --now "psiphon@${n}.service" 2>/dev/null || \
            systemctl restart "psiphon@${n}.service" 2>/dev/null || true
    done
    sleep 3
    ok "All instances started."
}

# ── Step 8: Inject Xray Configuration ─────────────────────────────────────────
find_xray_config() {
    local candidates=(
        "/etc/x-ui/xray.json"
        "/usr/local/x-ui/bin/config.json"
        "/etc/xray/config.json"
        "/usr/local/etc/xray/config.json"
        "/opt/xray/config.json"
    )
    for c in "${candidates[@]}"; do
        [[ -f "$c" ]] && { echo "$c"; return; }
    done
    find /etc /opt /usr/local -maxdepth 5 -name "config.json" 2>/dev/null \
        | xargs grep -l '"inbounds"' 2>/dev/null \
        | head -1 || true
}

inject_xray() {
    log "Step 8/8: Injecting routes into Xray/Panel configuration..."
    local XRAY_CFG
    XRAY_CFG=$(find_xray_config)

    [[ -z "$XRAY_CFG" ]] && { warn "Xray config not found, skipping injection."; return; }

    log "Updating Xray config: $XRAY_CFG"
    cp "$XRAY_CFG" "${BACKUP_DIR}/xray_config_backup.json"

    python3 - <<PYEOF
import json, uuid

cfg_path = "${XRAY_CFG}"
n_instances = ${PSIPHON_INSTANCES}
tag_in_pfx = "${XRAY_TAG_IN_PREFIX}"
tag_out_pfx = "${XRAY_TAG_OUT_PREFIX}"
socks_base = ${SOCKS_BASE_PORT}
inbound_base = ${INBOUND_BASE_PORT}
socks_ip = "${SOCKS_LISTEN_IP}"

with open(cfg_path, "r") as f:
    cfg = json.load(f)

cfg.setdefault("inbounds", [])
cfg.setdefault("outbounds", [])
cfg.setdefault("routing", {}).setdefault("rules", [])

existing_in_tags = {ib.get("tag") for ib in cfg["inbounds"]}
existing_out_tags = {ob.get("tag") for ob in cfg["outbounds"]}
existing_in_ports = {ib.get("port") for ib in cfg["inbounds"]}

routing_tags = {
    r.get("inboundTag", [None])[0] if isinstance(r.get("inboundTag"), list) else r.get("inboundTag")
    for r in cfg["routing"]["rules"]
}

for n in range(1, n_instances + 1):
    tag_in   = f"{tag_in_pfx}{n}"
    tag_out  = f"{tag_out_pfx}{n}"
    in_port  = inbound_base + n
    s_port   = socks_base + n

    if tag_in not in existing_in_tags and in_port not in existing_in_ports:
        cfg["inbounds"].append({
            "tag": tag_in, "listen": "0.0.0.0", "port": in_port, "protocol": "vless",
            "settings": {"clients": [{"id": str(uuid.uuid4()), "flow": ""}], "decryption": "none"},
            "streamSettings": {"network": "tcp", "tcpSettings": {"header": {"type": "none"}}},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
        })

    if tag_out not in existing_out_tags:
        cfg["outbounds"].append({
            "tag": tag_out, "protocol": "socks",
            "settings": {"servers": [{"address": socks_ip, "port": s_port}]}
        })

    if tag_in not in routing_tags:
        cfg["routing"]["rules"].append({
            "type": "field", "inboundTag": [tag_in], "outboundTag": tag_out
        })

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF

    ok "Xray configuration updated."
    for svc in 3x-ui x-ui xray; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl restart "$svc" && ok "$svc restarted."
            break
        fi
    done
}

# ── Fix Permissions ───────────────────────────────────────────────────────────
fix_permissions() {
    chown -R "$PSIPHON_USER":"$PSIPHON_USER" "$PSIPHON_DIR" "$LOG_DIR"
    chmod 750 "$PSIPHON_DIR"
    chmod 640 "$PSIPHON_DIR"/config-*.json 2>/dev/null || true
}

# ── Print Summary ─────────────────────────────────────────────────────────────
print_summary() {
    echo
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    printf "${CYAN}%-5s %-22s %-18s %-10s${NC}\n" "#" "Inbound (VLESS)" "Psiphon SOCKS5" "Status"
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    for n in $(seq 1 "$PSIPHON_INSTANCES"); do
        in_port=$(( INBOUND_BASE_PORT + n ))
        s_port=$(( SOCKS_BASE_PORT + n ))
        status=$(systemctl is-active "psiphon@${n}.service" 2>/dev/null || echo "unknown")
        [[ "$status" == "active" ]] && sc="${GREEN}" || sc="${RED}"
        printf "%-5s %-22s %-18s ${sc}%-10s${NC}\n" \
            "$n" "0.0.0.0:${in_port}" "${SOCKS_LISTEN_IP}:${s_port}" "$status"
    done
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    log "=== Psiphon Multi-Region Auto-Installer v4.5 ==="
    update_and_install_deps
    setup_loopback_alias
    create_user
    download_psiphon
    generate_configs
    setup_systemd
    start_instances
    fix_permissions
    inject_xray
    print_summary
    ok "Full installation completed successfully!"
}

main "$@"
