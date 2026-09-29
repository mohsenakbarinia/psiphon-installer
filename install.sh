#!/usr/bin/env bash
# =====================================================================
#  psiphon-multi-region :: install.sh
#  نصب چند اینستنس Psiphon (هر اینستنس = یک کشور خروجی) + Xray
#  Multi-region Psiphon egress + Xray router for Ubuntu 24.04 x86_64
#  License: MIT
# =====================================================================
set -Eeuo pipefail

readonly VERSION="1.0.0"

# ---------------------------------------------------------------------
# ⚠️ بعد از ساخت ریپو، USERNAME و REPO را با مقادیر خودتان عوض کنید.
#    یا هنگام اجرا override کنید:  REPO_RAW_BASE=https://raw.githubusercontent.com/me/repo/main
# ---------------------------------------------------------------------
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/USERNAME/REPO/main}"

readonly INSTALL_DIR="/opt/psiphon-multi-region"
readonly LOG_FILE="/var/log/psiphon-installer.log"
readonly SVC_USER="psiphon"
readonly DUMMY_IF="psi0"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly DEFAULT_REGIONS="US,NL,GB,FR,JP,CA,DE,SE,CH,SG,AT,BE,ES,IT,NO,DK,FI,PL,RO,IN"

# منابع دانلود باینری Psiphon (رسمی + mirror). نیاز به راستی‌آزمایی مسیر در زمان انتشار.
readonly -a PSIPHON_URLS=(
  "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
  "https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries/raw/master/linux/psiphon-tunnel-core-x86_64"
  "https://cdn.jsdelivr.net/gh/Psiphon-Labs/psiphon-tunnel-core-binaries@master/linux/psiphon-tunnel-core-x86_64"
)
readonly XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"

# لیست کامل کدهای ISO 3166-1 alpha-2 برای اعتبارسنجی
readonly ISO_CODES="AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW"

# مقادیر پیش‌فرض (در اجرای مجدد، از settings.env قبلی بارگذاری می‌شوند و CLI روی آن‌ها اعمال می‌شود)
LISTEN_IP="127.20.0.1"
BIND_MODE="dummy"          # dummy | loopback | any
SOCKS_BASE=10800
HTTP_BASE=10900
XRAY_BASE=20000
SAVED_RAW_BASE=""
INSTANCES=20
INSTANCES_SET=0
REGIONS=""
ASSUME_YES=0
MODE="install"
PSIPHON_CONFIG_FILE=""
SKIP_UPGRADE=0
WAIT_TIMEOUT=180
CONFIG_READY=0
REGION_LIST=()
TMP_DIR=""
SCRIPT_DIR=""

C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""

# ------------------------------- خروجی رنگی -------------------------------
init_colors() {
  if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'
    C_BLU=$'\e[36m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
  fi
}
info() { printf '%s[i]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[✔]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[✘]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$C_BLD" "$*" "$C_RST"; }

# ------------------------------- مدیریت خطا -------------------------------
on_error() {
  local code=$? line=$1 cmd=$2
  printf '%s[✘] خطا / Error (exit %s) line %s: %s%s\n' "$C_RED" "$code" "$line" "$cmd" "$C_RST" >&2
  printf '    لاگ کامل / Full log: %s\n' "$LOG_FILE" >&2
  exit "$code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

cleanup() {
  if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

usage() {
  cat <<EOF
psiphon-multi-region installer v${VERSION}

Usage:
  bash <(curl -fsSL ${REPO_RAW_BASE}/install.sh) [options]

Options:
  --regions "US,NL,GB"   کشورهای خروجی (ISO 3166-1 alpha-2) / egress countries
  --instances N          تعداد اینستنس از لیست پیش‌فرض (default 20, max 20 without --regions)
  --socks-base N         پورت پایه SOCKS5 (default 10800 → instance i = base+i)
  --http-base N          پورت پایه HTTP   (default 10900)
  --xray-base N          پورت پایه inbound Xray (default 20000)
  --bind-mode MODE       dummy (127.20.0.1, default) | loopback (127.0.0.1) | any (0.0.0.0 ⚠️)
  --listen-any           = --bind-mode any (پروکسی باز روی اینترنت! فقط اگر می‌دانید)
  --psiphon-config FILE  فایل JSON شامل PropagationChannelId/SponsorId/... (از Psiphon)
  --skip-upgrade         اجرا نکردن apt upgrade
  --wait-timeout SEC     زمان انتظار برای آماده شدن تونل‌ها (default 180)
  -y, --yes              بدون سوال / non-interactive
  --update               آپدیت (همان نصب مجدد با حفظ تنظیمات)
  --status               نمایش وضعیت
  --uninstall            حذف کامل
  -h, --help             راهنما

Env overrides (بدون هاردکد راز):
  PSIPHON_PROPAGATION_CHANNEL_ID, PSIPHON_SPONSOR_ID,
  PSIPHON_RSL_PUBKEY, PSIPHON_RSL_URL (plain URL; base64 می‌شود), REPO_RAW_BASE
EOF
}

need_val() {
  if [[ $# -lt 2 || -z ${2:-} ]]; then die "مقدار برای $1 لازم است / $1 requires a value"; fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --regions)        need_val "$@"; REGIONS=$2; shift 2 ;;
      --regions=*)      REGIONS=${1#*=}; shift ;;
      --instances)      need_val "$@"; INSTANCES=$2; INSTANCES_SET=1; shift 2 ;;
      --socks-base)     need_val "$@"; SOCKS_BASE=$2; shift 2 ;;
      --http-base)      need_val "$@"; HTTP_BASE=$2; shift 2 ;;
      --xray-base)      need_val "$@"; XRAY_BASE=$2; shift 2 ;;
      --bind-mode)      need_val "$@"; BIND_MODE=$2; shift 2 ;;
      --listen-any)     BIND_MODE="any"; shift ;;
      --psiphon-config) need_val "$@"; PSIPHON_CONFIG_FILE=$2; shift 2 ;;
      --skip-upgrade)   SKIP_UPGRADE=1; shift ;;
      --wait-timeout)   need_val "$@"; WAIT_TIMEOUT=$2; shift 2 ;;
      -y|--yes)         ASSUME_YES=1; shift ;;
      --update)         MODE="update"; ASSUME_YES=1; shift ;;
      --status)         MODE="status"; shift ;;
      --uninstall)      MODE="uninstall"; shift ;;
      -h|--help)        usage; exit 0 ;;
      *) die "آرگومان ناشناخته / Unknown argument: $1  (--help)" ;;
    esac
  done
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "باید با root اجرا شود / Must run as root.
    sudo -i   سپس دستور نصب را دوباره اجرا کنید، یا:
    curl -fsSL ${REPO_RAW_BASE}/install.sh | sudo bash -s -- --yes"
  fi
}

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  printf '\n===== %s | installer v%s | mode=%s | args: %s =====\n' "$(date -Is)" "$VERSION" "$MODE" "$1"
}

load_previous_settings() {
  local f="$INSTALL_DIR/config/settings.env"
  if [[ -r $f ]]; then
    # shellcheck source=/dev/null
    . "$f"
  fi
  # اگر اسکریپت هنوز placeholder دارد ولی نصب قبلی آدرس واقعی را دارد، از آن استفاده کن
  if [[ $REPO_RAW_BASE == *USERNAME/REPO* && -n $SAVED_RAW_BASE ]]; then
    REPO_RAW_BASE=$SAVED_RAW_BASE
  fi
}

detect_script_dir() {
  # وقتی با bash <(curl ...) اجرا شود، BASH_SOURCE یک pipe است و فایل محلی نداریم
  if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]]; then
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  fi
}

banner() {
  printf '%s' "$C_BLD"
  cat <<'EOF'
  ____       _       _                     __  __       _ _   _
 |  _ \ ___ (_)_ __ | |__   ___  _ __     |  \/  |_   _| | |_(_)
 | |_) / __|| | '_ \| '_ \ / _ \| '_ \    | |\/| | | | | | __| |
 |  __/\__ \| | |_) | | | | (_) | | | |   | |  | | |_| | | |_| |
 |_|   |___/|_| .__/|_| |_|\___/|_| |_|   |_|  |_|\__,_|_|\__|_|
              |_|            multi-region egress + Xray
EOF
  printf '%s  v%s\n' "$C_RST" "$VERSION"
}

# ------------------------------- بررسی سیستم -------------------------------
check_system() {
  [[ -r /etc/os-release ]] || die "/etc/os-release پیدا نشد / not found"
  local os_id os_ver arch avail_kb
  # shellcheck source=/dev/null
  os_id=$(. /etc/os-release && printf '%s' "${ID:-}")
  # shellcheck source=/dev/null
  os_ver=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
  if [[ $os_id != "ubuntu" || $os_ver != "24.04" ]]; then
    die "فقط Ubuntu 24.04 پشتیبانی می‌شود / Only Ubuntu 24.04 is supported (found: ${os_id} ${os_ver})"
  fi
  arch=$(uname -m)
  [[ $arch == "x86_64" ]] || die "فقط x86_64 پشتیبانی می‌شود / Only x86_64 supported (found: $arch)"
  [[ -d /run/systemd/system ]] || die "systemd لازم است / systemd is required"

  mkdir -p /opt
  avail_kb=$(df -Pk /opt | awk 'NR==2 {print $4}')
  if (( avail_kb < 512000 )); then
    die "فضای دیسک کافی نیست (حداقل 500MB) / Not enough disk space (need 500MB, have $((avail_kb/1024))MB)"
  fi

  if ! curl -fsS -m 15 -o /dev/null https://github.com && ! curl -fsS -m 15 -o /dev/null https://1.1.1.1; then
    die "اتصال اینترنت برقرار نیست / No internet connectivity"
  fi
  ok "OS=${os_id} ${os_ver}, arch=${arch}, disk=$((avail_kb/1024))MB, internet=OK"
}

is_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65400 )); }

validate_numbers() {
  local b
  for b in "$SOCKS_BASE" "$HTTP_BASE" "$XRAY_BASE"; do
    is_port "$b" || die "پورت پایه نامعتبر / invalid base port: $b (1024..65400)"
  done
  local d1=$(( SOCKS_BASE - HTTP_BASE )) d2=$(( SOCKS_BASE - XRAY_BASE )) d3=$(( HTTP_BASE - XRAY_BASE ))
  if (( ${d1#-} < 100 || ${d2#-} < 100 || ${d3#-} < 100 )); then
    die "پورت‌های پایه باید حداقل 100 واحد فاصله داشته باشند / base ports must be >=100 apart"
  fi
  if ! [[ $INSTANCES =~ ^[0-9]+$ ]] || (( INSTANCES < 1 || INSTANCES > 99 )); then
    die "--instances باید 1..99 باشد / must be 1..99"
  fi
  [[ $WAIT_TIMEOUT =~ ^[0-9]+$ ]] || die "--wait-timeout نامعتبر"
  case $BIND_MODE in
    dummy|loopback) ;;
    any) warn "BIND_MODE=any: پروکسی‌ها روی 0.0.0.0 باز می‌شوند (بدون احراز هویت!). حتماً فایروال بگذارید." ;;
    *) die "--bind-mode باید dummy | loopback | any باشد" ;;
  esac
}

# اعتبارسنجی و نرمال‌سازی کد کشورها
normalize_regions() {
  local raw=$1 cc seen=" "
  local -a arr=()
  raw=${raw^^}
  raw=${raw// /}
  IFS=',' read -r -a arr <<< "$raw"
  REGION_LIST=()
  for cc in "${arr[@]}"; do
    [[ -z $cc ]] && continue
    [[ $cc =~ ^[A-Z]{2}$ ]] || die "کد کشور نامعتبر / invalid country code: $cc"
    [[ " $ISO_CODES " == *" $cc "* ]] || die "کد ISO 3166-1 وجود ندارد / not an ISO 3166-1 alpha-2 code: $cc"
    if [[ $seen == *" $cc "* ]]; then warn "تکراری حذف شد / duplicate skipped: $cc"; continue; fi
    seen+="$cc "
    REGION_LIST+=("$cc")
  done
  (( ${#REGION_LIST[@]} > 0 )) || die "هیچ کشوری انتخاب نشده / no regions selected"
  (( ${#REGION_LIST[@]} <= 99 )) || die "حداکثر 99 کشور / max 99 regions"
}

decide_regions() {
  local existing="" conf="$INSTALL_DIR/config/regions.conf" ans
  if [[ -s $conf ]]; then existing=$(awk 'NF==2 {print $2}' "$conf" | paste -sd, -); fi

  if [[ -n $REGIONS ]]; then
    :
  elif [[ -n $existing && $INSTANCES_SET -eq 0 ]]; then
    REGIONS=$existing
    info "کشورهای نصب قبلی حفظ شد / keeping existing regions: $REGIONS"
  else
    if (( INSTANCES > 20 )); then die "برای بیش از 20 اینستنس باید --regions بدهید / use --regions for >20"; fi
    REGIONS=$(cut -d, -f1-"$INSTANCES" <<< "$DEFAULT_REGIONS")
    if [[ $ASSUME_YES -eq 0 && -t 0 ]]; then
      read -r -p "کشورها / Regions [${REGIONS}]: " ans
      if [[ -n $ans ]]; then REGIONS=$ans; fi
    fi
  fi
  normalize_regions "$REGIONS"
  if (( INSTANCES_SET == 1 && INSTANCES != ${#REGION_LIST[@]} )); then
    warn "تعداد اینستنس = تعداد کشورها (${#REGION_LIST[@]}) / instances follow region count"
  fi
}

show_plan() {
  printf '\n%sPlan / برنامه:%s\n' "$C_BLD" "$C_RST"
  printf '  Install dir : %s\n  Bind mode   : %s (%s)\n' "$INSTALL_DIR" "$BIND_MODE" "$LISTEN_IP"
  printf '  Ports       : SOCKS %s+i | HTTP %s+i | Xray %s+i\n' "$SOCKS_BASE" "$HTTP_BASE" "$XRAY_BASE"
  printf '  Regions (%s): %s\n\n' "${#REGION_LIST[@]}" "${REGION_LIST[*]}"
}

confirm() {
  if (( ASSUME_YES == 1 )); then return 0; fi
  [[ -t 0 ]] || die "حالت غیرتعاملی: از --yes استفاده کنید / non-interactive: use --yes"
  local ans
  read -r -p "ادامه؟ / Continue? [y/N]: " ans
  [[ $ans =~ ^[Yy]$ ]] || die "لغو شد / aborted"
}

# ------------------------------- نصب پکیج‌ها -------------------------------
system_update() {
  export DEBIAN_FRONTEND=noninteractive
  local apt_opts=(-y -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  apt-get "${apt_opts[@]}" update
  if (( SKIP_UPGRADE == 0 )); then
    apt-get "${apt_opts[@]}" upgrade
  else
    info "apt upgrade رد شد / skipped"
  fi
  apt-get "${apt_opts[@]}" install --no-install-recommends \
    curl wget git jq unzip ca-certificates iproute2 net-tools socat cron openssl tar logrotate coreutils
  ok "پیش‌نیازها نصب شد / dependencies installed"
}

create_user_dirs() {
  if ! id -u "$SVC_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SVC_USER"
    ok "کاربر $SVC_USER ساخته شد / user created"
  else
    info "کاربر $SVC_USER از قبل وجود دارد / user exists"
  fi
  install -d -m 0755 -o root -g root "$INSTALL_DIR" "$INSTALL_DIR/bin" "$INSTALL_DIR/scripts" "$INSTALL_DIR/templates"
  install -d -m 0750 -o root -g "$SVC_USER" "$INSTALL_DIR/config" "$INSTALL_DIR/config/instances" "$INSTALL_DIR/logs"
  install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$INSTALL_DIR/data"
  ok "پوشه‌ها آماده شد / directories ready"
}

# دانلود با ۳ بار تلاش
download() {
  local url=$1 dest=$2 i
  for i in 1 2 3; do
    if curl -fsSL --connect-timeout 15 --max-time 600 -o "$dest" "$url"; then return 0; fi
    warn "دانلود ناموفق ($i/3) / download failed: $url"
    sleep $(( i * 3 ))
  done
  return 1
}

# فایل‌های پروژه: اگر از clone اجرا شود محلی، وگرنه از GitHub raw
fetch_asset() {
  local rel=$1 dest=$2 mode=${3:-0644} tmp
  tmp=$(mktemp -p "$TMP_DIR")
  if [[ -n $SCRIPT_DIR && -f $SCRIPT_DIR/$rel ]]; then
    cp -f "$SCRIPT_DIR/$rel" "$tmp"
  else
    if [[ $REPO_RAW_BASE == *USERNAME/REPO* ]]; then
      die "REPO_RAW_BASE هنوز placeholder است. USERNAME/REPO را در install.sh عوض کنید / set your repo in install.sh"
    fi
    download "$REPO_RAW_BASE/$rel" "$tmp" || die "دانلود $rel ناموفق / failed to fetch $rel"
  fi
  install -m "$mode" -o root -g root "$tmp" "$dest"
}

install_project_files() {
  local t
  fetch_asset "psictl" "/usr/local/bin/psictl" 0755
  fetch_asset "uninstall.sh" "$INSTALL_DIR/scripts/uninstall.sh" 0755
  for t in psiphon.config.tpl.json xray.config.tpl.json; do
    fetch_asset "templates/$t" "$INSTALL_DIR/templates/$t" 0644
  done
  fetch_asset "templates/psiphon@.service" "$SYSTEMD_DIR/psiphon@.service" 0644
  # نام psiphon-xray.service تا با نصب رسمی Xray (xray.service) تداخل نکند
  fetch_asset "templates/xray.service" "$SYSTEMD_DIR/psiphon-xray.service" 0644
  for t in psiphon-net.service psiphon-healthcheck.service psiphon-healthcheck.timer; do
    fetch_asset "templates/$t" "$SYSTEMD_DIR/$t" 0644
  done
  fetch_asset "templates/logrotate.conf" "/etc/logrotate.d/psiphon-multi-region" 0644
  ok "فایل‌های پروژه نصب شد / project files installed"
}

is_elf() {
  [[ -s $1 ]] || return 1
  (( $(stat -c %s "$1") > 1000000 )) || return 1
  [[ $(head -c 4 "$1" | od -An -tx1 | tr -d ' \n') == "7f454c46" ]]
}

install_psiphon() {
  local tmp="$TMP_DIR/psiphon-tunnel-core" url got=0 bin="$INSTALL_DIR/bin/psiphon-tunnel-core" ver
  for url in "${PSIPHON_URLS[@]}"; do
    info "دانلود / downloading: $url"
    if download "$url" "$tmp" && is_elf "$tmp"; then got=1; break; fi
    warn "mirror بعدی / trying next mirror"
  done
  if (( got == 0 )); then
    if [[ -x $bin ]]; then warn "دانلود نشد؛ باینری قبلی حفظ شد / keeping existing binary"; return 0; fi
    die "دانلود psiphon-tunnel-core از همه mirrorها شکست خورد / all mirrors failed"
  fi
  install -m 0755 -o root -g root "$tmp" "$bin"
  # فلگ -version نیاز به راستی‌آزمایی دارد؛ شکستش fatal نیست
  ver=$(timeout 10 "$bin" -version 2>&1 | head -n 3 || true)
  ok "psiphon-tunnel-core نصب شد / installed ($(stat -c %s "$bin") bytes) ${ver:+| $ver}"
}

install_xray() {
  local zip="$TMP_DIR/xray.zip" dir="$TMP_DIR/xray" bin="$INSTALL_DIR/bin/xray" expected actual f
  if ! download "$XRAY_URL" "$zip"; then
    if [[ -x $bin ]]; then warn "دانلود Xray نشد؛ نسخه قبلی حفظ شد / keeping existing xray"; return 0; fi
    die "دانلود Xray ناموفق / Xray download failed"
  fi
  # بررسی SHA256 از فایل .dgst رسمی (فرمت نیاز به راستی‌آزمایی)
  if download "${XRAY_URL}.dgst" "$TMP_DIR/xray.dgst"; then
    expected=$(awk -F'= ' '/^SHA2-256=/ {print $2}' "$TMP_DIR/xray.dgst" | tr -d '\r' | head -n1)
    actual=$(sha256sum "$zip" | awk '{print $1}')
    if [[ -n $expected && $expected != "$actual" ]]; then die "SHA256 Xray مطابقت ندارد / checksum mismatch"; fi
    if [[ -n $expected ]]; then ok "SHA256 Xray تأیید شد / verified"; fi
  else
    warn "فایل dgst دریافت نشد؛ checksum بررسی نشد / checksum not verified"
  fi
  rm -rf "$dir"; mkdir -p "$dir"
  unzip -oq "$zip" -d "$dir"
  [[ -f $dir/xray ]] || die "xray در zip پیدا نشد / binary missing in zip"
  install -m 0755 -o root -g root "$dir/xray" "$bin"
  for f in geoip.dat geosite.dat; do
    if [[ -f $dir/$f ]]; then install -m 0644 -o root -g root "$dir/$f" "$INSTALL_DIR/bin/$f"; fi
  done
  ok "Xray نصب شد / installed: $("$bin" version 2>/dev/null | head -n1 || echo unknown)"
}

jq_set() {
  local file=$1 t
  shift
  t=$(mktemp -p "$TMP_DIR")
  jq "$@" "$file" > "$t"
  mv -f "$t" "$file"
}

# کانفیگ پایه Psiphon: مقادیر شبکه Psiphon را حدس نمی‌زنیم (TODO_VERIFY)
setup_base_config() {
  local base="$INSTALL_DIR/config/base.json" tpl="$INSTALL_DIR/templates/psiphon.config.tpl.json" tmp url_b64
  tmp=$(mktemp -p "$TMP_DIR")
  if [[ -n $PSIPHON_CONFIG_FILE ]]; then
    [[ -r $PSIPHON_CONFIG_FILE ]] || die "فایل پیدا نشد / not found: $PSIPHON_CONFIG_FILE"
    jq -e . "$PSIPHON_CONFIG_FILE" >/dev/null || die "JSON نامعتبر / invalid JSON: $PSIPHON_CONFIG_FILE"
    jq -s '.[0] * .[1]' "$tpl" "$PSIPHON_CONFIG_FILE" > "$tmp"
  elif [[ -s $base ]]; then
    jq -s '.[0] * .[1]' "$tpl" "$base" > "$tmp"   # مقادیر قبلی حفظ می‌شود
  else
    cp -f "$tpl" "$tmp"
  fi
  if [[ -n ${PSIPHON_PROPAGATION_CHANNEL_ID:-} ]]; then jq_set "$tmp" --arg v "$PSIPHON_PROPAGATION_CHANNEL_ID" '.PropagationChannelId=$v'; fi
  if [[ -n ${PSIPHON_SPONSOR_ID:-} ]]; then jq_set "$tmp" --arg v "$PSIPHON_SPONSOR_ID" '.SponsorId=$v'; fi
  if [[ -n ${PSIPHON_RSL_PUBKEY:-} ]]; then jq_set "$tmp" --arg v "$PSIPHON_RSL_PUBKEY" '.RemoteServerListSignaturePublicKey=$v'; fi
  if [[ -n ${PSIPHON_RSL_URL:-} ]]; then
    url_b64=$(printf '%s' "$PSIPHON_RSL_URL" | base64 -w0)
    jq_set "$tmp" --arg u "$url_b64" '.RemoteServerListURLs=[{"URL":$u,"OnlyAfterAttempts":0,"SkipVerify":false}]'
  fi
  install -m 0640 -o root -g "$SVC_USER" "$tmp" "$base"

  if grep -q 'TODO_VERIFY' "$base"; then
    CONFIG_READY=0
    warn "کانفیگ پایه Psiphon هنوز TODO_VERIFY دارد. سرویس‌های Psiphon اجرا نمی‌شوند."
    warn "Base config still contains TODO_VERIFY values; Psiphon instances will NOT start."
  else
    CONFIG_READY=1
    ok "کانفیگ پایه Psiphon آماده است / base config ready"
  fi
}

# IP اختصاصی 127.20.0.1 روی اینترفیس dummy (psi0)
# چرا dummy و نه alias روی lo؟ ListenInterface در Psiphon «نام اینترفیس» می‌گیرد و اولین IPv4 آن را
# استفاده می‌کند؛ روی lo همیشه 127.0.0.1 است. (نیاز به راستی‌آزمایی روی نسخه فعلی Psiphon)
setup_network() {
  systemctl daemon-reload
  if [[ $BIND_MODE != "dummy" ]]; then
    systemctl disable -q --now psiphon-net.service 2>/dev/null || true
    info "bind-mode=$BIND_MODE: اینترفیس dummy لازم نیست / not needed"
    return 0
  fi
  systemctl enable -q psiphon-net.service
  systemctl restart psiphon-net.service
  if ip -4 addr show dev "$DUMMY_IF" 2>/dev/null | grep -q "inet ${LISTEN_IP}/"; then
    ok "IP لوکال $LISTEN_IP روی $DUMMY_IF فعال است (پایدار با systemd)"
  else
    warn "ساخت $DUMMY_IF ناموفق؛ fallback به loopback (127.0.0.1) / falling back to loopback"
    systemctl disable -q --now psiphon-net.service 2>/dev/null || true
    BIND_MODE="loopback"
  fi
}

write_settings() {
  local f="$INSTALL_DIR/config/settings.env" tmp
  tmp=$(mktemp -p "$TMP_DIR")
  cat > "$tmp" <<EOF
# Generated by install.sh v${VERSION} at $(date -Is). Re-run installer to change.
LISTEN_IP="${LISTEN_IP}"
BIND_MODE="${BIND_MODE}"
SOCKS_BASE=${SOCKS_BASE}
HTTP_BASE=${HTTP_BASE}
XRAY_BASE=${XRAY_BASE}
SAVED_RAW_BASE="${REPO_RAW_BASE}"
INSTALLER_URL="${REPO_RAW_BASE}/install.sh"
INSTALLED_VERSION="${VERSION}"
EOF
  install -m 0640 -o root -g "$SVC_USER" "$tmp" "$f"
  printf '%s\n' "$ISO_CODES" | tr ' ' '\n' > "$tmp"
  install -m 0644 -o root -g root "$tmp" "$INSTALL_DIR/config/iso3166.txt"
}

# نگهداری ایندکس کشورهای قبلی تا پورت‌ها در آپدیت عوض نشوند
write_regions() {
  local conf="$INSTALL_DIR/config/regions.conf" cc idx tmp out=""
  local -A old=() used=()
  if [[ -s $conf ]]; then
    while read -r idx cc; do
      if [[ -n ${cc:-} && $idx =~ ^[0-9]+$ ]]; then old[$cc]=$idx; fi
    done < "$conf"
  fi
  for cc in "${REGION_LIST[@]}"; do
    if [[ -n ${old[$cc]:-} ]]; then used[${old[$cc]}]=1; fi
  done
  for cc in "${REGION_LIST[@]}"; do
    if [[ -n ${old[$cc]:-} ]]; then
      idx=${old[$cc]}
    else
      idx=1
      while [[ -n ${used[$idx]:-} ]]; do idx=$(( idx + 1 )); done
      used[$idx]=1
    fi
    (( idx <= 99 )) || die "ایندکس بیش از 99 / index overflow"
    out+="$idx $cc"$'\n'
  done
  tmp=$(mktemp -p "$TMP_DIR")
  printf '%s' "$out" | sort -n > "$tmp"
  install -m 0640 -o root -g "$SVC_USER" "$tmp" "$conf"
  ok "regions.conf نوشته شد / written (${#REGION_LIST[@]} regions)"
}

install_units() {
  systemctl daemon-reload
  systemctl enable -q --now psiphon-healthcheck.timer
  systemctl enable -q cron 2>/dev/null || true
  ok "systemd units + health-check timer فعال شد / enabled"
}

summary() {
  local ip="$LISTEN_IP" xip="$LISTEN_IP"
  if [[ $BIND_MODE != "dummy" ]]; then ip="127.0.0.1"; fi
  if [[ $BIND_MODE == "any" ]]; then xip="0.0.0.0"; fi
  printf '\n%s════════════ خلاصه / Summary ════════════%s\n' "$C_BLD" "$C_RST"
  /usr/local/bin/psictl list || true
  cat <<EOF

${C_BLD}تست / Test:${C_RST}
  curl --socks5-hostname ${ip}:$((SOCKS_BASE + 1)) https://ipinfo.io/json
  curl -x http://${ip}:$((HTTP_BASE + 1)) https://ipinfo.io/json
  psictl test

${C_BLD}مدیریت / Manage:${C_RST}
  psictl status | list | start | stop | restart | test [CC] | logs [CC]
  psictl add-region CC | remove-region CC | update | uninstall

${C_BLD}Xray inbounds:${C_RST} SOCKS روی ${xip}:$((XRAY_BASE + 1)) به بعد (هر کشور یک پورت)
Log: ${LOG_FILE}
EOF
  if (( CONFIG_READY == 0 )); then
    cat <<EOF

${C_YLW}⚠️  Psiphon هنوز اجرا نشده: مقادیر شبکه Psiphon (PropagationChannelId, SponsorId,
    RemoteServerListURLs, RemoteServerListSignaturePublicKey) لازم است.
    فایل JSON را بسازید و اجرا کنید:
      sudo psictl import-config /path/to/psiphon-network.json
    (راهنما در README بخش «کانفیگ Psiphon»)${C_RST}
EOF
  fi
}

run_status() {
  [[ -x /usr/local/bin/psictl ]] || die "نصب نشده / not installed"
  exec /usr/local/bin/psictl status
}

run_uninstall() {
  local args=()
  if (( ASSUME_YES == 1 )); then args+=(--yes); fi
  if [[ -x $INSTALL_DIR/scripts/uninstall.sh ]]; then
    exec "$INSTALL_DIR/scripts/uninstall.sh" "${args[@]}"
  fi
  local tmp="$TMP_DIR/uninstall.sh"
  if [[ -n $SCRIPT_DIR && -f $SCRIPT_DIR/uninstall.sh ]]; then
    cp -f "$SCRIPT_DIR/uninstall.sh" "$tmp"
  else
    download "$REPO_RAW_BASE/uninstall.sh" "$tmp" || die "دانلود uninstall.sh ناموفق"
  fi
  bash "$tmp" "${args[@]}"
}

run_install() {
  banner
  step "[1/13] بررسی سیستم / System checks";       check_system
  validate_numbers
  decide_regions
  show_plan
  if [[ $BIND_MODE == "any" && $ASSUME_YES -eq 0 ]]; then warn "0.0.0.0 = open proxy!"; fi
  confirm
  step "[2/13] آپدیت سیستم و پیش‌نیازها / apt";     system_update
  step "[3/13] کاربر و پوشه‌ها / user & dirs";      create_user_dirs
  step "[4/13] فایل‌های پروژه / project files";      install_project_files
  step "[5/13] Psiphon binary";                      install_psiphon
  step "[6/13] Xray-core";                           install_xray
  step "[7/13] کانفیگ پایه / base config";           setup_base_config
  step "[8/13] شبکه لوکال / local IP";               setup_network
  step "[9/13] تنظیمات و کشورها / settings";         write_settings; write_regions
  step "[10/13] systemd";                            install_units
  step "[11/13] تولید کانفیگ و اجرا / generate & start"
  /usr/local/bin/psictl reconfigure
  if (( CONFIG_READY == 1 )); then
    step "[12/13] انتظار برای تونل‌ها / waiting (max ${WAIT_TIMEOUT}s)"
    /usr/local/bin/psictl wait "$WAIT_TIMEOUT" || warn "برخی تونل‌ها هنوز آماده نیستند / some tunnels not ready yet"
    step "[13/13] تست سلامت / health test"
    /usr/local/bin/psictl test || warn "برخی اینستنس‌ها تست را رد کردند / some instances failed"
  fi
  summary
  ok "تمام شد / Done."
}

main() {
  local orig_args="$*"
  init_colors
  load_previous_settings
  parse_args "$@"
  require_root
  setup_logging "$orig_args"
  TMP_DIR=$(mktemp -d)
  detect_script_dir
  case $MODE in
    status)         run_status ;;
    uninstall)      run_uninstall ;;
    install|update) run_install ;;
  esac
}

main "$@"
