#!/usr/bin/env bash
# =============================================================================
# Psiphon Multi-Region Installer v5.1
# Installs 20 Psiphon instances + optional Xray inbounds
# SOCKS ports: 10800-10819 (loopback 127.20.0.x)
# Xray inbound ports: 20000-20019
# =============================================================================
set -Eeuo pipefail

# --- Constants ---------------------------------------------------------------
readonly VERSION="5.1"
readonly INSTALL_DIR="/opt/psiphon-multi-region"
readonly PSIPHON_USER="psiphon"
readonly INSTANCE_COUNT=20
readonly BASE_LOOPBACK="127.20.0"
readonly SOCKS_BASE_PORT=10800
readonly XRAY_BASE_PORT=20000
readonly LOG_FILE="/var/log/psiphon-installer.log"
readonly LOCK_FILE="/tmp/psiphon-installer.lock"

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

# --- Logging -----------------------------------------------------------------
log()  { echo -e "$(date '+%F %T') [INFO]  $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "$(date '+%F %T') [WARN]  ${YELLOW}$*${NC}" | tee -a "$LOG_FILE"; }
err()  { echo -e "$(date '+%F %T') [ERROR] ${RED}$*${NC}" | tee -a "$LOG_FILE" >&2; }
ok()   { echo -e "$(date '+%F %T') [OK]    ${GREEN}$*${NC}" | tee -a "$LOG_FILE"; }

# --- Lock --------------------------------------------------------------------
acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        err "Another instance of this installer is running. Exiting."
        exit 1
    fi
}

# --- Root check --------------------------------------------------------------
ROOT_CHECK() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (sudo)."
        exit 1
    fi
}

# --- SSH safety check --------------------------------------------------------
SSH_SAFETY_CHECK() {
    log "Checking SSH connectivity safety..."
    local ssh_port
    ssh_port=$(ss -tlnp | awk '/sshd/{print $4}' | grep -oP ':\K[0-9]+' | head -1)
    ssh_port=${ssh_port:-22}

    if ! ufw status | grep -qE "^${ssh_port}.*ALLOW"; then
        warn "SSH port ${ssh_port} may not be open in UFW. Adding rule before any changes."
        ufw allow "${ssh_port}/tcp" comment "SSH - psiphon-installer safety" || true
    fi
    ok "SSH safety check passed (port ${ssh_port})."
}

# --- Install prerequisites ---------------------------------------------------
INSTALL_DEPS() {
    log "Updating package lists..."
    apt-get update -qq

    local pkgs=(curl wget unzip jq ufw netplan.io iproute2 systemd)
    local missing=()
    for pkg in "${pkgs[@]}"; do
        dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "Installing missing packages: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    else
        ok "All prerequisites already installed."
    fi
}

# --- Create system user ------------------------------------------------------
CREATE_USER() {
    if ! id "$PSIPHON_USER" &>/dev/null; then
        log "Creating system user: ${PSIPHON_USER}"
        useradd --system --no-create-home --shell /usr/sbin/nologin "$PSIPHON_USER"
        ok "User ${PSIPHON_USER} created."
    else
        ok "User ${PSIPHON_USER} already exists."
    fi
}

# --- Setup directories -------------------------------------------------------
SETUP_DIRS() {
    log "Setting up directories under ${INSTALL_DIR}..."
    mkdir -p "${INSTALL_DIR}"/{bin,configs,logs,data}
    chown -R "${PSIPHON_USER}:${PSIPHON_USER}" "${INSTALL_DIR}"
    chmod 750 "${INSTALL_DIR}"
    ok "Directories ready."
}

# --- Download psiphon-tunnel-core --------------------------------------------
DOWNLOAD_PSIPHON() {
    local bin="${INSTALL_DIR}/bin/psiphon-tunnel-core"

    if [[ -x "$bin" ]]; then
        ok "psiphon-tunnel-core already present, skipping download."
        return
    fi

    log "Downloading psiphon-tunnel-core..."
    mkdir -p "${INSTALL_DIR}/bin"

    local arch
    arch=$(uname -m)
    local asset
    case "$arch" in
        x86_64)  asset="psiphon-tunnel-core-x86_64-linux" ;;
        aarch64) asset="psiphon-tunnel-core-aarch64-linux" ;;
        *)
            err "Unsupported architecture: ${arch}"
            exit 1
            ;;
    esac

    local api_url="https://api.github.com/repos/Psiphon-Labs/psiphon-tunnel-core/releases/latest"
    local download_url
    download_url=$(curl -fsSL "$api_url" \
        | jq -r --arg asset "$asset" '.assets[] | select(.name==$asset) | .browser_download_url')

    if [[ -z "$download_url" ]]; then
        err "Could not find download URL for ${asset}."
        exit 1
    fi

    curl -fsSL -o "$bin" "$download_url"
    chmod +x "$bin"
    chown "${PSIPHON_USER}:${PSIPHON_USER}" "$bin"
    ok "psiphon-tunnel-core downloaded and installed."
}

# --- Generate Psiphon configs ------------------------------------------------
GEN_PSIPHON_CONFIGS() {
    log "Generating Psiphon instance configs (${INSTANCE_COUNT} instances)..."

    for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
        local idx=$(printf "%02d" "$i")
        local socks_port=$(( SOCKS_BASE_PORT + i ))
        local loopback_ip="${BASE_LOOPBACK}.$(( i + 1 ))"
        local cfg="${INSTALL_DIR}/configs/psiphon-${idx}.json"

        cat > "$cfg" <<EOF
{
  "PropagationChannelId": "FFFFFFFFFFFFFFFF",
  "SponsorId": "FFFFFFFFFFFFFFFF",
  "LocalSocksProxyPort": ${socks_port},
  "LocalHttpProxyPort": 0,
  "ListenInterface": "${loopback_ip}",
  "DisableLocalSocksProxy": false,
  "DisableLocalHTTPProxy": true,
  "DataRootDirectory": "${INSTALL_DIR}/data/instance-${idx}",
  "MigrateDataStoreDirectory": "",
  "TunnelProtocol": "",
  "EgressRegion": "",
  "EmitDiagnosticNotices": true,
  "EmitDiagnosticNetworkParameters": false
}
EOF
        mkdir -p "${INSTALL_DIR}/data/instance-${idx}"
        chown -R "${PSIPHON_USER}:${PSIPHON_USER}" "$cfg" "${INSTALL_DIR}/data/instance-${idx}"
    done

    ok "Psiphon configs generated."
}

# --- Configure loopback addresses via netplan --------------------------------
SETUP_NETPLAN() {
    log "Configuring loopback aliases via netplan..."

    local netplan_file="/etc/netplan/99-psiphon-loopback.yaml"
    local addresses=()
    for i in $(seq 1 "$INSTANCE_COUNT"); do
        addresses+=("          - ${BASE_LOOPBACK}.${i}/32")
    done

    cat > "$netplan_file" <<EOF
network:
  version: 2
  ethernets:
    lo:
      match:
        name: lses[resses:
$(printf '%s\n' "${addresses[@]}")
EOF

    log "Applying netplan (timeout 30s)..."
    if ! timeout 30 netplan apply 2>>"$LOG_FILE"; then
        warn "netplan apply timed out or failed. Loopback aliases may need manual setup."
    else
        ok "Netplan applied."
    fi
}

# --- Create systemd service per instance ------------------------------------
CREATE_SERVICES() {
    log "Creating systemd service units..."

    for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
        local idx=$(printf "%02d" "$i")
        local svc="psiphon-instance-${idx}.service"

        cat > "/etc/systemd/system/${svc}" <<EOF
[Unit]
Description=Psiphon Multi-Region Instance ${idx}
After=network.target
Wants=network.target

[Service]
Type=simple
User=${PSIPHON_USER}
Group=${PSIPHON_USER}
ExecStart=${INSTALL_DIR}/bin/psiphon-tunnel-core \
    -config ${INSTALL_DIR}/configs/psiphon-${idx}.json
Restart=on-failure
RestartSec=5
StandardOutput=append:${INSTALL_DIR}/logs/instance-${idx}.log
StandardError=append:${INSTALL_DIR}/logs/instance-${idx}.log
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    done

    systemctl daemon-reload
    ok "Systemd units created."
}

# --- Optional: Download and configure Xray ----------------------------------
DOWNLOAD_XRAY() {
    log "Downloading Xray..."
    local xray_dir="${INSTALL_DIR}/bin/xray"
    mkdir -p "$xray_dir"

    local arch
    arch=$(uname -m)
    local asset
    case "$arch" in
        x86_64)  asset="Xray-linux-64.zip" ;;
        aarch64) asset="Xray-linux-arm64-v8a.zip" ;;
        *)
            err "Unsupported architecture for Xray: ${arch}"
            exit 1
            ;;
    esac

    local api_url="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    local download_url
    download_url=$(curl -fsSL "$api_url" \
        | jq -r --arg asset "$asset" '.assets[] | select(.name==$asset) | .browser_download_url')

    if [[ -z "$download_url" ]]; then
        err "Could not find Xray download URL for ${asset}."
        exit 1
    fi

    local tmp_zip
    tmp_zip=$(mktemp /tmp/xray-XXXXXX.zip)
    curl -fsSL -o "$tmp_zip" "$download_url"
    unzip -oq "$tmp_zip" -d "$xray_dir"
    rm -f "$tmp_zip"
    chmod +x "${xray_dir}/xray"
    chown -R "${PSIPHON_USER}:${PSIPHON_USER}" "$xray_dir"
    ok "Xray downloaded and installed."
}

GEN_XRAY_CONFIGS() {
    log "Generating Xray inbound configs (${INSTANCE_COUNT} instances)..."

    for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
        local idx=$(printf "%02d" "$i")
        local inbound_port=$(( XRAY_BASE_PORT + i ))
        local socks_port=$(( SOCKS_BASE_PORT + i ))
        local loopback_ip="${BASE_LOOPBACK}.$(( i + 1 ))"
        local cfg="${INSTALL_DIR}/configs/xray-${idx}.json"

        cat > "$cfg" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${INSTALL_DIR}/logs/xray-${idx}-access.log",
    "error":  "${INSTALL_DIR}/logs/xray-${idx}-error.log"
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
      "tag": "inbound-${idx}"
    }
  ],
  "outbounds": [
    {
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "${loopback_ip}",
            "port": ${socks_port}
          }
        ]
      },
      "tag": "psiphon-${idx}"
    }
  ]
}
EOF
        chown "${PSIPHON_USER}:${PSIPHON_USER}" "$cfg"
    done

    ok "Xray configs generated."
}

CREATE_XRAY_SERVICES() {
    log "Creating Xray systemd service units..."

    for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
        local idx=$(printf "%02d" "$i")
        local svc="xray-instance-${idx}.service"

        cat > "/etc/systemd/system/${svc}" <<EOF
[Unit]
Description=Xray Multi-Region Instance ${idx}
After=network.target psiphon-instance-${idx}.service
Wants=psiphon-instance-${idx}.service

[Service]
Type=simple
User=${PSIPHON_USER}
Group=${PSIPHON_USER}
ExecStart=${INSTALL_DIR}/bin/xray/xray run \
    -config ${INSTALL_DIR}/configs/xray-${idx}.json
Restart=on-failure
RestartSec=5
StandardOutput=append:${INSTALL_DIR}/logs/xray-${idx}.log
StandardError=append:${INSTALL_DIR}/logs/xray-${idx}.log
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    done

    systemctl daemon-reload
    ok "Xray systemd units created."
}

# --- Configure UFW -----------------------------------------------------------
SETUP_UFW() {
    log "Configuring UFW rules..."

    # Allow Xray inbound ports
    ufw allow "${XRAY_BASE_PORT}:$(( XRAY_BASE_PORT + INSTANCE_COUNT - 1 ))/tcp" \
        comment "Psiphon Multi-Region Xray inbounds"

    # Ensure UFW is enabled (won't disconnect SSH if SSH rule already exists)
    if ! ufw status | grep -q "Status: active"; then
        ufw --force enable
    fi

    ok "UFW configured."
}

# --- Start services with retry -----------------------------------------------
START_SERVICES() {
    local with_xray="${1:-false}"
    log "Enabling and starting Psiphon services..."

    for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
        local idx=$(printf "%02d" "$i")
        systemctl enable --now "psiphon-instance-${idx}.service" 2>>"$LOG_FILE" || true
    done

    if [[ "$with_xray" == "true" ]]; then
        log "Enabling and starting Xray services..."
        for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
            local idx=$(printf "%02d" "$i")
            systemctl enable --now "xray-instance-${idx}.service" 2>>"$LOG_FILE" || true
        done
    fi

    # Retry loop: wait up to 30s for first psiphon instance
    log "Waiting for psiphon-instance-00 to become active..."
    local retries=10
    for (( n=1; n<=retries; n++ )); do
        if systemctl is-active --quiet psiphon-instance-00.service; then
            ok "psiphon-instance-00 is active."
            break
        fi
        if (( n == retries )); then
            warn "psiphon-instance-00 did not start within ${retries} attempts. Check logs."
        else
            log "Attempt ${n}/${retries} — waiting 3s..."
            sleep 3
        fi
    done
}

# --- Print summary -----------------------------------------------------------
PRINT_SUMMARY() {
    local with_xray="${1:-false}"
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${GREEN}  Psiphon Multi-Region v${VERSION} — Installation Complete${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
    echo "  Instances  : ${INSTANCE_COUNT}"
    echo "  SOCKS ports: ${SOCKS_BASE_PORT} – $(( SOCKS_BASE_PORT + INSTANCE_COUNT - 1 ))"
    echo "  Loopback   : ${BASE_LOOPBACK}.1 – ${BASE_LOOPBACK}.${INSTANCE_COUNT}"
    if [[ "$with_xray" == "true" ]]; then
        echo "  Xray ports : ${XRAY_BASE_PORT} – $(( XRAY_BASE_PORT + INSTANCE_COUNT - 1 ))"
    fi
    echo ""
    echo "  Install dir: ${INSTALL_DIR}"
    echo "  Logs       : ${INSTALL_DIR}/logs/"
    echo "  Installer  : ${LOG_FILE}"
    echo ""
    echo "  Status check:"
    echo "    systemctl status psiphon-instance-00.service"
    echo ""
    echo -e "${BLUE}============================================================${NC}"
}

# --- Main --------------------------------------------------------------------
main() {
    # Parse arguments
    local WITH_XRAY=false
    for arg in "$@"; do
        case "$arg" in
            --with-xray) WITH_XRAY=true ;;
            --help|-h)
                echo "Usage: $0 [--with-xray]"
                exit 0
                ;;
            *)
                err "Unknown argument: ${arg}"
                exit 1
                ;;
        esac
    done

    mkdir -p "$(dirname "$LOG_FILE")"
    log "===== Psiphon Multi-Region Installer v${VERSION} started ====="

    acquire_lock
    ROOT_CHECK
    SSH_SAFETY_CHECK
    INSTALL_DEPS
    CREATE_USER
    SETUP_DIRS
    DOWNLOAD_PSIPHON
    GEN_PSIPHON_CONFIGS
    SETUP_NETPLAN
    CREATE_SERVICES

    if [[ "$WITH_XRAY" == "true" ]]; then
        DOWNLOAD_XRAY
        GEN_XRAY_CONFIGS
        CREATE_XRAY_SERVICES
        SETUP_UFW
    fi

    START_SERVICES "$WITH_XRAY"
    PRINT_SUMMARY "$WITH_XRAY"

    log "===== Installation finished ====="
}

main "$@"
