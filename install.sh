#!/usr/bin/env bash
# =============================================================================
#  MAXNET6G ULTIMATE MANAGER · Psiphon Multi-Instance CLI  (v6.0.0)
#  Developer: mohsenakbarinia
#
#  sudo bash install.sh           -> interactive bilingual menu (installs the `maxnet` command)
#  maxnet                         -> open the menu from anywhere
#
#  Non-interactive:
#   maxnet --install | --update | --status | --repair | --uninstall
#   maxnet --renew US             renew exit IP of one location
#   maxnet --xui-sync             inject 22 SOCKS5 outbounds into 3X-UI
#   maxnet --backup [file]        maxnet --restore <file>
#
#  SELF-HEALING
#   * Every package operation first releases stale apt/dpkg locks, runs
#     `dpkg --configure -a` + `apt-get check`, and falls back to `apt-get install -f -y`.
#   * Every heavy network step (apt, Docker pulls/builds, binary downloads) retries 3x.
#
#  SAFETY GUARANTEES
#   * Never runs `ufw reset`, `iptables -F`, or changes default firewall policies on its own.
#   * Only touches Docker containers whose name starts with "psiphon-".
#   * SOCKS5 ports are fixed: US=1081 ... AU=1102, bound to 127.0.0.1 only.
#   * Smart Update never moves ports and never restarts healthy containers.
#   * SSH port(s) are never touched by any firewall / Fail2Ban action.
#
#  ENV OVERRIDES
#   HEALTH_TIMEOUT=150  PSIPHON_BINARY_URL=...  PSIPHON_BINARY_PATH=/local/bin  BASE_IMAGE=debian:stable-slim
#   XUI_DB=/etc/x-ui/x-ui.db  GOST_URL=...  GOST_PATH=/local/gost  BACKHAUL_URL=...  BACKHAUL_PATH=/local/backhaul
# =============================================================================
set -uo pipefail

_loc=$(locale -a 2>/dev/null | grep -iE '^(c|en_us)\.utf-?8$' | head -n1)
[[ -n "$_loc" ]] && export LC_ALL="$_loc"
unset _loc

# ----------------------------- constants -------------------------------------
readonly VERSION="6.0.0"
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
readonly BH_BIN="${TUN_DIR}/backhaul"
readonly BH_CONF="${TUN_DIR}/backhaul.toml"
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
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
readonly LEGACY_DIRS=(/opt/psiphon-manager /etc/psiphon-manager /var/lib/psiphon-manager /usr/local/lib/psiphon-manager)
readonly LEGACY_BIN="/opt/psiphon-manager/bin/psiphon-tunnel-core"
readonly MAX_RETRY=3

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-150}"
PSIPHON_BINARY_URL="${PSIPHON_BINARY_URL:-https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64}"
PSIPHON_BINARY_PATH="${PSIPHON_BINARY_PATH:-}"
BASE_IMAGE="${BASE_IMAGE:-debian:stable-slim}"
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

STEP_ACTIVE=0
INTERACTIVE="no"
log()   { ((STEP_ACTIVE)) && return 0; { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$INSTALL_LOG"; } 2>/dev/null || true; }
info()  { printf '%s[i]%s %s\n' "$C" "$N" "$*"; log "[i] $*"; }
ok()    { printf '%s[✓]%s %s\n' "$G" "$N" "$*"; log "[ok] $*"; }
warn()  { printf '%s[!]%s %s\n' "$Y" "$N" "$*"; log "[warn] $*"; }
err()   { printf '%s[✗]%s %s\n' "$RED" "$N" "$*" >&2; log "[err] $*"; }

# ---- compact bilingual step line:  [+] فارسی | English... [✔]
# Runs in the CURRENT shell (state survives); full output goes to the log file only.
step() {  # step "متن فارسی" "English text" command [args...]
  local fa=$1 en=$2 rc sp="" before=0 label sink=$INSTALL_LOG
  shift 2
  label="${fa} | ${en}..."
  { : >>"$sink"; } 2>/dev/null || sink=/dev/null
  before=$(wc -l <"$sink" 2>/dev/null || echo 0)
  printf '%s [step] %s\n' "$(date '+%F %T')" "$en" >>"$sink" 2>/dev/null
  if [[ "$PLAIN" != "yes" && -t 1 ]]; then
    printf '%s[+]%s %s  ' "$RED" "$N" "$label"
    ( trap 'exit 0' TERM
      while :; do for c in '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'; do printf '%s\b' "$c"; sleep 0.12; done; done ) &
    sp=$!
  fi
  STEP_ACTIVE=1
  "$@" >>"$sink" 2>&1 </dev/null
  rc=$?
  STEP_ACTIVE=0
  if [[ -n "$sp" ]]; then kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null; printf '\r\033[K'; fi
  if ((rc == 0)); then
    printf '%s[+]%s %s %s[✔]%s\n' "$RED" "$N" "$label" "$G" "$N"
  else
    printf '%s[+]%s %s %s[✘]%s\n' "$RED" "$N" "$label" "$RED" "$N"
    tail -n +"$((before + 1))" "$sink" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
      | grep -E '\[✗\]|\[!\]|[Ee]rror|[Ff]ailed' | tail -n 3 | sed "s/^/      ${DIM}↳ /;s/\$/${N}/"
    printf '      %s↳ جزئیات کامل | Full log: %s%s\n' "$DIM" "$INSTALL_LOG" "$N"
  fi
  return $rc
}

# ---- generic retry:  retry <attempts> <base-delay> cmd...   (RETRY_FIX=<func> runs between attempts)
retry() {
  local n=$1 d=$2 i
  shift 2
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    ((i < n)) || break
    warn "Attempt ${i}/${n} failed (${1##*/}); retrying in $((d * i))s"
    if [[ -n "${RETRY_FIX:-}" ]]; then "$RETRY_FIX" >/dev/null 2>&1 || true; fi
    sleep $((d * i))
  done
  err "Failed after ${n} attempts: ${1##*/} ${2:-}"
  return 1
}

# ---- resumable download with 3 retries (never leaves a half file at the destination)
_dl_once() {  # $1 url  $2 out
  local rc
  curl -fsSL --connect-timeout 15 --max-time 300 -C - -o "${2}.part" "$1"
  rc=$?
  if ((rc == 0)) && [[ -s "${2}.part" ]]; then mv -f "${2}.part" "$2"; return 0; fi
  ((rc == 33 || rc == 22 || rc == 36)) && rm -f "${2}.part"
  return 1
}
download() {  # download <url> <out>
  rm -f "${2}.part"
  retry "$MAX_RETRY" 5 _dl_once "$1" "$2"
  local rc=$?
  rm -f "${2}.part"
  return $rc
}

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
yesno() { local v; v=$(ask "$1 [y/N]: "); [[ "$v" =~ ^([Yy]([Ee][Ss])?|بله|آره)$ ]]; }
pause() { read -r -p "  ${DIM}↩ برای بازگشت Enter بزنید | Press Enter to return...${N}" _ </dev/tty 2>/dev/null || true; }

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
    if command -v flock >/dev/null 2>&1 && ! flock -n 9; then err "عملیات دیگری در حال اجراست | Another maxnet operation is running"; exit 1; fi
    "$@"
  )
}

# =============================================================================
# PACKAGE REPAIR & AUTO-FIX LAYER (apt/dpkg locks, half-installed packages, retries)
# =============================================================================
readonly APT_LOCKS=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
readonly APT_BASE_PKGS=(ca-certificates curl jq net-tools iproute2 util-linux python3 tar gzip cron psmisc procps)
readonly RPM_BASE_PKGS=(ca-certificates curl jq net-tools iproute util-linux python3 tar gzip cronie psmisc procps-ng)
APT_UPDATED=0

has_apt() { command -v apt-get >/dev/null 2>&1; }
rpm_pm()  { if command -v dnf >/dev/null 2>&1; then echo dnf; elif command -v yum >/dev/null 2>&1; then echo yum; fi; }

apt_run() {
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
    apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    -o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 "$@" >>"$INSTALL_LOG" 2>&1
}

pkg_installed() {
  if has_apt; then dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
  else rpm -q "$1" >/dev/null 2>&1; fi
}
apt_available() { apt-cache show "$1" >/dev/null 2>&1; }

apt_busy() {
  local l
  if command -v fuser >/dev/null 2>&1; then
    for l in "${APT_LOCKS[@]}"; do [[ -e "$l" ]] && fuser "$l" >/dev/null 2>&1 && return 0; done
    return 1
  fi
  pgrep -x 'apt|apt-get|aptitude|dpkg|unattended-upgr' >/dev/null 2>&1
}

apt_release_locks() {  # wait politely, then stop timers, then kill stale holders, then drop orphan lock files
  has_apt || return 0
  local i l
  for ((i = 0; i < 36; i++)); do
    apt_busy || break
    ((i == 0)) && warn "apt/dpkg is locked by another process; waiting (max 3 min)"
    sleep 5
  done
  if apt_busy; then
    warn "Stopping unattended-upgrades / apt-daily timers holding the lock"
    systemctl stop unattended-upgrades.service apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true
    for ((i = 0; i < 12; i++)); do apt_busy || break; sleep 5; done
  fi
  if apt_busy; then
    warn "Killing stale apt/dpkg processes that still hold the lock"
    if command -v fuser >/dev/null 2>&1; then
      for l in "${APT_LOCKS[@]}"; do [[ -e "$l" ]] && fuser -k -TERM "$l" >/dev/null 2>&1; done
      sleep 3
      for l in "${APT_LOCKS[@]}"; do [[ -e "$l" ]] && fuser -k -KILL "$l" >/dev/null 2>&1; done
    else
      pkill -TERM -x 'apt|apt-get|aptitude|unattended-upgr' >/dev/null 2>&1; sleep 3
      pkill -KILL -x 'apt|apt-get|aptitude|unattended-upgr' >/dev/null 2>&1
    fi
    sleep 2
  fi
  if ! apt_busy; then
    for l in "${APT_LOCKS[@]}"; do [[ -e "$l" ]] && rm -f "$l"; done
  fi
  return 0
}

apt_heal() {  # clears locks, finishes interrupted dpkg runs, fixes broken dependencies
  has_apt || { local pm; pm=$(rpm_pm); [[ -n "$pm" ]] && { "$pm" clean all >/dev/null 2>&1; rpm --rebuilddb >/dev/null 2>&1; }; return 0; }
  apt_release_locks
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold >>"$INSTALL_LOG" 2>&1 || true
  if ! apt-get check >>"$INSTALL_LOG" 2>&1; then
    warn "Broken dependencies detected → apt-get install -f -y"
    apt_run install -f || true
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold >>"$INSTALL_LOG" 2>&1 || true
  fi
  return 0
}

apt_update() {
  has_apt || return 0
  ((APT_UPDATED)) && return 0
  if ! RETRY_FIX=apt_release_locks retry "$MAX_RETRY" 5 apt_run update; then
    warn "apt index looks corrupted → cleaning partial lists and retrying once"
    rm -rf /var/lib/apt/lists/partial/* 2>/dev/null
    apt-get clean >/dev/null 2>&1 || true
    apt_run update || warn "apt-get update still failing; continuing with the cached index"
  fi
  APT_UPDATED=1
  return 0
}

apt_try() {  # one install attempt; on failure it repairs dpkg so the next attempt starts clean
  apt_run install "$@" && return 0
  warn "Install of '$*' failed → dpkg --configure -a + apt-get install -f -y"
  apt_heal
  return 1
}

pkg_install() {  # pkg_install pkg... ; installs one by one, 3 attempts each, auto-repair between attempts
  local p pm failed=()
  (($#)) || return 0
  if has_apt; then
    apt_heal
    apt_update
    for p in "$@"; do
      pkg_installed "$p" && continue
      if ! apt_available "$p"; then warn "Package '$p' is not in the repositories"; failed+=("$p"); continue; fi
      retry "$MAX_RETRY" 5 apt_try "$p" || failed+=("$p")
    done
  else
    pm=$(rpm_pm)
    [[ -n "$pm" ]] || { err "No supported package manager (apt/dnf/yum)"; return 1; }
    for p in "$@"; do
      pkg_installed "$p" && continue
      RETRY_FIX=apt_heal retry "$MAX_RETRY" 5 "$pm" install -y -q "$p" >>"$INSTALL_LOG" 2>&1 || failed+=("$p")
    done
  fi
  ((${#failed[@]})) && { err "Could not install: ${failed[*]}"; return 1; }
  return 0
}

repair_broken_pkgs() {  # reinstall every half-installed / reinst-required package
  has_apt || { apt_heal; return 0; }
  apt_heal
  local -a broken=()
  mapfile -t broken < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null \
    | awk '$1 !~ /^[ih]i$/ && $1 ~ /^[ih]/ {print $2}')
  if ((${#broken[@]} == 0)); then ok "No half-installed packages found"; return 0; fi
  warn "Reinstalling damaged packages: ${broken[*]}"
  apt_update
  RETRY_FIX=apt_heal retry "$MAX_RETRY" 5 apt_run install --reinstall "${broken[@]}" || {
    local p; for p in "${broken[@]}"; do RETRY_FIX=apt_heal retry 2 3 apt_run install --reinstall "$p" || true; done; }
  apt_heal
  ok "Package database repaired"
}

ensure_base_tools() {
  local need=() p c
  if has_apt; then for p in "${APT_BASE_PKGS[@]}"; do pkg_installed "$p" || need+=("$p"); done
  else for p in "${RPM_BASE_PKGS[@]}"; do pkg_installed "$p" || need+=("$p"); done; fi
  ((${#need[@]})) || return 0
  info "Installing missing packages: ${need[*]}"
  if ! pkg_install "${need[@]}"; then
    for c in curl python3 tar ss flock; do
      command -v "$c" >/dev/null 2>&1 || { err "Essential tool missing: $c"; return 1; }
    done
    warn "Some optional packages failed (${need[*]}); essential tools are present, continuing"
  fi
  return 0
}

ensure_ufw() {  # installs ufw (never enables it silently); skips when it would conflict
  command -v ufw >/dev/null 2>&1 && return 0
  has_apt || return 0
  if pkg_installed iptables-persistent || pkg_installed netfilter-persistent || pkg_installed firewalld; then
    info "iptables-persistent/firewalld present → ufw skipped to avoid package conflicts (iptables mode)"
    return 0
  fi
  pkg_install ufw || warn "ufw could not be installed; iptables mode will be used"
  return 0
}

# ----------------------------- docker health ----------------------------------
docker_ok() { docker info >/dev/null 2>&1; }

docker_wait() { local i; for ((i = 0; i < ${1:-30}; i++)); do docker_ok && return 0; sleep 1; done; return 1; }

docker_heal() {  # restart the daemon step by step until it answers
  command -v docker >/dev/null 2>&1 || return 1
  docker_ok && return 0
  warn "Docker daemon not responding → restarting containerd + docker"
  if has_systemd; then
    systemctl reset-failed docker.service docker.socket containerd.service >/dev/null 2>&1 || true
    systemctl enable containerd docker >/dev/null 2>&1 || true
    systemctl restart containerd >/dev/null 2>&1 || true
    systemctl restart docker.socket >/dev/null 2>&1 || true
    systemctl restart docker >/dev/null 2>&1 || true
  else
    service docker restart >/dev/null 2>&1 || true
  fi
  docker_wait 30 && { ok "Docker daemon is back"; return 0; }
  warn "Removing stale docker pid/socket and trying again"
  rm -f /var/run/docker.pid /run/docker.pid 2>/dev/null
  if has_systemd; then systemctl restart docker >/dev/null 2>&1 || true; else service docker restart >/dev/null 2>&1 || true; fi
  docker_wait 40
}

docker_reinstall() {
  has_apt || return 1
  local pk list=()
  for pk in docker-ce docker-ce-cli containerd.io docker.io containerd runc; do pkg_installed "$pk" && list+=("$pk"); done
  ((${#list[@]})) || return 1
  warn "Reinstalling Docker packages: ${list[*]}"
  apt_heal; apt_update
  RETRY_FIX=apt_heal retry "$MAX_RETRY" 5 apt_run install --reinstall "${list[@]}"
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    docker_heal && return 0
    docker_reinstall && docker_heal && return 0
    err "Docker is installed but the daemon cannot start (journalctl -u docker -n 50)"
    return 1
  fi
  has_apt && { apt_heal; apt_update; }
  if has_apt && ! pkg_installed containerd.io && apt_available docker.io; then
    info "Installing docker.io from the distro repository"
    pkg_install docker.io || true
    if command -v docker >/dev/null 2>&1 && apt_available docker-buildx; then pkg_install docker-buildx >/dev/null 2>&1 || true; fi
  fi
  if ! command -v docker >/dev/null 2>&1; then
    info "Installing Docker via get.docker.com"
    local tmp; tmp=$(mktemp)
    if download https://get.docker.com "$tmp"; then
      RETRY_FIX=apt_heal retry "$MAX_RETRY" 10 sh "$tmp" >>"$INSTALL_LOG" 2>&1 || true
    fi
    rm -f "$tmp"
  fi
  command -v docker >/dev/null 2>&1 || { err "Docker installation failed"; return 1; }
  docker_heal || { err "Docker daemon is not running"; return 1; }
}

ensure_deps() {
  ensure_base_tools || return 1
  ensure_ufw
  install_docker || return 1
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
        && ok "دستور میانبر ثبت شد | Command installed: type ${BOLD}maxnet${N} anywhere"
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
  if ! download "$url" "${bin}.new"; then
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
FROM __BASE_IMAGE__
RUN for i in 1 2 3; do apt-get update && break; sleep 5; done \
 && for i in 1 2 3; do apt-get install -y --no-install-recommends ca-certificates && break; sleep 5; done \
 && rm -rf /var/lib/apt/lists/*
COPY psiphon-tunnel-core /usr/local/bin/psiphon-tunnel-core
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /usr/local/bin/psiphon-tunnel-core /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOD
  sed -i "s|__BASE_IMAGE__|${BASE_IMAGE}|" "${BUILD_DIR}/Dockerfile"
  local hash
  hash=$(cat "${BUILD_DIR}/Dockerfile" "${BUILD_DIR}/entrypoint.sh" "${BUILD_DIR}/psiphon-tunnel-core" | sha256sum | cut -c1-16)
  if [[ "$(docker image inspect -f '{{index .Config.Labels "maxnet.hash"}}' "$IMAGE" 2>/dev/null || true)" == "$hash" ]]; then
    info "Docker image is up to date"; return 0
  fi
  if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    info "Pulling base image ${BASE_IMAGE}"
    RETRY_FIX=docker_heal retry "$MAX_RETRY" 10 docker pull -q "$BASE_IMAGE" >>"$INSTALL_LOG" 2>&1 \
      || { err "Could not pull ${BASE_IMAGE} (Docker Hub blocked? set BASE_IMAGE=mirror/debian:stable-slim)"; return 1; }
  fi
  info "Building Docker image ${IMAGE}"
  RETRY_FIX=docker_heal retry "$MAX_RETRY" 10 docker build -q --label "maxnet.hash=${hash}" -t "$IMAGE" "$BUILD_DIR" >>"$INSTALL_LOG" 2>&1 \
    || { err "Image build failed"; return 1; }
  ok "Image built"
}

run_container() {  # $1 = cc   (uses SOCKS_OF / CPU_OF)
  local cc=$1 name="${PREFIX}${1,,}" dir="${DATA_DIR}/${1,,}" cpu=${CPU_OF[$1]:--}
  [[ "$name" == ${PREFIX}* ]] || return 1
  local -a cpuarg=()
  [[ "$cpu" =~ ^[0-9]+$ ]] && (( cpu < $(nproc) )) && cpuarg=(--cpuset-cpus "$cpu")
  mkdir -p "$dir" && chown -R "${CONTAINER_UID}:${CONTAINER_UID}" "$dir"
  docker rm -f "$name" >/dev/null 2>&1 || true
  RETRY_FIX=docker_heal retry "$MAX_RETRY" 3 _docker_run_node "$name" "$cc" "$dir" "${cpuarg[@]}"
}

_docker_run_node() {  # $1 name $2 cc $3 dir [cpuargs...]
  local name=$1 cc=$2 dir=$3; shift 3
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
    --memory="${CONTAINER_MEM}" --memory-swap="${CONTAINER_MEM}" \
    "$@" \
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
  if [[ "$mode" != "ufw" ]] && command -v ufw >/dev/null 2>&1; then  # pre-register so enabling UFW later keeps them open
    for item in "$@"; do
      p=${item%/*}; proto=tcp; [[ "$item" == */udp ]] && proto=udp
      valid_port "$p" && ! in_list "$p" "${SSH_PORTS[@]}" && ufw allow "${p}/${proto}" comment "$FW_COMMENT" >/dev/null 2>&1
    done
  fi
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
      *) command -v ufw >/dev/null 2>&1 && ufw delete allow "${p}/${proto}" >/dev/null 2>&1 ;;&
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
    ((STEP_ACTIVE)) || printf '\r    %sconnected: %d/%d  (%ds)%s   ' "$DIM" $((total - ${#pending[@]})) "$total" "$SECONDS" "$N"
    ((${#pending[@]})) && sleep 6
  done
  ((STEP_ACTIVE)) || echo
  info "Connected: $((total - ${#pending[@]}))/${total}"
  return 0
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
# 1) FULL INSTALLATION
# =============================================================================
declare -A PREV_IN=()
declare -a STARTED=() FWPORTS=() FREE_PORTS=() BUSY_CAND=()

collect_prev_inbounds() {
  load_state || true
  PREV_IN=()
  local cc a b c d
  for cc in "${!INBOUND_OF[@]}"; do PREV_IN[$cc]=${INBOUND_OF[$cc]}; done
  if [[ -r /etc/psiphon-manager/instances.tsv ]]; then
    while IFS=$'\t' read -r a b c d _; do
      [[ -z "${a:-}" || "$a" == \#* || -z "${CNAME[$a]:-}" ]] && continue
      [[ -z "${PREV_IN[$a]:-}" && "${d:--}" != "-" ]] && PREV_IN[$a]=$d
    done </etc/psiphon-manager/instances.tsv
  fi
  return 0
}

install_prepare() {
  mkdir -p "$BASE_DIR" "$DATA_DIR" "$HEALTH_DIR"
  rm -f "$CRON_FILE"
  pkill -f "$WATCHDOG" 2>/dev/null || true
  remove_project_containers
  return 0
}

scan_ports() {
  local p
  refresh_ports
  FREE_PORTS=(); BUSY_CAND=()
  for p in "${CANDIDATE_PORTS[@]}"; do if port_free "$p"; then FREE_PORTS+=("$p"); else BUSY_CAND+=("$p"); fi; done
  info "SSH port(s) protected: ${SSH_PORTS[*]}"
  ((${#BUSY_CAND[@]})) && info "Occupied candidate ports (untouched): ${BUSY_CAND[*]}"
  info "Free inbound candidates: ${#FREE_PORTS[@]} / ${#CANDIDATE_PORTS[@]}"
  return 0
}

deploy_all() {
  local cc sp
  INBOUND_OF=(); IN_STATE=(); CPU_OF=(); STARTED=(); FWPORTS=()
  for cc in "${COUNTRIES[@]}"; do
    sp=${SOCKS_OF[$cc]}
    if ! port_free "$sp"; then
      err "${cc}: SOCKS5 port ${sp} is used by another service; location skipped (port NOT changed)"
      continue
    fi
    if [[ -n "${PREV_IN[$cc]:-}" && "${PREV_IN[$cc]}" != "-" ]]; then INBOUND_OF[$cc]=${PREV_IN[$cc]}
    else INBOUND_OF[$cc]=$(next_free_inbound); fi
    CPU_OF[$cc]=$(cpu_for "$cc")
    if run_container "$cc"; then
      IN_STATE[$cc]=1; STARTED+=("$cc")
      [[ "${INBOUND_OF[$cc]}" != "-" ]] && FWPORTS+=("${INBOUND_OF[$cc]}")
      info "${cc} socks5://127.0.0.1:${sp} inbound:${INBOUND_OF[$cc]} cpu:${CPU_OF[$cc]}"
    else
      err "Failed to start ${PREFIX}${cc,,}"; unset "INBOUND_OF[$cc]" "CPU_OF[$cc]"
    fi
  done
  save_state
  ((${#STARTED[@]})) || { err "No container could be started"; return 1; }
  ok "State saved (${#STARTED[@]} locations)"
}

cleanup_legacy() {
  local d
  for d in "${LEGACY_DIRS[@]}"; do [[ -d "$d" ]] && rm -rf "$d" && info "Cleaned legacy dir $d"; done
  return 0
}

finalize_install() { install_watchdog && cleanup_legacy; }

ufw_safe_enable() {  # allow SSH + every port already listening publicly, THEN enable (no reset, no flush)
  local p proto
  refresh_ports
  for p in "${SSH_PORTS[@]}"; do ufw allow "${p}/tcp" comment "maxnet-ssh" >/dev/null 2>&1 || true; done
  while read -r proto p; do
    valid_port "$p" || continue
    ufw allow "${p}/${proto}" comment "maxnet-keep" >/dev/null 2>&1 || true
  done < <(ss -tuln 2>/dev/null | awk 'NR>1 {
      a=$5; p=a; sub(/.*:/, "", p); h=a; sub(/:[^:]*$/, "", h)
      if (h ~ /^127\./ || h ~ /^\[?::1\]?$/ || h ~ /%lo$/) next
      pr=($1 ~ /^udp/) ? "udp" : "tcp"; print pr, p }' | sort -u)
  ufw --force enable >/dev/null 2>&1 || { err "ufw enable failed"; return 1; }
  ok "UFW enabled (SSH + all already-listening ports allowed first)"
}

ufw_offer_enable() {
  [[ "$INTERACTIVE" == "yes" ]] || return 0
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' && return 0
  echo
  warn "UFW نصب است ولی غیرفعال | UFW is installed but inactive"
  info "قبل از فعال‌سازی، SSH و همه پورت‌های فعلی باز می‌شوند | SSH + all listening ports are allowed first"
  if yesno "  فعال‌سازی UFW؟ | Enable UFW now?"; then
    step "فعال‌سازی امن فایروال UFW" "Enabling UFW Safely" ufw_safe_enable
  else
    info "UFW دست‌نخورده ماند | UFW left untouched (iptables mode)"
  fi
}

do_install() {
  title "🚀 نصب و راه‌اندازی کامل | Full Installation"
  mkdir -p "$BASE_DIR"
  step "نصب پیش‌نیازها و تعمیر پکیج‌ها" "Installing & Repairing Dependencies" ensure_deps || return 1
  collect_prev_inbounds
  step "توقف واچ‌داگ و پاکسازی کانتینرهای قبلی" "Pausing Watchdog & Cleaning Old Containers" install_prepare
  step "اسکن ۱۰۰ پورت ورودی آزاد" "Scanning 100 Free Inbound Ports" scan_ports
  step "آماده‌سازی قالب کانفیگ سایفون" "Writing Psiphon Config Template" write_template || return 1
  step "دریافت هسته سایفون" "Downloading Psiphon Core" fetch_binary no || return 1
  step "دریافت و ساخت ایمیج داکر" "Pulling & Building Docker Image" build_image || return 1
  step "راه‌اندازی ۲۲ کانتینر سایفون (128MB/CPU)" "Deploying 22 Psiphon Containers" deploy_all || return 1
  ufw_offer_enable
  step "اعمال تک‌به‌تک قوانین فایروال" "Applying Firewall Rules One-by-One" fw_open_ports "${FWPORTS[@]}"
  step "فعال‌سازی واچ‌داگ" "Enabling Watchdog" finalize_install
  step "ثبت دستور میانبر maxnet" "Registering 'maxnet' Command" install_cli
  step "اتصال تونل‌های سایفون" "Connecting Psiphon Tunnels" wait_tunnels "${STARTED[@]}"
  local ncpu; ncpu=$(nproc 2>/dev/null || echo 1)
  printf '  %sپورت‌های آزاد | Free inbound ports:%s %d/%d   %sSSH:%s %s   %sCPU:%s %s   %sRAM/node:%s %s\n' \
    "$W" "$N" "${#FREE_PORTS[@]}" "${#CANDIDATE_PORTS[@]}" "$W" "$N" "${SSH_PORTS[*]}" \
    "$W" "$N" "$( ((ncpu > 1)) && echo "cores 1-$((ncpu - 1))" || echo "single-core")" "$W" "$N" "$CONTAINER_MEM"
  probe_list "${STARTED[@]}"
  render_table "${STARTED[@]}"
}

# =============================================================================
# 2) SMART UPDATE (keeps ports, rebuilds only FAILED)
# =============================================================================
declare -a UPD_CCS=() UPD_FAILED=() UPD_RECREATED=() UPD_NEWFW=()

update_core()  { write_template && fetch_binary yes && build_image; }
update_tools() { install_watchdog && install_cli; }
update_bot()   { write_bot && systemctl restart maxnet-bot >/dev/null 2>&1; }

update_detect_failed() {
  local cc f2=()
  mapfile -t UPD_CCS < <(state_ccs)
  UPD_FAILED=()
  probe_list "${UPD_CCS[@]}"
  for cc in "${UPD_CCS[@]}"; do [[ "${STATUS_OF[$cc]}" == "ACTIVE" ]] || UPD_FAILED+=("$cc"); done
  if ((${#UPD_FAILED[@]})); then
    sleep 5; probe_list "${UPD_FAILED[@]}"
    for cc in "${UPD_FAILED[@]}"; do [[ "${STATUS_OF[$cc]}" == "ACTIVE" ]] || f2+=("$cc"); done
    UPD_FAILED=("${f2[@]}")
  fi
  info "Healthy: $(( ${#UPD_CCS[@]} - ${#UPD_FAILED[@]} ))  FAILED: ${#UPD_FAILED[@]} ${UPD_FAILED[*]}"
  return 0
}

update_rebuild_failed() {
  local cc rc=0
  for cc in "${UPD_FAILED[@]}"; do
    [[ "${CPU_OF[$cc]:--}" == "-" ]] && CPU_OF[$cc]=$(cpu_for "$cc")
    info "Rebuilding ${PREFIX}${cc,,} (same SOCKS5 ${SOCKS_OF[$cc]}, same inbound ${INBOUND_OF[$cc]})"
    if run_container "$cc"; then UPD_RECREATED+=("$cc"); else err "Could not rebuild ${PREFIX}${cc,,}"; rc=1; fi
  done
  save_state
  return $rc
}

update_add_missing() {
  local cc
  refresh_ports
  for cc in "${COUNTRIES[@]}"; do
    [[ -n "${IN_STATE[$cc]:-}" ]] && continue
    port_free "${SOCKS_OF[$cc]}" || { warn "${cc}: SOCKS5 ${SOCKS_OF[$cc]} still busy; skipped"; continue; }
    INBOUND_OF[$cc]=$(next_free_inbound); CPU_OF[$cc]=$(cpu_for "$cc")
    if run_container "$cc"; then
      IN_STATE[$cc]=1; UPD_RECREATED+=("$cc")
      [[ "${INBOUND_OF[$cc]}" != "-" ]] && UPD_NEWFW+=("${INBOUND_OF[$cc]}")
      ok "New location ${cc} on 127.0.0.1:${SOCKS_OF[$cc]}"
    fi
  done
  save_state
  ((${#UPD_NEWFW[@]})) && fw_open_ports "${UPD_NEWFW[@]}"
  return 0
}

do_update() {
  title "🔄 به‌روزرسانی هوشمند | Smart Update (Keep Ports)"
  if ! load_state; then warn "هنوز نصب نشده | Not installed yet (use option 1)"; return 1; fi
  mkdir -p "$DATA_DIR" "$HEALTH_DIR"
  UPD_RECREATED=(); UPD_NEWFW=(); UPD_FAILED=()
  step "بررسی و تعمیر پیش‌نیازها" "Checking & Repairing Dependencies" ensure_deps || return 1
  step "به‌روزرسانی هسته و ایمیج سایفون" "Updating Psiphon Core & Image" update_core || return 1
  step "به‌روزرسانی واچ‌داگ و دستور maxnet" "Updating Watchdog & maxnet" update_tools
  [[ -f "$BOT_UNIT" ]] && step "آپدیت ربات تلگرام" "Updating Telegram Bot" update_bot
  step "تست سلامت لوکیشن‌ها (پورت‌ها ثابت)" "Health-Checking Locations (Ports Locked)" update_detect_failed
  if ((${#UPD_FAILED[@]})); then
    step "بازسازی فقط لوکیشن‌های FAILED" "Rebuilding FAILED Locations Only" update_rebuild_failed
  fi
  step "افزودن لوکیشن‌های جاافتاده" "Adding Missing Locations" update_add_missing
  mapfile -t UPD_CCS < <(state_ccs)
  local healthy=$(( ${#UPD_CCS[@]} - ${#UPD_RECREATED[@]} ))
  printf '  %sبدون قطعی | Untouched:%s %s%d%s   %sبازسازی/افزوده | Rebuilt/Added:%s %s%d%s\n' \
    "$W" "$N" "$G" "$healthy" "$N" "$W" "$N" "$Y" "${#UPD_RECREATED[@]}" "$N"
  ((${#UPD_RECREATED[@]})) && step "اتصال تونل‌های بازسازی‌شده" "Connecting Rebuilt Tunnels" wait_tunnels "${UPD_RECREATED[@]}"
  probe_list "${UPD_CCS[@]}"
  render_table "${UPD_CCS[@]}"
}

# =============================================================================
# 3) STATUS + SPEEDTEST
# =============================================================================
do_status() {
  local interactive=${1:-yes} ans cc
  title "📊 بررسی لوکیشن‌ها و پینگ | Status & Ping Check"
  command -v docker >/dev/null 2>&1 || { warn "Docker is not installed. Use option 1 first."; return 1; }
  if ! load_state; then warn "هنوز نصب نشده | Not installed yet (use option 1)"; return 1; fi
  local -a ccs=()
  mapfile -t ccs < <(state_ccs)
  step "تست زنده ${#ccs[@]} لوکیشن" "Live-Testing ${#ccs[@]} SOCKS5 Tunnels" probe_list "${ccs[@]}"
  render_table "${ccs[@]}"
  [[ "$interactive" == "yes" ]] || return 0
  ans=$(ask "  تست سرعت؟ | Speedtest? [a]=all  [CC]=one (e.g. DE)  [Enter]=skip: ")
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
  title "⚡ تعویض آی‌پی لوکیشن | Renew Node IP"
  load_state || { warn "هنوز نصب نشده | Not installed yet (use option 1)"; return 1; }
  local -a ccs=(); mapfile -t ccs < <(state_ccs)
  local i=0 line="" cc pick
  for cc in "${ccs[@]}"; do
    i=$((i + 1))
    line+=$(printf '%2d) %s %-3s' "$i" "${CFLAG[$cc]}" "$cc")"   "
    if ((i % 5 == 0)); then echo "  $line"; line=""; fi
  done
  [[ -n "$line" ]] && echo "  $line"
  pick=$(ask "  شماره یا کد لوکیشن | Location number or code (Enter = cancel): ")
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
  title "🔗 همگام‌سازی دیتابیس | Sync 3X-UI Outbounds"
  ensure_base_tools || return 1
  load_state || { warn "Psiphon locations are not installed yet (option 1)."; return 1; }
  if [[ ! -f "$XUI_DB" ]]; then
    local cand
    for cand in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /usr/local/x-ui/db/x-ui.db /opt/3x-ui/db/x-ui.db /root/3x-ui/db/x-ui.db; do
      [[ -f "$cand" ]] && { XUI_DB=$cand; break; }
    done
    [[ -f "$XUI_DB" ]] || XUI_DB=$(find /etc /usr/local /opt /root -maxdepth 4 -name 'x-ui.db' -type f 2>/dev/null | head -n1)
  fi
  [[ -n "$XUI_DB" && -f "$XUI_DB" ]] || { err "دیتابیس 3X-UI پیدا نشد | 3X-UI database not found (set XUI_DB=/path/x-ui.db)"; return 1; }
  info "3X-UI database: ${XUI_DB}"
  if [[ "$interactive" == "yes" ]]; then
    info "22 SOCKS5 outbounds (127.0.0.1:1081-1102) will be merged into the Xray template."
    info "Existing outbounds / routing stay as-is; x-ui restarts once (a few seconds)."
    yesno "  ادامه؟ | Continue?" || { info "لغو شد | Cancelled"; return 0; }
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
    return [[btn("🟢 وضعیت زنده | Live Status", "status"), btn("🟩 تست پینگ | Ping Test", "ping")],
            [btn("🔄 تعویض IP | Renew Location IP", "renew"), btn("⚡ همگام‌سازی | Sync 3X-UI", "xui")],
            [btn("📈 مصرف سیستم | System Status", "sys"), btn("🔔 تنظیمات | Alert Settings", "alerts")]]


BACK = [btn("🔙 منوی اصلی | Main Menu", "home", "primary")]


def home_text():
    return ("🟩 <b>MAXNET6G ULTIMATE MANAGER</b> 🟩\n"
            "━━━━━━━━━━━━━━━━━━\n"
            f"🖥 سرور: <code>{html.escape(os.uname().nodename)}</code>\n"
            f"🌍 لوکیشن‌ها: <b>{len(read_state())}</b>\n"
            "👇 یکی از گزینه‌ها را انتخاب کنید | Choose an option\n\n<i>Developer: mohsenakbarinia</i>")


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
  step "راه‌اندازی سرویس ربات تلگرام" "Starting Telegram Bot Service" install_bot_service || return 1
  bot_send $'🟩 <b>MAXNET6G</b> ربات با موفقیت متصل شد ✅\nبرای باز کردن منو /start را بزنید.' >/dev/null
  ok "Welcome message sent. Open your bot and press /start"
}

do_bot_menu() {
  local c st
  while true; do
    st="not installed"; bot_installed && st=$(systemctl is-active maxnet-bot 2>/dev/null || echo inactive)
    submenu "🤖 ربات تلگرام دکمه سبز | Telegram Bot · ${st}" \
      "1) نصب / تنظیم مجدد ربات | Setup (Token + Admin ID)" \
      "2) ارسال پیام تست | Send Test Message" \
      "3) ریستارت ربات | Restart Bot" \
      "4) نمایش لاگ ربات | Bot Logs" \
      "5) حذف ربات | Remove Bot" \
      "0) بازگشت | Back"
    c=$(ask "  ${RED}▶${N} انتخاب | Select: ")
    case "$c" in
      1) bot_configure ;;
      2) bot_installed && { bot_send $'🟢 پیام تست از <b>MAXNET6G</b> · همه‌چیز اوکی است ✅' >/dev/null && ok "Sent"; } || warn "Bot not installed" ;;
      3) bot_installed && systemctl restart maxnet-bot && ok "Restarted" || warn "Bot not installed" ;;
      4) journalctl -u maxnet-bot -n 30 --no-pager 2>/dev/null || warn "No logs" ;;
      5) remove_bot ;;
      0|"") return 0 ;;
      *) warn "گزینه نامعتبر | Invalid option" ;;
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
# 7) AUTO TUNNEL BRIDGE  ·  Gost (relay+TLS)  |  Backhaul (reverse tunnel)
# =============================================================================
tunnel_load_env() {  # sets ENGINE ROLE LISTEN_PORT USER PASS REMOTE PORTS UDP TRANSPORT TOKEN
  ENGINE=gost; ROLE=""; LISTEN_PORT=""; USER=""; PASS=""; REMOTE=""; PORTS=""; UDP=no; TRANSPORT=tcp; TOKEN=""
  [[ -s "$TUN_ENV" ]] || return 1
  # shellcheck disable=SC1090
  source "$TUN_ENV"
  ENGINE=${ENGINE:-gost}
}

tunnel_save_env() {
  mkdir -p "$TUN_DIR"
  umask 077
  printf 'ENGINE=%s\nROLE=%s\nLISTEN_PORT=%s\nUSER=%s\nPASS=%s\nREMOTE=%s\nPORTS=%s\nUDP=%s\nTRANSPORT=%s\nTOKEN=%s\n' \
    "$ENGINE" "$ROLE" "$LISTEN_PORT" "$USER" "$PASS" "$REMOTE" "$PORTS" "$UDP" "$TRANSPORT" "$TOKEN" >"$TUN_ENV"
  umask 022
  chmod 600 "$TUN_ENV"
}

_install_archive_bin() {  # $1 archive  $2 binary name  $3 destination
  local tmp; tmp=$(mktemp -d)
  case "$1" in
    *.tar.gz|*.tgz) tar -xzf "$1" -C "$tmp" 2>/dev/null ;;
    *.gz)           gunzip -c "$1" >"$tmp/$2" 2>/dev/null ;;
    *)              cp -f "$1" "$tmp/$2" ;;
  esac
  local f; f=$(find "$tmp" -type f -name "$2*" ! -name '*.md' 2>/dev/null | head -n1)
  [[ -n "$f" ]] && install -m 0755 "$f" "$3"
  local rc=$?
  rm -rf "$tmp"
  [[ -n "$f" ]] && return $rc || return 1
}

fetch_gost() {
  mkdir -p "$TUN_DIR"
  [[ -x "$TUN_BIN" ]] && "$TUN_BIN" -V >/dev/null 2>&1 && { info "Gost already present ($("$TUN_BIN" -V 2>&1 | head -n1))"; return 0; }
  if [[ -n "${GOST_PATH:-}" ]]; then install -m 0755 "$GOST_PATH" "$TUN_BIN" && ok "Using local gost binary"; return $?; fi
  local a u pkg urls=()
  a=$(arch_tag); [[ "$a" == unsupported ]] && { err "Unsupported CPU arch for gost"; return 1; }
  [[ -n "${GOST_URL:-}" ]] && urls+=("$GOST_URL")
  if [[ "$a" == amd64 ]]; then
    urls+=("https://github.com/ginuerzh/gost/releases/download/v2.12.0/gost_2.12.0_linux_amd64.tar.gz"
           "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz")
  else
    urls+=("https://github.com/ginuerzh/gost/releases/download/v2.12.0/gost_2.12.0_linux_arm64.tar.gz"
           "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-armv8-2.11.5.gz")
  fi
  pkg=$(mktemp -d)
  for u in "${urls[@]}"; do
    info "Downloading gost: ${u##*/}"
    download "$u" "$pkg/${u##*/}" || continue
    _install_archive_bin "$pkg/${u##*/}" gost "$TUN_BIN" || continue
    if "$TUN_BIN" -V >/dev/null 2>&1; then rm -rf "$pkg"; ok "Gost installed ($("$TUN_BIN" -V 2>&1 | head -n1))"; return 0; fi
  done
  rm -rf "$pkg"
  err "Could not download gost (GitHub blocked?). Copy it to this server and run: GOST_PATH=/path/gost maxnet"
  return 1
}

fetch_backhaul() {
  mkdir -p "$TUN_DIR"
  [[ -x "$BH_BIN" ]] && { info "Backhaul already present"; return 0; }
  if [[ -n "${BACKHAUL_PATH:-}" ]]; then install -m 0755 "$BACKHAUL_PATH" "$BH_BIN" && ok "Using local backhaul binary"; return $?; fi
  local a u pkg urls=()
  a=$(arch_tag); [[ "$a" == unsupported ]] && { err "Unsupported CPU arch for backhaul"; return 1; }
  [[ -n "${BACKHAUL_URL:-}" ]] && urls+=("$BACKHAUL_URL")
  urls+=("https://github.com/Musixal/Backhaul/releases/download/v0.7.2/backhaul_linux_${a}.tar.gz"
         "https://github.com/Musixal/Backhaul/releases/latest/download/backhaul_linux_${a}.tar.gz")
  pkg=$(mktemp -d)
  for u in "${urls[@]}"; do
    info "Downloading backhaul: ${u}"
    download "$u" "$pkg/bh.tar.gz" || continue
    if _install_archive_bin "$pkg/bh.tar.gz" backhaul "$BH_BIN" && [[ "$(head -c 4 "$BH_BIN" | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]]; then
      rm -rf "$pkg"; ok "Backhaul installed"; return 0
    fi
    rm -f "$BH_BIN"
  done
  rm -rf "$pkg"
  err "Could not download backhaul (GitHub blocked?). Copy it to this server and run: BACKHAUL_PATH=/path/backhaul maxnet"
  return 1
}

write_backhaul_conf() {
  local p list="" udp=false
  [[ "$UDP" == "yes" ]] && udp=true
  if [[ "$ROLE" == "iran" ]]; then
    for p in ${PORTS//,/ }; do list+="\"${p}\", "; done
    list=${list%, }
    cat >"$BH_CONF" <<TOML
# MAXNET6G Backhaul (managed by maxnet) · IRAN server
[server]
bind_addr = "0.0.0.0:${LISTEN_PORT}"
transport = "${TRANSPORT}"
accept_udp = ${udp}
token = "${TOKEN}"
keepalive_period = 75
nodelay = true
heartbeat = 40
channel_size = 2048
mux_con = 8
sniffer = false
web_port = 0
log_level = "info"
ports = [${list}]
TOML
  else
    cat >"$BH_CONF" <<TOML
# MAXNET6G Backhaul (managed by maxnet) · FOREIGN client
[client]
remote_addr = "${REMOTE}:${LISTEN_PORT}"
transport = "${TRANSPORT}"
token = "${TOKEN}"
connection_pool = 8
aggressive_pool = false
keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true
sniffer = false
web_port = 0
log_level = "info"
TOML
  fi
  chmod 600 "$BH_CONF"
}

write_tunnel_service() {  # builds the systemd unit from tunnel.env
  tunnel_load_env || { err "No tunnel configuration"; return 1; }
  local exec_start args=() p
  if [[ "$ENGINE" == "backhaul" ]]; then
    write_backhaul_conf
    exec_start="${BH_BIN} -c ${BH_CONF}"
  else
    if [[ "$ROLE" == "foreign" ]]; then
      args=(-L "relay+tls://${USER}:${PASS}@:${LISTEN_PORT}")
    else
      for p in ${PORTS//,/ }; do
        args+=(-L "tcp://:${p}/127.0.0.1:${p}")
        [[ "$UDP" == "yes" ]] && args+=(-L "udp://:${p}/127.0.0.1:${p}?ttl=60s")
      done
      args+=(-F "relay+tls://${USER}:${PASS}@${REMOTE}:${LISTEN_PORT}")
    fi
    exec_start="${TUN_BIN} ${args[*]}"
  fi
  cat >"$TUN_UNIT" <<UNIT
[Unit]
Description=MAXNET6G Auto Tunnel Bridge (${ENGINE} · ${ROLE})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exec_start}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
  chmod 600 "$TUN_UNIT"
  systemctl daemon-reload
  systemctl enable maxnet-tunnel >/dev/null 2>&1
  systemctl restart maxnet-tunnel
  sleep 2
  systemctl is-active --quiet maxnet-tunnel && ok "Tunnel service running (maxnet-tunnel · ${ENGINE})" \
    || { err "Tunnel failed: journalctl -u maxnet-tunnel -n 30"; return 1; }
}

tunnel_fw_ports() {  # prints the inbound ports this tunnel needs
  local p
  if [[ "$ENGINE" == "backhaul" ]]; then
    [[ "$ROLE" == "iran" ]] || return 0
    echo "$LISTEN_PORT"
    for p in ${PORTS//,/ }; do echo "$p"; [[ "$UDP" == "yes" ]] && echo "${p}/udp"; done
  else
    if [[ "$ROLE" == "foreign" ]]; then echo "$LISTEN_PORT"
    else for p in ${PORTS//,/ }; do echo "$p"; [[ "$UDP" == "yes" ]] && echo "${p}/udp"; done; fi
  fi
}

tunnel_open_fw() { local -a fw=(); mapfile -t fw < <(tunnel_fw_ports); refresh_ports; ((${#fw[@]})) && fw_open_ports "${fw[@]}"; return 0; }

tunnel_fetch_engine() { if [[ "$ENGINE" == "backhaul" ]]; then fetch_backhaul; else fetch_gost; fi; }

tunnel_reapply() {  # used by restore
  local ENGINE ROLE LISTEN_PORT USER PASS REMOTE PORTS UDP TRANSPORT TOKEN
  tunnel_load_env || return 0
  tunnel_fetch_engine && write_tunnel_service && tunnel_open_fw
}

tunnel_replace_guard() {
  [[ -s "$TUN_ENV" ]] || return 0
  warn "یک تونل از قبل وجود دارد و جایگزین می‌شود | An existing tunnel will be replaced"
  yesno "  ادامه؟ | Continue?"
}

ask_ports_list() {  # $1 prompt $2 default -> validated comma list or empty
  local ports p bad=()
  ports=$(askdef "$1" "$2"); ports=${ports// /}
  for p in ${ports//,/ }; do
    valid_port "$p" || { err "Invalid port: $p" >&2; return 1; }
    port_free "$p" || bad+=("$p")
  done
  ((${#bad[@]})) && { err "Already in use on this server: ${bad[*]}" >&2; return 1; }
  printf '%s' "$ports"
}

tunnel_summary() {
  echo
  box_top; box_row "✅ $1" "$G"; box_mid
  shift
  local r; for r in "$@"; do box_row "$r"; done
  box_bot
}

gost_foreign() {
  local ENGINE ROLE LISTEN_PORT USER PASS REMOTE PORTS UDP TRANSPORT TOKEN
  has_systemd || { err "systemd is required"; return 1; }
  tunnel_replace_guard || return 0
  step "بررسی پیش‌نیازها" "Checking Dependencies" ensure_base_tools || return 1
  refresh_ports
  ENGINE=gost; ROLE=foreign; REMOTE=""; PORTS=""; UDP=no; TRANSPORT=tcp; TOKEN=""
  LISTEN_PORT=$(askdef "  پورت تونل روی سرور خارج | Tunnel listen port (FOREIGN)" "2087")
  valid_port "$LISTEN_PORT" || { err "Invalid port"; return 1; }
  port_free "$LISTEN_PORT" || { err "Port $LISTEN_PORT is already in use"; return 1; }
  USER=$(askdef "  نام کاربری | Username" "maxnet")
  PASS=$(askdef "  رمز عبور | Password" "$(randstr 20)")
  [[ "$USER" =~ ^[A-Za-z0-9._-]+$ && "$PASS" =~ ^[A-Za-z0-9._-]+$ ]] || { err "Username/password: only A-Z a-z 0-9 . _ -"; return 1; }
  step "دریافت Gost" "Downloading Gost" fetch_gost || return 1
  tunnel_save_env
  step "راه‌اندازی تونل ارتباطی" "Tunnel Bridge Setup" write_tunnel_service || return 1
  step "باز کردن پورت تونل" "Opening Tunnel Port" tunnel_open_fw
  local myip; myip=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "<FOREIGN_IP>")
  tunnel_summary "سمت خارج آماده است | FOREIGN SIDE READY" \
    "روی سرور ایران | On IRAN: maxnet → 7 → 2" \
    "Foreign IP : ${myip}" "Port       : ${LISTEN_PORT}" "Username   : ${USER}" "Password   : ${PASS}"
}

gost_iran() {
  local ENGINE ROLE LISTEN_PORT USER PASS REMOTE PORTS UDP TRANSPORT TOKEN
  has_systemd || { err "systemd is required"; return 1; }
  tunnel_replace_guard || return 0
  step "بررسی پیش‌نیازها" "Checking Dependencies" ensure_base_tools || return 1
  refresh_ports
  ENGINE=gost; ROLE=iran; TRANSPORT=tcp; TOKEN=""
  REMOTE=$(ask "  آی‌پی/دامنه سرور خارج | FOREIGN server IP/domain: ")
  valid_ip "$REMOTE" || { err "Invalid address"; return 1; }
  LISTEN_PORT=$(askdef "  پورت تونل خارج | Foreign tunnel port" "2087"); valid_port "$LISTEN_PORT" || { err "Invalid port"; return 1; }
  USER=$(askdef "  نام کاربری | Username" "maxnet")
  PASS=$(ask "  رمز عبور | Password: ")
  [[ "$USER" =~ ^[A-Za-z0-9._-]+$ && "$PASS" =~ ^[A-Za-z0-9._-]+$ ]] || { err "Username/password: only A-Z a-z 0-9 . _ -"; return 1; }
  PORTS=$(ask_ports_list "  پورت‌های فوروارد | Ports to forward (Xray inbounds on foreign, comma-separated)" "443") || return 1
  UDP=no; yesno "  فوروارد UDP هم انجام شود؟ | Also forward UDP (gaming/QUIC)?" && UDP=yes
  timeout 6 bash -c "exec 3<>/dev/tcp/${REMOTE}/${LISTEN_PORT}" 2>/dev/null \
    || warn "${REMOTE}:${LISTEN_PORT} فعلاً در دسترس نیست | not reachable right now (check foreign firewall); continuing"
  step "دریافت Gost" "Downloading Gost" fetch_gost || return 1
  tunnel_save_env
  step "راه‌اندازی تونل ارتباطی" "Tunnel Bridge Setup" write_tunnel_service || return 1
  step "باز کردن پورت‌های فوروارد" "Opening Forwarded Ports" tunnel_open_fw
  tunnel_summary "پل ایران آماده است | IRAN BRIDGE READY" \
    "کلاینت‌ها → این سرور | Clients → THIS server : ${PORTS}" \
    "رله رمزنگاری‌شده | Encrypted relay → ${REMOTE}:${LISTEN_PORT}" "UDP : ${UDP}"
}

ask_transport() {
  local t
  t=$(askdef "  نوع ترنسپورت | Transport (tcp / tcpmux / ws / wsmux)" "tcp")
  case "$t" in tcp|tcpmux|ws|wsmux) printf '%s' "$t" ;; *) printf 'tcp' ;; esac
}

backhaul_iran() {
  local ENGINE ROLE LISTEN_PORT USER PASS REMOTE PORTS UDP TRANSPORT TOKEN
  has_systemd || { err "systemd is required"; return 1; }
  tunnel_replace_guard || return 0
  step "بررسی پیش‌نیازها" "Checking Dependencies" ensure_base_tools || return 1
  refresh_ports
  ENGINE=backhaul; ROLE=iran; REMOTE=""; USER=""; PASS=""
  LISTEN_PORT=$(askdef "  پورت تونل روی ایران | Tunnel bind port on IRAN" "3080")
  valid_port "$LISTEN_PORT" || { err "Invalid port"; return 1; }
  port_free "$LISTEN_PORT" || { err "Port $LISTEN_PORT is already in use"; return 1; }
  TRANSPORT=$(ask_transport)
  TOKEN=$(askdef "  توکن | Token" "$(randstr 24)")
  [[ "$TOKEN" =~ ^[A-Za-z0-9._-]+$ ]] || { err "Token: only A-Z a-z 0-9 . _ -"; return 1; }
  PORTS=$(ask_ports_list "  پورت‌های فوروارد | Ports to forward (Xray inbounds on foreign, comma-separated)" "443") || return 1
  UDP=no
  [[ "$TRANSPORT" == "tcp" ]] && yesno "  انتقال UDP روی TCP؟ | Accept UDP over TCP?" && UDP=yes
  step "دریافت Backhaul" "Downloading Backhaul" fetch_backhaul || return 1
  tunnel_save_env
  step "راه‌اندازی تونل ارتباطی" "Tunnel Bridge Setup" write_tunnel_service || return 1
  step "باز کردن پورت‌های تونل" "Opening Tunnel Ports" tunnel_open_fw
  local myip; myip=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "<IRAN_IP>")
  tunnel_summary "سرور ایران آماده است | IRAN SERVER READY" \
    "روی سرور خارج | On FOREIGN: maxnet → 7 → 4" \
    "Iran IP   : ${myip}" "Port      : ${LISTEN_PORT}" "Transport : ${TRANSPORT}" "Token     : ${TOKEN}" \
    "Forwards  : ${PORTS} (udp: ${UDP})"
}

backhaul_foreign() {
  local ENGINE ROLE LISTEN_PORT USER PASS REMOTE PORTS UDP TRANSPORT TOKEN
  has_systemd || { err "systemd is required"; return 1; }
  tunnel_replace_guard || return 0
  step "بررسی پیش‌نیازها" "Checking Dependencies" ensure_base_tools || return 1
  ENGINE=backhaul; ROLE=foreign; USER=""; PASS=""; PORTS=""; UDP=no
  REMOTE=$(ask "  آی‌پی/دامنه سرور ایران | IRAN server IP/domain: ")
  valid_ip "$REMOTE" || { err "Invalid address"; return 1; }
  LISTEN_PORT=$(askdef "  پورت تونل ایران | Iran tunnel port" "3080"); valid_port "$LISTEN_PORT" || { err "Invalid port"; return 1; }
  TRANSPORT=$(ask_transport)
  TOKEN=$(ask "  توکن (همان توکن ایران) | Token (same as Iran): ")
  [[ "$TOKEN" =~ ^[A-Za-z0-9._-]+$ ]] || { err "Token: only A-Z a-z 0-9 . _ -"; return 1; }
  step "دریافت Backhaul" "Downloading Backhaul" fetch_backhaul || return 1
  tunnel_save_env
  step "راه‌اندازی تونل ارتباطی" "Tunnel Bridge Setup" write_tunnel_service || return 1
  tunnel_summary "کلاینت خارج متصل شد | FOREIGN CLIENT READY" \
    "Iran → ${REMOTE}:${LISTEN_PORT} (${TRANSPORT})" \
    "پورت ورودی نیاز نیست | No inbound port needed on this server"
}

tunnel_status() {
  local ENGINE ROLE LISTEN_PORT USER PASS REMOTE PORTS UDP TRANSPORT TOKEN
  tunnel_load_env || { warn "تونلی تنظیم نشده | No tunnel configured"; return 0; }
  box_top; box_row "🌉 وضعیت تونل | TUNNEL STATUS" "$W" yes; box_mid
  box_row "Engine   : ${ENGINE}    Role: ${ROLE}"
  box_row "Service  : $(systemctl is-active maxnet-tunnel 2>/dev/null)"
  if [[ "$ENGINE" == "backhaul" ]]; then
    box_row "Port     : ${LISTEN_PORT}   Transport: ${TRANSPORT}   Token: ${TOKEN:0:3}*****"
    [[ "$ROLE" == "iran" ]] && box_row "Forwards : ${PORTS} (udp: ${UDP})"
    [[ "$ROLE" == "foreign" ]] && box_row "Remote   : ${REMOTE}"
  else
    box_row "Port     : ${LISTEN_PORT}   User: ${USER}   Pass: ${PASS:0:3}*****"
    [[ "$ROLE" == "iran" ]] && { box_row "Remote   : ${REMOTE}"; box_row "Forwards : ${PORTS} (udp: ${UDP})"; }
  fi
  box_bot
  if [[ -n "$REMOTE" ]]; then
    if timeout 6 bash -c "exec 3<>/dev/tcp/${REMOTE}/${LISTEN_PORT}" 2>/dev/null; then ok "سمت مقابل در دسترس است | Remote side reachable"
    else err "سمت مقابل در دسترس نیست | Remote side NOT reachable"; fi
  elif [[ "$ENGINE" == "backhaul" && "$ROLE" == "iran" ]]; then
    local n; n=$(ss -Htn state established "( sport = :${LISTEN_PORT} )" 2>/dev/null | wc -l)
    ((n > 0)) && ok "اتصالات فعال از خارج | Active foreign connections: ${n}" || warn "هنوز کلاینتی وصل نیست | No foreign client connected yet"
  fi
}

remove_tunnel() {
  if [[ -f "$TUN_UNIT" ]]; then systemctl disable --now maxnet-tunnel >/dev/null 2>&1 || true; rm -f "$TUN_UNIT"; systemctl daemon-reload 2>/dev/null || true; fi
  rm -rf "$TUN_DIR"
  ok "تونل حذف شد | Tunnel removed (firewall rules kept; option 13 can remove them)"
}

do_tunnel_menu() {
  local c
  while true; do
    submenu "🌉 راه‌اندازی تونل | Auto Tunnel Bridge" \
      "1) Gost · این سرور خارج است | Foreign Endpoint" \
      "2) Gost · این سرور ایران است | Iran Bridge → Foreign" \
      "3) Backhaul · سرور ایران | Iran Server (Reverse)" \
      "4) Backhaul · سرور خارج | Foreign Client (Reverse)" \
      "5) وضعیت تونل | Tunnel Status" \
      "6) حذف تونل | Remove Tunnel" \
      "0) بازگشت | Back"
    c=$(ask "  ${RED}▶${N} انتخاب | Select: ")
    case "$c" in
      1) with_lock gost_foreign ;;
      2) with_lock gost_iran ;;
      3) with_lock backhaul_iran ;;
      4) with_lock backhaul_foreign ;;
      5) tunnel_status ;;
      6) remove_tunnel ;;
      0|"") return 0 ;;
      *) warn "گزینه نامعتبر | Invalid option" ;;
    esac
    pause
  done
}

# =============================================================================
# 8) CLOUDFLARE CLEAN IP FINDER
# =============================================================================
do_cf_scan() {
  title "🔍 اسکنر آی‌پی کلودفلر | Cloudflare Clean IP Finder"
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
  title "🎮 بهینه‌سازی گیمینگ و BBR | BBR & Gaming Optimizer"
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
  command -v irqbalance >/dev/null 2>&1 || pkg_install irqbalance >/dev/null 2>&1 || true
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
  title "🔐 رمزنگاری DNS | DNS-over-HTTPS (dnscrypt-proxy)"
  command -v apt-get >/dev/null 2>&1 || { err "DoH setup supports Debian/Ubuntu only"; return 1; }
  warn "This changes the system DNS resolver. It is verified and rolled back automatically if DNS breaks."
  yesno "  Continue?" || return 0
  step "نصب dnscrypt-proxy" "Installing dnscrypt-proxy" pkg_install dnscrypt-proxy || return 1
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
    submenu "🎮 بهینه‌سازی گیمینگ و BBR | BBR & Gaming Optimizer" \
      "1) BBR + بافر UDP + پخش هسته‌ها | BBR + UDP Buffers + CPU" \
      "2) فعال‌سازی DoH | Enable DNS-over-HTTPS" \
      "3) بازگردانی تنظیمات | Revert All" \
      "0) بازگشت | Back"
    c=$(ask "  ${RED}▶${N} انتخاب | Select: ")
    case "$c" in
      1) optimize_network ;;
      2) setup_doh ;;
      3) revert_optimize ;;
      0|"") return 0 ;;
      *) warn "گزینه نامعتبر | Invalid option" ;;
    esac
    pause
  done
}

# =============================================================================
# 10) FAIL2BAN SHIELD (anti-scan)
# =============================================================================
f2b_install() {
  title "🔒 سیستم ضد اسکن | Fail2Ban Security Shield"
  command -v fail2ban-client >/dev/null 2>&1 || step "نصب و تعمیر Fail2Ban" "Installing & Repairing Fail2Ban" pkg_install fail2ban || return 1
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
    submenu "🔒 سیستم ضد اسکن | Fail2Ban Security Shield" \
      "1) نصب و فعال‌سازی | Install & Enable" \
      "2) وضعیت و آی‌پی‌های بن‌شده | Status & Banned IPs" \
      "3) آزاد کردن آی‌پی | Unban IP" \
      "4) حذف جیل‌های MAXNET6G | Remove Jails" \
      "0) بازگشت | Back"
    c=$(ask "  ${RED}▶${N} انتخاب | Select: ")
    case "$c" in
      1) f2b_install ;;
      2) f2b_status ;;
      3) ip=$(ask "  IP to unban: "); [[ -n "$ip" ]] && fail2ban-client unban "$ip" >/dev/null 2>&1 && ok "Unbanned $ip" || warn "Not banned / invalid" ;;
      4) f2b_remove ;;
      0|"") return 0 ;;
      *) warn "گزینه نامعتبر | Invalid option" ;;
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
    --exclude="${BASE_DIR#/}/health" --exclude="${BASE_DIR#/}/backups" --exclude="${BASE_DIR#/}/tunnel/gost" --exclude="${BASE_DIR#/}/tunnel/backhaul" \
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
  if [[ -s "$BOT_ENV" ]]; then step "بازگردانی ربات تلگرام" "Restoring Telegram Bot" install_bot_service; fi
  if [[ -s "$TUN_ENV" ]]; then
    step "بازسازی تونل ارتباطی" "Restoring Tunnel Bridge" tunnel_reapply
  fi
  ok "بازگردانی کامل شد | Restore complete"
}

do_backup_menu() {
  local c
  submenu "💾 بکاپ و بازگردانی | Backup & Restore Settings" \
    "1) ساخت بکاپ | Create maxnet6g-backup.tar.gz" \
    "2) بازگردانی از بکاپ | Restore" \
    "0) بازگشت | Back"
  c=$(ask "  ${RED}▶${N} انتخاب | Select: ")
  case "$c" in
    1) do_backup ;;
    2) with_lock do_restore ;;
    *) return 0 ;;
  esac
}

# =============================================================================
# 12) REPAIR PACKAGES & DOCKER
# =============================================================================
repair_packages() { repair_broken_pkgs; }

docker_cleanup() {  # only psiphon-* containers and this project's dangling images
  command -v docker >/dev/null 2>&1 || return 0
  local n st
  while read -r n st; do
    [[ -n "$n" && "$n" == ${PREFIX}* ]] || continue
    case "$st" in
      dead|created|exited|removing) docker rm -f "$n" >/dev/null 2>&1 && info "Removed stale container $n ($st)" ;;
    esac
  done < <(docker ps -a --filter "name=^${PREFIX}" --format '{{.Names}} {{.State}}' 2>/dev/null)
  docker image prune -f --filter "label=maxnet.hash" >/dev/null 2>&1 || true
  return 0
}

ensure_image() { fetch_binary no && build_image; }

repair_containers() {  # recreate every deployed location that is missing / not running (ports unchanged)
  local cc name fixed=0 rc=0
  for cc in $(state_ccs); do
    name="${PREFIX}${cc,,}"
    container_running "$name" && continue
    [[ "${CPU_OF[$cc]:--}" == "-" ]] && CPU_OF[$cc]=$(cpu_for "$cc")
    if run_container "$cc"; then fixed=$((fixed + 1)); info "Rebuilt $name on 127.0.0.1:${SOCKS_OF[$cc]}"
    else err "Could not rebuild $name"; rc=1; fi
  done
  save_state
  info "Rebuilt ${fixed} location(s)"
  return $rc
}

services_heal() {
  local u
  for u in maxnet-bot maxnet-tunnel; do
    [[ -f "/etc/systemd/system/${u}.service" ]] || continue
    systemctl is-active --quiet "$u" && continue
    systemctl reset-failed "$u" >/dev/null 2>&1 || true
    systemctl restart "$u" >/dev/null 2>&1 && info "Restarted $u" || warn "$u still failing (journalctl -u $u)"
  done
  return 0
}

do_repair() {
  title "🛠 عیب‌یابی و تعمیر پکیج‌ها | Repair Packages & Docker"
  APT_UPDATED=0
  step "آزادسازی قفل‌های apt/dpkg" "Releasing apt/dpkg Locks" apt_release_locks
  step "تعمیر پکیج‌های نیمه‌کاره (dpkg/apt -f)" "Repairing Half-Installed Packages" repair_packages
  step "نصب و تعمیر پیش‌نیازها" "Installing & Repairing Dependencies" ensure_deps
  step "بررسی سلامت داکر" "Docker Health Check" docker_heal
  step "پاکسازی کانتینرهای معلق" "Cleaning Stale Containers" docker_cleanup
  if load_state; then
    step "بررسی ایمیج سایفون" "Verifying Psiphon Image" ensure_image
    step "بازسازی لوکیشن‌های از کار افتاده" "Rebuilding Broken Locations" repair_containers
    step "بازنویسی واچ‌داگ" "Restoring Watchdog" install_watchdog
  fi
  step "بررسی سرویس ربات و تونل" "Checking Bot & Tunnel Services" services_heal
  step "ثبت دستور میانبر maxnet" "Registering 'maxnet' Command" install_cli
  echo
  ok "تعمیر کامل شد | Repair finished · log: ${INSTALL_LOG}"
}

# =============================================================================
# 13) UNINSTALL
# =============================================================================
do_uninstall() {
  local interactive=${1:-yes} ans
  title "🗑 حذف کامل | Full Uninstall"
  if [[ "$interactive" == "yes" ]]; then
    ans=$(ask "  ${RED}حذف همه کانتینرها، ربات، تونل و فایل‌ها؟ | Remove everything? type 'yes': ${N}")
    [[ "$ans" == "yes" ]] || { info "لغو شد | Cancelled"; return 0; }
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
  ok "حذف کامل انجام شد | Uninstalled. 'maxnet' removed; other containers, services and firewall rules untouched."
}

# =============================================================================
# MENU
# =============================================================================
menu_status_line() {
  local n=0 bot="—" tun="—"
  [[ -r "$STATE_FILE" ]] && n=$(grep -vc '^#' "$STATE_FILE" 2>/dev/null || echo 0)
  [[ -f "$BOT_UNIT" ]] && bot=$(systemctl is-active maxnet-bot 2>/dev/null || echo off)
  [[ -f "$TUN_UNIT" ]] && tun=$(systemctl is-active maxnet-tunnel 2>/dev/null || echo off)
  box_row "لوکیشن‌ها | Nodes: ${n}/22   ربات | Bot: ${bot}   تونل | Tunnel: ${tun}" "$DIM" yes
}

show_menu() {
  clear 2>/dev/null || printf '\033c'
  print_logo
  box_top
  box_row "${BRAND} ULTIMATE MANAGER  v${VERSION}" "$W" yes
  box_mid
  box_row " 1) 🚀 نصب و راه‌اندازی کامل | Full Installation"
  box_row " 2) 🔄 به‌روزرسانی هوشمند | Smart Update (Keep Ports)"
  box_row " 3) 📊 بررسی لوکیشن‌ها و پینگ | Status & Ping Check"
  box_row " 4) ⚡ تعویض آی‌پی لوکیشن | Renew Node IP"
  box_row " 5) 🔗 همگام‌سازی دیتابیس | Sync 3X-UI Outbounds"
  box_row " 6) 🤖 ربات تلگرام دکمه سبز | Green Theme Telegram Bot"
  box_row " 7) 🌉 راه‌اندازی تونل | Auto Tunnel Bridge Setup"
  box_row " 8) 🔍 اسکنر آی‌پی کلودفلر | Cloudflare Clean IP Finder"
  box_row " 9) 🎮 بهینه‌سازی گیمینگ و BBR | BBR & Gaming Optimizer"
  box_row "10) 🔒 سیستم ضد اسکن | Fail2Ban Security Shield"
  box_row "11) 💾 بکاپ و بازگردانی | Backup & Restore Settings"
  box_row "12) 🛠 عیب‌یابی و تعمیر پکیج‌ها | Repair Packages & Docker"
  box_row "13) 🗑 حذف کامل | Full Uninstall"
  box_row " 0) ❌ خروج | Exit"
  box_mid
  menu_status_line
  box_bot
}

main_menu() {
  local choice
  INTERACTIVE="yes"
  while true; do
    show_menu
    choice=$(ask "  ${RED}▶${N} ${W}انتخاب گزینه | Select an option [0-13]: ${N}")
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
      12) with_lock do_repair;  pause ;;
      13) with_lock do_uninstall yes
          [[ -x "$CLI_PATH" ]] || exit 0
          pause ;;
      0)  echo; ok "خدانگهدار | Bye · MAXNET6G"; exit 0 ;;
      *)  warn "گزینه نامعتبر | Invalid option"; sleep 1 ;;
    esac
  done
}

main() {
  case "${1:-}" in -h|--help) awk 'NR > 2 && /^# =+$/ {exit} NR > 2 {sub(/^# ?/, ""); print}' "$0"; exit 0 ;; esac
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
    --repair)    with_lock do_repair ;;
    --renew)     [[ -n "${2:-}" && "${2:-}" != --* ]] || { err "Usage: maxnet --renew US"; exit 1; }; renew_node "$2" ;;
    --xui-sync)  with_lock do_xui_sync no ;;
    --backup)    do_backup "${2:-/root/maxnet6g-backup.tar.gz}" ;;
    --restore)   [[ -n "${2:-}" ]] || { err "Usage: maxnet --restore file.tar.gz"; exit 1; }; with_lock do_restore "$2" ;;
    --uninstall) with_lock do_uninstall no ;;
    -h|--help)   awk 'NR > 2 && /^# =+$/ {exit} NR > 2 {sub(/^# ?/, ""); print}' "$0" ;;
    "")          main_menu ;;
    *)           err "Unknown option: $1 (use --help)"; exit 1 ;;
  esac
}

main "$@"
