#!/usr/bin/env bash
# =============================================================================
#  Psiphon Multi-Instance Installer (Upgrade)            version 3.0.0
#
#  - Safe inbound port discovery over 100 common ports (ss / netstat)
#  - 22 country-locked Psiphon outbounds (one container each, EGRESS_REGION)
#  - SOCKS5 outbounds on 127.0.0.1:1081+ for Xray / 3X-UI / Marzban
#  - Targeted firewall rules only (never resets UFW / iptables)
#  - Health check via ipinfo.io + 24/7 watchdog (cron.d, every 5 minutes)
#  - Unicode box dashboard
#
#  SAFETY GUARANTEES
#   * Never runs `ufw reset`, `iptables -F`, or changes default policies.
#   * Only touches Docker containers whose name starts with "psiphon-".
#   * SSH port(s) and every port currently in LISTEN state are excluded.
#   * Idempotent: re-running is safe.
#
#  USAGE
#   sudo bash install.sh                  # install / upgrade
#   sudo bash install.sh --countries US,DE,NL
#   sudo bash install.sh --scan-only      # phase 1 only, no changes
#   sudo bash install.sh --status         # health check + dashboard only
#   sudo bash install.sh --no-firewall    # skip phase 3
#   sudo bash install.sh --uninstall      # remove only this project
#
#  UPGRADE FROM v2 (psiphon-1..N, public 1081-1090 / 8081-8090)
#   Old cron is disabled first, old psiphon-* containers are replaced,
#   binary in /opt/psiphon-manager/bin is reused. Old UFW rules are left
#   as-is (nothing listens publicly anymore); CLEAN_LEGACY_FW=true removes them.
#
#  ENV OVERRIDES
#   START_PORT=1081  HEALTH_TIMEOUT=150  FORCE_BINARY_UPDATE=true
#   CLEAN_LEGACY_FW=true  PSIPHON_BINARY_URL=...
#   PSIPHON_BINARY_PATH=/path/to/psiphon-tunnel-core (use local binary)
# =============================================================================
set -Eeuo pipefail

# ----------------------------- constants -------------------------------------
readonly VERSION="3.0.0"
readonly APP="psiphon-manager"
readonly PREFIX="psiphon-"
readonly BASE_DIR="/opt/psiphon-manager"
readonly BIN_DIR="${BASE_DIR}/bin"
readonly BUILD_DIR="${BASE_DIR}/build"
readonly DATA_DIR="${BASE_DIR}/data"
readonly CONF_DIR="/etc/psiphon-manager"
readonly STATE_DIR="/var/lib/psiphon-manager"
readonly LEGACY_LIB="/usr/local/lib/psiphon-manager"
readonly LEGACY_NET="psiphon_net"
readonly LOGROTATE_FILE="/etc/logrotate.d/psiphon-manager"
readonly STATE_FILE="${CONF_DIR}/instances.tsv"
readonly FW_PORTS_FILE="${CONF_DIR}/firewall.ports"
readonly FW_MODE_FILE="${CONF_DIR}/firewall.mode"
readonly TEMPLATE_FILE="${CONF_DIR}/config.template.json"
readonly IMAGE="psiphon-local:latest"
readonly WATCHDOG="/usr/local/bin/psiphon-watchdog.sh"
readonly CRON_FILE="/etc/cron.d/psiphon-watchdog"
readonly LOCK_FILE="/run/psiphon-manager-install.lock"
readonly INSTALL_LOG="/var/log/psiphon_installer.log"
readonly WATCHDOG_LOG="/var/log/psiphon_watchdog.log"
readonly FW_COMMENT="psiphon-manager"
readonly CONTAINER_UID="65534"

SOCKS_START="${SOCKS_START:-${START_PORT:-1081}}"   # START_PORT kept for v2 compatibility
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-150}"
PSIPHON_BINARY_URL="${PSIPHON_BINARY_URL:-https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64}"
PSIPHON_BINARY_PATH="${PSIPHON_BINARY_PATH:-}"

MODE="install"
DO_FIREWALL="yes"
FORCE_BINARY="no"
[[ "${FORCE_BINARY_UPDATE:-false}" == "true" ]] && FORCE_BINARY="yes"

# ----------------------------- countries -------------------------------------
COUNTRIES=(US GB CA DE NL FR JP SG AT BE CH ES IT SE NO FI DK PL CZ RO IE AU)

declare -A CNAME=(
  [US]="United States" [GB]="United Kingdom" [CA]="Canada" [DE]="Germany"
  [NL]="Netherlands" [FR]="France" [JP]="Japan" [SG]="Singapore"
  [AT]="Austria" [BE]="Belgium" [CH]="Switzerland" [ES]="Spain"
  [IT]="Italy" [SE]="Sweden" [NO]="Norway" [FI]="Finland"
  [DK]="Denmark" [PL]="Poland" [CZ]="Czechia" [RO]="Romania"
  [IE]="Ireland" [AU]="Australia"
)
declare -A CFLAG=(
  [US]="🇺🇸" [GB]="🇬🇧" [CA]="🇨🇦" [DE]="🇩🇪" [NL]="🇳🇱" [FR]="🇫🇷"
  [JP]="🇯🇵" [SG]="🇸🇬" [AT]="🇦🇹" [BE]="🇧🇪" [CH]="🇨🇭" [ES]="🇪🇸"
  [IT]="🇮🇹" [SE]="🇸🇪" [NO]="🇳🇴" [FI]="🇫🇮" [DK]="🇩🇰" [PL]="🇵🇱"
  [CZ]="🇨🇿" [RO]="🇷🇴" [IE]="🇮🇪" [AU]="🇦🇺"
)

# ------------------ 100 candidate inbound ports (priority order) -------------
CANDIDATE_PORTS=(
  # Cloudflare-proxied HTTPS / HTTP ports
  443 8443 2053 2083 2087 2096 80 8080 8880 2052 2082 2086 2095
  # x443 family
  1443 2443 3443 4443 5443 6443 7443 9443 10443 11443 12443 13443 14443 15443 16443
  # 8xxx web family
  8000 8001 8008 8081 8082 8088 8090 8181 8282 8383 8484 8585 8686 8787 8888 8989
  # 9xxx
  9000 9001 9090 9091 9999
  # 10k-20k
  10000 10001 10080 11000 12000 13000 14000 15000 16000 17000 18000 19000 20000
  # high x443
  20443 21443 22443 23443 24443 25443 26443 27443 28443 29443 30443
  # 30k-50k
  31000 32000 33000 34000 35000 36000 37000 38000 39000 40000
  41000 42000 43000 44000 45000 46000 47000 48000 49000 50000
  # 5x443
  51443 52443 53443 54443 55443 56443 57443
)

# ----------------------------- colors / ui -----------------------------------
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; M=$'\e[35m'; C=$'\e[36m'
  W=$'\e[97m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; M=""; C=""; W=""; DIM=""; BOLD=""; N=""
fi

log()   { printf '%s\n' "$*" >>"$INSTALL_LOG" 2>/dev/null || true; }
info()  { printf '%s[i]%s %s\n' "$C" "$N" "$*"; log "[i] $*"; }
ok()    { printf '%s[✓]%s %s\n' "$G" "$N" "$*"; log "[ok] $*"; }
warn()  { printf '%s[!]%s %s\n' "$Y" "$N" "$*"; log "[warn] $*"; }
err()   { printf '%s[✗]%s %s\n' "$R" "$N" "$*" >&2; log "[err] $*"; }
die()   { err "$*"; exit 1; }
phase() { printf '\n%s%s━━━ %s ━━━%s\n' "$BOLD" "$M" "$*" "$N"; log "=== $* ==="; }

trap 'err "Unexpected error on line ${LINENO} (exit $?). Other services were not modified."' ERR

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ----------------------------- args ------------------------------------------
parse_args() {
  while (($#)); do
    case "$1" in
      --countries)
        [[ -n "${2:-}" ]] || die "--countries needs a value, e.g. US,DE"
        IFS=',' read -r -a COUNTRIES <<<"${2^^}"; shift ;;
      --countries=*) IFS=',' read -r -a COUNTRIES <<<"${1#*=}"; COUNTRIES=("${COUNTRIES[@]^^}") ;;
      --scan-only)     MODE="scan" ;;
      --status)        MODE="status" ;;
      --uninstall)     MODE="uninstall" ;;
      --no-firewall)   DO_FIREWALL="no" ;;
      --update-binary) FORCE_BINARY="yes" ;;
      -h|--help)       usage ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  local cc
  for cc in "${COUNTRIES[@]}"; do
    [[ -n "${CNAME[$cc]:-}" ]] || die "Unsupported country code: $cc"
  done
  [[ "$SOCKS_START" =~ ^[0-9]+$ ]] && ((SOCKS_START > 1024 && SOCKS_START < 65000)) \
    || die "SOCKS_START must be between 1025 and 64999"
}

# ----------------------------- prechecks -------------------------------------
require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo bash install.sh)"; }

acquire_lock() {
  exec 9>"$LOCK_FILE"
  command -v flock >/dev/null 2>&1 && { flock -n 9 || die "Another install.sh run is in progress"; }
}

pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
  elif command -v dnf >/dev/null 2>&1; then dnf install -y -q "$@" >/dev/null
  elif command -v yum >/dev/null 2>&1; then yum install -y -q "$@" >/dev/null
  else die "No supported package manager; install manually: $*"; fi
}

ensure_deps() {
  local missing=()
  command -v curl  >/dev/null 2>&1 || missing+=(curl)
  command -v ss    >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || missing+=(iproute2)
  command -v flock >/dev/null 2>&1 || missing+=(util-linux)
  if [[ ! -d /etc/cron.d ]] || ! { command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; }; then
    if command -v apt-get >/dev/null 2>&1; then missing+=(cron); else missing+=(cronie); fi
  fi
  if ((${#missing[@]})); then
    info "Installing missing packages: ${missing[*]}"
    pkg_install "${missing[@]}"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    info "Docker not found, installing via get.docker.com"
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || die "Docker installation failed"
  fi
  if ! docker info >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
    docker info >/dev/null 2>&1 || die "Docker daemon is not running"
  fi
  systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
  ok "Dependencies ready (docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'))"
}

# ----------------------------- port helpers ----------------------------------
# Every port in LISTEN (tcp) or bound (udp) state, plus Docker-published host ports.
collect_busy_ports() {
  {
    if command -v ss >/dev/null 2>&1; then
      ss -tuln 2>/dev/null | awk 'NR>1 {print $5}'
    elif command -v netstat >/dev/null 2>&1; then
      netstat -tuln 2>/dev/null | awk 'NR>2 {print $4}'
    fi | sed -E 's/.*[:.]([0-9]+)$/\1/'
    if command -v docker >/dev/null 2>&1; then
      docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' \
        | sed -nE 's/.*:([0-9]+)(-([0-9]+))?->.*/\1/p'
    fi
  } | grep -E '^[0-9]+$' | sort -un || true
}

detect_ssh_ports() {
  {
    command -v sshd >/dev/null 2>&1 && sshd -T 2>/dev/null | awk '$1=="port"{print $2}'
    grep -hsE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
      | awk '{print $2}'
    command -v ss >/dev/null 2>&1 && ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/'
    echo 22
  } | grep -E '^[0-9]+$' | sort -un || true
}

in_list() { local needle=$1; shift; local x; for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done; return 1; }

# ----------------------------- project cleanup --------------------------------
project_containers() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${PREFIX}" || true
}

remove_old_containers() {
  local names n
  names=$(project_containers)
  if [[ -z "$names" ]]; then info "No previous ${PREFIX}* containers found"; return; fi
  while read -r n; do
    [[ "$n" == ${PREFIX}* ]] || continue       # hard guard: project prefix only
    docker rm -f "$n" >/dev/null 2>&1 && info "Replaced old container: $n"
  done <<<"$names"
  sleep 2   # let the kernel release the sockets
}

# ----------------------------- v2 migration -----------------------------------
# Stops the old watchdog from resurrecting psiphon-1..N while we upgrade.
migrate_legacy() {
  if [[ -f "$CRON_FILE" ]] && ! grep -q 'managed by install.sh v3' "$CRON_FILE"; then
    rm -f "$CRON_FILE"; info "Disabled legacy watchdog cron"
  fi
  if crontab -l 2>/dev/null | grep -q 'psiphon-watchdog'; then
    crontab -l 2>/dev/null | grep -v 'psiphon-watchdog' | crontab - && info "Removed legacy root crontab line (only psiphon-watchdog)"
  fi
  pkill -f '/usr/local/bin/psiphon-watchdog.sh' 2>/dev/null || true
  [[ -f "${CONF_DIR}/psiphon.env" ]] && mv -f "${CONF_DIR}/psiphon.env" "${CONF_DIR}/psiphon.env.v2.bak" \
    && info "Old settings kept as ${CONF_DIR}/psiphon.env.v2.bak"
  [[ -d "${CONF_DIR}/instances" ]] && rm -rf "${CONF_DIR}/instances"
  [[ -d "$LEGACY_LIB" ]] && rm -rf "$LEGACY_LIB"
  return 0
}

remove_legacy_network() {
  docker network inspect "$LEGACY_NET" >/dev/null 2>&1 || return 0
  if [[ -z "$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$LEGACY_NET" 2>/dev/null | tr -d ' ')" ]]; then
    docker network rm "$LEGACY_NET" >/dev/null 2>&1 && info "Removed unused legacy network ${LEGACY_NET}"
  else
    warn "Network ${LEGACY_NET} still used by other containers; left untouched"
  fi
}

clean_legacy_fw() {
  [[ "${CLEAN_LEGACY_FW:-false}" == "true" ]] || return 0
  command -v ufw >/dev/null 2>&1 || return 0
  local p
  for p in $(seq 1081 1090) $(seq 8081 8090); do
    in_list "$p" "${SSH_PORTS[@]}" && continue
    in_list "$p" "${BUSY_PORTS[@]}" && continue   # something else listens: keep its rule
    ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
  done
  info "Removed v2 public UFW rules for 1081-1090 / 8081-8090 (free ports only)"
}

# =============================================================================
# PHASE 1: Safe inbound port discovery
# =============================================================================
declare -a BUSY_PORTS=() SSH_PORTS=() FREE_INBOUND=() BUSY_IN_LIST=()

phase1_scan() {
  phase "PHASE 1 · Safe Inbound Port Discovery (${#CANDIDATE_PORTS[@]} ports)"
  mapfile -t BUSY_PORTS < <(collect_busy_ports)
  mapfile -t SSH_PORTS  < <(detect_ssh_ports)
  info "SSH port(s) protected: ${SSH_PORTS[*]}"
  info "Ports currently in use on this server: ${#BUSY_PORTS[@]}"

  FREE_INBOUND=(); BUSY_IN_LIST=()
  local p
  for p in "${CANDIDATE_PORTS[@]}"; do
    if in_list "$p" "${SSH_PORTS[@]}" || in_list "$p" "${BUSY_PORTS[@]}"; then
      BUSY_IN_LIST+=("$p")
    else
      FREE_INBOUND+=("$p")
    fi
  done
  if ((${#BUSY_IN_LIST[@]})); then
    warn "Occupied (skipped, untouched): ${BUSY_IN_LIST[*]}"
  fi
  ok "100% free candidate inbound ports: ${#FREE_INBOUND[@]} / ${#CANDIDATE_PORTS[@]}"
  printf '    %sTop picks:%s %s\n' "$DIM" "$N" "${FREE_INBOUND[*]:0:12}"
}

# =============================================================================
# PHASE 2: Build country-locked Psiphon outbounds
# =============================================================================
declare -A SOCKS_OF=() INBOUND_OF=()

write_template() {
  mkdir -p "$CONF_DIR"
  if [[ -s "$TEMPLATE_FILE" ]]; then
    info "Keeping existing config template: $TEMPLATE_FILE"
    return
  fi
  cat >"$TEMPLATE_FILE" <<'JSON'
{
  "LocalSocksProxyPort": __SOCKS_PORT__,
  "LocalHttpProxyPort": 0,
  "DisableLocalHTTPProxy": true,
  "EgressRegion": "__EGRESS_REGION__",
  "DataRootDirectory": "/data",
  "PropagationChannelId": "FFFFFFFFFFFFFFFF",
  "SponsorId": "FFFFFFFFFFFFFFFF",
  "RemoteServerListDownloadFilename": "remote_server_list",
  "RemoteServerListSignaturePublicKey": "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=",
  "RemoteServerListUrl": "https://s3.amazonaws.com//psiphon/web/mjr4-p23r-puwl/server_list_compressed",
  "UseIndistinguishableTLS": true,
  "EmitDiagnosticNotices": false
}
JSON
  ok "Config template written: $TEMPLATE_FILE"
}

fetch_binary() {
  mkdir -p "$BIN_DIR"
  local bin="${BIN_DIR}/psiphon-tunnel-core"
  if [[ -n "$PSIPHON_BINARY_PATH" ]]; then
    [[ -f "$PSIPHON_BINARY_PATH" ]] || die "PSIPHON_BINARY_PATH not found: $PSIPHON_BINARY_PATH"
    install -m 0755 "$PSIPHON_BINARY_PATH" "$bin"
    ok "Using local Psiphon binary"
    return
  fi
  if [[ -x "$bin" && "$FORCE_BINARY" == "no" ]]; then
    info "Psiphon binary already present (use --update-binary to refresh)"
    return
  fi
  case "$(uname -m)" in
    x86_64|amd64) ;;
    aarch64|arm64)
      [[ "$PSIPHON_BINARY_URL" == *x86_64 ]] && PSIPHON_BINARY_URL="${PSIPHON_BINARY_URL%x86_64}arm64"
      warn "arm64 is experimental" ;;
    *) die "Arch $(uname -m) unsupported; set PSIPHON_BINARY_URL or PSIPHON_BINARY_PATH" ;;
  esac
  info "Downloading psiphon-tunnel-core"
  curl -fsSL --retry 3 --max-time 180 -o "${bin}.new" "$PSIPHON_BINARY_URL" || die "Binary download failed"
  if [[ "$(head -c 4 "${bin}.new" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]]; then
    rm -f "${bin}.new"; die "Downloaded file is not a valid ELF binary"
  fi
  chmod 0755 "${bin}.new" && mv -f "${bin}.new" "$bin"
  ok "Psiphon binary installed"
}

build_image() {
  mkdir -p "$BUILD_DIR"
  cp -f "${BIN_DIR}/psiphon-tunnel-core" "${BUILD_DIR}/psiphon-tunnel-core"
  cat >"${BUILD_DIR}/entrypoint.sh" <<'EOS'
#!/bin/sh
set -eu
: "${EGRESS_REGION:?EGRESS_REGION is required}"
: "${SOCKS_PORT:?SOCKS_PORT is required}"
TEMPLATE=/etc/psiphon/config.template.json
[ -r "$TEMPLATE" ] || { echo "missing $TEMPLATE" >&2; exit 1; }
sed -e "s/__EGRESS_REGION__/${EGRESS_REGION}/g" \
    -e "s/__SOCKS_PORT__/${SOCKS_PORT}/g" "$TEMPLATE" > /data/config.json
echo "psiphon: region=${EGRESS_REGION} socks=127.0.0.1:${SOCKS_PORT}"
exec /usr/local/bin/psiphon-tunnel-core -config /data/config.json
EOS
  cat >"${BUILD_DIR}/Dockerfile" <<'EOD'
FROM debian:stable-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY psiphon-tunnel-core /usr/local/bin/psiphon-tunnel-core
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /usr/local/bin/psiphon-tunnel-core /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOD
  local hash
  hash=$(cat "${BUILD_DIR}/Dockerfile" "${BUILD_DIR}/entrypoint.sh" "${BUILD_DIR}/psiphon-tunnel-core" | sha256sum | cut -c1-16)
  if [[ "$(docker image inspect -f '{{index .Config.Labels "psiphon-manager.hash"}}' "$IMAGE" 2>/dev/null || true)" == "$hash" ]]; then
    info "Docker image ${IMAGE} is up to date"
    return
  fi
  info "Building Docker image ${IMAGE}"
  docker build -q --label "psiphon-manager.hash=${hash}" -t "$IMAGE" "$BUILD_DIR" >/dev/null || die "Image build failed"
  ok "Image ${IMAGE} built"
}

allocate_ports() {
  local port=$SOCKS_START cc
  local -a used=()
  for cc in "${COUNTRIES[@]}"; do
    while in_list "$port" "${BUSY_PORTS[@]}" || in_list "$port" "${SSH_PORTS[@]}" \
          || in_list "$port" "${CANDIDATE_PORTS[@]}"; do
      port=$((port + 1))
    done
    SOCKS_OF[$cc]=$port; used+=("$port"); port=$((port + 1))
  done
  local i=0
  for cc in "${COUNTRIES[@]}"; do
    if (( i < ${#FREE_INBOUND[@]} )); then INBOUND_OF[$cc]=${FREE_INBOUND[$i]}; else INBOUND_OF[$cc]="-"; fi
    i=$((i + 1))
  done
}

phase2_deploy() {
  phase "PHASE 2 · Building ${#COUNTRIES[@]} Psiphon Outbounds"
  write_template
  fetch_binary
  build_image
  allocate_ports

  local cc name dir
  : >"${STATE_FILE}.new"
  printf '# cc\tcontainer\tsocks_port\tsuggested_inbound\n' >>"${STATE_FILE}.new"
  for cc in "${COUNTRIES[@]}"; do
    name="${PREFIX}${cc,,}"
    dir="${DATA_DIR}/${cc,,}"
    mkdir -p "$dir" && chown -R "${CONTAINER_UID}:${CONTAINER_UID}" "$dir"
    docker run -d \
      --name "$name" \
      --label "psiphon.manager=1" \
      --label "psiphon.region=${cc}" \
      --restart unless-stopped \
      --network host \
      --user "${CONTAINER_UID}:${CONTAINER_UID}" \
      --cap-drop ALL \
      --security-opt no-new-privileges \
      --memory 256m \
      --log-opt max-size=5m --log-opt max-file=2 \
      -e "EGRESS_REGION=${cc}" \
      -e "SOCKS_PORT=${SOCKS_OF[$cc]}" \
      -v "${dir}:/data" \
      -v "${TEMPLATE_FILE}:/etc/psiphon/config.template.json:ro" \
      "$IMAGE" >/dev/null || { err "Failed to start $name"; continue; }
    printf '%s\t%s\t%s\t%s\n' "$cc" "$name" "${SOCKS_OF[$cc]}" "${INBOUND_OF[$cc]}" >>"${STATE_FILE}.new"
    printf '    %s%-3s%s %s %-15s → socks5://127.0.0.1:%s\n' "$G" "✓" "$N" "${CFLAG[$cc]}" "${CNAME[$cc]}" "${SOCKS_OF[$cc]}"
  done
  mv -f "${STATE_FILE}.new" "$STATE_FILE"
  ok "State saved: $STATE_FILE"
}

# =============================================================================
# PHASE 3: Targeted firewall rules (additive only)
# =============================================================================
fw_mode() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then echo ufw
  elif command -v iptables >/dev/null 2>&1; then echo iptables
  else echo none; fi
}

ipt_allow() {  # $1 = binary (iptables|ip6tables), $2 = port
  "$1" -C INPUT -p tcp --dport "$2" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null \
    || "$1" -I INPUT -p tcp --dport "$2" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null
}

phase3_firewall() {
  phase "PHASE 3 · Targeted Firewall Rules"
  if [[ "$DO_FIREWALL" != "yes" ]]; then warn "Skipped (--no-firewall)"; return; fi
  local mode p added=0
  local -a ports=()
  mode=$(fw_mode)
  for cc in "${COUNTRIES[@]}"; do
    p=${INBOUND_OF[$cc]:-"-"}
    [[ "$p" == "-" ]] && continue
    in_list "$p" "${SSH_PORTS[@]}" && continue   # never touch SSH
    ports+=("$p")
  done
  info "Firewall backend: ${mode}. SOCKS5 ports stay on 127.0.0.1 and are NOT opened."
  case "$mode" in
    ufw)
      for p in "${ports[@]}"; do
        ufw allow "${p}/tcp" comment "$FW_COMMENT" >/dev/null 2>&1 && added=$((added + 1))
      done ;;
    iptables)
      for p in "${ports[@]}"; do
        ipt_allow iptables "$p" && added=$((added + 1))
        command -v ip6tables >/dev/null 2>&1 && ipt_allow ip6tables "$p" || true
      done ;;
    none) warn "No UFW/iptables found; nothing to do" ;;
  esac
  echo "$mode" >"$FW_MODE_FILE"
  { [[ -s "$FW_PORTS_FILE" ]] && cat "$FW_PORTS_FILE"; printf '%s\n' "${ports[@]}"; } \
    | grep -E '^[0-9]+$' | sort -un >"${FW_PORTS_FILE}.new" || true
  mv -f "${FW_PORTS_FILE}.new" "$FW_PORTS_FILE"
  ok "Ensured ${added} inbound rule(s) (existing rules untouched): ${ports[*]:-none}"
}

# =============================================================================
# PHASE 4: Health check + watchdog
# =============================================================================
declare -A EXIT_IP=() EXIT_CC=() HEALTH=()

load_state() {
  [[ -r "$STATE_FILE" ]] || die "No state file found; run install first"
  COUNTRIES=()
  local cc name socks inbound
  while IFS=$'\t' read -r cc name socks inbound; do
    [[ -z "$cc" || "$cc" == \#* ]] && continue
    COUNTRIES+=("$cc"); SOCKS_OF[$cc]=$socks; INBOUND_OF[$cc]=$inbound
  done <"$STATE_FILE"
}

probe() {  # $1 cc, $2 port, $3 outdir
  local body ip country
  body=$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:$2" https://ipinfo.io/json 2>/dev/null || true)
  ip=$(sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$body" | head -n1)
  country=$(sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$body" | head -n1)
  [[ -n "$ip" ]] && printf '%s\t%s\n' "$ip" "$country" >"$3/$1"
}

phase4_health() {
  phase "PHASE 4 · Health Check (ipinfo.io via each SOCKS5)"
  local tmp cc deadline
  tmp=$(mktemp -d)
  deadline=$((SECONDS + HEALTH_TIMEOUT))
  local -a pending=("${COUNTRIES[@]}")
  info "Waiting for tunnels to establish (max ${HEALTH_TIMEOUT}s)"
  while ((${#pending[@]})) && ((SECONDS < deadline)); do
    for cc in "${pending[@]}"; do probe "$cc" "${SOCKS_OF[$cc]}" "$tmp" & done
    wait
    local -a still=()
    for cc in "${pending[@]}"; do [[ -s "$tmp/$cc" ]] || still+=("$cc"); done
    pending=("${still[@]}")
    printf '\r    %sconnected: %d/%d  (%ds)%s ' "$DIM" $(( ${#COUNTRIES[@]} - ${#pending[@]} )) "${#COUNTRIES[@]}" "$SECONDS" "$N"
    ((${#pending[@]})) && sleep 8
  done
  echo
  for cc in "${COUNTRIES[@]}"; do
    if [[ -s "$tmp/$cc" ]]; then
      IFS=$'\t' read -r EXIT_IP[$cc] EXIT_CC[$cc] <"$tmp/$cc"
      HEALTH[$cc]="HEALTHY"
    else
      EXIT_IP[$cc]="-"; EXIT_CC[$cc]=""; HEALTH[$cc]="FAILED"
    fi
  done
  rm -rf "$tmp"
}

install_watchdog() {
  cat >"${WATCHDOG}.new" <<'WD'
#!/usr/bin/env bash
# Psiphon Multi-Instance watchdog (managed by install.sh). Touches only psiphon-* containers.
set -uo pipefail
STATE=/etc/psiphon-manager/instances.tsv
FW_MODE_FILE=/etc/psiphon-manager/firewall.mode
FW_PORTS_FILE=/etc/psiphon-manager/firewall.ports
FAILDIR=/var/lib/psiphon-manager/health
LOG=/var/log/psiphon_watchdog.log
MAX_FAILS=2
CHECK_URL="https://www.cloudflare.com/cdn-cgi/trace"

mkdir -p "$FAILDIR"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
if [[ -f "$LOG" ]] && (( $(stat -c %s "$LOG" 2>/dev/null || echo 0) > 1048576 )); then
  tail -n 2000 "$LOG" >"${LOG}.tmp" && mv -f "${LOG}.tmp" "$LOG"
fi
[[ -r "$STATE" ]] || exit 0
command -v docker >/dev/null 2>&1 || exit 0
if ! docker info >/dev/null 2>&1; then
  systemctl restart docker >/dev/null 2>&1 && log "docker daemon was down -> restarted"
  sleep 10
fi

if [[ "${1:-}" == "--status" ]]; then
  printf '%-4s %-14s %-7s %-8s %-9s %-40s %-8s %s\n' "#" "CONTAINER" "REGION" "SOCKS5" "INBOUND" "EXIT IP" "COUNTRY" "HEALTH"
  i=0
  while IFS=$'\t' read -r cc name socks inbound; do
    [[ -z "${cc:-}" || "$cc" == \#* ]] && continue
    i=$((i + 1))
    body=$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:${socks}" https://ipinfo.io/json 2>/dev/null || true)
    ip=$(sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$body" | head -n1)
    co=$(sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$body" | head -n1)
    if [[ -n "$ip" ]]; then h=$'\e[32mHEALTHY\e[0m'; else h=$'\e[31mFAILED\e[0m'; ip="-"; co="-"; fi
    printf '%-4s %-14s %-7s %-8s %-9s %-40s %-8s %s\n' "$i" "$name" "$cc" "$socks" "$inbound" "$ip" "$co" "$h"
  done <"$STATE"
  exit 0
fi

check_one() {
  local name=$1 socks=$2 f="$FAILDIR/$1.fails" running fails
  running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo missing)
  if [[ "$running" == "missing" ]]; then log "$name missing; re-run install.sh to recreate"; return; fi
  if [[ "$running" != "true" ]]; then
    docker start "$name" >/dev/null 2>&1 && log "$name was stopped -> started"
    echo 0 >"$f"; return
  fi
  if curl -s -o /dev/null --max-time 20 --socks5-hostname "127.0.0.1:${socks}" "$CHECK_URL"; then
    echo 0 >"$f"
  else
    fails=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
    echo "$fails" >"$f"
    log "$name socks5 127.0.0.1:${socks} failed (${fails}/${MAX_FAILS})"
    if (( fails >= MAX_FAILS )); then
      docker restart -t 5 "$name" >/dev/null 2>&1 && log "$name restarted"
      echo 0 >"$f"
    fi
  fi
}

while IFS=$'\t' read -r cc name socks _; do
  [[ -z "${cc:-}" || "$cc" == \#* ]] && continue
  [[ "$name" == psiphon-* ]] || continue
  check_one "$name" "$socks" &
done <"$STATE"
wait

# Re-ensure iptables ACCEPT rules after reboot (additive, never flushes anything)
if [[ "$(cat "$FW_MODE_FILE" 2>/dev/null)" == "iptables" && -r "$FW_PORTS_FILE" ]]; then
  while read -r p; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    for t in iptables ip6tables; do
      command -v "$t" >/dev/null 2>&1 || continue
      "$t" -C INPUT -p tcp --dport "$p" -m comment --comment psiphon-manager -j ACCEPT 2>/dev/null \
        || "$t" -I INPUT -p tcp --dport "$p" -m comment --comment psiphon-manager -j ACCEPT 2>/dev/null || true
    done
  done <"$FW_PORTS_FILE"
fi
exit 0
WD
  chmod 0755 "${WATCHDOG}.new" && mv -f "${WATCHDOG}.new" "$WATCHDOG"

  # Remove only our own legacy line from root's crontab (older versions used it).
  if crontab -l 2>/dev/null | grep -q 'psiphon-watchdog'; then
    crontab -l 2>/dev/null | grep -v 'psiphon-watchdog' | crontab - && info "Migrated legacy crontab entry to ${CRON_FILE}"
  fi
  cat >"$CRON_FILE" <<CRON
# Psiphon Multi-Instance watchdog (managed by install.sh v3)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root flock -n /run/psiphon-watchdog.lock ${WATCHDOG} >/dev/null 2>&1
@reboot root sleep 90 && flock -n /run/psiphon-watchdog.lock ${WATCHDOG} >/dev/null 2>&1
CRON
  chmod 0644 "$CRON_FILE"
  cat >"$LOGROTATE_FILE" <<LR
${INSTALL_LOG} ${WATCHDOG_LOG} {
  weekly
  rotate 4
  compress
  missingok
  notifempty
  copytruncate
}
LR
  ok "Watchdog installed: ${WATCHDOG} (every 5 min via ${CRON_FILE})"
}

# =============================================================================
# PHASE 5: Dashboard
# =============================================================================
readonly -a COLW=(3 20 6 8 9 17 9)
readonly -a HEAD=("#" "Country" "Region" "SOCKS5" "Inbound" "Exit IP" "Status")

hline() {  # $1 left  $2 mid  $3 right
  local i out="$1"
  for i in "${!COLW[@]}"; do
    out+=$(printf '─%.0s' $(seq 1 $(( COLW[i] + 2 ))))
    (( i < ${#COLW[@]} - 1 )) && out+="$2"
  done
  printf '%s%s%s%s\n' "$B" "$out" "$3" "$N"
}
cell() {  # $1 text  $2 width  $3 color
  local t=$1
  (( ${#t} > $2 )) && t="${t:0:$(( $2 - 1 ))}…"
  printf '%s│%s %s%-*s%s ' "$B" "$N" "${3:-}" "$2" "$t" "$N"
}

phase5_dashboard() {
  local total=${#COUNTRIES[@]} healthy=0 cc i=0 ipcol stcol
  for cc in "${COUNTRIES[@]}"; do [[ "${HEALTH[$cc]}" == "HEALTHY" ]] && healthy=$((healthy + 1)); done

  printf '\n%s%s  PSIPHON MULTI-INSTANCE v%s · DASHBOARD%s   %shealthy %d/%d%s\n' \
    "$BOLD" "$W" "$VERSION" "$N" "$( ((healthy == total)) && echo "$G" || echo "$Y")" "$healthy" "$total" "$N"
  hline "┌" "┬" "┐"
  for i in "${!HEAD[@]}"; do cell "${HEAD[$i]}" "${COLW[$i]}" "$BOLD$W"; done
  printf '%s│%s\n' "$B" "$N"
  hline "├" "┼" "┤"
  i=0
  for cc in "${COUNTRIES[@]}"; do
    i=$((i + 1))
    if [[ "${HEALTH[$cc]}" == "HEALTHY" ]]; then
      stcol="$G"; ipcol="$W"
      [[ -n "${EXIT_CC[$cc]}" && "${EXIT_CC[$cc]}" != "$cc" ]] && ipcol="$Y"
    else
      stcol="$R"; ipcol="$DIM"
    fi
    cell "$i" "${COLW[0]}" "$DIM"
    # flag renders 2 columns wide: print it outside printf padding
    printf '%s│%s %s %-*s ' "$B" "$N" "${CFLAG[$cc]}" $(( COLW[1] - 3 )) "${CNAME[$cc]}"
    cell "$cc" "${COLW[2]}" "$C"
    cell "${SOCKS_OF[$cc]}" "${COLW[3]}" "$M"
    cell "${INBOUND_OF[$cc]}" "${COLW[4]}" "$Y"
    cell "${EXIT_IP[$cc]}" "${COLW[5]}" "$ipcol"
    cell "${HEALTH[$cc]}" "${COLW[6]}" "$BOLD$stcol"
    printf '%s│%s\n' "$B" "$N"
  done
  hline "└" "┴" "┘"

  local first=${COUNTRIES[0]}
  printf '%sXray/3X-UI outbound example:%s\n' "$DIM" "$N"
  printf '  {"tag":"psiphon-%s","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":%s}]}}\n' \
    "${first,,}" "${SOCKS_OF[$first]}"
  printf '%sState:%s %s   %sWatchdog log:%s %s   %sLive status:%s psiphon-watchdog.sh --status\n' "$DIM" "$N" "$STATE_FILE" "$DIM" "$N" "$WATCHDOG_LOG" "$DIM" "$N"
  printf '%sYellow exit IP = Psiphon exited from a different country than requested.%s\n\n' "$DIM" "$N"
}

# =============================================================================
# Uninstall (project-only)
# =============================================================================
do_uninstall() {
  phase "UNINSTALL · removing only Psiphon Multi-Instance components"
  rm -f "$CRON_FILE"
  pkill -f "$WATCHDOG" 2>/dev/null || true
  remove_old_containers
  remove_legacy_network
  rm -f "$WATCHDOG"
  if crontab -l 2>/dev/null | grep -q 'psiphon-watchdog'; then
    crontab -l 2>/dev/null | grep -v 'psiphon-watchdog' | crontab - || true
  fi
  local mode p
  mode=$(cat "$FW_MODE_FILE" 2>/dev/null || echo none)
  if [[ -r "$FW_PORTS_FILE" ]]; then
    while read -r p; do
      [[ "$p" =~ ^[0-9]+$ ]] || continue
      case "$mode" in
        ufw) ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true ;;
        iptables)
          for t in iptables ip6tables; do
            command -v "$t" >/dev/null 2>&1 || continue
            while "$t" -D INPUT -p tcp --dport "$p" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null; do :; done
          done ;;
      esac
    done <"$FW_PORTS_FILE"
    info "Removed only the firewall rules this project added"
  fi
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$BASE_DIR" "$CONF_DIR" "$STATE_DIR" "$LEGACY_LIB"
  rm -f "$LOGROTATE_FILE"
  ok "Uninstalled. No other container, service, or firewall rule was touched."
}

# =============================================================================
main() {
  parse_args "$@"
  require_root
  mkdir -p "$(dirname "$INSTALL_LOG")"; log "---- $(date '+%F %T') install.sh v${VERSION} mode=${MODE}"
  acquire_lock
  printf '%s%s\n  Psiphon Multi-Instance Installer v%s%s\n' "$BOLD" "$C" "$VERSION" "$N"

  case "$MODE" in
    scan)
      phase1_scan ;;
    status)
      command -v docker >/dev/null 2>&1 || die "Docker not installed"
      load_state
      phase4_health
      phase5_dashboard ;;
    uninstall)
      command -v docker >/dev/null 2>&1 || die "Docker not installed"
      do_uninstall ;;
    install)
      ensure_deps
      mkdir -p "$BASE_DIR" "$CONF_DIR" "$DATA_DIR" "$STATE_DIR"
      phase "PHASE 0 · Upgrade: replacing previous ${PREFIX}* containers only"
      migrate_legacy
      remove_old_containers
      remove_legacy_network
      phase1_scan
      clean_legacy_fw
      phase2_deploy
      phase3_firewall
      phase4_health
      install_watchdog
      phase5_dashboard ;;
  esac
}

main "$@"
