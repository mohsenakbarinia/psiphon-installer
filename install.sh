#!/usr/bin/env bash
# =============================================================================
#  Psiphon Multi-Instance Manager - Production Installer (Debian / Ubuntu)
# -----------------------------------------------------------------------------
#  One-liner:
#    bash <(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/install.sh)
#  With overrides:
#    CONTAINER_COUNT=5 START_PORT=2001 EGRESS_REGION=DE \
#      bash <(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/install.sh)
#
#  What it does:
#    1) root check + non-interactive apt       5) N isolated Psiphon containers
#    2) BBR + TCP kernel tuning (persistent)    6) health check + auto-repair (3x)
#    3) apt upgrade + dependencies              7) watchdog + cron every 5 minutes
#    4) pre-flight checks + self-fix            8) colored dashboard + full logging
# =============================================================================
set -Eeuo pipefail

# ============================ USER SETTINGS ==================================
CONTAINER_COUNT="${CONTAINER_COUNT:-10}"        # number of Psiphon containers
START_PORT="${START_PORT:-1081}"                # first SOCKS5 port (1081..1090)
HTTP_START_PORT="${HTTP_START_PORT:-8081}"      # first HTTP proxy port (8081..8090)
ENABLE_HTTP_PROXY="${ENABLE_HTTP_PROXY:-true}"  # also publish HTTP proxy ports
EGRESS_REGION="${EGRESS_REGION:-}"              # e.g. DE, NL, US ; empty = best server
ALLOWED_SOURCES="${ALLOWED_SOURCES:-any}"       # "any" or "1.2.3.4,5.6.0.0/16"
BIND_ADDRESS="${BIND_ADDRESS:-0.0.0.0}"         # host address for published ports
DOCKER_NETWORK="${DOCKER_NETWORK:-psiphon_net}" # isolated bridge network
DOCKER_SUBNET="${DOCKER_SUBNET:-}"              # optional, e.g. 172.30.0.0/24
DOCKER_REGISTRY_MIRROR="${DOCKER_REGISTRY_MIRROR:-}" # optional mirror URL
MAX_RETRIES="${MAX_RETRIES:-3}"                 # repair attempts per instance
BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-240}"   # first-connect wait (seconds)
REPAIR_WAIT="${REPAIR_WAIT:-120}"               # wait after each repair (seconds)
PROBE_TIMEOUT="${PROBE_TIMEOUT:-20}"            # curl timeout per probe
SKIP_UPGRADE="${SKIP_UPGRADE:-false}"           # true = skip apt-get upgrade
UFW_ENABLE="${UFW_ENABLE:-true}"                # false = never turn UFW on (iptables rules only)
KEEP_EXTRA_PORTS="${KEEP_EXTRA_PORTS:-}"        # extra ports to always keep open, e.g. "80,443,2053"
XUI_DB="${XUI_DB:-}"                            # 3x-ui DB path (auto-detected, read-only)
FORCE_BINARY_UPDATE="${FORCE_BINARY_UPDATE:-false}"
PSIPHON_BINARY_URL="${PSIPHON_BINARY_URL:-}"    # optional custom binary URL

# Psiphon public network parameters (replace with your own sponsor values if you have them)
PSIPHON_PROPAGATION_CHANNEL_ID="${PSIPHON_PROPAGATION_CHANNEL_ID:-FFFFFFFFFFFFFFFF}"
PSIPHON_SPONSOR_ID="${PSIPHON_SPONSOR_ID:-FFFFFFFFFFFFFFFF}"
PSIPHON_REMOTE_SERVER_LIST_URL="${PSIPHON_REMOTE_SERVER_LIST_URL:-https://s3.amazonaws.com//psiphon/web/mjr4-p23r-puwl/server_list_compressed}"
PSIPHON_RSL_PUBKEY="${PSIPHON_RSL_PUBKEY:-MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=}"

# ============================ PATHS ==========================================
LOG_FILE="/var/log/psiphon_installer.log"
WATCHDOG_LOG="/var/log/psiphon_watchdog.log"
BASE_DIR="/opt/psiphon-manager"
CONF_DIR="/etc/psiphon-manager"
ENV_FILE="${CONF_DIR}/psiphon.env"
STATE_DIR="/var/lib/psiphon-manager"
LIB_DIR="/usr/local/lib/psiphon-manager"
LIB_FILE="${LIB_DIR}/common.sh"
WATCHDOG_BIN="/usr/local/bin/psiphon-watchdog.sh"
CRON_FILE="/etc/cron.d/psiphon-watchdog"
IMAGE_NAME="psiphon-local:latest"

XRAY_SNIPPET="${CONF_DIR}/xray-psiphon-outbounds.json"
LISTEN_INTERFACE="any"   # auto-detected by the image self-test
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=600)

# =============================================================================
# 1. Root check (before anything else)
# =============================================================================
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf '\033[1;31m[✗] This installer must be run as root. Try: sudo bash install.sh\033[0m\n' >&2
    exit 1
  fi
}

# =============================================================================
# Shared library (used by installer AND watchdog)
# =============================================================================
write_lib() {
  mkdir -p "$LIB_DIR"
  cat > "$LIB_FILE" <<'LIB_EOF'
#!/usr/bin/env bash
# Psiphon Manager shared library - generated by install.sh, do not edit by hand.
PSI_ENV_FILE="${PSI_ENV_FILE:-/etc/psiphon-manager/psiphon.env}"

if [[ "${PSI_COLOR:-}" == "1" || -t 1 ]]; then
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'; C_BOLD=$'\033[1m'; C_NC=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''; C_NC=''
fi

_ts()      { date '+%Y-%m-%d %H:%M:%S'; }
log_info() { printf '%s %s[i]%s %s\n' "$(_ts)" "$C_BLUE"   "$C_NC" "$*"; }
log_ok()   { printf '%s %s[✓]%s %s\n' "$(_ts)" "$C_GREEN"  "$C_NC" "$*"; }
log_warn() { printf '%s %s[!]%s %s\n' "$(_ts)" "$C_YELLOW" "$C_NC" "$*"; }
log_err()  { printf '%s %s[✗]%s %s\n' "$(_ts)" "$C_RED"    "$C_NC" "$*" >&2; }
log_step() { printf '\n%s━━━━━━━━━━ %s ━━━━━━━━━━%s\n' "$C_CYAN" "$*" "$C_NC"; }

psi_load_env() {
  if [[ -f "$PSI_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$PSI_ENV_FILE"
  else
    log_err "Config file $PSI_ENV_FILE not found. Re-run install.sh."
    return 1
  fi
}

psi_name()       { printf 'psiphon-%s' "$1"; }
psi_socks_port() { echo $(( START_PORT + $1 - 1 )); }
psi_http_port()  { echo $(( HTTP_START_PORT + $1 - 1 )); }

# Create (or re-create) one instance with plain "docker run" (no compose dependency)
psi_run_container() {
  local i="$1" name sp hp
  local -a args
  name="$(psi_name "$i")"; sp="$(psi_socks_port "$i")"; hp="$(psi_http_port "$i")"
  docker rm -f "$name" >/dev/null 2>&1 || true
  args=(-d --name "$name" --restart always --network "$DOCKER_NETWORK"
        --label psiphon.manager=1 --label "psiphon.index=$i"
        -p "${BIND_ADDRESS}:${sp}:1080"
        --ulimit nofile=65535:65535
        --log-driver json-file --log-opt max-size=10m --log-opt max-file=3
        -v "${CONF_DIR}/instances/${i}/psiphon.json:/config/psiphon.json:ro"
        -v "${STATE_DIR}/data/${i}:/data")
  if [[ "${ENABLE_HTTP_PROXY:-true}" == "true" ]]; then
    args+=(-p "${BIND_ADDRESS}:${hp}:8080")
  fi
  mkdir -p "${STATE_DIR}/data/${i}"
  docker run "${args[@]}" "$IMAGE_NAME" >/dev/null
}

# Make sure every instance exists; remove instances above CONTAINER_COUNT
psi_ensure_containers() {
  local i name idx
  for (( i = 1; i <= CONTAINER_COUNT; i++ )); do
    name="$(psi_name "$i")"
    if ! psi_container_exists "$name"; then
      log_warn "[$name] missing -> creating"
      psi_run_container "$i" || log_err "[$name] could not be created"
    fi
  done
  while read -r name; do
    [[ -z "$name" ]] && continue
    idx="${name#psiphon-}"
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx > CONTAINER_COUNT )); then
      docker rm -f "$name" >/dev/null 2>&1 || true
      rm -f "${STATE_DIR}/status/instance-${idx}"
      log_info "[$name] removed (above CONTAINER_COUNT)"
    fi
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^psiphon-[0-9]+$' || true)
}

psi_container_exists()  { docker inspect "$1" >/dev/null 2>&1; }
psi_container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

# True when the latest "Tunnels" notice in the container log reports >= 1 tunnel.
psi_tunnel_established() {
  local last re='"count":[1-9]'
  last="$(docker logs --tail 300 "$1" 2>&1 | grep '"Tunnels"' | tail -n1)" || true
  [[ "$last" =~ $re ]]
}

# Probe a SOCKS5 port; prints "ip|country" on success.
psi_probe() {
  local port="$1" ep url fip fcc resp ip country
  for ep in "http://ipinfo.io/json|.ip|.country" \
            "http://ip-api.com/json|.query|.countryCode" \
            "https://ifconfig.co/json|.ip|.country_iso"; do
    IFS='|' read -r url fip fcc <<<"$ep"
    resp="$(curl -sS --max-time "${PROBE_TIMEOUT:-20}" --socks5-hostname "127.0.0.1:${port}" \
            -H 'Accept: application/json' "$url" 2>/dev/null)" || continue
    ip="$(jq -r "${fip} // empty" <<<"$resp" 2>/dev/null)" || continue
    [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || continue
    country="$(jq -r "${fcc} // \"??\"" <<<"$resp" 2>/dev/null)" || country="??"
    printf '%s|%s\n' "$ip" "${country:-??}"
    return 0
  done
  return 1
}

# ------------------------------ Firewall -------------------------------------
_psi_ipt_purge() {   # remove every rule in <chain> tagged with comment psiphon-<port>
  local chain="$1" port="$2" line
  local -a args
  while read -r line; do
    [[ -z "$line" ]] && continue
    read -ra args <<<"$line"
    args[0]="-D"
    iptables -w 10 "${args[@]}" 2>/dev/null || true
  done < <(iptables -w 10 -S "$chain" 2>/dev/null | grep -E -- "--comment \"?psiphon-${port}\"?( |$)" || true)
}

_psi_fw_port() {
  local port="$1" src
  local -a srcs=() base=()
  if [[ "${ALLOWED_SOURCES:-any}" == "any" ]]; then
    srcs=(any)
  else
    IFS=',' read -ra srcs <<<"${ALLOWED_SOURCES// /}"
  fi

  # UFW (host-level policy)
  local ufw_state=""
  command -v ufw >/dev/null 2>&1 && ufw_state="$(ufw status 2>/dev/null || true)"
  if [[ "$ufw_state" == *"Status: active"* ]]; then
    for src in "${srcs[@]}"; do
      if [[ "$src" == "any" ]]; then
        ufw allow "${port}/tcp" comment "psiphon" >/dev/null 2>&1 || true
      else
        ufw allow from "$src" to any port "$port" proto tcp comment "psiphon" >/dev/null 2>&1 || true
      fi
    done
  fi

  # iptables INPUT (rewrite)
  _psi_ipt_purge INPUT "$port"
  for src in "${srcs[@]}"; do
    if [[ "$src" == "any" ]]; then
      iptables -w 10 -I INPUT -p tcp --dport "$port" -m comment --comment "psiphon-${port}" -j ACCEPT
    else
      iptables -w 10 -I INPUT -s "$src" -p tcp --dport "$port" -m comment --comment "psiphon-${port}" -j ACCEPT
    fi
  done

  # DOCKER-USER (Docker-published ports bypass UFW, so enforce here as well)
  if iptables -w 10 -nL DOCKER-USER >/dev/null 2>&1; then
    _psi_ipt_purge DOCKER-USER "$port"
    base=(-p tcp -m conntrack --ctorigdstport "$port" --ctdir ORIGINAL -m comment --comment "psiphon-${port}")
    if [[ "${srcs[0]}" == "any" ]]; then
      iptables -w 10 -I DOCKER-USER "${base[@]}" -j ACCEPT
    else
      iptables -w 10 -I DOCKER-USER "${base[@]}" -j DROP
      for src in "${srcs[@]}"; do
        iptables -w 10 -I DOCKER-USER -s "$src" "${base[@]}" -j ACCEPT
      done
    fi
  fi
}

# ------------------- Keep existing services (3x-ui, SSH, web...) open --------
psi_xui_db() {
  local db
  for db in "${XUI_DB:-}" /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /etc/x-ui/db/x-ui.db; do
    if [[ -n "$db" && -f "$db" ]]; then echo "$db"; return 0; fi
  done
  return 1
}

# Prints "port" lines from the 3x-ui database. STRICTLY read-only, never writes.
psi_xui_ports() {
  local db v
  db="$(psi_xui_db)" || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  sqlite3 -readonly -cmd ".timeout 5000" "$db" "SELECT port FROM inbounds;" 2>/dev/null || true
  for v in webPort subPort; do
    sqlite3 -readonly -cmd ".timeout 5000" "$db" "SELECT value FROM settings WHERE key='${v}';" 2>/dev/null || true
  done
  # 3x-ui defaults when the keys are not stored yet
  echo 2053; echo 2096
}

# Prints "port proto" for every socket already listening on a public address
psi_listening_ports() {
  ss -H -tulnp 2>/dev/null | awk '
    {
      proto = ($1 == "udp") ? "udp" : "tcp"
      if ($0 ~ /docker-proxy/) next
      local_addr = $5
      n = split(local_addr, a, ":"); port = a[n]
      addr = substr(local_addr, 1, length(local_addr) - length(port) - 1)
      if (port !~ /^[0-9]+$/) next
      if (addr ~ /^127\./ || addr == "[::1]" || addr ~ /%lo$/) next
      print port, proto
    }' | sort -u || true
}

_psi_is_proxy_port() {
  local p="$1" s_end h_end
  s_end=$(( START_PORT + CONTAINER_COUNT - 1 )); h_end=$(( HTTP_START_PORT + CONTAINER_COUNT - 1 ))
  (( p >= START_PORT && p <= s_end )) && return 0
  [[ "${ENABLE_HTTP_PROXY:-true}" == "true" ]] && (( p >= HTTP_START_PORT && p <= h_end )) && return 0
  return 1
}

# Allow (never remove) every port that existing services use. Safe to run repeatedly.
psi_keep_existing_ports() {
  local ufw_state="" port proto count=0
  local -A done_=()
  command -v ufw >/dev/null 2>&1 && ufw_state="$(ufw status 2>/dev/null || true)"
  [[ "$ufw_state" == *"Status: active"* || "${1:-}" == "--force" ]] || return 0
  while read -r port proto; do
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    (( port >= 1 && port <= 65535 )) || continue
    _psi_is_proxy_port "$port" && continue
    [[ -n "${done_[$port/$proto]:-}" ]] && continue
    done_[$port/$proto]=1
    if [[ "$ufw_state" != *"${port}/${proto} "* ]]; then
      ufw allow "${port}/${proto}" comment "keep-existing" >/dev/null 2>&1 || true
      count=$((count + 1))
    fi
  done < <(
    psi_listening_ports
    psi_xui_ports | awk '/^[0-9]+$/ {print $1, "tcp"; print $1, "udp"}'
    tr ', ' '\n\n' <<<"${KEEP_EXTRA_PORTS:-}" | awk '/^[0-9]+$/ {print $1, "tcp"; print $1, "udp"}'
  )
  (( count > 0 )) && log_info "Firewall: kept ${count} existing service port(s) open"
  return 0
}

psi_fw_instance() {   # serialized with a lock (instances are repaired in parallel)
  local i="$1"
  (
    flock -w 120 8 || exit 1
    _psi_fw_port "$(psi_socks_port "$i")"
    if [[ "${ENABLE_HTTP_PROXY:-true}" == "true" ]]; then
      _psi_fw_port "$(psi_http_port "$i")"
    fi
  ) 8>/run/psiphon-fw.lock
}

# ------------------------------ State ----------------------------------------
psi_state_write() {   # <i> <ip> <country> <status>
  mkdir -p "${STATE_DIR}/status"
  printf '%s|%s|%s|%s\n' "$2" "$3" "$4" "$(date '+%F %T')" > "${STATE_DIR}/status/instance-$1"
}
psi_state_read() {
  local f="${STATE_DIR}/status/instance-$1"
  if [[ -f "$f" ]]; then cat "$f"; else echo "-|-|UNKNOWN|-"; fi
}

# ------------------------------ Health / Repair ------------------------------
psi_wait_ready() {   # <i> <timeout> ; prints ip|country on success
  local i="$1" timeout="$2" name port start n=0 res
  name="$(psi_name "$i")"; port="$(psi_socks_port "$i")"; start=$SECONDS
  while (( SECONDS - start < timeout )); do
    if psi_container_running "$name"; then
      if psi_tunnel_established "$name" || (( n % 6 == 0 )); then
        if res="$(psi_probe "$port")"; then echo "$res"; return 0; fi
      fi
    fi
    n=$((n + 1))
    sleep 5
  done
  psi_probe "$port"
}

psi_repair() {
  local i="$1" name port attempt res
  name="$(psi_name "$i")"; port="$(psi_socks_port "$i")"
  for (( attempt = 1; attempt <= MAX_RETRIES; attempt++ )); do
    log_warn "[$name:$port] auto-repair attempt ${attempt}/${MAX_RETRIES}"
    # Step 1: restart (last attempt = full recreate)
    if (( attempt == MAX_RETRIES )) || ! psi_container_exists "$name"; then
      psi_run_container "$i" || log_warn "[$name] recreate failed"
    else
      docker restart -t 10 "$name" >/dev/null 2>&1 \
        || psi_run_container "$i" \
        || log_warn "[$name] restart failed"
    fi
    # Step 2: rewrite firewall rules
    psi_fw_instance "$i" || log_warn "[$name] firewall rewrite failed"
    # Step 3: re-test
    if res="$(psi_wait_ready "$i" "${REPAIR_WAIT:-120}")"; then
      psi_state_write "$i" "${res%%|*}" "${res##*|}" "HEALTHY"
      log_ok "[$name:$port] repaired -> ${res%%|*} (${res##*|})"
      return 0
    fi
  done
  psi_state_write "$i" "-" "-" "FAILED"
  log_err "[$name:$port] still unhealthy after ${MAX_RETRIES} attempts"
  return 1
}

psi_check_instance() {   # <i> <bootstrap|watchdog|status>
  local i="$1" mode="${2:-watchdog}" name port res=""
  name="$(psi_name "$i")"; port="$(psi_socks_port "$i")"

  if ! psi_container_running "$name"; then
    if [[ "$mode" == "status" ]]; then psi_state_write "$i" "-" "-" "DOWN"; return 1; fi
    log_warn "[$name:$port] container is not running"
    psi_repair "$i"; return $?
  fi

  if [[ "$mode" == "bootstrap" ]]; then
    res="$(psi_wait_ready "$i" "${BOOTSTRAP_TIMEOUT:-240}")" || res=""
  else
    res="$(psi_probe "$port")" || { sleep 10; res="$(psi_probe "$port")" || res=""; }
  fi

  if [[ -n "$res" ]]; then
    psi_state_write "$i" "${res%%|*}" "${res##*|}" "HEALTHY"
    log_ok "[$name:$port] healthy -> ${res%%|*} (${res##*|})"
    return 0
  fi
  if [[ "$mode" == "status" ]]; then psi_state_write "$i" "-" "-" "DOWN"; return 1; fi
  log_warn "[$name:$port] no response through proxy"
  psi_repair "$i"
}

psi_check_all() {   # parallel checks, returns number of failed instances (capped)
  local mode="${1:-watchdog}" i p fail=0
  local -a pids=()
  for (( i = 1; i <= CONTAINER_COUNT; i++ )); do
    ( set +eE; trap - ERR; psi_check_instance "$i" "$mode" ) &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do
    wait "$p" || fail=$((fail + 1))
  done
  return $(( fail > 0 ? 1 : 0 ))
}

# ------------------------------ Dashboard ------------------------------------
psi_dashboard() {
  local i st ip cc status ts color healthy=0 http sep pub
  sep="+------+--------------+--------+--------+-----------------------------------------+---------+------------+"
  pub="$(curl -s4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ "$pub" =~ ^[0-9.]+$ ]] || pub="<SERVER_IP>"

  printf '\n%s%s%s\n' "$C_BLUE" "$sep" "$C_NC"
  printf '%s| %-4s | %-12s | %-6s | %-6s | %-39s | %-7s | %-10s |%s\n' \
    "$C_BOLD" "#" "Container" "SOCKS5" "HTTP" "Psiphon Exit IP" "Country" "Health" "$C_NC"
  printf '%s%s%s\n' "$C_BLUE" "$sep" "$C_NC"
  for (( i = 1; i <= CONTAINER_COUNT; i++ )); do
    st="$(psi_state_read "$i")"
    IFS='|' read -r ip cc status ts <<<"$st"
    case "$status" in
      HEALTHY) color="$C_GREEN"; healthy=$((healthy + 1)) ;;
      FAILED|DOWN) color="$C_RED" ;;
      *) color="$C_YELLOW" ;;
    esac
    if [[ "${ENABLE_HTTP_PROXY:-true}" == "true" ]]; then http="$(psi_http_port "$i")"; else http="-"; fi
    printf '| %-4s | %-12s | %-6s | %-6s | %-39s | %-7s | %s%-10s%s |\n' \
      "$i" "$(psi_name "$i")" "$(psi_socks_port "$i")" "$http" "$ip" "$cc" "$color" "$status" "$C_NC"
  done
  printf '%s%s%s\n' "$C_BLUE" "$sep" "$C_NC"

  if (( healthy == CONTAINER_COUNT )); then color="$C_GREEN"; elif (( healthy > 0 )); then color="$C_YELLOW"; else color="$C_RED"; fi
  printf '%s  Healthy: %d / %d%s   (server: %s)\n' "$color" "$healthy" "$CONTAINER_COUNT" "$C_NC" "$pub"

  printf '\n%s  Useful commands%s\n' "$C_CYAN" "$C_NC"
  printf '  %-44s %s\n' \
    "psiphon-watchdog.sh --status"            "live health table" \
    "psiphon-watchdog.sh"                     "run a check + repair cycle now" \
    "docker ps --filter name=psiphon-"        "list containers" \
    "docker logs -f --tail 100 psiphon-1"     "follow logs of instance 1" \
    "docker restart psiphon-3"                "restart instance 3" \
    "docker stats --no-stream \$(docker ps -q --filter label=psiphon.manager=1)" "resource usage" \
    "tail -f $WATCHDOG_LOG"                   "watchdog log" \
    "less $INSTALL_LOG"                       "installer log" \
    "cat ${XRAY_SNIPPET:-/etc/psiphon-manager/xray-psiphon-outbounds.json}" "3x-ui outbounds snippet" \
    "curl --socks5-hostname ${pub}:${START_PORT} http://ipinfo.io/json" "client test"
  printf '\n'
}
LIB_EOF
  chmod 644 "$LIB_FILE"
}

# =============================================================================
# Helpers
# =============================================================================
die() { log_err "$*"; log_err "Full log: $LOG_FILE"; exit 1; }

on_error() {
  local code=$? line="$1" cmd="$2"
  log_err "Unexpected failure (exit ${code}) at line ${line}: ${cmd}"
  log_err "Full log: $LOG_FILE"
  exit "$code"
}

retry() {   # retry <times> <cmd...>
  local n="$1" i; shift
  for (( i = 1; i <= n; i++ )); do
    if "$@"; then return 0; fi
    log_warn "Attempt ${i}/${n} failed: $*"
    sleep $(( i * 5 ))
  done
  return 1
}

setup_logging() {
  if [[ -t 1 ]]; then export PSI_COLOR=1; fi
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"; chmod 640 "$LOG_FILE"
  printf '\n===== Psiphon installer run: %s =====\n' "$(date '+%F %T')" >> "$LOG_FILE"
  # terminal gets colors, log file gets clean text
  exec > >(tee >(sed -u 's/\x1B\[[0-9;]*[A-Za-z]//g' >> "$LOG_FILE")) 2>&1
}

validate_settings() {
  local v p s_end h_end
  for v in CONTAINER_COUNT START_PORT HTTP_START_PORT MAX_RETRIES BOOTSTRAP_TIMEOUT REPAIR_WAIT PROBE_TIMEOUT; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be a positive integer (got '${!v}')"
  done
  (( CONTAINER_COUNT >= 1 && CONTAINER_COUNT <= 200 )) || die "CONTAINER_COUNT must be 1..200"
  (( MAX_RETRIES >= 1 )) || die "MAX_RETRIES must be >= 1"
  s_end=$(( START_PORT + CONTAINER_COUNT - 1 ))
  h_end=$(( HTTP_START_PORT + CONTAINER_COUNT - 1 ))
  (( START_PORT >= 1 && s_end <= 65535 )) || die "SOCKS port range ${START_PORT}-${s_end} is invalid"
  if [[ "$ENABLE_HTTP_PROXY" == "true" ]]; then
    (( HTTP_START_PORT >= 1 && h_end <= 65535 )) || die "HTTP port range ${HTTP_START_PORT}-${h_end} is invalid"
    if (( START_PORT <= h_end && HTTP_START_PORT <= s_end )); then
      die "SOCKS range ${START_PORT}-${s_end} overlaps HTTP range ${HTTP_START_PORT}-${h_end}"
    fi
  fi
  [[ -z "$EGRESS_REGION" || "$EGRESS_REGION" =~ ^[A-Z]{2}$ ]] || die "EGRESS_REGION must be a 2-letter code (e.g. DE)"

  # ports must be free (or already held by docker-proxy from a previous run)
  for (( p = START_PORT; p <= s_end; p++ )); do
    if ss -tlnpH "( sport = :$p )" 2>/dev/null | grep -v docker-proxy | grep -q .; then
      die "Port $p is already in use by another process"
    fi
  done
}

banner() {
  printf '%s\n' "${C_CYAN}╔══════════════════════════════════════════════════════════╗"
  printf '%s\n' "║        Psiphon Multi-Instance Manager - Installer        ║"
  printf '%s\n' "╚══════════════════════════════════════════════════════════╝${C_NC}"
  log_info "Instances: ${CONTAINER_COUNT} | SOCKS5: ${START_PORT}-$(( START_PORT + CONTAINER_COUNT - 1 )) | HTTP: $([[ $ENABLE_HTTP_PROXY == true ]] && echo "${HTTP_START_PORT}-$(( HTTP_START_PORT + CONTAINER_COUNT - 1 ))" || echo off) | Region: ${EGRESS_REGION:-auto}"
  if [[ "$ALLOWED_SOURCES" == "any" ]]; then
    log_warn "ALLOWED_SOURCES=any -> proxies are reachable by EVERYONE (open proxy). Restrict it for production."
  fi
}

# =============================================================================
# 2. Kernel & network tuning
# =============================================================================
set_sysctl() {
  local key="$1" val="$2" file="/etc/sysctl.conf" re
  re="^[[:space:]]*#?[[:space:]]*${key//./\\.}[[:space:]]*="
  if grep -Eq "$re" "$file"; then
    sed -ri "s|${re}.*|${key} = ${val}|" "$file"
  else
    printf '%s = %s\n' "$key" "$val" >> "$file"
  fi
}

tune_kernel() {
  log_step "2/8 Kernel & network tuning"
  touch /etc/sysctl.conf
  grep -q "Psiphon Manager tuning" /etc/sysctl.conf || printf '\n# ---- Psiphon Manager tuning ----\n' >> /etc/sysctl.conf

  if command -v modprobe >/dev/null 2>&1; then modprobe tcp_bbr 2>/dev/null || true; fi
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    set_sysctl net.core.default_qdisc fq
    set_sysctl net.ipv4.tcp_congestion_control bbr
  else
    log_warn "Kernel $(uname -r) does not expose BBR (container/OpenVZ VPS?). Skipping BBR."
  fi

  set_sysctl net.core.somaxconn 65535
  set_sysctl net.core.netdev_max_backlog 65535
  set_sysctl net.ipv4.tcp_fastopen 3
  set_sysctl net.ipv4.tcp_rmem "4096 87380 16777216"
  set_sysctl net.ipv4.tcp_wmem "4096 65536 16777216"
  set_sysctl net.ipv4.ip_forward 1

  if sysctl -p >/dev/null 2>&1; then
    log_ok "sysctl settings applied and persisted in /etc/sysctl.conf"
  else
    log_warn "Some sysctl keys could not be applied (virtualization limits):"
    sysctl -p 2>&1 | grep -iE 'error|denied|cannot' || true
  fi
  log_info "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown) | qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
}

# =============================================================================
# 3. System update & packages
# =============================================================================
apt_install() {
  if ! apt-get install "${APT_OPTS[@]}" --no-install-recommends "$@"; then
    log_warn "apt install failed, running self-fix (dpkg --configure -a / --fix-broken)"
    dpkg --configure -a || true
    apt-get --fix-broken install "${APT_OPTS[@]}" || true
    apt-get install "${APT_OPTS[@]}" --no-install-recommends "$@"
  fi
}

pkg_available() {
  local out re='Candidate: [^(]'
  out="$(apt-cache policy "$1" 2>/dev/null)" || return 1
  [[ "$out" =~ $re ]]
}

configure_docker_mirror() {
  [[ -z "$DOCKER_REGISTRY_MIRROR" ]] && return 0
  local f=/etc/docker/daemon.json tmp
  mkdir -p /etc/docker
  [[ -s "$f" ]] || echo '{}' > "$f"
  tmp="$(mktemp)"
  jq --arg m "$DOCKER_REGISTRY_MIRROR" '."registry-mirrors" = ((."registry-mirrors" // []) + [$m] | unique)' "$f" > "$tmp" && mv "$tmp" "$f"
  systemctl restart docker
  log_ok "Docker registry mirror set: $DOCKER_REGISTRY_MIRROR"
}

system_setup() {
  log_step "3/8 System update & dependencies"
  dpkg --configure -a || true
  retry 3 apt-get update -q -o DPkg::Lock::Timeout=600 || die "apt-get update failed"

  if [[ "$SKIP_UPGRADE" != "true" ]]; then
    if ! apt-get upgrade "${APT_OPTS[@]}"; then
      log_warn "Upgrade failed, trying --fix-broken"
      apt-get --fix-broken install "${APT_OPTS[@]}" || true
      apt-get upgrade "${APT_OPTS[@]}" || log_warn "apt-get upgrade still failing, continuing"
    fi
    log_ok "System upgraded"
  fi

  apt_install curl wget git jq ufw iptables net-tools cron bc ca-certificates sqlite3 \
              iproute2 procps kmod util-linux logrotate gnupg

  if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
    log_ok "Docker already installed: $(docker --version)"
  else
    apt_install docker.io
  fi

  # Compose is installed as a tool only; the manager itself uses plain "docker run"
  # (docker-compose 1.29 is incompatible with Docker Engine 29+).
  if docker compose version >/dev/null 2>&1; then
    log_ok "Compose v2 already available"
  elif pkg_available docker-compose-v2; then
    apt_install docker-compose-v2 || log_warn "docker-compose-v2 install failed (not required)"
  elif ! command -v docker-compose >/dev/null 2>&1 && pkg_available docker-compose; then
    apt_install docker-compose || log_warn "docker-compose install failed (not required)"
  fi
  if ! docker buildx version >/dev/null 2>&1 && pkg_available docker-buildx; then
    apt_install docker-buildx || log_warn "docker-buildx install failed (legacy builder will be used)"
  fi

  systemctl enable --now containerd >/dev/null 2>&1 || true
  systemctl enable --now docker
  systemctl enable --now cron
  configure_docker_mirror
  log_ok "Docker & Cron enabled at boot"
}

# =============================================================================
# 4. Pre-flight verification + self-fix
# =============================================================================
docker_healthy() {
  systemctl is-active --quiet docker || return 1
  timeout 30 docker info >/dev/null 2>&1 || return 1
  docker network rm psiphon_preflight >/dev/null 2>&1 || true
  docker network create psiphon_preflight >/dev/null 2>&1 || return 1
  docker network rm psiphon_preflight >/dev/null 2>&1 || return 1
}

network_healthy() {
  curl -fsS -I --max-time 15 -o /dev/null https://github.com 2>/dev/null
}

preflight() {
  log_step "4/8 Pre-flight verification"
  local t; local -a missing=()
  for t in curl jq ufw iptables docker bc crontab ss; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if (( ${#missing[@]} > 0 )); then
    log_warn "Missing tools: ${missing[*]} -> repairing"
    apt-get --fix-broken install "${APT_OPTS[@]}" || true
    apt_install curl jq ufw iptables bc cron iproute2 docker.io
  fi

  if ! docker_healthy; then
    log_warn "Docker is unhealthy -> fix-broken + service restart"
    apt-get --fix-broken install "${APT_OPTS[@]}" || true
    systemctl daemon-reload
    systemctl restart containerd >/dev/null 2>&1 || true
    systemctl restart docker
    sleep 8
    docker_healthy || die "Docker is still not working. Check: journalctl -u docker --no-pager | tail -50"
  fi
  log_ok "Docker engine OK ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"

  if docker compose version >/dev/null 2>&1; then
    log_ok "Compose OK ($(docker compose version --short 2>/dev/null))"
  else
    log_info "Compose v2 not present (not required, containers are managed directly)"
  fi

  if ! network_healthy; then
    log_warn "Outbound HTTPS check failed -> fix-broken + DNS/Docker restart"
    apt-get --fix-broken install "${APT_OPTS[@]}" || true
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
    systemctl restart docker
    sleep 5
    network_healthy && log_ok "Network recovered" || log_warn "GitHub still unreachable; binary download may fail"
  else
    log_ok "Outbound network OK"
  fi

  if timeout 90 docker run --rm hello-world >/dev/null 2>&1; then
    log_ok "docker run hello-world OK"
    docker rmi hello-world >/dev/null 2>&1 || true
  else
    log_warn "Docker Hub pull failed (often blocked). Not required: the Psiphon image is built locally FROM scratch."
  fi
}

# =============================================================================
# 5. Deployment
# =============================================================================
write_env_file() {
  local v
  mkdir -p "$CONF_DIR" "$STATE_DIR/status" "$STATE_DIR/data" "$BASE_DIR/bin"
  {
    echo "# Psiphon Manager config - generated $(date '+%F %T')"
    for v in CONTAINER_COUNT START_PORT HTTP_START_PORT ENABLE_HTTP_PROXY EGRESS_REGION \
             ALLOWED_SOURCES BIND_ADDRESS DOCKER_NETWORK MAX_RETRIES BOOTSTRAP_TIMEOUT \
             REPAIR_WAIT PROBE_TIMEOUT BASE_DIR CONF_DIR STATE_DIR IMAGE_NAME \
             WATCHDOG_LOG UFW_ENABLE KEEP_EXTRA_PORTS XUI_DB XRAY_SNIPPET; do
      printf '%s=%q\n' "$v" "${!v}"
    done
    printf 'INSTALL_LOG=%q\n' "$LOG_FILE"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  INSTALL_LOG="$LOG_FILE"
}

is_elf() { [[ -s "$1" && "$(head -c4 "$1" | tail -c3)" == "ELF" ]]; }

binary_runs() {   # the binary must actually execute on this host/arch
  local out rc=0
  chmod +x "$1" 2>/dev/null || true
  out="$(timeout 10 "$1" -h 2>&1)" || rc=$?
  if (( rc == 126 || rc == 127 )) || [[ "$out" == *"exec format error"* || "$out" == *"cannot execute"* ]]; then
    log_warn "Binary does not execute on this host (rc=$rc): ${out:0:200}"
    return 1
  fi
  return 0
}

download_binary() {
  local bin="${BASE_DIR}/bin/psiphon-tunnel-core" arch url tmp
  local -a urls=()
  arch="$(uname -m)"
  [[ -n "$PSIPHON_BINARY_URL" ]] && urls+=("$PSIPHON_BINARY_URL")
  case "$arch" in
    x86_64|amd64)
      urls+=("https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
             "https://github.com/ehsanecc/psiphon-builder/releases/latest/download/psiphon-tunnel-core-linux-x86_64") ;;
    aarch64|arm64)
      urls+=("https://github.com/ehsanecc/psiphon-builder/releases/latest/download/psiphon-tunnel-core-linux-arm64") ;;
    *)
      (( ${#urls[@]} > 0 )) || die "Unsupported architecture '$arch'. Set PSIPHON_BINARY_URL." ;;
  esac

  if [[ "$FORCE_BINARY_UPDATE" != "true" ]] && is_elf "$bin" && binary_runs "$bin"; then
    log_ok "Psiphon binary already present ($(du -h "$bin" | cut -f1))"
    return 0
  fi

  for url in "${urls[@]}"; do
    log_info "Downloading Psiphon tunnel-core: $url"
    tmp="$(mktemp)"
    if curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 --max-time 600 -o "$tmp" "$url" \
       || wget -q --tries=3 --timeout=30 -O "$tmp" "$url"; then
      if is_elf "$tmp" && (( $(stat -c %s "$tmp") > 1000000 )) && binary_runs "$tmp"; then
        install -m 755 "$tmp" "$bin"; rm -f "$tmp"
        log_ok "Binary installed: $bin ($(du -h "$bin" | cut -f1))"
        return 0
      fi
      log_warn "Downloaded file is not a usable binary, trying next source"
    fi
    rm -f "$tmp"
  done
  die "Could not download the Psiphon binary from any source"
}

build_image() {   # build_image <scratch|debian>
  local variant="${1:-scratch}" ctx="${BASE_DIR}/build" rootfs bin="${BASE_DIR}/bin/psiphon-tunnel-core" lib
  rootfs="${ctx}/rootfs"
  rm -rf "$ctx"
  mkdir -p "$rootfs"/{psiphon,config,data,tmp,etc/ssl/certs}
  chmod 1777 "$rootfs/tmp"
  cp "$bin" "$rootfs/psiphon/psiphon-tunnel-core"
  chmod 755 "$rootfs/psiphon/psiphon-tunnel-core"
  cp -L /etc/ssl/certs/ca-certificates.crt "$rootfs/etc/ssl/certs/ca-certificates.crt"

  if [[ "$variant" == "scratch" ]]; then
    printf 'hosts: files dns\n' > "$rootfs/etc/nsswitch.conf"
    # scratch has no libc: bundle shared libraries if the binary is dynamic
    if ldd "$bin" >/dev/null 2>&1; then
      while read -r lib; do
        if [[ -e "$lib" ]]; then cp -L --parents "$lib" "$rootfs/"; fi
      done < <(ldd "$bin" | grep -oE '/[^[:space:]]+' | sort -u)
      log_info "Dynamic binary: bundled shared libraries into image"
    fi
    printf 'FROM scratch\n' > "${ctx}/Dockerfile"
  else
    printf 'FROM debian:bookworm-slim\n' > "${ctx}/Dockerfile"
  fi
  cat >> "${ctx}/Dockerfile" <<'EOF'
COPY rootfs/ /
WORKDIR /data
ENTRYPOINT ["/psiphon/psiphon-tunnel-core"]
CMD ["-config", "/config/psiphon.json"]
EOF
  if ! retry 2 docker build -q -t "$IMAGE_NAME" "$ctx" >/dev/null; then
    log_warn "docker build (${variant}) failed"
    return 1
  fi
  log_ok "Image ${IMAGE_NAME} built (base: ${variant})"
}

write_psiphon_config() {   # write_psiphon_config <file> <listen-interface>
  jq -n \
    --arg pc  "$PSIPHON_PROPAGATION_CHANNEL_ID" \
    --arg sp  "$PSIPHON_SPONSOR_ID" \
    --arg rsl "$PSIPHON_REMOTE_SERVER_LIST_URL" \
    --arg key "$PSIPHON_RSL_PUBKEY" \
    --arg reg "$EGRESS_REGION" \
    --arg li  "$2" \
    '{
      LocalSocksProxyPort: 1080,
      LocalHttpProxyPort: 8080,
      PropagationChannelId: $pc,
      SponsorId: $sp,
      RemoteServerListDownloadFilename: "remote_server_list",
      RemoteServerListSignaturePublicKey: $key,
      RemoteServerListUrl: $rsl,
      UseIndistinguishableTLS: true,
      DataRootDirectory: "/data"
    }
    + (if $li  != "" then {ListenInterface: $li} else {} end)
    + (if $reg != "" then {EgressRegion: $reg} else {} end)' > "$1"
  chmod 644 "$1"
}

# Real runtime test: start a throw-away container and verify the SOCKS listener comes up.
image_selftest() {
  local listen dir name="psiphon-selftest" logs t
  dir="$(mktemp -d /tmp/psiphon-selftest.XXXXXX)"
  mkdir -p "$dir/data"
  for listen in any eth0; do
    write_psiphon_config "$dir/psiphon.json" "$listen"
    docker rm -f "$name" >/dev/null 2>&1 || true
    if ! logs="$(docker run -d --name "$name" --network "$DOCKER_NETWORK" \
                  -v "$dir/psiphon.json:/config/psiphon.json:ro" -v "$dir/data:/data" \
                  "$IMAGE_NAME" 2>&1)"; then
      log_warn "Self-test container could not start: ${logs:0:300}"
      continue
    fi
    for (( t = 0; t < 40; t += 2 )); do
      sleep 2
      logs="$(docker logs --tail 200 "$name" 2>&1 || true)"
      if [[ "$logs" == *ListeningSocksProxyPort* ]]; then break; fi
      psi_container_running "$name" || break
    done
    if psi_container_running "$name"; then
      LISTEN_INTERFACE="$listen"
      docker rm -f "$name" >/dev/null 2>&1 || true
      rm -rf "$dir"
      if [[ "$logs" == *ListeningSocksProxyPort* ]]; then
        log_ok "Image self-test passed (SOCKS listener up, ListenInterface=${listen})"
      else
        log_ok "Image self-test passed (process stable, ListenInterface=${listen})"
      fi
      return 0
    fi
    log_warn "Self-test with ListenInterface=${listen} failed. Container output:"
    printf '%s\n' "$logs" | tail -n 15
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
  rm -rf "$dir"
  return 1
}

prepare_image() {
  build_image scratch && image_selftest && return 0
  log_warn "scratch image failed -> re-downloading binary and retrying"
  FORCE_BINARY_UPDATE=true download_binary
  build_image scratch && image_selftest && return 0
  log_warn "scratch image still failing -> trying debian:bookworm-slim base"
  if timeout 180 docker pull -q debian:bookworm-slim >/dev/null 2>&1; then
    build_image debian && image_selftest && return 0
  else
    log_warn "Cannot pull debian:bookworm-slim (registry unreachable)"
  fi
  die "Psiphon image failed all self-tests (see container output above)"
}

generate_instance_configs() {
  local i dir
  for (( i = 1; i <= CONTAINER_COUNT; i++ )); do
    dir="${CONF_DIR}/instances/${i}"
    mkdir -p "$dir" "${STATE_DIR}/data/${i}"
    write_psiphon_config "${dir}/psiphon.json" "$LISTEN_INTERFACE"
  done
  # drop state of instances that no longer exist
  mkdir -p "${STATE_DIR}/status"
  find "${STATE_DIR}/status" -name 'instance-*' -type f 2>/dev/null | while read -r f; do
    i="${f##*-}"; (( i > CONTAINER_COUNT )) && rm -f "$f" || true
  done
  log_ok "Generated ${CONTAINER_COUNT} Psiphon configs in ${CONF_DIR}/instances"
}

deploy() {
  log_step "5/8 Multi-instance Psiphon deployment"
  local i
  if docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
    log_ok "Docker network ${DOCKER_NETWORK} exists"
  else
    if [[ -n "$DOCKER_SUBNET" ]]; then
      docker network create --driver bridge --subnet "$DOCKER_SUBNET" "$DOCKER_NETWORK" >/dev/null
    else
      docker network create --driver bridge "$DOCKER_NETWORK" >/dev/null
    fi
    log_ok "Created isolated bridge network ${DOCKER_NETWORK}"
  fi

  download_binary
  prepare_image
  generate_instance_configs

  for (( i = 1; i <= CONTAINER_COUNT; i++ )); do
    retry 2 psi_run_container "$i" || die "Could not start $(psi_name "$i")"
  done
  psi_ensure_containers
  log_ok "Started ${CONTAINER_COUNT} containers (restart=always) on ${DOCKER_NETWORK}"
}

configure_firewall() {
  log_info "Configuring firewall (existing services are kept open)"
  local p i db ufw_state=""
  local -a ssh_ports=()

  if db="$(psi_xui_db)"; then
    log_ok "3x-ui panel detected (${db}). Its database is only READ, never modified."
    log_info "3x-ui ports: $(psi_xui_ports | awk '/^[0-9]+$/' | sort -un | tr '\n' ' ')"
  fi

  mapfile -t ssh_ports < <(ss -tlnpH 2>/dev/null | awk '/sshd/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -u)
  (( ${#ssh_ports[@]} > 0 )) || ssh_ports=(22)

  ufw_state="$(ufw status 2>/dev/null || true)"
  if [[ "$ufw_state" == *"Status: active"* || "$UFW_ENABLE" == "true" ]]; then
    for p in "${ssh_ports[@]}"; do ufw allow "${p}/tcp" comment "SSH" >/dev/null 2>&1 || true; done
    # 1) open every port currently used by xray / x-ui / nginx / anything else
    psi_keep_existing_ports --force
    # 2) only then enable UFW (if it was not already active)
    if [[ "$ufw_state" != *"Status: active"* ]]; then
      ufw default deny incoming >/dev/null
      ufw default allow outgoing >/dev/null
      ufw --force enable >/dev/null
    fi
    log_ok "UFW active. SSH: ${ssh_ports[*]} | all existing service ports kept open"
  else
    log_info "UFW_ENABLE=false and UFW is inactive -> leaving UFW off"
  fi

  for (( i = 1; i <= CONTAINER_COUNT; i++ )); do
    psi_fw_instance "$i"
  done
  log_ok "Proxy ports opened in UFW, iptables INPUT and DOCKER-USER"
}

# Ready-to-paste Xray outbounds/balancer for 3x-ui (file only, panel is NOT touched)
generate_xray_snippet() {
  jq -n --argjson n "$CONTAINER_COUNT" --argjson sp "$START_PORT" '{
    outbounds: [ range(0; $n) as $i | {
      tag: "psiphon-\($i + 1)",
      protocol: "socks",
      settings: { servers: [ { address: "127.0.0.1", port: ($sp + $i) } ] }
    } ],
    observatory: {
      subjectSelector: ["psiphon-"],
      probeURL: "https://www.gstatic.com/generate_204",
      probeInterval: "1m",
      enableConcurrency: true
    },
    routing: {
      balancers: [ {
        tag: "psiphon-balancer",
        selector: ["psiphon-"],
        strategy: { type: "leastPing" },
        fallbackTag: "direct"
      } ],
      rules: [ {
        type: "field",
        inboundTag: ["PUT-YOUR-INBOUND-TAG-HERE"],
        network: "tcp",
        balancerTag: "psiphon-balancer"
      } ]
    }
  }' > "$XRAY_SNIPPET"
  chmod 644 "$XRAY_SNIPPET"
  log_ok "3x-ui / Xray snippet written: ${XRAY_SNIPPET} (panel not modified)"
}

# =============================================================================
# 6. Initial health check with auto-repair
# =============================================================================
initial_health_check() {
  log_step "6/8 Health check & self-healing"
  log_info "Waiting for tunnels (up to ${BOOTSTRAP_TIMEOUT}s, all instances in parallel)..."
  if psi_check_all bootstrap; then
    log_ok "All instances passed the health check"
  else
    log_warn "Some instances are unhealthy; the watchdog will keep repairing them every 5 minutes"
  fi
}

# =============================================================================
# 7. Watchdog + cron
# =============================================================================
install_watchdog() {
  log_step "7/8 Watchdog service (24/7)"
  cat > "$WATCHDOG_BIN" <<'WD_EOF'
#!/usr/bin/env bash
# Psiphon watchdog - checks every instance, restarts/repairs dead ones.
# Usage: psiphon-watchdog.sh            -> check + auto-repair cycle
#        psiphon-watchdog.sh --status   -> live health table (no repair)
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# shellcheck disable=SC1091
source /usr/local/lib/psiphon-manager/common.sh || exit 1
psi_load_env || exit 1

ensure_docker() {
  if ! timeout 30 docker info >/dev/null 2>&1; then
    log_warn "Docker daemon not responding -> restarting"
    systemctl restart docker; sleep 15
    timeout 30 docker info >/dev/null 2>&1 || { log_err "Docker still down"; exit 1; }
  fi
  if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
    log_warn "Network $DOCKER_NETWORK missing -> recreating"
    docker network create --driver bridge "$DOCKER_NETWORK" >/dev/null
  fi
}

case "${1:-}" in
  --status)
    PROBE_TIMEOUT=12
    psi_check_all status || true
    psi_dashboard
    ;;
  -h|--help)
    sed -n '2,5p' "$0"
    ;;
  *)
    exec 9>/run/psiphon-watchdog.lock
    flock -n 9 || { log_warn "Another watchdog run is in progress, skipping"; exit 0; }
    log_info "===== watchdog cycle start ====="
    ensure_docker
    psi_ensure_containers
    ( flock -w 120 8 && psi_keep_existing_ports ) 8>/run/psiphon-fw.lock || true
    for (( i = 1; i <= CONTAINER_COUNT; i++ )); do psi_fw_instance "$i" || true; done
    if psi_check_all watchdog; then log_ok "All ${CONTAINER_COUNT} instances healthy"
    else log_warn "Cycle finished with failed instances"; fi
    log_info "===== watchdog cycle end ====="
    ;;
esac
WD_EOF
  chmod 755 "$WATCHDOG_BIN"

  cat > "$CRON_FILE" <<EOF
# Psiphon watchdog - generated by install.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root ${WATCHDOG_BIN} >> ${WATCHDOG_LOG} 2>&1
@reboot root sleep 90 && ${WATCHDOG_BIN} >> ${WATCHDOG_LOG} 2>&1
EOF
  chmod 644 "$CRON_FILE"

  cat > /etc/logrotate.d/psiphon-manager <<EOF
${WATCHDOG_LOG} ${LOG_FILE} {
    weekly
    rotate 4
    size 20M
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  touch "$WATCHDOG_LOG"
  systemctl restart cron
  log_ok "Watchdog: ${WATCHDOG_BIN} | cron: every 5 min + @reboot | log: ${WATCHDOG_LOG}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  require_root
  write_lib
  setup_logging
  # shellcheck disable=SC1090
  source "$LIB_FILE"
  trap 'on_error $LINENO "$BASH_COMMAND"' ERR

  log_step "1/8 Prerequisites"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 UCF_FORCE_CONFFOLD=1
  validate_settings
  banner
  log_ok "Running as root, non-interactive mode enabled"

  tune_kernel
  system_setup
  preflight
  write_env_file
  deploy
  configure_firewall
  generate_xray_snippet
  initial_health_check
  install_watchdog

  log_step "8/8 Dashboard"
  psi_dashboard
  log_ok "Installation finished. Log: ${LOG_FILE}"
  sleep 1
}

main "$@"
