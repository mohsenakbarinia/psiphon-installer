#!/usr/bin/env bash
# =============================================================================
#  MAXNET6G ULTIMATE MANAGER · Psiphon Multi-Instance CLI  (v5.0.0)
#  Developer: mohsenakbarinia
#
#  sudo bash install.sh           -> interactive menu (installs the `maxnet` command)
#  maxnet                         -> open the menu from anywhere
#
#  Non-interactive:
#   maxnet --install | --update | --status | --uninstall
#   maxnet --renew US             renew exit IP of one location
#   maxnet --xui-sync             inject 22 SOCKS5 outbounds into 3X-UI
#   maxnet --backup [file]        maxnet --restore <file>
#
#  SAFETY GUARANTEES
#   * Never runs `ufw reset`, `iptables -F`, or changes default firewall policies.
#   * Only touches Docker containers whose name starts with "psiphon-".
#   * SOCKS5 ports are fixed: US=1081 ... AU=1102, bound to 127.0.0.1 only.
#   * Smart Update never moves ports and never restarts healthy containers.
#   * SSH port(s) are never touched by any firewall / Fail2Ban action.
#
#  ENV OVERRIDES
#   HEALTH_TIMEOUT=150  PSIPHON_BINARY_URL=...  PSIPHON_BINARY_PATH=/local/bin
#   XUI_DB=/etc/x-ui/x-ui.db  GOST_URL=...  GOST_PATH=/local/gost
# =============================================================================
set -uo pipefail

_loc=$(locale -a 2>/dev/null | grep -iE '^(c|en_us)\.utf-?8$' | head -n1)
[[ -n "$_loc" ]] && export LC_ALL="$_loc"
unset _loc

# ----------------------------- constants -------------------------------------
readonly VERSION="5.0.0"
readonly BRAND="MAXNET6G"
readonly PREFIX="psiphon-"
readonly BASE_DIR="/var/lib/psiphon-multi"
readonly BIN_DIR="${BASE_DIR}/bin"
readonly BUILD_DIR="${BASE_DIR}/build"
readonly DATA_DIR="${BASE_DIR}/data"
readonly HEALTH_DIR="${BASE_DIR}/health"
readonly LIB_DIR="${BASE_DIR}/lib"
readonly BOT_DIR="${BASE_DIR}/bot"
readonly BOT_ENV="${BOT_DIR}/bot.env"
readonly BOT_PY="${BOT_DIR}/maxnet_bot.py"
readonly BOT_UNIT="/etc/systemd/system/maxnet-bot.service"
readonly TUN_DIR="${BASE_DIR}/tunnel"
readonly TUN_ENV="${TUN_DIR}/tunnel.env"
readonly TUN_BIN="${TUN_DIR}/gost"
readonly TUN_UNIT="/etc/systemd/system/maxnet-tunnel.service"
readonly OPT_DIR="${BASE_DIR}/optimize"
readonly SYSCTL_FILE="/etc/sysctl.d/99-maxnet6g.conf"
readonly OPT_CRON="/etc/cron.d/maxnet-optimize"
readonly F2B_JAIL="/etc/fail2ban/jail.d/maxnet6g.local"
readonly F2B_FILTER="/etc/fail2ban/filter.d/maxnet-portscan.conf"
readonly STATE_FILE="${BASE_DIR}/instances.tsv"
readonly TEMPLATE_FILE="${BASE_DIR}/config.template.json"
readonly FW_PORTS_FILE="${BASE_DIR}/firewall.ports"
readonly FW_MODE_FILE="${BASE_DIR}/firewall.mode"
readonly CF_RESULT="${BASE_DIR}/cf-clean-ips.txt"
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
readonly CONTAINER_MEM="128m"
readonly SOCKS_BASE=1081
readonly XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
readonly LEGACY_DIRS=(/opt/psiphon-manager /etc/psiphon-manager /var/lib/psiphon-manager /usr/local/lib/psiphon-manager)
readonly LEGACY_BIN="/opt/psiphon-manager/bin/psiphon-tunnel-core"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-150}"
PSIPHON_BINARY_URL="${PSIPHON_BINARY_URL:-https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64}"
PSIPHON_BINARY_PATH="${PSIPHON_BINARY_PATH:-}"
PLAIN="no"   # --plain: machine-friendly output (used by the Telegram bot)

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
declare -A SOCKS_OF=() IDX_OF=()
for _i in "${!COUNTRIES[@]}"; do SOCKS_OF[${COUNTRIES[$_i]}]=$((SOCKS_BASE + _i)); IDX_OF[${COUNTRIES[$_i]}]=$_i; done
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

dwidth() { printf '%s' "$1" | wc -L; }
repeat() { local i s=""; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf '%s' "$s"; }

readonly BOX_W=64
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
submenu() {  # $1 title, rest = rows
  local t=$1; shift
  echo; box_top; box_row "$t" "$W" yes; box_mid
  local r; for r in "$@"; do box_row "$r"; done
  box_bot
}

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

ask()   { local __v; read -r -p "$1" __v </dev/tty || __v=""; printf '%s' "$__v"; }
askdef(){ local v; v=$(ask "$1 [${2}]: "); printf '%s' "${v:-$2}"; }
yesno() { local v; v=$(ask "$1 [y/N]: "); [[ "$v" =~ ^[Yy]([Ee][Ss])?$ ]]; }
pause() { read -r -p "  ${DIM}Press Enter to return to menu...${N}" _ </dev/tty 2>/dev/null || true; }

in_list() { local n=$1; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" =~ ^[0-9a-fA-F:]+$ && "$1" == *:* ]] || [[ "$1" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
randstr() { tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "${1:-20}"; }
arch_tag() { case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) echo unsupported ;; esac; }
has_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

# ----------------------------- prechecks -------------------------------------
require_root() { [[ $EUID -eq 0 ]] || { err "Run as root: sudo bash install.sh"; exit 1; }; }

with_lock() {
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

ensure_base_tools() {
  local missing=()
  command -v curl    >/dev/null 2>&1 || missing+=(curl)
  command -v ss      >/dev/null 2>&1 || missing+=(iproute2)
  command -v flock   >/dev/null 2>&1 || missing+=(util-linux)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  command -v tar     >/dev/null 2>&1 || missing+=(tar)
  if ((${#missing[@]})); then
    info "Installing missing packages: ${missing[*]}"
    pkg_install "${missing[@]}" || { err "Could not install: ${missing[*]}"; return 1; }
  fi
}

ensure_deps() {
  ensure_base_tools || return 1
  if ! { command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; }; then
    if command -v apt-get >/dev/null 2>&1; then pkg_install cron; else pkg_install cronie; fi \
      || { err "Could not install cron"; return 1; }
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
  ok "Dependencies ready (docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), $(nproc) CPU cores)"
}

# ----------------------------- `maxnet` command -------------------------------
install_cli() {
  local src
  src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")
  [[ "$src" == "$CLI_PATH" ]] && return 0
  if [[ -n "$src" && -f "$src" ]]; then
    if ! cmp -s "$src" "$CLI_PATH" 2>/dev/null; then
      cp -f "$src" "${CLI_PATH}.new" && chmod +x "${CLI_PATH}.new" && mv -f "${CLI_PATH}.new" "$CLI_PATH" \
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
    command -v docker >/dev/null 2>&1 && docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' \
      | sed -nE 's/.*:([0-9]+)(-[0-9]+)?->.*/\1/p'
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
# instances.tsv: cc  container  socks_port(fixed)  inbound_port  cpuset
declare -A INBOUND_OF=() IN_STATE=() CPU_OF=()

load_state() {
  INBOUND_OF=(); IN_STATE=(); CPU_OF=()
  [[ -r "$STATE_FILE" ]] || return 1
  local cc name socks inbound cpu
  while IFS=$'\t' read -r cc name socks inbound cpu; do
    [[ -z "${cc:-}" || "$cc" == \#* ]] && continue
    [[ -n "${CNAME[$cc]:-}" ]] || continue
    IN_STATE[$cc]=1; INBOUND_OF[$cc]="${inbound:--}"; CPU_OF[$cc]="${cpu:--}"
  done <"$STATE_FILE"
  return 0
}

save_state() {
  local cc
  mkdir -p "$BASE_DIR"
  {
    printf '# cc\tcontainer\tsocks_port(fixed)\tinbound_port\tcpuset\n'
    for cc in "${COUNTRIES[@]}"; do
      [[ -n "${IN_STATE[$cc]:-}" ]] || continue
      printf '%s\t%s%s\t%s\t%s\t%s\n' "$cc" "$PREFIX" "${cc,,}" "${SOCKS_OF[$cc]}" "${INBOUND_OF[$cc]:--}" "${CPU_OF[$cc]:--}"
    done
  } >"${STATE_FILE}.new" && mv -f "${STATE_FILE}.new" "$STATE_FILE"
}

state_ccs() { local cc; for cc in "${COUNTRIES[@]}"; do [[ -n "${IN_STATE[$cc]:-}" ]] && printf '%s\n' "$cc"; done; }

next_free_inbound() {
  local p cc used=()
  for cc in "${!INBOUND_OF[@]}"; do used+=("${INBOUND_OF[$cc]}"); done
  for p in "${CANDIDATE_PORTS[@]}"; do
    port_free "$p" || continue
    in_list "$p" "${used[@]}" && continue
    printf '%s' "$p"; return 0
  done
  printf '%s' "-"
}

# Spread containers over cores 1..N-1 (keeps Core 0 free for the kernel / SSH / Xray).
cpu_for() {  # $1 = cc
  local n; n=$(nproc 2>/dev/null || echo 1)
  if ((n <= 1)); then echo "-"; return; fi
  echo $(( 1 + IDX_OF[$1] % (n - 1) ))
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
  case "$(arch_tag)" in
    amd64) ;;
    arm64) [[ "$url" == *x86_64 ]] && url="${url%x86_64}arm64"; warn "arm64 is experimental" ;;
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

run_container() {  # $1 = cc   (uses SOCKS_OF / CPU_OF)
  local cc=$1 name="${PREFIX}${1,,}" dir="${DATA_DIR}/${1,,}" cpu=${CPU_OF[$1]:--}
  [[ "$name" == ${PREFIX}* ]] || return 1
  local -a cpuarg=()
  [[ "$cpu" =~ ^[0-9]+$ ]] && (( cpu < $(nproc) )) && cpuarg=(--cpuset-cpus "$cpu")
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
    --memory="${CONTAINER_MEM}" \
    "${cpuarg[@]}" \
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

ipt_allow() {  # $1 bin  $2 port  $3 proto
  "$1" -C INPUT -p "${3:-tcp}" --dport "$2" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null \
    || "$1" -I INPUT -p "${3:-tcp}" --dport "$2" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null
}

fw_open_ports() {  # "$@" = ports (optionally "port/udp"); opens each individually, never resets anything
  local mode item p proto added=0
  mode=$(fw_mode)
  (($#)) || return 0
  mkdir -p "$BASE_DIR"; touch "$FW_PORTS_FILE"
  [[ ${#SSH_PORTS[@]} -eq 0 ]] && mapfile -t SSH_PORTS < <(detect_ssh_ports)
  for item in "$@"; do
    p=${item%/*}; proto=tcp; [[ "$item" == */udp ]] && proto=udp
    valid_port "$p" || continue
    in_list "$p" "${SSH_PORTS[@]}" && continue
    case "$mode" in
      ufw) ufw allow "${p}/${proto}" comment "$FW_COMMENT" >/dev/null 2>&1 && added=$((added + 1)) ;;
      iptables)
        ipt_allow iptables "$p" "$proto" && added=$((added + 1))
        command -v ip6tables >/dev/null 2>&1 && { ipt_allow ip6tables "$p" "$proto" || true; } ;;
    esac
    echo "${p}/${proto}" >>"$FW_PORTS_FILE"
  done
  sort -u "$FW_PORTS_FILE" -o "$FW_PORTS_FILE" 2>/dev/null || true
  echo "$mode" >"$FW_MODE_FILE"
  case "$mode" in
    none) warn "No active UFW/iptables found; firewall untouched" ;;
    *)    ok "Firewall (${mode}): ensured ${added} rule(s) one-by-one (SSH untouched, SOCKS5 stays on 127.0.0.1)" ;;
  esac
}

fw_remove_ports() {  # "$@" = port/proto entries previously added by us
  local mode item p proto t
  mode=$(cat "$FW_MODE_FILE" 2>/dev/null || echo none)
  for item in "$@"; do
    p=${item%/*}; proto=tcp; [[ "$item" == */udp ]] && proto=udp
    valid_port "$p" || continue
    case "$mode" in
      ufw) ufw delete allow "${p}/${proto}" >/dev/null 2>&1 || true ;;
      iptables) for t in iptables ip6tables; do
                  command -v "$t" >/dev/null 2>&1 || continue
                  while "$t" -D INPUT -p "$proto" --dport "$p" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null; do :; done
                done ;;
    esac
    [[ -f "$FW_PORTS_FILE" ]] && sed -i "\|^${p}/${proto}\$|d;\|^${p}\$|d" "$FW_PORTS_FILE"
  done
}

# ----------------------------- watchdog --------------------------------------
install_watchdog() {
  cat >"${WATCHDOG}.new" <<'WD'
#!/usr/bin/env bash
# MAXNET6G · Psiphon Multi-Instance watchdog (managed by maxnet). Touches only psiphon-* containers.
set -uo pipefail
_loc=$(locale -a 2>/dev/null | grep -iE '^(c|en_us)\.utf-?8$' | head -n1); [[ -n "$_loc" ]] && export LC_ALL="$_loc"
BASE=/var/lib/psiphon-multi
STATE=$BASE/instances.tsv
TEMPLATE=$BASE/config.template.json
FAILDIR=$BASE/health
BOT_ENV=$BASE/bot/bot.env
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

flag() { local c=${1^^} a b; a=$(printf '%d' "'${c:0:1}"); b=$(printf '%d' "'${c:1:1}")
  printf "\\U$(printf '%08X' $((0x1F1E6 + a - 65)))\\U$(printf '%08X' $((0x1F1E6 + b - 65)))"; }

tg() {  # instant Telegram alert (if bot configured and alerts enabled)
  [[ -r "$BOT_ENV" ]] || return 0
  local token chat alerts id
  token=$(sed -n 's/^BOT_TOKEN=//p' "$BOT_ENV"); chat=$(sed -n 's/^ADMIN_ID=//p' "$BOT_ENV")
  alerts=$(sed -n 's/^ALERTS=//p' "$BOT_ENV")
  [[ -n "$token" && -n "$chat" && "${alerts:-1}" == "1" ]] || return 0
  for id in ${chat//,/ }; do
    curl -s --max-time 10 "https://api.telegram.org/bot${token}/sendMessage" \
      --data-urlencode "chat_id=${id}" --data-urlencode "parse_mode=HTML" \
      --data-urlencode "text=$1" >/dev/null 2>&1 &
  done
}

[[ -r "$STATE" ]] || exit 0
command -v docker >/dev/null 2>&1 || exit 0
if ! docker info >/dev/null 2>&1; then
  systemctl restart docker >/dev/null 2>&1 && { log "docker daemon was down -> restarted"; tg "🔴 <b>Docker</b> از کار افتاده بود → 🟢 ریستارت شد"; }
  sleep 10
fi

recreate() {  # $1 cc  $2 name  $3 socks  $4 cpu
  local cc=$1 name=$2 socks=$3 cpu=${4:--} dir="$BASE/data/${1,,}" cpuarg=()
  [[ "$name" == psiphon-* ]] || return 1
  docker image inspect "$IMAGE" >/dev/null 2>&1 || { log "$name missing and image missing; run: maxnet"; return 1; }
  [[ "$cpu" =~ ^[0-9]+$ ]] && (( cpu < $(nproc) )) && cpuarg=(--cpuset-cpus "$cpu")
  mkdir -p "$dir" && chown -R 65534:65534 "$dir"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --label psiphon.manager=maxnet --label "psiphon.region=${cc}" \
    --restart unless-stopped --network host --user 65534:65534 --cap-drop ALL \
    --security-opt no-new-privileges --memory=128m "${cpuarg[@]}" \
    --log-opt max-size=5m --log-opt max-file=2 \
    -e "EGRESS_REGION=${cc}" -e "SOCKS_PORT=${socks}" -v "${dir}:/data" \
    -v "${TEMPLATE}:/etc/psiphon/config.template.json:ro" "$IMAGE" >/dev/null 2>&1 \
    && { log "$name was missing -> recreated on 127.0.0.1:${socks}"
         tg "🔴 لوکیشن $(flag "$cc") <b>${cc}</b> حذف شده بود → ♻️ <b>بازسازی شد</b> (SOCKS5 ${socks})"; }
}

check_one() {
  local cc=$1 name=$2 socks=$3 cpu=$4 f="$FAILDIR/$2.fails" running fails
  running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo missing)
  if [[ "$running" == "missing" ]]; then recreate "$cc" "$name" "$socks" "$cpu"; echo 0 >"$f"; return; fi
  if [[ "$running" != "true" ]]; then
    docker start "$name" >/dev/null 2>&1 && { log "$name was stopped -> started"
      tg "🔴 لوکیشن $(flag "$cc") <b>${cc}</b> متوقف بود → 🟢 <b>دوباره روشن شد</b>"; }
    echo 0 >"$f"; return
  fi
  if curl -s -o /dev/null --max-time 20 --socks5-hostname "127.0.0.1:${socks}" "$CHECK_URL"; then
    if [[ -f "$FAILDIR/$name.down" ]]; then
      rm -f "$FAILDIR/$name.down"; tg "🟢 لوکیشن $(flag "$cc") <b>${cc}</b> دوباره <b>ACTIVE</b> شد"
    fi
    echo 0 >"$f"
  else
    fails=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
    echo "$fails" >"$f"
    log "$name socks5 127.0.0.1:${socks} failed (${fails}/${MAX_FAILS})"
    if (( fails >= MAX_FAILS )); then
      docker restart -t 5 "$name" >/dev/null 2>&1 && log "$name restarted"
      touch "$FAILDIR/$name.down"
      tg "🔴 لوکیشن $(flag "$cc") <b>${cc}</b> قطع شد (FAILED) → ♻️ Watchdog کانتینر را ریستارت کرد"
      echo 0 >"$f"
    fi
  fi
}

while IFS=$'\t' read -r cc name socks _ cpu; do
  [[ -z "${cc:-}" || "$cc" == \#* ]] && continue
  [[ "$name" == psiphon-* ]] || continue
  check_one "$cc" "$name" "$socks" "${cpu:--}" &
done <"$STATE"
wait

# Re-ensure our iptables ACCEPT rules after reboot (additive, never flushes anything)
if [[ "$(cat "$FW_MODE_FILE" 2>/dev/null)" == "iptables" && -r "$FW_PORTS_FILE" ]]; then
  while read -r item; do
    p=${item%/*}; proto=tcp; [[ "$item" == */udp ]] && proto=udp
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    for t in iptables ip6tables; do
      command -v "$t" >/dev/null 2>&1 || continue
      "$t" -C INPUT -p "$proto" --dport "$p" -m comment --comment maxnet-psiphon -j ACCEPT 2>/dev/null \
        || "$t" -I INPUT -p "$proto" --dport "$p" -m comment --comment maxnet-psiphon -j ACCEPT 2>/dev/null || true
    done
  done <"$FW_PORTS_FILE"
fi
wait
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
  ok "Watchdog ready: ${WATCHDOG} (cron every 5 min, Telegram alerts if bot enabled)"
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
  t2=$(curl -s -o /dev/null --max-time 10 -w '%{time_total}' --socks5-hostname "127.0.0.1:${port}" \
        http://cp.cloudflare.com/generate_204 2>/dev/null) || t2=""
  [[ "$t2" =~ ^[0-9.]+$ && "$t2" != "0.000000" ]] || t2=$t1
  ms=$(awk -v t="$t2" 'BEGIN{printf "%d", t*1000}')
  printf '%s\t%s\t%s\n' "$ip" "$loc" "$ms" >"$2/$cc"
}

probe_list() {
  local tmp cc
  (($#)) || return 0
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

wait_tunnels() {
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

# ----------------------------- generic red table -----------------------------
declare -a TCOLW=()
t_line() {
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
t_end() { printf '%s│%s\n' "$RED" "$N"; }

render_table() {  # "$@" = ccs
  local cc i=0 ping pcol scol icol active=0 total=$#
  TCOLW=(3 18 4 7 8 15 9 8)
  local -a head=("#" "Country" "Code" "SOCKS5" "Inbound" "Exit IP" "Ping" "Status")
  for cc in "$@"; do [[ "${STATUS_OF[$cc]}" == "ACTIVE" ]] && active=$((active + 1)); done
  echo
  t_line "┌" "┬" "┐"
  for i in "${!head[@]}"; do t_cell "${head[$i]}" "${TCOLW[$i]}" "$W"; done; t_end
  t_line "├" "┼" "┤"
  i=0
  for cc in "$@"; do
    i=$((i + 1))
    ping=${PING_MS[$cc]:--}
    if [[ "$ping" =~ ^[0-9]+$ ]]; then
      if ((ping < 300)); then pcol=$G; elif ((ping <= 600)); then pcol=$Y; else pcol=$RED; fi
      ping="${ping} ms"
    else pcol=$RED; ping="timeout"; fi
    if [[ "${STATUS_OF[$cc]}" == "ACTIVE" ]]; then
      scol=$G; icol=$W
      [[ -n "${EXIT_CC[$cc]}" && "${EXIT_CC[$cc]}" != "$cc" ]] && icol=$Y
    else scol=$RED; icol=$DIM; fi
    t_cell "$i" "${TCOLW[0]}" "$DIM"
    t_cell "${CFLAG[$cc]} ${CNAME[$cc]}" "${TCOLW[1]}" ""
    t_cell "$cc" "${TCOLW[2]}" "$C"
    t_cell "${SOCKS_OF[$cc]}" "${TCOLW[3]}" "$W"
    t_cell "${INBOUND_OF[$cc]:--}" "${TCOLW[4]}" "$Y"
    t_cell "${EXIT_IP[$cc]}" "${TCOLW[5]}" "$icol"
    t_cell "$ping" "${TCOLW[6]}" "$pcol"
    t_cell "${STATUS_OF[$cc]}" "${TCOLW[7]}" "$scol"
    t_end
  done
  t_line "└" "┴" "┘"
  printf '  %sActive:%s %s%d/%d%s   %sPing:%s %s<300%s %s300-600%s %s>600/down%s   %sYellow IP = exit country differs%s\n\n' \
    "$W" "$N" "$( ((active == total)) && echo "$G" || echo "$Y")" "$active" "$total" "$N" \
    "$W" "$N" "$G" "$N" "$Y" "$N" "$RED" "$N" "$DIM" "$N"
}

# ----------------------------- speedtest -------------------------------------
speedtest_list() {  # "$@" = ccs ; sequential so tests don't share bandwidth
  local cc i=0 out spd size mbps col mb
  TCOLW=(3 18 4 10 12 8)
  local -a head=("#" "Country" "Code" "Download" "Speed" "Rating")
  info "Downloading a 10 MB test file through each SOCKS5 (sequential)..."
  echo
  t_line "┌" "┬" "┐"
  for i in "${!head[@]}"; do t_cell "${head[$i]}" "${TCOLW[$i]}" "$W"; done; t_end
  t_line "├" "┼" "┤"
  i=0
  for cc in "$@"; do
    i=$((i + 1))
    out=$(curl -s -o /dev/null --max-time 30 -w '%{speed_download} %{size_download}' \
          --socks5-hostname "127.0.0.1:${SOCKS_OF[$cc]}" "https://speed.cloudflare.com/__down?bytes=10000000" 2>/dev/null) || true
    read -r spd size <<<"${out:-0 0}"
    mbps=$(awk -v s="${spd:-0}" 'BEGIN{printf "%.1f", s*8/1000000}')
    mb=$(awk -v s="${size:-0}" 'BEGIN{printf "%.1f MB", s/1000000}')
    if awk -v m="$mbps" 'BEGIN{exit !(m>=20)}'; then col=$G; rt="FAST"
    elif awk -v m="$mbps" 'BEGIN{exit !(m>=5)}'; then col=$Y; rt="OK"
    else col=$RED; rt="SLOW"; fi
    [[ "${size:-0}" == "0" ]] && { rt="DOWN"; mbps="0.0"; }
    t_cell "$i" "${TCOLW[0]}" "$DIM"
    t_cell "${CFLAG[$cc]} ${CNAME[$cc]}" "${TCOLW[1]}" ""
    t_cell "$cc" "${TCOLW[2]}" "$C"
    t_cell "$mb" "${TCOLW[3]}" "$W"
    t_cell "${mbps} Mbps" "${TCOLW[4]}" "$col"
    t_cell "$rt" "${TCOLW[5]}" "$col"
    t_end
  done
  t_line "└" "┴" "┘"
  echo
}

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
  if [[ -r /etc/psiphon-manager/instances.tsv ]]; then
    local a b c d
    while IFS=$'\t' read -r a b c d _; do
      [[ -z "${a:-}" || "$a" == \#* || -z "${CNAME[$a]:-}" ]] && continue
      [[ -z "${PREV_IN[$a]:-}" && "${d:--}" != "-" ]] && PREV_IN[$a]=$d
    done </etc/psiphon-manager/instances.tsv
  fi

  info "Pausing watchdog during installation"
  rm -f "$CRON_FILE"; pkill -f "$WATCHDOG" 2>/dev/null || true
  remove_project_containers

  refresh_ports
  local p free=() busy=()
  for p in "${CANDIDATE_PORTS[@]}"; do if port_free "$p"; then free+=("$p"); else busy+=("$p"); fi; done
  info "SSH port(s) protected: ${SSH_PORTS[*]}"
  ((${#busy[@]})) && warn "Occupied candidate ports (untouched): ${busy[*]}"
  ok "Free inbound candidates: ${#free[@]} / ${#CANDIDATE_PORTS[@]}  ${DIM}top: ${free[*]:0:12}${N}"

  write_template || return 1
  fetch_binary no || return 1
  build_image || return 1

  local ncpu; ncpu=$(nproc 2>/dev/null || echo 1)
  if ((ncpu > 1)); then info "CPU pinning: containers spread over cores 1-$((ncpu - 1)) (Core 0 kept free), RAM limit ${CONTAINER_MEM}"
  else warn "Single-core server: CPU pinning skipped, RAM limit ${CONTAINER_MEM}"; fi

  INBOUND_OF=(); IN_STATE=(); CPU_OF=()
  local started=() fwports=() sp
  for cc in "${COUNTRIES[@]}"; do
    sp=${SOCKS_OF[$cc]}
    if ! port_free "$sp"; then
      err "${CFLAG[$cc]} ${cc}: SOCKS5 port ${sp} is used by another service; location skipped (port NOT changed)"
      continue
    fi
    if [[ -n "${PREV_IN[$cc]:-}" && "${PREV_IN[$cc]}" != "-" ]]; then INBOUND_OF[$cc]=${PREV_IN[$cc]}
    else INBOUND_OF[$cc]=$(next_free_inbound); fi
    CPU_OF[$cc]=$(cpu_for "$cc")
    if run_container "$cc"; then
      IN_STATE[$cc]=1; started+=("$cc")
      [[ "${INBOUND_OF[$cc]}" != "-" ]] && fwports+=("${INBOUND_OF[$cc]}")
      printf '    %s✓%s %s %-15s socks5://127.0.0.1:%s  inbound:%-6s cpu:%s\n' "$G" "$N" "${CFLAG[$cc]}" "${CNAME[$cc]}" "$sp" "${INBOUND_OF[$cc]}" "${CPU_OF[$cc]}"
    else
      err "Failed to start ${PREFIX}${cc,,}"; unset "INBOUND_OF[$cc]" "CPU_OF[$cc]"
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
# 2) SMART UPDATE
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
  if [[ -f "$BOT_UNIT" ]]; then write_bot && systemctl restart maxnet-bot >/dev/null 2>&1 && ok "Telegram bot updated & restarted (no traffic impact)"; fi

  local -a ccs=() failed=() recreated=() newfw=()
  local cc
  mapfile -t ccs < <(state_ccs)
  info "Checking ${#ccs[@]} locations (healthy ones stay untouched)"
  probe_list "${ccs[@]}"
  for cc in "${ccs[@]}"; do [[ "${STATUS_OF[$cc]}" == "ACTIVE" ]] || failed+=("$cc"); done
  if ((${#failed[@]})); then
    sleep 5; probe_list "${failed[@]}"
    local -a f2=(); for cc in "${failed[@]}"; do [[ "${STATUS_OF[$cc]}" == "ACTIVE" ]] || f2+=("$cc"); done
    failed=("${f2[@]}")
  fi

  for cc in "${failed[@]}"; do
    [[ "${CPU_OF[$cc]:--}" == "-" ]] && CPU_OF[$cc]=$(cpu_for "$cc")
    info "Rebuilding ${PREFIX}${cc,,} (same SOCKS5 ${SOCKS_OF[$cc]}, same inbound ${INBOUND_OF[$cc]})"
    run_container "$cc" && recreated+=("$cc") || err "Could not rebuild ${PREFIX}${cc,,}"
  done

  refresh_ports
  for cc in "${COUNTRIES[@]}"; do
    [[ -n "${IN_STATE[$cc]:-}" ]] && continue
    port_free "${SOCKS_OF[$cc]}" || { warn "${cc}: SOCKS5 ${SOCKS_OF[$cc]} still busy; skipped"; continue; }
    INBOUND_OF[$cc]=$(next_free_inbound); CPU_OF[$cc]=$(cpu_for "$cc")
    if run_container "$cc"; then
      IN_STATE[$cc]=1; recreated+=("$cc")
      [[ "${INBOUND_OF[$cc]}" != "-" ]] && newfw+=("${INBOUND_OF[$cc]}")
      ok "New location ${CFLAG[$cc]} ${cc} on 127.0.0.1:${SOCKS_OF[$cc]}"
    fi
  done
  save_state
  ((${#newfw[@]})) && fw_open_ports "${newfw[@]}"

  mapfile -t ccs < <(state_ccs)
  local healthy=$(( ${#ccs[@]} - ${#recreated[@]} ))
  ok "Kept running without interruption: ${healthy}   Rebuilt/added: ${#recreated[@]}"
  ((healthy > 0)) && info "Healthy containers switch to the new core the next time they are rebuilt or renewed"

  ((${#recreated[@]})) && wait_tunnels "${recreated[@]}"
  probe_list "${ccs[@]}"
  render_table "${ccs[@]}"
}

# =============================================================================
# 3) STATUS + SPEEDTEST
# =============================================================================
do_status() {
  local interactive=${1:-yes} ans cc
  title "📊 LOCATIONS · PING · SPEEDTEST"
  command -v docker >/dev/null 2>&1 || { warn "Docker is not installed. Use option 1 first."; return 1; }
  if ! load_state; then warn "Not installed yet. Use option 1 first."; return 1; fi
  local -a ccs=()
  mapfile -t ccs < <(state_ccs)
  info "Live-testing ${#ccs[@]} SOCKS5 tunnels..."
  probe_list "${ccs[@]}"
  render_table "${ccs[@]}"
  [[ "$interactive" == "yes" ]] || return 0
  ans=$(ask "  Speedtest? [a]=all active  [CC]=one location (e.g. DE)  [Enter]=skip: ")
  ans=${ans^^}
  if [[ "$ans" == "A" ]]; then
    local -a act=(); for cc in "${ccs[@]}"; do [[ "${STATUS_OF[$cc]}" == "ACTIVE" ]] && act+=("$cc"); done
    ((${#act[@]})) && speedtest_list "${act[@]}" || warn "No active location to test"
  elif [[ -n "$ans" ]]; then
    if [[ -n "${IN_STATE[$ans]:-}" ]]; then speedtest_list "$ans"; else warn "Unknown/undeployed location: $ans"; fi
  fi
}

# =============================================================================
# 4) RENEW NODE IP
# =============================================================================
probe_ip() {  # $1 cc -> prints exit IP or nothing
  curl -s --max-time 12 --socks5-hostname "127.0.0.1:${SOCKS_OF[$1]}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | awk -F= '$1=="ip"{print $2}' | head -n1
}

renew_node() {  # $1 cc
  local cc=${1^^} name old new attempt t result="FAILED"
  [[ -n "${CNAME[$cc]:-}" ]] || { err "Unknown location: $cc"; echo "RESULT|$cc|-|-|UNKNOWN"; return 1; }
  load_state || { err "Not installed"; echo "RESULT|$cc|-|-|NOTINSTALLED"; return 1; }
  [[ -n "${IN_STATE[$cc]:-}" ]] || { err "$cc is not deployed"; echo "RESULT|$cc|-|-|NOTDEPLOYED"; return 1; }
  name="${PREFIX}${cc,,}"
  exec 8>"/run/maxnet-renew-${cc,,}.lock"
  command -v flock >/dev/null 2>&1 && ! flock -n 8 && { err "Renew already running for $cc"; echo "RESULT|$cc|-|-|BUSY"; return 1; }
  old=$(probe_ip "$cc"); old=${old:--}
  info "${CFLAG[$cc]} ${cc}: current exit IP ${old}. Other locations stay online."
  for attempt in 1 2 3; do
    if ((attempt < 3)); then
      info "Attempt ${attempt}/3: restarting ${name}"
      if container_running "$name"; then docker restart -t 3 "$name" >/dev/null 2>&1; else run_container "$cc"; fi
    else
      info "Attempt 3/3: resetting server affinity (fresh server list) for ${name}"
      docker stop -t 3 "$name" >/dev/null 2>&1 || true
      find "${DATA_DIR}/${cc,,}" -mindepth 1 -maxdepth 1 ! -name config.json -exec rm -rf {} + 2>/dev/null
      docker start "$name" >/dev/null 2>&1 || run_container "$cc"
    fi
    new=""
    for t in $(seq 1 15); do sleep 4; new=$(probe_ip "$cc"); [[ -n "$new" ]] && break; done
    if [[ -n "$new" && "$new" != "$old" ]]; then result="RENEWED"; break; fi
    [[ -n "$new" ]] && warn "Still same IP (${new}), trying again..."
  done
  new=${new:--}
  case "$result" in
    RENEWED) ok "${CFLAG[$cc]} ${cc}: ${old}  →  ${G}${new}${N}" ;;
    *) if [[ "$new" != "-" ]]; then result="SAME"; warn "${cc}: tunnel is up but Psiphon returned the same IP (${new})"
       else err "${cc}: tunnel did not come back yet; watchdog will keep repairing it"; fi ;;
  esac
  echo "RESULT|$cc|$old|$new|$result"
  [[ "$result" != "FAILED" ]]
}

do_renew_menu() {
  title "⚡ RENEW NODE IP"
  load_state || { warn "Not installed yet. Use option 1 first."; return 1; }
  local -a ccs=(); mapfile -t ccs < <(state_ccs)
  local i=0 line="" cc pick
  for cc in "${ccs[@]}"; do
    i=$((i + 1))
    line+=$(printf '%2d) %s %-3s' "$i" "${CFLAG[$cc]}" "$cc")"   "
    if ((i % 5 == 0)); then echo "  $line"; line=""; fi
  done
  [[ -n "$line" ]] && echo "  $line"
  pick=$(ask "  Location number or code (Enter = cancel): ")
  [[ -z "$pick" ]] && return 0
  if [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#ccs[@]})); then cc=${ccs[$((pick - 1))]}; else cc=${pick^^}; fi
  renew_node "$cc" | grep -v '^RESULT|'
}

# =============================================================================
# 5) 3X-UI OUTBOUND INJECTION
# =============================================================================
xui_restart() {
  if has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
    systemctl restart x-ui >/dev/null 2>&1
  elif command -v x-ui >/dev/null 2>&1; then
    x-ui restart >/dev/null 2>&1 </dev/null
  else
    return 1
  fi
}

do_xui_sync() {
  local interactive=${1:-yes}
  title "🔗 3X-UI OUTBOUND INJECTION"
  ensure_base_tools || return 1
  load_state || { warn "Psiphon locations are not installed yet (option 1)."; return 1; }
  [[ -f "$XUI_DB" ]] || { err "3X-UI database not found at ${XUI_DB} (set XUI_DB=/path/x-ui.db)"; return 1; }
  if [[ "$interactive" == "yes" ]]; then
    info "22 SOCKS5 outbounds (127.0.0.1:1081-1102) will be merged into the Xray template."
    info "Existing outbounds / routing stay as-is; x-ui restarts once (a few seconds)."
    yesno "  Continue?" || { info "Cancelled"; return 0; }
  fi
  mkdir -p "${BASE_DIR}/backups"
  local bk="${BASE_DIR}/backups/x-ui.db.$(date +%Y%m%d-%H%M%S)"
  cp -a "$XUI_DB" "$bk" && ok "Database backed up: $bk"
  local cc entries="["
  for cc in "${COUNTRIES[@]}"; do
    [[ -n "${IN_STATE[$cc]:-}" ]] || continue
    entries+="[\"$cc\",\"${CFLAG[$cc]}\",\"${CNAME[$cc]}\",${SOCKS_OF[$cc]}],"
  done
  entries="${entries%,}]"
  local out
  out=$(python3 - "$XUI_DB" "$entries" <<'PY'
import json, sqlite3, sys
db, entries = sys.argv[1], json.loads(sys.argv[2])
DEFAULT = {
  "log": {"access": "none", "dnsLog": False, "error": "", "loglevel": "warning", "maskAddress": ""},
  "api": {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]},
  "inbounds": [{"tag": "api", "listen": "127.0.0.1", "port": 62789, "protocol": "dokodemo-door",
                "settings": {"address": "127.0.0.1"}}],
  "outbounds": [{"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "AsIs"}},
                {"tag": "blocked", "protocol": "blackhole", "settings": {}}],
  "policy": {"levels": {"0": {"statsUserDownlink": True, "statsUserUplink": True}},
             "system": {"statsInboundDownlink": True, "statsInboundUplink": True,
                        "statsOutboundDownlink": True, "statsOutboundUplink": True}},
  "routing": {"domainStrategy": "AsIs", "rules": [
      {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
      {"type": "field", "outboundTag": "blocked", "ip": ["geoip:private"]},
      {"type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"]}]},
  "stats": {}
}
con = sqlite3.connect(db, timeout=15)
cur = con.cursor()
cur.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'")
row = cur.fetchone()
try:
    cfg = json.loads(row[0]) if row and row[0] else DEFAULT
except Exception:
    print("ERR template is not valid JSON"); sys.exit(2)
outs = cfg.get("outbounds") or []
def ours(o):
    if "PSIPHON-" in str(o.get("tag", "")): return True
    if o.get("protocol") == "socks":
        for s in (o.get("settings") or {}).get("servers") or []:
            try:
                if s.get("address") in ("127.0.0.1", "localhost") and 1081 <= int(s.get("port", 0)) <= 1102:
                    return True
            except Exception:
                pass
    return False
kept = [o for o in outs if not ours(o)]
removed = len(outs) - len(kept)
if not kept:
    kept = [{"tag": "direct", "protocol": "freedom", "settings": {}}]
new = [{"tag": f"{flag} PSIPHON-{cc}", "protocol": "socks",
        "settings": {"servers": [{"address": "127.0.0.1", "port": int(port)}]}}
       for cc, flag, name, port in entries]
cfg["outbounds"] = kept + new
val = json.dumps(cfg, indent=2, ensure_ascii=False)
if row:
    cur.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (val,))
else:
    cur.execute("INSERT INTO settings(key, value) VALUES('xrayTemplateConfig', ?)", (val,))
con.commit(); con.close()
print(f"OK {len(new)} {removed}")
PY
)
  if [[ "$out" != OK* ]]; then err "Injection failed: ${out:-python error}. Restore with: cp $bk $XUI_DB"; return 1; fi
  local added removed; read -r _ added removed <<<"$out"
  ok "Injected ${added} outbounds (replaced ${removed} old PSIPHON entries). Tags: '🇺🇸 PSIPHON-US' ..."
  if xui_restart; then ok "x-ui restarted, outbounds are live (Panel → Xray Configs → Outbounds)"
  else warn "Could not restart x-ui automatically; restart the panel to apply"; fi
  echo "RESULT|XUI|${added}|${removed}|OK"
}

write_bot() {
  mkdir -p "$BOT_DIR"; chmod 700 "$BOT_DIR"
  cat >"${BOT_PY}.new" <<'PYBOT'
#!/usr/bin/env python3
# MAXNET6G Telegram bot (managed by maxnet) · Developer: mohsenakbarinia
import datetime, html, json, os, shutil, subprocess, threading, time, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = "/var/lib/psiphon-multi"
ENV = f"{BASE}/bot/bot.env"
STATE = f"{BASE}/instances.tsv"
MARK = f"{BASE}/bot/daily.last"
MAXNET = "/usr/local/bin/maxnet"
TUN_UNIT = "maxnet-tunnel"
ORDER = "US GB CA DE NL FR JP SG AT BE CH ES IT SE NO FI DK PL CZ RO IE AU".split()


def flag(cc):
    return "".join(chr(0x1F1E6 + ord(c) - 65) for c in cc.upper())


def load_env():
    cfg = {"BOT_TOKEN": "", "ADMIN_ID": "", "ALERTS": "1", "DAILY_HOUR": "9"}
    try:
        with open(ENV) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return cfg


def save_env(cfg):
    tmp = ENV + ".new"
    with open(tmp, "w") as f:
        for k in ("BOT_TOKEN", "ADMIN_ID", "ALERTS", "DAILY_HOUR"):
            f.write(f"{k}={cfg.get(k, '')}\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, ENV)


CFG = load_env()
API = f"https://api.telegram.org/bot{CFG['BOT_TOKEN']}/"
ADMINS = {x.strip() for x in CFG["ADMIN_ID"].split(",") if x.strip()}
STYLE_OK = True  # colored buttons (Bot API "style"); auto-disabled if Telegram rejects it
LOCK = threading.Lock()


def api(method, **params):
    req = urllib.request.Request(API + method, data=json.dumps(params).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=70) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"ok": False, "description": str(e)}
    except Exception as e:
        return {"ok": False, "description": str(e)}


def btn(text, data, style="success"):
    b = {"text": text, "callback_data": data}
    if STYLE_OK and style:
        b["style"] = style
    return b


def strip_style(kb):
    return [[{k: v for k, v in b.items() if k != "style"} for b in row] for row in kb]


def send(chat, text, kb=None, edit=None):
    global STYLE_OK
    p = {"chat_id": chat, "text": text, "parse_mode": "HTML", "disable_web_page_preview": True}
    if kb:
        p["reply_markup"] = {"inline_keyboard": kb}
    method = "sendMessage"
    if edit:
        method, p["message_id"] = "editMessageText", edit
    r = api(method, **p)
    if not r.get("ok") and kb and STYLE_OK and "not modified" not in r.get("description", ""):
        STYLE_OK = False
        p["reply_markup"] = {"inline_keyboard": strip_style(kb)}
        r = api(method, **p)
    if not r.get("ok") and edit and "not modified" not in r.get("description", ""):
        p.pop("message_id", None)
        r = api("sendMessage", **p)
    return r


def read_state():
    rows = []
    try:
        with open(STATE) as f:
            for line in f:
                if not line.strip() or line.startswith("#"):
                    continue
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    rows.append({"cc": parts[0], "name": parts[1], "socks": parts[2],
                                 "inbound": parts[3] if len(parts) > 3 else "-"})
    except FileNotFoundError:
        pass
    return rows


def sh(cmd, timeout=30):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def probe(row):
    port = row["socks"]
    out = sh(["curl", "-s", "--max-time", "12", "--socks5-hostname", f"127.0.0.1:{port}",
              "https://www.cloudflare.com/cdn-cgi/trace"], 15)
    ip = loc = ""
    for line in out.splitlines():
        if line.startswith("ip="):
            ip = line[3:]
        elif line.startswith("loc="):
            loc = line[4:]
    ms = None
    if ip:
        t = sh(["curl", "-s", "-o", "/dev/null", "--max-time", "10", "-w", "%{time_total}",
                "--socks5-hostname", f"127.0.0.1:{port}", "http://cp.cloudflare.com/generate_204"], 12)
        try:
            ms = int(float(t) * 1000) or None
        except ValueError:
            ms = None
    running = sh(["docker", "inspect", "-f", "{{.State.Running}}", row["name"]], 10).strip() == "true"
    return dict(row, ip=ip, loc=loc, ms=ms, ok=bool(ip) and running)


def probe_all():
    rows = read_state()
    with ThreadPoolExecutor(max_workers=max(1, len(rows))) as ex:
        return list(ex.map(probe, rows))


def dot(r):
    if not r["ok"]:
        return "🔴"
    return "🟢" if (r["ms"] or 9999) < 300 else ("🟡" if (r["ms"] or 9999) <= 600 else "🔴")


def home_kb():
    return [[btn("🟢 وضعیت زنده سرور", "status"), btn("🟩 تست پینگ و IPها", "ping")],
            [btn("🔄 تعویض IP لوکیشن", "renew"), btn("⚡ همگام‌سازی 3X-UI", "xui")],
            [btn("📈 گزارش مصرف سیستم", "sys"), btn("🔔 تنظیمات هشدارها", "alerts")]]


BACK = [btn("🔙 منوی اصلی", "home", "primary")]


def home_text():
    return ("🟩 <b>MAXNET6G ULTIMATE MANAGER</b> 🟩\n"
            "━━━━━━━━━━━━━━━━━━\n"
            f"🖥 سرور: <code>{html.escape(os.uname().nodename)}</code>\n"
            f"🌍 لوکیشن‌ها: <b>{len(read_state())}</b>\n"
            "👇 یکی از گزینه‌ها را انتخاب کنید\n\n<i>Developer: mohsenakbarinia</i>")


def ping_text(res):
    act = sum(1 for r in res if r["ok"])
    lines = [f"{'':2} {'CC':<3}{'PING':>7}  {'EXIT IP':<15}"]
    for r in res:
        ms = f"{r['ms']}ms" if r["ms"] else "down"
        ip = (r["ip"] or "-")[:15]
        lines.append(f"{dot(r)} {r['cc']:<3}{ms:>7}  {ip:<15}")
    return (f"🟩 <b>تست پینگ و IP ها</b> · فعال <b>{act}/{len(res)}</b>\n"
            f"<pre>{html.escape(chr(10).join(lines))}</pre>\n"
            "🟢 &lt;300ms   🟡 300-600ms   🔴 &gt;600ms/قطع\n"
            "👇 روی هر لوکیشن بزنید تا <b>IP آن فوراً تعویض</b> شود")


def loc_kb(res=None, prefix="rn:"):
    info = {r["cc"]: r for r in (res or [])}
    items = []
    for row in read_state():
        cc = row["cc"]
        r = info.get(cc)
        if r:
            label = f"{flag(cc)} {cc} {str(r['ms']) + 'ms' if r['ms'] else '✖'}"
            style = "success" if r["ok"] else "danger"
        else:
            label, style = f"{flag(cc)} {cc}", "success"
        items.append(btn(label, prefix + cc, style))
    kb = [items[i:i + 3] for i in range(0, len(items), 3)]
    return kb


def status_text():
    res = probe_all()
    act = sum(1 for r in res if r["ok"])
    wd = "🟢 فعال" if os.path.exists("/etc/cron.d/psiphon-watchdog") else "🔴 غیرفعال"
    tun = sh(["systemctl", "is-active", TUN_UNIT], 5).strip()
    tun = "🟢 فعال" if tun == "active" else "⚪️ نصب نشده/خاموش"
    up = int(float(open("/proc/uptime").read().split()[0]))
    la = os.getloadavg()
    bad = ", ".join(f"{flag(r['cc'])}{r['cc']}" for r in res if not r["ok"]) or "هیچ"
    best = sorted([r for r in res if r["ok"] and r["ms"]], key=lambda r: r["ms"])[:3]
    best = " · ".join(f"{flag(r['cc'])}{r['ms']}ms" for r in best) or "-"
    return ("🟢 <b>وضعیت زنده سرور</b>\n━━━━━━━━━━━━━━━━━━\n"
            f"🌍 لوکیشن‌های فعال: <b>{act}/{len(res)}</b>\n"
            f"🔴 قطع: {bad}\n"
            f"⚡ سریع‌ترین‌ها: {best}\n"
            f"🛡 Watchdog: {wd}\n🌉 تونل: {tun}\n"
            f"⏱ Uptime: {up // 86400}d {up % 86400 // 3600}h {up % 3600 // 60}m\n"
            f"📊 Load: {la[0]:.2f} / {la[1]:.2f} / {la[2]:.2f}")


def sys_text():
    mem = {}
    for line in open("/proc/meminfo"):
        k, v = line.split(":", 1)
        mem[k] = int(v.split()[0]) * 1024
    tot, av = mem.get("MemTotal", 1), mem.get("MemAvailable", 0)
    du = shutil.disk_usage("/")
    rx = tx = 0
    for line in open("/proc/net/dev").readlines()[2:]:
        iface, data = line.split(":", 1)
        if iface.strip() in ("lo",) or iface.strip().startswith(("docker", "veth", "br-")):
            continue
        f = data.split()
        rx += int(f[0]); tx += int(f[8])
    gb = lambda b: f"{b / 1024 ** 3:.1f}GB"
    ds = sh(["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"], 40)
    rows = [l.split("\t") for l in ds.splitlines() if l.startswith("psiphon-")]
    cpu_sum = sum(float(r[1].rstrip("%") or 0) for r in rows if len(r) > 1)
    top = sorted(rows, key=lambda r: float(r[1].rstrip("%") or 0), reverse=True)[:5]
    top_txt = "\n".join(f"{flag(r[0][8:10])} {r[0][8:].upper():<3} CPU {r[1]:>6}  RAM {r[2].split('/')[0].strip()}"
                        for r in top) or "-"
    la = os.getloadavg()
    return ("📈 <b>گزارش مصرف سیستم</b>\n━━━━━━━━━━━━━━━━━━\n"
            f"🧠 CPU: {os.cpu_count()} هسته · Load {la[0]:.2f}\n"
            f"💾 RAM: {gb(tot - av)} / {gb(tot)} ({(tot - av) * 100 // tot}%)\n"
            f"🗄 Disk: {gb(du.used)} / {gb(du.total)} ({du.used * 100 // du.total}%)\n"
            f"🌐 ترافیک از بوت: ⬇️ {gb(rx)}  ⬆️ {gb(tx)}\n"
            f"🐳 مجموع CPU سایفون‌ها: {cpu_sum:.1f}%\n"
            f"<pre>{html.escape(top_txt)}</pre>")


def alerts_view():
    a = CFG.get("ALERTS", "1") == "1"
    h = int(CFG.get("DAILY_HOUR", "9") or -1)
    text = ("🔔 <b>تنظیمات هشدارها</b>\n━━━━━━━━━━━━━━━━━━\n"
            f"⚠️ هشدار آنی قطعی/بازسازی: {'🟢 روشن' if a else '🔴 خاموش'}\n"
            f"🗓 گزارش روزانه: {'🟢 ساعت ' + str(h).zfill(2) + ':00' if h >= 0 else '🔴 خاموش'}")
    kb = [[btn(("🔕 خاموش کردن هشدار آنی" if a else "🔔 روشن کردن هشدار آنی"), "al:t", "danger" if a else "success")],
          [btn(f"{'✅ ' if h == x else ''}{x:02d}:00", f"dh:{x}") for x in (8, 12, 18, 22)],
          [btn("🚫 بدون گزارش روزانه", "dh:-1", "danger"), btn("🧪 تست هشدار", "al:test")], BACK]
    return text, kb


def run_bg(fn, *a):
    threading.Thread(target=fn, args=a, daemon=True).start()


def do_renew(chat, mid, cc):
    send(chat, f"⏳ در حال تعویض IP {flag(cc)} <b>{cc}</b> ...\nسایر لوکیشن‌ها بدون قطعی فعال هستند.", None, mid)
    out = sh([MAXNET, "--renew", cc, "--plain"], 400)
    res = [l for l in out.splitlines() if l.startswith("RESULT|")]
    _, _, old, new, st = (res[-1].split("|") + ["-"] * 5)[:5] if res else ("", cc, "-", "-", "FAILED")
    icon = {"RENEWED": "🟢 IP جدید گرفته شد", "SAME": "🟡 تونل فعال است ولی IP تکراری بود"}.get(st, "🔴 ناموفق (Watchdog ادامه می‌دهد)")
    send(chat, f"⚡ <b>Renew {flag(cc)} {cc}</b>\n{icon}\n\n🔸 قبلی: <code>{old}</code>\n🔹 جدید: <code>{new}</code>",
         [[btn("🔁 دوباره", "rn:" + cc), btn("🟩 تست پینگ", "ping")], BACK], mid)


def do_ping(chat, mid):
    send(chat, "⏳ در حال تست زنده ۲۲ لوکیشن ...", None, mid)
    res = probe_all()
    kb = loc_kb(res) + [[btn("🔄 بروزرسانی", "ping"), BACK[0]]]
    send(chat, ping_text(res), kb, mid)


def do_status(chat, mid):
    send(chat, "⏳ در حال بررسی ...", None, mid)
    send(chat, status_text(), [[btn("🔄 بروزرسانی", "status"), BACK[0]]], mid)


def do_sys(chat, mid):
    send(chat, "⏳ در حال جمع‌آوری آمار ...", None, mid)
    send(chat, sys_text(), [[btn("🔄 بروزرسانی", "sys"), BACK[0]]], mid)


def do_xui(chat, mid):
    send(chat, "⏳ در حال تزریق Outboundها به 3X-UI ...", None, mid)
    out = sh([MAXNET, "--xui-sync", "--plain"], 120)
    res = [l for l in out.splitlines() if l.startswith("RESULT|")]
    if res:
        p = res[-1].split("|")
        txt = f"⚡ <b>همگام‌سازی 3X-UI</b>\n🟢 {p[2]} خروجی SOCKS5 تزریق شد و x-ui ریستارت شد."
    else:
        last = html.escape("\n".join(out.strip().splitlines()[-3:]) or "error")
        txt = f"⚡ <b>همگام‌سازی 3X-UI</b>\n🔴 ناموفق:\n<pre>{last}</pre>"
    send(chat, txt, [BACK], mid)


def handle_callback(cq):
    chat = cq["message"]["chat"]["id"]
    mid = cq["message"]["message_id"]
    data = cq.get("data", "")
    api("answerCallbackQuery", callback_query_id=cq["id"])
    if str(cq["from"]["id"]) not in ADMINS and str(chat) not in ADMINS:
        return
    if data == "home":
        send(chat, home_text(), home_kb(), mid)
    elif data == "status":
        run_bg(do_status, chat, mid)
    elif data == "ping":
        run_bg(do_ping, chat, mid)
    elif data == "renew":
        send(chat, "🔄 <b>تعویض IP لوکیشن</b>\nکشور موردنظر را انتخاب کنید:", loc_kb() + [BACK], mid)
    elif data.startswith("rn:"):
        run_bg(do_renew, chat, mid, data[3:].upper()[:2])
    elif data == "xui":
        send(chat, "⚡ <b>همگام‌سازی 3X-UI</b>\n۲۲ خروجی SOCKS5 به قالب Xray اضافه و پنل یک بار ریستارت می‌شود.",
             [[btn("✅ تایید و تزریق", "xui:go"), BACK[0]]], mid)
    elif data == "xui:go":
        run_bg(do_xui, chat, mid)
    elif data == "sys":
        run_bg(do_sys, chat, mid)
    elif data == "alerts":
        t, k = alerts_view(); send(chat, t, k, mid)
    elif data == "al:t":
        with LOCK:
            CFG["ALERTS"] = "0" if CFG.get("ALERTS", "1") == "1" else "1"; save_env(CFG)
        t, k = alerts_view(); send(chat, t, k, mid)
    elif data.startswith("dh:"):
        with LOCK:
            CFG["DAILY_HOUR"] = data[3:]; save_env(CFG)
        t, k = alerts_view(); send(chat, t, k, mid)
    elif data == "al:test":
        send(chat, "🔴 لوکیشن 🇺🇸 <b>US</b> قطع شد (FAILED) → ♻️ Watchdog کانتینر را ریستارت کرد\n<i>(پیام تستی)</i>")


def handle_message(msg):
    chat = msg["chat"]["id"]
    if str(msg.get("from", {}).get("id")) not in ADMINS and str(chat) not in ADMINS:
        send(chat, f"⛔️ دسترسی ندارید.\nChat ID شما: <code>{chat}</code>")
        return
    text = (msg.get("text") or "").strip().lower()
    if text.startswith("/ping"):
        r = send(chat, "⏳ ...")
        run_bg(do_ping, chat, r.get("result", {}).get("message_id"))
    elif text.startswith("/status"):
        r = send(chat, "⏳ ...")
        run_bg(do_status, chat, r.get("result", {}).get("message_id"))
    else:
        send(chat, home_text(), home_kb())


def daily_loop():
    while True:
        try:
            h = int(CFG.get("DAILY_HOUR", "-1") or -1)
            now = datetime.datetime.now()
            today = now.strftime("%Y-%m-%d")
            last = open(MARK).read().strip() if os.path.exists(MARK) else ""
            if h >= 0 and now.hour == h and last != today:
                with open(MARK, "w") as f:
                    f.write(today)
                res = probe_all()
                txt = "🗓 <b>گزارش روزانه MAXNET6G</b>\n" + today + "\n\n" + ping_text(res).split("\n👇")[0]
                for a in ADMINS:
                    send(a, txt, [[btn("🟩 تست پینگ", "ping"), btn("📈 مصرف سیستم", "sys")]])
        except Exception:
            pass
        time.sleep(30)


def main():
    if not CFG["BOT_TOKEN"] or not ADMINS:
        raise SystemExit("bot.env is missing BOT_TOKEN / ADMIN_ID")
    api("setMyCommands", commands=[{"command": "start", "description": "منوی اصلی"},
                                   {"command": "ping", "description": "تست پینگ ۲۲ لوکیشن"},
                                   {"command": "status", "description": "وضعیت زنده سرور"}])
    threading.Thread(target=daily_loop, daemon=True).start()
    offset = 0
    while True:
        r = api("getUpdates", offset=offset, timeout=50, allowed_updates=["message", "callback_query"])
        if not r.get("ok"):
            time.sleep(5); continue
        for u in r.get("result", []):
            offset = u["update_id"] + 1
            try:
                if "callback_query" in u:
                    handle_callback(u["callback_query"])
                elif "message" in u:
                    handle_message(u["message"])
            except Exception as e:
                print("handler error:", e, flush=True)


if __name__ == "__main__":
    main()
PYBOT
  chmod 0700 "${BOT_PY}.new" && mv -f "${BOT_PY}.new" "$BOT_PY"
}

# =============================================================================
# 6) TELEGRAM BOT (green glass buttons)
# =============================================================================
bot_installed() { [[ -f "$BOT_UNIT" && -s "$BOT_ENV" ]]; }

install_bot_service() {
  has_systemd || { err "systemd is required for the bot service"; return 1; }
  write_bot || return 1
  cat >"$BOT_UNIT" <<UNIT
[Unit]
Description=MAXNET6G Telegram Bot (Psiphon Multi-Instance)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 ${BOT_PY}
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now maxnet-bot >/dev/null 2>&1 && systemctl restart maxnet-bot
  sleep 2
  if systemctl is-active --quiet maxnet-bot; then ok "Telegram bot is running (service: maxnet-bot)"; else err "Bot failed to start: journalctl -u maxnet-bot -n 30"; return 1; fi
}

bot_send() {  # $1 text
  local token chat id
  token=$(sed -n 's/^BOT_TOKEN=//p' "$BOT_ENV"); chat=$(sed -n 's/^ADMIN_ID=//p' "$BOT_ENV")
  for id in ${chat//,/ }; do
    curl -s --max-time 15 "https://api.telegram.org/bot${token}/sendMessage" \
      --data-urlencode "chat_id=${id}" --data-urlencode "parse_mode=HTML" --data-urlencode "text=$1"
  done
}

bot_configure() {
  ensure_base_tools || return 1
  mkdir -p "$BOT_DIR"; chmod 700 "$BOT_DIR"
  local token admin hour me
  token=$(ask "  Bot Token (from @BotFather): ")
  [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || { err "Invalid token format"; return 1; }
  me=$(curl -s --max-time 15 "https://api.telegram.org/bot${token}/getMe")
  [[ "$me" == *'"ok":true'* ]] || { err "Telegram rejected this token (or api.telegram.org is unreachable from this server)"; return 1; }
  ok "Bot verified: @$(sed -n 's/.*"username":"\([^"]*\)".*/\1/p' <<<"$me")"
  admin=$(ask "  Admin Chat ID (numeric, comma-separated for multiple; get it from @userinfobot): ")
  [[ "$admin" =~ ^-?[0-9]+(,-?[0-9]+)*$ ]] || { err "Invalid Chat ID"; return 1; }
  hour=$(askdef "  Daily report hour (0-23, -1 = off)" "9")
  [[ "$hour" =~ ^-?[0-9]+$ ]] && ((hour >= -1 && hour <= 23)) || hour=9
  umask 077
  printf 'BOT_TOKEN=%s\nADMIN_ID=%s\nALERTS=1\nDAILY_HOUR=%s\n' "$token" "$admin" "$hour" >"$BOT_ENV"
  umask 022
  chmod 600 "$BOT_ENV"
  install_bot_service || return 1
  bot_send $'🟩 <b>MAXNET6G</b> ربات با موفقیت متصل شد ✅\nبرای باز کردن منو /start را بزنید.' >/dev/null
  ok "Welcome message sent. Open your bot and press /start"
}

do_bot_menu() {
  local c st
  while true; do
    st="not installed"; bot_installed && st=$(systemctl is-active maxnet-bot 2>/dev/null || echo inactive)
    submenu "🤖 TELEGRAM BOT · status: ${st}" \
      "1) نصب / تنظیم مجدد ربات (Token + Admin ID)" \
      "2) ارسال پیام تست (Send test message)" \
      "3) ریستارت ربات (Restart)" \
      "4) نمایش لاگ ربات (Logs)" \
      "5) حذف ربات (Remove bot)" \
      "0) بازگشت (Back)"
    c=$(ask "  ${RED}▶${N} Select: ")
    case "$c" in
      1) bot_configure ;;
      2) bot_installed && { bot_send $'🟢 پیام تست از <b>MAXNET6G</b> · همه‌چیز اوکی است ✅' >/dev/null && ok "Sent"; } || warn "Bot not installed" ;;
      3) bot_installed && systemctl restart maxnet-bot && ok "Restarted" || warn "Bot not installed" ;;
      4) journalctl -u maxnet-bot -n 30 --no-pager 2>/dev/null || warn "No logs" ;;
      5) remove_bot ;;
      0|"") return 0 ;;
      *) warn "Invalid option" ;;
    esac
    pause
  done
}

remove_bot() {
  if [[ -f "$BOT_UNIT" ]]; then
    systemctl disable --now maxnet-bot >/dev/null 2>&1 || true
    rm -f "$BOT_UNIT"; systemctl daemon-reload 2>/dev/null || true
  fi
  rm -rf "$BOT_DIR"
  ok "Telegram bot removed"
}

# =============================================================================
# 7) AUTO TUNNEL BRIDGE (Gost relay+TLS, Iran -> Foreign)
# =============================================================================
fetch_gost() {
  mkdir -p "$TUN_DIR"
  [[ -x "$TUN_BIN" ]] && "$TUN_BIN" -V >/dev/null 2>&1 && { info "Gost already present ($("$TUN_BIN" -V 2>&1 | head -n1))"; return 0; }
  if [[ -n "${GOST_PATH:-}" ]]; then
    install -m 0755 "$GOST_PATH" "$TUN_BIN" && ok "Using local gost binary"; return $?
  fi
  local a tmp urls=() u
  a=$(arch_tag); [[ "$a" == unsupported ]] && { err "Unsupported CPU arch for gost"; return 1; }
  [[ -n "${GOST_URL:-}" ]] && urls+=("$GOST_URL")
  if [[ "$a" == amd64 ]]; then
    urls+=("https://github.com/ginuerzh/gost/releases/download/v2.12.0/gost_2.12.0_linux_amd64.tar.gz"
           "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz")
  else
    urls+=("https://github.com/ginuerzh/gost/releases/download/v2.12.0/gost_2.12.0_linux_arm64.tar.gz"
           "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-armv8-2.11.5.gz")
  fi
  tmp=$(mktemp -d)
  for u in "${urls[@]}"; do
    info "Downloading gost: ${u##*/}"
    curl -fsSL --retry 2 --max-time 120 -o "$tmp/pkg" "$u" || continue
    case "$u" in
      *.tar.gz) tar -xzf "$tmp/pkg" -C "$tmp" 2>/dev/null && [[ -f "$tmp/gost" ]] && install -m 0755 "$tmp/gost" "$TUN_BIN" ;;
      *.gz)     gunzip -c "$tmp/pkg" >"$tmp/gost" 2>/dev/null && install -m 0755 "$tmp/gost" "$TUN_BIN" ;;
      *)        install -m 0755 "$tmp/pkg" "$TUN_BIN" ;;
    esac
    if [[ -x "$TUN_BIN" ]] && "$TUN_BIN" -V >/dev/null 2>&1; then rm -rf "$tmp"; ok "Gost installed ($("$TUN_BIN" -V 2>&1 | head -n1))"; return 0; fi
  done
  rm -rf "$tmp"
  err "Could not download gost (GitHub blocked?). Copy the binary to this server and run: GOST_PATH=/path/gost maxnet"
  return 1
}

write_tunnel_service() {  # builds ExecStart from tunnel.env
  local ROLE LISTEN_PORT USER PASS REMOTE PORTS UDP args=() p
  # shellcheck disable=SC1090
  source "$TUN_ENV"
  if [[ "$ROLE" == "foreign" ]]; then
    args=(-L "relay+tls://${USER}:${PASS}@:${LISTEN_PORT}")
  else
    for p in ${PORTS//,/ }; do
      args+=(-L "tcp://:${p}/127.0.0.1:${p}")
      [[ "$UDP" == "yes" ]] && args+=(-L "udp://:${p}/127.0.0.1:${p}?ttl=60s")
    done
    args+=(-F "relay+tls://${USER}:${PASS}@${REMOTE}:${LISTEN_PORT}")
  fi
  cat >"$TUN_UNIT" <<UNIT
[Unit]
Description=MAXNET6G Auto Tunnel Bridge (${ROLE})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${TUN_BIN} ${args[*]}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now maxnet-tunnel >/dev/null 2>&1; systemctl restart maxnet-tunnel
  sleep 2
  systemctl is-active --quiet maxnet-tunnel && ok "Tunnel service running (maxnet-tunnel)" || { err "Tunnel failed: journalctl -u maxnet-tunnel -n 30"; return 1; }
}

tunnel_foreign() {
  has_systemd || { err "systemd is required"; return 1; }
  ensure_base_tools || return 1
  refresh_ports
  local port user pass myip
  port=$(askdef "  Tunnel listen port on this FOREIGN server" "2087")
  valid_port "$port" || { err "Invalid port"; return 1; }
  port_free "$port" || { err "Port $port is already in use"; return 1; }
  user=$(askdef "  Tunnel username" "maxnet")
  pass=$(askdef "  Tunnel password" "$(randstr 20)")
  [[ "$user" =~ ^[A-Za-z0-9._-]+$ && "$pass" =~ ^[A-Za-z0-9._-]+$ ]] || { err "Username/password: only A-Z a-z 0-9 . _ -"; return 1; }
  fetch_gost || return 1
  mkdir -p "$TUN_DIR"; umask 077
  printf 'ROLE=foreign\nLISTEN_PORT=%s\nUSER=%s\nPASS=%s\nREMOTE=\nPORTS=\nUDP=no\n' "$port" "$user" "$pass" >"$TUN_ENV"
  umask 022; chmod 600 "$TUN_ENV"
  write_tunnel_service || return 1
  fw_open_ports "$port"
  myip=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "<FOREIGN_IP>")
  echo
  box_top; box_row "✅ FOREIGN SIDE READY · now run on the IRAN server:" "$G"; box_mid
  box_row "maxnet → 7 → 2 (Iran server)"
  box_row "Foreign IP : ${myip}"; box_row "Port       : ${port}"
  box_row "Username   : ${user}"; box_row "Password   : ${pass}"
  box_bot
}

tunnel_iran() {
  has_systemd || { err "systemd is required"; return 1; }
  ensure_base_tools || return 1
  refresh_ports
  local remote port user pass ports udp p bad=() fw=()
  remote=$(ask "  FOREIGN server IP/domain: ")
  valid_ip "$remote" || { err "Invalid address"; return 1; }
  port=$(askdef "  Foreign tunnel port" "2087"); valid_port "$port" || { err "Invalid port"; return 1; }
  user=$(askdef "  Tunnel username" "maxnet")
  pass=$(ask "  Tunnel password: ")
  [[ "$user" =~ ^[A-Za-z0-9._-]+$ && "$pass" =~ ^[A-Za-z0-9._-]+$ ]] || { err "Username/password: only A-Z a-z 0-9 . _ -"; return 1; }
  ports=$(askdef "  Ports to forward (your Xray inbound ports on foreign, comma-separated)" "443")
  ports=${ports// /}
  for p in ${ports//,/ }; do
    valid_port "$p" || { err "Invalid port: $p"; return 1; }
    port_free "$p" || bad+=("$p")
  done
  ((${#bad[@]})) && { err "Already in use on this server: ${bad[*]}"; return 1; }
  udp="no"; yesno "  Also forward UDP (gaming/QUIC)?" && udp="yes"
  if ! timeout 6 bash -c "exec 3<>/dev/tcp/${remote}/${port}" 2>/dev/null; then
    warn "Cannot reach ${remote}:${port} right now (check foreign firewall); continuing anyway"
  fi
  fetch_gost || return 1
  mkdir -p "$TUN_DIR"; umask 077
  printf 'ROLE=iran\nLISTEN_PORT=%s\nUSER=%s\nPASS=%s\nREMOTE=%s\nPORTS=%s\nUDP=%s\n' "$port" "$user" "$pass" "$remote" "$ports" "$udp" >"$TUN_ENV"
  umask 022; chmod 600 "$TUN_ENV"
  write_tunnel_service || return 1
  for p in ${ports//,/ }; do fw+=("$p"); [[ "$udp" == "yes" ]] && fw+=("${p}/udp"); done
  fw_open_ports "${fw[@]}"
  ok "Iran bridge ready: clients connect to THIS server on ports ${ports} → encrypted relay → ${remote}"
}

tunnel_status() {
  [[ -s "$TUN_ENV" ]] || { warn "No tunnel configured"; return 0; }
  local ROLE LISTEN_PORT USER PASS REMOTE PORTS UDP
  # shellcheck disable=SC1090
  source "$TUN_ENV"
  box_top; box_row "🌉 TUNNEL STATUS" "$W" yes; box_mid
  box_row "Role     : ${ROLE}"
  box_row "Service  : $(systemctl is-active maxnet-tunnel 2>/dev/null)"
  box_row "Port     : ${LISTEN_PORT}   User: ${USER}   Pass: ${PASS:0:3}*****"
  [[ "$ROLE" == "iran" ]] && { box_row "Remote   : ${REMOTE}"; box_row "Forwards : ${PORTS} (udp: ${UDP})"; }
  box_bot
  if [[ "$ROLE" == "iran" ]]; then
    if timeout 6 bash -c "exec 3<>/dev/tcp/${REMOTE}/${LISTEN_PORT}" 2>/dev/null; then ok "Foreign relay reachable"; else err "Foreign relay NOT reachable"; fi
  fi
}

remove_tunnel() {
  if [[ -f "$TUN_UNIT" ]]; then systemctl disable --now maxnet-tunnel >/dev/null 2>&1 || true; rm -f "$TUN_UNIT"; systemctl daemon-reload 2>/dev/null || true; fi
  rm -rf "$TUN_DIR"
  ok "Tunnel removed (firewall rules kept; remove them from option 12 if needed)"
}

do_tunnel_menu() {
  local c
  while true; do
    submenu "🌉 AUTO TUNNEL BRIDGE · Gost relay+TLS" \
      "1) این سرور خارج است (Foreign endpoint)" \
      "2) این سرور ایران است (Iran bridge → Foreign)" \
      "3) وضعیت تونل (Status)" \
      "4) حذف تونل (Remove)" \
      "0) بازگشت (Back)"
    c=$(ask "  ${RED}▶${N} Select: ")
    case "$c" in
      1) with_lock tunnel_foreign ;;
      2) with_lock tunnel_iran ;;
      3) tunnel_status ;;
      4) remove_tunnel ;;
      0|"") return 0 ;;
      *) warn "Invalid option" ;;
    esac
    pause
  done
}

# =============================================================================
# 8) CLOUDFLARE CLEAN IP FINDER
# =============================================================================
do_cf_scan() {
  title "🔍 CLOUDFLARE CLEAN IP FINDER"
  ensure_base_tools || return 1
  local count workers top port
  count=$(askdef "  How many random Cloudflare IPs to test" "300")
  workers=$(askdef "  Parallel workers" "48")
  top=$(askdef "  Show top" "15")
  port=$(askdef "  TLS port (443/2053/2083/2087/2096/8443)" "443")
  [[ "$count" =~ ^[0-9]+$ && "$workers" =~ ^[0-9]+$ && "$top" =~ ^[0-9]+$ ]] && valid_port "$port" || { err "Invalid input"; return 1; }
  info "Scanning from THIS server's network (TCP + TLS handshake + HTTP 200, 3 tries per IP)..."
  mkdir -p "$BASE_DIR"
  python3 - "$count" "$workers" "$top" "$CF_RESULT" "$port" <<'PY'
import ipaddress, random, socket, ssl, sys, time
from concurrent.futures import ThreadPoolExecutor
n, workers, top, out, port = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
RANGES = ["173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
          "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17",
          "162.158.0.0/15", "104.16.0.0/13", "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22"]
nets = [ipaddress.ip_network(r) for r in RANGES]
weights = [x.num_addresses for x in nets]
ips = set()
while len(ips) < n:
    net = random.choices(nets, weights)[0]
    ips.add(str(net[random.randrange(1, net.num_addresses - 1)]))
ctx = ssl.create_default_context()
done = [0]
def test(ip):
    times, colo = [], "-"
    for _ in range(3):
        t0 = time.perf_counter()
        try:
            with socket.create_connection((ip, port), timeout=2) as s:
                with ctx.wrap_socket(s, server_hostname="speed.cloudflare.com") as ss:
                    ss.settimeout(3)
                    ss.sendall(b"GET /cdn-cgi/trace HTTP/1.1\r\nHost: speed.cloudflare.com\r\nConnection: close\r\n\r\n")
                    data = b""
                    while len(data) < 4096:
                        chunk = ss.recv(1024)
                        if not chunk:
                            break
                        data += chunk
                        if b"colo=" in data and b"\n" in data.split(b"colo=", 1)[1]:
                            break
            if b" 200 " in data.split(b"\r\n", 1)[0]:
                times.append((time.perf_counter() - t0) * 1000)
                for line in data.decode(errors="ignore").splitlines():
                    if line.startswith("colo="):
                        colo = line[5:]
        except Exception:
            pass
    done[0] += 1
    if done[0] % 20 == 0:
        print(f"\r    scanned {done[0]}/{n}", end="", flush=True)
    if not times:
        return None
    return (ip, int(sum(times) / len(times)), int(min(times)), 100 - len(times) * 100 // 3, colo)
with ThreadPoolExecutor(max_workers=workers) as ex:
    res = [r for r in ex.map(test, list(ips)) if r]
print()
res.sort(key=lambda r: (r[3], r[1]))
R, G, Y, W, N = "\033[1;31m", "\033[1;32m", "\033[1;33m", "\033[1;97m", "\033[0m"
cols = [3, 15, 8, 8, 6, 5]
head = ["#", "IP", "AVG", "BEST", "LOSS", "COLO"]
line = lambda l, m, r: R + l + m.join("─" * (c + 2) for c in cols) + r + N
cell = lambda t, w, c="": f"{R}│{N} {c}{t:<{w}}{N} "
print(line("┌", "┬", "┐"))
print("".join(cell(h, w, W) for h, w in zip(head, cols)) + R + "│" + N)
print(line("├", "┼", "┤"))
for i, (ip, avg, best, loss, colo) in enumerate(res[:top], 1):
    c = G if avg < 150 else (Y if avg < 300 else R)
    lc = G if loss == 0 else (Y if loss <= 34 else R)
    print(cell(str(i), 3) + cell(ip, 15, W) + cell(f"{avg}ms", 8, c) + cell(f"{best}ms", 8, c)
          + cell(f"{loss}%", 6, lc) + cell(colo, 5) + R + "│" + N)
print(line("└", "┴", "┘"))
print(f"  {G}{len(res)}{N} clean / {n} tested")
with open(out, "w") as f:
    f.write("# ip\tavg_ms\tbest_ms\tloss%\tcolo\n")
    for r in res:
        f.write("\t".join(map(str, r)) + "\n")
PY
  ok "Full list saved: ${CF_RESULT}"
}

# =============================================================================
# 9) BBR · GAMING · CPU SPREAD · DoH
# =============================================================================
optimize_network() {
  title "🎮 BBR · GAMING UDP BUFFERS · CPU SPREAD"
  mkdir -p "$OPT_DIR"
  local keys=(net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max
              net.core.rmem_default net.core.wmem_default net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min
              net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.netdev_max_backlog net.core.somaxconn
              net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing net.ipv4.tcp_slow_start_after_idle
              net.ipv4.tcp_notsent_lowat fs.file-max)
  local k
  if [[ ! -s "${OPT_DIR}/sysctl.before" ]]; then
    for k in "${keys[@]}"; do printf '%s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null | tr '\t' ' ')"; done >"${OPT_DIR}/sysctl.before"
    info "Original kernel values saved (used by Revert)"
  fi
  modprobe tcp_bbr 2>/dev/null || true
  local bbr="yes"
  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr || { bbr="no"; warn "Kernel has no BBR module; skipping BBR (other tweaks still applied)"; }
  {
    echo "# MAXNET6G network optimization (managed by maxnet)"
    [[ "$bbr" == "yes" ]] && printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n'
    cat <<'SYS'
# larger socket buffers = less UDP packet loss for gaming / QUIC / WireGuard
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
fs.file-max = 1048576
SYS
  } >"$SYSCTL_FILE"
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 && ok "Kernel tuning applied (${SYSCTL_FILE})" || warn "Some sysctl keys are not supported by this kernel (rest applied)"
  [[ "$bbr" == "yes" ]] && ok "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)  qdisc: $(sysctl -n net.core.default_qdisc)"

  # spread NIC interrupts + packet processing (RPS/XPS) across all cores
  command -v irqbalance >/dev/null 2>&1 || pkg_install irqbalance || true
  systemctl enable --now irqbalance >/dev/null 2>&1 && ok "irqbalance enabled (IRQs spread over all cores)"
  cat >"${OPT_DIR}/rps.sh" <<'RPS'
#!/usr/bin/env bash
# MAXNET6G: spread packet processing (RPS/RFS) across all CPU cores
n=$(nproc); ((n > 1)) || exit 0
mask=$(printf '%x' $(( (1 << n) - 1 )))
sysctl -qw net.core.rps_sock_flow_entries=32768 2>/dev/null
for dev in /sys/class/net/*; do
  name=${dev##*/}
  [[ "$name" == lo || "$name" == docker* || "$name" == veth* || "$name" == br-* ]] && continue
  for q in "$dev"/queues/rx-*; do
    [[ -w "$q/rps_cpus" ]] && echo "$mask" >"$q/rps_cpus" 2>/dev/null
    [[ -w "$q/rps_flow_cnt" ]] && echo 4096 >"$q/rps_flow_cnt" 2>/dev/null
  done
done
exit 0
RPS
  chmod 0755 "${OPT_DIR}/rps.sh" && "${OPT_DIR}/rps.sh"
  printf '# MAXNET6G optimize (managed by maxnet)\n@reboot root sleep 20 && %s >/dev/null 2>&1\n' "${OPT_DIR}/rps.sh" >"$OPT_CRON"
  chmod 0644 "$OPT_CRON"
  ok "RPS/RFS enabled on all NIC queues (persisted after reboot)"
  info "Psiphon containers are pinned to cores 1..N-1 at install (Core 0 stays free)"
}

setup_doh() {
  title "🔐 DNS-over-HTTPS (dnscrypt-proxy)"
  command -v apt-get >/dev/null 2>&1 || { err "DoH setup supports Debian/Ubuntu only"; return 1; }
  warn "This changes the system DNS resolver. It is verified and rolled back automatically if DNS breaks."
  yesno "  Continue?" || return 0
  pkg_install dnscrypt-proxy || { err "Could not install dnscrypt-proxy"; return 1; }
  mkdir -p "$OPT_DIR"
  local conf=/etc/dnscrypt-proxy/dnscrypt-proxy.toml
  [[ -f "$conf" && ! -f "${OPT_DIR}/dnscrypt-proxy.toml.bak" ]] && cp -a "$conf" "${OPT_DIR}/dnscrypt-proxy.toml.bak"
  local listen="listen_addresses = ['127.0.2.1:53']"
  systemctl list-unit-files 2>/dev/null | grep -q '^dnscrypt-proxy\.socket' && listen="listen_addresses = []"
  cat >"$conf" <<TOML
# MAXNET6G DoH (managed by maxnet)
${listen}
server_names = ['cloudflare', 'google', 'quad9-doh-ip4-port443-filter-pri']
doh_servers = true
dnscrypt_servers = false
require_dnssec = false
require_nolog = true
ipv6_servers = false
cache = true
cache_size = 4096

[sources.public-resolvers]
urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 72
TOML
  systemctl restart dnscrypt-proxy.socket >/dev/null 2>&1 || true
  systemctl restart dnscrypt-proxy >/dev/null 2>&1 || true
  sleep 3
  if systemctl is-active --quiet systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=127.0.2.1\nDomains=~.\n' >/etc/systemd/resolved.conf.d/99-maxnet-doh.conf
    systemctl restart systemd-resolved
  else
    [[ -f "${OPT_DIR}/resolv.conf.bak" ]] || cp -aL /etc/resolv.conf "${OPT_DIR}/resolv.conf.bak" 2>/dev/null
    rm -f /etc/resolv.conf; printf '# MAXNET6G DoH\nnameserver 127.0.2.1\n' >/etc/resolv.conf
  fi
  sleep 2
  if getent hosts cloudflare.com >/dev/null 2>&1 && getent hosts github.com >/dev/null 2>&1; then
    ok "DoH active: all DNS queries now go encrypted via dnscrypt-proxy (127.0.2.1)"
  else
    err "DNS test failed; rolling back"; revert_doh
  fi
}

revert_doh() {
  rm -f /etc/systemd/resolved.conf.d/99-maxnet-doh.conf
  systemctl is-active --quiet systemd-resolved && systemctl restart systemd-resolved
  if [[ -f "${OPT_DIR}/resolv.conf.bak" ]]; then rm -f /etc/resolv.conf; cp -a "${OPT_DIR}/resolv.conf.bak" /etc/resolv.conf; rm -f "${OPT_DIR}/resolv.conf.bak"; fi
  [[ -f "${OPT_DIR}/dnscrypt-proxy.toml.bak" ]] && cp -a "${OPT_DIR}/dnscrypt-proxy.toml.bak" /etc/dnscrypt-proxy/dnscrypt-proxy.toml
  systemctl disable --now dnscrypt-proxy dnscrypt-proxy.socket >/dev/null 2>&1 || true
  ok "DNS restored to previous configuration"
}

revert_optimize() {
  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    [[ -s "${OPT_DIR}/sysctl.before" ]] && sysctl -p "${OPT_DIR}/sysctl.before" >/dev/null 2>&1
    ok "Kernel values restored"
  fi
  rm -f "$OPT_CRON" "${OPT_DIR}/rps.sh" "${OPT_DIR}/sysctl.before"
  [[ -f /etc/systemd/resolved.conf.d/99-maxnet-doh.conf || -f "${OPT_DIR}/resolv.conf.bak" ]] && revert_doh
  ok "Optimizations reverted (RPS resets on next reboot)"
}

do_optimize_menu() {
  local c
  while true; do
    submenu "🎮 BBR · GAMING · CPU CORES" \
      "1) فعال‌سازی BBR + بافر UDP گیمینگ + پخش هسته‌ها" \
      "2) فعال‌سازی DNS-over-HTTPS (DoH)" \
      "3) بازگردانی همه تنظیمات (Revert)" \
      "0) بازگشت (Back)"
    c=$(ask "  ${RED}▶${N} Select: ")
    case "$c" in
      1) optimize_network ;;
      2) setup_doh ;;
      3) revert_optimize ;;
      0|"") return 0 ;;
      *) warn "Invalid option" ;;
    esac
    pause
  done
}

# =============================================================================
# 10) FAIL2BAN SHIELD (anti-scan)
# =============================================================================
f2b_install() {
  title "🔒 FAIL2BAN SHIELD"
  command -v fail2ban-client >/dev/null 2>&1 || { info "Installing fail2ban"; pkg_install fail2ban || { err "Install failed"; return 1; }; }
  refresh_ports
  local mode banaction sshports me backend logpath="" scan="no" backend_scan="auto" jm=""
  mode=$(fw_mode)
  case "$mode" in ufw) banaction="ufw" ;; *) banaction="iptables-multiport" ;; esac
  sshports=$(IFS=,; echo "${SSH_PORTS[*]}")
  me=${SSH_CLIENT:-}; me=${me%% *}
  if [[ -f /var/log/auth.log ]]; then backend="auto"; else backend="systemd"; pkg_install python3-systemd >/dev/null 2>&1 || true; fi

  # port-scan detection needs firewall "blocked packet" logs
  if [[ "$mode" == "ufw" ]]; then
    if ! ufw status verbose 2>/dev/null | grep -q '^Logging: on'; then
      yesno "  Enable UFW logging (low) so scanners can be detected? (rules are NOT changed)" && ufw logging low >/dev/null 2>&1
    fi
    ufw status verbose 2>/dev/null | grep -q '^Logging: on' && scan="yes"
    logpath="/var/log/ufw.log"; [[ -f "$logpath" ]] || logpath="/var/log/kern.log"
    printf '[Definition]\nfailregex = \\[UFW BLOCK\\] .* SRC=<HOST> .*DPT=\\d+\nignoreregex =\n' >"$F2B_FILTER"
  elif [[ "$mode" == "iptables" ]] && iptables -S INPUT 2>/dev/null | head -n1 | grep -q -- '-P INPUT DROP'; then
    # default-drop firewall: log what reaches the end of INPUT (i.e. packets that would be dropped)
    iptables -C INPUT -p tcp --syn -m limit --limit 30/min -m comment --comment "$FW_COMMENT-scanlog" -j LOG --log-prefix "MAXNET-SCAN " 2>/dev/null \
      || iptables -A INPUT -p tcp --syn -m limit --limit 30/min -m comment --comment "$FW_COMMENT-scanlog" -j LOG --log-prefix "MAXNET-SCAN "
    scan="yes"; logpath="/var/log/kern.log"
    printf '[Definition]\nfailregex = MAXNET-SCAN .* SRC=<HOST> .*DPT=\\d+\nignoreregex =\n' >"$F2B_FILTER"
  else
    warn "Firewall accepts everything by default: port-scan jail skipped to avoid banning real users (SSH + recidive still active)"
  fi
  if [[ "$scan" == "yes" && ! -f "$logpath" ]]; then backend_scan="systemd"; jm="journalmatch = _TRANSPORT=kernel"; fi

  cat >"$F2B_JAIL" <<JAIL
# MAXNET6G Fail2Ban Shield (managed by maxnet) - does not modify your own jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${me:-}
bantime  = 1h
findtime = 10m
maxretry = 5
banaction = ${banaction}
banaction_allports = ${banaction/iptables-multiport/iptables-allports}

[sshd]
enabled  = true
port     = ${sshports}
backend  = ${backend}
maxretry = 4
bantime  = 6h

[recidive]
enabled  = true
bantime  = 1w
findtime = 1d
maxretry = 3
JAIL
  if [[ "$scan" == "yes" ]]; then
    cat >>"$F2B_JAIL" <<JAIL

[maxnet-portscan]
enabled  = true
filter   = maxnet-portscan
logpath  = ${logpath}
backend  = ${backend_scan}
${jm}
findtime = 60
maxretry = 10
bantime  = 24h
action   = %(banaction_allports)s[name=maxnet-portscan]
JAIL
  fi
  systemctl enable fail2ban >/dev/null 2>&1
  if systemctl restart fail2ban && sleep 2 && fail2ban-client ping >/dev/null 2>&1; then
    ok "Fail2Ban Shield active: sshd(${sshports}) + recidive$([[ "$scan" == yes ]] && echo " + port-scan")"
    [[ -n "${me:-}" ]] && info "Your current IP ${me} is whitelisted"
  else
    err "Fail2Ban failed to start: journalctl -u fail2ban -n 30"; return 1
  fi
}

f2b_status() {
  command -v fail2ban-client >/dev/null 2>&1 || { warn "Fail2Ban not installed"; return 0; }
  local j
  for j in sshd recidive maxnet-portscan; do
    fail2ban-client status "$j" 2>/dev/null | sed -n 's/.*Currently banned:[[:space:]]*/'"$j"' banned: /p; s/.*Total banned:[[:space:]]*/  total: /p; s/.*Banned IP list:[[:space:]]*/  IPs: /p'
  done
}

f2b_remove() {
  rm -f "$F2B_JAIL" "$F2B_FILTER"
  while iptables -D INPUT -p tcp --syn -m limit --limit 30/min -m comment --comment "$FW_COMMENT-scanlog" -j LOG --log-prefix "MAXNET-SCAN " 2>/dev/null; do :; done
  command -v fail2ban-client >/dev/null 2>&1 && systemctl restart fail2ban >/dev/null 2>&1
  ok "MAXNET6G jails removed (fail2ban package and your own jails kept)"
}

do_f2b_menu() {
  local c ip
  while true; do
    submenu "🔒 FAIL2BAN SHIELD · ANTI-SCAN" \
      "1) نصب و فعال‌سازی (Install & Enable)" \
      "2) وضعیت و لیست آی‌پی‌های بن‌شده (Status)" \
      "3) آزاد کردن یک آی‌پی (Unban IP)" \
      "4) غیرفعال‌سازی جیل‌های MAXNET6G (Remove)" \
      "0) بازگشت (Back)"
    c=$(ask "  ${RED}▶${N} Select: ")
    case "$c" in
      1) f2b_install ;;
      2) f2b_status ;;
      3) ip=$(ask "  IP to unban: "); [[ -n "$ip" ]] && fail2ban-client unban "$ip" >/dev/null 2>&1 && ok "Unbanned $ip" || warn "Not banned / invalid" ;;
      4) f2b_remove ;;
      0|"") return 0 ;;
      *) warn "Invalid option" ;;
    esac
    pause
  done
}

# =============================================================================
# 11) BACKUP & RESTORE
# =============================================================================
do_backup() {  # $1 optional output file
  local out=${1:-}
  [[ -d "$BASE_DIR" ]] || { err "Nothing to back up"; return 1; }
  [[ -z "$out" ]] && out=$(askdef "  Backup file" "/root/maxnet6g-backup.tar.gz")
  [[ "$out" == *.tar.gz ]] || out="${out%/}/maxnet6g-backup.tar.gz"
  printf 'version=%s\ndate=%s\nhost=%s\n' "$VERSION" "$(date '+%F %T')" "$(hostname)" >"${BASE_DIR}/backup.manifest"
  umask 077
  tar -czf "$out" -C / \
    --exclude="${BASE_DIR#/}/bin" --exclude="${BASE_DIR#/}/build" --exclude="${BASE_DIR#/}/data" \
    --exclude="${BASE_DIR#/}/health" --exclude="${BASE_DIR#/}/backups" --exclude="${BASE_DIR#/}/tunnel/gost" \
    "${BASE_DIR#/}" 2>/dev/null
  umask 022
  chmod 600 "$out"
  ok "Backup created: ${out} ($(du -h "$out" | cut -f1)) · contains ports, tunnel config and bot token: keep it private"
}

do_restore() {  # $1 optional file
  local f=${1:-}
  [[ -z "$f" ]] && f=$(askdef "  Backup file to restore" "/root/maxnet6g-backup.tar.gz")
  [[ -f "$f" ]] || { err "File not found: $f"; return 1; }
  if tar -tzf "$f" 2>/dev/null | grep -vqE "^${BASE_DIR#/}(/|$)"; then err "Archive contains unexpected paths; refusing"; return 1; fi
  tar -tzf "$f" 2>/dev/null | grep -q "instances.tsv\|bot.env\|tunnel.env" || { err "Not a MAXNET6G backup"; return 1; }
  tar -xzf "$f" -C / && ok "Configuration restored to ${BASE_DIR}"
  [[ -f "${BASE_DIR}/backup.manifest" ]] && info "Backup from: $(tr '\n' ' ' <"${BASE_DIR}/backup.manifest")"
  if [[ -s "$STATE_FILE" ]]; then
    info "Re-deploying Psiphon locations with the SAME ports from the backup"
    do_install
  fi
  if [[ -s "$BOT_ENV" ]]; then install_bot_service; fi
  if [[ -s "$TUN_ENV" ]]; then
    fetch_gost && write_tunnel_service
    local ROLE LISTEN_PORT USER PASS REMOTE PORTS UDP p fw=()
    # shellcheck disable=SC1090
    source "$TUN_ENV"
    if [[ "$ROLE" == "foreign" ]]; then fw=("$LISTEN_PORT"); else for p in ${PORTS//,/ }; do fw+=("$p"); [[ "$UDP" == yes ]] && fw+=("${p}/udp"); done; fi
    refresh_ports; fw_open_ports "${fw[@]}"
  fi
  ok "Restore complete"
}

do_backup_menu() {
  local c
  submenu "💾 BACKUP & RESTORE" \
    "1) ساخت بکاپ (Create maxnet6g-backup.tar.gz)" \
    "2) بازگردانی از بکاپ (Restore)" \
    "0) بازگشت (Back)"
  c=$(ask "  ${RED}▶${N} Select: ")
  case "$c" in
    1) do_backup ;;
    2) with_lock do_restore ;;
    *) return 0 ;;
  esac
}

# =============================================================================
# 12) UNINSTALL
# =============================================================================
do_uninstall() {
  local interactive=${1:-yes} ans
  title "🗑  UNINSTALL & CLEANUP"
  if [[ "$interactive" == "yes" ]]; then
    ans=$(ask "  ${RED}Remove all psiphon-* containers, bot, tunnel and project files? type 'yes': ${N}")
    [[ "$ans" == "yes" ]] || { info "Cancelled"; return 0; }
  fi
  rm -f "$CRON_FILE"
  pkill -f "$WATCHDOG" 2>/dev/null || true
  if crontab -l 2>/dev/null | grep -q 'psiphon-watchdog'; then
    crontab -l 2>/dev/null | grep -v 'psiphon-watchdog' | crontab - || true
  fi
  command -v docker >/dev/null 2>&1 && { remove_project_containers; docker image rm "$IMAGE" >/dev/null 2>&1 || true; }
  [[ -f "$BOT_UNIT" ]] && remove_bot
  [[ -f "$TUN_UNIT" || -d "$TUN_DIR" ]] && remove_tunnel

  if [[ "$interactive" == "yes" ]]; then
    if [[ -s "$FW_PORTS_FILE" ]] && yesno "  Remove the firewall rules this project added ($(tr '\n' ' ' <"$FW_PORTS_FILE"))? Keep them if Xray uses these ports"; then
      local -a items=(); mapfile -t items <"$FW_PORTS_FILE"; fw_remove_ports "${items[@]}"; ok "Removed only this project's rules"
    fi
    [[ -f "$SYSCTL_FILE" ]] && yesno "  Revert BBR/gaming/DoH optimizations?" && revert_optimize
    [[ -f "$F2B_JAIL" ]] && yesno "  Remove MAXNET6G Fail2Ban jails?" && f2b_remove
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
  print_logo
  box_top
  box_row "${BRAND} ULTIMATE MANAGER  v${VERSION}" "$W" yes
  box_mid
  box_row " 1) 🚀 نصب و راه‌اندازی کامل (Install All Locations)"
  box_row " 2) 🔄 به‌روزرسانی هوشمند (Smart Update - Keep Ports)"
  box_row " 3) 📊 بررسی لوکیشن‌ها، پینگ و تست سرعت (Status & Ping)"
  box_row " 4) ⚡ تعویض فوری IP یک لوکیشن خاص (Renew Node IP)"
  box_row " 5) 🔗 تزریق خودکار Outboundها به دیتابیس 3X-UI"
  box_row " 6) 🤖 ربات تلگرام با دکمه‌های شیشه‌ای سبز (Telegram Bot)"
  box_row " 7) 🌉 راه‌اندازی تونل ایران به خارج (Auto Tunnel Bridge)"
  box_row " 8) 🔍 اسکنر آی‌پی تمیز کلودفلر (Cloudflare IP Finder)"
  box_row " 9) 🎮 بهینه‌سازی BBR، گیمینگ و پخش هسته‌های CPU"
  box_row "10) 🔒 سیستم ضد اسکن و امنیت پورت‌ها (Fail2Ban Shield)"
  box_row "11) 💾 بکاپ و بازگردانی تنظیمات (Backup & Restore)"
  box_row "12) 🗑 حذف کامل و پاکسازی (Uninstall)"
  box_row " 0) ❌ خروج (Exit)"
  box_bot
}

main_menu() {
  local choice
  while true; do
    show_menu
    choice=$(ask "  ${RED}▶${N} ${W}Select an option [0-12]: ${N}")
    case "$choice" in
      1)  with_lock do_install; pause ;;
      2)  with_lock do_update;  pause ;;
      3)  do_status yes;        pause ;;
      4)  do_renew_menu;        pause ;;
      5)  with_lock do_xui_sync yes | grep -v '^RESULT|'; pause ;;
      6)  do_bot_menu ;;
      7)  do_tunnel_menu ;;
      8)  do_cf_scan;           pause ;;
      9)  do_optimize_menu ;;
      10) do_f2b_menu ;;
      11) do_backup_menu;       pause ;;
      12) with_lock do_uninstall yes
          [[ -x "$CLI_PATH" ]] || exit 0
          pause ;;
      0)  exit 0 ;;
      *)  warn "Invalid option"; sleep 1 ;;
    esac
  done
}

main() {
  require_root
  mkdir -p "$(dirname "$INSTALL_LOG")"
  log "---- maxnet v${VERSION} args=$*"
  local a; for a in "$@"; do [[ "$a" == "--plain" ]] && PLAIN="yes"; done
  if [[ "$PLAIN" == "yes" ]]; then RED=""; G=""; Y=""; C=""; W=""; DIM=""; BOLD=""; N=""; fi
  if [[ -z "${1:-}" ]]; then install_cli; sleep 1; else install_cli >/dev/null 2>&1 || true; fi
  [[ "$PLAIN" == "no" && -n "${1:-}" && "$1" != "-h" && "$1" != "--help" ]] && print_logo
  case "${1:-}" in
    --install)   with_lock do_install ;;
    --update)    with_lock do_update ;;
    --status)    do_status no ;;
    --renew)     [[ -n "${2:-}" && "${2:-}" != --* ]] || { err "Usage: maxnet --renew US"; exit 1; }; renew_node "$2" ;;
    --xui-sync)  with_lock do_xui_sync no ;;
    --backup)    do_backup "${2:-/root/maxnet6g-backup.tar.gz}" ;;
    --restore)   [[ -n "${2:-}" ]] || { err "Usage: maxnet --restore file.tar.gz"; exit 1; }; with_lock do_restore "$2" ;;
    --uninstall) with_lock do_uninstall no ;;
    -h|--help)   sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' ;;
    "")          main_menu ;;
    *)           err "Unknown option: $1 (use --help)"; exit 1 ;;
  esac
}

main "$@"
