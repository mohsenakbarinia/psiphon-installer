#!/usr/bin/env bash
# =============================================================================
# Psiphon Multi-Region Installer v3.0
# Ubuntu 24.04 | psiphon-tunnel-core + Xray (x-ui/3x-ui)
# =============================================================================
set -Eeuo pipefail

# ── Re-exec safely (detach from SSH session) ─────────────────────────────────
if [[ -z "${PSIPHON_DETACHED:-}" ]]; then
    LOG_DIR="/var/log/psiphon"
    mkdir -p "$LOG_DIR"
    LOGFILE="$LOG_DIR/install.log"
    export PSIPHON_DETACHED=1
    echo "[*] Re-launching in detached mode. Follow: tail -f $LOGFILE"
    nohup setsid bash "$0" "$@" >"$LOGFILE" 2>&1 &
    disown
    exit 0
fi

# ── Config ────────────────────────────────────────────────────────────────────
PSIPHON_INSTANCES="${PSIPHON_INSTANCES:-20}"
PSIPHON_USER="psiphon"
PSIPHON_DIR="/opt/psiphon"
PSIPHON_BIN="$PSIPHON_DIR/psiphon-tunnel-core"
SOCKS_BASE_PORT=10800          # instance N → port 10800+N  (10801–10820)
SOCKS_LISTEN_IP="127.20.0.1"   # loopback alias (avoids clash with 127.0.0.1)
INBOUND_BASE_PORT=20000        # instance N → port 20000+N  (20001-20020)
XRAY_TAG_IN_PREFIX="psiphon-in-"
XRAY_TAG_OUT_PREFIX="psiphon-out-"
GITHUB_REPO="Psiphon-Labs/psiphon-tunnel-core"
LOG_DIR="/var/log/psiphon"
BACKUP_DIR="$PSIPHON_DIR/backups"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root."

# ── Loopback alias (127.20.0.1) ───────────────────────────────────────────────
setup_loopback_alias() {
    if ! ip addr show lo | grep -q "$SOCKS_LISTEN_IP"; then
        log "Adding loopback alias $SOCKS_LISTEN_IP"
        ip addr add "$SOCKS_LISTEN_IP/8" dev lo 2>/dev/null || true
        
        # Persist across reboots
        cat > /etc/systemd/network/10-lo-alias.network <<EOF
[Match]
Name=lo

[Network]
Address=$SOCKS_LISTEN_IP/8
EOF
        systemctl restart systemd-networkd 2>/dev/null || true
    fi
}

# ── Install dependencies ──────────────────────────────────────────────────────
install_deps() {
    log "Installing dependencies..."
    apt-get update -qq
    apt-get install -y -qq curl jq python3 ca-certificates unzip iproute2 || \
        die "apt-get failed"
    ok "Dependencies ready"
}

# ── Create system user ────────────────────────────────────────────────────────
create_user() {
    if ! id "$PSIPHON_USER" &>/dev/null; then
        log "Creating system user: $PSIPHON_USER"
        useradd --system --no-create-home --shell /usr/sbin/nologin "$PSIPHON_USER"
    fi
}

# ── Download psiphon-tunnel-core ──────────────────────────────────────────────
download_psiphon() {
    mkdir -p "$PSIPHON_DIR" "$LOG_DIR" "$BACKUP_DIR"

    if [[ -x "$PSIPHON_BIN" ]]; then
        warn "psiphon-tunnel-core already exists — skipping download"
        return
    fi

    log "Fetching latest psiphon-tunnel-core release..."
    LATEST_URL=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
assets = data.get('assets', [])
for a in assets:
    if 'linux' in a['name'].lower() and 'amd64' in a['name'].lower() and a['name'].endswith('.tar.gz'):
        print(a['browser_download_url'])
        break
" 2>/dev/null) || true

    # Fallback: try direct URL pattern
    if [[ -z "$LATEST_URL" ]]; then
        LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null)
        LATEST_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/psiphon-tunnel-core_${LATEST_TAG#v}_linux_amd64.tar.gz"
    fi

    log "Downloading: $LATEST_URL"
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    curl -fsSL -o "$TMP_DIR/psi.tar.gz" "$LATEST_URL" || die "Download failed"
    tar -xzf "$TMP_DIR/psi.tar.gz" -C "$TMP_DIR"
    BIN_FILE=$(find "$TMP_DIR" -name "psiphon-tunnel-core" -type f | head -1)
    [[ -n "$BIN_FILE" ]] || die "Binary not found in archive"
    install -m 755 "$BIN_FILE" "$PSIPHON_BIN"
    ok "psiphon-tunnel-core installed: $PSIPHON_BIN"
}

# ── Generate per-instance config ──────────────────────────────────────────────
generate_config() {
    local n="$1"
    local socks_port=$(( SOCKS_BASE_PORT + n ))
    local cfg="$PSIPHON_DIR/config-${n}.json"

    [[ -f "$cfg" ]] && return  # idempotent

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
    ok "Config generated: $cfg"
}

# ── Systemd unit (template) ───────────────────────────────────────────────────
install_systemd_template() {
    cat > /etc/systemd/system/psiphon@.service <<EOF
[Unit]
Description=Psiphon Tunnel Instance %i
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${PSIPHON_USER}
Group=${PSIPHON_USER}
ExecStart=${PSIPHON_BIN} -config ${PSIPHON_DIR}/config-%i.json
Restart=on-failure
RestartSec=5s
StandardOutput=append:${LOG_DIR}/psiphon-%i.log
StandardError=append:${LOG_DIR}/psiphon-%i.log

# Hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${PSIPHON_DIR} ${LOG_DIR}
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ok "Systemd template installed: psiphon@.service"
}

# ── Enable & start instances ──────────────────────────────────────────────────
start_instances() {
    for n in $(seq 1 "$PSIPHON_INSTANCES"); do
        generate_config "$n"
        systemctl enable --now "psiphon@${n}.service" 2>/dev/null || \
            systemctl restart "psiphon@${n}.service" 2>/dev/null || true
    done
    sleep 2  # allow brief startup
}

# ── Find Xray config ──────────────────────────────────────────────────────────
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
    # Dynamic search
    find /etc /opt /usr/local -maxdepth 5 -name "config.json" 2>/dev/null \
        | xargs grep -l '"inbounds"' 2>/dev/null \
        | head -1 || true
}

# ── Inject Xray inbounds + routingDIR}/psiphon-%i.log

# Hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${PSIPHON_DIR} ${LOG_DIR}
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ok "Systemd template installed: psiphon@.service"
}

# ── Enable & start instances ──────────────────────────────────────────────────
start_instances() {
    for n in $(seq 1 "$PSIPHON_INSTANCES"); do
        generate_config "$n"
        systemctl enable --now "psiphon@${n}.service" 2>/dev/null || \
            systemctl restart "psiphon@${n}.service" 2>/dev/null || true
    done
    sleep 2  # allow brief startup
}

# ── Find Xray config ──────────────────────────────────────────────────────────
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
    # Dynamic search
    find /etc /opt /usr/local -maxdepth 5 -name "config.json" 2>/dev/null \
        | xargs grep -l '"inbounds"' 2>/dev/null \
        | head -1 || true
}

# ── Inject Xray inbounds + routing (Python3, no jq dependency) ───────────────
inject_xray_config() {
    local XRAY_CFG
    XRAY_CFG=$(find_xray_config)

    ifport") for ib in cfg["inbounds"]}
existing_out_ports= set()  # SOCKS outbounds use address+port

routing_tags = {
    r.get("inboundTag", [None])[0] if isinstance(r.get("inboundTag"), list) else r.get("inboundTag")
    for r in cfg["routing"]["rules"]
}

for n in range(1, n_instances + 1):
    tag_in   = f"{tag_in_pfx}{n}"
    tag_out  = f"{tag_out_pfx}{n}"
    in_port  = inbound_base + n
    s_port   = socks_base + n

    # ── Inbound (VLESS) ──────────────────────────────────────────────────
    if tag_in not in existing_in_tags and in_port not in existing_in_ports:
        import uuid
        inbound = {
            "tag":      tag_in,
            "listen":   "0.0.0.0",
            "port":     in_port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": str(uuid.uuid4()), "flow": ""}],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "tcpSettings": {"header": {"type": "none"}}
            },
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
        }
        cfg["inbounds"].append(inbound)

    # ── Outbound (SOCKS5 → Psiphon) ──────────────────────────────────────
    if tag_out not in existing_out_tags:
        outbound = {
            "tag":      tag_out,
            "protocol": "socks",
            "settings": {
                "servers": [{
                    "address": socks_ip,
                    "port":    s_port
                }]
            }
        }
        cfg["outbounds"].append(outbound)

    # ── Routing rule: inbound N → outbound SOCKS N ───────────────────────
    if tag_in not in routing_tags:
        rule = {
            "type":        "field",
            "inboundTag":  [tag_in],
            "outboundTag": tag_out
        }
        cfg["routing"]["rules"].append(rule)

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)

print(f"[ok] Xray config updated: {n_instances} inbound/outbound pairs injected.")
PYEOF

    ok "Xray config updated: $XRAY_CFG"

    # Restart x-ui / xray service
    for svc in x-ui 3x-ui xray; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "Restarting $svc..."
            systemctl restart "$svc" && ok "$svc restarted"
            break
        fi
    done
}

# ── Fix permissions ───────────────────────────────────────────────────────────
fix_permissions() {
    chown -R "$PSIPHON_USER":"$PSIPHON_USER" "$PSIPHON_DIR" "$LOG_DIR"
    chmod 750 "$PSIPHON_DIR"
    chmod 640 "$PSIPHON_DIR"/config-*.json 2>/dev/null || true
}

# ── Summary table ─────────────────────────────────────────────────────────────
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
    echo -e "  Logs   : ${YELLOW}tail -f $LOG_DIR/psiphon-N.log${NC}"
    echo -e "  Install: ${YELLOW}tail -f $LOG_DIR/install.log${NC}"
    echo -e "  Restart: ${YELLOW}systemctl restart psiphon@N.service${NC}"
    echo
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    log "=== Psiphon Multi-Region Install v3.0 ==="
    log "Instances: $PSIPHON_INSTANCES"
    log "Inbound ports : $(( INBOUND_BASE_PORT + 1 ))–$(( INBOUND_BASE_PORT + PSIPHON_INSTANCES ))"
    log "SOCKS5 ports  : $(( SOCKS_BASE_PORT + 1 ))–$(( SOCKS_BASE_PORT + PSIPHON_INSTANCES ))"
    echo

    install_deps
    create_user
    setup_loopback_alias
    download_psiphon
    install_systemd_template
    start_instances
    fix_permissions
    inject_xray_config
    print_summary

    ok "Installation complete."
}

main "$@"
