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

SCRIPT_VERSION="3.2.0-p1"
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
  local rc=$? line=${1:-?} cmd=${2:-unknown}
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
  local -A used_offset=()
  local cc s h off
  # خواندن mapping قبلی
  if [[ -f "$MAPPING_FILE" ]]; then
    while read -r cc s h; do
      [[ -z "${cc:-}" || "$cc" == \#* ]] && continue
      [[ "$s" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || continue
      off=$(( s - SOCKS_PORT_BASE ))
      if (( off >= 0 && off < MAX_INSTANCES && h == HTTP_PORT_BASE + off )); then
        SOCKS_PORT[$cc]=$s; HTTP_PORT[$cc]=$h
      fi
    done < <(sed 's/[[:space:]]*->[[:space:]]*/ /g' "$MAPPING_FILE")
  fi
  # فقط کشورهای فعلی نگه داشته می‌شوند
  local -A keep_s=() keep_h=()
  for cc in "${COUNTRIES[@]}"; do
    if [[ -n "${SOCKS_PORT[$cc]:-}" ]]; then
      keep_s[$cc]=${SOCKS_PORT[$cc]}; keep_h[$cc]=${HTTP_PORT[$cc]}
      used_offset[$(( SOCKS_PORT[$cc] - SOCKS_PORT_BASE ))]=1
    fi
  done
  SOCKS_PORT=(); HTTP_PORT=()
  for cc in "${!keep_s[@]}"; do SOCKS_PORT[$cc]=${keep_s[$cc]}; HTTP_PORT[$cc]=${keep_h[$cc]}; done

  # کشورهای جدید: اولین offset آزاد
  for cc in "${COUNTRIES[@]}"; do
    [[ -n "${SOCKS_PORT[$cc]:-}" ]] && continue
    off=0
    while (( off < MAX_INSTANCES )); do
      if [[ -z "${used_offset[$off]:-}" ]] \
         && ! port_in_use_by_other "$(( SOCKS_PORT_BASE + off ))" \
         && ! port_in_use_by_other "$(( HTTP_PORT_BASE + off ))"; then
        break
      fi
      off=$(( off + 1 ))
    done
    (( off < MAX_INSTANCES )) || die "پورت آزاد برای ${cc} پیدا نشد"
    used_offset[$off]=1
    SOCKS_PORT[$cc]=$(( SOCKS_PORT_BASE + off ))
    HTTP_PORT[$cc]=$(( HTTP_PORT_BASE + off ))
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
  local cc
  for cc in "$@"; do
    rm -f "${outdir}/${cc}"
    health_wait_one "$cc" "${SOCKS_PORT[$cc]}" "$outdir" &
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
# MAXNET6G Telegram bot v3.2.0-p1 (bash + curl + jq)
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
VERSION="3.2.0-p1"
OFFSET_FILE="${DATA}/telegram-bot.offset"
LAST_TESTS="${DATA}/last-tests.json"

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
settings_load() {
  local k v
  [[ -r "$SETTINGS" ]] || return 0
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Z_]+$ ]] || continue
    v="${v%\"}"; v="${v#\"}"
    [[ "$v" =~ ^[A-Za-z0-9_.:/?=\&%+-]*$ ]] || continue
    case "$k" in
      BTN_STYLE|API_RETRIES|API_BACKOFF|API_TIMEOUT|TEST_PARALLEL|TEST_TIMEOUT|GEO_URL|LAT_URL|LAT_SAMPLES|\
      SPEED_URL|SPEED_TIMEOUT|STRICT_COUNTRY_MATCH|PENDING_TTL|CONFIRM_TTL|PAGE_SIZE|PAGE_COLS) printf -v "$k" '%s' "$v" ;;
    esac
  done < "$SETTINGS"
}
settings_load

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

# run_all_tests [CC...] → آرایه JSON مرتب بر اساس score؛ disabledها رد می‌شوند
run_all_tests() {
  local tmp cc list=("$@")
  (( ${#list[@]} )) || mapfile -t list < <(enabled_locations)
  tmp="$(mktemp -d "${RUN}/tests.XXXXXX")"
  for cc in "${list[@]}"; do
    is_disabled "$cc" && continue
    test_location "$cc" > "${tmp}/${cc}.json" &
    while (( $(jobs -rp | wc -l) >= TEST_PARALLEL )); do wait -n 2>/dev/null || true; done
  done
  wait 2>/dev/null || true
  if compgen -G "${tmp}/*.json" >/dev/null; then
    jq -sc 'sort_by(-.score)' "${tmp}"/*.json
  else
    echo '[]'
  fi
  rm -rf -- "$tmp"
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
# jobها: پس‌زمینه + flock؛ با systemd-run تا restart ربات (مثلاً در update) قطعشان نکند
# =============================================================================
job_lock_key() { case "$1" in update|turbo|doctor) echo sys ;; *) echo "$1" ;; esac; }
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
    restart) job_restart "$mid" "$@" ;;
    update)  job_installer "$mid" update --update "🟠 آپدیت" "" ;;
    turbo)   job_installer "$mid" turbo --turbo "🟣 Turbo" "${DATA}/turbo-last.json" ;;
    doctor)  job_installer "$mid" doctor --net-doctor "🟣 Network doctor" "${DATA}/netdoctor-last.json" ;;
    ips)     job_ips "$mid" ;;
  esac
}

job_tests() {
  local mid=$1 target=${2:-all} res txt ok fail deg skipped
  if [[ "$target" == all ]]; then
    res="$(run_all_tests)"
    jq -c --arg t "$(date -Is)" '{ts:$t, results:.}' <<<"$res" > "${LAST_TESTS}.tmp" && mv -f "${LAST_TESTS}.tmp" "$LAST_TESTS"
    ok="$(jq '[.[]|select(.state=="ok")]|length' <<<"$res")"
    deg="$(jq '[.[]|select(.state=="degraded")]|length' <<<"$res")"
    fail="$(jq '[.[]|select(.state=="fail")]|length' <<<"$res")"
    skipped="$(grep -cvE '^[[:space:]]*(#|$)' "$DISABLED_FILE" 2>/dev/null || echo 0)"
    txt="${HDR}🟢 <b>پینگ همه لوکیشن‌ها</b>
🟢 ${ok}  🟡 ${deg}  🔴 ${fail}  ⚪ رد‌شده: ${skipped}

<pre>   CC SCR     LAT  SPEED CO REASON
$(trunc "$(fmt_table "$res")" 3300)</pre>
<i>$(date '+%F %T')</i>"
    job_finish tests "$mid" "$txt" "$( { printf '🔁 تست مجدد|ping:all|success;;🗺 انتخاب کشور|pick:ping:0\n'; nav pg; } | kb)"
  else
    res="$(test_location "$target")"
    txt="${HDR}$(fmt_single "$res")
<i>$(date '+%F %T')</i>"
    job_finish tests "$mid" "$txt" "$( { printf '🔁 تست مجدد|ping:%s|success;;🔴 ریستارت این لوکیشن|restart:%s|danger\n' "$target" "$target"; nav "pick:ping:0"; } | kb)"
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
🟡 تنظیمات|soon:settings;;🔵 IPها|ip|primary
🔵 لاگ‌ها|lg|primary;;🔵 گزارش ۲۴ساعته|soon:report
🟣 پیش‌بینی خرابی|soon:predict;;⚫ بستن|x
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
IP خروجی، کشور، latency، سرعت (~1MB) و امتیاز ۰ تا ۱۰۰." "$( { printf '🌍 همه لوکیشن‌ها|ping:all|success;;🗺 انتخاب کشور|pick:ping:0|primary\n⌨️ تایپ کد کشور|in:ping\n'; nav m; } | kb)" "$1"
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
  case "$act" in ping) back=pg; title="🟢 پینگ: کشور را انتخاب کن";; restart) back=rs; title="🔴 ریستارت: کشور را انتخاب کن";; *) back=m; title="🔵 لاگ‌ها: کشور را انتخاب کن";; esac
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
نتیجه همین‌جا نمایش داده می‌شود." "$(nav m | kb)" "$mid"
  job_run "$name" "$mid" "$@" || edit "${HDR}⚠️ اجرای job ممکن نشد." "$(nav m | kb)" "$mid"
}

screen_input_prompt() { # mid act
  set_pending "$2" "$1"
  edit "${HDR}⌨️ کد دوحرفی کشور را بفرست (مثلاً <code>NL</code>).
برای لغو: /cancel" "$(nav "$( [[ $2 == ping ]] && echo pg || { [[ $2 == restart ]] && echo rs || echo m; } )" | kb)" "$1"
}

# =============================================================================
# routing
# =============================================================================
do_action() { # mid action arg  (بعد از تأیید یا مستقیم)
  local mid=$1 act=$2 arg=${3:-}
  if [[ "${arg,,}" == all ]]; then arg=all; else arg=${arg^^}; fi
  case "$act" in
    ping)    [[ "$arg" == all ]] || valid_cc "$arg" || { edit "${HDR}⚠️ کشور نامعتبر: $(esc "$arg")" "$(nav pg | kb)" "$mid"; return; }
             screen_busy_or_start "$mid" tests "تست ${arg}" "$arg" ;;
    restart) screen_busy_or_start "$mid" restart "ریستارت ${arg}" "$arg" ;;
    update)  screen_busy_or_start "$mid" update "آپدیت" ;;
    turbo)   screen_busy_or_start "$mid" turbo "Turbo" ;;
    doctor)  screen_busy_or_start "$mid" doctor "Network doctor" ;;
  esac
}

handle_callback() { # cbid mid data
  local cbid=$1 mid=$2 data=$3 a b c
  IFS=':' read -r a b c _ <<<"$data"
  [[ "$a" == soon ]] && { answer_cb "$cbid" "🚧 به‌زودی"; return; }
  [[ "$a" == nop ]]  && { answer_cb "$cbid"; return; }
  local jn=""
  case "$a" in ping) jn=tests ;; ip) jn=ips ;; y) case "$b" in restart|update|turbo|doctor) jn=$b ;; esac ;; esac
  if [[ -n "$jn" ]] && job_busy "$jn"; then answer_cb "$cbid" "⏳ این کار در حال اجراست…"; return; fi
  answer_cb "$cbid"
  clear_pending
  set_owner "$mid" nav
  case "$a" in
    m)       screen_menu "$mid" ;;
    st)      screen_status "$mid" ;;
    pg)      screen_ping_menu "$mid" ;;
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
    y)       local t=${data##*:}
             if [[ ! "$t" =~ ^[0-9]+$ ]] || (( $(now) - t > CONFIRM_TTL )); then
               edit "${HDR}⌛ تأیید منقضی شد. دوباره امتحان کن." "$(nav m | kb)" "$mid"; return
             fi
             case "$b" in
               restart) [[ "$c" == ALL ]] && c=all; { [[ "$c" == all ]] || valid_cc "$c"; } && do_action "$mid" restart "$c" ;;
               update|turbo|doctor) do_action "$mid" "$b" ;;
             esac ;;
    x)       delete_msg "$mid" || edit "✖️ منو بسته شد. برای باز کردن: /menu" "" "$mid" ;;
    *)       screen_menu "$mid" ;;
  esac
}

new_screen() { # پیام خالی می‌سازد و message_id برمی‌گرداند
  send "${HDR}⏳" "" | jq -r '.result.message_id // empty'
}

handle_text() { # text
  local text=$1 cmd arg p kind pmid mid
  cmd="${text%% *}"; cmd="${cmd%@*}"; arg="${text#"${text%% *}"}"; arg="${arg# }"
  if [[ "$text" != /* ]] && p="$(get_pending)"; then
    read -r kind pmid <<<"$p"; clear_pending
    arg="$(tr -d '[:space:]' <<<"$text")"
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
    /ping)    mid="$(new_screen)" && [[ -n "$mid" ]] && { [[ -n "$arg" ]] && do_action "$mid" ping "${arg,,}" || screen_ping_menu "$mid"; } ;;
    /restart) mid="$(new_screen)" && [[ -n "$mid" ]] && {
                if [[ "${arg,,}" == all ]] || valid_cc "$arg"; then screen_confirm "$mid" restart "${arg^^}" "🔴 ریستارت <b>${arg^^}</b>" rs
                else screen_restart_menu "$mid"; fi; } ;;
    /logs)    mid="$(new_screen)" && [[ -n "$mid" ]] && { valid_cc "$arg" && screen_logs "$mid" "$arg" || screen_pick "$mid" logs 0; } ;;
    /ips)     mid="$(new_screen)" && [[ -n "$mid" ]] && screen_busy_or_start "$mid" ips "رتبه‌بندی IPها" ;;
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
    [[ "$chat" == "$ADMIN_CHAT_ID" ]] || continue
    data="${data//\\n/ }"; data="${data//\\t/ }"
    if [[ -n "$cbid" ]]; then handle_callback "$cbid" "$mid" "$data"
    elif [[ -n "$data" ]]; then handle_text "$data"; fi
  done < <(jq -r '.result[] | [ (.update_id|tostring),
            ((.message.chat.id // .callback_query.message.chat.id // "")|tostring),
            ((.callback_query.message.message_id // "")|tostring),
            (.callback_query.id // ""),
            (.callback_query.data // .message.text // "") ] | @tsv' 2>/dev/null <<<"$resp" || true)
done
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
SET_EOF
  fi
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
key_state() { awk -v k="$1" '$1==k{print $2}' "$STATE" 2>/dev/null || true; }
set_state() { local k=$1 v=$2 t=$3; awk -v k="$k" '$1!=k' "$STATE" > "${STATE}.tmp" 2>/dev/null || true; printf '%s %s %s\n' "$k" "$v" "$t" >> "${STATE}.tmp"; mv "${STATE}.tmp" "$STATE"; }
notify() {
  local key=$1 new=$2 msg=$3 old t
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
while read -r cc socks http; do
  [[ "$cc" == \#* || -z "$cc" ]] && continue
  [[ -r "$DIS" ]] && grep -qiE "^[[:space:]]*${cc}([[:space:]]|#|$)" "$DIS" && continue
  active="$(systemctl is-active "psiphon-${cc}.service" 2>/dev/null || true)"
  reason="service=${active}"
  probe="$(curl -sS --max-time 12 --socks5-hostname "127.0.0.1:${socks}" https://ipinfo.io/json 2>/dev/null || true)"
  country="$(jq -r '.country // "-"' <<<"$probe" 2>/dev/null || echo -)"
  if [[ "$active" == active && "$country" != "-" ]]; then
    notify "instance_${cc}" up "🟢 ${cc} up: country=${country}, port=${socks}"
  else
    [[ "$active" != active ]] && reason="${reason}; service unavailable"
    [[ "$country" == "-" ]] && reason="${reason}; SOCKS/HTTPS probe failed"
    notify "instance_${cc}" down "🔴 ${cc} down: country=${country}, port=${socks}, reason=${reason}"
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
  write_file "$BOT_WATCHER_TIMER" 0644 "root:root" <<EOF
# Generated by ${SCRIPT_NAME}
[Unit]
Description=${BRAND} watcher interval
[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
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
OnUnitActiveSec=6h
Persistent=true
[Install]
WantedBy=timers.target
EOF
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
  ok "ربات MAXNET6G فعال شد"
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
  fi

  run rm -f "$CTL_PATH" "$LOGROTATE_FILE" /run/psiphon-healthcheck.lock
  local bot_unit
  for bot_unit in psiphon-bot.service psiphon-bot-watcher.service psiphon-bot-watcher.timer psiphon-bot-ip-refresh.service psiphon-bot-ip-refresh.timer; do
    run systemctl disable --now "$bot_unit" 2>/dev/null || true
  done
  run rm -f "$BOT_SERVICE" "$BOT_WATCHER_SERVICE" "$BOT_WATCHER_TIMER" "$BOT_REFRESH_SERVICE" "$BOT_TIMER" /usr/local/bin/psiphon-ip-refresh "$SELF_INSTALL_PATH" /run/lock/maxnet6g-*.lock
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
  ok "حذف کامل انجام شد (لاگ نصب در ${INSTALL_LOG} نگه داشته شد)"
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
