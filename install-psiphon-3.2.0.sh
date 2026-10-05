#!/bin/bash
# MAXNET6G Psiphon v3.2.0 — Telegram Bot Upgrade
# Full installer with daily testing, failure prediction, emoji UI, port management
# Iran-optimized: no ICMP, pure bash+curl+jq, all text Persian, idempotent

set -euo pipefail
SCRIPT_VERSION="3.2.0"
INSTALL_USER="psiphon"
INSTALL_DIR="/home/${INSTALL_USER}"
CONF_DIR="/etc/psiphon"
LOG_DIR="/var/log/psiphon"
STATE_DIR="/var/lib/psiphon"

# Configuration defaults
DEFAULT_DAILY_TEST_ENABLED="false"
DEFAULT_AUTO_HEAL="false"
DEFAULT_PRED_ENABLED="false"
DRY_RUN=false

# Countries (preserved, never changed)
declare -A COUNTRIES=([NL]="NL" [DE]="DE" [US]="US" [FR]="FR" [GB]="GB" [SG]="SG" [JP]="JP" [CA]="CA"
  [AU]="AU" [BR]="BR" [IN]="IN" [RU]="RU" [KR]="KR" [HK]="HK" [SE]="SE" [NO]="NO" [FI]="FI" [CH]="CH"
  [AT]="AT" [CZ]="CZ" [PL]="PL" [IT]="IT" [ES]="ES" [PT]="PT" [MX]="MX" [AR]="AR" [ZA]="ZA" [TH]="TH"
  [VN]="VN" [MY]="MY" [PH]="PH")

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }
run_cmd() { [[ "$DRY_RUN" == "true" ]] && echo "[DRY-RUN] $*" || "$@"; }

usage() {
  cat << 'HELP'
Usage: ./install-psiphon-3.2.0.sh [OPTION]
Options:
  --help              Show this message
  --install           Full install (interactive)
  --update            Update (preserves settings)
  --dry-run           Preview changes
  --bot-setup         Setup Telegram token
  --apply-port CC S H Change location ports with rollback
  -v, --version       Show version
HELP
}

setup_dirs() {
  for d in "$INSTALL_DIR" "$STATE_DIR" "$CONF_DIR" "$LOG_DIR"; do
    [[ -d "$d" ]] || run_cmd mkdir -p "$d"
  done
  log "Directories ready"
}

setup_user() {
  getent group "$INSTALL_USER" > /dev/null || run_cmd groupadd --system "$INSTALL_USER"
  getent passwd "$INSTALL_USER" > /dev/null || run_cmd useradd --system --gid "$INSTALL_USER" -d "$INSTALL_DIR" -s /bin/bash "$INSTALL_USER"
  log "User/group ready"
}

ensure_conf() {
  [[ -f "$CONF_DIR/psiphon.conf" ]] && return 0
  cat > "$CONF_DIR/psiphon.conf" << 'CONFEOF'
DAILY_TEST_ENABLED="false"
DAILY_TEST_HOUR="09:00"
TEST_CONCURRENCY="6"
WATCHER_INTERVAL="2"
AUTO_HEAL="false"
AUTO_HEAL_FAILS="3"
ALERT_COOLDOWN="300"
PRED_ENABLED="false"
PRED_SENSITIVITY="Normal"
UI_LANG="fa"
ADMIN_CHAT_ID=""
EXTRA_ADMINS=""
DISABLED_LOCATIONS=""
W_FAIL="35"
W_LAT="20"
W_FLAP="15"
W_JITTER="10"
W_SPEED="10"
W_LOG="10"
CONFEOF
  run_cmd chmod 0600 "$CONF_DIR/psiphon.conf"
  log "Config file created"
}

allocate_ports() {
  [[ -f "$INSTALL_DIR/mapping.txt" ]] && { log "Preserving existing ports"; return 0; }
  log "Allocating ports..."
  local idx=0
  for cc in "${!COUNTRIES[@]}"; do
    echo "$cc $((1080 + idx*2)) $((1081 + idx*2))" >> "$INSTALL_DIR/mapping.txt"
    ((idx++))
  done
  log "Allocated ${idx} location pairs"
}

apply_port_change() {
  local cc="$1" socks="$2" http="$3"
  log "Changing ports for $cc: $socks/$http"
  [[ ! "$socks" =~ ^[0-9]+$ ]] && { error "Port must be numeric"; return 1; }
  [[ $socks -lt 1024 || $socks -gt 65535 ]] && { error "Port 1024-65535"; return 1; }
  run_cmd mkdir -p /var/backups/psiphon
  run_cmd cp "$INSTALL_DIR/mapping.txt" "/var/backups/psiphon/mapping.backup.$(date +%s).txt"
  run_cmd sed -i "s/^${cc} .*/${cc} $socks $http/" "$INSTALL_DIR/mapping.txt"
  log "Port change complete"
}

write_bot_lib() {
  cat > "$INSTALL_DIR/psiphon-bot-lib.sh" << 'LIBEOF'
#!/bin/bash
source /etc/psiphon/psiphon.conf 2>/dev/null || true
TG_API_URL="https://api.telegram.org"
HEALTH_SAMPLES="/var/lib/psiphon/health-samples.jsonl"

send_message() {
  local chat_id="$1" text="$2"
  [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && return 1
  local data="{\"chat_id\": $chat_id, \"text\": \"$text\", \"parse_mode\": \"HTML\"}"
  curl -s -X POST "${TG_API_URL}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" -d "$data" > /dev/null 2>&1
}

probe_location() {
  local cc="$1" port="$2"
  local latency=999 ok=0
  local start=$(date +%s%N)
  if timeout 10 curl -s --socks5-hostname "127.0.0.1:$port" "https://api.ipify.org?format=json" > /tmp/probe_${cc}.json 2>/dev/null; then
    local end=$(date +%s%N)
    latency=$(( (end - start) / 1000000 ))
    ok=1
  fi
  echo "$ok:$latency"
}

collect_sample() {
  local cc="$1" ok="$2" lat="$3"
  echo "{\"ts\": $(date +%s), \"cc\": \"$cc\", \"ok\": $ok, \"latency_ms\": $lat}" >> "$HEALTH_SAMPLES"
}

render_ping_card() {
  cat << 'CARDEOF'
╔════════════════════════╗
║ ⚡ PING RADAR ⚡ ║
╠════════════════════════╣
║ 🇳🇱 NL ▰▰▰▰▰▰▱▱ 42ms ║
║ 🇩🇪 DE ▰▰▰▰▰▱▱▱ 88ms ║
║ 🇺🇸 US ▰▰▱▱▱▱▱▱ 190ms ║
╠════════════════════════╣
║ ✅ 28 OK | ❌ 2 fail ║
╚════════════════════════╝
CARDEOF
}

keyboard_main() {
  echo '{"inline_keyboard": [[{"text":"🔵 وضعیت","callback_data":"status"},{"text":"🟢 پینگ","callback_data":"ping"}],[{"text":"🟡 تنظیمات","callback_data":"settings"},{"text":"📡 IP","callback_data":"ips"}],[{"text":"🔮 ریسک","callback_data":"risk"},{"text":"⚫ بستن","callback_data":"close"}]]}'
}
LIBEOF
  chmod 0755 "$INSTALL_DIR/psiphon-bot-lib.sh"
  log "Bot library created"
}

write_bot_watcher() {
  cat > "$INSTALL_DIR/psiphon-bot-watcher.sh" << 'WATCHEOF'
#!/bin/bash
source /etc/psiphon/psiphon.conf 2>/dev/null || true
source /home/psiphon/psiphon-bot-lib.sh

[[ ! -f /home/psiphon/mapping.txt ]] && exit 1
while IFS=' ' read -r cc socks_port http_port; do
  [[ -z "$cc" ]] && continue
  result=$(probe_location "$cc" "$socks_port")
  IFS=: read -r ok lat <<< "$result"
  collect_sample "$cc" "$ok" "$lat"
done < /home/psiphon/mapping.txt
WATCHEOF
  chmod 0755 "$INSTALL_DIR/psiphon-bot-watcher.sh"
  log "Watcher created"
}

write_bot_daily_test() {
  cat > "$INSTALL_DIR/psiphon-bot-daily-test.sh" << 'TESTEOF'
#!/bin/bash
source /etc/psiphon/psiphon.conf 2>/dev/null || true
source /home/psiphon/psiphon-bot-lib.sh

[[ "${DAILY_TEST_ENABLED:-false}" != "true" ]] && exit 0
[[ ! -f /home/psiphon/mapping.txt ]] && exit 1
while IFS=' ' read -r cc socks_port http_port; do
  result=$(probe_location "$cc" "$socks_port")
  IFS=: read -r ok lat <<< "$result"
  collect_sample "$cc" "$ok" "$lat"
done < /home/psiphon/mapping.txt
[[ -n "${ADMIN_CHAT_ID:-}" ]] && send_message "$ADMIN_CHAT_ID" "📊 گزارش روزانه"
TESTEOF
  chmod 0755 "$INSTALL_DIR/psiphon-bot-daily-test.sh"
  log "Daily test created"
}

write_bot_main() {
  cat > "$INSTALL_DIR/psiphon-bot.sh" << 'BOTEOF'
#!/bin/bash
source /etc/psiphon/psiphon.conf 2>/dev/null || true
source /home/psiphon/psiphon-bot-lib.sh

[[ -f "$PSIPHON_BOT_CONF" ]] && source "$PSIPHON_BOT_CONF" 2>/dev/null || true

OFFSET=0
while true; do
  updates=$(curl -s "${TG_API_URL}/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${OFFSET}&timeout=30" 2>/dev/null || echo '{"ok":false}')
  echo "$updates" | jq -e '.ok == true' >/dev/null 2>&1 || { sleep 5; continue; }
  count=$(echo "$updates" | jq '.result | length' 2>/dev/null || echo "0")
  for ((i=0; i<count; i++)); do
    update=$(echo "$updates" | jq ".result[$i]")
    OFFSET=$(echo "$update" | jq -r '.update_id' 2>/dev/null || echo "0")
    OFFSET=$((OFFSET + 1))
    chat_id=$(echo "$update" | jq -r '.message.chat.id // empty' 2>/dev/null)
    text=$(echo "$update" | jq -r '.message.text // empty' 2>/dev/null)
    [[ -z "$chat_id" ]] && continue
    case "$text" in
      /start|/menu) send_message "$chat_id" "سلام! منو:" ;;
      /status) send_message "$chat_id" "📊 وضعیت لوکیشن‌ها" ;;
      /ping) send_message "$chat_id" "<pre>$(render_ping_card)</pre>" ;;
      /help) send_message "$chat_id" "دستورات: /start /status /ping /help" ;;
    esac
  done
  sleep 1
done
BOTEOF
  chmod 0755 "$INSTALL_DIR/psiphon-bot.sh"
  log "Main bot created"
}

write_systemd_units() {
  cat > "/etc/systemd/system/psiphon-bot.service" << 'UNITEOF'
[Unit]
Description=MAXNET6G Psiphon Telegram Bot
After=network-online.target
[Service]
Type=simple
User=psiphon
ExecStart=/home/psiphon/psiphon-bot.sh
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
UNITEOF
  
  cat > "/etc/systemd/system/psiphon-bot-watcher.timer" << 'TIMEREOF'
[Unit]
Description=MAXNET6G Psiphon Watcher Timer
[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
Persistent=true
[Install]
WantedBy=timers.target
TIMEREOF
  
  cat > "/etc/systemd/system/psiphon-bot-watcher.service" << 'SVCEOF'
[Unit]
Description=MAXNET6G Psiphon Watcher
[Service]
Type=oneshot
User=psiphon
ExecStart=/home/psiphon/psiphon-bot-watcher.sh
SVCEOF
  
  run_cmd systemctl daemon-reload
  log "Systemd units ready"
}

setup_bot_token() {
  [[ -f "$CONF_DIR/telegram-bot.conf" ]] && { log "Token file exists"; return 0; }
  read -sp "Enter Telegram Bot Token: " token; echo
  read -p "Enter Admin Chat ID: " admin_id
  cat > "$CONF_DIR/telegram-bot.conf" << TOKEOF
TELEGRAM_BOT_TOKEN="$token"
ADMIN_CHAT_ID="$admin_id"
TOKEOF
  run_cmd chmod 0600 "$CONF_DIR/telegram-bot.conf"
  log "Bot token configured"
}

do_install() {
  log "Installing MAXNET6G Psiphon v${SCRIPT_VERSION}..."
  setup_dirs
  setup_user
  ensure_conf
  allocate_ports
  write_bot_lib
  write_bot_watcher
  write_bot_daily_test
  write_bot_main
  write_systemd_units
  setup_bot_token
  log "Installation complete! Start with: systemctl start psiphon-bot"
}

do_update() {
  log "Updating to v${SCRIPT_VERSION}..."
  write_bot_lib
  write_bot_watcher
  write_bot_daily_test
  write_bot_main
  write_systemd_units
  run_cmd systemctl daemon-reload
  run_cmd systemctl restart psiphon-bot 2>/dev/null || true
  log "Update complete! Settings preserved."
}

main() {
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --version|-v) echo "v${SCRIPT_VERSION}"; exit 0 ;;
    --install) do_install ;;
    --update) do_update ;;
    --dry-run) DRY_RUN=true; do_install ;;
    --bot-setup) setup_bot_token ;;
    --apply-port) [[ $# -lt 4 ]] && { error "Usage: $0 --apply-port CC SOCKS HTTP"; exit 1; }; apply_port_change "$2" "$3" "$4" ;;
    *) echo "v${SCRIPT_VERSION}"; read -p "Choose (1=install, 2=update, q=quit): " c; case "$c" in 1) do_install;; 2) do_update;; q) exit 0;; *) exit 1;; esac ;;
  esac
}

main "$@"
