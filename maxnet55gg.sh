#!/usr/bin/env bash
# =============================================================================
#  MAXNET6G install-warpplus.sh
#  نصب و مدیریت امن چند-instance از warp-plus روی Ubuntu 20.04 / 22.04 / 24.04 / 26.04
#  هر کشور = یک سرویس systemd + پورت اختصاصی روی 127.0.0.1 (کاملاً مجزا از سایفون)
#
#  استفاده:
#     sudo bash install-warpplus.sh                # نصب کاملاً خودکار ۳۰ کشور (idempotent)
#     sudo ./install-warpplus.sh --status          # نمایش وضعیت سرویس‌ها و تست سلامت
#     sudo ./install-warpplus.sh --update          # آپدیت هسته بدون تغییر پورت‌ها
#     sudo ./install-warpplus.sh --dry-run         # فقط نمایش کارها، بدون اجرا
#     sudo ./install-warpplus.sh --uninstall       # حذف کامل (بدون دست زدن به سایفون)
#     sudo ./install-warpplus.sh --uninstall --yes # حذف بدون سؤال
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="3.2.0"
BRAND="MAXNET6G-WARP"

# =============================================================================
# ███  بخش متغیرهای قابل ویرایش  ███  (همه تنظیمات فقط همین‌جاست)
# =============================================================================

# --- لیست لوکیشن‌ها (کد دوحرفی ISO 3166). اضافه/کم کنید. ---
COUNTRIES=(AT AU BE BG BR CA CH CZ DE DK EE ES FI FR GB HU IE IN IT JP LV NL NO PL RO RS SE SG SK US)

# --- تنظیمات شبکه Warp-Plus ---
ENABLE_SCAN=false              # true = اسکن اندپوینت کلودفلر (روی سرور خارج false سریع‌تر است)
CUSTOM_ENDPOINT=""             # اختیاری: مثلاً 162.159.192.1:2408 (خالی = خودکار)

# --- پورت‌ها (کاملاً مجزا از پورت‌های 10800 سایفون) ---
SOCKS_PORT_BASE=20800          # اولین پورت SOCKS5 (پورت Mixed: هم SOCKS5 و هم HTTP)
HTTP_PORT_BASE=20800           # در warp-plus پورت SOCKS5 و HTTP یکی است (Mixed Port)
MAX_INSTANCES=100              # سقف تعداد instance

# --- لینک‌های باینری رسمی Warp-Plus ---
WARP_BIN_URL_AMD64="https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus_linux-amd64.zip"
WARP_BIN_URL_ARM64="https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus_linux-arm64.zip"
FORCE_DOWNLOAD=false
DOWNLOAD_RETRIES=3
DOWNLOAD_BACKOFF_BASE=5

# --- مسیرها و یوزر (کاملاً ایزوله از سایفون) ---
WARP_USER="warpplus"
INSTALL_DIR="/opt/warpplus"
BIN_DIR="${INSTALL_DIR}/bin"
BIN_PATH="${BIN_DIR}/warp-plus"
CONF_DIR="/etc/warpplus"
DATA_DIR="/var/lib/warpplus"
LOG_DIR="/var/log/warpplus"
INSTALL_LOG="/var/log/warpplus-install.log"
MAPPING_FILE="${CONF_DIR}/mapping.txt"
CTL_CONF="${CONF_DIR}/warpplus-ctl.conf"
CTL_PATH="/usr/local/bin/warpplus-ctl"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_PREFIX="warpplus-"
LOGROTATE_FILE="/etc/logrotate.d/warpplus"
FIREWALL_STATE="${DATA_DIR}/ufw-rules-installed"
DISABLED_LOCATIONS="${CONF_DIR}/disabled-locations.txt"

# --- systemd ---
RESTART_SEC=10
LIMIT_NOFILE=1048576
START_STAGGER_SEC=2            # فاصله بین start هر instance برای جلوگیری از Rate-Limit کلودفلر
HEALTH_TIMER_INTERVAL="5min"   # فاصله تایمر health-check
PRUNE_REMOVED_COUNTRIES=true

# --- تست سلامت ---
TEST_URL="https://ipinfo.io/json"
TEST_TIMEOUT=15
HEALTH_WAIT=60
HEALTH_POLL_INTERVAL=5
STRICT_COUNTRY_MATCH=true
HEALTH_PARALLEL=10

# --- فایروال و سیستم‌عامل ---
MANAGE_UFW=true
SUPPORTED_UBUNTU=("20.04" "22.04" "24.04" "25.04" "25.10" "26.04")
ALLOW_UNSUPPORTED_OS=true
PREREQS=("curl:curl" "jq:jq" "unzip:unzip" "ufw:ufw" "ss:iproute2" "ip:iproute2" "timeout:coreutils" "getent:libc-bin" "logrotate:logrotate" "flock:util-linux" "sha256sum:coreutils" "update-ca-certificates:ca-certificates")

# =============================================================================
# ███  پایان بخش قابل ویرایش  ███
# =============================================================================

DRY_RUN=false
MODE="install"
ASSUME_YES=false
SCRIPT_NAME="$(basename "$0")"
WORK_TMP=""
declare -A SOCKS_PORT=() HTTP_PORT=()
declare -a CHANGED_INSTANCES=()
declare -a OK_LIST=() FAIL_LIST=()
BINARY_CHANGED=false
FILE_CHANGED=false

usage() {
  cat <<EOF
Usage: sudo ${SCRIPT_NAME} [--install|--update|--status|--dry-run|--uninstall [--yes]|--help]
  --install     اجرای نصب کامل و خودکار
  --update      به‌روزرسانی هسته warp-plus بدون تغییر پورت‌ها
  --status      نمایش وضعیت سرویس‌ها و سلامت instanceها
  --dry-run     فقط نمایش کارها بدون اعمال تغییر
  --uninstall   حذف کامل سرویس‌ها، فایل‌ها و یوزر (بدون تداخل با سایفون)
  --yes         رد کردن سؤال تأیید در uninstall
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --install)   MODE="install" ;;
    --update)    MODE="update" ;;
    --status)    MODE="status" ;;
    --uninstall) MODE="uninstall" ;;
    --yes|-y)    ASSUME_YES=true ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# رنگ‌ها و توابع لاگ
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[36m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi
ts()    { date '+%Y-%m-%d %H:%M:%S'; }
log()   { echo "${C_BLU}[$(ts)] [INFO]${C_RST} $*"; }
ok()    { echo "${C_GRN}[$(ts)] [ OK ]${C_RST} $*"; }
warn()  { echo "${C_YLW}[$(ts)] [WARN]${C_RST} $*" >&2; }
err()   { echo "${C_RED}[$(ts)] [FAIL]${C_RST} $*" >&2; }
die()   { err "$*"; exit 1; }
step()  { echo; echo "${C_BLD}==> $*${C_RST}"; }

on_error() {
  local line=${1:-?} cmd=${2:-unknown} rc=${3:-1}
  err "خطا در خط ${line} (exit=${rc}): ${cmd}"
  err "لاگ کامل: ${INSTALL_LOG}"
  exit "$rc"
}
cleanup() { [[ -n "${WORK_TMP:-}" && -d "${WORK_TMP}" ]] && rm -rf -- "$WORK_TMP"; return 0; }
trap 'rc=$?; on_error "$LINENO" "$BASH_COMMAND" "$rc"' ERR
trap cleanup EXIT

run() {
  if $DRY_RUN; then echo "${C_YLW}[DRY-RUN]${C_RST} $*"; else "$@"; fi
}

write_file() {
  local dest=$1 mode=$2 owner=$3 tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/warpplus-write.XXXXXX")"
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
    install -d -m 0755 -o root -g root "$(dirname "$dest")"
    install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "${dest}.new"
    mv -f -- "${dest}.new" "$dest"
    rm -f "$tmp"
    log "نوشته شد: ${dest}"
  fi
}

setup_logging() {
  if [[ $EUID -eq 0 ]] && ! $DRY_RUN; then
    touch "$INSTALL_LOG" && chmod 0640 "$INSTALL_LOG"
    exec > >(tee -a "$INSTALL_LOG") 2>&1
    echo "------------------------------------------------------------------"
    log "شروع ${SCRIPT_NAME} mode=${MODE}"
  fi
}

# =============================================================================
# مرحله 1: چک root، معماری و نسخه سیستم‌عامل
# =============================================================================
check_root() {
  if [[ $EUID -ne 0 ]]; then
    $DRY_RUN && warn "اجرا بدون root در حالت dry-run" || die "این اسکریپت باید با root اجرا شود: sudo ${SCRIPT_NAME}"
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
  if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *ubuntu* && "${ID_LIKE:-}" != *debian* && "${ID:-}" != "debian" ]]; then
    die "فقط توزیع‌های مبتنی بر Ubuntu/Debian پشتیبانی می‌شوند"
  fi
  command -v systemctl >/dev/null || die "systemd موجود نیست"
  ok "سیستم‌عامل: ${PRETTY_NAME:-Linux}"
}

validate_config() {
  ((${#COUNTRIES[@]} > 0)) || die "آرایه COUNTRIES خالی است"
  ((${#COUNTRIES[@]} <= MAX_INSTANCES)) || die "تعداد کشورها بیشتر از MAX_INSTANCES است"
  (( SOCKS_PORT_BASE >= 1024 && SOCKS_PORT_BASE + MAX_INSTANCES <= 65535 )) || die "رنج پورت نامعتبر است"
  local -A seen=(); local cc
  for cc in "${COUNTRIES[@]}"; do
    [[ "$cc" =~ ^[A-Z]{2}$ ]] || die "کد کشور نامعتبر: '${cc}'"
    [[ -z "${seen[$cc]:-}" ]] || die "کد کشور تکراری: ${cc}"
    seen[$cc]=1
  done
  ok "متغیرهای پیکربندی معتبرند (${#COUNTRIES[@]} کشور)"
}

# =============================================================================
# مرحله 2: نصب پیش‌نیازها
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
  if id -u "$WARP_USER" >/dev/null 2>&1; then
    ok "یوزر ${WARP_USER} موجود است"
  else
    run useradd --system --no-create-home --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$WARP_USER"
  fi
  run install -d -m 0755 -o root -g root "$INSTALL_DIR" "$BIN_DIR"
  run install -d -m 0750 -o root -g "$WARP_USER" "$CONF_DIR"
  run install -d -m 0750 -o "$WARP_USER" -g "$WARP_USER" "$DATA_DIR"
  run install -d -m 0750 -o root -g root "$LOG_DIR"
  local cc
  for cc in "${COUNTRIES[@]}"; do
    run install -d -m 0700 -o "$WARP_USER" -g "$WARP_USER" "${DATA_DIR}/${cc}"
  done
  if [[ ! -e "$DISABLED_LOCATIONS" ]]; then
    printf '# یک کد کشور در هر خط (مثلاً NL) برای غیرفعال‌سازی موقت\n' | write_file "$DISABLED_LOCATIONS" 0644 "root:root"
  fi
}

# =============================================================================
# مرحله 3: دانلود باینری warp-plus
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
  local url api_url
  case "$ARCH" in
    amd64) url="$WARP_BIN_URL_AMD64" ;;
    arm64) url="$WARP_BIN_URL_ARM64" ;;
  esac

  if [[ -x "$BIN_PATH" ]] && ! $FORCE_DOWNLOAD; then
    ok "باینری از قبل موجود است: ${BIN_PATH}"
    return 0
  fi
  if $DRY_RUN; then
    echo "${C_YLW}[DRY-RUN]${C_RST} download ${url} -> ${BIN_PATH}"
    return 0
  fi

  # تلاش برای گرفتن آخرین لینک از API گیت‌هاب، در صورت محدودیت استفاده از لینک مستقیم
  api_url="$(curl -fsSL --max-time 10 https://api.github.com/repos/bepass-org/warp-plus/releases/latest 2>/dev/null | jq -r ".assets[] | select(.name | test(\"linux-${ARCH}.*\\\\.zip$\")) | .browser_download_url" | head -n1 || true)"
  [[ -n "$api_url" && "$api_url" != "null" ]] && url="$api_url"

  local zip_tmp="${WORK_TMP}/warp-plus.zip"
  local ext_dir="${WORK_TMP}/extracted"
  mkdir -p "$ext_dir"
  log "دانلود باینری از ${url}"
  download_with_retry "$url" "$zip_tmp" || die "دانلود باینری شکست خورد"
  unzip -q -o "$zip_tmp" -d "$ext_dir"
  local bin_found
  bin_found="$(find "$ext_dir" -type f -name 'warp-plus' | head -n1)"
  [[ -n "$bin_found" && -f "$bin_found" ]] || die "فایل اجرایی warp-plus داخل آرشیو پیدا نشد"
  [[ "$(head -c 4 "$bin_found" | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]] || die "فایل دانلودشده ELF معتبر نیست"

  if [[ -f "$BIN_PATH" ]] && cmp -s "$bin_found" "$BIN_PATH"; then
    ok "باینری تغییری نکرده"
  else
    install -m 0755 -o root -g root "$bin_found" "$BIN_PATH"
    BINARY_CHANGED=true
    ok "باینری نصب شد: ${BIN_PATH}"
  fi
}

# =============================================================================
# مرحله 5: تخصیص پورت پایدار و ساخت کانفیگ‌ها
# =============================================================================
port_in_use_by_other() {
  local port=$1 line
  line="$(ss -H -tlnp "sport = :${port}" 2>/dev/null || true)"
  [[ -n "$line" ]] && ! grep -q 'warp-plus' <<<"$line"
}

allocate_ports() {
  local -A used_port=()
  local cc s h off
  if [[ -f "$MAPPING_FILE" ]]; then
    while read -r cc s h; do
      [[ -z "${cc:-}" || "$cc" == \#* ]] && continue
      [[ "$s" =~ ^[0-9]+$ ]] || continue
      if (( s >= 1024 && s <= 65535 )); then
        SOCKS_PORT[$cc]=$s; HTTP_PORT[$cc]=$s
        used_port[$s]=1
      fi
    done < "$MAPPING_FILE"
  fi

  local -A keep_s=()
  for cc in "${COUNTRIES[@]}"; do
    [[ -n "${SOCKS_PORT[$cc]:-}" ]] && keep_s[$cc]=${SOCKS_PORT[$cc]}
  done
  SOCKS_PORT=(); HTTP_PORT=()
  for cc in "${!keep_s[@]}"; do
    SOCKS_PORT[$cc]=${keep_s[$cc]}
    HTTP_PORT[$cc]=${keep_s[$cc]}
  done

  for cc in "${COUNTRIES[@]}"; do
    [[ -n "${SOCKS_PORT[$cc]:-}" ]] && continue
    off=0
    while (( off < MAX_INSTANCES )); do
      local candidate=$(( SOCKS_PORT_BASE + off ))
      if [[ -z "${used_port[$candidate]:-}" ]] && ! port_in_use_by_other "$candidate"; then
        break
      fi
      off=$(( off + 1 ))
    done
    (( off < MAX_INSTANCES )) || die "پورت آزاد برای ${cc} پیدا نشد"
    SOCKS_PORT[$cc]=$(( SOCKS_PORT_BASE + off ))
    HTTP_PORT[$cc]=$(( SOCKS_PORT_BASE + off ))
    used_port[${SOCKS_PORT[$cc]}]=1
    log "پورت جدید برای ${cc}: SOCKS5/HTTP=${SOCKS_PORT[$cc]}"
  done
}

write_mapping() {
  {
    echo "# COUNTRY  SOCKS_PORT  HTTP_PORT   (generated by ${SCRIPT_NAME}; Mixed SOCKS5/HTTP port)"
    local cc
    for cc in "${COUNTRIES[@]}"; do
      printf '%-8s %-11s %s\n' "$cc" "${SOCKS_PORT[$cc]}" "${HTTP_PORT[$cc]}"
    done
  } | write_file "$MAPPING_FILE" 0644 "root:root"

  local cc json='{}'
  for cc in "${COUNTRIES[@]}"; do
    json="$(jq -c --arg c "$cc" --argjson s "${SOCKS_PORT[$cc]}" --argjson h "${HTTP_PORT[$cc]}" \
      '. + {($c): {socks: $s, http: $h}}' <<<"$json")"
  done
  jq . <<<"$json" | write_file "${CONF_DIR}/mapping.json" 0644 "root:root"
}

write_configs() {
  local cc
  for cc in "${COUNTRIES[@]}"; do
    jq -n \
      --arg bind "127.0.0.1:${SOCKS_PORT[$cc]}" \
      --arg cc "$cc" \
      --arg ep "$CUSTOM_ENDPOINT" \
      --argjson scan "$ENABLE_SCAN" \
      '{
        bind: $bind,
        country: $cc,
        cfon: true,
        scan: $scan,
        endpoint: $ep
      }' | write_file "${CONF_DIR}/${cc}.json" 0640 "root:${WARP_USER}"
    $FILE_CHANGED && CHANGED_INSTANCES+=("$cc")
  done
}

# =============================================================================
# مرحله 6: سرویس systemd هر کشور
# =============================================================================
write_unit() {
  local cc=$1 extra_flags=""
  $ENABLE_SCAN && extra_flags+=" --scan"
  [[ -n "$CUSTOM_ENDPOINT" ]] && extra_flags+=" -e ${CUSTOM_ENDPOINT}"
  cat <<EOF
# Generated by ${SCRIPT_NAME} - Warp-Plus instance for ${cc}
[Unit]
Description=${BRAND} tunnel (${cc}) SOCKS5/HTTP 127.0.0.1:${SOCKS_PORT[$cc]}
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${WARP_USER}
Group=${WARP_USER}
WorkingDirectory=${DATA_DIR}/${cc}
ExecStart=${BIN_PATH} -b 127.0.0.1:${SOCKS_PORT[$cc]} --cfon --country ${cc}${extra_flags}
Restart=always
RestartSec=${RESTART_SEC}
LimitNOFILE=${LIMIT_NOFILE}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=warpplus-${cc}
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
}

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
    if $acted && ! $DRY_RUN; then sleep "$START_STAGGER_SEC"; fi
  done
}

# =============================================================================
# مرحله 7 و 8: تست سلامت موازی + ریستارت یک‌باره خراب‌ها
# =============================================================================
probe_once() {
  local port=$1 out ip country
  out="$(curl -sS --max-time "$TEST_TIMEOUT" --socks5-hostname "127.0.0.1:${port}" "$TEST_URL" 2>/dev/null)" || return 1
  ip="$(jq -r '.ip // empty' <<<"$out" 2>/dev/null)" || return 1
  country="$(jq -r '.country // empty' <<<"$out" 2>/dev/null)" || return 1
  [[ -n "$ip" ]] || return 1
  echo "${ip}|${country}"
}

health_wait_one() {
  local cc=$1 port=$2 outdir=$3 deadline res ip country
  deadline=$(( $(date +%s) + HEALTH_WAIT ))
  while :; do
    if res="$(probe_once "$port")"; then
      ip="${res%%|*}"; country="${res##*|}"
      if [[ "$country" == "$cc" ]] || ! $STRICT_COUNTRY_MATCH; then
        echo "OK|${ip}|${country}" > "${outdir}/${cc}"; return 0
      fi
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
    (( n % HEALTH_PARALLEL == 0 )) && { wait || true; }
  done
  wait || true
}

run_health_checks() {
  $DRY_RUN && { echo "${C_YLW}[DRY-RUN]${C_RST} health-check ${#COUNTRIES[@]} instances"; return 0; }
  local outdir="${WORK_TMP}/health" cc st
  mkdir -p "$outdir"
  log "تست سلامت ${#COUNTRIES[@]} instance به‌صورت موازی (حداکثر ${HEALTH_WAIT}s)..."
  health_round "$outdir" "${COUNTRIES[@]}"

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
  $MANAGE_UFW || return 0
  command -v ufw >/dev/null || return 0
  local s_range="${SOCKS_PORT_BASE}:$(( SOCKS_PORT_BASE + MAX_INSTANCES - 1 ))"
  $DRY_RUN || { install -d -m 0750 -o root -g root "$DATA_DIR"; : > "$FIREWALL_STATE"; chmod 0600 "$FIREWALL_STATE"; }
  if ! ufw status 2>/dev/null | grep -q "$s_range.*warpplus-local-only"; then
    run ufw deny proto tcp from any to any port "$s_range" comment 'warpplus-local-only'
    $DRY_RUN || printf '%s\n' socks >> "$FIREWALL_STATE"
  fi
}

verify_listen() {
  $DRY_RUN && return 0
  local cc port addrs bad=0 a
  for cc in "${COUNTRIES[@]}"; do
    port="${SOCKS_PORT[$cc]}"
    addrs="$(ss -H -tlnp "sport = :${port}" 2>/dev/null | awk '{print $4}' || true)"
    [[ -z "$addrs" ]] && continue
    while read -r a; do
      if [[ "$a" != "127.0.0.1:${port}" ]]; then
        err "${cc}: پورت ${port} روی ${a} listen است (غیرلوکال)! سرویس متوقف می‌شود."
        systemctl stop "${SERVICE_PREFIX}${cc}.service" || true
        bad=1
      fi
    done <<<"$addrs"
  done
  ((bad == 0)) && ok "تأیید شد: همه پورت‌های فعال فقط روی 127.0.0.1 هستند"
}

# =============================================================================
# مرحله 11: اسکریپت کمکی warpplus-ctl (مشابه psiphon-ctl)
# =============================================================================
write_ctl_conf() {
  cat <<EOF | write_file "$CTL_CONF" 0644 "root:root"
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
# warpplus-ctl: مدیریت instanceهای Warp-Plus
set -Eeuo pipefail
CONF="/etc/warpplus/warpplus-ctl.conf"
[[ -r "$CONF" ]] || { echo "config not found: $CONF" >&2; exit 1; }
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
Usage: warpplus-ctl <command> [args]
  list                    نمایش mapping کشور/پورت
  status                  وضعیت همه سرویس‌ها
  start   [CC|all]        start (پیش‌فرض all)
  stop    [CC|all]        stop  (پیش‌فرض all)
  restart <CC|all>        restart
  test    [CC|all]        تست اتصال از طریق SOCKS5
  logs    <CC> [-f]       لاگ journal
  healthcheck             تست همه + ریستارت خودکار خراب‌ها
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

probe() {
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

test_many() {
  local tmp cc n=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/warpplus-ctl.XXXXXX")"
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
  local cc st ip c ok=0 fail=0 col
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
  exec 9>/run/warpplus-healthcheck.lock
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
  echo "healthcheck done: total=${#ACTIVE[@]} restarted=${#bad[@]}"
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
  *)           usage ;;
esac
CTL_EOF
}

# =============================================================================
# مرحله 12 و 13: تایمر systemd برای health-check هر ۵ دقیقه + logrotate
# =============================================================================
write_timer() {
  write_file "${SYSTEMD_DIR}/warpplus-healthcheck.service" 0644 "root:root" <<EOF
[Unit]
Description=${BRAND} instances health-check and auto-restart
After=network-online.target

[Service]
Type=oneshot
ExecStart=${CTL_PATH} healthcheck
EOF
  write_file "${SYSTEMD_DIR}/warpplus-healthcheck.timer" 0644 "root:root" <<EOF
[Unit]
Description=${BRAND} health-check every ${HEALTH_TIMER_INTERVAL}

[Timer]
OnBootSec=3min
OnUnitActiveSec=${HEALTH_TIMER_INTERVAL}
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now warpplus-healthcheck.timer
}

write_logrotate() {
  write_file "$LOGROTATE_FILE" 0644 "root:root" <<EOF
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
EOF
}

# =============================================================================
# حالت --uninstall: حذف کامل (بدون دست زدن به سایفون)
# =============================================================================
do_uninstall() {
  check_root
  echo "${C_RED}${C_BLD}هشدار:${C_RST} همه سرویس‌های warpplus، کانفیگ‌ها و یوزر ${WARP_USER} حذف می‌شوند (سایفون دست‌نخورده می‌ماند)."
  if ! $ASSUME_YES && ! $DRY_RUN; then
    local ans
    read -r -p "برای ادامه بنویسید yes: " ans
    [[ "$ans" == "yes" ]] || { log "لغو شد"; exit 0; }
  fi

  run systemctl disable --now warpplus-healthcheck.timer 2>/dev/null || true
  run systemctl stop warpplus-healthcheck.service 2>/dev/null || true
  local f unit
  for f in "${SYSTEMD_DIR}/${SERVICE_PREFIX}"??.service; do
    [[ -e "$f" ]] || continue
    unit="$(basename "$f")"
    run systemctl disable --now "$unit" 2>/dev/null || true
    run rm -f "$f"
  done
  run rm -f "${SYSTEMD_DIR}/warpplus-healthcheck.service" "${SYSTEMD_DIR}/warpplus-healthcheck.timer"
  run systemctl daemon-reload

  if $MANAGE_UFW && command -v ufw >/dev/null && [[ -f "$FIREWALL_STATE" ]]; then
    grep -qx socks "$FIREWALL_STATE" && run ufw delete deny proto tcp from any to any port "${SOCKS_PORT_BASE}:$(( SOCKS_PORT_BASE + MAX_INSTANCES - 1 ))" 2>/dev/null || true
  fi

  run rm -f "$CTL_PATH" "$LOGROTATE_FILE" "$INSTALL_LOG" /run/warpplus-healthcheck.lock
  run rm -rf "${CONF_DIR:?}" "${DATA_DIR:?}" "${LOG_DIR:?}" "${INSTALL_DIR:?}"
  if id -u "$WARP_USER" >/dev/null 2>&1; then
    run userdel "$WARP_USER" || true
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
  echo "  warpplus-ctl list | status | test all | test DE | restart FR | logs NL -f"
  echo "  curl --socks5-hostname 127.0.0.1:<SOCKS_PORT> ${TEST_URL}"
  echo "  Health-check خودکار: systemctl list-timers warpplus-healthcheck.timer"
  echo "${C_BLD}================================================${C_RST}"
}

run_install() {
  CHANGED_INSTANCES=(); OK_LIST=(); FAIL_LIST=(); BINARY_CHANGED=false
  setup_logging
  WORK_TMP="$(mktemp -d)"
  step "1) بررسی root، معماری و سیستم‌عامل";   check_root; check_arch; check_os
  step "2) پیش‌نیازها";                         install_prereqs
  step "اعتبارسنجی پیکربندی";                  validate_config
  step "4) یوزر و دایرکتوری‌ها";                setup_user_dirs
  step "3) باینری warp-plus";                  install_binary
  step "5) تخصیص پورت و کانفیگ‌ها";             allocate_ports; write_configs
  step "9) فایل mapping";                       write_mapping
  step "6) سرویس‌های systemd";                  prune_removed; write_units; start_instances
  step "7-8) تست سلامت";                        run_health_checks
  step "10) فایروال و تأیید listen لوکال";      setup_firewall; verify_listen
  step "11) warpplus-ctl";                      write_ctl_conf; write_ctl
  step "12) تایمر health-check";                write_timer
  step "13) logrotate";                         write_logrotate
  summary
}

main() {
  if [[ "$MODE" == "status" ]]; then
    if [[ -x "$CTL_PATH" ]]; then
      "$CTL_PATH" status || true
      "$CTL_PATH" test all || true
    else
      echo "هنوز نصب نشده است."
    fi
    exit 0
  elif [[ "$MODE" == "uninstall" ]]; then
    setup_logging
    WORK_TMP="$(mktemp -d)"
    do_uninstall
  elif [[ "$MODE" == "update" ]]; then
    FORCE_DOWNLOAD=true
    run_install
  else
    run_install
  fi
}

main "$@"
