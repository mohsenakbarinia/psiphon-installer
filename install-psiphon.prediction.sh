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

SCRIPT_VERSION="3.1.0-part3"
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

declare -A SP=() HP=(); ORDER=()
while read -r cc s h; do
  [[ -z "${cc:-}" || "$cc" == \#* ]] && continue
  SP[$cc]=$s; HP[$cc]=$h; ORDER+=("$cc")
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
  if [[ "$t" == "all" ]]; then printf '%s\n' "${ORDER[@]}"; return; fi
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
  done < <(test_many "${ORDER[@]}")
  for cc in "${bad[@]}"; do
    echo "$(date '+%F %T') $cc unhealthy -> restart" >> "$log"
    systemctl restart "${SERVICE_PREFIX}${cc}.service" || true
    sleep "$START_STAGGER_SEC"
  done
  echo "healthcheck done: total=${#ORDER[@]} restarted=${#bad[@]}"
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
# health-samples.jsonl is managed by psiphon-risk cleanup under flock:
# atomic timestamp pruning + hard 20 MiB cap, not unsafe copytruncate.
EOF
  write_file /etc/cron.hourly/psiphon-risk-cleanup 0755 "root:root" <<'RISK_CLEANUP_EOF'
#!/bin/sh
test ! -x /usr/local/bin/psiphon-risk || /usr/local/bin/psiphon-risk cleanup
RISK_CLEANUP_EOF
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
  write_risk_files
  write_file "$BOT_SCRIPT" 0750 "root:root" <<'BOT_EOF'
#!/usr/bin/env bash
# ربات تلگرام MAXNET6G، فقط bash/curl/jq
set -Eeuo pipefail
CONF="/etc/psiphon/telegram-bot.conf"
[[ -r "$CONF" ]] || exit 0
# shellcheck disable=SC1090
. "$CONF"
[[ "${BOT_ENABLED:-false}" == true ]] || exit 0
. /etc/psiphon/risk-lib.sh
STATE="/var/lib/psiphon/telegram-bot-state.json"
CTL="/usr/local/bin/psiphon-ctl"
BRAND="MAXNET6G"
LAST=0
RATE=3

trap 'exit 0' TERM INT
mkdir -p "$(dirname "$STATE")"; chmod 0750 "$(dirname "$STATE")"
api() {
  local method=$1 rc=0 cfg
  shift
  cfg="$(mktemp "${TMPDIR:-/tmp}/psiphon-telegram.XXXXXX")" || return 1
  chmod 0600 "$cfg"
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$BOT_TOKEN" "$method" > "$cfg"
  curl -fsS --retry 5 --retry-delay 2 --max-time 35 -X POST --config "$cfg" "$@" || rc=$?
  rm -f -- "$cfg"
  return "$rc"
}
send() {
  local text=$1; shift
  api sendMessage --data-urlencode "chat_id=${ADMIN_CHAT_ID}" \
    --data-urlencode "text=${text}" "$@" >/dev/null
}
header() { printf '🟦 %s\n\n' "$BRAND"; }
allowed() { [[ "${1:-}" == "$ADMIN_CHAT_ID" ]]; }
valid_country() { [[ "${1:-}" =~ ^[A-Za-z]{2}$ ]] && [[ -n "$(awk -v x="${1^^}" '$1==x{print $1}' /etc/psiphon/mapping.txt 2>/dev/null)" ]]; }
escape_arg() { [[ "${1:-}" =~ ^[A-Za-z]{2}$|^all$ ]]; }
status_text() { header; "$CTL" status 2>&1 | tail -n 120; }
ping_text() { header; printf '🟢 server TCP/HTTPS: '; curl -fsSI --max-time 8 https://example.com >/dev/null && echo UP || echo DOWN; }
logs_text() {
  local c=${1^^}
  valid_country "$c" || { send "$(header)⚠️ کشور نامعتبر"; return; }
  header; journalctl -u "psiphon-${c}.service" -n 40 --no-pager 2>&1 | tail -c 3500
}
ips_text() {
  header
  local out; out="$(/usr/local/bin/psiphon-ip-refresh report 2>&1 || true)"
  send "$(header)📡 رتبه‌بندی endpointها
${out}"
}
update_text() { local logf; logf="$(mktemp /var/lib/psiphon/update.XXXXXX)"; chmod 0600 "$logf"; send "$(header)🔄 شروع update"; /usr/local/bin/install-psiphon.sh --update >"$logf" 2>&1 && send "$(header)✅ update تمام شد" || send "$(header)⚠️ update شکست خورد"; rm -f -- "$logf"; }
turbo_text() {
  /usr/local/bin/install-psiphon.sh --turbo >/var/lib/psiphon/turbo.log 2>&1 || true
  local x=''; [[ -r /var/lib/psiphon/turbo-last.json ]] && x="$(jq -c . /var/lib/psiphon/turbo-last.json 2>/dev/null || true)"
  send "$(header)⚡ Turbo اجرا شد
${x:-نتیجه‌ای ثبت نشده است}"
}
doctor_text() {
  /usr/local/bin/install-psiphon.sh --net-doctor >/var/lib/psiphon/doctor.log 2>&1 || true
  local x=''; [[ -r /var/lib/psiphon/netdoctor-last.json ]] && x="$(jq -c . /var/lib/psiphon/netdoctor-last.json 2>/dev/null || true)"
  send "$(header)🩺 Network doctor
${x:-نتیجه‌ای ثبت نشده است}"
}
help_text() {
  api sendMessage --data-urlencode "chat_id=${ADMIN_CHAT_ID}" \
    --data-urlencode "text=$(header)دستورات:
/status /ping /ips
/restart <country|all>
/logs <country>
/update /turbo /netdoctor
/risk [CC] /settings
/help" \
    --data-urlencode 'reply_markup={"inline_keyboard":[[{"text":"📊 Status","callback_data":"status"},{"text":"📡 IPs","callback_data":"ips"}],[{"text":"🟢 Ping","callback_data":"ping"},{"text":"🩺 Doctor","callback_data":"doctor"}],[{"text":"🔮 پیش‌بینی خرابی","callback_data":"risk"},{"text":"⚙️ تنظیمات","callback_data":"settings"}]]}' >/dev/null
}
. /etc/psiphon/risk-bot-functions.sh
handle() {
  local chat=$1 text=$2 cmd arg
  allowed "$chat" || return 0
  (( $(date +%s) - LAST < RATE )) && return 0
  LAST=$(date +%s)
  cmd="${text%% *}"; arg="${text#"$cmd"}"; arg="${arg# }"
  case "$cmd" in
    /start|/help) help_text ;;
    /status) send "$(status_text)" ;;
    /ping) send "$(ping_text)" ;;
    /ips) ips_text ;;
    /restart)
      escape_arg "$arg" || { send "$(header)⚠️ آرگومان نامعتبر"; return; }
      send "$(header)🔄 restart staggered: ${arg^^}"; "$CTL" restart "${arg^^}" >/var/lib/psiphon/restart.log 2>&1 || true ;;
    /logs) logs_text "$arg" ;;
    /update) update_text ;;
    /turbo) turbo_text ;;
    /netdoctor) doctor_text ;;
    /risk)
      [[ -z "$arg" ]] || valid_country "$arg" || { send "⚠️ کشور نامعتبر"; return; }
      risk_menu "${arg^^}" ;;
    /settings) send "⚙️ تنظیمات" --data-urlencode 'reply_markup={"inline_keyboard":[[{"text":"🔮 پیش‌بینی خرابی","callback_data":"risksettings"}]]}' ;;
    /risksettings) risk_settings ;;
    /riskset) risk_handle_set "$arg" ;;
    /riskcooldown) risk_handle_set "RISK_COOLDOWN_MIN $arg" ;;
    /riskquiet) risk_handle_quiet "$arg" ;;
    /riskmute)
      valid_country "$arg" || { send "⚠️ کشور نامعتبر"; return; }
      risk_mute "${arg^^}"; send "🔇 هشدار پیش‌بینی ${arg^^} برای یک ساعت خاموش شد" ;;
    /risktest)
      [[ "$arg" == all ]] || valid_country "$arg" || { send "⚠️ کشور نامعتبر"; return; }
      /usr/local/bin/psiphon-risk test "${arg^^}" >/dev/null 2>&1 || true
      [[ "$arg" != all ]] || arg=''
      risk_menu "${arg^^}" ;;
    /riskresetask)
      send "تاریخچه و baseline پیش‌بینی پاک شوند؟" --data-urlencode 'reply_markup={"inline_keyboard":[[{"text":"بله، پاک شود","callback_data":"riskreset"},{"text":"لغو","callback_data":"risksettings"}]]}' ;;
    /riskreset) risk_reset; send "✅ baseline پاک شد؛ تا دو ساعت داده کافی نیست" ;;
  esac
}
offset=0
send "$(header)🟢 bot started"
while :; do
  resp="$(api getUpdates --data-urlencode "timeout=45" --data-urlencode "offset=${offset}" || true)"
  jq -e '.ok == true' >/dev/null <<<"$resp" 2>/dev/null || { sleep 5; continue; }
  while IFS=$'\t' read -r id chat text; do
    [[ -n "${id:-}" ]] || continue
    offset=$((id + 1))
    [[ -n "${chat:-}" && -n "${text:-}" ]] && handle "$chat" "$text"
  done < <(jq -r '.result[] | [(.update_id|tostring),((.message.chat.id // .callback_query.message.chat.id)|tostring),(.message.text // ("/"+(.callback_query.data // "")))] | @tsv' <<<"$resp" 2>/dev/null || true)
done
BOT_EOF

  write_file "$BOT_WATCHER" 0750 "root:root" <<'WATCH_EOF'
#!/usr/bin/env bash
# دیده‌بان ربات، بدون تکیه بر ICMP برای تشخیص قطعی سرور
set -Eeuo pipefail
CONF="/etc/psiphon/telegram-bot.conf"
[[ -r "$CONF" ]] || exit 0
. "$CONF"
. /etc/psiphon/risk-lib.sh
batch="$(mktemp /var/lib/psiphon/.watch-samples.XXXXXX)"
trap 'rm -f "$batch"' EXIT
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
while read -r cc socks http; do
  [[ "$cc" == \#* || -z "$cc" ]] && continue
  risk_probe "$cc" "$socks"
  printf '%s\n' "$RISK_PROBE_SAMPLE" >> "$batch"
  active="$RISK_PROBE_ACTIVE"
  reason="service=${active}"
  country="$RISK_PROBE_COUNTRY"
  if [[ "$active" == active && "$country" != "-" ]]; then
    notify "instance_${cc}" up "🟢 ${cc} up: country=${country}, port=${socks}"
  else
    [[ "$active" != active ]] && reason="${reason}; service unavailable"
    [[ "$country" == "-" ]] && reason="${reason}; SOCKS/HTTPS probe failed"
    notify "instance_${cc}" down "🔴 ${cc} down: country=${country}, port=${socks}, reason=${reason}"
  fi
done < "$MAP"
# Prediction must never prevent legacy down/up alerts from being delivered.
risk_ingest "$batch" || true
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
ReadWritePaths=${DATA_DIR} ${CONF_DIR}
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
  run systemctl enable --now psiphon-risk-daily.timer psiphon-risk-weekly.timer
  run systemctl try-restart psiphon-bot.service 2>/dev/null || true
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
  local token chat me risk_values
  read -r -s -p "Bot token: " token; echo
  read -r -p "Admin chat ID: " chat
  [[ "$token" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{20,}$ ]] || die "فرمت token نامعتبر است"
  [[ "$chat" =~ ^-?[0-9]{5,20}$ ]] || die "فرمت chat ID نامعتبر است"
  me="$(cfg="$(mktemp "${TMPDIR:-/tmp}/psiphon-telegram.XXXXXX")"; chmod 0600 "$cfg"; printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$token" > "$cfg"; curl -fsS --max-time 15 --config "$cfg" 2>/dev/null || true; rm -f -- "$cfg")"
  jq -e '.ok == true' <<<"$me" >/dev/null || die "اعتبارسنجی Telegram API شکست خورد"
  bot_send_test "$token" "$chat" || die "ارسال پیام آزمایشی شکست خورد"
  risk_values="$(grep '^RISK_[A-Z_]*=' "$BOT_CONF" 2>/dev/null || true)"
  backup_path "$BOT_CONF"
  write_file "$BOT_CONF" 0600 "root:root" <<EOF
# MAXNET6G Telegram credentials, root-only
BOT_ENABLED=true
BOT_TOKEN=${token}
ADMIN_CHAT_ID=${chat}
${risk_values}
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
  if [[ -f "$old_binary" && ! "$DRY_RUN" ]]; then
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
  for bot_unit in psiphon-bot.service psiphon-bot-watcher.service psiphon-bot-watcher.timer psiphon-bot-ip-refresh.service psiphon-bot-ip-refresh.timer psiphon-risk-daily.timer psiphon-risk-weekly.timer psiphon-risk-daily.service psiphon-risk-weekly.service; do
    run systemctl disable --now "$bot_unit" 2>/dev/null || true
  done
  run rm -f "$BOT_SERVICE" "$BOT_WATCHER_SERVICE" "$BOT_WATCHER_TIMER" "$BOT_REFRESH_SERVICE" "$BOT_TIMER" /usr/local/bin/psiphon-ip-refresh
  run rm -f /usr/local/bin/psiphon-risk /etc/cron.hourly/psiphon-risk-cleanup \
    "${SYSTEMD_DIR}/psiphon-risk-daily.timer" "${SYSTEMD_DIR}/psiphon-risk-daily.service" \
    "${SYSTEMD_DIR}/psiphon-risk-weekly.timer" "${SYSTEMD_DIR}/psiphon-risk-weekly.service"
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

# The self-contained prediction payload and main invocation follow below.

# =============================================================================
# 5-B: lightweight failure prediction (embedded payload, no downloads).
# =============================================================================
write_risk_files() {
  write_file "${CONF_DIR}/risk-lib.sh" 0640 "root:root" <<'PAYLOAD_risk_lib_sh_END'
#!/usr/bin/env bash
# Shared prediction engine. No network probes in evaluation; caller supplies samples.
RISK_DIR="${RISK_DIR:-/var/lib/psiphon}"
RISK_CONF="${RISK_CONF:-/etc/psiphon/telegram-bot.conf}"
RISK_MAP="${RISK_MAP:-/etc/psiphon/mapping.txt}"
RISK_AWK="${RISK_AWK:-/etc/psiphon/risk-metrics.awk}"
RISK_SAMPLES="$RISK_DIR/health-samples.jsonl"
RISK_STATE="$RISK_DIR/risk-state.json"
risk_load() {
  [[ ! -r "$RISK_CONF" ]] || . "$RISK_CONF"
  : "${RISK_ENABLED:=true}" "${RISK_SENSITIVITY:=Normal}" "${RISK_NOTIFY_LEVEL:=2}"
  : "${RISK_COOLDOWN_MIN:=30}" "${RISK_QUIET_START:=-1}" "${RISK_QUIET_END:=-1}"
  : "${RISK_AUTO_RESTART:=false}" "${RISK_AUTO_DEGRADE:=false}"
  : "${RISK_W_FAILURE:=35}" "${RISK_W_LATENCY:=20}" "${RISK_W_FLAP:=15}"
  : "${RISK_W_JITTER:=10}" "${RISK_W_SPEED:=10}" "${RISK_W_LOG:=10}"
  : "${RISK_FLAP_N:=4}" "${RISK_IP_CHANGES_N:=6}" "${RISK_LOG_N:=5}"
  : "${RISK_JITTER_MS:=150}" "${RISK_FAILURE_DELTA:=0.15}" "${RISK_LOG_INTERVAL:=600}"
}
risk_load
risk_init() (
  mkdir -p "$RISK_DIR"; chmod 0750 "$RISK_DIR"
  exec 6>"$RISK_DIR/risk.lock"; flock -w 30 6 || exit 1
  [[ -e "$RISK_SAMPLES" ]] || (umask 077; : > "$RISK_SAMPLES")
  [[ -e "$RISK_STATE" ]] || (umask 077; printf '{"locations":{}}\n' > "$RISK_STATE")
)
risk_probe() {
  # Exactly one HTTPS-over-SOCKS request, including DNS through SOCKS.
  local cc=$1 socks=$2 url=${3:-https://ipinfo.io/json} limit=${4:-12}
  local out elapsed rc=0 active restarts=0 good=0 ip country properties key value invocation=''
  out="$(curl -sS --max-time "$limit" --socks5-hostname "127.0.0.1:$socks" \
    -w $'\n%{time_total}' "$url" 2>/dev/null)" || rc=$?
  elapsed="${out##*$'\n'}"; RISK_PROBE_BODY="${out%$'\n'*}"
  active="$(systemctl is-active "psiphon-${cc}.service" 2>/dev/null || true)"
  properties="$(systemctl show "psiphon-${cc}.service" -p NRestarts -p InvocationID 2>/dev/null || true)"
  while IFS='=' read -r key value; do
    case "$key" in NRestarts) restarts=$value ;; InvocationID) invocation=$value ;; esac
  done <<<"$properties"
  [[ "$restarts" =~ ^[0-9]+$ ]] || restarts=0
  # Preserve the watcher's existing up/down criterion (a returned country).
  country="$(jq -r '.country // "-"' <<<"$RISK_PROBE_BODY" 2>/dev/null || echo -)"
  ip="$(jq -r '.ip // "-"' <<<"$RISK_PROBE_BODY" 2>/dev/null || echo -)"
  country="${country:--}"; ip="${ip:--}"
  [[ "$active" == active && "$country" != "-" && "$rc" == 0 ]] && good=1
  elapsed="$(awk -v x="$elapsed" -v rc="$rc" 'BEGIN {if(rc || x !~ /^[0-9]+([.][0-9]+)?$/) print "null"; else printf "%.3f",x*1000}')"
  RISK_PROBE_ACTIVE=$active; RISK_PROBE_COUNTRY=$country
  RISK_PROBE_SAMPLE="$(jq -cn --argjson ts "$(date +%s)" --arg cc "$cc" \
    --argjson ok "$good" --argjson latency "$elapsed" --arg ip "$ip" --arg country "$country" \
    --arg state "$active" --argjson restarts "$restarts" --arg invocation "$invocation" \
    '{ts:$ts,cc:$cc,ok:$ok,latency_ms:$latency,egress_ip:$ip,egress_country:$country,service_state:$state,restarts_count:$restarts,service_invocation_id:$invocation}')"
}
risk_trim_locked() {
  # All readers/writers/cleanup use a separate, stable lock, never the renamed inode.
  local now=$1 source=${2:-$RISK_SAMPLES} tmp count excess bytes
  tmp="$(mktemp "$RISK_DIR/.samples.XXXXXX")" || return 1
  # Canonical JSONL is validated at ingestion. Timestamp-only retention needs no
  # full JSON/date parsing for every historical record on every watcher run.
  LC_ALL=C awk -v cutoff="$((now-604800))" '
    match($0,/"ts":[[:space:]]*[0-9]+/) {
      t=substr($0,RSTART,RLENGTH); sub(/^[^:]*:[[:space:]]*/,"",t)
      if(t+0>=cutoff) print
    }' "$source" > "$tmp" || { rm -f "$tmp"; return 1; }
  bytes="$(wc -c < "$tmp")"
  # Cap at 20 MiB, retaining newest complete records. Do not copytruncate live JSONL.
  if ((bytes > 20971520)); then
    count="$(wc -l < "$tmp")"; excess=$((count * (bytes-20971520) / bytes + 1))
    tail -n "+$((excess+1))" "$tmp" > "${tmp}.cap"
    while (( $(wc -c < "${tmp}.cap") > 20971520 )); do
      tail -n +2 "${tmp}.cap" > "${tmp}.next"; mv "${tmp}.next" "${tmp}.cap"
    done
    mv "${tmp}.cap" "$tmp"
  fi
  chmod 0600 "$tmp"; mv -f "$tmp" "$RISK_SAMPLES"
}
risk_api() {
  local method=$1 cfg rc=0; shift
  [[ "${BOT_ENABLED:-false}" == true && -n "${BOT_TOKEN:-}" && -n "${ADMIN_CHAT_ID:-}" ]] || return 1
  cfg="$(mktemp "$RISK_DIR/.telegram.XXXXXX")" || return 1
  chmod 0600 "$cfg"
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$BOT_TOKEN" "$method" > "$cfg"
  curl -fsS --max-time 20 -X POST --config "$cfg" "$@" | jq -e '.ok == true' >/dev/null || rc=$?
  rm -f "$cfg"; return "$rc"
}
risk_flag() {
  local cc=$1 a b
  a=$(printf '%d' "'${cc:0:1}"); b=$(printf '%d' "'${cc:1:1}")
  printf "\\U$(printf '%08x' "$((127397+a))")\\U$(printf '%08x' "$((127397+b))")"
}
risk_best() {
  local best c
  best="$(jq -r --arg cc "$1" '.locations|to_entries|map(select(.key!=$cc and
    .value.enough and .value.ok==1 and .value.level==0 and (.value.degraded|not) and .value.score<30))|
    sort_by(.value.score,.value.latency_ms // 1e9)|.[0]|
    if .==null then "لوکیشن سالم با داده کافی موجود نیست" else
    "\(.key) (پینگ \(.value.latency_ms // "-")ms، ریسک \(.value.score)/100)" end' "$RISK_STATE")"
  c="${best:0:2}"
  if [[ "$c" =~ ^[A-Z]{2}$ ]]; then printf '%s %s\n' "$(risk_flag "$c")" "$best"
  else printf '%s\n' "$best"; fi
}
risk_buttons() {
  jq -cn --arg c "$1" '{inline_keyboard:[
    [{text:("♻️ ریستارت "+$c),callback_data:("restart "+$c)},{text:"🔁 تست فوری",callback_data:("risktest "+$c)}],
    [{text:"🔇 ۱ ساعت سکوت",callback_data:("riskmute "+$c)},{text:"📈 جزئیات",callback_data:("risk "+$c)}]]}'
}
risk_quiet() {
  local hour; hour=$((10#$(date +%H)))
  (( RISK_QUIET_START >= 0 && RISK_QUIET_END >= 0 )) || return 1
  if ((RISK_QUIET_START < RISK_QUIET_END)); then
    ((hour >= RISK_QUIET_START && hour < RISK_QUIET_END))
  elif ((RISK_QUIET_START > RISK_QUIET_END)); then
    ((hour >= RISK_QUIET_START || hour < RISK_QUIET_END))
  else return 1; fi
}
risk_evaluate_locked() {
  local now=$1 work cc st last logs cached scale=1
  work="$(mktemp -d "$RISK_DIR/.risk-eval.XXXXXX")" || return 1
  cp "$RISK_STATE" "$work/old.json"
  : > "$work/logs.tsv"
  [[ "$RISK_SENSITIVITY" != High ]] || scale=0.75
  [[ "$RISK_SENSITIVITY" != Low ]] || scale=1.5
  while read -r cc _; do
    [[ "$cc" =~ ^[A-Z]{2}$ ]] || continue
    read -r last cached < <(jq -r --arg c "$cc" '[.locations[$c].log_checked//0,.locations[$c].log_errors//0]|@tsv' "$work/old.json")
    if ((now-last >= RISK_LOG_INTERVAL)); then
      # Read at most 2,000 records/location every ten minutes. No extra network traffic.
      logs="$(journalctl -u "psiphon-${cc}.service" --since "@$((now-1800))" -n 2000 \
        --no-pager -o cat 2>/dev/null | awk 'tolower($0) ~ /reconnect|tunnel.*fail|failed.*tunnel/ {n++} END{print n+0}' || true)"
      [[ "$logs" =~ ^[0-9]+$ ]] || logs=0
      last=$now
    else logs=$cached; fi
    printf '%s\t%s\t%s\n' "$cc" "$logs" "$last" >> "$work/logs.tsv"
  done < "$RISK_MAP"
  jq -r '[.ts,.cc,.ok,(.latency_ms//-1),(.speed_mbps//-1),(.egress_ip//"-"),
    (.egress_country//"-"),(.service_state//"-"),(.restarts_count//0),
    (.service_invocation_id//"")]|@tsv' "$RISK_SAMPLES" |
    LC_ALL=C sort -k2,2 -k1,1n |
    LC_ALL=C TZ=UTC awk -v now="$now" -v scale="$scale" -v flap_n="$RISK_FLAP_N" \
      -v ip_n="$RISK_IP_CHANGES_N" -v jitter_ms="$RISK_JITTER_MS" \
      -v fail_delta="$RISK_FAILURE_DELTA" -v log_n="$RISK_LOG_N" \
      -v wf="$RISK_W_FAILURE" -v wl="$RISK_W_LATENCY" -v wfl="$RISK_W_FLAP" \
      -v wj="$RISK_W_JITTER" -v ws="$RISK_W_SPEED" -v we="$RISK_W_LOG" \
      -f "$RISK_AWK" "$work/logs.tsv" - > "$work/metrics.tsv" || { rm -rf "$work"; return 1; }
  jq -Rn '[inputs|split("\t")|{key:.[0],value:{
    enough:(.[1]=="1"),score:(.[2]|tonumber),raw_level:(.[3]|tonumber),
    latency_ms:(.[4]|tonumber),baseline_ms:(.[5]|tonumber),jitter_ms:(.[6]|tonumber),
    failure_pct:(.[7]|tonumber),baseline_failure_pct:(.[8]|tonumber),
    consecutive_failures:(.[9]|tonumber),flaps:(.[10]|tonumber),restarts:(.[11]|tonumber),
    ip_changes:(.[12]|tonumber),drift:(.[13]=="1"),log_errors:(.[14]|tonumber),
    log_checked:(.[15]|tonumber),recurring:(.[16]=="1"),reason:.[17],
    sparkline:.[18],failure_24h_pct:(.[19]|tonumber),failure_7d_pct:(.[20]|tonumber),
    ok:(.[21]|tonumber),ts:(.[22]|tonumber)}}]|from_entries' \
    < "$work/metrics.tsv" > "$work/metrics.json"
  jq --argjson now "$now" --slurpfile m "$work/metrics.json" --argjson auto "$RISK_AUTO_DEGRADE" '
    .locations as $old |
    .locations=($m[0]|with_entries(
      .key as $c | .value as $v | ($old[$c]//{}) as $p |
      .value=($p+$v |
        .candidate=$v.raw_level |
        .candidate_runs=(if $p.candidate==$v.raw_level then (($p.candidate_runs//0)+1) else 1 end) |
        .level=(if ($v.enough|not) then 0 elif .candidate_runs>=2 then $v.raw_level else ($p.level//0) end) |
        .critical_since=(if $v.enough and $v.score>=80 then
          (if ($p.critical_since//0)>0 then $p.critical_since else $now end) else 0 end) |
        .recovery_since=(if $v.enough and $v.score<30 and $v.ok==1 then
          (if ($p.recovery_since//0)>0 then $p.recovery_since else $now end) else 0 end) |
        .degraded=(if ($auto|not) then false elif $v.enough and $v.score>=60 then true
          elif .recovery_since>0 and $now-.recovery_since>=1800 then false else ($p.degraded//false) end) |
        .auto_restarts=(($p.auto_restarts//[])|map(select(.>($now-3600)))))))' \
    "$work/old.json" > "$work/new.json" || { rm -rf "$work"; return 1; }
  chmod 0600 "$work/new.json"; mv "$work/new.json" "$RISK_STATE"
  rm -rf "$work"
}
risk_state_update_locked() {
  local tmp; tmp="$(mktemp "$RISK_DIR/.state.XXXXXX")" || return 1
  jq "$@" "$RISK_STATE" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp"; mv -f "$tmp" "$RISK_STATE"
}
risk_commit_update() (
  exec 8>"$RISK_DIR/risk.lock"; flock -w 30 8 || exit 1
  risk_state_update_locked "$@"
)
risk_actions_locked() {
  local now=$1 cc score level enough runs last notified mute critical count previous=0 message reason label alt
  while IFS=$'\t' read -r cc score level enough runs last notified mute critical count; do
    [[ "$enough" == true ]] || continue
    if [[ "${BOT_ENABLED:-false}" == true ]] &&
      ((runs>=2 && level>=RISK_NOTIFY_LEVEL && now>=mute)) && ! risk_quiet &&
      { ((level>notified)) || ((now-last>=RISK_COOLDOWN_MIN*60)); }; then
      case "$level" in 1) label='🟡 مراقبت' ;; 2) label='🟠 بالا' ;; 3) label='🔴 بحرانی' ;; *) label='🟢 پایدار' ;; esac
      reason="$(jq -r --arg c "$cc" '.locations[$c].reason' "$RISK_STATE")"
      alt="$(risk_best "$cc")"
      message="⚠️ پیش‌بینی خرابی: $(risk_flag "$cc") $cc
ریسک: $score/100 ($label)
دلایل: $reason
پیشنهاد: $alt"
      if risk_api sendMessage --data-urlencode "chat_id=${ADMIN_CHAT_ID:-}" --data-urlencode "text=$message" \
        --data-urlencode "reply_markup=$(risk_buttons "$cc")"; then
        risk_commit_update --arg c "$cc" --argjson n "$now" --argjson l "$level" \
          '.locations[$c].last_notified=$n | .locations[$c].notified_level=$l'
      fi
    fi
    if [[ "$RISK_AUTO_RESTART" == true ]] && ((critical>0 && now-critical>=600 && count<3)); then
      if ((previous>0)); then sleep "${START_STAGGER_SEC:-3}"; fi
      # Count attempts too, so a failed restart cannot cause a runaway loop.
      risk_commit_update --arg c "$cc" --argjson n "$now" \
        '.locations[$c].auto_restarts += [$n] | .locations[$c].critical_since=$n'
      systemctl restart "psiphon-${cc}.service" >/dev/null 2>&1 || true
      previous=1
    fi
  done < <(jq -r '.locations|to_entries[]|[.key,.value.score,.value.level,.value.enough,
    .value.candidate_runs,(.value.last_notified//0),(.value.notified_level//-1),
    (.value.mute_until//0),(.value.critical_since//0),(.value.auto_restarts|length)]|@tsv' "$RISK_STATE")
}
risk_ingest() (
  # Collector passes a batch file. Network alerts never hold the samples lock.
  umask 077; risk_init
  exec 8>"$RISK_DIR/risk.lock"; flock -w 30 8 || exit 1
  local now merged; now="$(date +%s)"
  if [[ -n "${1:-}" && -s "$1" ]]; then
    merged="$(mktemp "$RISK_DIR/.merge.XXXXXX")" || exit 1
    cat "$RISK_SAMPLES" > "$merged"
    jq -c 'select((.ts|type)=="number" and (.cc|test("^[A-Z]{2}$")) and (.ok==0 or .ok==1)) |
      {ts:(.ts|floor),cc,ok,latency_ms:(.latency_ms//null),
       speed_mbps:(.speed_mbps//null),egress_ip:(.egress_ip//"-"),
       egress_country:(.egress_country//"-"),service_state:(.service_state//"-"),
       restarts_count:(.restarts_count//0),service_invocation_id:(.service_invocation_id//"")}' \
      "$1" >> "$merged" || { rm -f "$merged"; exit 1; }
    risk_trim_locked "$now" "$merged" || { rm -f "$merged"; exit 1; }
    rm -f "$merged"
  else
    risk_trim_locked "$now" || exit 1
  fi
  flock -u 8
  [[ "$RISK_ENABLED" == true ]] || exit 0
  # Another evaluator may be sending alerts. Collection above still succeeds.
  exec 9>"$RISK_DIR/risk-eval.lock"; flock -n 9 || exit 0
  flock -w 30 8 || exit 1
  risk_evaluate_locked "$now" || exit 1
  flock -u 8
  risk_actions_locked "$now"
)
risk_mute() (
  risk_init; exec 8>"$RISK_DIR/risk.lock"; flock -w 30 8 || exit 1
  [[ "$1" =~ ^[A-Z]{2}$ ]] || exit 1
  risk_state_update_locked --arg c "$1" --argjson t "$(($(date +%s)+3600))" '.locations[$c].mute_until=$t'
)
risk_reset() (
  risk_init
  exec 9>"$RISK_DIR/risk-eval.lock"; flock -w 30 9 || exit 1
  exec 8>"$RISK_DIR/risk.lock"; flock -w 30 8 || exit 1
  local tmp
  tmp="$(mktemp "$RISK_DIR/.reset.XXXXXX")"; chmod 0600 "$tmp"; mv "$tmp" "$RISK_SAMPLES"
  tmp="$(mktemp "$RISK_DIR/.reset.XXXXXX")"; printf '{"locations":{}}\n' > "$tmp"; chmod 0600 "$tmp"; mv "$tmp" "$RISK_STATE"
)
risk_set() (
  local key=$1 value=$2 tmp
  case "$key:$value" in
    RISK_ENABLED:true|RISK_ENABLED:false|RISK_AUTO_RESTART:true|RISK_AUTO_RESTART:false|RISK_AUTO_DEGRADE:true|RISK_AUTO_DEGRADE:false|RISK_SENSITIVITY:Low|RISK_SENSITIVITY:Normal|RISK_SENSITIVITY:High|RISK_NOTIFY_LEVEL:1|RISK_NOTIFY_LEVEL:2|RISK_NOTIFY_LEVEL:3) ;;
    RISK_COOLDOWN_MIN:*) [[ "$value" =~ ^[0-9]{1,3}$ ]] && ((10#$value>=1 && 10#$value<=720)) || exit 1 ;;
    RISK_QUIET_START:*|RISK_QUIET_END:*) [[ "$value" == -1 ]] || { [[ "$value" =~ ^[0-9]{1,2}$ ]] && ((10#$value<=23)); } || exit 1 ;;
    *) exit 1 ;;
  esac
  exec 7>"$RISK_DIR/risk-conf.lock"; flock -w 30 7 || exit 1
  tmp="$(mktemp "$(dirname "$RISK_CONF")/.risk-conf.XXXXXX")" || exit 1
  [[ ! -r "$RISK_CONF" ]] || awk -v key="$key" '$0 !~ ("^"key"=")' "$RISK_CONF" > "$tmp"
  printf '%s=%s\n' "$key" "$value" >> "$tmp"; chmod 0600 "$tmp"; mv "$tmp" "$RISK_CONF"
)
risk_report() {
  risk_load; risk_init
  local c=${1:-} title='🔮 پیش‌بینی خرابی'
  [[ "$RISK_ENABLED" == true ]] || title="$title (خاموش)"
  printf '%s\n' "$title"
  if [[ -n "$c" ]]; then
    jq -r --arg c "$c" '.locations[$c] as $v |
      if $v==null or ($v.enough|not) then "\($c): داده کافی نیست" else
      "\($c): ریسک \($v.score)/100\nپینگ: \($v.latency_ms)ms، میانه: \($v.baseline_ms)ms\n" +
      "نوسان: \($v.jitter_ms)ms\nتست ناموفق ۱ ساعت: \($v.failure_pct)%، ۲۴ ساعت: \($v.failure_24h_pct)%\n" +
      "خطاهای متوالی: \($v.consecutive_failures) " +
      (if $v.consecutive_failures>=3 then "(قطع)" elif $v.consecutive_failures==2 then "(پیش‌هشدار)" else "" end) +
      "\nدلایل: \($v.reason)\nپینگ ۲۴ ساعت (UTC): \($v.sparkline)\nنمونه: \($v.ts|todate)" end' "$RISK_STATE"
  else
    # All mapping locations, including those without any history.
    jq -r --rawfile mapping "$RISK_MAP" '
      .locations as $l | ($mapping|split("\n")|map([scan("\\S+")]|.[0])|
        map(select(.!=null and test("^[A-Z]{2}$")))|map({key:.,value:$l[.]}))|
      sort_by(-(.value.score//0))[] |
      if .value==null or (.value.enough|not) then "\(.key): داده کافی نیست" else
      .value as $v | (["🟢","🟡","🟠","🔴"][$v.raw_level]) as $icon |
      (($v.score/100*6|ceil)) as $bars |
      "\($icon) \(.key) \($v.score)/100 " +
      ([range(0;6)|if .<$bars then "▰" else "▱" end]|join("")) + " " +
      (if $v.latency_ms>$v.baseline_ms*1.1 then "▲" elif $v.latency_ms<$v.baseline_ms*0.9 then "▼" else "▬" end) +
      " \($v.reason)" end' "$RISK_STATE"
  fi
}
risk_summary() {
  local period=${1:-daily} fld=failure_24h_pct
  [[ "$period" != weekly ]] || fld=failure_7d_pct
  printf '📊 %s\nCC | Risk | Failed %%\n' "$period"
  jq -r --arg f "$fld" '.locations|to_entries|sort_by(-.value.score)[]|
    if .value.enough then "\(.key) | \(.value.score)/100 | \(.value[$f])"
    else "\(.key) | داده کافی نیست | \(.value[$f])" end' "$RISK_STATE"
  printf '\nسه لوکیشن پرریسک:\n'
  jq -r '.locations|to_entries|map(select(.value.enough))|sort_by(-.value.score)|.[0:3][]|
    "\(.key): \(.value.score)/100، \(.value.reason)"' "$RISK_STATE"
}

PAYLOAD_risk_lib_sh_END
  write_file "${CONF_DIR}/risk-metrics.awk" 0640 "root:root" <<'PAYLOAD_risk_metrics_awk_END'
# POSIX awk, one streaming pass; medians use O(n log n) merge sort.
BEGIN { FS=OFS="\t"; split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █",glyph," ") }
function sortpart(a,tmp,lo,hi,mid,i,j,k) {
  if(lo>=hi) return
  mid=int((lo+hi)/2); sortpart(a,tmp,lo,mid); sortpart(a,tmp,mid+1,hi)
  i=lo; j=mid+1
  for(k=lo;k<=hi;k++) {
    if(i<=mid && (j>hi || a[i]<=a[j])) tmp[k]=a[i++]; else tmp[k]=a[j++]
  }
  for(k=lo;k<=hi;k++) a[k]=tmp[k]
}
function median(cc,kind,n,i,a,tmp) {
  n=(kind=="lat" ? ln[cc] : sn[cc]); if(!n) return 0
  for(i=1;i<=n;i++) a[i]=(kind=="lat" ? lat[cc,i] : speed[cc,i])
  sortpart(a,tmp,1,n)
  return n%2 ? a[int(n/2)+1] : (a[n/2]+a[n/2+1])/2
}
function max(a,b) { return a>b?a:b }
function min(a,b) { return a<b?a:b }
function reason(s) { reasons=(reasons=="" ? s : reasons "، " s) }
FILENAME != "-" { logs[$1]=$2+0; checked[$1]=$3+0; countries[$1]=1; next }
{
  t=$1+0; c=$2; good=$3+0; v=$4+0; sp=$5+0
  if(t>now || t<now-604800) next
  countries[c]=1
  if(!first[c] || t<first[c]) first[c]=t
  # Same-hour recurrence is in UTC, explicitly labelled in docs/UI.
  if(!good && t<now-86400 && int(t%86400/3600)==int(now%86400/3600)) days[c,int(t/86400)]=1
  total7[c]++; failed7[c]+=!good
  if(t>=now-86400) {
    total[c]++; failed[c]+=!good
    if(good && v>=0) lat[c,++ln[c]]=v
    if(good && sp>=0) speed[c,++sn[c]]=sp
    h=int((t-(now-86400))/3600); if(h>23)h=23
    if(good && v>=0) { hours[c,h]+=v; hn[c,h]++ }
    if(t>=now-5400 && good && v>=0) {
      w=int((now-t)/1800); window_sum[c,w]+=v; window_n[c,w]++
    }
    if(t>=now-1800 && good && v>=0) {sum[c]+=v; sumsq[c]+=v*v; recent_n[c]++}
    if(t>=now-3600) {
      n1[c]++; f1[c]+=!good
      if(seen1[c]) {
        changes[c]+=(good!=prev_ok[c])
        delta=($9+0>=prev_restart[c] ? $9-prev_restart[c] : 0)
        invocation_change=($10!="" && prev_invocation[c]!="" && $10!=prev_invocation[c])
        restarts[c]+=max(delta,invocation_change)
        if($6!="-" && prev_ip[c]!="-" && $6!=prev_ip[c]) ipchanges[c]++
      }
      seen1[c]=1; prev_ok[c]=good; prev_restart[c]=$9+0; prev_invocation[c]=$10
      if($6!="-")prev_ip[c]=$6
    }
  }
  # Samples are appended in time order by a locked batch writer.
  if(t>=latest[c]) {
    latest[c]=t; latest_ok[c]=good; latest_lat[c]=v; latest_speed[c]=sp
    latest_country[c]=$7; latest_service[c]=$8
    if(good) consecutive[c]=0; else consecutive[c]++
  }
}
END {
  for(c in countries) {
    enough=(now-first[c]>=7200 && total[c]>=10 && latest[c]>=now-600)
    base=median(c,"lat"); sb=median(c,"speed")
    avg=recent_n[c] ? sum[c]/recent_n[c] : 0
    jitter=recent_n[c] ? sqrt(max(0,sumsq[c]/recent_n[c]-avg*avg)) : 0
    fr=n1[c] ? f1[c]/n1[c] : 0; br=total[c] ? failed[c]/total[c] : 0
    rising=base>0
    for(w=0;w<3;w++) if(window_n[c,w]<3 || window_sum[c,w]/window_n[c,w]<=base*(1+0.5*scale)) rising=0
    fs=min(1,max(0,fr-br)/(fail_delta*scale))
    # Failure severity, streaks, drift, and recurring history strengthen failure channel.
    fs=max(fs,min(1,fr/(0.4*scale)))
    if(consecutive[c]==2)fs=max(fs,0.6)
    if(consecutive[c]>=3)fs=1
    drift=(latest_country[c]!="-" && latest_country[c]!="" && latest_country[c]!=c)
    if(drift)fs=1
    recurrence=0
    for(k in days) {split(k,p,SUBSEP); if(p[1]==c)recurrence++}
    if(recurrence>=2)fs=max(fs,0.5)
    fl=min(1,max(changes[c],restarts[c])/(flap_n*scale+1))
    if(ipchanges[c]>ip_n*scale)fl=1
    js=min(1,jitter/(jitter_ms*scale))
    ss=(sb>0 && latest_speed[c]>=0 && latest_speed[c]<sb*(1-0.5*scale))
    es=min(1,logs[c]/(log_n*scale))
    weight=wf+wl+wfl+wj+ws+we
    score=weight>0 ? int((fs*wf+rising*wl+fl*wfl+js*wj+ss*ws+es*we)*100/weight+0.5) : 0
    # A confirmed down condition is critical, not a weak 35-point signal.
    if(consecutive[c]>=3 || latest_service[c]=="failed")score=100
    if(!enough)score=0
    level=(score>=80 ? 3 : score>=60 ? 2 : score>=30 ? 1 : 0)
    reasons=""
    if(fr>0)reason(sprintf("%.0f%% تست‌ها ناموفق",fr*100))
    if(consecutive[c]>=2)reason(sprintf("%d خطای متوالی",consecutive[c]))
    if(rising)reason(sprintf("پینگ %.1f برابر شده",avg/base))
    if(changes[c]>flap_n*scale || restarts[c]>flap_n*scale)reason(sprintf("%d تغییر وضعیت / %d ریستارت در ساعت",changes[c],restarts[c]))
    if(jitter>jitter_ms*scale)reason(sprintf("نوسان %.0fms",jitter))
    if(ss)reason("افت سرعت")
    if(drift)reason("کشور خروجی غیرمنتظره")
    if(ipchanges[c]>ip_n*scale)reason("تغییر مکرر IP")
    if(logs[c]>=log_n*scale)reason(sprintf("%d خطای تونل",logs[c]))
    if(recurrence>=2)reason("مشکل تکراری در همین ساعت (UTC)")
    if(reasons=="")reasons="نشانه مهمی ثبت نشده"
    spark=""; lo=1e30; hi=0
    for(h=0;h<24;h++)if(hn[c,h]){v=hours[c,h]/hn[c,h];lo=min(lo,v);hi=max(hi,v)}
    for(h=0;h<24;h++) {
      if(!hn[c,h])spark=spark "·"
      else {v=hours[c,h]/hn[c,h];idx=hi>lo ? int((v-lo)/(hi-lo)*7)+1 : 1;spark=spark glyph[idx]}
    }
    printf "%s\t%d\t%d\t%d\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%.1f\t%.1f\t%d\t%d\n",
      c,enough,score,level,avg,base,jitter,fr*100,br*100,consecutive[c],
      changes[c],restarts[c],ipchanges[c],drift,logs[c],checked[c],(recurrence>=2),
      reasons,spark,br*100,(total7[c]?failed7[c]/total7[c]*100:0),latest_ok[c],latest[c]
  }
}

PAYLOAD_risk_metrics_awk_END
  write_file "${CONF_DIR}/risk-bot-functions.sh" 0640 "root:root" <<'PAYLOAD_risk_bot_functions_sh_END'
# Embedded in telegram-bot.sh after its standard helpers.
send_long() {
  # Keep Telegram's 4,096-character ceiling with room for flags/markup.
  local text=$1 chunk
  while [[ -n "$text" ]]; do
    chunk="${text:0:3200}"; text="${text:3200}"; send "$chunk" "${@:2}"
  done
}
risk_menu() {
  send_long "$(risk_report "${1:-}")" --data-urlencode \
    'reply_markup={"inline_keyboard":[[{"text":"⚙️ تنظیمات 🔮","callback_data":"risksettings"},{"text":"🔁 تست همه","callback_data":"risktest all"}]]}'
}
risk_settings() {
  risk_load
  local markup text
  text="⚙️ تنظیمات 🔮
فعال: $RISK_ENABLED
حساسیت: $RISK_SENSITIVITY
سطح هشدار: $RISK_NOTIFY_LEVEL (1 مراقبت، 2 بالا، 3 بحرانی)
کول‌داون: $RISK_COOLDOWN_MIN دقیقه
ساعات سکوت: $RISK_QUIET_START تا $RISK_QUIET_END (ساعت محلی سرور؛ -1 خاموش)
ریستارت خودکار: $RISK_AUTO_RESTART
حذف موقت از پیشنهادها: $RISK_AUTO_DEGRADE
تنظیم دقیق: /riskcooldown 30 و /riskquiet 23 7"
  markup="$(jq -cn --arg enabled "$([[ "$RISK_ENABLED" == true ]] && echo false || echo true)" \
    --arg restart "$([[ "$RISK_AUTO_RESTART" == true ]] && echo false || echo true)" \
    --arg degraded "$([[ "$RISK_AUTO_DEGRADE" == true ]] && echo false || echo true)" \
    '{inline_keyboard:[
    [{text:"🔮 روشن/خاموش",callback_data:("riskset RISK_ENABLED "+$enabled)}],
    [{text:"Low",callback_data:"riskset RISK_SENSITIVITY Low"},{text:"Normal",callback_data:"riskset RISK_SENSITIVITY Normal"},{text:"High",callback_data:"riskset RISK_SENSITIVITY High"}],
    [{text:"🟡 Watch",callback_data:"riskset RISK_NOTIFY_LEVEL 1"},{text:"🟠 High",callback_data:"riskset RISK_NOTIFY_LEVEL 2"},{text:"🔴 Critical",callback_data:"riskset RISK_NOTIFY_LEVEL 3"}],
    [{text:"کول‌داون ۱۵",callback_data:"riskset RISK_COOLDOWN_MIN 15"},{text:"کول‌داون ۳۰",callback_data:"riskset RISK_COOLDOWN_MIN 30"},{text:"کول‌داون ۶۰",callback_data:"riskset RISK_COOLDOWN_MIN 60"}],
    [{text:"سکوت ۲۳ تا ۷",callback_data:"riskquiet 23 7"},{text:"لغو سکوت",callback_data:"riskquiet -1 -1"}],
    [{text:"ریستارت خودکار",callback_data:("riskset RISK_AUTO_RESTART "+$restart)}],
    [{text:"حذف موقت لوکیشن خراب",callback_data:("riskset RISK_AUTO_DEGRADE "+$degraded)}],
    [{text:"پاک‌کردن baseline",callback_data:"riskresetask"}],
    [{text:"🔮 پیش‌بینی خرابی",callback_data:"risk"}]]}')"
  send "$text" --data-urlencode "reply_markup=$markup"
}
risk_handle_set() {
  local key value extra
  read -r key value extra <<<"$1"
  if [[ -z "${extra:-}" ]] && risk_set "${key:-}" "${value:-}"; then risk_settings
  else send "⚠️ تنظیم نامعتبر"; fi
}
risk_handle_quiet() {
  local start end extra
  read -r start end extra <<<"$1"
  for x in "${start:-}" "${end:-}"; do
    [[ "$x" == -1 ]] || { [[ "$x" =~ ^[0-9]{1,2}$ ]] && ((10#$x<=23)); } ||
      { send "⚠️ ساعت نامعتبر"; return; }
  done
  [[ -z "${extra:-}" ]] || { send "⚠️ آرگومان اضافی"; return; }
  risk_set RISK_QUIET_START "$start"; risk_set RISK_QUIET_END "$end"; risk_settings
}

PAYLOAD_risk_bot_functions_sh_END
  write_file "/usr/local/bin/psiphon-risk" 0755 "root:root" <<'PAYLOAD_risk_cli_sh_END'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/psiphon/risk-lib.sh
case "${1:-report}" in
  report) risk_report "${2:-}" ;;
  ingest) risk_ingest "${2:-}" ;;
  cleanup) (risk_init; exec 8>"$RISK_DIR/risk.lock"; flock -w 30 8; risk_trim_locked "$(date +%s)") ;;
  mute) risk_mute "${2^^}" ;;
  reset) risk_reset ;;
  set) risk_set "$2" "$3" ;;
  summary) risk_init; risk_summary "${2:-daily}" ;;
  test|daily)
    risk_init
    target="${2:-all}"; [[ "$target" != ALL ]] || target=all
    batch="$(mktemp "$RISK_DIR/.probe-batch.XXXXXX")"; trap 'rm -f "$batch"' EXIT
    while read -r cc socks http; do
      [[ "$cc" =~ ^[A-Z]{2}$ ]] || continue
      [[ "$target" == all || "${target^^}" == "$cc" ]] || continue
      risk_probe "$cc" "$socks"
      printf '%s\n' "$RISK_PROBE_SAMPLE" >> "$batch"
    done < "$RISK_MAP"
    risk_ingest "$batch"
    if [[ "$1" == daily ]]; then
      text="$(risk_summary daily)"
      risk_api sendMessage --data-urlencode "chat_id=${ADMIN_CHAT_ID:-}" --data-urlencode "text=$text" || true
    else [[ "$target" != all ]] || target=''; risk_report "${target^^}"; fi ;;
  weekly)
    risk_init
    text="$(risk_summary weekly)"
    risk_api sendMessage --data-urlencode "chat_id=${ADMIN_CHAT_ID:-}" --data-urlencode "text=$text" || true ;;
  *) printf 'Usage: psiphon-risk report [CC] | test [CC|all] | daily | weekly | cleanup | mute CC | reset | set KEY VALUE\n' ;;
esac

PAYLOAD_risk_cli_sh_END
  if ! $DRY_RUN; then
    local tmp key value
    (
      umask 077
      exec 7>"${DATA_DIR}/risk-conf.lock"; flock -w 30 7 || exit 1
      tmp="$(mktemp "${CONF_DIR}/.risk-defaults.XXXXXX")"
      [[ ! -r "$BOT_CONF" ]] || cat "$BOT_CONF" > "$tmp"
      while read -r key value; do
        grep -q "^${key}=" "$tmp" || printf '%s=%s\n' "$key" "$value" >> "$tmp"
      done <<'RISK_DEFAULTS_EOF'
RISK_ENABLED true
RISK_SENSITIVITY Normal
RISK_NOTIFY_LEVEL 2
RISK_COOLDOWN_MIN 30
RISK_QUIET_START -1
RISK_QUIET_END -1
RISK_AUTO_RESTART false
RISK_AUTO_DEGRADE false
RISK_W_FAILURE 35
RISK_W_LATENCY 20
RISK_W_FLAP 15
RISK_W_JITTER 10
RISK_W_SPEED 10
RISK_W_LOG 10
RISK_FLAP_N 4
RISK_IP_CHANGES_N 6
RISK_LOG_N 5
RISK_JITTER_MS 150
RISK_FAILURE_DELTA 0.15
RISK_LOG_INTERVAL 600
RISK_DEFAULTS_EOF
      chmod 0600 "$tmp"; mv "$tmp" "$BOT_CONF"
    )
  fi
  write_file "${SYSTEMD_DIR}/psiphon-risk-daily.service" 0644 "root:root" <<'RISK_DAILY_SERVICE_EOF'
[Unit]
Description=Psiphon daily HTTPS-over-SOCKS test and 24h risk report
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/psiphon-risk daily
TimeoutStartSec=15min
Nice=10
UMask=0077
RISK_DAILY_SERVICE_EOF
  write_file "${SYSTEMD_DIR}/psiphon-risk-daily.timer" 0644 "root:root" <<'RISK_DAILY_TIMER_EOF'
[Unit]
Description=Psiphon daily test and 24h report
[Timer]
OnCalendar=*-*-* 09:00:00
RandomizedDelaySec=5min
Persistent=true
[Install]
WantedBy=timers.target
RISK_DAILY_TIMER_EOF
  write_file "${SYSTEMD_DIR}/psiphon-risk-weekly.service" 0644 "root:root" <<'RISK_WEEKLY_SERVICE_EOF'
[Unit]
Description=Psiphon weekly risk summary (no additional probes)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/psiphon-risk weekly
Nice=10
UMask=0077
RISK_WEEKLY_SERVICE_EOF
  write_file "${SYSTEMD_DIR}/psiphon-risk-weekly.timer" 0644 "root:root" <<'RISK_WEEKLY_TIMER_EOF'
[Unit]
Description=Psiphon weekly risk summary
[Timer]
OnCalendar=Mon *-*-* 09:10:00
RandomizedDelaySec=5min
Persistent=true
[Install]
WantedBy=timers.target
RISK_WEEKLY_TIMER_EOF
}

main "$@"
