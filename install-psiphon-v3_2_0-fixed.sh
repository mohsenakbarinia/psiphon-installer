#!/usr/bin/env bash
# =============================================================================
#  MAXNET6G install-psiphon.sh
#  MAXNET6G: نصب و مدیریت امن چند-instance از psiphon-tunnel-core
#  نصب چند-instance از psiphon-tunnel-core (ConsoleClient) روی Ubuntu 20.04 / 22.04 / 24.04 / 26.04
#  هر کشور (EgressRegion) = یک سرویس systemd + یک پورت SOCKS5 + یک پورت HTTP
#  همه پورت‌ها فقط روی 127.0.0.1
#
#  استفاده:
#     sudo bash install-psiphon.sh           # نصب کاملاً خودکار، بدون نیاز به ویرایش (idempotent)
#     sudo ./install-psiphon.sh --dry-run    # فقط نمایش کارها، بدون اجرا
#     sudo ./install-psiphon.sh --uninstall  # حذف کامل (با تأیید)
#     sudo ./install-psiphon.sh --uninstall --yes   # حذف بدون سؤال
#     ./install-psiphon.sh --help
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="3.2.0"
BRAND="MAXNET6G"
WELCOME_MARKER="/etc/psiphon/.maxnet6g_welcomed"

# =============================================================================
# ███  بخش متغیرهای قابل ویرایش  ███  (همه تنظیمات فقط همین‌جاست)
# =============================================================================

# --- لیست لوکیشن‌ها (کد دوحرفی ISO 3166). اضافه/کم کنید. ---
COUNTRIES=(AT AU BE BG BR CA CH CZ DE DK EE ES FI FR GB HU IE IN IT JP LV NL NO PL RO RS SE SG SK US)

# --- مقادیر سایفون (از قبل پر شده با مقادیر عمومی شبکه رایگان Psiphon؛ نیازی به تغییر نیست) ---
# همان مقادیری که پروژه‌های عمومی مثل SpherionOS/PsiphonLinux استفاده می‌کنند.
# اگر مقادیر اختصاصی از Psiphon Inc. دارید، فقط این‌ها را عوض کنید. خالی = خطا.
PROPAGATION_CHANNEL_ID="FFFFFFFFFFFFFFFF"
SPONSOR_ID="FFFFFFFFFFFFFFFF"
REMOTE_SERVER_LIST_URL="https://s3.amazonaws.com//psiphon/web/mjr4-p23r-puwl/server_list_compressed"
REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY="MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM="

# --- مقادیر اختیاری سایفون (خالی = در کانفیگ نوشته نمی‌شود) ---
OBFUSCATED_SERVER_LIST_ROOT_URL=""
# فیلدهای اضافه دلخواه به‌صورت یک آبجکت JSON که با کانفیگ هر کشور merge می‌شود
# مثال: EXTRA_CONFIG_JSON='{"EmitDiagnosticNotices":true,"UpstreamProxyUrl":""}'
EXTRA_CONFIG_JSON='{}'
# 0 = بدون محدودیت زمانی برای برقراری تونل
ESTABLISH_TUNNEL_TIMEOUT_SECONDS=0
# اینترفیس listen. خالی = پیش‌فرض سایفون یعنی 127.0.0.1 (توصیه‌شده). "lo" هم مجاز است.
# مقدار "any" (یعنی 0.0.0.0) عمداً ممنوع است.
LISTEN_INTERFACE=""

# --- پورت‌ها ---
SOCKS_PORT_BASE=10800          # اولین پورت SOCKS5
HTTP_PORT_BASE=10900           # اولین پورت HTTP
MAX_INSTANCES=100              # سقف تعداد instance (باید <= فاصله دو پایه باشد)

# --- باینری ---
# amd64: ریپوی رسمی Psiphon-Labs. اگر شکست خورد، خودکار سراغ fallback می‌رود.
# arm64: ریپوی رسمی باینری arm64 ندارد؛ پیش‌فرض بیلد خودکار عمومی ehsanecc/psiphon-builder است.
PSIPHON_BIN_URL_AMD64="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
PSIPHON_BIN_URL_AMD64_FALLBACK="https://github.com/ehsanecc/psiphon-builder/releases/latest/download/psiphon-tunnel-core-linux-x86_64"
PSIPHON_BIN_URL_ARM64="https://github.com/ehsanecc/psiphon-builder/releases/latest/download/psiphon-tunnel-core-linux-arm64"
PSIPHON_BIN_URL_ARM64_FALLBACK=""
PSIPHON_BIN_SHA256=""          # اختیاری: اگر پر شود، هش باینری دانلودی چک می‌شود
FORCE_DOWNLOAD=false           # true = حتی اگر باینری هست دوباره دانلود و مقایسه کن
DOWNLOAD_RETRIES=3             # تعداد تلاش دانلود
DOWNLOAD_BACKOFF_BASE=5        # ثانیه؛ backoff = base * 2^(n-1)

# --- مسیرها و یوزر ---
PSIPHON_USER="psiphon"
INSTALL_DIR="/opt/psiphon"
BIN_DIR="${INSTALL_DIR}/bin"
BIN_PATH="${BIN_DIR}/psiphon-tunnel-core"
CONF_DIR="/etc/psiphon"
DATA_DIR="/var/lib/psiphon"
LOG_DIR="/var/log/psiphon"
INSTALL_LOG="/var/log/psiphon-install.log"
MAPPING_FILE="${CONF_DIR}/mapping.txt"
PORT_BASES_FILE="${CONF_DIR}/port-bases.conf"
CTL_CONF="${CONF_DIR}/psiphon-ctl.conf"
CTL_PATH="/usr/local/bin/psiphon-ctl"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_PREFIX="psiphon-"
LOGROTATE_FILE="/etc/logrotate.d/psiphon"
TURBO_DIR="${CONF_DIR}/turbo-backups"
TURBO_SYSCTL="/etc/sysctl.d/99-psiphon-turbo.conf"
TURBO_MANAGER_DROPIN="/etc/systemd/system.conf.d/99-psiphon-turbo.conf"
TURBO_STATE="${DATA_DIR}/turbo-last.json"
NETDOCTOR_STATE="${DATA_DIR}/netdoctor-last.json"
NETDOCTOR_CLIENT="${CONF_DIR}/netdoctor-client.sh"
BOT_CONF="${CONF_DIR}/telegram-bot.conf"
BOT_SCRIPT="${CONF_DIR}/telegram-bot.sh"
BOT_WATCHER="${CONF_DIR}/telegram-watcher.sh"
BOT_SERVICE="${SYSTEMD_DIR}/psiphon-bot.service"
BOT_WATCHER_SERVICE="${SYSTEMD_DIR}/psiphon-bot-watcher.service"
BOT_WATCHER_TIMER="${SYSTEMD_DIR}/psiphon-bot-watcher.timer"
BOT_TIMER="${SYSTEMD_DIR}/psiphon-bot-ip-refresh.timer"
BOT_REFRESH_SERVICE="${SYSTEMD_DIR}/psiphon-bot-ip-refresh.service"
BOT_DAILY_SERVICE="${SYSTEMD_DIR}/psiphon-bot-daily-test.service"
BOT_DAILY_TIMER="${SYSTEMD_DIR}/psiphon-bot-daily-test.timer"
BOT_STATE="${DATA_DIR}/telegram-bot-state.json"
BOT_SETTINGS="${CONF_DIR}/bot-settings.conf"         # تنظیمات ربات (پیش‌فرض‌ها خودکار ساخته می‌شوند)
DISABLED_LOCATIONS="${CONF_DIR}/disabled-locations.txt"  # هر خط یک کد کشور؛ در تست/healthcheck/watcher رد می‌شوند
SELF_INSTALL_PATH="/usr/local/bin/install-psiphon.sh"

# --- systemd ---
RESTART_SEC=10
LIMIT_NOFILE=1048576
START_STAGGER_SEC=3            # فاصله بین start هر instance
HEALTH_TIMER_INTERVAL="5min"   # فاصله تایمر health-check
PRUNE_REMOVED_COUNTRIES=true   # کشورهایی که از آرایه حذف شده‌اند، سرویسشان حذف شود
DAILY_TEST_HOUR="09:00"        # ساعت تست روزانه ربات (HH:MM). اگر در bot-settings.conf باشد، همان اولویت دارد
DAILY_TEST_ENABLED=true
WATCHER_INTERVAL_MIN=2
IP_REFRESH_HOURS=6

# --- تست سلامت ---
TEST_URL="https://ipinfo.io/json"   # باید JSON با فیلدهای ip و country برگرداند
TEST_TIMEOUT=15                # timeout هر درخواست curl (ثانیه)
HEALTH_WAIT=60                 # حداکثر انتظار برای بالا آمدن هر instance (ثانیه)
HEALTH_POLL_INTERVAL=5         # فاصله تلاش‌ها در زمان انتظار
STRICT_COUNTRY_MATCH=true      # true = کشور واقعی متفاوت یعنی FAIL
HEALTH_PARALLEL=10             # تعداد تست هم‌زمان در psiphon-ctl

# --- فایروال ---
MANAGE_UFW=true                # افزودن rule برای deny بیرونی رنج پورت‌ها (اگر ufw فعال باشد)

# --- سیستم‌عامل ---
SUPPORTED_UBUNTU=("20.04" "22.04" "24.04" "25.04" "25.10" "26.04")
# نسخه‌های دیگر اوبونتو/دبیان: فقط هشدار می‌دهد و ادامه می‌دهد (کاملاً خودکار)
ALLOW_UNSUPPORTED_OS=true

# --- پیش‌نیازها: "دستور:پکیج" ---
PREREQS=("curl:curl" "jq:jq" "wget:wget" "ufw:ufw" "ss:iproute2" "ip:iproute2" "ping:iputils-ping" "timeout:coreutils" "getent:libc-bin" "tar:tar" "logrotate:logrotate" "flock:util-linux" "sha256sum:coreutils" "update-ca-certificates:ca-certificates")

# =============================================================================
# ███  پایان بخش قابل ویرایش  ███
# =============================================================================

# -----------------------------------------------------------------------------
# متغیرهای داخلی و پارس آرگومان‌ها
# -----------------------------------------------------------------------------
DRY_RUN=false
MODE="install"
ASSUME_YES=false
INTERACTIVE_MENU=false
SCRIPT_NAME="$(basename "$0")"
WORK_TMP=""
declare -A SOCKS_PORT=() HTTP_PORT=()
declare -a CHANGED_INSTANCES=()
declare -a OK_LIST=() FAIL_LIST=()
BINARY_CHANGED=false
FILE_CHANGED=false
FIREWALL_STATE="${DATA_DIR}/ufw-rules-installed"

usage() {
  cat <<EOF
Usage: sudo ${SCRIPT_NAME} [--install|--update|--status|--dry-run|--uninstall [--yes]|--help]
  --dry-run     فقط نمایش کارها بدون اعمال تغییر
  --install     اجرای نصب کامل
  --update      به‌روزرسانی باینری و اسکریپت‌ها با rollback خودکار
  --status      نمایش وضعیت سرویس‌ها و سلامت instanceها
  --uninstall   حذف کامل سرویس‌ها، فایل‌ها و یوزر (با تأیید)
  --yes         رد کردن سؤال تأیید در uninstall
  --turbo       فعال‌سازی بهینه‌سازی‌های امن و قابل بازگشت
  --turbo-revert برگشت تنظیمات Turbo
  --net-doctor  تشخیص سلامت شبکه و ساخت تست سمت کلاینت
  --net-doctor-revert برگشت تغییرات شبکه doctor
  --bot-setup   راه‌اندازی یا مدیریت ربات تلگرام MAXNET6G
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --install)   MODE="install" ;;
    --update)    MODE="update" ;;
    --status)    MODE="status" ;;
    --turbo) MODE="turbo" ;;
    --turbo-revert) MODE="turbo-revert" ;;
    --net-doctor) MODE="net-doctor" ;;
    --net-doctor-revert) MODE="net-doctor-revert" ;;
    --bot-setup) MODE="bot-setup" ;;
    --uninstall) MODE="uninstall" ;;
    --yes|-y)    ASSUME_YES=true ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# رنگ‌ها و توابع لاگ
# -----------------------------------------------------------------------------
NO_COLOR="${NO_COLOR:-}"
USE_COLOR=false
USE_UNICODE=false
if [[ -t 1 && -z "$NO_COLOR" && "${TERM:-dumb}" != "dumb" && "${LANG:-}" == *UTF-8* ]]; then
  USE_COLOR=true
  USE_UNICODE=true
fi
if $USE_COLOR; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[36m'
  C_MAG=$'\e[35m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_MAG=""; C_BLD=""; C_RST=""
fi
ts()    { date '+%Y-%m-%d %H:%M:%S'; }
log()   { echo "${C_BLU}[$(ts)] [INFO]${C_RST} $*"; }
ok()    { echo "${C_GRN}[$(ts)] [ OK ]${C_RST} $*"; }
warn()  { echo "${C_YLW}[$(ts)] [WARN]${C_RST} $*" >&2; }
err()   { echo "${C_RED}[$(ts)] [FAIL]${C_RST} $*" >&2; }
die()   { err "$*"; exit 1; }
step()  { echo; echo "${C_BLD}==> $*${C_RST}"; }

brand_line() {
  local line="${1:-$BRAND}"
  if $USE_UNICODE; then printf '║ %-*s ║\n' 70 "$line"; else printf '| %-*s |\n' 70 "$line"; fi
}

brand_header() {
  local os_name host_name
  host_name="$(hostname 2>/dev/null || echo unknown)"
  os_name="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)"
  echo
  if $USE_UNICODE; then
    echo "╔════════════════════════════════════════════════════════════════════════╗"
  else
    echo "+------------------------------------------------------------------------+"
  fi
  brand_line "${BRAND} | Psiphon Control Center"
  brand_line "host: ${host_name} | os: ${os_name}"
  if $USE_UNICODE; then
    echo "╚════════════════════════════════════════════════════════════════════════╝"
  else
    echo "+------------------------------------------------------------------------+"
  fi
}

public_ip() {
  curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || echo "unavailable"
}

system_snapshot() {
  local os_name cpu ram
  os_name="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)"
  cpu="$(nproc 2>/dev/null || echo '?')"
  ram="$(awk '/MemTotal/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo '?')"
  printf 'hostname: %s | public IP: %s | OS: %s | CPU/RAM: %s/%s\n' \
    "$(hostname 2>/dev/null || echo unknown)" "$(public_ip)" "$os_name" "$cpu" "$ram"
}

show_splash() {
  [[ -t 1 && "$MODE" != "status" ]] || return 0
  [[ -e "$WELCOME_MARKER" ]] && { brand_header; return 0; }
  clear 2>/dev/null || true
  if $USE_COLOR; then
    printf '%b\n' "${C_BLU}███╗   ███╗ █████╗ ██╗  ██╗███╗   ██╗███████╗████████╗${C_RST}"
    printf '%b\n' "${C_MAG}████╗ ████║██╔══██╗╚██╗██╔╝████╗  ██║██╔════╝╚══██╔══╝${C_RST}"
    printf '%b\n' "${C_BLU}██╔████╔██║███████║ ╚███╔╝ ██╔██╗ ██║█████╗     ██║   ${C_RST}"
    printf '%b\n' "${C_MAG}██║╚██╔╝██║██╔══██║ ██╔██╗ ██║╚██╗██║██╔══╝     ██║   ${C_RST}"
    printf '%b\n' "${C_BLU}██║ ╚═╝ ██║██║  ██║██╔╝ ██╗██║ ╚████║███████╗   ██║   ${C_RST}"
    printf '%b\n' "${C_MAG}╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ${C_RST}"
  else
    echo "MAXNET6G"
  fi
  echo "Secure multi-instance Psiphon operations"
  echo "version: ${SCRIPT_VERSION}"
  system_snapshot
  printf 'loading'
  local i; for i in 1 2 3 4 5; do printf '.'; sleep 0.4; done
  echo
  if ! $DRY_RUN && [[ $EUID -eq 0 ]]; then
    install -d -m 0750 -o root -g root "${WELCOME_MARKER%/*}"
    : > "$WELCOME_MARKER"
    chmod 0600 "$WELCOME_MARKER"
  fi
}

backup_path() {
  local src=$1 backup_dir
  [[ "$DRY_RUN" == true || ! -e "$src" ]] && return 0
  backup_dir="${CONF_DIR}/backups/$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 -o root -g root "$backup_dir"
  cp -a -- "$src" "$backup_dir/"
}

# -----------------------------------------------------------------------------
# مدیریت خطا: trap با شماره خط + پاکسازی فایل‌های موقت
# -----------------------------------------------------------------------------
on_error() {
  local line=${1:-?} cmd=${2:-unknown} rc=${3:-1}
  err "خطا در خط ${line} (exit=${rc}): ${cmd}"
  err "لاگ کامل: ${INSTALL_LOG}"
  exit "$rc"
}
cleanup() { [[ -n "${WORK_TMP:-}" && -d "${WORK_TMP}" ]] && rm -rf -- "$WORK_TMP"; return 0; }
trap 'rc=$?; on_error "$LINENO" "$BASH_COMMAND" "$rc"' ERR
trap cleanup EXIT

# -----------------------------------------------------------------------------
# اجرای دستورات با پشتیبانی از dry-run
# -----------------------------------------------------------------------------
run() {
  if $DRY_RUN; then
    echo "${C_YLW}[DRY-RUN]${C_RST} $*"
  else
    "$@"
  fi
}

# نوشتن فایل فقط در صورت تغییر محتوا (idempotent). محتوا از stdin.
# write_file <dest> <mode> <owner:group>  → FILE_CHANGED=true|false
write_file() {
  local dest=$1 mode=$2 owner=$3 tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/psiphon-write.XXXXXX")"
  cat > "$tmp"
  FILE_CHANGED=false
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    if ! $DRY_RUN; then chmod "$mode" "$dest"; chown "$owner" "$dest"; fi
    return 0
  fi
  FILE_CHANGED=true
  if $DRY_RUN; then
    echo "${C_YLW}[DRY-RUN]${C_RST} write ${dest} (mode ${mode}, owner ${owner})"
    rm -f "$tmp"
  else
    backup_path "$dest"
    install -d -m 0755 -o root -g root "$(dirname "$dest")"
    install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "${dest}.new"
    mv -f -- "${dest}.new" "$dest"
    rm -f "$tmp"
    log "نوشته شد: ${dest}"
  fi
}

# -----------------------------------------------------------------------------
# راه‌اندازی لاگ کامل در فایل
# -----------------------------------------------------------------------------
setup_logging() {
  if [[ $EUID -eq 0 ]]; then
    touch "$INSTALL_LOG" && chmod 0640 "$INSTALL_LOG"
    exec > >(tee -a "$INSTALL_LOG") 2>&1
    echo "------------------------------------------------------------------"
    log "شروع ${SCRIPT_NAME} mode=${MODE} dry_run=${DRY_RUN}"
  fi
}

# =============================================================================
# مرحله 1: چک root، معماری و نسخه سیستم‌عامل
# =============================================================================
check_root() {
  if [[ $EUID -ne 0 ]]; then
    if $DRY_RUN; then
      warn "اجرا بدون root در حالت dry-run (بعضی چک‌ها ممکن است ناقص باشند)"
    else
      die "این اسکریپت باید با root اجرا شود: sudo ${SCRIPT_NAME}"
    fi
  fi
}

ARCH=""
check_arch() {
  local m
  m="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$m" in
    amd64|x86_64)  ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) die "معماری پشتیبانی نمی‌شود: ${m} (فقط amd64/arm64)" ;;
  esac
  ok "معماری: ${ARCH}"
}

check_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release پیدا نشد"
  # shellcheck disable=SC1091
  . /etc/os-release
  local supported=false v
  for v in "${SUPPORTED_UBUNTU[@]}"; do [[ "${VERSION_ID:-}" == "$v" ]] && supported=true; done
  if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *ubuntu* && "${ID_LIKE:-}" != *debian* && "${ID:-}" != "debian" ]]; then
    die "فقط توزیع‌های مبتنی بر Ubuntu/Debian پشتیبانی می‌شوند (فعلی: ${PRETTY_NAME:-unknown})"
  fi
  # bash حداقل 4.4 (برای آرایه‌های خالی با set -u)
  if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    die "bash نسخه 4.4 یا بالاتر لازم است"
  fi
  if [[ "${ID:-}" == "ubuntu" ]] && $supported; then
    ok "سیستم‌عامل: ${PRETTY_NAME}"
  elif $ALLOW_UNSUPPORTED_OS; then
    warn "سیستم‌عامل پشتیبانی‌نشده (${PRETTY_NAME:-unknown})، ادامه به‌دلیل ALLOW_UNSUPPORTED_OS=true"
  else
    die "فقط Ubuntu ${SUPPORTED_UBUNTU[*]} پشتیبانی می‌شود (فعلی: ${PRETTY_NAME:-unknown})"
  fi
  command -v systemctl >/dev/null || die "systemd موجود نیست"
}

# =============================================================================
# اعتبارسنجی متغیرهای بالای اسکریپت (قبل از هر تغییری)
# =============================================================================
validate_config() {
  local missing=() v
  if [[ -r "$PORT_BASES_FILE" ]]; then
    # Runtime base ports are optional; existing per-location mappings always win.
    # shellcheck disable=SC1090
    . "$PORT_BASES_FILE"
  fi
  for v in PROPAGATION_CHANNEL_ID SPONSOR_ID REMOTE_SERVER_LIST_URL REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY; do
    [[ -n "${!v// /}" ]] || missing+=("$v")
  done
  if ((${#missing[@]})); then
    die "این متغیرهای الزامی بالای اسکریپت خالی هستند: ${missing[*]}"
  fi
  [[ "$REMOTE_SERVER_LIST_URL" =~ ^https?:// ]] || die "REMOTE_SERVER_LIST_URL باید با http(s):// شروع شود"
  ((${#COUNTRIES[@]} > 0)) || die "آرایه COUNTRIES خالی است"
  ((${#COUNTRIES[@]} <= MAX_INSTANCES)) || die "تعداد کشورها بیشتر از MAX_INSTANCES است"

  # پورت‌ها نباید هم‌پوشانی داشته باشند
  local lo=$(( SOCKS_PORT_BASE < HTTP_PORT_BASE ? SOCKS_PORT_BASE : HTTP_PORT_BASE ))
  local hi=$(( SOCKS_PORT_BASE > HTTP_PORT_BASE ? SOCKS_PORT_BASE : HTTP_PORT_BASE ))
  (( SOCKS_PORT_BASE >= 1024 && SOCKS_PORT_BASE <= 65535 )) || die "SOCKS_PORT_BASE باید بین 1024 و 65535 باشد"
  (( HTTP_PORT_BASE >= 1024 && HTTP_PORT_BASE <= 65535 )) || die "HTTP_PORT_BASE باید بین 1024 و 65535 باشد"
  (( hi - lo >= MAX_INSTANCES )) || die "فاصله SOCKS_PORT_BASE و HTTP_PORT_BASE باید حداقل MAX_INSTANCES باشد"
  (( hi + MAX_INSTANCES - 1 <= 65535 )) || die "رنج پورت از 65535 بیشتر می‌شود"

  # کد کشورها: دو حرف بزرگ، بدون تکرار
  local -A seen=(); local cc
  for cc in "${COUNTRIES[@]}"; do
    [[ "$cc" =~ ^[A-Z]{2}$ ]] || die "کد کشور نامعتبر: '${cc}' (باید دو حرف بزرگ باشد)"
    [[ -z "${seen[$cc]:-}" ]] || die "کد کشور تکراری: ${cc}"
    seen[$cc]=1
  done

  # listen فقط لوکال
  case "${LISTEN_INTERFACE}" in
    ""|lo) ;;
    *) die "LISTEN_INTERFACE فقط می‌تواند خالی یا 'lo' باشد (bind فقط روی 127.0.0.1)" ;;
  esac
  [[ "$DAILY_TEST_HOUR" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "DAILY_TEST_HOUR باید HH:MM باشد (مثلاً 09:00)"
  command -v jq >/dev/null 2>&1 || die "jq برای ساخت کانفیگ لازم است"
  echo "$EXTRA_CONFIG_JSON" | jq -e 'type=="object"' >/dev/null \
    || die "EXTRA_CONFIG_JSON یک آبجکت JSON معتبر نیست"
  ok "متغیرهای پیکربندی معتبرند (${#COUNTRIES[@]} کشور)"
}

# =============================================================================
# مرحله 2: نصب پیش‌نیازها در صورت نبودن
# =============================================================================
install_prereqs() {
  local pkgs=() item cmd pkg
  for item in "${PREREQS[@]}"; do
    cmd="${item%%:*}"; pkg="${item##*:}"
    command -v "$cmd" >/dev/null 2>&1 || pkgs+=("$pkg")
  done
  if ((${#pkgs[@]})); then
    log "نصب پیش‌نیازها: ${pkgs[*]}"
    run env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update -qq
    run env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq "${pkgs[@]}"
  else
    ok "همه پیش‌نیازها موجودند"
  fi
}

# =============================================================================
# مرحله 4: ساخت یوزر سیستمی و دایرکتوری‌ها
# =============================================================================
setup_user_dirs() {
  run systemctl daemon-reload
  if id -u "$PSIPHON_USER" >/dev/null 2>&1; then
    ok "یوزر ${PSIPHON_USER} موجود است"
  else
    run useradd --system --no-create-home --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$PSIPHON_USER"
  fi
  run install -d -m 0755 -o root -g root "$INSTALL_DIR" "$BIN_DIR"
  run install -d -m 0750 -o root -g "$PSIPHON_USER" "$CONF_DIR"
  run install -d -m 0750 -o "$PSIPHON_USER" -g "$PSIPHON_USER" "$DATA_DIR"
  run install -d -m 0750 -o root -g root "$LOG_DIR"
  local cc
  for cc in "${COUNTRIES[@]}"; do
    run install -d -m 0700 -o "$PSIPHON_USER" -g "$PSIPHON_USER" "${DATA_DIR}/${cc}"
  done
}

# =============================================================================
# مرحله 3: دانلود باینری با retry و backoff
# =============================================================================
download_with_retry() {
  local url=$1 out=$2 i delay
  for ((i = 1; i <= DOWNLOAD_RETRIES; i++)); do
    if curl -fL --connect-timeout 20 --max-time 300 -sS -o "$out" "$url"; then
      return 0
    fi
    if ((i < DOWNLOAD_RETRIES)); then
      delay=$(( DOWNLOAD_BACKOFF_BASE * (1 << (i - 1)) ))
      warn "دانلود ناموفق (تلاش ${i}/${DOWNLOAD_RETRIES})، تلاش مجدد بعد از ${delay}s"
      sleep "$delay"
    fi
  done
  return 1
}

install_binary() {
  local url fallback
  case "$ARCH" in
    amd64) url="$PSIPHON_BIN_URL_AMD64"; fallback="$PSIPHON_BIN_URL_AMD64_FALLBACK" ;;
    arm64) url="$PSIPHON_BIN_URL_ARM64"; fallback="$PSIPHON_BIN_URL_ARM64_FALLBACK" ;;
  esac
  [[ -n "$url" ]] || die "برای معماری ${ARCH} آدرس باینری تعریف نشده (PSIPHON_BIN_URL_${ARCH^^})"
  [[ "$ARCH" == "arm64" ]] && warn "arm64: باینری از بیلد عمومی غیررسمی دانلود می‌شود (${url})"

  if [[ -x "$BIN_PATH" ]] && ! $FORCE_DOWNLOAD; then
    ok "باینری از قبل موجود است: ${BIN_PATH} (برای آپدیت FORCE_DOWNLOAD=true)"
    return 0
  fi
  if $DRY_RUN; then
    echo "${C_YLW}[DRY-RUN]${C_RST} download ${url} -> ${BIN_PATH}"
    return 0
  fi

  local tmp="${WORK_TMP}/psiphon-tunnel-core"
  log "دانلود باینری از ${url}"
  if ! download_with_retry "$url" "$tmp"; then
    [[ -n "$fallback" ]] || die "دانلود باینری بعد از ${DOWNLOAD_RETRIES} تلاش شکست خورد"
    warn "منبع اصلی در دسترس نیست؛ تلاش با fallback: ${fallback}"
    download_with_retry "$fallback" "$tmp" || die "دانلود باینری از هر دو منبع شکست خورد"
  fi

  # اطمینان از اینکه فایل ELF است (نه صفحه HTML خطا)
  [[ "$(head -c 4 "$tmp" | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]] || die "فایل دانلودشده باینری ELF معتبر نیست"
  if [[ -n "$PSIPHON_BIN_SHA256" ]]; then
    echo "${PSIPHON_BIN_SHA256}  ${tmp}" | sha256sum -c --status || die "هش SHA256 باینری مطابقت ندارد"
    ok "هش SHA256 تأیید شد"
  fi

  if [[ -f "$BIN_PATH" ]] && cmp -s "$tmp" "$BIN_PATH"; then
    ok "باینری تغییری نکرده"
  else
    backup_path "$BIN_PATH"
    install -m 0755 -o root -g root "$tmp" "$BIN_PATH"
    BINARY_CHANGED=true
    ok "باینری نصب شد: ${BIN_PATH} ($(sha256sum "$BIN_PATH" | cut -c1-16)...)"
  fi
}

# =============================================================================
# مرحله 5 (بخش پورت): تخصیص پورت پایدار. پورت‌های قبلی از mapping حفظ می‌شوند.
# =============================================================================
port_in_use_by_other() {
  # 0 = پورت توسط پروسه‌ای غیر از psiphon اشغال است
  local port=$1 line
  line="$(ss -H -tlnp "sport = :${port}" 2>/dev/null || true)"
  [[ -n "$line" ]] && ! grep -q 'psiphon' <<<"$line"
}

allocate_ports() {
  local -A used_port=()
  local cc s h off
  if [[ -r "$PORT_BASES_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$PORT_BASES_FILE"
  fi
  # خواندن mapping قبلی
  if [[ -f "$MAPPING_FILE" ]]; then
    while read -r cc s h; do
      [[ -z "${cc:-}" || "$cc" == \#* ]] && continue
      [[ "$s" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || continue
      if (( s >= 1024 && s <= 65535 && h >= 1024 && h <= 65535 )); then
        SOCKS_PORT[$cc]=$s; HTTP_PORT[$cc]=$h
        used_port[$s]=1; used_port[$h]=1
      fi
    done < <(sed 's/[[:space:]]*->[[:space:]]*/ /g' "$MAPPING_FILE")
  fi
  # فقط کشورهای فعلی نگه داشته می‌شوند
  local -A keep_s=() keep_h=()
  for cc in "${COUNTRIES[@]}"; do
    if [[ -n "${SOCKS_PORT[$cc]:-}" ]]; then
      keep_s[$cc]=${SOCKS_PORT[$cc]}; keep_h[$cc]=${HTTP_PORT[$cc]}
    fi
  done
  SOCKS_PORT=(); HTTP_PORT=()
  for cc in "${!keep_s[@]}"; do SOCKS_PORT[$cc]=${keep_s[$cc]}; HTTP_PORT[$cc]=${keep_h[$cc]}; done

  # کشورهای جدید: اولین offset آزاد
  for cc in "${COUNTRIES[@]}"; do
    [[ -n "${SOCKS_PORT[$cc]:-}" ]] && continue
    off=0
    while (( off < MAX_INSTANCES )); do
      if [[ -z "${used_port[$(( SOCKS_PORT_BASE + off ))]:-}" ]] \
         && [[ -z "${used_port[$(( HTTP_PORT_BASE + off ))]:-}" ]] \
         && ! port_in_use_by_other "$(( SOCKS_PORT_BASE + off ))" \
         && ! port_in_use_by_other "$(( HTTP_PORT_BASE + off ))"; then
        break
      fi
      off=$(( off + 1 ))
    done
    (( off < MAX_INSTANCES )) || die "پورت آزاد برای ${cc} پیدا نشد"
    SOCKS_PORT[$cc]=$(( SOCKS_PORT_BASE + off ))
    HTTP_PORT[$cc]=$(( HTTP_PORT_BASE + off ))
    used_port[${SOCKS_PORT[$cc]}]=1; used_port[${HTTP_PORT[$cc]}]=1
    log "پورت جدید برای ${cc}: SOCKS=${SOCKS_PORT[$cc]} HTTP=${HTTP_PORT[$cc]}"
  done

  local -A seen_ports=()
  for cc in "${COUNTRIES[@]}"; do
    [[ -z "${seen_ports[${SOCKS_PORT[$cc]}]:-}" ]] || die "mapping contains duplicate SOCKS port for ${cc}"
    [[ -z "${seen_ports[${HTTP_PORT[$cc]}]:-}" ]] || die "mapping contains duplicate HTTP port for ${cc}"
    seen_ports[${SOCKS_PORT[$cc]}]=1; seen_ports[${HTTP_PORT[$cc]}]=1
    port_in_use_by_other "${SOCKS_PORT[$cc]}" && warn "پورت ${SOCKS_PORT[$cc]} (${cc}) توسط پروسه دیگری اشغال است!"
    port_in_use_by_other "${HTTP_PORT[$cc]}"  && warn "پورت ${HTTP_PORT[$cc]} (${cc}) توسط پروسه دیگری اشغال است!"
  done
  return 0
}

# =============================================================================
# مرحله 9: فایل mapping (COUNTRY  SOCKS  HTTP)
# =============================================================================
write_mapping() {
  {
    echo "# COUNTRY  SOCKS_PORT  HTTP_PORT   (generated by ${SCRIPT_NAME}; do not edit by hand)"
    local cc
    for cc in "${COUNTRIES[@]}"; do
      printf '%-8s %-11s %s\n' "$cc" "${SOCKS_PORT[$cc]}" "${HTTP_PORT[$cc]}"
    done
  } | write_file "$MAPPING_FILE" 0644 "root:root"
  # نسخه JSON برای اسکریپت‌ها/اتوماسیون
  local cc json='{}'
  for cc in "${COUNTRIES[@]}"; do
    json="$(jq -c --arg c "$cc" --argjson s "${SOCKS_PORT[$cc]}" --argjson h "${HTTP_PORT[$cc]}" \
      '. + {($c): {socks: $s, http: $h}}' <<<"$json")"
  done
  jq . <<<"$json" | write_file "${CONF_DIR}/mapping.json" 0644 "root:root"
}

# =============================================================================
# مرحله 5: ساخت کانفیگ JSON هر کشور
# =============================================================================
build_config_json() {
  local cc=$1
  jq -n \
    --arg pci  "$PROPAGATION_CHANNEL_ID" \
    --arg sid  "$SPONSOR_ID" \
    --arg rsl  "$REMOTE_SERVER_LIST_URL" \
    --arg key  "$REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY" \
    --arg osl  "$OBFUSCATED_SERVER_LIST_ROOT_URL" \
    --arg cc   "$cc" \
    --arg dr   "${DATA_DIR}/${cc}" \
    --arg li   "$LISTEN_INTERFACE" \
    --argjson socks "${SOCKS_PORT[$cc]}" \
    --argjson http  "${HTTP_PORT[$cc]}" \
    --argjson est   "$ESTABLISH_TUNNEL_TIMEOUT_SECONDS" \
    --argjson extra "$EXTRA_CONFIG_JSON" '
    {
      PropagationChannelId: $pci,
      SponsorId: $sid,
      RemoteServerListUrl: $rsl,
      RemoteServerListSignaturePublicKey: $key,
      EgressRegion: $cc,
      DataRootDirectory: $dr,
      LocalSocksProxyPort: $socks,
      LocalHttpProxyPort: $http,
      DisableLocalSocksProxy: false,
      DisableLocalHTTPProxy: false,
      EstablishTunnelTimeoutSeconds: $est
    }
    + (if $osl != "" then {ObfuscatedServerListRootURL: $osl} else {} end)
    + (if $li  != "" then {ListenInterface: $li} else {} end)
    + $extra
    # محافظ نهایی: حتی اگر EXTRA مقدار را عوض کند، این‌ها ثابت می‌مانند
    + {EgressRegion: $cc, DataRootDirectory: $dr, LocalSocksProxyPort: $socks, LocalHttpProxyPort: $http}
    | if (.ListenInterface // "") == "any" then error("ListenInterface=any is forbidden") else . end
  '
}

write_configs() {
  local cc
  for cc in "${COUNTRIES[@]}"; do
    build_config_json "$cc" | write_file "${CONF_DIR}/${cc}.json" 0640 "root:${PSIPHON_USER}"
    $FILE_CHANGED && CHANGED_INSTANCES+=("$cc")
  done
  return 0
}

# =============================================================================
# مرحله 6: سرویس systemd هر کشور
# =============================================================================
write_unit() {
  local cc=$1
  cat <<EOF
# Generated by ${SCRIPT_NAME} - Psiphon instance for ${cc}
[Unit]
Description=${BRAND} Psiphon tunnel (${cc}) SOCKS 127.0.0.1:${SOCKS_PORT[$cc]} HTTP 127.0.0.1:${HTTP_PORT[$cc]}
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${PSIPHON_USER}
Group=${PSIPHON_USER}
WorkingDirectory=${DATA_DIR}/${cc}
ExecStart=${BIN_PATH} -config ${CONF_DIR}/${cc}.json
Restart=always
RestartSec=${RESTART_SEC}
LimitNOFILE=${LIMIT_NOFILE}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=psiphon-${cc}
# سخت‌سازی امنیتی
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
ReadWritePaths=${DATA_DIR}/${cc}

[Install]
WantedBy=multi-user.target
EOF
}

write_units() {
  local cc
  for cc in "${COUNTRIES[@]}"; do
    write_unit "$cc" | write_file "${SYSTEMD_DIR}/${SERVICE_PREFIX}${cc}.service" 0644 "root:root"
    if $FILE_CHANGED && [[ ! " ${CHANGED_INSTANCES[*]} " == *" ${cc} "* ]]; then
      CHANGED_INSTANCES+=("$cc")
    fi
  done
  return 0
}

# حذف سرویس کشورهایی که از آرایه برداشته شده‌اند
prune_removed() {
  $PRUNE_REMOVED_COUNTRIES || return 0
  local f cc
  for f in "${SYSTEMD_DIR}/${SERVICE_PREFIX}"??.service; do
    [[ -e "$f" ]] || continue
    cc="$(basename "$f" .service)"; cc="${cc#"$SERVICE_PREFIX"}"
    [[ "$cc" =~ ^[A-Z]{2}$ ]] || continue
    [[ " ${COUNTRIES[*]} " == *" ${cc} "* ]] && continue
    warn "کشور ${cc} از لیست حذف شده؛ سرویسش حذف می‌شود"
    run systemctl disable --now "${SERVICE_PREFIX}${cc}.service" || true
    run rm -f "$f" "${CONF_DIR}/${cc}.json"
    run rm -rf "${DATA_DIR:?}/${cc}"
  done
  return 0
}

start_instances() {
  run systemctl daemon-reload
  local cc acted
  for cc in "${COUNTRIES[@]}"; do
    acted=false
    local unit="${SERVICE_PREFIX}${cc}.service"
    if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      run systemctl enable --quiet "$unit"
    fi
    if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
      log "start ${unit}"; run systemctl start "$unit"; acted=true
    elif $BINARY_CHANGED || [[ " ${CHANGED_INSTANCES[*]} " == *" ${cc} "* ]]; then
      log "restart ${unit} (کانفیگ/باینری تغییر کرده)"; run systemctl restart "$unit"; acted=true
    else
      ok "${unit} در حال اجراست و تغییری ندارد"
    fi
    if $acted; then
      if $DRY_RUN; then echo "${C_YLW}[DRY-RUN]${C_RST} sleep ${START_STAGGER_SEC}"; else sleep "$START_STAGGER_SEC"; fi
    fi
  done
  return 0
}

# =============================================================================
# مرحله 7 و 8: تست سلامت (موازی) + یک بار ریستارت برای خراب‌ها
# =============================================================================
# خروجی: "OK|ip|country" یا "FAIL|ip|country|reason"
probe_once() {
  local port=$1 out ip country
  out="$(curl -sS --max-time "$TEST_TIMEOUT" --socks5-hostname "127.0.0.1:${port}" "$TEST_URL" 2>/dev/null)" || return 1
  ip="$(jq -r '.ip // empty' <<<"$out" 2>/dev/null)" || return 1
  country="$(jq -r '.country // empty' <<<"$out" 2>/dev/null)" || return 1
  [[ -n "$ip" ]] || return 1
  echo "${ip}|${country}"
}

# تا HEALTH_WAIT ثانیه تلاش؛ نتیجه در فایل result_dir/CC
health_wait_one() {
  local cc=$1 port=$2 outdir=$3 deadline res ip country
  deadline=$(( $(date +%s) + HEALTH_WAIT ))
  while :; do
    if res="$(probe_once "$port")"; then
      ip="${res%%|*}"; country="${res##*|}"
      if [[ "$country" == "$cc" ]] || ! $STRICT_COUNTRY_MATCH; then
        echo "OK|${ip}|${country}" > "${outdir}/${cc}"; return 0
      fi
      # کشور اشتباه: ادامه تلاش تا پایان مهلت
      echo "FAIL|${ip}|${country}|country-mismatch" > "${outdir}/${cc}"
    else
      [[ -f "${outdir}/${cc}" ]] || echo "FAIL|-|-|no-response" > "${outdir}/${cc}"
    fi
    (( $(date +%s) >= deadline )) && return 0
    sleep "$HEALTH_POLL_INTERVAL"
  done
}

health_round() {
  local outdir=$1; shift
  local cc n=0
  for cc in "$@"; do
    rm -f "${outdir}/${cc}"
    health_wait_one "$cc" "${SOCKS_PORT[$cc]}" "$outdir" &
    n=$((n + 1))
    if (( n % HEALTH_PARALLEL == 0 )); then
      wait || true
    fi
  done
  wait || true
}

run_health_checks() {
  if $DRY_RUN; then
    echo "${C_YLW}[DRY-RUN]${C_RST} health-check ${#COUNTRIES[@]} instance (تا ${HEALTH_WAIT}s برای هرکدام)"
    return 0
  fi
  local outdir="${WORK_TMP}/health" cc st
  mkdir -p "$outdir"
  log "تست سلامت ${#COUNTRIES[@]} instance به‌صورت موازی (حداکثر ${HEALTH_WAIT}s)..."
  health_round "$outdir" "${COUNTRIES[@]}"

  # مرحله 8: ریستارت یک‌باره و تست مجدد برای FAILها
  local retry=()
  for cc in "${COUNTRIES[@]}"; do
    st="$(cut -d'|' -f1 "${outdir}/${cc}" 2>/dev/null || echo FAIL)"
    [[ "$st" == "OK" ]] || retry+=("$cc")
  done
  if ((${#retry[@]})); then
    warn "ریستارت و تست مجدد: ${retry[*]}"
    for cc in "${retry[@]}"; do
      systemctl restart "${SERVICE_PREFIX}${cc}.service" || true
      sleep "$START_STAGGER_SEC"
    done
    health_round "$outdir" "${retry[@]}"
  fi

  # جدول رنگی
  echo
  printf "${C_BLD}%-8s | %-6s | %-6s | %-39s | %-12s | %s${C_RST}\n" "COUNTRY" "SOCKS" "HTTP" "IP" "REAL_COUNTRY" "STATUS"
  printf '%s\n' "---------+--------+--------+-----------------------------------------+--------------+--------"
  local line ip real reason
  for cc in "${COUNTRIES[@]}"; do
    line="$(cat "${outdir}/${cc}" 2>/dev/null || echo 'FAIL|-|-|no-result')"
    IFS='|' read -r st ip real reason <<<"$line"
    if [[ "$st" == "OK" ]]; then
      OK_LIST+=("$cc")
      printf "%-8s | %-6s | %-6s | %-39s | %-12s | ${C_GRN}%s${C_RST}\n" "$cc" "${SOCKS_PORT[$cc]}" "${HTTP_PORT[$cc]}" "$ip" "$real" "OK"
    else
      FAIL_LIST+=("$cc")
      printf "%-8s | %-6s | %-6s | %-39s | %-12s | ${C_RED}%s${C_RST}\n" "$cc" "${SOCKS_PORT[$cc]}" "${HTTP_PORT[$cc]}" "$ip" "$real" "FAIL (${reason:-?})"
    fi
  done
  echo
}

# =============================================================================
# مرحله 10: فایروال و تأیید listen فقط روی 127.0.0.1
# =============================================================================
setup_firewall() {
  $MANAGE_UFW || { log "مدیریت ufw غیرفعال است (MANAGE_UFW=false)"; return 0; }
  command -v ufw >/dev/null || { warn "ufw موجود نیست"; return 0; }
  local s_range="${SOCKS_PORT_BASE}:$(( SOCKS_PORT_BASE + MAX_INSTANCES - 1 ))"
  $DRY_RUN || { install -d -m 0750 -o root -g root "$DATA_DIR"; : > "$FIREWALL_STATE"; chmod 0600 "$FIREWALL_STATE"; }
  local h_range="${HTTP_PORT_BASE}:$(( HTTP_PORT_BASE + MAX_INSTANCES - 1 ))"
  # ufw ترافیک loopback را در before.rules قبل از این ruleها می‌پذیرد، پس دسترسی لوکال حفظ می‌شود.
  # فقط ruleهایی که خود اسکریپت ساخته ثبت می‌شوند تا uninstall به rule کاربر دست نزند.
  if ! ufw status 2>/dev/null | grep -q "$s_range.*psiphon-local-only"; then
    run ufw deny proto tcp from any to any port "$s_range" comment 'psiphon-local-only'
    $DRY_RUN || printf '%s\n' socks >> "$FIREWALL_STATE"
  fi
  if ! ufw status 2>/dev/null | grep -q "$h_range.*psiphon-local-only"; then
    run ufw deny proto tcp from any to any port "$h_range" comment 'psiphon-local-only'
    $DRY_RUN || printf '%s\n' http >> "$FIREWALL_STATE"
  fi
  # Custom per-location ports may be outside the default ranges.
  local cc p
  for cc in "${COUNTRIES[@]}"; do
    for p in "${SOCKS_PORT[$cc]}" "${HTTP_PORT[$cc]}"; do
      if ! ufw status 2>/dev/null | grep -q "port ${p}.*psiphon-custom-local-only"; then
        run ufw deny proto tcp from any to any port "$p" comment 'psiphon-custom-local-only'
        $DRY_RUN || printf 'port:%s\n' "$p" >> "$FIREWALL_STATE"
      fi
    done
  done
  if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "ufw فعال نیست؛ ruleها اضافه شدند ولی اعمال نمی‌شوند. (اسکریپت عمداً ufw را enable نمی‌کند تا SSH قطع نشود)"
    warn "به هر حال پورت‌ها فقط روی 127.0.0.1 bind هستند و از بیرون قابل دسترس نیستند."
  fi
}

verify_listen() {
  $DRY_RUN && { echo "${C_YLW}[DRY-RUN]${C_RST} verify ss -tlnp"; return 0; }
  local cc port addrs bad=0 a
  for cc in "${COUNTRIES[@]}"; do
    for port in "${SOCKS_PORT[$cc]}" "${HTTP_PORT[$cc]}"; do
      addrs="$(ss -H -tlnp "sport = :${port}" 2>/dev/null | awk '{print $4}' || true)"
      [[ -z "$addrs" ]] && continue   # هنوز تونل برقرار نشده
      while read -r a; do
        if [[ "$a" != "127.0.0.1:${port}" ]]; then
          err "${cc}: پورت ${port} روی ${a} listen است (غیرلوکال)! سرویس متوقف می‌شود."
          systemctl stop "${SERVICE_PREFIX}${cc}.service" || true
          bad=1
        fi
      done <<<"$addrs"
    done
  done
  if ((bad)); then
    err "حداقل یک instance روی آدرس غیرلوکال listen می‌کرد و متوقف شد."
  else
    ok "تأیید شد: همه پورت‌های فعال psiphon فقط روی 127.0.0.1 هستند"
  fi
  return 0
}

# =============================================================================
# مرحله 11: اسکریپت کمکی psiphon-ctl
# =============================================================================
write_ctl_conf() {
  cat <<EOF | write_file "$CTL_CONF" 0644 "root:root"
# Generated by ${SCRIPT_NAME}
MAPPING_FILE="${MAPPING_FILE}"
SERVICE_PREFIX="${SERVICE_PREFIX}"
LOG_DIR="${LOG_DIR}"
TEST_URL="${TEST_URL}"
TEST_TIMEOUT=${TEST_TIMEOUT}
STRICT_COUNTRY_MATCH=${STRICT_COUNTRY_MATCH}
HEALTH_PARALLEL=${HEALTH_PARALLEL}
START_STAGGER_SEC=${START_STAGGER_SEC}
DISABLED_FILE="${DISABLED_LOCATIONS}"
EOF
}

write_ctl() {
  write_file "$CTL_PATH" 0755 "root:root" <<'CTL_EOF'
#!/usr/bin/env bash
# psiphon-ctl: مدیریت instanceهای سایفون (ساخته‌شده توسط install-psiphon.sh)
set -Eeuo pipefail
CONF="/etc/psiphon/psiphon-ctl.conf"
[[ -r "$CONF" ]] || { echo "config not found: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=""; R=""; Y=""; B=""; N=""; fi

declare -A SP=() HP=() DIS=(); ORDER=(); ACTIVE=()
if [[ -r "${DISABLED_FILE:-}" ]]; then
  while read -r cc _; do [[ "$cc" =~ ^[A-Za-z]{2}$ ]] && DIS[${cc^^}]=1; done < "$DISABLED_FILE"
fi
while read -r cc s h; do
  [[ -z "${cc:-}" || "$cc" == \#* ]] && continue
  SP[$cc]=$s; HP[$cc]=$h; ORDER+=("$cc")
  [[ -n "${DIS[$cc]:-}" ]] || ACTIVE+=("$cc")
done < "$MAPPING_FILE"

usage() {
  cat <<EOF
Usage: psiphon-ctl <command> [args]
  list                    نمایش mapping کشور/پورت
  status                  وضعیت همه سرویس‌ها
  start   [CC|all]        start (پیش‌فرض all)
  stop    [CC|all]        stop  (پیش‌فرض all)
  restart <CC|all>        restart
  test    <CC|all>        تست اتصال از طریق SOCKS
  logs    <CC> [-f]       لاگ journal
  healthcheck             تست همه + ریستارت خودکار خراب‌ها (برای تایمر)
EOF
}

need_root() { [[ $EUID -eq 0 ]] || { echo "need root" >&2; exit 1; }; }

targets() {
  local t="${1:-all}"
  if [[ "$t" == "all" ]]; then (( ${#ACTIVE[@]} )) && printf '%s\n' "${ACTIVE[@]}"; return; fi
  t="${t^^}"
  [[ -n "${SP[$t]:-}" ]] || { echo "unknown country: $t" >&2; exit 1; }
  echo "$t"
}

probe() { # $1=CC → "STATUS|ip|country"
  local cc=$1 out ip c
  if ! out="$(curl -sS --max-time "$TEST_TIMEOUT" --socks5-hostname "127.0.0.1:${SP[$cc]}" "$TEST_URL" 2>/dev/null)"; then
    echo "FAIL|-|-"; return
  fi
  ip="$(jq -r '.ip // "-"' <<<"$out" 2>/dev/null || echo -)"
  c="$(jq -r '.country // "-"' <<<"$out" 2>/dev/null || echo -)"
  if [[ "$ip" == "-" ]]; then echo "FAIL|-|-"
  elif [[ "$c" == "$cc" ]] || [[ "$STRICT_COUNTRY_MATCH" != "true" ]]; then echo "OK|$ip|$c"
  else echo "FAIL|$ip|$c"; fi
}

# تست موازی؛ خروجی: CC|STATUS|ip|country
test_many() {
  local tmp cc n=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/psiphon-ctl.XXXXXX")"
  for cc in "$@"; do
    ( echo "$cc|$(probe "$cc")" > "$tmp/$cc" ) &
    n=$((n + 1)); (( n % HEALTH_PARALLEL == 0 )) && wait
  done
  wait
  for cc in "$@"; do cat "$tmp/$cc"; done
  rm -rf -- "$tmp"
}

cmd_test() {
  local list; mapfile -t list < <(targets "${1:-all}")
  printf "${B}%-8s | %-6s | %-39s | %-7s | %s${N}\n" COUNTRY SOCKS IP REAL STATUS
  local cc st ip c ok=0 fail=0
  while IFS='|' read -r cc st ip c; do
    if [[ "$st" == OK ]]; then ok=$((ok+1)); col=$G; else fail=$((fail+1)); col=$R; fi
    printf "%-8s | %-6s | %-39s | %-7s | ${col}%s${N}\n" "$cc" "${SP[$cc]}" "$ip" "$c" "$st"
  done < <(test_many "${list[@]}")
  echo "OK=${ok} FAIL=${fail}"
}

cmd_status() {
  printf "${B}%-8s | %-6s | %-6s | %-10s | %s${N}\n" COUNTRY SOCKS HTTP ACTIVE ENABLED
  local cc a e col
  for cc in "${ORDER[@]}"; do
    a="$(systemctl is-active "${SERVICE_PREFIX}${cc}.service" 2>/dev/null || true)"
    e="$(systemctl is-enabled "${SERVICE_PREFIX}${cc}.service" 2>/dev/null || true)"
    [[ "$a" == active ]] && col=$G || col=$R
    [[ -n "${DIS[$cc]:-}" ]] && { a="disabled"; col=$Y; }
    printf "%-8s | %-6s | %-6s | ${col}%-10s${N} | %s\n" "$cc" "${SP[$cc]}" "${HP[$cc]}" "$a" "$e"
  done
}

svc_action() {
  need_root
  local action=$1 cc; shift
  while read -r cc; do
    echo "${action} ${SERVICE_PREFIX}${cc}"
    systemctl "$action" "${SERVICE_PREFIX}${cc}.service" || echo "${R}failed: $cc${N}" >&2
    [[ "$action" != stop ]] && sleep "$START_STAGGER_SEC"
  done < <(targets "${1:-all}")
}

cmd_healthcheck() {
  need_root
  exec 9>/run/psiphon-healthcheck.lock
  flock -n 9 || { echo "another healthcheck is running"; exit 0; }
  local log="${LOG_DIR}/healthcheck.log" cc st ip c bad=()
  while IFS='|' read -r cc st ip c; do
    if [[ "$st" != OK ]]; then bad+=("$cc"); fi
    echo "$(date '+%F %T') $cc port=${SP[$cc]} status=$st ip=$ip country=$c" >> "$log"
  done < <(test_many "${ACTIVE[@]}")
  for cc in "${bad[@]}"; do
    echo "$(date '+%F %T') $cc unhealthy -> restart" >> "$log"
    systemctl restart "${SERVICE_PREFIX}${cc}.service" || true
    sleep "$START_STAGGER_SEC"
  done
  echo "healthcheck done: total=${#ACTIVE[@]} skipped=$(( ${#ORDER[@]} - ${#ACTIVE[@]} )) restarted=${#bad[@]}"
}

case "${1:-}" in
  list)        printf "${B}%-8s %-8s %s${N}\n" COUNTRY SOCKS HTTP; for cc in "${ORDER[@]}"; do printf '%-8s %-8s %s\n' "$cc" "${SP[$cc]}" "${HP[$cc]}"; done ;;
  status)      cmd_status ;;
  start)       svc_action start "${2:-all}" ;;
  stop)        svc_action stop "${2:-all}" ;;
  restart)     [[ -n "${2:-}" ]] || { usage; exit 1; }; svc_action restart "$2" ;;
  test)        cmd_test "${2:-all}" ;;
  logs)        [[ -n "${2:-}" ]] || { usage; exit 1; }
               cc="$(targets "$2")"
               if [[ "${3:-}" == "-f" ]]; then journalctl -u "${SERVICE_PREFIX}${cc}.service" -f
               else journalctl -u "${SERVICE_PREFIX}${cc}.service" -n 200 --no-pager; fi ;;
  healthcheck) cmd_healthcheck ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown command: $1" >&2; usage; exit 1 ;;
esac
CTL_EOF
}

# =============================================================================
# مرحله 12: تایمر systemd برای health-check هر ۵ دقیقه
# =============================================================================
write_timer() {
  write_file "${SYSTEMD_DIR}/psiphon-healthcheck.service" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}
[Unit]
Description=${BRAND} Psiphon instances health-check and auto-restart
After=network-online.target

[Service]
Type=oneshot
ExecStart=${CTL_PATH} healthcheck
EOF
  write_file "${SYSTEMD_DIR}/psiphon-healthcheck.timer" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}
[Unit]
Description=${BRAND} psiphon health-check every ${HEALTH_TIMER_INTERVAL}

[Timer]
OnBootSec=3min
OnUnitActiveSec=${HEALTH_TIMER_INTERVAL}
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now psiphon-healthcheck.timer
}

# =============================================================================
# مرحله 13: logrotate
# =============================================================================
write_logrotate() {
  write_file "$LOGROTATE_FILE" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}
${LOG_DIR}/*.log {
    weekly
    rotate 8
    maxsize 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
${DATA_DIR}/telegram-bot.log ${DATA_DIR}/autoheal.log {
    weekly
    rotate 8
    maxsize 20M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
${INSTALL_LOG} {
    monthly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
}

# =============================================================================
# قابلیت‌های Part 2: Turbo و Network doctor
# =============================================================================
# =============================================================================
# بخش 3: ربات تلگرام و دیده‌بان سلامت
# =============================================================================
telegram_api() {
  local method=$1; shift
  [[ -r "$BOT_CONF" ]] || return 1
  # shellcheck disable=SC1090
  . "$BOT_CONF"
  local cfg rc=0
  cfg="$(mktemp "${TMPDIR:-/tmp}/psiphon-telegram.XXXXXX")"; chmod 0600 "$cfg"
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$BOT_TOKEN" "$method" > "$cfg"
  curl -fsS --retry 4 --retry-delay 2 --max-time 20 -X POST --config "$cfg" "$@" || rc=$?
  rm -f -- "$cfg"
  return "$rc"
}

bot_send_test() {
  local token=$1 chat=$2 cfg rc=0
  cfg="$(mktemp "${TMPDIR:-/tmp}/psiphon-telegram.XXXXXX")"
  chmod 0600 "$cfg"
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" > "$cfg"
  printf 'data-urlencode = "chat_id=%s"\ndata-urlencode = "text=%s: ربات با موفقیت راه‌اندازی شد ✅"\n' "$chat" "$BRAND" >> "$cfg"
  curl -fsS --retry 3 --max-time 20 -X POST --config "$cfg" | jq -e '.ok == true' >/dev/null || rc=$?
  rm -f -- "$cfg"
  return "$rc"
}

write_bot_files() {
  run install -d -m 0700 -o root -g root "$CONF_DIR"
  run install -d -m 0750 -o root -g root "$DATA_DIR"
  local bot_changed=false
  write_file "$BOT_SCRIPT" 0750 "root:root" <<'BOT_EOF'
#!/usr/bin/env bash
# =============================================================================
# MAXNET6G Telegram bot v3.2.0 (bash + curl + jq + awk)
#   - p2: ⚡ Ping radar (latency واقعی از تونل)، 📅 تست روزانه + گزارش ۲۴ساعته، ♻️ AUTO-HEAL
#   - inline UI با editMessageText، answerCallbackQuery، retry/backoff
#   - jobهای سنگین در پس‌زمینه با flock (روی systemd-run تا با restart ربات قطع نشوند)
#   - test_location / run_all_tests با خروجی JSON
# =============================================================================
set -Euo pipefail
umask 077

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
CONF="/etc/psiphon/telegram-bot.conf"
SETTINGS="/etc/psiphon/bot-settings.conf"
DISABLED_FILE="/etc/psiphon/disabled-locations.txt"
MAP="/etc/psiphon/mapping.txt"
DATA="/var/lib/psiphon"
RUN="/run/maxnet6g-bot"
CTL="/usr/local/bin/psiphon-ctl"
INSTALLER="/usr/local/bin/install-psiphon.sh"
IPREFRESH="/usr/local/bin/psiphon-ip-refresh"
BRAND="MAXNET6G"
VERSION="3.2.0"
OFFSET_FILE="${DATA}/telegram-bot.offset"
LAST_TESTS="${DATA}/last-tests.json"
LAST_PING="${DATA}/last-ping.json"
DAILY_LAST="${DATA}/daily-last.json"
DAILY_HISTORY="${DATA}/daily-history.json"
HEALTH_SAMPLES="${DATA}/health-samples.jsonl"
RISK_STATE="${DATA}/risk-alert.state"
AUTOHEAL_STATE="${DATA}/autoheal.state"
AUTOHEAL_LOG="${DATA}/autoheal.log"
# substring/طول رشته در bash باید UTF-8-aware باشد (systemd معمولاً LANG ندارد)
export LANG=C.UTF-8 LC_ALL=C.UTF-8 2>/dev/null || true

[[ -r "$CONF" ]] || exit 0
# shellcheck disable=SC1090
. "$CONF"
[[ "${BOT_ENABLED:-false}" == true ]] || exit 0
mkdir -p "$RUN" "$DATA"; chmod 0700 "$RUN"

# -----------------------------------------------------------------------------
# تنظیمات: پیش‌فرض‌ها + فایل settings (پارس امن، بدون source)
# -----------------------------------------------------------------------------
BTN_STYLE=auto            # auto | on | off  (رنگ دکمه از طریق فیلد style در Bot API جدید)
API_RETRIES=4
API_BACKOFF=1
API_TIMEOUT=30
TEST_PARALLEL=6
TEST_TIMEOUT=15
GEO_URL="https://ipinfo.io/json"
LAT_URL="https://www.gstatic.com/generate_204"
LAT_SAMPLES=3
SPEED_URL="https://speed.cloudflare.com/__down?bytes=1000000"
SPEED_TIMEOUT=25
STRICT_COUNTRY_MATCH=true
PENDING_TTL=300
CONFIRM_TTL=120
PAGE_SIZE=12
PAGE_COLS=3
# --- Part 2 ---
PING_SAMPLES=3            # نمونه‌های latency برای هر لوکیشن (میانه گزارش می‌شود)
PING_TIMEOUT=8
PING_GOOD_MS=120          # کمتر = 🟢
PING_SLOW_MS=300          # کمتر = 🟡 ، بیشتر = 🟠 ، خطا = 🔴
DAILY_TEST_HOUR=09:00     # فقط برای نمایش؛ زمان واقعی را تایمر systemd تعیین می‌کند
DAILY_TOP=5
HISTORY_DAYS=7
AUTO_HEAL=false           # true = ریستارت خودکار بعد از AUTO_HEAL_FAILS خطای پیاپی
AUTO_HEAL_FAILS=3
AUTO_HEAL_MAX_PER_HOUR=3  # سقف سخت: ۳
DAILY_TEST_ENABLED=true
WATCHER_INTERVAL_MIN=2
IP_REFRESH_HOURS=6
ALERT_LOCATION_DOWN=true
ALERT_SERVER_DOWN=true
ALERT_LATENCY=true
LATENCY_ALERT_MS=300
ALERT_COOLDOWN_SEC=300
QUIET_HOURS_ENABLED=false
QUIET_HOURS_START=23:00
QUIET_HOURS_END=07:00
SUMMARY_ONLY=false
UI_LANG=FA
UI_COMPACT=false
EMOJI_ENABLED=true
EXTRA_ADMIN_IDS=
RISK_ENABLED=true
RISK_SENSITIVITY=50
RISK_THRESHOLD=60
RISK_COOLDOWN_SEC=1800
RISK_AUTO_RESTART=false
RISK_MUTE_UNTIL=0
settings_load() {
  local k v
  [[ -r "$SETTINGS" ]] || return 0
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Z_]+$ ]] || continue
    v="${v%\"}"; v="${v#\"}"
    [[ "$v" =~ ^[A-Za-z0-9_.:/?=\&%+-]*$ ]] || continue
    case "$k" in
      BTN_STYLE|API_RETRIES|API_BACKOFF|API_TIMEOUT|TEST_PARALLEL|TEST_TIMEOUT|GEO_URL|LAT_URL|LAT_SAMPLES|\
      SPEED_URL|SPEED_TIMEOUT|STRICT_COUNTRY_MATCH|PENDING_TTL|CONFIRM_TTL|PAGE_SIZE|PAGE_COLS|\
      PING_SAMPLES|PING_TIMEOUT|PING_GOOD_MS|PING_SLOW_MS|DAILY_TEST_HOUR|DAILY_TOP|HISTORY_DAYS|\
      AUTO_HEAL|AUTO_HEAL_FAILS|AUTO_HEAL_MAX_PER_HOUR|DAILY_TEST_ENABLED|WATCHER_INTERVAL_MIN|\
      IP_REFRESH_HOURS|ALERT_LOCATION_DOWN|ALERT_SERVER_DOWN|ALERT_LATENCY|LATENCY_ALERT_MS|\
      ALERT_COOLDOWN_SEC|QUIET_HOURS_ENABLED|QUIET_HOURS_START|QUIET_HOURS_END|SUMMARY_ONLY|\
      UI_LANG|UI_COMPACT|EMOJI_ENABLED|EXTRA_ADMIN_IDS) printf -v "$k" '%s' "$v" ;;
      RISK_ENABLED|RISK_SENSITIVITY|RISK_THRESHOLD|RISK_COOLDOWN_SEC|RISK_AUTO_RESTART|RISK_MUTE_UNTIL) printf -v "$k" '%s' "$v" ;;
    esac
  done < "$SETTINGS"
}
settings_load
# مقادیر عددی Part 2: نامعتبر → پیش‌فرض
for _k in PING_SAMPLES:3 PING_TIMEOUT:8 PING_GOOD_MS:120 PING_SLOW_MS:300 DAILY_TOP:5 HISTORY_DAYS:7 AUTO_HEAL_FAILS:3 AUTO_HEAL_MAX_PER_HOUR:3; do
  _n=${_k%%:*}; [[ "${!_n}" =~ ^[1-9][0-9]*$ ]] || printf -v "$_n" '%s' "${_k#*:}"
done; unset _k _n
[[ "$RISK_SENSITIVITY" =~ ^[1-9][0-9]?$|^100$ ]] || RISK_SENSITIVITY=50
[[ "$RISK_THRESHOLD" =~ ^[1-9][0-9]?$|^100$ ]] || RISK_THRESHOLD=60
[[ "$RISK_COOLDOWN_SEC" =~ ^[0-9]+$ ]] || RISK_COOLDOWN_SEC=1800

# -----------------------------------------------------------------------------
# ابزارهای عمومی
# -----------------------------------------------------------------------------
now() { date +%s; }
esc() { local s=${1-} a='&amp;' l='&lt;' g='&gt;'; s=${s//&/"$a"}; s=${s//</"$l"}; s=${s//>/"$g"}; printf '%s' "$s"; }
trunc() { local s=$1 n=${2:-3500}; (( ${#s} > n )) && s="…${s: -n}"; printf '%s' "$s"; }
flag() { # NL → 🇳🇱  (بایت‌های UTF-8 مستقیم؛ مستقل از locale)
  local cc=${1^^} a b
  [[ "$cc" =~ ^[A-Z]{2}$ ]] || return 0
  printf -v a '%d' "'${cc:0:1}"; printf -v b '%d' "'${cc:1:1}"
  printf "\\xF0\\x9F\\x87\\x$(printf %02X $((0xA6 + a - 65)))\\xF0\\x9F\\x87\\x$(printf %02X $((0xA6 + b - 65)))"
}
HDR="🟦 <b>${BRAND}</b>  <i>v${VERSION}</i>"$'\n\n'
log_bot() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "${DATA}/telegram-bot.log" 2>/dev/null || true; }

is_disabled() { [[ -r "$DISABLED_FILE" ]] && grep -qiE "^[[:space:]]*${1}([[:space:]]|#|$)" "$DISABLED_FILE"; }
all_locations() { awk '$1 !~ /^#/ && NF>=2 {print toupper($1)}' "$MAP" 2>/dev/null; }
enabled_locations() { local c; while read -r c; do is_disabled "$c" || echo "$c"; done < <(all_locations); }
socks_port() { awk -v c="${1^^}" 'toupper($1)==c {print $2; exit}' "$MAP" 2>/dev/null; }
valid_cc() { [[ "${1:-}" =~ ^[A-Za-z]{2}$ ]] && [[ -n "$(socks_port "$1")" ]]; }

# -----------------------------------------------------------------------------
# Telegram API: retry با backoff نمایی + احترام به retry_after (429)
#   api METHOD JSON  → بدنه پاسخ روی stdout؛ rc=0 فقط اگر ok==true
# -----------------------------------------------------------------------------
api() {
  local method=$1 json=${2:-'{}'} maxt=${3:-$API_TIMEOUT}
  local attempt=1 delay=$API_BACKOFF cfg out code body ra
  cfg="$(mktemp "${RUN}/api.XXXXXX")" || return 1
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$BOT_TOKEN" "$method" > "$cfg"   # توکن در ps دیده نشود
  while :; do
    out="$(curl -sS --max-time "$maxt" -X POST --config "$cfg" -H 'Content-Type: application/json' \
            --data-binary "$json" -w $'\n%{http_code}' 2>/dev/null)" || out=$'\n000'
    code="${out##*$'\n'}"; body="${out%$'\n'*}"
    if [[ "$code" == 200 ]] && jq -e '.ok == true' >/dev/null 2>&1 <<<"$body"; then
      rm -f -- "$cfg"; printf '%s' "$body"; return 0
    fi
    # خطاهای قطعی (درخواست بد/دسترسی) تکرار نمی‌شوند
    if [[ "$code" =~ ^(400|401|403|404)$ ]] || (( attempt >= API_RETRIES )); then
      rm -f -- "$cfg"; printf '%s' "$body"
      [[ "$code" != 400 ]] && log_bot "api ${method} failed code=${code}"
      return 1
    fi
    ra="$(jq -r '.parameters.retry_after // empty' 2>/dev/null <<<"$body" || true)"
    sleep "${ra:-$delay}"
    delay=$((delay * 2)); attempt=$((attempt + 1))
  done
}

# -----------------------------------------------------------------------------
# کیبورد: DSL ساده → JSON
#   هر خط = یک ردیف، دکمه‌ها با ";;" جدا، هر دکمه "label|callback|style"
#   style: danger(🔴) success(🟢) primary(🔵) یا خالی
# -----------------------------------------------------------------------------
kb() { jq -Rsc 'split("\n") | map(select(length>0) | split(";;") | map(split("|") |
        {text:.[0], callback_data:.[1]} + (if ((.[2] // "") != "") then {style:.[2]} else {} end)))
        | {inline_keyboard:.}'; }
nav() { printf '⬅️ بازگشت|%s;;🏠 منو|m\n' "${1:-m}"; }
style_enabled() { [[ "$BTN_STYLE" == on ]] || { [[ "$BTN_STYLE" == auto && ! -e "${RUN}/style.off" ]]; }; }
strip_style() { jq -c 'walk(if type == "object" then del(.style) else . end)'; }

# _msg METHOD TEXT KB [MSGID] → با fallback بدون style
_msg() {
  local method=$1 text=$2 kbj=${3:-} mid=${4:-} payload resp
  [[ -n "$kbj" ]] && ! style_enabled && kbj="$(strip_style <<<"$kbj")"
  payload="$(jq -nc --arg c "$ADMIN_CHAT_ID" --arg t "$text" --arg m "$mid" --arg k "$kbj" \
    '{chat_id:$c, text:$t, parse_mode:"HTML", disable_web_page_preview:true}
     + (if $m != "" then {message_id:($m|tonumber)} else {} end)
     + (if $k != "" then {reply_markup:($k|fromjson)} else {} end)')"
  if resp="$(api "$method" "$payload")"; then printf '%s' "$resp"; return 0; fi
  # پیام تغییری نکرده: موفق حساب می‌شود
  grep -q 'message is not modified' <<<"$resp" && return 0
  # Bot API قدیمی/ناسازگار با style: یک‌بار بدون style و به خاطر سپردن
  if [[ -n "$kbj" ]] && grep -q '"style"' <<<"$kbj"; then
    payload="$(jq -c 'walk(if type == "object" then del(.style) else . end)' <<<"$payload")"
    if resp="$(api "$method" "$payload")"; then
      : > "${RUN}/style.off"; log_bot "button style unsupported → fallback (emoji-only colors)"
      printf '%s' "$resp"; return 0
    fi
  fi
  return 1
}
send() { _msg sendMessage "$1" "${2:-}"; }
edit() { # edit TEXT KB MSGID ؛ اگر edit نشد، پیام جدید
  _msg editMessageText "$1" "${2:-}" "$3" >/dev/null || send "$1" "${2:-}" >/dev/null
}
answer_cb() { # answer_cb ID [TEXT] [alert]
  [[ -n "${1:-}" ]] || return 0
  api answerCallbackQuery "$(jq -nc --arg i "$1" --arg t "${2:-}" --arg a "${3:-false}" \
    '{callback_query_id:$i} + (if $t != "" then {text:$t, show_alert:($a=="true")} else {} end)')" 10 >/dev/null || true
}
delete_msg() { api deleteMessage "$(jq -nc --arg c "$ADMIN_CHAT_ID" --argjson m "$1" '{chat_id:$c, message_id:$m}')" >/dev/null; }

# صاحب پیام: اگر کاربر وسط job جای دیگری رفت، نتیجه به‌صورت پیام جدید می‌آید
set_owner() { printf '%s' "$2" > "${RUN}/owner.$1"; }
get_owner() { cat "${RUN}/owner.$1" 2>/dev/null || true; }

# -----------------------------------------------------------------------------
# pending input (مثلاً منتظر تایپ کد کشور)
# -----------------------------------------------------------------------------
set_pending()   { printf '%s %s %s\n' "$1" "$2" "$(now)" > "${RUN}/pending"; }   # kind msgid
clear_pending() { rm -f -- "${RUN}/pending"; }
get_pending() {
  local kind mid t
  read -r kind mid t < "${RUN}/pending" 2>/dev/null || return 1
  (( $(now) - t <= PENDING_TTL )) || { clear_pending; return 1; }
  printf '%s %s' "$kind" "$mid"
}

# =============================================================================
# Helpers تست
# =============================================================================
# test_location CC → یک خط JSON:
# {cc,state,service,port,ip,country,latency_avg_ms,latency_best_ms,speed_kbps,score,reason,ts}
#   state: ok | degraded | fail | disabled
test_location() {
  local cc=${1^^} port svc state=ok reason="" ip="-" country="-" out rc
  local lat_sum=0 lat_n=0 lat_best=0 avg=0 t ms speed=0 score=0 i
  port="$(socks_port "$cc")"
  _emit() {
    jq -nc --arg cc "$cc" --arg st "$state" --arg svc "${svc:-unknown}" --arg port "${port:-0}" \
      --arg ip "$ip" --arg c "$country" --arg avg "$avg" --arg best "$lat_best" --arg sp "$speed" \
      --arg sc "$score" --arg r "$reason" --arg ts "$(date -Is)" \
      '{cc:$cc,state:$st,service:$svc,port:($port|tonumber),ip:$ip,country:$c,
        latency_avg_ms:($avg|tonumber),latency_best_ms:($best|tonumber),speed_kbps:($sp|tonumber),
        score:($sc|tonumber),reason:$r,ts:$ts}'
  }
  if [[ -z "$port" ]]; then state=fail; reason="در mapping نیست"; _emit; return 0; fi
  if is_disabled "$cc"; then state=disabled; reason="در لیست غیرفعال"; _emit; return 0; fi
  svc="$(systemctl is-active "psiphon-${cc}.service" 2>/dev/null || true)"
  if [[ "$svc" != active ]]; then state=fail; reason="سرویس ${svc:-unknown}"; _emit; return 0; fi
  if ! ss -Hltn "sport = :${port}" 2>/dev/null | grep -q .; then state=fail; reason="پورت SOCKS ${port} باز نیست"; _emit; return 0; fi

  # 1) egress IP / کشور
  out="$(curl -sS --max-time "$TEST_TIMEOUT" --socks5-hostname "127.0.0.1:${port}" "$GEO_URL" 2>/dev/null)"; rc=$?
  if (( rc != 0 )); then
    state=fail
    case $rc in
      28) reason="timeout (${TEST_TIMEOUT}s) — تونل برقرار نیست" ;;
      7|97) reason="اتصال به SOCKS رد شد" ;;
      35|60) reason="خطای TLS" ;;
      6) reason="DNS از داخل تونل resolve نشد" ;;
      *) reason="probe ناموفق (curl ${rc})" ;;
    esac
    _emit; return 0
  fi
  ip="$(jq -r '.ip // "-"' 2>/dev/null <<<"$out" || echo -)"
  country="$(jq -r '.country // "-"' 2>/dev/null <<<"$out" || echo -)"
  [[ "$ip" == "-" ]] && { state=fail; reason="پاسخ geo نامعتبر"; _emit; return 0; }
  if [[ "${country^^}" != "$cc" ]]; then
    if [[ "$STRICT_COUNTRY_MATCH" == true ]]; then state=fail; reason="کشور اشتباه: ${country}"; _emit; return 0; fi
    state=degraded; reason="کشور اشتباه: ${country}"
  fi

  # 2) latency: میانگین و بهترین
  for ((i = 0; i < LAT_SAMPLES; i++)); do
    t="$(curl -sS -o /dev/null --max-time 10 -w '%{time_total}' --socks5-hostname "127.0.0.1:${port}" "$LAT_URL" 2>/dev/null)" || continue
    ms="$(awk -v t="$t" 'BEGIN{printf "%d", t*1000}')"
    (( ms > 0 )) || continue
    lat_sum=$((lat_sum + ms)); lat_n=$((lat_n + 1))
    (( lat_best == 0 || ms < lat_best )) && lat_best=$ms
  done
  (( lat_n > 0 )) && avg=$((lat_sum / lat_n))

  # 3) سرعت تقریبی (~1MB)
  t="$(curl -sS -o /dev/null --max-time "$SPEED_TIMEOUT" -w '%{speed_download} %{size_download}' \
        --socks5-hostname "127.0.0.1:${port}" "$SPEED_URL" 2>/dev/null)" || t=""
  if [[ -n "$t" ]]; then speed="$(awk -v s="${t%% *}" 'BEGIN{printf "%d", s*8/1000}')"; fi

  # 4) امتیاز 0-100: اتصال 30 + latency 40 + سرعت 30
  score="$(awk -v ok="$([[ "${country^^}" == "$cc" ]] && echo 30 || echo 15)" -v a="$avg" -v n="$lat_n" -v sp="$speed" 'BEGIN{
    l = (n == 0) ? 0 : 40 - (a - 200) / 45; if (l > 40) l = 40; if (l < 0) l = 0
    s = sp / 4000 * 30; if (s > 30) s = 30; if (s < 0) s = 0
    printf "%d", ok + l + s }')"
  if (( lat_n == 0 )); then state=degraded; reason="${reason:+$reason؛ }latency ناموفق"; fi
  if (( speed == 0 )); then state=degraded; reason="${reason:+$reason؛ }تست سرعت ناموفق"; fi
  if [[ "$state" == ok ]] && (( score < 50 )); then state=degraded; reason="کیفیت پایین"; fi
  _emit
}

# run_all_tests [CC...] → آرایه JSON مرتب بر اساس score؛ disabledها رد می‌شوند (پیشرفت روی PROG_MID)
run_all_tests() {
  local l=("$@") list=() cc
  (( ${#l[@]} )) || mapfile -t l < <(enabled_locations)
  for cc in "${l[@]}"; do is_disabled "$cc" || list+=("$cc"); done
  par_run test_location "${list[@]}" | jq -c 'sort_by(-.score)'
}

state_icon() { case "$1" in ok) printf '🟢';; degraded) printf '🟡';; fail) printf '🔴';; disabled) printf '⚪';; *) printf '⚫';; esac; }

fmt_table() { # آرایه JSON → جدول <pre>
  jq -r '.[] | [.state, .cc, (.score|tostring), (if .latency_avg_ms>0 then (.latency_avg_ms|tostring)+"ms" else "-" end),
                (if .speed_kbps>0 then ((.speed_kbps/1000*10|floor)/10|tostring)+"Mb" else "-" end), .country, .reason] | @tsv' <<<"$1" |
  while IFS=$'\t' read -r st cc sc lat sp c r; do
    printf '%s %-2s %3s %7s %6s %-2s %s\n' "$(state_icon "$st")" "$cc" "$sc" "$lat" "$sp" "$c" "$(esc "${r:0:28}")"
  done
}

fmt_single() {
  local j=$1
  jq -r '"\(.state)\t\(.cc)\t\(.service)\t\(.port)\t\(.ip)\t\(.country)\t\(.latency_avg_ms)\t\(.latency_best_ms)\t\(.speed_kbps)\t\(.score)\t\(.reason)"' <<<"$j" |
  while IFS=$'\t' read -r st cc svc port ip c avg best sp sc r; do
    printf '%s <b>%s %s</b>  امتیاز: <b>%s/100</b>\n\n' "$(state_icon "$st")" "$(flag "$cc")" "$cc" "$sc"
    printf '<pre>service : %s\nsocks   : 127.0.0.1:%s\negress  : %s (%s)\nlatency : avg %sms / best %sms\nspeed   : ~%s kbps\nreason  : %s</pre>' \
      "$svc" "$port" "$(esc "$ip")" "$c" "$avg" "$best" "$sp" "$(esc "${r:--}")"
  done
}

# =============================================================================
# Part 2 · ابزار پیشرفت (progress bar) و اجرای موازی
# =============================================================================
PROG_MID=""; PROG_LABEL=""
prog_bar() { # done total [width] → ▰▰▰▱▱▱
  local d=$1 t=$2 w=${3:-12} f i s=""
  (( t > 0 )) || t=1; f=$(( d * w / t )); (( f > w )) && f=$w
  for ((i = 0; i < w; i++)); do if (( i < f )); then s+='▰'; else s+='▱'; fi; done
  printf '%s' "$s"
}
progress() { # done total → ویرایش پیام PROG_MID (فقط اگر کاربر هنوز روی همین پیام است؛ هرگز پیام جدید نمی‌سازد)
  local d=$1 t=$2 pct
  [[ -n "$PROG_MID" ]] || return 0
  [[ "$(get_owner "$PROG_MID")" == job:* ]] || return 0
  (( t > 0 )) || t=1; pct=$(( d * 100 / t ))
  _msg editMessageText "${HDR}⏳ <b>${PROG_LABEL}</b>
<code>$(prog_bar "$d" "$t")</code>  ${d}/${t} · ${pct}%
<i>نتیجه همین‌جا نمایش داده می‌شود.</i>" "$(printf '🏠 منو|m\n' | kb)" "$PROG_MID" >/dev/null 2>&1 || true
}
par_run() { # par_run FUNC CC... → آرایه JSON (نامرتب)؛ هر ۲ ثانیه پیشرفت روی PROG_MID
  local fn=$1 tmp pid total d last=-1 cc; shift
  total=$#
  (( total )) || { echo '[]'; return 0; }
  tmp="$(mktemp -d "${RUN}/par.XXXXXX")" || { echo '[]'; return 0; }
  (
    for cc in "$@"; do
      { "$fn" "$cc" > "${tmp}/${cc}.part" 2>/dev/null && mv -f "${tmp}/${cc}.part" "${tmp}/${cc}.json"; } &
      while (( $(jobs -rp | wc -l) >= TEST_PARALLEL )); do wait -n 2>/dev/null || true; done
    done
    wait
  ) </dev/null >/dev/null 2>&1 &
  pid=$!
  if [[ -n "$PROG_MID" ]]; then
    progress 0 "$total"
    while kill -0 "$pid" 2>/dev/null; do
      sleep 2
      d="$(find "$tmp" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
      (( d != last )) && { progress "$d" "$total"; last=$d; }
    done
  fi
  wait "$pid" 2>/dev/null || true
  if compgen -G "${tmp}/*.json" >/dev/null; then jq -sc '.' "${tmp}"/*.json; else echo '[]'; fi
  rm -rf -- "$tmp"
}

# =============================================================================
# Part 2 · ⚡ PING RADAR
#   latency واقعی = time_starttransfer − time_appconnect از داخل SOCKS همان لوکیشن
#   (یک رفت‌وبرگشت HTTP خالص از مسیر تونل؛ هزینه‌ی handshake SOCKS/TLS حذف می‌شود) → میانه‌ی نمونه‌ها
# =============================================================================
# ping_location CC → {cc,state,ms,samples,reason,ts}   state: ok | down | disabled
ping_location() {
  local cc=${1^^} port svc state=down reason="" ms=0 i out rc last_rc=0 v vals=()
  port="$(socks_port "$cc")"
  if [[ -z "$port" ]]; then reason="در mapping نیست"
  elif is_disabled "$cc"; then state=disabled; reason="غیرفعال"
  else
    svc="$(systemctl is-active "psiphon-${cc}.service" 2>/dev/null || true)"
    if [[ "$svc" != active ]]; then reason="سرویس ${svc:-unknown}"
    elif ! ss -Hltn "sport = :${port}" 2>/dev/null | grep -q .; then reason="پورت SOCKS ${port} باز نیست"
    else
      for ((i = 0; i < PING_SAMPLES; i++)); do
        out="$(curl -sS -o /dev/null --max-time "$PING_TIMEOUT" \
                 -w '%{http_code} %{time_connect} %{time_appconnect} %{time_starttransfer}' \
                 --socks5-hostname "127.0.0.1:${port}" "$LAT_URL" 2>/dev/null)"; rc=$?
        if (( rc != 0 )); then last_rc=$rc; continue; fi
        v="$(awk '$1 != "000" { b = ($3 > 0) ? $3 : $2; d = ($4 - b) * 1000; if (d < 1) d = 1; printf "%d", d }' <<<"$out")"
        [[ "$v" =~ ^[0-9]+$ ]] && vals+=("$v")
      done
      if (( ${#vals[@]} )); then
        state=ok
        ms="$(printf '%s\n' "${vals[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')"
        (( ${#vals[@]} < PING_SAMPLES )) && reason="loss $(( (PING_SAMPLES - ${#vals[@]}) * 100 / PING_SAMPLES ))%"
      else
        case $last_rc in
          28)    reason="timeout (${PING_TIMEOUT}s)" ;;
          7|97)  reason="اتصال SOCKS رد شد" ;;
          35|60) reason="خطای TLS" ;;
          6)     reason="DNS داخل تونل resolve نشد" ;;
          *)     reason="ناموفق (curl ${last_rc})" ;;
        esac
      fi
    fi
  fi
  jq -nc --arg cc "$cc" --arg st "$state" --arg ms "$ms" --arg n "${#vals[@]}" --arg r "$reason" --arg ts "$(date -Is)" \
    '{cc:$cc, state:$st, ms:($ms|tonumber), samples:($n|tonumber), reason:$r, ts:$ts}'
}

# run_pings [CC...] → سالم‌ها بر اساس ms صعودی (بهترین→بدترین)، بعد خراب‌ها
run_pings() {
  local l=("$@") list=() cc
  (( ${#l[@]} )) || mapfile -t l < <(enabled_locations)
  for cc in "${l[@]}"; do is_disabled "$cc" || list+=("$cc"); done
  par_run ping_location "${list[@]}" |
    jq -c 'map(select(.state != "disabled")) | (map(select(.state == "ok")) | sort_by(.ms)) + (map(select(.state != "ok")) | sort_by(.cc))'
}

ping_grade() { if (( $1 < PING_GOOD_MS )); then echo g; elif (( $1 < PING_SLOW_MS )); then echo y; else echo o; fi; }
grade_dot()  { case "$1" in g) printf '🟢';; y) printf '🟡';; o) printf '🟠';; *) printf '🔴';; esac; }
ping_bar() { # ms → ۱۰ خانه؛ هر ۶۰ms یک خانه کمتر (حداقل ۱)؛ خراب = خالی
  local ms=$1 f i s=""
  if (( ms <= 0 )); then f=0; else f=$(( 10 - ms / 60 )); (( f < 1 )) && f=1; (( f > 10 )) && f=10; fi
  for ((i = 0; i < 10; i++)); do if (( i < f )); then s+='▰'; else s+='▱'; fi; done
  printf '%s' "$s"
}

ping_card() { # ping_card RESULTS_JSON [all|best|down] → کارت جعبه‌ای (متن خام، بعداً esc می‌شود)
  local res=$1 view=${2:-all} rows="" cc st ms r g line sel
  local n_ok=0 n_slow=0 n_down=0 best="-" worst="-" B='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  while IFS=$'\t' read -r cc st ms r; do
    if [[ "$st" == ok ]]; then
      g="$(ping_grade "$ms")"; if [[ "$g" == g ]]; then n_ok=$((n_ok + 1)); else n_slow=$((n_slow + 1)); fi
      [[ "$best" == "-" ]] && best="$(flag "$cc") ${cc} ${ms}ms"
      worst="$(flag "$cc") ${cc} ${ms}ms"
    else n_down=$((n_down + 1)); fi
  done < <(jq -r '.[] | [.cc, .state, (.ms|tostring), .reason] | @tsv' <<<"$res")
  case "$view" in
    best) sel='[.[] | select(.state == "ok")][0:5]' ;;
    down) sel='[.[] | select(.state != "ok")]' ;;
    *)    sel='.' ;;
  esac
  while IFS=$'\t' read -r cc st ms r; do
    if [[ "$st" == ok ]]; then
      line="$(printf '┃ %s %-2s %s %5sms %s' "$(flag "$cc")" "$cc" "$(ping_bar "$ms")" "$ms" "$(grade_dot "$(ping_grade "$ms")")")"
    else
      line="$(printf '┃ %s %-2s %s  DOWN  🔴' "$(flag "$cc")" "$cc" "$(ping_bar 0)")"
      [[ "$view" == down && -n "${r:-}" ]] && line+=$'\n'"┃     └ ${r}"
    fi
    rows+="${line}"$'\n'
  done < <(jq -r "${sel} | .[] | [.cc, .state, (.ms|tostring), .reason] | @tsv" <<<"$res")
  if [[ -z "$rows" ]]; then
    if [[ "$view" == down ]]; then rows=$'┃ ✨ هیچ لوکیشن خرابی نیست\n'; else rows=$'┃ — نتیجه‌ای نیست\n'; fi
  fi
  printf '┏%s┓\n┃    ⚡ MAXNET6G PING RADAR ⚡\n┣%s┫\n%s┣%s┫\n' "$B" "$B" "$rows" "$B"
  printf '┃ 🏆 best : %s\n┃ 🐢 worst: %s\n┃ 🟢 OK %s · 🟡 slow %s · 🔴 down %s\n┗%s┛' \
    "$best" "$worst" "$n_ok" "$n_slow" "$n_down" "$B"
}

ping_screen_text() { # [all|best|down] → متن کامل از کش آخرین پینگ
  local view=${1:-all} res ts title=""
  res="$(jq -c '.results // []' "$LAST_PING" 2>/dev/null || echo '[]')"
  ts="$(jq -r '.ts // ""' "$LAST_PING" 2>/dev/null || true)"
  case "$view" in best) title=$'<b>🏆 بهترین‌ها (Top 5)</b>\n' ;; down) title=$'<b>🔴 فقط خراب‌ها</b>\n' ;; esac
  printf '%s%s<pre>%s</pre>\n<i>⏱ latency واقعی از تونل · میانه‌ی %s نمونه · 🟢&lt;%s 🟡&lt;%s 🟠≥%s · %s</i>' \
    "$HDR" "$title" "$(esc "$(trunc "$(ping_card "$res" "$view")" 3400)")" \
    "$PING_SAMPLES" "$PING_GOOD_MS" "$PING_SLOW_MS" "$PING_SLOW_MS" "$(esc "${ts:0:16}" | tr 'T' ' ')"
}

ping_kb() { # view target
  local view=$1 target=${2:-all} b1='🏆 بهترین‌ها|pv:best|primary' b2='🔴 فقط خرابها|pv:down|danger'
  [[ "$view" == best ]] && b1='📋 همه|pv:all|primary'
  [[ "$view" == down ]] && b2='📋 همه|pv:all|primary'
  printf '🔄 دوباره|ping:%s|success;;%s\n%s;;🏠 منو|m\n' "$target" "$b1" "$b2" | kb
}

# =============================================================================
# Part 2 · 📅 تست روزانه + سلامت سرور + تاریخچه ۷ روزه
# =============================================================================
server_health() { # → JSON: DNS، CPU، RAM، دیسک
  local t0 t1 dns_ok=true h u n s i w x y z tot1 idle1 tot2 idle2 cpu load ncpu mt ma mp dp dfree upd
  t0="$(date +%s%3N)"
  for h in ipinfo.io api.telegram.org; do timeout 5 getent ahosts "$h" >/dev/null 2>&1 || dns_ok=false; done
  t1="$(date +%s%3N)"
  read -r _ u n s i w x y z _ < /proc/stat; tot1=$((u+n+s+i+w+x+y+z)); idle1=$((i+w))
  sleep 1
  read -r _ u n s i w x y z _ < /proc/stat; tot2=$((u+n+s+i+w+x+y+z)); idle2=$((i+w))
  cpu=$(( tot2 > tot1 ? (100 * ((tot2 - tot1) - (idle2 - idle1))) / (tot2 - tot1) : 0 ))
  read -r load _ < /proc/loadavg; ncpu="$(nproc 2>/dev/null || echo 1)"
  read -r mt ma < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d %d", t/1024, a/1024}' /proc/meminfo)
  mp=$(( mt > 0 ? (100 * (mt - ma)) / mt : 0 ))
  read -r dp dfree < <(df -Pk / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5, $4}')
  dfree="$(numfmt --to=iec $(( ${dfree:-0} * 1024 )) 2>/dev/null || echo "${dfree:-0}K")"
  upd="$(awk '{printf "%d", $1/86400}' /proc/uptime)"
  jq -nc --argjson dok "$dns_ok" --arg dms "$((t1 - t0))" --arg cpu "$cpu" --arg load "$load" --arg nc "$ncpu" \
    --arg mp "$mp" --arg mu "$((mt - ma))" --arg mt "$mt" --arg dp "${dp:-0}" --arg df "$dfree" --arg up "$upd" \
    '{dns_ok:$dok, dns_ms:($dms|tonumber), cpu_pct:($cpu|tonumber), load1:$load, ncpu:($nc|tonumber),
      mem_pct:($mp|tonumber), mem_used_mb:($mu|tonumber), mem_total_mb:($mt|tonumber),
      disk_pct:($dp|tonumber), disk_free:$df, uptime_days:($up|tonumber)}'
}
health_icon() { if (( $1 < 70 )); then printf '🟢'; elif (( $1 < 90 )); then printf '🟡'; else printf '🔴'; fi; }

hist_update() { # RESULTS_JSON TS → افزودن/جایگزینی رکورد امروز و نگه‌داشتن HISTORY_DAYS روز آخر
  local res=$1 ts=$2 d cut entry old
  d=${ts:0:10}
  cut="$(date -d "${d} -$(( HISTORY_DAYS - 1 )) days" +%F 2>/dev/null || echo 0000-00-00)"
  entry="$(jq -c --arg d "$d" --arg ts "$ts" '{
      date:$d, ts:$ts, total:length,
      ok:   ([.[] | select(.state == "ok")] | length),
      deg:  ([.[] | select(.state == "degraded")] | length),
      fail: ([.[] | select(.state == "fail")] | length),
      avg_lat:   ([.[] | select(.latency_avg_ms > 0) | .latency_avg_ms] | if length > 0 then (add / length | floor) else 0 end),
      avg_score: ([.[] | .score] | if length > 0 then (add / length | floor) else 0 end),
      scores: (map({(.cc): .score}) | add // {}),
      fails:  [.[] | select(.state == "fail") | .cc] }' <<<"$res")"
  old="$(cat "$DAILY_HISTORY" 2>/dev/null || true)"
  [[ -n "$old" ]] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$old" || old='[]'
  jq -c --argjson e "$entry" --arg cut "$cut" --argjson n "$HISTORY_DAYS" \
    '[.[] | select(.date != $e.date and .date >= $cut)] + [$e] | sort_by(.date) | .[-$n:]' <<<"$old" \
    > "${DAILY_HISTORY}.tmp" && mv -f "${DAILY_HISTORY}.tmp" "$DAILY_HISTORY"
}

arrow() { # cur prev [tol] → ▲ ▼ ▬
  local c=${1:-0} p=${2:-} tol=${3:-0}
  [[ "$p" =~ ^-?[0-9]+$ && "$c" =~ ^-?[0-9]+$ ]] || { printf '▬'; return; }
  if (( c - p > tol )); then printf '▲'; elif (( c - p < -tol )); then printf '▼'; else printf '▬'; fi
}
trend() { # cur prev [tol] → "▲ +2" | "▼ -15" | "▬"
  local c=${1:-0} p=${2:-} a
  a="$(arrow "$@")"
  if [[ "$a" == '▬' ]]; then printf '▬'; else printf '%s %+d' "$a" $(( c - p )); fi
}
mbps() { awk -v k="${1:-0}" 'BEGIN{ if (k > 0) printf "%.1fMb", k/1000; else printf "-" }'; }

record_samples() { # results JSON, append atomically and retain 7 days / ~20MB
  local res=$1 tmp cut
  mkdir -p "$DATA"; touch "$HEALTH_SAMPLES"
  jq -c --argjson t "$(date +%s)" '.[] | {ts:$t,cc,state,ok:(.state=="ok"),latency:(.latency_avg_ms//0),
    speed:(.speed_kbps//0),ip:(.ip//"-"),country:(.country//"-"),restarts:0}' <<<"$res" |
    { flock -w 10 9 || exit 0; cat >> "$HEALTH_SAMPLES"; cut="$(date -d '7 days ago' +%s)"; awk -v c="$cut" '{n=$0; sub(/.*"ts":/,"",n); sub(/,.*/,"",n); if ((n+0)>=c) print}' "$HEALTH_SAMPLES" > "${HEALTH_SAMPLES}.tmp" || true; tail -c 20000000 "${HEALTH_SAMPLES}.tmp" > "${HEALTH_SAMPLES}.cap" 2>/dev/null || true; mv -f "${HEALTH_SAMPLES}.cap" "$HEALTH_SAMPLES"; rm -f "${HEALTH_SAMPLES}.tmp"; } 9>"${HEALTH_SAMPLES}.lock"
}

# Part 5: risk scoring from the append-only sample history.
risk_rows() {
  [[ "$RISK_ENABLED" == true && -r "$HEALTH_SAMPLES" ]] || return 0
  local now_ts cutoff
  now_ts="$(date +%s)"
  cutoff=$((now_ts - 86400))
  jq -r --argjson c "$cutoff" \
    'select((.ts|tonumber) >= $c) |
     [.cc, (.ts|tonumber), (if .ok then 1 else 0 end),
      (.latency|tonumber? // 0), (.speed|tonumber? // 0), (.country // "-")] | @tsv' \
    "$HEALTH_SAMPLES" 2>/dev/null |
    awk -F '\t' -v sens="${RISK_SENSITIVITY:-50}" -v now="$now_ts" '
      function abs(x){return x<0?-x:x}
      function level(s){return s<30?"🟢":s<60?"🟡":s<80?"🟠":"🔴"}
      {
        cc=$1; ts[cc,++n[cc]]=$2; ok[cc,n[cc]]=$3
        lat[cc,n[cc]]=$4; speed[cc,n[cc]]=$5; country[cc,n[cc]]=$6
      }
      END {
        for (cc in n) {
          total=n[cc]; first=ts[cc,1]
          if (total < 2 || now-first < 7200) continue
          fails=0; bad=0; flips=0; consecutive=0; lastok=1
          base=0; base_n=0; recent=0; recent_lat=0; recent_lat_n=0
          for (i=1;i<=total;i++) {
            fails += (ok[cc,i] == 0)
            if (ok[cc,i] == 0) consecutive++; else consecutive=0
            if (i>1 && ok[cc,i] != ok[cc,i-1]) flips++
            if (lat[cc,i] > 0) { base += lat[cc,i]; base_n++ }
            if (i > total-8 && lat[cc,i] > 0) { recent_lat += lat[cc,i]; recent_lat_n++ }
            if (country[cc,i] != "-" && country[cc,i] != cc) bad++
          }
          trend=(base_n && recent_lat_n) ? (recent_lat/recent_lat_n)/(base/base_n)-1 : 0
          failrate=fails/total; drift=bad/total
          score=35*(trend>0?trend:0)+35*failrate+(consecutive>4?20:consecutive*5)
          score += (flips>7?10:flips*1.5)
          score += 15*(drift>0.1?drift:0)
          score=int(score*(0.5+sens/100)+0.5); if(score>100) score=100
          why=""
          if(trend>.2) why=why "latency↑,"
          if(failrate>.15) why=why "failures,"
          if(consecutive>=2) why=why "consecutive,"
          if(flips>=3) why=why "flapping,"
          if(drift>.1) why=why "IP/country drift,"
          sub(/,$/,"",why); if(why=="") why="stable"
          print cc "\t" score "\t" level(score) "\t" why "\t" ts[cc,total]
        }
      }' | sort -t$'\t' -k1,1
}
risk_summary() {
  local rows="$(risk_rows)" line cc score icon why best=""
  [[ -n "$rows" ]] || return 0
  while IFS=$'\t' read -r cc score icon why _; do
    [[ -n "$cc" ]] || continue
    [[ -z "$best" ]] && best="$cc"
    printf '%s %-2s %3s/100  %s\n' "$icon" "$cc" "$score" "$why"
  done < <(sort -t$'\t' -k2,2nr <<<"$rows" | head -3)
  [[ -n "$best" ]] && printf '💡 جایگزین پیشنهادی: <b>%s</b>\n' "$best"
}

risk_auto_restart() {
  [[ "$RISK_ENABLED" == true && "$RISK_AUTO_RESTART" == true ]] || return 0
  (( $(now) >= ${RISK_MUTE_UNTIL:-0} )) || return 0
  local t cc score icon why last
  t="$(now)"
  touch "$RISK_STATE"
  while IFS=$'\t' read -r cc score icon why last; do
    [[ "$cc" =~ ^[A-Z]{2}$ && "$score" =~ ^[0-9]+$ ]] || continue
    (( score >= RISK_THRESHOLD )) || continue
    last="$(awk -v c="$cc" '$1==c{print $2}' "$RISK_STATE" 2>/dev/null | tail -n1)"
    [[ "$last" =~ ^[0-9]+$ ]] && (( t - last < RISK_COOLDOWN_SEC )) && continue
    systemctl restart "psiphon-${cc}.service" >/dev/null 2>&1 || true
    awk -v c="$cc" '$1!=c' "$RISK_STATE" > "${RISK_STATE}.tmp" 2>/dev/null || true
    printf '%s %s\n' "$cc" "$t" >> "${RISK_STATE}.tmp"
    mv -f "${RISK_STATE}.tmp" "$RISK_STATE"
    log_bot "risk auto-restart: ${cc} score=${score}"
  done < <(risk_rows)
}

risk_level() { local n=${1:-0}; ((n<30)) && printf '🟢' || { ((n<60)) && printf '🟡' || { ((n<80)) && printf '🟠' || printf '🔴'; }; }; }
screen_risk() {
  local mid=$1 cc=${2:-} rows="$(risk_rows)" line rcc score icon why best=""
  if [[ -n "$cc" ]]; then
    while IFS=$'\t' read -r rcc score icon why _; do
      [[ "$rcc" == "${cc^^}" ]] && { edit "${HDR}🔮 <b>پیش‌بینی خرابی ${rcc}</b>
${icon} ریسک: <b>${score}%</b>
دلایل: <code>$(esc "$why")</code>
نمونه‌برداری: حداقل ۲ ساعت داده لازم است." "$(printf '♻️ ریستارت|restart:%s|danger;;🔁 تست|qt:%s|success;;🔇 سکوت ۱ساعت|riskmute:%s\n📈 جزئیات|risk:%s\n' "$rcc" "$rcc" "$rcc" "$rcc" | kb)" "$mid"; return; }
    done <<<"$rows"
  fi
  while IFS=$'\t' read -r rcc score icon why _; do
    [[ -n "$rcc" ]] || continue
    rows="${rows//$'\t'/ }"
  done < <(sort -t$'\t' -k2,2nr <<<"$rows" | head -12)
  local body="$(risk_summary "$DAILY_LAST" "$DAILY_HISTORY" 2>/dev/null || true)"
  edit "${HDR}🔮 <b>پیش‌بینی خرابی</b>
${body:-هنوز ۲ ساعت داده برای محاسبه ریسک نداریم.}" "$(printf '🔄 تازه‌سازی|risk\n🏠 منو|m\n' | kb)" "$mid"
}

daily_render() { # → متن گزارش از DAILY_LAST + تاریخچه
  [[ -r "$DAILY_LAST" ]] || return 1
  local res health ts d hist cur prev ok deg fail total lat sc pok plat psc dis age next risk
  local top="" fails="" i=0 cc s l sp ps st r line spark
  res="$(jq -c '.results // []' "$DAILY_LAST" 2>/dev/null)" || return 1
  health="$(jq -c '.health // {}' "$DAILY_LAST")"; ts="$(jq -r '.ts // ""' "$DAILY_LAST")"; d=${ts:0:10}
  hist="$(cat "$DAILY_HISTORY" 2>/dev/null || true)"; [[ -n "$hist" ]] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$hist" || hist='[]'
  cur="$(jq -c --arg d "$d" '[.[] | select(.date == $d)] | last // {}' <<<"$hist")"
  prev="$(jq -c --arg d "$d" '[.[] | select(.date < $d)] | last // {}' <<<"$hist")"
  read -r ok deg fail total lat sc < <(jq -r '[.ok // 0, .deg // 0, .fail // 0, .total // 0, .avg_lat // 0, .avg_score // 0] | @tsv' <<<"$cur")
  read -r pok plat psc < <(jq -r '[(.ok // "-"), (.avg_lat // "-"), (.avg_score // "-")] | map(tostring) | @tsv' <<<"$prev")
  dis="$(grep -cvE '^[[:space:]]*(#|$)' "$DISABLED_FILE" 2>/dev/null)"; dis=${dis:-0}

  while IFS=$'\t' read -r cc s l sp ps; do
    i=$((i + 1))
    top+="$(printf '%s. %s %-2s %3s  %6s %7s %s' "$i" "$(flag "$cc")" "$cc" "$s" "$( (( l > 0 )) && echo "${l}ms" || echo -)" "$(mbps "$sp")" "$(arrow "$s" "$ps" 2)")"$'\n'
  done < <(jq -r --argjson p "$(jq -c '.scores // {}' <<<"$prev")" --argjson n "$DAILY_TOP" \
            '[.[] | select(.state != "fail")] | sort_by(-.score) | .[0:$n][] |
             [.cc, (.score|tostring), (.latency_avg_ms|tostring), (.speed_kbps|tostring), (($p[.cc] // "-")|tostring)] | @tsv' <<<"$res")

  while IFS=$'\t' read -r st cc r; do
    fails+="$(state_icon "$st") $(flag "$cc") ${cc}  ${r:-?}"$'\n'
  done < <(jq -r '([.[] | select(.state == "fail")] + [.[] | select(.state == "degraded")]) | .[0:15][] | [.state, .cc, .reason] | @tsv' <<<"$res")

  local dok dms cpu load nc mp mu mt dp df up
  read -r dok dms cpu load nc mp mu mt dp df up < <(jq -r '[.dns_ok, .dns_ms, .cpu_pct, .load1, .ncpu, .mem_pct, .mem_used_mb, .mem_total_mb, .disk_pct, .disk_free, .uptime_days] | map(tostring) | @tsv' <<<"$health")
  spark="$(jq -r 'def ch: ["▁","▂","▃","▄","▅","▆","▇","█"][.];
                  map(if (.total // 0) > 0 then ((.ok * 7 / .total) | floor) else 0 end | ch) | join("")' <<<"$hist")"
  age=""; local tse; tse="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
  (( $(now) - tse > 86400 )) && age=$'\n''⚠️ <i>این گزارش قدیمی‌تر از ۲۴ ساعت است.</i>'
  next="$(systemctl show psiphon-bot-daily-test.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)"
  [[ -z "$next" || "$next" == n/a ]] && next="هر روز ${DAILY_TEST_HOUR}"
  risk="$(risk_summary "$DAILY_LAST" "$DAILY_HISTORY" 2>/dev/null || true)"

  printf '%s' "${HDR}📅 <b>گزارش ۲۴ ساعته</b> · <code>$(esc "${ts:0:16}" | tr 'T' ' ')</code>${age}
<pre>🟢 OK ${ok}  🟡 ${deg}  🔴 ${fail}  ⚪ ${dis}   (تست: ${total})
⏱ latency: ${lat}ms  ⭐ score: ${sc}/100</pre>
🏆 <b>Top ${DAILY_TOP}</b>
<pre>${top:-— لوکیشن سالمی نیست}</pre>
🔴 <b>خرابی‌ها</b>
<pre>$(esc "$(trunc "${fails:-✨ بدون خرابی}" 1200)")</pre>
🖥 <b>سلامت سرور</b>
<pre>DNS  : $([[ "$dok" == true ]] && echo "🟢 OK · ${dms}ms" || echo "🔴 FAIL · ${dms}ms")
CPU  : $(health_icon "$cpu") ${cpu}% · load ${load}/${nc}c
RAM  : $(health_icon "$mp") ${mp}% · ${mu}/${mt} MB
Disk : $(health_icon "$dp") ${dp}% · ${df} free
Up   : ${up} روز</pre>
📈 <b>روند</b> (نسبت به گزارش قبلی)
<pre>OK      : ${ok} $(trend "$ok" "$pok")
latency : ${lat}ms $(trend "$lat" "$plat" 5)
score   : ${sc} $(trend "$sc" "$psc" 1)
${HISTORY_DAYS}d OK   : ${spark:-▬}</pre>${risk:+
🟣 <b>ریسک</b>
${risk}}
<i>⏭ بعدی: $(esc "$next")</i>"
}

daily_kb() { printf '🔄 تست مجدد|dt:run|success;;📊 کامل|dt:full|primary\n♻️ ریستارت خرابها|dt:heal|danger\n🏠 منو|m\n' | kb; }
failed_from_daily() { jq -r '.results[]? | select(.state == "fail") | .cc' "$DAILY_LAST" 2>/dev/null || true; }

job_daily() { # mid
  local mid=$1 res ts health cc st
  PROG_MID=$mid; PROG_LABEL="📅 تست روزانه همه لوکیشن‌ها"
  res="$(run_all_tests)"; ts="$(date -Is)"
  record_samples "$res"
  jq -c --arg t "$ts" '{ts:$t, results:.}' <<<"$res" > "${LAST_TESTS}.tmp" && mv -f "${LAST_TESTS}.tmp" "$LAST_TESTS"
  health="$(server_health)"
  jq -nc --arg t "$ts" --argjson r "$res" --argjson h "$health" '{ts:$t, results:$r, health:$h}' \
    > "${DAILY_LAST}.tmp" && mv -f "${DAILY_LAST}.tmp" "$DAILY_LAST"
  hist_update "$res" "$ts"
  risk_auto_restart
  # auto-heal (فقط اگر AUTO_HEAL=true باشد کاری می‌کند)
  while read -r cc st; do [[ -n "$cc" ]] && heal_tick "$cc" "$st" daily; done \
    < <(jq -r '.[] | select(.state != "disabled") | "\(.cc) \(if .state == "fail" then "fail" else "ok" end)"' <<<"$res")
  job_finish daily "$mid" "$(daily_render)" "$(daily_kb)"
}

daily_main() { # از تایمر: یک پیام می‌سازد، پیشرفت را روی همان نشان می‌دهد و در آخر گزارش را جایش می‌نشاند
  local mid
  exec 9>"/run/lock/maxnet6g-$(job_lock_key daily).lock"
  if ! flock -w 900 9; then
    send "${HDR}⚠️ تست روزانه رد شد: یک تست دیگر بیش از ۱۵ دقیقه در حال اجرا بود." "$(nav m | kb)" >/dev/null || true
    return 0
  fi
  mid="$(send "${HDR}⏳ <b>📅 تست روزانه</b> شروع شد…" "$(printf '🏠 منو|m\n' | kb)" | jq -r '.result.message_id // empty' 2>/dev/null || true)"
  [[ -n "$mid" ]] && set_owner "$mid" job:daily
  job_daily "${mid:-}"
}

job_heal() { # mid → ریستارت لوکیشن‌های خراب آخرین گزارش + تست دوباره
  local mid=$1 list=() cc res i=0 fixed still
  mapfile -t list < <(failed_from_daily)
  if (( ! ${#list[@]} )); then job_finish heal "$mid" "${HDR}✨ در آخرین گزارش لوکیشن خرابی نبود." "$(daily_kb)"; return; fi
  PROG_MID=$mid
  for cc in "${list[@]}"; do
    i=$((i + 1)); PROG_LABEL="♻️ ریستارت ${cc}"; progress "$((i - 1))" "${#list[@]}"
    systemctl restart "psiphon-${cc}.service" >/dev/null 2>&1 || true
    sleep 3
  done
  sleep 8
  PROG_LABEL="🧪 تست دوباره‌ی ${#list[@]} لوکیشن"
  res="$(run_all_tests "${list[@]}")"
  # نتیجه‌ی جدید در گزارش روزانه هم ثبت می‌شود تا دکمه دوباره همان‌ها را ریستارت نکند
  jq -c --argjson n "$res" '.results |= map(. as $o | (($n | map(select(.cc == $o.cc)) | .[0]) // $o))' "$DAILY_LAST" \
    > "${DAILY_LAST}.tmp" 2>/dev/null && mv -f "${DAILY_LAST}.tmp" "$DAILY_LAST"
  fixed="$(jq '[.[] | select(.state != "fail")] | length' <<<"$res")"; still="$(jq '[.[] | select(.state == "fail")] | length' <<<"$res")"
  job_finish heal "$mid" "${HDR}♻️ <b>ریستارت خرابها</b>: ${#list[@]} لوکیشن
🟢 برگشت: ${fixed}  ·  🔴 هنوز خراب: ${still}
<pre>   CC SCR     LAT  SPEED CO REASON
$(trunc "$(fmt_table "$res")" 3000)</pre>" "$(daily_kb)"
}

# =============================================================================
# Part 2 · AUTO-HEAL (پیش‌فرض خاموش)
#   شمارش خطای پیاپی از watcher (هر ۲ دقیقه) و تست روزانه. بعد از AUTO_HEAL_FAILS خطا → restart
#   سقف: AUTO_HEAL_MAX_PER_HOUR (حداکثر ۳) ریستارت در ساعت برای هر لوکیشن
# =============================================================================
heal_tick() { # CC ok|fail [source]
  [[ "$AUTO_HEAL" == true ]] || return 0
  local cc=${1^^} res=${2:-fail} src=${3:-watch} cnt capn recent cap t fails
  valid_cc "$cc" || return 0
  is_disabled "$cc" && return 0
  fails=$AUTO_HEAL_FAILS; [[ "$fails" =~ ^[0-9]+$ ]] && (( fails >= 1 )) || fails=3
  cap=$AUTO_HEAL_MAX_PER_HOUR; [[ "$cap" =~ ^[0-9]+$ ]] || cap=3; (( cap > 3 )) && cap=3; (( cap < 1 )) && cap=1
  {
    flock -w 15 8 || return 0
    touch "$AUTOHEAL_STATE" "$AUTOHEAL_LOG"
    t="$(now)"
    read -r cnt capn < <(awk -v c="$cc" '$1==c{print $2, $3}' "$AUTOHEAL_STATE")
    cnt=${cnt:-0}; capn=${capn:-0}
    if [[ "$res" == ok ]]; then
      cnt=0
    else
      cnt=$((cnt + 1))
      if (( cnt >= fails )); then
        recent="$(awk -v c="$cc" -v s="$((t - 3600))" '$2==c && $1>=s' "$AUTOHEAL_LOG" | wc -l)"
        if (( recent < cap )); then
          systemctl restart "psiphon-${cc}.service" >/dev/null 2>&1 || true
          printf '%s %s\n' "$t" "$cc" >> "$AUTOHEAL_LOG"
          log_bot "auto-heal: restart ${cc} after ${cnt} failures (${src}) $((recent + 1))/${cap}"
          send "${HDR}♻️ <b>AUTO-HEAL</b>: $(flag "$cc") ${cc} بعد از ${cnt} خطای پیاپی ریستارت شد.
<i>منبع: ${src} · $((recent + 1))/${cap} در این ساعت</i>" \
            "$(printf '⚡ پینگ %s|ping:%s|success;;🏠 منو|m\n' "$cc" "$cc" | kb)" >/dev/null || true
          cnt=0
        elif (( t - capn >= 3600 )); then
          send "${HDR}⛔ <b>AUTO-HEAL</b>: سقف ${cap} ریستارت در ساعت برای $(flag "$cc") ${cc} پر شد. دستی بررسی کن." \
            "$(printf '🔵 لاگ‌ها|logs:%s|primary;;🏠 منو|m\n' "$cc" | kb)" >/dev/null || true
          capn=$t
        fi
      fi
    fi
    { awk -v c="$cc" '$1!=c' "$AUTOHEAL_STATE"; printf '%s %s %s\n' "$cc" "$cnt" "$capn"; } > "${AUTOHEAL_STATE}.tmp" \
      && mv -f "${AUTOHEAL_STATE}.tmp" "$AUTOHEAL_STATE"
    awk -v s="$((t - 7200))" '$1>=s' "$AUTOHEAL_LOG" > "${AUTOHEAL_LOG}.tmp" && mv -f "${AUTOHEAL_LOG}.tmp" "$AUTOHEAL_LOG"
  } 8>"/run/lock/maxnet6g-autoheal.lock"
}

# =============================================================================
# jobها: پس‌زمینه + flock؛ با systemd-run تا restart ربات (مثلاً در update) قطعشان نکند
# =============================================================================
job_lock_key() { case "$1" in update|turbo|doctor) echo sys ;; tests|ping|daily) echo tests ;; restart|heal) echo restart ;; *) echo "$1" ;; esac; }
job_busy() { ! flock -n "/run/lock/maxnet6g-$(job_lock_key "$1").lock" true 2>/dev/null; }
job_run() { # job_run NAME MSGID [ARGS...]
  local name=$1 mid=$2; shift 2
  job_busy "$name" && return 1
  set_owner "$mid" "job:${name}"
  if command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemd-run --quiet --collect --unit="mx6g-job-${name}-$(now)-${RANDOM}" \
      "$SELF" --job "$name" "$mid" "$@" >/dev/null 2>&1 && return 0
  fi
  setsid "$SELF" --job "$name" "$mid" "$@" </dev/null >/dev/null 2>&1 &
  return 0
}
job_finish() { # job_finish NAME MSGID TEXT KB
  local name=$1 mid=$2
  if [[ "$(get_owner "$mid")" == "job:${name}" ]]; then edit "$3" "$4" "$mid"; else send "$3" "$4" >/dev/null; fi
  rm -f -- "${RUN}/owner.${mid}"
}
job_main() { # در process جدا اجرا می‌شود
  local name=$1 mid=$2; shift 2
  exec 9>"/run/lock/maxnet6g-$(job_lock_key "$name").lock"
  flock -n 9 || { job_finish "$name" "$mid" "${HDR}⏳ یک کار مشابه در حال اجراست." "$(nav m | kb)"; exit 0; }
  case "$name" in
    tests)   job_tests "$mid" "$@" ;;
    ping)    job_ping "$mid" "$@" ;;
    daily)   job_daily "$mid" ;;
    heal)    job_heal "$mid" ;;
    restart) job_restart "$mid" "$@" ;;
    update)  job_installer "$mid" update --update "🟠 آپدیت" "" ;;
    turbo)   job_installer "$mid" turbo --turbo "🟣 Turbo" "${DATA}/turbo-last.json" ;;
    doctor)  job_installer "$mid" doctor --net-doctor "🟣 Network doctor" "${DATA}/netdoctor-last.json" ;;
    ips)     job_ips "$mid" ;;
  esac
}

job_ping() { # mid target
  local mid=$1 target=${2:-all} res
  PROG_MID=$mid; PROG_LABEL="⚡ Ping radar · ${target}"
  if [[ "$target" == all ]]; then res="$(run_pings)"; else res="$(run_pings "$target")"; fi
  jq -c --arg t "$(date -Is)" --arg g "$target" '{ts:$t, target:$g, results:.}' <<<"$res" > "${LAST_PING}.tmp" \
    && mv -f "${LAST_PING}.tmp" "$LAST_PING"
  job_finish ping "$mid" "$(ping_screen_text all)" "$(ping_kb all "$target")"
}

job_tests() {
  local mid=$1 target=${2:-all} res txt ok fail deg skipped
  PROG_MID=$mid; PROG_LABEL="🧪 تست کیفیت · ${target}"
  if [[ "$target" == all ]]; then
    res="$(run_all_tests)"
    jq -c --arg t "$(date -Is)" '{ts:$t, results:.}' <<<"$res" > "${LAST_TESTS}.tmp" && mv -f "${LAST_TESTS}.tmp" "$LAST_TESTS"
    ok="$(jq '[.[]|select(.state=="ok")]|length' <<<"$res")"
    deg="$(jq '[.[]|select(.state=="degraded")]|length' <<<"$res")"
    fail="$(jq '[.[]|select(.state=="fail")]|length' <<<"$res")"
    skipped="$(grep -cvE '^[[:space:]]*(#|$)' "$DISABLED_FILE" 2>/dev/null)"; skipped=${skipped:-0}
    txt="${HDR}🧪 <b>تست کیفیت همه لوکیشن‌ها</b>
🟢 ${ok}  🟡 ${deg}  🔴 ${fail}  ⚪ رد‌شده: ${skipped}

<pre>   CC SCR     LAT  SPEED CO REASON
$(trunc "$(fmt_table "$res")" 3300)</pre>
<i>$(date '+%F %T')</i>"
    job_finish tests "$mid" "$txt" "$( { printf '🔁 تست مجدد|qt:all|success;;⚡ رادار پینگ|ping:all|primary\n'; nav pm; } | kb)"
  else
    res="$(test_location "$target")"
    txt="${HDR}$(fmt_single "$res")
<i>$(date '+%F %T')</i>"
    job_finish tests "$mid" "$txt" "$( { printf '🔁 تست مجدد|qt:%s|success;;🔴 ریستارت این لوکیشن|restart:%s|danger\n' "$target" "$target"; nav "pick:ping:0"; } | kb)"
  fi
}

job_restart() {
  local mid=$1 target=$2 out res txt
  out="$("$CTL" restart "$target" 2>&1 | tail -n 40)" || true
  if [[ "$target" != all ]]; then
    sleep 8
    res="$(test_location "$target")"
    txt="${HDR}🔴 <b>ریستارت ${target} انجام شد</b>

$(fmt_single "$res")"
  else
    txt="${HDR}🔴 <b>ریستارت همه انجام شد</b>
<pre>$(esc "$(trunc "$out" 3000)")</pre>"
  fi
  job_finish restart "$mid" "$txt" "$( { printf '🟢 تست|ping:%s|success\n' "$target"; nav rs; } | kb)"
}

job_installer() { # mid name flag title jsonfile
  local mid=$1 name=$2 flagopt=$3 title=$4 jf=$5 logf rc=0 x="" tail_out
  if [[ ! -x "$INSTALLER" ]]; then
    job_finish "$name" "$mid" "${HDR}⚠️ ${title}: فایل ${INSTALLER} پیدا نشد. یک‌بار نصب را دستی اجرا کنید." "$(nav m | kb)"; return
  fi
  logf="${DATA}/bot-${name}.log"
  "$INSTALLER" "$flagopt" > "$logf" 2>&1 < /dev/null || rc=$?
  tail_out="$(sed -E 's/\x1b\[[0-9;]*m//g' "$logf" | tail -n 15)"
  [[ -n "$jf" && -r "$jf" ]] && x="$(jq -r 'to_entries[] | "\(.key): \(.value)"' "$jf" 2>/dev/null | head -n 20 || true)"
  job_finish "$name" "$mid" "${HDR}${title}: $([[ $rc == 0 ]] && echo '✅ موفق' || echo "⚠️ ناموفق (exit ${rc})")
${x:+<pre>$(esc "$x")</pre>
}<pre>$(esc "$(trunc "$tail_out" 2000)")</pre>" "$(nav m | kb)"
}

job_ips() {
  local mid=$1 out rows
  out="$("$IPREFRESH" report 2>/dev/null || echo '[]')"
  rows="$(jq -r '.[] | "\(.latency)s  \(.endpoint)"' <<<"$out" 2>/dev/null || echo "$out")"
  job_finish ips "$mid" "${HDR}🔵 <b>رتبه‌بندی endpointها</b> (TCP connect)
<pre>$(esc "${rows:-نتیجه‌ای نیست}")</pre>" "$( { printf '🔄 تازه‌سازی|ip|primary\n'; nav m; } | kb)"
}

# =============================================================================
# صفحه‌ها
# =============================================================================
svc_counts() { # → "active total disabled"
  local all=() a t=0 d=0 c units=()
  mapfile -t all < <(all_locations)
  for c in "${all[@]}"; do is_disabled "$c" && d=$((d+1)) || units+=("psiphon-${c}.service"); done
  t=${#units[@]}
  a=0; (( t )) && a="$(systemctl is-active "${units[@]}" 2>/dev/null | grep -cx active || true)"
  printf '%s %s %s' "${a:-0}" "$t" "$d"
}

MAX_INSTANCES=100
PORT_BASES="/etc/psiphon/port-bases.conf"
port_rows() { awk '$1 !~ /^#/ && NF>=3 {printf "%s  SOCKS:%s  HTTP:%s\n",$1,$2,$3}' "$MAP" 2>/dev/null; }
port_used_by_other() {
  local p=$1 line
  line="$(ss -H -tlnp "sport = :${p}" 2>/dev/null || true)"
  [[ -n "$line" ]] && ! grep -q psiphon <<<"$line"
}
port_plan_valid() {
  local cc s h p
  declare -A seen=()
  for p in "$@"; do
    [[ "$p" =~ ^[0-9]+$ && p -ge 1024 && p -le 65535 ]] || return 1
    [[ -z "${seen[$p]:-}" ]] || return 1
    seen[$p]=1
  done
  while read -r cc s h; do
    [[ "$cc" == \#* || -z "$cc" ]] && continue
    [[ "$s" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || return 1
  done < "$MAP"
  return 0
}
cfg_set() {
  local k=$1 v=$2 tmp
  [[ "$k" =~ ^[A-Z_]+$ ]] || return 1
  [[ "$v" =~ ^[A-Za-z0-9_.:/?=\&%+,-]*$ ]] || return 1
  tmp="${SETTINGS}.tmp"
  awk -F= -v k="$k" -v v="$v" 'BEGIN{done=0} $1==k{print k "=" v; done=1; next} {print} END{if(!done)print k "=" v}' "$SETTINGS" > "$tmp"
  install -m 0600 -o root -g root "$tmp" "$SETTINGS"; rm -f "$tmp"
}
settings_value() { awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$SETTINGS" 2>/dev/null | tail -n1; }
screen_settings() {
  local s="$(settings_value WATCHER_INTERVAL_MIN)" d="$(settings_value DAILY_TEST_ENABLED)" a="$(settings_value AUTO_HEAL)"
  edit "${HDR}⚙️ <b>تنظیمات</b>
پورت‌ها و کنترل‌های Part 4 آماده‌اند.
زمان‌بندی: <b>$(settings_value DAILY_TEST_HOUR)</b>، watcher هر <b>${s:-2} دقیقه</b>، IP هر <b>$(settings_value IP_REFRESH_HOURS) ساعت</b>
تست روزانه: <b>${d:-true}</b> · هشدارها: <b>$(settings_value ALERT_LOCATION_DOWN)</b> · ریستارت خودکار: <b>${a:-false}</b>" "$(printf '🔌 پورت‌ها|ports|primary\n🗺 لوکیشن‌ها|locs|primary;;⏰ زمان‌بندی|sched|primary\n🔔 هشدارها|alerts|primary;;🔁 ریستارت خودکار|autorst|primary\n🎨 ظاهر|appear|primary;;💾 بکاپ|backup|primary\n🔐 امنیت|security|primary\n'; nav m | kb)" "$1"
}
settings_toggle() {
  local k=$1 cur="$(settings_value "$1")" next=true
  [[ "$cur" == true ]] && next=false
  cfg_set "$k" "$next"
}
screen_locs() {
  local rows="" c mark
  while read -r c; do mark="✅"; is_disabled "$c" && mark="⛔"; rows+="${mark} ${c}|loc:${c}"$'\n'; done < <(all_locations)
  edit "${HDR}🗺 <b>لوکیشن‌ها</b>
✅ فعال، ⛔ غیرفعال. با غیرفعال‌سازی سرویس متوقف می‌شود و watcher/test آن را رد می‌کنند." "$( { printf '%s' "$rows"; nav settings; } | kb)" "$1"
}
set_location() {
  local cc=${1^^} tmp
  valid_cc "$cc" || return 0
  if is_disabled "$cc"; then
    grep -viE "^[[:space:]]*${cc}([[:space:]]|#|$)" "$DISABLED_FILE" > "${DISABLED_FILE}.tmp" || true
    install -m 0644 "${DISABLED_FILE}.tmp" "$DISABLED_FILE"; rm -f "${DISABLED_FILE}.tmp"
    systemctl enable --now "psiphon-${cc}.service" >/dev/null 2>&1 || true
  else
    printf '%s\n' "$cc" >> "$DISABLED_FILE"
    systemctl disable --now "psiphon-${cc}.service" >/dev/null 2>&1 || true
  fi
}
screen_sched() { edit "${HDR}⏰ <b>زمان‌بندی</b>
تست روزانه: $(settings_value DAILY_TEST_ENABLED) · ساعت $(settings_value DAILY_TEST_HOUR)
watcher: هر $(settings_value WATCHER_INTERVAL_MIN) دقیقه · IP refresh: هر $(settings_value IP_REFRESH_HOURS) ساعت" "$(printf '🔄 تست روزانه on/off|tog:DAILY_TEST_ENABLED;;⏱ ساعت تست|hour\n⏲ watcher 1/2/5/10|wint;;🌐 IP refresh 3/6/12/24|ipint\n'; nav settings | kb)" "$1"; }
screen_alerts() { edit "${HDR}🔔 <b>هشدارها</b>
down لوکیشن: $(settings_value ALERT_LOCATION_DOWN) · down سرور: $(settings_value ALERT_SERVER_DOWN)
latency: $(settings_value ALERT_LATENCY) بالای $(settings_value LATENCY_ALERT_MS)ms
cooldown: $(settings_value ALERT_COOLDOWN_SEC)s · quiet: $(settings_value QUIET_HOURS_ENABLED) · summary-only: $(settings_value SUMMARY_ONLY)" "$(printf '🌍 location down|tog:ALERT_LOCATION_DOWN;;🖥 server down|tog:ALERT_SERVER_DOWN\n⚡ latency|tog:ALERT_LATENCY;;🔕 quiet hours|tog:QUIET_HOURS_ENABLED\n📊 summary-only|tog:SUMMARY_ONLY;;🎚 threshold|threshold\n'; nav settings | kb)" "$1"; }
screen_autorst() { edit "${HDR}🔁 <b>ریستارت خودکار</b>
فعال: $(settings_value AUTO_HEAL) · بعد از $(settings_value AUTO_HEAL_FAILS) خطا · سقف سخت ۳ بار در ساعت" "$(printf 'on/off|tog:AUTO_HEAL;;🔢 failures|fails\n'; nav settings | kb)" "$1"; }
screen_appear() { edit "${HDR}🎨 <b>ظاهر</b>
زبان: $(settings_value UI_LANG) · حالت: $(settings_value UI_COMPACT) · emoji: $(settings_value EMOJI_ENABLED)" "$(printf '🇮🇷/🇬🇧 زبان|lang;;📐 compact/detailed|tog:UI_COMPACT;;😀 emoji on/off|tog:EMOJI_ENABLED\n'; nav settings | kb)" "$1"; }
screen_security() { edit "${HDR}🔐 <b>امنیت</b>
Admin اصلی: <code>${ADMIN_CHAT_ID}</code>
Extra admins: <code>$(settings_value EXTRA_ADMIN_IDS)</code>
restore فقط از فایل tar.gz معتبر و بدون token انجام می‌شود." "$(printf '➕ افزودن admin|adminadd;;➖ حذف admin|adminrm\n'; nav settings | kb)" "$1"; }
admin_allowed() {
  [[ "$1" == "$ADMIN_CHAT_ID" ]] && return 0
  tr ',' '\n' <<<"$(settings_value EXTRA_ADMIN_IDS)" | grep -Fxq -- "$1"
}
backup_send() {
  local dir="/tmp/maxnet6g-backup-$(date +%Y%m%d-%H%M%S)" tar
  mkdir -p "$dir"; cp -f "$MAP" "$SETTINGS" "$dir/"
  tar="$(mktemp "${RUN}/backup.XXXXXX.tar.gz")"; tar -czf "$tar" -C "$dir" mapping.txt bot-settings.conf
  curl -fsS --max-time 30 -F "chat_id=${ADMIN_CHAT_ID}" -F "document=@${tar}" \
    "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" >/dev/null || true
  rm -rf "$dir" "$tar"
}
restore_file() {
  local src=$1 tmp d
  [[ -r "$src" ]] || { send "${HDR}⚠️ فایل پیدا نشد." "$(nav security | kb)" >/dev/null; return; }
  d="$(mktemp -d)"; tar -xzf "$src" -C "$d" 2>/dev/null || { rm -rf "$d"; send "${HDR}⚠️ فرمت بکاپ نامعتبر است." "$(nav security | kb)" >/dev/null; return; }
  [[ -s "$d/mapping.txt" && -s "$d/bot-settings.conf" ]] || { rm -rf "$d"; send "${HDR}⚠️ بکاپ باید mapping.txt و bot-settings.conf داشته باشد." "$(nav security | kb)" >/dev/null; return; }
  awk '$1 !~ /^#/ && NF>=3 && $1 !~ /[^A-Za-z]/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/' "$d/mapping.txt" | grep -q . || { rm -rf "$d"; send "${HDR}⚠️ mapping نامعتبر است." "$(nav security | kb)" >/dev/null; return; }
  backup_path "$MAP"; backup_path "$SETTINGS"; install -m 0644 "$d/mapping.txt" "$MAP"; install -m 0600 "$d/bot-settings.conf" "$SETTINGS"
  rm -rf "$d"; systemctl try-restart psiphon-bot.service >/dev/null 2>&1 || true
  send "${HDR}✅ بکاپ restore شد. token هرگز داخل بکاپ نیست." "$(nav settings | kb)" >/dev/null
}
screen_ports() {
  local rows="" cc s h
  while read -r cc s h; do
    [[ "$cc" == \#* || -z "$cc" ]] && continue
    rows+="$(flag "$cc") <code>${cc}</code>  SOCKS <b>${s}</b>  HTTP <b>${h}</b>"$'\n'
    rows+="🔧 تغییر ${cc} SOCKS|pc:${cc}:socks;;🔧 تغییر HTTP|pc:${cc}:http"$'\n'
  done < "$MAP"
  edit "${HDR}🔌 <b>پورت‌ها</b>
${rows}
پورت معتبر: 1024 تا 65535، بدون تکرار، آزاد و فقط روی 127.0.0.1." "$(printf '🧱 تغییر base ports|bases|primary\n'; nav settings | kb)" "$1"
}
port_change_prompt() {
  set_pending "port:$2:$3" "$1"
  edit "${HDR}⌨️ پورت جدید برای <b>${2^^} ${3^^}</b> را بفرست.
1024 تا 65535، بدون تکرار و بدون اشغال بودن. برای لغو: /cancel" "$(nav ports | kb)" "$1"
}
base_ports_prompt() {
  set_pending bases "$1"
  edit "${HDR}⌨️ دو base port را با فاصله بفرست، مثلاً:
<code>10800 10900</code>
تغییر فقط روی تخصیص‌های بعدی اثر می‌گذارد؛ mapping فعلی دست‌نخورده می‌ماند." "$(nav ports | kb)" "$1"
}
validate_base_ports() {
  local s=$1 h=$2 gap
  [[ "$s" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || return 1
  (( s >= 1024 && h >= 1024 && s <= 65535 && h <= 65535 )) || return 1
  gap=$(( s > h ? s-h : h-s ))
  (( gap >= MAX_INSTANCES )) || return 1
  (( (s > h ? s : h) + MAX_INSTANCES - 1 <= 65535 )) || return 1
  return 0
}
apply_base_ports() {
  local s=$1 h=$2 stamp dir
  validate_base_ports "$s" "$h" || { send "${HDR}⚠️ base ports نامعتبر است." "$(nav bases | kb)" >/dev/null; return; }
  stamp="$(date +%Y%m%d-%H%M%S)"; dir="/etc/psiphon/backups/$stamp"; mkdir -p "$dir"
  [[ -f "$PORT_BASES" ]] && cp -a "$PORT_BASES" "$dir/" || true
  printf 'SOCKS_PORT_BASE=%s\nHTTP_PORT_BASE=%s\n' "$s" "$h" > "${PORT_BASES}.tmp"
  install -m 0644 "${PORT_BASES}.tmp" "$PORT_BASES"; rm -f "${PORT_BASES}.tmp"
  send "${HDR}✅ base ports ذخیره شد: SOCKS=${s}, HTTP=${h}
mapping فعلی تغییر نکرد؛ تخصیص‌های بعدی از این پایه‌ها استفاده می‌کنند." "$(nav ports | kb)" >/dev/null
}
apply_port_change() {
  local cc=${1^^} kind=$2 new=$3 old_s old_h tmp stamp dir unit cfg mapjson
  [[ "$new" =~ ^[0-9]+$ && new -ge 1024 && new -le 65535 ]] || { send "${HDR}⚠️ پورت باید بین 1024 و 65535 باشد." "$(nav ports | kb)" >/dev/null; return; }
  old_s="$(awk -v c="$cc" '$1==c{print $2}' "$MAP")"; old_h="$(awk -v c="$cc" '$1==c{print $3}' "$MAP")"
  [[ -n "$old_s" && -n "$old_h" ]] || { send "${HDR}⚠️ لوکیشن پیدا نشد." "$(nav ports | kb)" >/dev/null; return; }
  if awk -v p="$new" -v c="$cc" '$1!="#" && $1!=c && ($2==p || $3==p){found=1} END{exit !found}' "$MAP"; then
    send "${HDR}⚠️ این پورت تکراری است." "$(nav ports | kb)" >/dev/null; return
  fi
  port_used_by_other "$new" && { send "${HDR}⚠️ پورت ${new} در حال استفاده است." "$(nav ports | kb)" >/dev/null; return; }
  stamp="$(date +%Y%m%d-%H%M%S)"; dir="/etc/psiphon/backups/$stamp"; mkdir -p "$dir"
  cp -a "$MAP" "$dir/mapping.txt"; [[ -f /etc/psiphon/mapping.json ]] && cp -a /etc/psiphon/mapping.json "$dir/mapping.json"
  cfg="/etc/psiphon/${cc}.json"; unit="/etc/systemd/system/psiphon-${cc}.service"
  [[ -f "$cfg" ]] && cp -a "$cfg" "$dir/" || true; [[ -f "$unit" ]] && cp -a "$unit" "$dir/" || true
  tmp="${MAP}.tmp"
  awk -v c="$cc" -v k="$kind" -v p="$new" 'BEGIN{OFS=" "} $1!="#" && $1==c {if(k=="socks") $2=p; else $3=p} {print}' "$MAP" > "$tmp"
  install -m 0644 "$tmp" "$MAP"; rm -f "$tmp"
  jq --arg c "$cc" --arg k "$kind" --argjson p "$new" '.[$c][$k] = $p' /etc/psiphon/mapping.json > /etc/psiphon/mapping.json.tmp
  install -m 0644 /etc/psiphon/mapping.json.tmp /etc/psiphon/mapping.json; rm -f /etc/psiphon/mapping.json.tmp
  jq --argjson p "$new" --arg k "$kind" '.LocalSocksProxyPort = (if $k=="socks" then $p else .LocalSocksProxyPort end) | .LocalHttpProxyPort = (if $k=="http" then $p else .LocalHttpProxyPort end)' "$cfg" > "${cfg}.tmp"
  install -m 0640 -o root -g psiphon "${cfg}.tmp" "$cfg"; rm -f "${cfg}.tmp"
  if [[ -f "$unit" ]]; then sed -E "s#^Description=.*#Description=MAXNET6G Psiphon tunnel (${cc}) SOCKS 127.0.0.1:$(awk -v c="$cc" '$1==c{print $2}' "$MAP") HTTP 127.0.0.1:$(awk -v c="$cc" '$1==c{print $3}' "$MAP")#" "$unit" > "${unit}.tmp"; install -m 0644 "${unit}.tmp" "$unit"; rm -f "${unit}.tmp"; fi
  systemctl daemon-reload; systemctl restart "psiphon-${cc}.service"
  sleep 2
  local s h listens
  s="$(awk -v c="$cc" '$1==c{print $2}' "$MAP")"; h="$(awk -v c="$cc" '$1==c{print $3}' "$MAP")"
  listens="$(ss -H -ltn 2>/dev/null || true)"
  if ! systemctl is-active --quiet "psiphon-${cc}.service" || ! grep -q "127.0.0.1:${s}" <<<"$listens" || ! grep -q "127.0.0.1:${h}" <<<"$listens" || ! curl -fsS --max-time 15 --socks5-hostname "127.0.0.1:${s}" https://ipinfo.io/json >/dev/null; then
    cp -a "$dir/mapping.txt" "$MAP"; [[ -f "$dir/mapping.json" ]] && cp -a "$dir/mapping.json" /etc/psiphon/mapping.json
    [[ -f "$dir/${cc}.json" ]] && cp -a "$dir/${cc}.json" "$cfg"; [[ -f "$dir/psiphon-${cc}.service" ]] && cp -a "$dir/psiphon-${cc}.service" "$unit"
    systemctl daemon-reload; systemctl restart "psiphon-${cc}.service" || true
    send "${HDR}🔴 تغییر پورت ${cc} شکست خورد؛ <b>rollback خودکار</b> انجام شد." "$(nav ports | kb)" >/dev/null
    return
  fi
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw deny proto tcp from any to any port "$new" comment 'psiphon-custom-local-only' >/dev/null 2>&1 || true
  fi
  send "${HDR}✅ پورت ${cc} تغییر کرد: ${kind^^}=${new}
backup: ${stamp}
تأیید شد: service active، tunnel سالم، listen فقط روی 127.0.0.1." "$(nav ports | kb)" >/dev/null
}

screen_menu() { # [MSGID]
  local a t d txt k
  read -r a t d < <(svc_counts)
  txt="${HDR}🖥 <b>$(esc "$(hostname)")</b>
سرویس‌ها: <b>${a}/${t}</b> فعال$( (( d )) && printf '  ·  ⚪ %s غیرفعال' "$d")

یک گزینه انتخاب کن:"
  k="$(kb <<'EOF'
🔵 وضعیت|st|primary;;🟢 پینگ|pg|success
🟣 Turbo|tb;;🟣 Doctor|dr
🟠 آپدیت|up;;🔴 ریستارت|rs|danger
🟡 تنظیمات|settings|primary;;🔵 IPها|ip|primary
🔵 لاگ‌ها|lg|primary;;🔵 گزارش ۲۴ساعته|rt|primary
🟣 پیش‌بینی خرابی|risk|primary;;⚫ بستن|x
EOF
)"
  if [[ -n "${1:-}" ]]; then edit "$txt" "$k" "$1"; else send "$txt" "$k" >/dev/null; fi
}

screen_status() {
  local mid=$1 c a rows="" last=""
  for c in $(all_locations); do
    if is_disabled "$c"; then rows+="⚪ ${c}  disabled"$'\n'; continue; fi
    a="$(systemctl is-active "psiphon-${c}.service" 2>/dev/null || true)"
    [[ "$a" == active ]] && rows+="🟢 ${c}  :$(socks_port "$c")"$'\n' || rows+="🔴 ${c}  ${a}"$'\n'
  done
  [[ -r "$LAST_TESTS" ]] && last="$(jq -r '"آخرین تست: \(.ts[0:16]|sub("T";" "))\nبهترین‌ها: " + ([.results[]|select(.state=="ok")][0:3]|map("\(.cc)(\(.score))")|join(" ")) ' "$LAST_TESTS" 2>/dev/null || true)"
  edit "${HDR}🔵 <b>وضعیت سرویس‌ها</b>
<pre>$(esc "$(trunc "$rows" 3000)")</pre>${last:+
$(esc "$last")}" "$( { printf '🔄 تازه‌سازی|st|primary;;🟢 پینگ همه|ping:all|success\n'; nav m; } | kb)" "$mid"
}

screen_ping_menu() {
  edit "${HDR}🟢 <b>پینگ و تست کیفیت</b>
⚡ رادار: latency واقعی از داخل تونل، مرتب بهترین→بدترین.
🧪 تست کیفیت: IP، کشور، latency، سرعت (~1MB) و امتیاز ۰ تا ۱۰۰." "$( { printf '⚡ رادار همه|ping:all|success;;🗺 انتخاب کشور|pick:ping:0|primary\n🧪 تست کیفیت همه|qt:all;;⌨️ تایپ کد کشور|in:ping\n'; nav m; } | kb)" "$1"
}
screen_ping_view() { # mid view → از کش، بدون تست دوباره
  local mid=$1 view=$2 target
  [[ -r "$LAST_PING" ]] || { do_action "$mid" ping all; return; }
  target="$(jq -r '.target // "all"' "$LAST_PING" 2>/dev/null || echo all)"
  edit "$(ping_screen_text "$view")" "$(ping_kb "$view" "$target")" "$mid"
}
screen_report() { # mid → «گزارش ۲۴ساعته»
  local txt
  if txt="$(daily_render)" && [[ -n "$txt" ]]; then edit "$txt" "$(daily_kb)" "$1"; return; fi
  edit "${HDR}📅 <b>گزارش ۲۴ ساعته</b>
هنوز گزارشی ثبت نشده. تست روزانه هر روز ساعت <b>$(esc "$DAILY_TEST_HOUR")</b> خودکار اجرا می‌شود." \
    "$( { printf '▶️ همین الان اجرا کن|dt:run|success\n'; nav m; } | kb)" "$1"
}
screen_daily_full() { # mid
  local mid=$1 res ts
  [[ -r "$DAILY_LAST" ]] || { screen_report "$mid"; return; }
  res="$(jq -c '.results // []' "$DAILY_LAST")"; ts="$(jq -r '.ts // ""' "$DAILY_LAST")"
  edit "${HDR}📊 <b>نتیجه کامل تست روزانه</b> · <code>$(esc "${ts:0:16}" | tr 'T' ' ')</code>
<pre>   CC SCR     LAT  SPEED CO REASON
$(trunc "$(fmt_table "$res")" 3300)</pre>" "$( { printf '🔄 تست مجدد|dt:run|success;;♻️ ریستارت خرابها|dt:heal|danger\n'; nav rt; } | kb)" "$mid"
}
screen_restart_menu() {
  edit "${HDR}🔴 <b>ریستارت</b>
ریستارت‌ها پله‌ای (staggered) انجام می‌شوند." "$( { printf '🌍 ریستارت همه|restart:all|danger;;🗺 انتخاب کشور|pick:restart:0|primary\n⌨️ تایپ کد کشور|in:restart\n'; nav m; } | kb)" "$1"
}

# picker: ۳ ستون، ۱۲ تا در هر صفحه
screen_pick() { # mid action page
  local mid=$1 act=$2 page=${3:-0} list=() n pages i c row="" rows="" back title
  if [[ "$act" == ping ]]; then mapfile -t list < <(enabled_locations); else mapfile -t list < <(all_locations); fi
  n=${#list[@]}; pages=$(( (n + PAGE_SIZE - 1) / PAGE_SIZE )); (( pages < 1 )) && pages=1
  (( page < 0 )) && page=0; (( page >= pages )) && page=$((pages - 1))
  for ((i = page * PAGE_SIZE; i < n && i < (page + 1) * PAGE_SIZE; i++)); do
    c=${list[i]}
    row+="${row:+;;}$(flag "$c") ${c}$(is_disabled "$c" && printf ' ⚪')|${act}:${c}"
    if (( (i - page * PAGE_SIZE + 1) % PAGE_COLS == 0 )); then rows+="${row}"$'\n'; row=""; fi
  done
  [[ -n "$row" ]] && rows+="${row}"$'\n'
  if (( pages > 1 )); then
    rows+="$( (( page > 0 )) && printf '◀️ قبلی|pick:%s:%s;;' "$act" $((page - 1)))📄 $((page + 1))/${pages}|nop$( (( page + 1 < pages )) && printf ';;بعدی ▶️|pick:%s:%s' "$act" $((page + 1)))"$'\n'
  fi
  case "$act" in ping) back=pm; title="⚡ پینگ: کشور را انتخاب کن";; restart) back=rs; title="🔴 ریستارت: کشور را انتخاب کن";; *) back=m; title="🔵 لاگ‌ها: کشور را انتخاب کن";; esac
  rows+="⌨️ تایپ کد|in:${act}"$'\n'
  edit "${HDR}<b>${title}</b>" "$( { printf '%s' "$rows"; nav "$back"; } | kb)" "$mid"
}

screen_confirm() { # mid action arg text back
  edit "${HDR}⚠️ <b>تأیید لازم است</b>

$4

مطمئنی؟ (اعتبار: ${CONFIRM_TTL} ثانیه)" "$( { printf '✅ بله، انجام بده|y:%s:%s:%s|danger;;❌ لغو|%s\n' "$2" "$3" "$(now)" "$5"; nav "$5"; } | kb)" "$1"
}

screen_logs() { # mid CC
  local mid=$1 cc=${2^^} out
  out="$(journalctl -u "psiphon-${cc}.service" -n 30 --no-pager -o short-iso 2>&1 | cut -c1-200)"
  edit "${HDR}🔵 <b>لاگ $(flag "$cc") ${cc}</b>
<pre>$(esc "$(trunc "$out" 3300)")</pre>" "$( { printf '🔄 تازه‌سازی|logs:%s|primary;;🗺 کشور دیگر|pick:logs:0\n' "$cc"; nav "pick:logs:0"; } | kb)" "$mid"
}

screen_busy_or_start() { # mid name label [args]
  local mid=$1 name=$2 label=$3; shift 3
  if job_busy "$name"; then
    edit "${HDR}⏳ یک کار مشابه هنوز در حال اجراست. کمی بعد دوباره امتحان کن." "$(nav m | kb)" "$mid"; return
  fi
  # اول صفحه انتظار، بعد job (تا نتیجه‌ی سریع با ⏳ بازنویسی نشود)
  edit "${HDR}⏳ <b>${label}</b> در حال اجرا…
<code>$(prog_bar 0 1)</code>  0%
<i>نتیجه همین‌جا نمایش داده می‌شود.</i>" "$(printf '🏠 منو|m\n' | kb)" "$mid"
  job_run "$name" "$mid" "$@" || edit "${HDR}⚠️ اجرای job ممکن نشد." "$(nav m | kb)" "$mid"
}

screen_input_prompt() { # mid act
  set_pending "$2" "$1"
  edit "${HDR}⌨️ کد دوحرفی کشور را بفرست (مثلاً <code>NL</code>).
برای لغو: /cancel" "$(nav "$( [[ $2 == ping ]] && echo pm || { [[ $2 == restart ]] && echo rs || echo m; } )" | kb)" "$1"
}

# =============================================================================
# routing
# =============================================================================
do_action() { # mid action arg  (بعد از تأیید یا مستقیم)
  local mid=$1 act=$2 arg=${3:-}
  if [[ "${arg,,}" == all ]]; then arg=all; else arg=${arg^^}; fi
  case "$act" in
    ping|qt) [[ "$arg" == all ]] || valid_cc "$arg" || { edit "${HDR}⚠️ کشور نامعتبر: $(esc "$arg")" "$(nav pm | kb)" "$mid"; return; }
             if [[ "$act" == ping ]]; then screen_busy_or_start "$mid" ping "⚡ Ping radar · ${arg}" "$arg"
             else screen_busy_or_start "$mid" tests "🧪 تست کیفیت ${arg}" "$arg"; fi ;;
    daily)   screen_busy_or_start "$mid" daily "📅 تست روزانه" ;;
    heal)    screen_busy_or_start "$mid" heal "♻️ ریستارت خرابها" ;;
    restart) screen_busy_or_start "$mid" restart "ریستارت ${arg}" "$arg" ;;
    update)  screen_busy_or_start "$mid" update "آپدیت" ;;
    turbo)   screen_busy_or_start "$mid" turbo "Turbo" ;;
    doctor)  screen_busy_or_start "$mid" doctor "Network doctor" ;;
    risk)    screen_risk "$mid" "$arg" ;;
  esac
}

handle_callback() { # cbid mid data
  local cbid=$1 mid=$2 data=$3 a b c
  IFS=':' read -r a b c _ <<<"$data"
  [[ "$a" == soon ]] && { answer_cb "$cbid"; screen_risk "$mid"; return; }
  [[ "$a" == nop ]]  && { answer_cb "$cbid"; return; }
  if [[ "$a" == dt && "$b" == heal ]] && [[ -z "$(failed_from_daily)" ]]; then answer_cb "$cbid" "✨ در آخرین گزارش لوکیشن خرابی نیست"; return; fi
  local jn=""
  case "$a" in
    ping) jn=ping ;; qt) jn=tests ;; ip) jn=ips ;;
    dt) [[ "$b" == run ]] && jn=daily ;;
    y)  case "$b" in restart|update|turbo|doctor|heal) jn=$b ;; esac ;;
  esac
  if [[ -n "$jn" ]] && job_busy "$jn"; then answer_cb "$cbid" "⏳ این کار در حال اجراست…"; return; fi
  answer_cb "$cbid"
  clear_pending
  set_owner "$mid" nav
  case "$a" in
    m)       screen_menu "$mid" ;;
    settings) screen_settings "$mid" ;;
    ports)   screen_ports "$mid" ;;
    locs)    screen_locs "$mid" ;;
    loc)     set_location "$b"; screen_locs "$mid" ;;
    sched)   screen_sched "$mid" ;;
    alerts)  screen_alerts "$mid" ;;
    autorst) screen_autorst "$mid" ;;
    appear)  screen_appear "$mid" ;;
    security) screen_security "$mid" ;;
    tog)     settings_toggle "$b"; screen_settings "$mid" ;;
    wint)    set_pending watcher "$mid"; edit "${HDR}⏲️ عدد دقیقه را بفرست: <code>1</code>، <code>2</code>، <code>5</code> یا <code>10</code>" "$(nav sched | kb)" "$mid" ;;
    ipint)   set_pending iphours "$mid"; edit "${HDR}🌐 فاصله IP refresh را بفرست: <code>3</code>، <code>6</code>، <code>12</code> یا <code>24</code> ساعت" "$(nav sched | kb)" "$mid" ;;
    hour)    set_pending hour "$mid"; edit "${HDR}⏰ ساعت را به شکل <code>09:30</code> بفرست." "$(nav sched | kb)" "$mid" ;;
    threshold) set_pending threshold "$mid"; edit "${HDR}🎚️ آستانه latency را به میلی‌ثانیه بفرست." "$(nav alerts | kb)" "$mid" ;;
    fails)   set_pending fails "$mid"; edit "${HDR}🔁 تعداد خطای پیاپی را بفرست (۱ تا ۹۹)." "$(nav autorst | kb)" "$mid" ;;
    lang)    set_pending lang "$mid"; edit "${HDR}🌐 زبان را بفرست: <code>FA</code> یا <code>EN</code>" "$(nav appear | kb)" "$mid" ;;
    backup)  backup_send; answer_cb "$cbid" "فایل بکاپ ارسال شد" ;;
    adminadd) set_pending adminadd "$mid"; edit "${HDR}➕ شناسه عددی admin جدید را بفرست." "$(nav security | kb)" "$mid" ;;
    adminrm) set_pending adminrm "$mid"; edit "${HDR}➖ شناسه admin را برای حذف بفرست." "$(nav security | kb)" "$mid" ;;
    bases)   base_ports_prompt "$mid" ;;
    pc)      valid_cc "$b" && [[ "$c" == socks || "$c" == http ]] && port_change_prompt "$mid" "$b" "$c" ;;
    py)      [[ "$b" =~ ^[A-Z]{2}$ && "$c" =~ ^(socks|http)$ && "${data##*:}" =~ ^[0-9]+$ ]] && apply_port_change "$b" "$c" "${data##*:}" ;;
    st)      screen_status "$mid" ;;
    pg)      do_action "$mid" ping all ;;
    pm)      screen_ping_menu "$mid" ;;
    pv)      [[ "$b" =~ ^(all|best|down)$ ]] && screen_ping_view "$mid" "$b" ;;
    qt)      do_action "$mid" qt "$b" ;;
    rt)      screen_report "$mid" ;;
    dt)      case "$b" in
               run)  do_action "$mid" daily ;;
               full) screen_daily_full "$mid" ;;
               heal) screen_confirm "$mid" heal - "♻️ ریستارت لوکیشن‌های خراب آخرین گزارش (پله‌ای) و تست دوباره:
<b>$(failed_from_daily | tr '\n' ' ')</b>" rt ;;
             esac ;;
    rs)      screen_restart_menu "$mid" ;;
    lg)      screen_pick "$mid" logs 0 ;;
    pick)    [[ "$b" =~ ^(ping|restart|logs)$ && "${c:-0}" =~ ^[0-9]+$ ]] && screen_pick "$mid" "$b" "${c:-0}" ;;
    in)      [[ "$b" =~ ^(ping|restart|logs)$ ]] && screen_input_prompt "$mid" "$b" ;;
    ping)    do_action "$mid" ping "$b" ;;
    logs)    valid_cc "$b" && screen_logs "$mid" "$b" ;;
    restart) if [[ "$b" == all ]] || valid_cc "$b"; then
               screen_confirm "$mid" restart "${b^^}" "🔴 ریستارت <b>${b^^}</b>$( [[ $b == all ]] && printf ' (همه لوکیشن‌ها، پله‌ای)')" rs
             fi ;;
    up)      screen_confirm "$mid" update - "🟠 آپدیت باینری و اسکریپت‌ها (با rollback خودکار). ممکن است سرویس‌ها و ربات ریستارت شوند." m ;;
    tb)      screen_confirm "$mid" turbo - "🟣 اعمال Turbo: تنظیمات sysctl و محدودیت‌های systemd تغییر می‌کند (قابل بازگشت)." m ;;
    dr)      screen_confirm "$mid" doctor - "🟣 Network doctor کامل: یک rule محدود ICMP در iptables اضافه می‌شود (قابل بازگشت)." m ;;
    ip)      screen_busy_or_start "$mid" ips "رتبه‌بندی IPها" ;;
    risk)    screen_risk "$mid" "$b" ;;
    riskmute) cfg_set RISK_MUTE_UNTIL "$(( $(now) + 3600 ))"; answer_cb "$cbid" "🔇 ریسک برای یک ساعت ساکت شد" ;;
    y)       local t=${data##*:}
             if [[ ! "$t" =~ ^[0-9]+$ ]] || (( $(now) - t > CONFIRM_TTL )); then
               edit "${HDR}⌛ تأیید منقضی شد. دوباره امتحان کن." "$(nav m | kb)" "$mid"; return
             fi
             case "$b" in
               restart) [[ "$c" == ALL ]] && c=all; { [[ "$c" == all ]] || valid_cc "$c"; } && do_action "$mid" restart "$c" ;;
               update|turbo|doctor|heal) do_action "$mid" "$b" ;;
             esac ;;
    x)       delete_msg "$mid" || edit "✖️ منو بسته شد. برای باز کردن: /menu" "" "$mid" ;;
    *)       screen_menu "$mid" ;;
  esac
}

new_screen() { # پیام خالی می‌سازد و message_id برمی‌گرداند
  send "${HDR}⏳" "" | jq -r '.result.message_id // empty'
}

handle_text() { # text
  local text=$1 cmd arg p kind pmid mid x y z
  cmd="${text%% *}"; cmd="${cmd%@*}"; arg="${text#"${text%% *}"}"; arg="${arg# }"
  if [[ "$text" != /* ]] && p="$(get_pending)"; then
    read -r kind pmid <<<"$p"; clear_pending
    arg="$(tr -d '[:space:]' <<<"$text")"
    case "$kind" in
      watcher) [[ "$arg" =~ ^(1|2|5|10)$ ]] && { cfg_set WATCHER_INTERVAL_MIN "$arg"; sed -i -E "s/^OnUnitActiveSec=.*/OnUnitActiveSec=${arg}min/" /etc/systemd/system/psiphon-bot-watcher.timer; systemctl daemon-reload; systemctl restart psiphon-bot-watcher.timer 2>/dev/null || true; screen_sched "$pmid"; } || send "${HDR}⚠️ فقط 1، 2، 5 یا 10." "$(nav sched | kb)" >/dev/null; return ;;
      iphours) [[ "$arg" =~ ^(3|6|12|24)$ ]] && { cfg_set IP_REFRESH_HOURS "$arg"; sed -i -E "s/^OnUnitActiveSec=.*/OnUnitActiveSec=${arg}h/" /etc/systemd/system/psiphon-bot-ip-refresh.timer; systemctl daemon-reload; systemctl restart psiphon-bot-ip-refresh.timer 2>/dev/null || true; screen_sched "$pmid"; } || send "${HDR}⚠️ فقط 3، 6، 12 یا 24." "$(nav sched | kb)" >/dev/null; return ;;
      hour) [[ "$arg" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] && { cfg_set DAILY_TEST_HOUR "$arg"; sed -i -E "s/^OnCalendar=.*/OnCalendar=*-*-* ${arg}:00/" /etc/systemd/system/psiphon-bot-daily-test.timer; systemctl daemon-reload; systemctl restart psiphon-bot-daily-test.timer 2>/dev/null || true; screen_sched "$pmid"; } || send "${HDR}⚠️ قالب ساعت نامعتبر است." "$(nav sched | kb)" >/dev/null; return ;;
      threshold) [[ "$arg" =~ ^[1-9][0-9]*$ ]] && { cfg_set LATENCY_ALERT_MS "$arg"; screen_alerts "$pmid"; } || send "${HDR}⚠️ فقط عدد مثبت." "$(nav alerts | kb)" >/dev/null; return ;;
      fails) [[ "$arg" =~ ^[1-9][0-9]?$ ]] && { cfg_set AUTO_HEAL_FAILS "$arg"; screen_autorst "$pmid"; } || send "${HDR}⚠️ عدد ۱ تا ۹۹." "$(nav autorst | kb)" >/dev/null; return ;;
      lang) [[ "$arg" =~ ^(FA|EN|fa|en)$ ]] && { cfg_set UI_LANG "${arg^^}"; screen_appear "$pmid"; } || send "${HDR}⚠️ فقط FA یا EN." "$(nav appear | kb)" >/dev/null; return ;;
      adminadd) [[ "$arg" =~ ^-?[0-9]{5,20}$ ]] && { cur="$(settings_value EXTRA_ADMIN_IDS)"; cfg_set EXTRA_ADMIN_IDS "${cur:+$cur,}$arg"; screen_security "$pmid"; } || send "${HDR}⚠️ شناسه عددی نامعتبر." "$(nav security | kb)" >/dev/null; return ;;
      adminrm) cur="$(settings_value EXTRA_ADMIN_IDS)"; cfg_set EXTRA_ADMIN_IDS "$(tr ',' '\n' <<<"$cur" | grep -vxF "$arg" | paste -sd, -)"; screen_security "$pmid"; return ;;
    esac
    if [[ "$kind" == bases ]]; then
      read -r x y <<<"$text"
      [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]] || { send "${HDR}⚠️ فرمت درست: <code>10800 10900</code>" "$(nav bases | kb)" >/dev/null; return; }
      apply_base_ports "$x" "$y"
      return
    fi
    if [[ "$kind" == port:* ]]; then
      IFS=: read -r _ x y <<<"$kind"
      [[ "$arg" =~ ^[0-9]+$ ]] || { send "${HDR}⚠️ فقط عدد پورت را بفرست." "$(nav ports | kb)" >/dev/null; return; }
      edit "${HDR}⚠️ <b>تأیید تغییر پورت</b>
${x^^} ${y^^}: <code>${arg}</code>
سرویس restart می‌شود؛ در صورت شکست، rollback خودکار است." "$(printf '✅ تأیید|py:%s:%s:%s\n❌ لغو|ports' "$x" "$y" "$arg" | kb)" "$pmid"
      return
    fi
    if ! valid_cc "$arg"; then send "${HDR}⚠️ کد نامعتبر: $(esc "$arg")" "$( { printf '⌨️ دوباره|in:%s\n' "$kind"; nav m; } | kb)" >/dev/null; return; fi
    set_owner "$pmid" nav
    case "$kind" in
      ping)    do_action "$pmid" ping "$arg" ;;
      logs)    screen_logs "$pmid" "$arg" ;;
      restart) screen_confirm "$pmid" restart "${arg^^}" "🔴 ریستارت <b>${arg^^}</b>" rs ;;
    esac
    return
  fi
  case "$cmd" in
    /start|/menu|/help) clear_pending; screen_menu ;;
    /cancel)  clear_pending; send "${HDR}لغو شد." "$(nav m | kb)" >/dev/null ;;
    /status)  mid="$(new_screen)" && [[ -n "$mid" ]] && screen_status "$mid" ;;
    /ping)    mid="$(new_screen)" && [[ -n "$mid" ]] && do_action "$mid" ping "${arg:-all}" ;;
    /test)    mid="$(new_screen)" && [[ -n "$mid" ]] && { [[ -n "$arg" ]] && do_action "$mid" qt "$arg" || screen_ping_menu "$mid"; } ;;
    /report)  mid="$(new_screen)" && [[ -n "$mid" ]] && screen_report "$mid" ;;
    /daily)   mid="$(new_screen)" && [[ -n "$mid" ]] && do_action "$mid" daily ;;
    /risk)    mid="$(new_screen)" && [[ -n "$mid" ]] && screen_risk "$mid" "${arg:-}" ;;
    /top)     mid="$(new_screen)" && [[ -n "$mid" ]] && { t="$(jq -r '[.results[]? | select(.state!="fail")] | sort_by(-.score) | .[0:5][] | "\(.cc) \(.score)/100 \(.latency_avg_ms)ms \(.speed_kbps)kbps"' "$LAST_TESTS" 2>/dev/null | tr '\n' ' ')"; send "${HDR}🏆 <b>Top</b>
<pre>$(esc "${t:-هنوز تستی ثبت نشده}")</pre>" "$(nav m | kb)" >/dev/null; } ;;
    /speed)   mid="$(new_screen)" && [[ -n "$mid" ]] && do_action "$mid" qt "${arg:-all}" ;;
    /ip)      mid="$(new_screen)" && [[ -n "$mid" ]] && { valid_cc "$arg" && { x="$(jq -r --arg c "${arg^^}" '.results[]? | select(.cc==$c) | "\(.ip) (\(.country))"' "$LAST_TESTS" 2>/dev/null | head -1)"; send "${HDR}🌐 <b>${arg^^}</b>
<pre>$(esc "${x:-هنوز داده‌ای برای این کشور نداریم}")</pre>" "$(nav m | kb)" >/dev/null; } || screen_pick "$mid" logs 0; } ;;
    /traffic) send "${HDR}📊 ترافیک: برای کیفیت از <code>/speed CC</code> و برای وضعیت از <code>/sys</code> استفاده کن." "$(nav m | kb)" >/dev/null ;;
    /sys)     mid="$(new_screen)" && [[ -n "$mid" ]] && { h="$(server_health)"; send "${HDR}🖥 <b>سیستم</b>
<pre>CPU $(jq -r '.cpu_pct' <<<"$h")% · RAM $(jq -r '.mem_pct' <<<"$h")% · Disk $(jq -r '.disk_pct' <<<"$h")% · load $(jq -r '.load1' <<<"$h")</pre>" "$(nav m | kb)" >/dev/null; } ;;
    /bestfor) send "${HDR}🎯 بهترین لوکیشن برای <b>$(esc "${arg:-عمومی}")</b> از امتیاز و latency گزارش روزانه انتخاب می‌شود. <code>/top</code>" "$(nav m | kb)" >/dev/null ;;
    /proxy)   mid="$(new_screen)" && [[ -n "$mid" ]] && { valid_cc "$arg" && screen_status "$mid" || screen_pick "$mid" logs 0; } ;;
    /restart) mid="$(new_screen)" && [[ -n "$mid" ]] && {
                if [[ "${arg,,}" == all ]] || valid_cc "$arg"; then screen_confirm "$mid" restart "${arg^^}" "🔴 ریستارت <b>${arg^^}</b>" rs
                else screen_restart_menu "$mid"; fi; } ;;
    /logs)    mid="$(new_screen)" && [[ -n "$mid" ]] && { valid_cc "$arg" && screen_logs "$mid" "$arg" || screen_pick "$mid" logs 0; } ;;
    /ips)     mid="$(new_screen)" && [[ -n "$mid" ]] && screen_busy_or_start "$mid" ips "رتبه‌بندی IPها" ;;
    /backup)  backup_send ;;
    /restore) [[ -n "$arg" ]] && restore_file "$arg" || send "${HDR}فرمت: <code>/restore /path/to/backup.tar.gz</code>" "$(nav security | kb)" >/dev/null ;;
    /update)  mid="$(new_screen)" && [[ -n "$mid" ]] && handle_callback "" "$mid" up ;;
    /turbo)   mid="$(new_screen)" && [[ -n "$mid" ]] && handle_callback "" "$mid" tb ;;
    /netdoctor|/doctor) mid="$(new_screen)" && [[ -n "$mid" ]] && handle_callback "" "$mid" dr ;;
    *)        screen_menu ;;
  esac
}

# =============================================================================
# entrypoints
# =============================================================================
if [[ "${1:-}" == --job ]]; then shift; job_main "$@"; exit 0; fi
if [[ "${1:-}" == --daily ]]; then daily_main; exit 0; fi
if [[ "${1:-}" == --heal-tick ]]; then shift; heal_tick "${1:-}" "${2:-fail}" "${3:-watch}"; exit 0; fi
if [[ "${1:-}" == --ping ]]; then shift; if [[ "${1:-all}" == all ]]; then run_pings; else run_pings "${1^^}"; fi; exit 0; fi
if [[ "${1:-}" == --daily-preview ]]; then daily_render; echo; exit 0; fi
if [[ "${1:-}" == --test ]]; then shift; if [[ "${1:-all}" == all ]]; then run_all_tests; else test_location "$1"; fi; exit 0; fi

trap 'exit 0' TERM INT
offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"; [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
send "${HDR}🟢 ربات بالا آمد" "$(printf '🏠 منو|m|primary\n' | kb)" >/dev/null || true
while :; do
  find "$RUN" -maxdepth 1 -name 'owner.*' -mmin +180 -delete 2>/dev/null || true
  resp="$(api getUpdates "$(jq -nc --argjson o "$offset" '{offset:$o, timeout:45, allowed_updates:["message","callback_query"]}')" 60)" || { sleep 5; continue; }
  while IFS=$'\t' read -r id chat mid cbid data; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    offset=$((id + 1)); printf '%s' "$offset" > "$OFFSET_FILE"   # قبل از اجرا: بعد از restart تکرار نمی‌شود
    admin_allowed "$chat" || continue
    data="${data//\\n/ }"; data="${data//\\t/ }"
    if [[ -n "$cbid" ]]; then handle_callback "$cbid" "$mid" "$data"
    elif [[ -n "$data" ]]; then handle_text "$data"; fi
  done < <(jq -r '.result[] | [ (.update_id|tostring),
            ((.message.chat.id // .callback_query.message.chat.id // "")|tostring),
            ((.callback_query.message.message_id // "")|tostring),
            (.callback_query.id // ""),
            (.callback_query.data // .message.text // "") ] | @tsv' 2>/dev/null <<<"$resp" || true)
done
[[ "$WATCHER_INTERVAL_MIN" =~ ^(1|2|5|10)$ ]] || WATCHER_INTERVAL_MIN=2
[[ "$IP_REFRESH_HOURS" =~ ^(3|6|12|24)$ ]] || IP_REFRESH_HOURS=6
[[ "$LATENCY_ALERT_MS" =~ ^[1-9][0-9]*$ ]] || LATENCY_ALERT_MS=300
[[ "$ALERT_COOLDOWN_SEC" =~ ^[1-9][0-9]*$ ]] || ALERT_COOLDOWN_SEC=300
[[ "$UI_LANG" =~ ^(FA|EN)$ ]] || UI_LANG=FA
BOT_EOF
  $FILE_CHANGED && bot_changed=true

  # تنظیمات پیش‌فرض ربات و لیست لوکیشن‌های غیرفعال (فقط اگر وجود ندارند؛ ویرایش کاربر حفظ می‌شود)
  if [[ ! -e "$BOT_SETTINGS" ]]; then
    write_file "$BOT_SETTINGS" 0600 "root:root" <<'SET_EOF'
# MAXNET6G bot settings (KEY=VALUE). مقدار نامعتبر نادیده گرفته می‌شود.
BTN_STYLE=auto
API_RETRIES=4
API_BACKOFF=1
TEST_PARALLEL=6
TEST_TIMEOUT=15
GEO_URL=https://ipinfo.io/json
LAT_URL=https://www.gstatic.com/generate_204
LAT_SAMPLES=3
SPEED_URL=https://speed.cloudflare.com/__down?bytes=1000000
SPEED_TIMEOUT=25
STRICT_COUNTRY_MATCH=true
PENDING_TTL=300
CONFIRM_TTL=120
PAGE_SIZE=12
PAGE_COLS=3
DAILY_TEST_ENABLED=true
WATCHER_INTERVAL_MIN=2
IP_REFRESH_HOURS=6
ALERT_LOCATION_DOWN=true
ALERT_SERVER_DOWN=true
ALERT_LATENCY=true
LATENCY_ALERT_MS=300
ALERT_COOLDOWN_SEC=300
QUIET_HOURS_ENABLED=false
QUIET_HOURS_START=23:00
QUIET_HOURS_END=07:00
SUMMARY_ONLY=false
UI_LANG=FA
UI_COMPACT=false
EMOJI_ENABLED=true
EXTRA_ADMIN_IDS=
RISK_ENABLED=true
RISK_SENSITIVITY=50
RISK_THRESHOLD=60
RISK_COOLDOWN_SEC=1800
RISK_AUTO_RESTART=false
RISK_MUTE_UNTIL=0
SET_EOF
  fi
  # کلیدهای جدید (Part 2) به فایل تنظیمات موجود اضافه می‌شوند؛ مقادیر کاربر دست نمی‌خورد
  local kv
  for kv in "PING_SAMPLES=3" "PING_TIMEOUT=8" "PING_GOOD_MS=120" "PING_SLOW_MS=300" \
            "DAILY_TEST_HOUR=${DAILY_TEST_HOUR}" "DAILY_TOP=5" "HISTORY_DAYS=7" \
            "AUTO_HEAL=false" "AUTO_HEAL_FAILS=3" "AUTO_HEAL_MAX_PER_HOUR=3" \
            "DAILY_TEST_ENABLED=true" "WATCHER_INTERVAL_MIN=2" "IP_REFRESH_HOURS=6" \
            "ALERT_LOCATION_DOWN=true" "ALERT_SERVER_DOWN=true" "ALERT_LATENCY=true" \
            "LATENCY_ALERT_MS=300" "ALERT_COOLDOWN_SEC=300" "QUIET_HOURS_ENABLED=false" \
            "QUIET_HOURS_START=23:00" "QUIET_HOURS_END=07:00" "SUMMARY_ONLY=false" \
            "UI_LANG=FA" "UI_COMPACT=false" "EMOJI_ENABLED=true" "EXTRA_ADMIN_IDS=" \
            "RISK_ENABLED=true" "RISK_SENSITIVITY=50" "RISK_THRESHOLD=60" \
            "RISK_COOLDOWN_SEC=1800" "RISK_AUTO_RESTART=false" "RISK_MUTE_UNTIL=0"; do
    if ! grep -q "^${kv%%=*}=" "$BOT_SETTINGS" 2>/dev/null; then
      if $DRY_RUN; then log "[dry-run] افزودن ${kv} به ${BOT_SETTINGS}"; else printf '%s\n' "$kv" >> "$BOT_SETTINGS"; fi
    fi
  done
  if [[ ! -e "$DISABLED_LOCATIONS" ]]; then
    printf '# یک کد کشور در هر خط (مثلاً NL). این لوکیشن‌ها در تست، healthcheck و watcher رد می‌شوند.\n' \
      | write_file "$DISABLED_LOCATIONS" 0644 "root:root"
  fi

  # نصب خود اسکریپت تا ربات بتواند Update/Turbo/Doctor را صدا بزند
  local self_src
  self_src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  if [[ -f "$self_src" && "$self_src" != "$SELF_INSTALL_PATH" ]]; then
    write_file "$SELF_INSTALL_PATH" 0755 "root:root" < "$self_src"
  elif [[ ! -f "$self_src" ]]; then
    warn "مسیر اسکریپت فایل واقعی نیست (pipe؟)؛ ${SELF_INSTALL_PATH} به‌روز نشد"
  fi

  write_file "$BOT_WATCHER" 0750 "root:root" <<'WATCH_EOF'
#!/usr/bin/env bash
# دیده‌بان ربات، بدون تکیه بر ICMP برای تشخیص قطعی سرور
set -Eeuo pipefail
CONF="/etc/psiphon/telegram-bot.conf"
[[ -r "$CONF" ]] || exit 0
. "$CONF"
MAP="/etc/psiphon/mapping.txt"
STATE="/var/lib/psiphon/telegram-watch.state"
SAMPLES="/var/lib/psiphon/health-samples.jsonl"
COOLDOWN=300
mkdir -p "$(dirname "$STATE")"; touch "$STATE"; chmod 0600 "$STATE"
send() {
  local cfg rc=0
  cfg="$(mktemp "${TMPDIR:-/tmp}/psiphon-telegram.XXXXXX")" || return 0
  chmod 0600 "$cfg"
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$BOT_TOKEN" > "$cfg"
  curl -fsS --retry 5 --retry-delay 2 --max-time 25 -X POST --config "$cfg" \
    --data-urlencode "chat_id=${ADMIN_CHAT_ID}" --data-urlencode "text=$1" >/dev/null || rc=$?
  rm -f -- "$cfg"
  return "$rc"
}
now="$(date +%s)"
setting() { awk -F= -v k="$1" '$1==k{print $2}' /etc/psiphon/bot-settings.conf 2>/dev/null | tail -n1; }
in_quiet_hours() {
  [[ "$(setting QUIET_HOURS_ENABLED)" == true ]] || return 1
  local cur start end; cur="$(date +%H:%M)"; start="$(setting QUIET_HOURS_START)"; end="$(setting QUIET_HOURS_END)"
  if [[ "$start" < "$end" ]]; then
    [[ "$cur" > "$start" || "$cur" == "$start" ]] && [[ "$cur" < "$end" ]]
  else
    [[ "$cur" > "$start" || "$cur" == "$start" || "$cur" < "$end" ]]
  fi
}
key_state() { awk -v k="$1" '$1==k{print $2}' "$STATE" 2>/dev/null || true; }
set_state() { local k=$1 v=$2 t=$3; awk -v k="$k" '$1!=k' "$STATE" > "${STATE}.tmp" 2>/dev/null || true; printf '%s %s %s\n' "$k" "$v" "$t" >> "${STATE}.tmp"; mv "${STATE}.tmp" "$STATE"; }
notify() {
  local key=$1 new=$2 msg=$3 old t
  in_quiet_hours && return 0
  [[ "$(setting SUMMARY_ONLY)" == true && "$key" == instance_* ]] && return 0
  [[ "$key" == server* && "$(setting ALERT_SERVER_DOWN)" != true ]] && return 0
  [[ "$key" == instance_* && "$(setting ALERT_LOCATION_DOWN)" != true ]] && return 0
  old="$(key_state "$key")"; t="$(awk -v k="$key" '$1==k{print $3}' "$STATE" 2>/dev/null || true)"
  if [[ "$old" != "$new" ]] || [[ -z "$t" ]] || (( now - t >= COOLDOWN )); then
    send "🟦 MAXNET6G
${msg}
time: $(date '+%F %T %Z')"
    set_state "$key" "$new" "$now"
  fi
}
server_ok=false
curl -fsSI --max-time 8 https://example.com >/dev/null 2>&1 && server_ok=true
if $server_ok; then notify server up "🟢 server recovered"; else notify server down "🔴 server down: TCP/HTTPS failed"; fi
DIS="/etc/psiphon/disabled-locations.txt"
BOT="/etc/psiphon/telegram-bot.sh"
HEAL=false
grep -qE '^AUTO_HEAL="?true"?[[:space:]]*$' /etc/psiphon/bot-settings.conf 2>/dev/null && [[ -x "$BOT" ]] && HEAL=true
while read -r cc socks http; do
  [[ "$cc" == \#* || -z "$cc" ]] && continue
  [[ -r "$DIS" ]] && grep -qiE "^[[:space:]]*${cc}([[:space:]]|#|$)" "$DIS" && continue
  active="$(systemctl is-active "psiphon-${cc}.service" 2>/dev/null || true)"
  reason="service=${active}"
  probe="$(curl -sS --max-time 12 --socks5-hostname "127.0.0.1:${socks}" https://ipinfo.io/json 2>/dev/null || true)"
  country="$(jq -r '.country // "-"' <<<"$probe" 2>/dev/null || echo -)"
  lat="$(curl -sS -o /dev/null --max-time 10 -w '%{time_total}' --socks5-hostname "127.0.0.1:${socks}" https://www.gstatic.com/generate_204 2>/dev/null || echo 0)"
  lat="$(awk -v t="$lat" 'BEGIN{printf "%d", t*1000}')"
  ok=false; [[ "$active" == active && "$country" != "-" ]] && ok=true
  mkdir -p "$(dirname "$SAMPLES")"; touch "$SAMPLES"
  jq -nc --argjson ts "$(date +%s)" --arg cc "$cc" --argjson ok "$ok" --argjson lat "${lat:-0}" \
    --arg ip "$(jq -r '.ip // "-"' <<<"$probe" 2>/dev/null || echo -)" --arg country "$country" \
    '{ts:$ts,cc:$cc,ok:$ok,state:(if $ok then "ok" else "fail" end),latency:$lat,speed:0,ip:$ip,country:$country,restarts:0}' |
    { flock -w 5 9 || exit 0; cat >> "$SAMPLES"; awk -v c="$(date -d '7 days ago' +%s)" '{n=$0; sub(/.*"ts":/,"",n); sub(/,.*/,"",n); if ((n+0)>=c) print}' "$SAMPLES" | tail -c 20000000 > "${SAMPLES}.tmp" && mv -f "${SAMPLES}.tmp" "$SAMPLES"; } 9>"${SAMPLES}.lock"
  if [[ "$active" == active && "$country" != "-" ]]; then
    notify "instance_${cc}" up "🟢 ${cc} up: country=${country}, port=${socks}"
    $HEAL && { "$BOT" --heal-tick "$cc" ok watcher </dev/null >/dev/null 2>&1 || true; }
  else
    [[ "$active" != active ]] && reason="${reason}; service unavailable"
    [[ "$country" == "-" ]] && reason="${reason}; SOCKS/HTTPS probe failed"
    notify "instance_${cc}" down "🔴 ${cc} down: country=${country}, port=${socks}, reason=${reason}"
    $HEAL && { "$BOT" --heal-tick "$cc" fail watcher </dev/null >/dev/null 2>&1 || true; }
  fi
done < "$MAP"
for unit in psiphon-bot.service psiphon-healthcheck.timer; do
  s="$(systemctl is-active "$unit" 2>/dev/null || true)"
  [[ "$s" == active ]] || notify "unit_${unit}" down "⚠️ logger/monitor unit failed: ${unit}, state=${s}"
done
WATCH_EOF

  write_file "$BOT_SERVICE" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}
[Unit]
Description=${BRAND} Telegram bot
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=${BOT_SCRIPT}
Restart=always
RestartSec=15
NoNewPrivileges=true
ProtectSystem=full
# jobهای سنگین (update/turbo/doctor) با systemd-run در unit جدا اجرا می‌شوند و این محدودیت‌ها را ندارند
ReadWritePaths=${DATA_DIR} ${CONF_DIR} /run
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
  write_file "$BOT_WATCHER_SERVICE" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}
[Unit]
Description=${BRAND} Telegram watcher
After=network-online.target
[Service]
Type=oneshot
ExecStart=${BOT_WATCHER}
EOF
  write_file "$BOT_REFRESH_SERVICE" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}
[Unit]
Description=${BRAND} endpoint refresh
[Service]
Type=oneshot
ExecStart=/usr/local/bin/psiphon-ip-refresh apply
EOF
  local wi ih
  wi=2
  ih=6
  if [[ -r "$BOT_SETTINGS" ]]; then
    wi="$(awk -F= '$1=="WATCHER_INTERVAL_MIN"{print $2}' "$BOT_SETTINGS" 2>/dev/null | tail -n1 || true)"
    ih="$(awk -F= '$1=="IP_REFRESH_HOURS"{print $2}' "$BOT_SETTINGS" 2>/dev/null | tail -n1 || true)"
  fi
  [[ "$wi" =~ ^(1|2|5|10)$ ]] || wi=2
  [[ "$ih" =~ ^(3|6|12|24)$ ]] || ih=6
  write_file "$BOT_WATCHER_TIMER" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}
[Unit]
Description=${BRAND} watcher interval
[Timer]
OnBootSec=2min
OnUnitActiveSec=${wi}min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  write_file "$BOT_TIMER" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}
[Unit]
Description=${BRAND} scheduled endpoint refresh
[Timer]
OnBootSec=10min
OnUnitActiveSec=${ih}h
Persistent=true
[Install]
WantedBy=timers.target
EOF
  write_file "$BOT_DAILY_SERVICE" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}
[Unit]
Description=${BRAND} daily location test + 24h report
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${BOT_SCRIPT} --daily
TimeoutStartSec=45min
Nice=5
EOF
  local dhour daily_changed=false
  dhour="$(daily_test_hour)"
  write_file "$BOT_DAILY_TIMER" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}
[Unit]
Description=${BRAND} daily test at ${dhour}
[Timer]
OnCalendar=*-*-* ${dhour}:00
Persistent=true
RandomizedDelaySec=60
Unit=psiphon-bot-daily-test.service
[Install]
WantedBy=timers.target
EOF
  $FILE_CHANGED && daily_changed=true
  write_file /usr/local/bin/psiphon-ip-refresh 0755 "root:root" <<'IP_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# endpointها بدون تغییر mapping، پورت یا کشور؛ فقط گزارش امن و قابل تکرار
CONF="/etc/psiphon/telegram-bot.conf"; [[ -r "$CONF" ]] || exit 1; . "$CONF"
STATE="/var/lib/psiphon/ip-candidates.json"; mkdir -p "$(dirname "$STATE")"
targets=(https://example.com https://1.1.1.1 https://8.8.8.8)
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
for url in "${targets[@]}"; do
  vals=()
  for _ in 1 2 3; do vals+=("$(curl -k -sS -o /dev/null -w '%{time_connect}' --connect-timeout 5 --max-time 8 "$url" 2>/dev/null || echo 99)"); done
  avg="$(printf '%s\n' "${vals[@]}" | awk '{s+=$1} END{if(NR)printf "%.4f",s/NR; else print 99}')"
  printf '%s\t%s\n' "$avg" "$url" >> "$tmp"
done
sort -n "$tmp" | jq -Rn '[inputs|split("\t")|{latency:(.[0]|tonumber),endpoint:.[1]}]' | tee "$STATE"
IP_EOF
  run chmod 0755 /usr/local/bin/psiphon-ip-refresh
  run systemctl daemon-reload
  if $bot_changed && ! $DRY_RUN && systemctl is-active --quiet psiphon-bot.service 2>/dev/null; then
    systemctl try-restart psiphon-bot.service || warn "ریستارت ربات ناموفق بود"
  fi
  # تایمر تست روزانه: اگر ربات فعال است، روشن بماند و با ساعت جدید بارگذاری شود
  if grep -qx 'BOT_ENABLED=true' "$BOT_CONF" 2>/dev/null; then
    run systemctl enable --now psiphon-bot-daily-test.timer 2>/dev/null || warn "فعال‌سازی تایمر تست روزانه ناموفق بود"
    if [[ "$(awk -F= '$1=="DAILY_TEST_ENABLED"{print $2}' "$BOT_SETTINGS" 2>/dev/null | tail -n1)" == false ]]; then
      run systemctl disable --now psiphon-bot-daily-test.timer 2>/dev/null || true
    fi
    if $daily_changed && ! $DRY_RUN; then systemctl restart psiphon-bot-daily-test.timer 2>/dev/null || true; fi
  fi
}

# ساعت تست روزانه: bot-settings.conf (اگر معتبر) وگرنه DAILY_TEST_HOUR. "9" یا "9:30" هم پذیرفته می‌شود.
daily_test_hour() {
  local v
  v=""
  if [[ -r "$BOT_SETTINGS" ]]; then
    v="$(awk -F= '$1=="DAILY_TEST_HOUR"{gsub(/["[:space:]]/,"",$2); print $2}' "$BOT_SETTINGS" 2>/dev/null | tail -n 1 || true)"
  fi
  [[ "$v" =~ ^[0-9]{1,2}$ ]] && v="${v}:00"
  if [[ "$v" =~ ^([0-9]{1,2}):([0-5][0-9])$ ]] && (( 10#${BASH_REMATCH[1]} <= 23 )); then
    printf '%02d:%s' "$((10#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]}"
  else
    printf '%s' "$DAILY_TEST_HOUR"
  fi
}

bot_setup() {
  check_root
  run install -d -m 0700 -o root -g root "$CONF_DIR"
  write_bot_files
  if [[ -r "$BOT_CONF" ]]; then
    echo "1) حفظ فعلی  2) غیرفعال‌سازی  3) حذف کامل  0) لغو"
    read -r action
    case "$action" in
      2) backup_path "$BOT_CONF"; run sed -i 's/^BOT_ENABLED=.*/BOT_ENABLED=false/' "$BOT_CONF"; run systemctl disable --now psiphon-bot.service 2>/dev/null || true; ok "ربات غیرفعال شد"; return ;;
      3) backup_path "$BOT_CONF"; run systemctl disable --now psiphon-bot.service 2>/dev/null || true; run rm -f "$BOT_CONF"; ok "ربات حذف شد"; return ;;
      0) return ;;
    esac
  fi
  local token chat me
  read -r -s -p "Bot token: " token; echo
  read -r -p "Admin chat ID: " chat
  [[ "$token" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{20,}$ ]] || die "فرمت token نامعتبر است"
  [[ "$chat" =~ ^-?[0-9]{5,20}$ ]] || die "فرمت chat ID نامعتبر است"
  me="$(cfg="$(mktemp "${TMPDIR:-/tmp}/psiphon-telegram.XXXXXX")"; chmod 0600 "$cfg"; printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$token" > "$cfg"; curl -fsS --max-time 15 --config "$cfg" 2>/dev/null || true; rm -f -- "$cfg")"
  jq -e '.ok == true' <<<"$me" >/dev/null || die "اعتبارسنجی Telegram API شکست خورد"
  bot_send_test "$token" "$chat" || die "ارسال پیام آزمایشی شکست خورد"
  backup_path "$BOT_CONF"
  write_file "$BOT_CONF" 0600 "root:root" <<EOF
# MAXNET6G Telegram credentials, root-only
BOT_ENABLED=true
BOT_TOKEN=${token}
ADMIN_CHAT_ID=${chat}
EOF
  run systemctl daemon-reload
  run systemctl enable --now psiphon-bot.service
  run systemctl enable --now psiphon-bot-watcher.timer
  run systemctl enable --now psiphon-bot-ip-refresh.timer 2>/dev/null || true
  run systemctl enable --now psiphon-bot-daily-test.timer 2>/dev/null || true
  ok "ربات MAXNET6G فعال شد (تست روزانه: هر روز $(daily_test_hour))"
}

menu_telegram_bot() { brand_header; bot_setup; read -r -p "Enter برای بازگشت..." _ || true; }

detect_container() {
  [[ -f /.dockerenv ]] || grep -qE 'docker|lxc|openvz|kubepods' /proc/1/cgroup 2>/dev/null
}

turbo_apply() {
  check_root; check_os; validate_config
  local ram_gib cpu rmem backlog cc
  ram_gib="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 1)"
  cpu="$(nproc 2>/dev/null || echo 1)"
  (( ram_gib < 1 )) && ram_gib=1
  (( cpu < 1 )) && cpu=1
  rmem=$(( ram_gib * 1024 * 1024 * 1024 / 2 ))
  backlog=$(( cpu * 4096 )); (( backlog > 250000 )) && backlog=250000
  if detect_container; then
    warn "کانتینر شناسایی شد؛ Turbo از تغییر sysctl، irqbalance و chrony صرف‌نظر می‌کند."
    return 0
  fi
  write_file "$TURBO_SYSCTL" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}; قابل بازگشت با --turbo-revert
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=${rmem}
net.core.wmem_max=${rmem}
net.ipv4.tcp_rmem=4096 87380 ${rmem}
net.ipv4.tcp_wmem=4096 65536 ${rmem}
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.core.somaxconn=65535
net.core.netdev_max_backlog=${backlog}
net.ipv4.ip_local_port_range=10240 65535
net.netfilter.nf_conntrack_max=$(( ram_gib * 65536 ))
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
  run sysctl --system >/dev/null 2>&1 || warn "برخی sysctlها پشتیبانی نمی‌شوند"
  run install -d -m 0755 -o root -g root "$(dirname "$TURBO_MANAGER_DROPIN")"
  write_file "$TURBO_MANAGER_DROPIN" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}
[Manager]
DefaultLimitNOFILE=${LIMIT_NOFILE}
EOF
  for cc in "${COUNTRIES[@]}"; do
    run install -d -m 0755 -o root -g root "${SYSTEMD_DIR}${SERVICE_PREFIX}${cc}.service.d"
    write_file "${SYSTEMD_DIR}${SERVICE_PREFIX}${cc}.service.d/99-psiphon-turbo.conf" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}; unit اصلی بازنویسی نشده است
[Service]
LimitNOFILE=${LIMIT_NOFILE}
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=4
Restart=always
RestartSec=${RESTART_SEC}
EOF
  done
  run systemctl daemon-reload
  command -v irqbalance >/dev/null 2>&1 && run systemctl enable --now irqbalance 2>/dev/null || true
  command -v chronyc >/dev/null 2>&1 && run systemctl enable --now chrony 2>/dev/null || true
  install -d -m 0750 -o "$PSIPHON_USER" -g "$PSIPHON_USER" "$DATA_DIR" 2>/dev/null || true
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg phase after --arg time "$(date -Is)" \
      --arg dns "$(getent hosts example.com 2>/dev/null | head -n1 | awk '{print $1}' || echo '-')" \
      --arg latency "$(curl -o /dev/null -sS -w '%{time_connect}' --max-time 10 https://example.com 2>/dev/null || echo '-')" \
      '{time:$time,phase:$phase,dns:$dns,https_connect_seconds:$latency}' \
      | write_file "$TURBO_STATE" 0640 "root:root"
  fi
  run_net_doctor true
  ok "Turbo فعال شد؛ سرویس‌های سالم restart نشدند."
}

turbo_revert() {
  check_root
  [[ -f "$TURBO_SYSCTL" ]] && run rm -f "$TURBO_SYSCTL"
  [[ -f "$TURBO_MANAGER_DROPIN" ]] && run rm -f "$TURBO_MANAGER_DROPIN"
  local cc
  for cc in "${COUNTRIES[@]}"; do
    run rm -f "${SYSTEMD_DIR}${SERVICE_PREFIX}${cc}.service.d/99-psiphon-turbo.conf"
    run rmdir "${SYSTEMD_DIR}${SERVICE_PREFIX}${cc}.service.d" 2>/dev/null || true
  done
  run sysctl --system >/dev/null 2>&1 || true
  run systemctl daemon-reload
  ok "تنظیمات Turbo حذف شد؛ سرویس‌ها restart نشدند."
}

run_net_doctor() {
  local light=${1:-false} iface mtu max=0 icmp=FAIL tcp=FAIL https=FAIL dns=FAIL clock=FAIL
  if $DRY_RUN; then
    echo "${C_YLW}[DRY-RUN]${C_RST} network doctor probes and writes skipped"
    return 0
  fi
  run install -d -m 0750 -o root -g root "$CONF_DIR" "$DATA_DIR"
  iface="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  mtu="$(ip link show "$iface" 2>/dev/null | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}' || echo 1500)"
  getent hosts example.com >/dev/null 2>&1 && dns=PASS
  timeout 5 bash -c 'cat < /dev/null > /dev/tcp/1.1.1.1/443' >/dev/null 2>&1 && tcp=PASS
  curl -4fsS --max-time 8 -o /dev/null https://example.com >/dev/null 2>&1 && https=PASS
  timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi yes && clock=PASS || chronyc tracking >/dev/null 2>&1 && clock=PASS || true
  if command -v ping >/dev/null 2>&1; then
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && icmp=PASS
    local target payload
    for target in 1.1.1.1 8.8.8.8 9.9.9.9; do
      for ((payload=1472; payload>=1200; payload-=8)); do
        ping -M do -c1 -W1 -s "$payload" "$target" >/dev/null 2>&1 && { max=$payload; break; }
      done
      (( max > 0 )) && break
    done
  fi
  # فقط echo-request را با rate limit مجاز می‌کنیم؛ هیچ پورتی باز نمی‌شود.
  if ! $light && command -v iptables >/dev/null 2>&1; then
    local fw_backup="${DATA_DIR}/netdoctor-firewall.v4"
    iptables-save > "$fw_backup" 2>/dev/null || true
    iptables -C INPUT -p icmp --icmp-type echo-request -m limit --limit 5/second --limit-burst 20 -j ACCEPT 2>/dev/null ||
      iptables -I INPUT 1 -p icmp --icmp-type echo-request -m limit --limit 5/second --limit-burst 20 -j ACCEPT 2>/dev/null || true
  fi
  if ! $light; then
    printf '%-12s | %-7s | %s\n' "ICMP" "$icmp" "شاخص کمکی، نه معیار down"
    printf '%-12s | %-7s | %s\n' "TCP connect" "$tcp" "معیار اصلی"
    printf '%-12s | %-7s | %s\n' "HTTPS" "$https" "معیار اصلی"
    printf '%-12s | %-7s | %s\n' "MTU/MSS" "$([[ "$max" -gt 0 ]] && echo PASS || echo FAIL)" "interface MTU=${mtu}, payload=${max:-unknown}"
    printf '%-12s | %-7s | %s\n' "DNS" "$dns" "resolver سیستم"
    [[ "$icmp" == FAIL && "$tcp" == PASS && "$https" == PASS ]] && warn "ICMP مسدود است اما TCP/HTTPS سالم است؛ سرور down نیست."
  fi
  install -d -m 0750 -o "$PSIPHON_USER" -g "$PSIPHON_USER" "$DATA_DIR" 2>/dev/null || true
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg time "$(date -Is)" --arg iface "$iface" --arg mtu "$mtu" --arg payload "$max" \
      --arg icmp "$icmp" --arg tcp "$tcp" --arg https "$https" --arg dns "$dns" --arg clock "$clock" \
      '{time:$time,interface:$iface,interface_mtu:$mtu,path_probe_payload:$payload,icmp:$icmp,tcp_connect:$tcp,https:$https,dns:$dns,clock_sync:$clock}' \
      | write_file "$NETDOCTOR_STATE" 0640 "root:root"
  fi
  write_file "$NETDOCTOR_CLIENT" 0755 "root:root" <<'EOF'
#!/usr/bin/env bash
set -u
host="${1:-example.com}"; port="${2:-443}"
printf 'ICMP: '; ping -c1 -W2 "$host" >/dev/null 2>&1 && echo PASS || echo FAIL
printf 'DNS: '; getent hosts "$host" >/dev/null 2>&1 && echo PASS || echo FAIL
printf 'TCP: '; timeout 8 bash -c "cat < /dev/null > /dev/tcp/$host/$port" >/dev/null 2>&1 && echo PASS || echo FAIL
printf 'TLS: '; curl -fsSI --connect-timeout 5 --max-time 10 "https://$host:$port/" >/dev/null 2>&1 && echo PASS || echo FAIL
printf 'MTU: '; ping -M do -c1 -W2 -s 1400 "$host" >/dev/null 2>&1 && echo PASS || echo FAIL
EOF
}

net_doctor_revert() {
  check_root
  if [[ -s "${DATA_DIR}/netdoctor-firewall.v4" ]] && command -v iptables-restore >/dev/null 2>&1; then
    iptables-restore < "${DATA_DIR}/netdoctor-firewall.v4" || warn "بازگردانی فایروال ناموفق بود"
  fi
  ok "تغییرات اختصاصی Network doctor برگشت داده شد."
}

menu_turbo()       { brand_header; turbo_apply; read -r -p "Enter برای بازگشت..." _ || true; }
menu_net_doctor()  { brand_header; run_net_doctor false; read -r -p "Enter برای بازگشت..." _ || true; }

menu_status() {
  brand_header
  if [[ -x "$CTL_PATH" ]]; then
    "$CTL_PATH" status || true
    echo
    "$CTL_PATH" test all || true
  else
    echo "MAXNET6G: هنوز نصب نشده است."
  fi
  read -r -p "Enter برای بازگشت..." _ || true
}

# آپدیت امن: پورت‌ها و EgressRegion از mapping فعلی خوانده می‌شوند و تغییر نمی‌کنند.
update_project() {
  CHANGED_INSTANCES=(); OK_LIST=(); FAIL_LIST=(); BINARY_CHANGED=false
  local old_binary="$BIN_PATH" backup_binary="" outdir cc st rollback_dir="" f
  local -a rollback_units=()
  step "MAXNET6G update: بررسی سیستم"
  check_root; check_arch; check_os; validate_config
  [[ -f "$MAPPING_FILE" ]] || die "mapping موجود نیست؛ ابتدا --install را اجرا کنید"
  WORK_TMP="$(mktemp -d)"
  setup_user_dirs
  allocate_ports
  for cc in "${COUNTRIES[@]}"; do
    [[ -n "${SOCKS_PORT[$cc]:-}" && -n "${HTTP_PORT[$cc]:-}" ]] ||
      die "mapping برای ${cc} ناقص است؛ update متوقف شد"
  done
  if [[ -f "$old_binary" && "$DRY_RUN" != true ]]; then
    backup_binary="${CONF_DIR}/backups/$(date +%Y%m%d-%H%M%S)/$(basename "$old_binary")"
    install -d -m 0700 -o root -g root "$(dirname "$backup_binary")"
    cp -a "$old_binary" "$backup_binary"
  fi
  rollback_dir="${WORK_TMP}/rollback"
  install -d -m 0700 "$rollback_dir"
  cp -a "$CONF_DIR" "$rollback_dir/conf"
  shopt -s nullglob
  rollback_units=("${SYSTEMD_DIR}/${SERVICE_PREFIX}"??.service "${SYSTEMD_DIR}/psiphon-healthcheck.service" "${SYSTEMD_DIR}/psiphon-healthcheck.timer" "${LOGROTATE_FILE}")
  for f in "${rollback_units[@]}"; do [[ -e "$f" ]] && cp -a "$f" "$rollback_dir/"; done
  shopt -u nullglob
  FORCE_DOWNLOAD=true
  install_binary
  write_configs
  write_mapping
  write_units
  write_ctl_conf; write_ctl; write_timer; write_logrotate
  write_bot_files
  if ! $BINARY_CHANGED; then
    run_net_doctor true
    ok "باینری تغییری نکرد؛ سرویس‌های در حال اجرا دست‌نخورده ماندند"
    return 0
  fi
  run systemctl daemon-reload
  outdir="${WORK_TMP}/update-health"; mkdir -p "$outdir"
  for cc in "${COUNTRIES[@]}"; do
    if systemctl is-active --quiet "${SERVICE_PREFIX}${cc}.service" 2>/dev/null; then
      log "update restart ${SERVICE_PREFIX}${cc}.service"
      systemctl restart "${SERVICE_PREFIX}${cc}.service"
      sleep "$START_STAGGER_SEC"
      rm -f "${outdir}/${cc}"
      health_wait_one "$cc" "${SOCKS_PORT[$cc]}" "$outdir" || true
      st="$(cut -d'|' -f1 "${outdir}/${cc}" 2>/dev/null || echo FAIL)"
      if [[ "$st" != "OK" ]]; then
        warn "سلامت ${cc} پس از آپدیت شکست خورد؛ rollback باینری"
        [[ -n "$backup_binary" && -f "$backup_binary" ]] &&
          install -m 0755 -o root -g root "$backup_binary" "$old_binary"
        rm -rf -- "$CONF_DIR"
        cp -a "$rollback_dir/conf" "$CONF_DIR"
        for f in "${SYSTEMD_DIR}/${SERVICE_PREFIX}"??.service; do [[ -e "$f" ]] && rm -f -- "$f"; done
        for f in "$rollback_dir"/psiphon-*.service "$rollback_dir"/psiphon-healthcheck.service "$rollback_dir"/psiphon-healthcheck.timer "$rollback_dir"/logrotate.d; do
          [[ -e "$f" ]] || continue
          case "$(basename "$f")" in
            psiphon-*.service|psiphon-healthcheck.timer|psiphon-healthcheck.service) cp -a "$f" "$SYSTEMD_DIR/" ;;
            psiphon) cp -a "$f" "$LOGROTATE_FILE" ;;
          esac
        done
        systemctl daemon-reload
        for cc in "${COUNTRIES[@]}"; do
          systemctl restart "${SERVICE_PREFIX}${cc}.service" || true
          sleep "$START_STAGGER_SEC"
        done
        die "آپدیت rollback شد؛ سرویس‌ها با باینری قبلی restart شدند"
      fi
    fi
  done
  run_net_doctor true
  ok "آپدیت MAXNET6G با موفقیت انجام شد"
}

# منوی تعاملی اصلی
interactive_menu() {
  while true; do
    brand_header
    echo "1) Install project"
    echo "2) Update project"
    echo "3) Telegram bot server management"
    echo "4) Turbo mode"
    echo "5) Network doctor"
    echo "6) Status"
    echo "7) Uninstall"
    echo "0) Exit"
    printf '\nSelect [0-7]: '
    local choice
    read -r choice || exit 0
    case "$choice" in
      1) MODE="install"; run_install ;;
      2) MODE="update"; update_project ;;
      3) menu_telegram_bot ;;
      4) menu_turbo ;;
      5) menu_net_doctor ;;
      6) menu_status ;;
      7) MODE="uninstall"; do_uninstall ;;
      0) exit 0 ;;
      *) warn "گزینه نامعتبر است" ;;
    esac
  done
}

# =============================================================================
# حالت --uninstall: حذف کامل (با تأیید)
# =============================================================================
do_uninstall() {
  check_root
  echo "${C_RED}${C_BLD}هشدار:${C_RST} همه سرویس‌های psiphon، کانفیگ‌ها، data، لاگ‌ها، باینری، psiphon-ctl و یوزر ${PSIPHON_USER} حذف می‌شوند."
  if ! $ASSUME_YES && ! $DRY_RUN; then
    local ans
    read -r -p "برای ادامه بنویسید yes: " ans
    [[ "$ans" == "yes" ]] || { log "لغو شد"; exit 0; }
  fi

  run systemctl disable --now psiphon-healthcheck.timer 2>/dev/null || true
  run systemctl stop psiphon-healthcheck.service 2>/dev/null || true
  local f unit
  for f in "${SYSTEMD_DIR}/${SERVICE_PREFIX}"??.service; do
    [[ -e "$f" ]] || continue
    unit="$(basename "$f")"
    run systemctl disable --now "$unit" 2>/dev/null || true
    run rm -f "$f"
  done
  run rm -f "${SYSTEMD_DIR}/psiphon-healthcheck.service" "${SYSTEMD_DIR}/psiphon-healthcheck.timer"
  run systemctl daemon-reload
  run systemctl reset-failed 2>/dev/null || true

  if $MANAGE_UFW && command -v ufw >/dev/null && [[ -f "$FIREWALL_STATE" ]]; then
    grep -qx socks "$FIREWALL_STATE" && run ufw delete deny proto tcp from any to any port "${SOCKS_PORT_BASE}:$(( SOCKS_PORT_BASE + MAX_INSTANCES - 1 ))" 2>/dev/null || true
    grep -qx http "$FIREWALL_STATE" && run ufw delete deny proto tcp from any to any port "${HTTP_PORT_BASE}:$(( HTTP_PORT_BASE + MAX_INSTANCES - 1 ))" 2>/dev/null || true
    while IFS=: read -r kind port; do
      [[ "$kind" == port && "$port" =~ ^[0-9]+$ ]] || continue
      run ufw delete deny proto tcp from any to any port "$port" 2>/dev/null || true
    done < "$FIREWALL_STATE"
  fi

  run rm -f "$CTL_PATH" "$LOGROTATE_FILE" "$INSTALL_LOG" /run/psiphon-healthcheck.lock
  local bot_unit
  for bot_unit in psiphon-bot.service psiphon-bot-watcher.service psiphon-bot-watcher.timer psiphon-bot-ip-refresh.service psiphon-bot-ip-refresh.timer psiphon-bot-daily-test.timer psiphon-bot-daily-test.service; do
    run systemctl disable --now "$bot_unit" 2>/dev/null || true
  done
  run rm -f "$BOT_SERVICE" "$BOT_WATCHER_SERVICE" "$BOT_WATCHER_TIMER" "$BOT_REFRESH_SERVICE" "$BOT_TIMER" "$BOT_DAILY_SERVICE" "$BOT_DAILY_TIMER" /usr/local/bin/psiphon-ip-refresh "$SELF_INSTALL_PATH" "$BOT_SCRIPT" /run/lock/maxnet6g-*.lock
  run rm -rf /run/maxnet6g-bot
  # Turbo و drop-inهای اختصاصی نیز باید همراه نصب حذف شوند.
  run rm -f "$TURBO_SYSCTL" "$TURBO_MANAGER_DROPIN"
  for f in "${SYSTEMD_DIR}/${SERVICE_PREFIX}"??.service.d/99-psiphon-turbo.conf; do [[ -e "$f" ]] && run rm -f -- "$f"; done
  for d in "${SYSTEMD_DIR}/${SERVICE_PREFIX}"??.service.d; do [[ -d "$d" ]] && run rmdir -- "$d" 2>/dev/null || true; done
  run rm -rf "${CONF_DIR:?}" "${DATA_DIR:?}" "${LOG_DIR:?}" "${INSTALL_DIR:?}"
  run systemctl daemon-reload
  if id -u "$PSIPHON_USER" >/dev/null 2>&1; then
    run userdel "$PSIPHON_USER" || warn "حذف یوزر ${PSIPHON_USER} ناموفق بود"
  fi
  ok "حذف کامل انجام شد"
}

# =============================================================================
# مرحله 14: گزارش نهایی
# =============================================================================
summary() {
  echo
  echo "${C_BLD}==================== خلاصه ====================${C_RST}"
  if $DRY_RUN; then
    echo "حالت dry-run: هیچ تغییری اعمال نشد."
  else
    echo "تعداد کل : ${#COUNTRIES[@]}"
    echo "${C_GRN}OK       : ${#OK_LIST[@]}${C_RST} ${OK_LIST[*]:-}"
    echo "${C_RED}FAIL     : ${#FAIL_LIST[@]}${C_RST} ${FAIL_LIST[*]:-}"
  fi
  echo "Mapping  : ${MAPPING_FILE}  (JSON: ${CONF_DIR}/mapping.json)"
  echo "لاگ نصب  : ${INSTALL_LOG}"
  echo
  echo "استفاده:"
  echo "  psiphon-ctl list | status | test all | test DE | restart FR | logs NL -f"
  echo "  curl --socks5-hostname 127.0.0.1:<SOCKS_PORT> ${TEST_URL}"
  echo "  Health-check خودکار: systemctl list-timers psiphon-healthcheck.timer"
  echo "${C_BLD}================================================${C_RST}"
}

# =============================================================================
# اجرای اصلی
# =============================================================================
run_install() {
  CHANGED_INSTANCES=(); OK_LIST=(); FAIL_LIST=(); BINARY_CHANGED=false
  MODE="install"
  setup_logging
  WORK_TMP="$(mktemp -d)"
  step "1) بررسی root، معماری و سیستم‌عامل";   check_root; check_arch; check_os
  step "2) پیش‌نیازها";                         install_prereqs
  step "اعتبارسنجی پیکربندی";                  validate_config
  step "4) یوزر و دایرکتوری‌ها";                setup_user_dirs
  step "3) باینری psiphon-tunnel-core";        install_binary
  step "5) تخصیص پورت و کانفیگ‌ها";             allocate_ports; write_configs
  step "9) فایل mapping";                       write_mapping
  step "6) سرویس‌های systemd";                  prune_removed; write_units; start_instances
  step "7-8) تست سلامت";                        run_health_checks
  step "10) فایروال و تأیید listen لوکال";      setup_firewall; verify_listen
  step "11) psiphon-ctl";                       write_ctl_conf; write_ctl
  step "12) تایمر health-check";                write_timer
  step "13) logrotate";                         write_logrotate
  step "14) Telegram bot files";                write_bot_files
  step "Network doctor سبک";                    run_net_doctor true
  summary
}

main() {
  if [[ "$MODE" == "turbo" ]]; then setup_logging; turbo_apply; exit 0; fi
  if [[ "$MODE" == "turbo-revert" ]]; then setup_logging; turbo_revert; exit 0; fi
  if [[ "$MODE" == "net-doctor" ]]; then setup_logging; check_root; run_net_doctor false; exit 0; fi
  if [[ "$MODE" == "net-doctor-revert" ]]; then setup_logging; net_doctor_revert; exit 0; fi
  if [[ "$MODE" == "bot-setup" ]]; then
    setup_logging
    bot_setup
    exit 0
  fi
  if [[ "$MODE" == "status" ]]; then
    brand_header
    if [[ -x "$CTL_PATH" ]]; then
      "$CTL_PATH" status || true
      "$CTL_PATH" test all || true
    else
      echo "MAXNET6G: هنوز نصب نشده است."
    fi
    exit 0
  fi
  show_splash
  if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
    INTERACTIVE_MENU=true
    interactive_menu
  elif [[ "$MODE" == "uninstall" ]]; then
    setup_logging
    WORK_TMP="$(mktemp -d)"
    do_uninstall
  elif [[ "$MODE" == "update" ]]; then
    setup_logging
    update_project
  else
    run_install
  fi
}

main "$@"
