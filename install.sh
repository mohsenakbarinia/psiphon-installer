#!/usr/bin/env bash
# =============================================================================
#  MAXNET6G MANAGER · Psiphon Multi-Instance Interactive CLI  (v4.0.0)
#  Developer: mohsenakbarinia
#
#  sudo bash install.sh            -> interactive menu (also installs `maxnet`)
#  maxnet                          -> open the menu from anywhere
#  maxnet --install | --update | --status | --uninstall   (non-interactive)
#
#  SAFETY GUARANTEES
#   * Never runs `ufw reset`, `iptables -F`, or changes default firewall policies.
#   * Only touches Docker containers whose name starts with "psiphon-".
#   * SOCKS5 ports are fixed: US=1081 ... AU=1102 (bound to 127.0.0.1 only).
#   * Smart Update never moves ports and never restarts healthy containers.
#
#  ENV OVERRIDES
#   HEALTH_TIMEOUT=150  PSIPHON_BINARY_URL=...  PSIPHON_BINARY_PATH=/local/bin
# =============================================================================
set -uo pipefail

# ----------------------------- locale (for box widths) -----------------------
_loc=$(locale -a 2>/dev/null | grep -iE '^(c|en_us)\.utf-?8$' | head -n1)
[[ -n "$_loc" ]] && export LC_ALL="$_loc"
unset _loc

# ----------------------------- constants -------------------------------------
readonly VERSION="4.0.0"
readonly BRAND="MAXNET6G"
readonly PREFIX="psiphon-"
readonly BASE_DIR="/var/lib/psiphon-multi"
readonly BIN_DIR="${BASE_DIR}/bin"
readonly BUILD_DIR="${BASE_DIR}/build"
readonly DATA_DIR="${BASE_DIR}/data"
readonly HEALTH_DIR="${BASE_DIR}/health"
readonly STATE_FILE="${BASE_DIR}/instances.tsv"
readonly TEMPLATE_FILE="${BASE_DIR}/config.template.json"
readonly FW_PORTS_FILE="${BASE_DIR}/firewall.ports"
readonly FW_MODE_FILE="${BASE_DIR}/firewall.mode"
readonly IMAGE="psiphon-local:latest"
readonly CLI_PATH="/usr/local/bin/maxnet"
readonly WATCHDOG="/usr/local/bin/psiphon-watchdog.sh"
readonly CRON_FILE="/etc/cron.d/psiphon-watchdog"
readonly LOGROTATE_FILE="/etc/logrotate.d/psiphon-multi"
readonly LOCK_FILE="/run/maxnet.lock"
readonly INSTALL_LOG="/var/log/maxnet.log"
readonly WATCHDOG_LOG="/var/log/psiphon_watchdog.log"
readonly FW_COMMENT="maxnet-psiphon"
readonly CONTAINER_UID="65534"
readonly SOCKS_BASE=1081
# previous project versions (cleaned on install/uninstall, binary reused)
readonly LEGACY_DIRS=(/opt/psiphon-manager /etc/psiphon-manager /var/lib/psiphon-manager /usr/local/lib/psiphon-manager)
readonly LEGACY_BIN="/opt/psiphon-manager/bin/psiphon-tunnel-core"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-150}"
PSIPHON_BINARY_URL="${PSIPHON_BINARY_URL:-https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64}"
PSIPHON_BINARY_PATH="${PSIPHON_BINARY_PATH:-}"

# ----------------------------- countries (order = fixed SOCKS port) ----------
readonly COUNTRIES=(US GB CA DE NL FR JP SG AT BE CH ES IT SE NO FI DK PL CZ RO IE AU)
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
declare -A SOCKS_OF=()
for _i in "${!COUNTRIES[@]}"; do SOCKS_OF[${COUNTRIES[$_i]}]=$((SOCKS_BASE + _i)); done
unset _i

# ------------------ 100 candidate inbound ports (priority order) -------------
readonly CANDIDATE_PORTS=(
  443 8443 2053 2083 2087 2096 80 8080 8880 2052 2082 2086 2095
  1443 2443 3443 4443 5443 6443 7443 9443 10443 11443 12443 13443 14443 15443 16443
  8000 8001 8008 8081 8082 8088 8090 8181 8282 8383 8484 8585 8686 8787 8888 8989
  9000 9001 9090 9091 9999
  10000 10001 10080 11000 12000 13000 14000 15000 16000 17000 18000 19000 20000
  20443 21443 22443 23443 24443 25443 26443 27443 28443 29443 30443
  31000 32000 33000 34000 35000 36000 37000 38000 39000 40000
  41000 42000 43000 44000 45000 46000 47000 48000 49000 50000
  51443 52443 53443 54443 55443 56443 57443
)

# ----------------------------- colors / ui -----------------------------------
RED=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; C=$'\033[1;36m'
W=$'\033[1;97m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; N=$'\033[0m'

log()   { { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$INSTALL_LOG"; } 2>/dev/null || true; }
info()  { printf '%s[i]%s %s\n' "$C" "$N" "$*"; log "[i] $*"; }
ok()    { printf '%s[✓]%s %s\n' "$G" "$N" "$*"; log "[ok] $*"; }
warn()  { printf '%s[!]%s %s\n' "$Y" "$N" "$*"; log "[warn] $*"; }
err()   { printf '%s[✗]%s %s\n' "$RED" "$N" "$*" >&2; log "[err] $*"; }

dwidth() { printf '%s' "$1" | wc -L; }            # terminal display width
repeat() { local i s=""; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf '%s' "$s"; }

readonly BOX_W=58                                   # inner width of menu boxes
box_top()  { printf '%s┌%s┐%s\n' "$RED" "$(repeat '─' "$BOX_W")" "$N"; }
box_mid()  { printf '%s├%s┤%s\n' "$RED" "$(repeat '─' "$BOX_W")" "$N"; }
box_bot()  { printf '%s└%s┘%s\n' "$RED" "$(repeat '─' "$BOX_W")" "$N"; }
box_row()  { # $1 text  $2 color  $3 center(yes/no)
  local t=$1 col=${2:-} w pad l r
  w=$(dwidth "$t"); pad=$(( BOX_W - 2 - w )); ((pad < 0)) && pad=0
  if [[ "${3:-no}" == "yes" ]]; then l=$((pad / 2)); r=$((pad - l)); else l=0; r=$pad; fi
  printf '%s│%s %*s%s%s%s%*s %s│%s\n' "$RED" "$N" "$l" "" "$col" "$t" "$N" "$r" "" "$RED" "$N"
}
title() { echo; box_top; box_row "$1" "$W" yes; box_bot; }

print_logo() {
  printf '%s' "$RED"
  cat <<'LOGO'

 ███╗   ███╗ █████╗ ██╗  ██╗███╗   ██╗███████╗████████╗ ██████╗  ██████╗ 
 ████╗ ████║██╔══██╗╚██╗██╔╝████╗  ██║██╔════╝╚══██╔══╝██╔════╝ ██╔════╝ 
 ██╔████╔██║███████║ ╚███╔╝ ██╔██╗ ██║█████╗     ██║   ███████╗ ██║  ███╗
 ██║╚██╔╝██║██╔══██║ ██╔██╗ ██║╚██╗██║██╔══╝     ██║   ██╔═══██╗██║   ██║
 ██║ ╚═╝ ██║██║  ██║██╔╝ ██╗██║ ╚████║███████╗   ██║   ╚██████╔╝╚██████╔╝
 ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝  ╚═════╝ 
LOGO
  printf '             ━━━━━━━━  Developer: mohsenakbarinia  ━━━━━━━━\n%s\n' "$N"
}

ask() { local __v; read -r -p "$1" __v </dev/tty || __v=""; printf '%s' "$__v"; }
pause() { [[ -t 0 || -r /dev/tty ]] && read -r -p "  ${DIM}Press Enter to return to menu...${N}" _ </dev/tty; }

in_list() { local n=$1; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }

# ----------------------------- prechecks -------------------------------------
require_root() { [[ $EUID -eq 0 ]] || { err "Run as root: sudo bash install.sh"; exit 1; }; }

with_lock() {  # run "$@" under an exclusive lock
  (
    exec 9>"$LOCK_FILE"
    if command -v flock >/dev/null 2>&1 && ! flock -n 9; then err "Another maxnet operation is running"; exit 1; fi
    "$@"
  )
}

pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then dnf install -y -q "$@" >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then yum install -y -q "$@" >/dev/null 2>&1
  else return 1; fi
}

ensure_deps() {
  local missing=()
  command -v curl  >/dev/null 2>&1 || missing+=(curl)
  command -v ss    >/dev/null 2>&1 || missing+=(iproute2)
  command -v flock >/dev/null 2>&1 || missing+=(util-linux)
  if ! { command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; }; then
    if command -v apt-get >/dev/null 2>&1; then missing+=(cron); else missing+=(cronie); fi
  fi
  if ((${#missing[@]})); then
    info "Installing missing packages: ${missing[*]}"
    pkg_install "${missing[@]}" || { err "Could not install: ${missing[*]}"; return 1; }
  fi
  if ! command -v docker >/dev/null 2>&1; then
    info "Docker not found, installing via get.docker.com"
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || { err "Docker installation failed"; return 1; }
  fi
  if ! docker info >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
    docker info >/dev/null 2>&1 || { err "Docker daemon is not running"; return 1; }
  fi
  systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
  ok "Dependencies ready (docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'))"
}

# ----------------------------- `maxnet` command -------------------------------
install_cli() {
  local src
  src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")
  [[ "$src" == "$CLI_PATH" ]] && return 0
  if [[ -n "$src" && -f "$src" ]]; then
    if ! cmp -s "$src" "$CLI_PATH" 2>/dev/null; then
      install -m 0755 "$src" "${CLI_PATH}.new" && mv -f "${CLI_PATH}.new" "$CLI_PATH" \
        && ok "Command installed: type ${BOLD}maxnet${N} anywhere to open this menu"
    fi
  elif [[ ! -x "$CLI_PATH" ]]; then
    warn "Script is running from a pipe; save it as install.sh and run it once to create 'maxnet'"
  fi
}

# ----------------------------- port helpers ----------------------------------
declare -a BUSY_PORTS=() SSH_PORTS=()

collect_busy_ports() {
  {
    ss -tuln 2>/dev/null | awk 'NR>1 {print $5}' | sed -E 's/.*[:.]([0-9]+)$/\1/'
    docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' | sed -nE 's/.*:([0-9]+)(-[0-9]+)?->.*/\1/p'
  } | grep -E '^[0-9]+$' | sort -un || true
}

detect_ssh_ports() {
  {
    command -v sshd >/dev/null 2>&1 && sshd -T 2>/dev/null | awk '$1=="port"{print $2}'
    grep -hsE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}'
    ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/'
    echo 22
  } | grep -E '^[0-9]+$' | sort -un || true
}

refresh_ports() {
  mapfile -t BUSY_PORTS < <(collect_busy_ports)
  mapfile -t SSH_PORTS  < <(detect_ssh_ports)
}

port_free() { ! in_list "$1" "${BUSY_PORTS[@]}" && ! in_list "$1" "${SSH_PORTS[@]}"; }

# ----------------------------- state -----------------------------------------
declare -A INBOUND_OF=() IN_STATE=()

load_state() {
  INBOUND_OF=(); IN_STATE=()
  [[ -r "$STATE_FILE" ]] || return 1
  local cc name socks inbound
  while IFS=$'\t' read -r cc name socks inbound; do
    [[ -z "${cc:-}" || "$cc" == \#* ]] && continue
    [[ -n "${CNAME[$cc]:-}" ]] || continue
    IN_STATE[$cc]=1; INBOUND_OF[$cc]="${inbound:--}"
  done <"$STATE_FILE"
  return 0
}

save_state() {
  local cc
  mkdir -p "$BASE_DIR"
  {
    printf '# cc\tcontainer\tsocks_port(fixed)\tinbound_port\n'
    for cc in "${COUNTRIES[@]}"; do
      [[ -n "${IN_STATE[$cc]:-}" ]] || continue
      printf '%s\t%s%s\t%s\t%s\n' "$cc" "$PREFIX" "${cc,,}" "${SOCKS_OF[$cc]}" "${INBOUND_OF[$cc]:--}"
    done
  } >"${STATE_FILE}.new" && mv -f "${STATE_FILE}.new" "$STATE_FILE"
}

next_free_inbound() {  # prints next free candidate not already assigned
  local p cc used=()
  for cc in "${!INBOUND_OF[@]}"; do used+=("${INBOUND_OF[$cc]}"); done
  for p in "${CANDIDATE_PORTS[@]}"; do
    port_free "$p" || continue
    in_list "$p" "${used[@]}" && continue
    printf '%s' "$p"; return 0
  done
  printf '%s' "-"
}

# ----------------------------- psiphon core ----------------------------------
write_template() {
  mkdir -p "$BASE_DIR"
  [[ -s "$TEMPLATE_FILE" ]] && return 0
  if [[ -s /etc/psiphon-manager/config.template.json ]]; then
    cp -f /etc/psiphon-manager/config.template.json "$TEMPLATE_FILE"; info "Reused previous config template"; return 0
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
  ok "Config template written"
}

fetch_binary() {  # $1 = force (yes/no)
  local force=${1:-no} bin="${BIN_DIR}/psiphon-tunnel-core" url=$PSIPHON_BINARY_URL
  mkdir -p "$BIN_DIR"
  if [[ -n "$PSIPHON_BINARY_PATH" ]]; then
    [[ -f "$PSIPHON_BINARY_PATH" ]] || { err "PSIPHON_BINARY_PATH not found"; return 1; }
    install -m 0755 "$PSIPHON_BINARY_PATH" "$bin"; ok "Using local Psiphon binary"; return 0
  fi
  if [[ "$force" == "no" && -x "$bin" ]]; then info "Psiphon core already present"; return 0; fi
  if [[ "$force" == "no" && -x "$LEGACY_BIN" ]]; then
    install -m 0755 "$LEGACY_BIN" "$bin"; info "Reused Psiphon core from previous version"; return 0
  fi
  case "$(uname -m)" in
    x86_64|amd64) ;;
    aarch64|arm64) [[ "$url" == *x86_64 ]] && url="${url%x86_64}arm64"; warn "arm64 is experimental" ;;
    *) err "Arch $(uname -m) unsupported; set PSIPHON_BINARY_URL or PSIPHON_BINARY_PATH"; return 1 ;;
  esac
  info "Downloading latest psiphon-tunnel-core"
  if ! curl -fsSL --retry 3 --max-time 180 -o "${bin}.new" "$url"; then
    rm -f "${bin}.new"
    if [[ -x "$bin" ]]; then warn "Download failed; keeping current core"; return 0; fi
    err "Binary download failed"; return 1
  fi
  if [[ "$(head -c 4 "${bin}.new" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]]; then
    rm -f "${bin}.new"; err "Downloaded file is not a valid ELF binary"
    [[ -x "$bin" ]] && return 0 || return 1
  fi
  if [[ -x "$bin" ]] && cmp -s "${bin}.new" "$bin"; then
    rm -f "${bin}.new"; ok "Psiphon core is already the latest"; return 0
  fi
  chmod 0755 "${bin}.new" && mv -f "${bin}.new" "$bin"
  ok "Psiphon core updated"
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
  if [[ "$(docker image inspect -f '{{index .Config.Labels "maxnet.hash"}}' "$IMAGE" 2>/dev/null || true)" == "$hash" ]]; then
    info "Docker image is up to date"; return 0
  fi
  info "Building Docker image ${IMAGE}"
  docker build -q --label "maxnet.hash=${hash}" -t "$IMAGE" "$BUILD_DIR" >/dev/null 2>&1 || { err "Image build failed"; return 1; }
  ok "Image built"
}

run_container() {  # $1 = cc
  local cc=$1 name="${PREFIX}${1,,}" dir="${DATA_DIR}/${1,,}"
  [[ "$name" == ${PREFIX}* ]] || return 1
  mkdir -p "$dir" && chown -R "${CONTAINER_UID}:${CONTAINER_UID}" "$dir"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d \
    --name "$name" \
    --label "psiphon.manager=maxnet" \
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
    "$IMAGE" >/dev/null 2>&1
}

remove_project_containers() {
  local n
  while read -r n; do
    [[ -n "$n" && "$n" == ${PREFIX}* ]] || continue       # hard guard: project prefix only
    docker rm -f "$n" >/dev/null 2>&1 && info "Removed container: $n"
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${PREFIX}" || true)
  sleep 2
}

container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

# ----------------------------- firewall (additive only) -----------------------
fw_mode() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then echo ufw
  elif command -v iptables >/dev/null 2>&1; then echo iptables
  else echo none; fi
}

ipt_allow() {
  "$1" -C INPUT -p tcp --dport "$2" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null \
    || "$1" -I INPUT -p tcp --dport "$2" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null
}

fw_open_ports() {  # "$@" = ports; opens each one individually, never resets anything
  local mode p added=0
  mode=$(fw_mode)
  (($#)) || return 0
  for p in "$@"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    in_list "$p" "${SSH_PORTS[@]}" && continue
    case "$mode" in
      ufw) ufw allow "${p}/tcp" comment "$FW_COMMENT" >/dev/null 2>&1 && added=$((added + 1)) ;;
      iptables)
        ipt_allow iptables "$p" && added=$((added + 1))
        command -v ip6tables >/dev/null 2>&1 && { ipt_allow ip6tables "$p" || true; } ;;
    esac
    echo "$p" >>"$FW_PORTS_FILE"
  done
  sort -un "$FW_PORTS_FILE" -o "$FW_PORTS_FILE" 2>/dev/null || true
  echo "$mode" >"$FW_MODE_FILE"
  case "$mode" in
    none) warn "No active UFW/iptables found; firewall untouched" ;;
    *)    ok "Firewall (${mode}): ensured ${added} inbound rule(s) one-by-one. SOCKS5 stays on 127.0.0.1 (not exposed)" ;;
  esac
}

# ----------------------------- watchdog --------------------------------------
install_watchdog() {
  cat >"${WATCHDOG}.new" <<'WD'
#!/usr/bin/env bash
# MAXNET6G · Psiphon Multi-Instance watchdog (managed by maxnet). Touches only psiphon-* containers.
set -uo pipefail
BASE=/var/lib/psiphon-multi
STATE=$BASE/instances.tsv
TEMPLATE=$BASE/config.template.json
FAILDIR=$BASE/health
FW_MODE_FILE=$BASE/firewall.mode
FW_PORTS_FILE=$BASE/firewall.ports
IMAGE=psiphon-local:latest
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

recreate() {  # $1 cc  $2 name  $3 socks
  local cc=$1 name=$2 socks=$3 dir="$BASE/data/${1,,}"
  [[ "$name" == psiphon-* ]] || return 1
  docker image inspect "$IMAGE" >/dev/null 2>&1 || { log "$name missing and image missing; run: maxnet"; return 1; }
  mkdir -p "$dir" && chown -R 65534:65534 "$dir"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --label psiphon.manager=maxnet --label "psiphon.region=${cc}" \
    --restart unless-stopped --network host --user 65534:65534 --cap-drop ALL \
    --security-opt no-new-privileges --memory 256m --log-opt max-size=5m --log-opt max-file=2 \
    -e "EGRESS_REGION=${cc}" -e "SOCKS_PORT=${socks}" -v "${dir}:/data" \
    -v "${TEMPLATE}:/etc/psiphon/config.template.json:ro" "$IMAGE" >/dev/null 2>&1 \
    && log "$name was missing -> recreated on 127.0.0.1:${socks}"
}

check_one() {
  local cc=$1 name=$2 socks=$3 f="$FAILDIR/$2.fails" running fails
  running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo missing)
  if [[ "$running" == "missing" ]]; then recreate "$cc" "$name" "$socks"; echo 0 >"$f"; return; fi
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
  check_one "$cc" "$name" "$socks" &
done <"$STATE"
wait

# Re-ensure our iptables ACCEPT rules after reboot (additive, never flushes anything)
if [[ "$(cat "$FW_MODE_FILE" 2>/dev/null)" == "iptables" && -r "$FW_PORTS_FILE" ]]; then
  while read -r p; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    for t in iptables ip6tables; do
      command -v "$t" >/dev/null 2>&1 || continue
      "$t" -C INPUT -p tcp --dport "$p" -m comment --comment maxnet-psiphon -j ACCEPT 2>/dev/null \
        || "$t" -I INPUT -p tcp --dport "$p" -m comment --comment maxnet-psiphon -j ACCEPT 2>/dev/null || true
    done
  done <"$FW_PORTS_FILE"
fi
exit 0
WD
  chmod 0755 "${WATCHDOG}.new" && mv -f "${WATCHDOG}.new" "$WATCHDOG"
  if crontab -l 2>/dev/null | grep -q 'psiphon-watchdog'; then
    crontab -l 2>/dev/null | grep -v 'psiphon-watchdog' | crontab - && info "Removed legacy crontab line"
  fi
  cat >"${CRON_FILE}.new" <<CRON
# MAXNET6G Psiphon watchdog (managed by maxnet v${VERSION})
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root flock -n /run/psiphon-watchdog.lock ${WATCHDOG} >/dev/null 2>&1
@reboot root sleep 90 && flock -n /run/psiphon-watchdog.lock ${WATCHDOG} >/dev/null 2>&1
CRON
  chmod 0644 "${CRON_FILE}.new" && mv -f "${CRON_FILE}.new" "$CRON_FILE"
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
  ok "Watchdog ready: ${WATCHDOG} (cron every 5 min)"
}

# ----------------------------- health probes ---------------------------------
declare -A EXIT_IP=() EXIT_CC=() PING_MS=() STATUS_OF=()

probe_one() {  # $1 cc  $2 outdir
  local cc=$1 port=${SOCKS_OF[$1]} out ip loc t1 t2 ms rc
  out=$(curl -s --max-time 15 -w $'\n__T=%{time_total}' --socks5-hostname "127.0.0.1:${port}" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null); rc=$?
  ((rc == 0)) || return 0
  ip=$(awk -F= '$1=="ip"{print $2}' <<<"$out" | head -n1)
  loc=$(awk -F= '$1=="loc"{print $2}' <<<"$out" | head -n1)
  [[ -n "$ip" ]] || return 0
  t1=$(sed -n 's/^__T=//p' <<<"$out")
  # second, lightweight request = real round-trip latency over a warm tunnel
  t2=$(curl -s -o /dev/null --max-time 10 -w '%{time_total}' --socks5-hostname "127.0.0.1:${port}" \
        http://cp.cloudflare.com/generate_204 2>/dev/null) || t2=""
  [[ "$t2" =~ ^[0-9.]+$ ]] && [[ "$t2" != "0.000000" ]] || t2=$t1
  ms=$(awk -v t="$t2" 'BEGIN{printf "%d", t*1000}')
  printf '%s\t%s\t%s\n' "$ip" "$loc" "$ms" >"$2/$cc"
}

probe_list() {  # "$@" = ccs ; fills EXIT_IP/EXIT_CC/PING_MS/STATUS_OF
  local tmp cc
  tmp=$(mktemp -d)
  for cc in "$@"; do probe_one "$cc" "$tmp" & done
  wait
  for cc in "$@"; do
    if [[ -s "$tmp/$cc" ]] && container_running "${PREFIX}${cc,,}"; then
      IFS=$'\t' read -r EXIT_IP[$cc] EXIT_CC[$cc] PING_MS[$cc] <"$tmp/$cc"
      STATUS_OF[$cc]="ACTIVE"
    else
      EXIT_IP[$cc]="-"; EXIT_CC[$cc]=""; PING_MS[$cc]="-"; STATUS_OF[$cc]="FAILED"
    fi
  done
  rm -rf "$tmp"
}

wait_tunnels() {  # "$@" = ccs ; waits up to HEALTH_TIMEOUT for all to become ACTIVE
  local -a pending=("$@") still=()
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) cc total=$#
  ((total)) || return 0
  info "Waiting for tunnels to connect (max ${HEALTH_TIMEOUT}s)"
  while ((${#pending[@]})) && ((SECONDS < deadline)); do
    probe_list "${pending[@]}"
    still=()
    for cc in "${pending[@]}"; do [[ "${STATUS_OF[$cc]}" == "ACTIVE" ]] || still+=("$cc"); done
    pending=("${still[@]}")
    printf '\r    %sconnected: %d/%d  (%ds)%s   ' "$DIM" $((total - ${#pending[@]})) "$total" "$SECONDS" "$N"
    ((${#pending[@]})) && sleep 6
  done
  echo
}

# ----------------------------- status table ----------------------------------
readonly -a TCOLW=(3 18 4 7 8 15 9 8)
readonly -a THEAD=("#" "Country" "Code" "SOCKS5" "Inbound" "Exit IP" "Ping" "Status")

t_line() {  # $1 left  $2 mid  $3 right
  local i out="$1"
  for i in "${!TCOLW[@]}"; do
    out+=$(repeat '─' $((TCOLW[i] + 2)))
    ((i < ${#TCOLW[@]} - 1)) && out+="$2"
  done
  printf '%s%s%s%s\n' "$RED" "$out" "$3" "$N"
}
t_cell() {  # $1 text  $2 width  $3 color
  local t=$1 w
  ((${#t} > $2)) && t="${t:0:$(($2 - 1))}…"
  w=$(dwidth "$t")
  printf '%s│%s %s%s%s%*s ' "$RED" "$N" "${3:-}" "$t" "$N" $(($2 - w)) ""
}

render_table() {  # "$@" = ccs
  local cc i=0 ping pcol scol icol active=0 total=$#
  for cc in "$@"; do [[ "${STATUS_OF[$cc]}" == "ACTIVE" ]] && active=$((active + 1)); done
  echo
  t_line "┌" "┬" "┐"
  for i in "${!THEAD[@]}"; do t_cell "${THEAD[$i]}" "${TCOLW[$i]}" "$W"; done
  printf '%s│%s\n' "$RED" "$N"
  t_line "├" "┼" "┤"
  i=0
  for cc in "$@"; do
    i=$((i + 1))
    ping=${PING_MS[$cc]:--}
    if [[ "$ping" =~ ^[0-9]+$ ]]; then
      if ((ping < 300)); then pcol=$G; elif ((ping <= 600)); then pcol=$Y; else pcol=$RED; fi
      ping="${ping} ms"
    else
      pcol=$RED; ping="timeout"
    fi
    if [[ "${STATUS_OF[$cc]}" == "ACTIVE" ]]; then
      scol=$G; icol=$W
      [[ -n "${EXIT_CC[$cc]}" && "${EXIT_CC[$cc]}" != "$cc" ]] && icol=$Y
    else
      scol=$RED; icol=$DIM
    fi
    t_cell "$i" "${TCOLW[0]}" "$DIM"
    t_cell "${CFLAG[$cc]} ${CNAME[$cc]}" "${TCOLW[1]}" ""
    t_cell "$cc" "${TCOLW[2]}" "$C"
    t_cell "${SOCKS_OF[$cc]}" "${TCOLW[3]}" "$W"
    t_cell "${INBOUND_OF[$cc]:--}" "${TCOLW[4]}" "$Y"
    t_cell "${EXIT_IP[$cc]}" "${TCOLW[5]}" "$icol"
    t_cell "$ping" "${TCOLW[6]}" "$pcol"
    t_cell "${STATUS_OF[$cc]}" "${TCOLW[7]}" "$scol"
    printf '%s│%s\n' "$RED" "$N"
  done
  t_line "└" "┴" "┘"
  printf '  %sActive:%s %s%d/%d%s   %sPing:%s %s<300%s %s300-600%s %s>600/down%s   %sYellow IP = exit country differs from requested%s\n' \
    "$W" "$N" "$( ((active == total)) && echo "$G" || echo "$Y")" "$active" "$total" "$N" \
    "$W" "$N" "$G" "$N" "$Y" "$N" "$RED" "$N" "$DIM" "$N"
  if ((total)); then
    printf '  %sXray/3X-UI outbound:%s {"tag":"psiphon-%s","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":%s}]}}\n\n' \
      "$DIM" "$N" "${1,,}" "${SOCKS_OF[$1]}"
  fi
}

state_ccs() { local cc; for cc in "${COUNTRIES[@]}"; do [[ -n "${IN_STATE[$cc]:-}" ]] && printf '%s\n' "$cc"; done; }

# =============================================================================
# 1) INSTALL
# =============================================================================
do_install() {
  title "🚀 INSTALL ALL LOCATIONS"
  ensure_deps || return 1
  mkdir -p "$BASE_DIR" "$DATA_DIR" "$HEALTH_DIR"

  load_state || true
  local -A PREV_IN=()
  local cc; for cc in "${!INBOUND_OF[@]}"; do PREV_IN[$cc]=${INBOUND_OF[$cc]}; done
  # carry inbound ports from the previous version too
  if [[ -r /etc/psiphon-manager/instances.tsv ]]; then
    local a b c d
    while IFS=$'\t' read -r a b c d; do
      [[ -z "${a:-}" || "$a" == \#* || -z "${CNAME[$a]:-}" ]] && continue
      [[ -z "${PREV_IN[$a]:-}" && "${d:--}" != "-" ]] && PREV_IN[$a]=$d
    done </etc/psiphon-manager/instances.tsv
  fi

  info "Pausing watchdog during installation"
  rm -f "$CRON_FILE"; pkill -f "$WATCHDOG" 2>/dev/null || true
  remove_project_containers

  # ---- safe inbound port discovery ----
  refresh_ports
  local p free=() busy=()
  for p in "${CANDIDATE_PORTS[@]}"; do if port_free "$p"; then free+=("$p"); else busy+=("$p"); fi; done
  info "SSH port(s) protected: ${SSH_PORTS[*]}"
  ((${#busy[@]})) && warn "Occupied candidate ports (untouched): ${busy[*]}"
  ok "Free inbound candidates: ${#free[@]} / ${#CANDIDATE_PORTS[@]}  ${DIM}top: ${free[*]:0:12}${N}"

  # ---- core ----
  write_template || return 1
  fetch_binary no || return 1
  build_image || return 1

  # ---- deploy 22 locations ----
  INBOUND_OF=(); IN_STATE=()
  local started=() fwports=() sp
  for cc in "${COUNTRIES[@]}"; do
    sp=${SOCKS_OF[$cc]}
    if ! port_free "$sp"; then
      err "${CFLAG[$cc]} ${cc}: SOCKS5 port ${sp} is used by another service; location skipped (port NOT changed)"
      continue
    fi
    if [[ -n "${PREV_IN[$cc]:-}" && "${PREV_IN[$cc]}" != "-" ]]; then
      INBOUND_OF[$cc]=${PREV_IN[$cc]}
    else
      INBOUND_OF[$cc]=$(next_free_inbound)
    fi
    if run_container "$cc"; then
      IN_STATE[$cc]=1; started+=("$cc")
      [[ "${INBOUND_OF[$cc]}" != "-" ]] && fwports+=("${INBOUND_OF[$cc]}")
      printf '    %s✓%s %s %-15s socks5://127.0.0.1:%s   inbound:%s\n' "$G" "$N" "${CFLAG[$cc]}" "${CNAME[$cc]}" "$sp" "${INBOUND_OF[$cc]}"
    else
      err "Failed to start ${PREFIX}${cc,,}"; unset "INBOUND_OF[$cc]"
    fi
  done
  save_state
  ok "State saved (${#started[@]} locations)"

  fw_open_ports "${fwports[@]}"
  install_watchdog
  for p in "${LEGACY_DIRS[@]}"; do [[ -d "$p" ]] && rm -rf "$p" && info "Cleaned legacy dir $p"; done
  install_cli

  wait_tunnels "${started[@]}"
  probe_list "${started[@]}"
  render_table "${started[@]}"
}

# =============================================================================
# 2) SMART UPDATE  (ports never change, healthy containers never restarted)
# =============================================================================
do_update() {
  title "🔄 SMART UPDATE · KEEP PORTS"
  if ! load_state; then warn "Not installed yet. Use option 1 first."; return 1; fi
  ensure_deps || return 1
  mkdir -p "$DATA_DIR" "$HEALTH_DIR"

  write_template || return 1
  fetch_binary yes || return 1
  build_image || return 1
  install_watchdog
  install_cli

  local -a ccs=() failed=() recreated=() newfw=()
  local cc
  mapfile -t ccs < <(state_ccs)
  info "Checking ${#ccs[@]} locations (healthy ones stay untouched)"
  probe_list "${ccs[@]}"
  for cc in "${ccs[@]}"; do [[ "${STATUS_OF[$cc]}" == "ACTIVE" ]] || failed+=("$cc"); done
  if ((${#failed[@]})); then            # second chance before rebuilding
    sleep 5; probe_list "${failed[@]}"
    local -a f2=(); for cc in "${failed[@]}"; do [[ "${STATUS_OF[$cc]}" == "ACTIVE" ]] || f2+=("$cc"); done
    failed=("${f2[@]}")
  fi

  refresh_ports
  for cc in "${failed[@]}"; do
    info "Rebuilding ${PREFIX}${cc,,} (same SOCKS5 ${SOCKS_OF[$cc]}, same inbound ${INBOUND_OF[$cc]})"
    docker rm -f "${PREFIX}${cc,,}" >/dev/null 2>&1 || true
    sleep 1
    run_container "$cc" && recreated+=("$cc") || err "Could not rebuild ${PREFIX}${cc,,}"
  done

  # locations never deployed before (e.g. port was busy at install time)
  for cc in "${COUNTRIES[@]}"; do
    [[ -n "${IN_STATE[$cc]:-}" ]] && continue
    port_free "${SOCKS_OF[$cc]}" || { warn "${cc}: SOCKS5 ${SOCKS_OF[$cc]} still busy; skipped"; continue; }
    INBOUND_OF[$cc]=$(next_free_inbound)
    if run_container "$cc"; then
      IN_STATE[$cc]=1; recreated+=("$cc"); ccs+=("$cc")
      [[ "${INBOUND_OF[$cc]}" != "-" ]] && newfw+=("${INBOUND_OF[$cc]}")
      ok "New location ${CFLAG[$cc]} ${cc} on 127.0.0.1:${SOCKS_OF[$cc]}"
    fi
  done
  save_state
  ((${#newfw[@]})) && fw_open_ports "${newfw[@]}"

  local healthy=$(( ${#ccs[@]} - ${#recreated[@]} ))
  ok "Kept running without interruption: ${healthy}   Rebuilt/added: ${#recreated[@]}"
  ((healthy > 0)) && info "Healthy containers switch to the new core automatically the next time they are rebuilt"

  mapfile -t ccs < <(state_ccs)
  ((${#recreated[@]})) && wait_tunnels "${recreated[@]}"
  probe_list "${ccs[@]}"
  render_table "${ccs[@]}"
}

# =============================================================================
# 3) STATUS
# =============================================================================
do_status() {
  title "📊 LOCATIONS · PING · ACTIVE STATUS"
  command -v docker >/dev/null 2>&1 || { warn "Docker is not installed. Use option 1 first."; return 1; }
  if ! load_state; then warn "Not installed yet. Use option 1 first."; return 1; fi
  local -a ccs=()
  mapfile -t ccs < <(state_ccs)
  info "Live-testing ${#ccs[@]} SOCKS5 tunnels..."
  probe_list "${ccs[@]}"
  render_table "${ccs[@]}"
}

# =============================================================================
# 4) UNINSTALL
# =============================================================================
do_uninstall() {
  local interactive=${1:-yes} ans
  title "🗑  UNINSTALL & CLEANUP"
  if [[ "$interactive" == "yes" ]]; then
    ans=$(ask "  ${RED}Remove all psiphon-* containers and project files? type 'yes': ${N}")
    [[ "$ans" == "yes" ]] || { info "Cancelled"; return 0; }
  fi
  rm -f "$CRON_FILE"
  pkill -f "$WATCHDOG" 2>/dev/null || true
  if crontab -l 2>/dev/null | grep -q 'psiphon-watchdog'; then
    crontab -l 2>/dev/null | grep -v 'psiphon-watchdog' | crontab - || true
  fi
  command -v docker >/dev/null 2>&1 && { remove_project_containers; docker image rm "$IMAGE" >/dev/null 2>&1 || true; }

  # Inbound rules may now serve your Xray/3X-UI panel -> kept unless you say so.
  if [[ "$interactive" == "yes" && -s "$FW_PORTS_FILE" ]]; then
    ans=$(ask "  Also remove the inbound firewall rules this project added ($(tr '\n' ' ' <"$FW_PORTS_FILE"))? [y/N]: ")
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      local mode p t; mode=$(cat "$FW_MODE_FILE" 2>/dev/null || echo none)
      while read -r p; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        case "$mode" in
          ufw) ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true ;;
          iptables) for t in iptables ip6tables; do
                      command -v "$t" >/dev/null 2>&1 || continue
                      while "$t" -D INPUT -p tcp --dport "$p" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null; do :; done
                    done ;;
        esac
      done <"$FW_PORTS_FILE"
      ok "Removed only this project's inbound rules"
    else
      info "Firewall rules kept as-is"
    fi
  fi

  rm -rf "$BASE_DIR" "${LEGACY_DIRS[@]}"
  rm -f "$WATCHDOG" "$LOGROTATE_FILE" "$CLI_PATH" "${CLI_PATH}.new"
  ok "Uninstalled. 'maxnet' removed. Other containers, services and firewall rules were not touched."
}

# =============================================================================
# MENU
# =============================================================================
show_menu() {
  clear 2>/dev/null || printf '\033c'
  box_top
  box_row "${BRAND} MANAGER  v${VERSION}" "$W" yes
  box_mid
  box_row "1) 🚀 نصب و راه‌اندازی (Install All Locations)"
  box_row "2) 🔄 به‌روزرسانی هوشمند (Smart Update - Keep Ports)"
  box_row "3) 📊 بررسی لوکیشن‌ها، پینگ و وضعیت (Check Status)"
  box_row "4) 🗑 حذف کامل و پاکسازی (Uninstall)"
  box_row "0) ❌ خروج (Exit)"
  box_bot
  print_logo
}

main_menu() {
  local choice
  while true; do
    show_menu
    choice=$(ask "  ${RED}▶${N} ${W}Select an option [0-4]: ${N}")
    case "$choice" in
      1) with_lock do_install; pause ;;
      2) with_lock do_update;  pause ;;
      3) do_status;            pause ;;
      4) with_lock do_uninstall yes
         [[ -x "$CLI_PATH" ]] || { print_logo; exit 0; }
         pause ;;
      0) print_logo; exit 0 ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

main() {
  require_root
  mkdir -p "$(dirname "$INSTALL_LOG")"
  log "---- maxnet v${VERSION} args=$*"
  install_cli
  case "${1:-}" in
    --install)   with_lock do_install ;;
    --update)    with_lock do_update ;;
    --status)    do_status ;;
    --uninstall) with_lock do_uninstall no ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
    "")          main_menu ;;
    *)           err "Unknown option: $1 (use --help)"; exit 1 ;;
  esac
  [[ -n "${1:-}" && "$1" != "-h" && "$1" != "--help" ]] && print_logo
  return 0
}

main "$@"
