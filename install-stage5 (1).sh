#!/usr/bin/env bash
# =============================================================================
#  ShopBots installer — multi-tenant Telegram store bots (Python / aiogram 3 / PostgreSQL)
#  Stage 5 of 10 · app version 0.5.0
#  Usage: sudo bash install.sh {install|update|status|logs [-f] [N]|backup|help}
#  Supported OS: Ubuntu 22.04, Ubuntu 24.04, Debian 12. Data is never deleted by default.
# =============================================================================
set -Eeuo pipefail
umask 077

readonly APP_VERSION="0.5.0"
readonly APP_USER="shopbots"
readonly APP_GROUP="shopbots"
readonly BASE_DIR="/opt/shopbots"
readonly RELEASES_DIR="${BASE_DIR}/releases"
readonly CURRENT_LINK="${BASE_DIR}/current"
readonly CONF_DIR="/etc/shopbots"
readonly CONF_FILE="${CONF_DIR}/shopbots.env"
readonly DATA_DIR="/var/lib/shopbots"
readonly LOG_DIR="/var/log/shopbots"
readonly BACKUP_DIR="/var/backups/shopbots"
readonly INSTALLER_LOG="/var/log/shopbots-installer.log"
readonly SERVICE_NAME="shopbots"
readonly UNIT_FILE="/etc/systemd/system/shopbots.service"
readonly LOGROTATE_FILE="/etc/logrotate.d/shopbots"
readonly DB_NAME="shopbots"
readonly DB_USER="shopbots"
readonly KEEP_RELEASES=3
readonly PIP_VERSION="24.2"
readonly LOCK_FILE="/run/shopbots-installer.lock"
readonly MIN_FREE_MB=1500

STEP="init"
NEW_RELEASE=""
BUILDING_RELEASE=""
PREV_RELEASE=""
SWITCHED=0
SERVICE_STOPPED=0
LAST_BACKUP=""
NEW_TOKEN=""
NEW_OWNER=""

# ----------------------------------------------------------------------------- output
log() {
    local ts
    ts="$(date '+%F %T')"
    printf '[%s] %s\n' "$ts" "$*" >&2
    if [[ -f $INSTALLER_LOG && -w $INSTALLER_LOG ]]; then
        printf '[%s] %s\n' "$ts" "$*" >>"$INSTALLER_LOG" || true
    fi
}

die() {
    log "خطا: $*"
    exit 1
}

# Run a noisy command with output captured in the installer log only.
quiet() {
    if [[ -f $INSTALLER_LOG ]]; then
        "$@" >>"$INSTALLER_LOG" 2>&1
    else
        "$@" >/dev/null 2>&1
    fi
}

print_recovery_hint() {
    case "$STEP" in
        packages) log "راهنما: اتصال به مخازن apt را بررسی کنید (apt-get update) و دوباره install را اجرا کنید." ;;
        postgres|database) log "راهنما: systemctl status postgresql و journalctl -u postgresql را ببینید؛ سپس install را دوباره اجرا کنید." ;;
        build) log "راهنما: دسترسی به pypi.org را بررسی کنید. نسخه نیمه‌کاره حذف شد و نسخه فعلی دست‌نخورده است." ;;
        verify) log "راهنما: تست‌ها یا بررسی تنظیمات شکست خورد؛ جزئیات در ${INSTALLER_LOG}. نسخه فعلی دست‌نخورده است." ;;
        migrate) log "راهنما: migration ناموفق در تراکنش برگشت خورد. لاگ را ببینید؛ برای بازیابی کامل از بکاپ: ${LAST_BACKUP:-<پوشه بکاپ>} (README بخش بازیابی)." ;;
        health) log "راهنما: bash install.sh logs را ببینید. نسخه قبلی در صورت وجود بازگردانی شد." ;;
        *) log "راهنما: جزئیات در ${INSTALLER_LOG}. اجرای مجدد install امن است و داده‌ها یا تنظیمات را حذف نمی‌کند." ;;
    esac
}

rollback() {
    local reason="$1"
    log "بازگردانی به‌علت: ${reason}"
    if [[ $SWITCHED -eq 1 ]]; then
        if [[ -n $PREV_RELEASE && -d $PREV_RELEASE ]]; then
            switch_release "$PREV_RELEASE" || true
            systemctl restart "$SERVICE_NAME" || true
            log "نسخه قبلی فعال شد: ${PREV_RELEASE##*/}"
        else
            systemctl stop "$SERVICE_NAME" || true
            log "نصب اولیه بود؛ سرویس متوقف شد تا خطا رفع شود."
        fi
    elif [[ $SERVICE_STOPPED -eq 1 ]]; then
        systemctl start "$SERVICE_NAME" || true
        log "سرویس با نسخه قبلی دوباره راه‌اندازی شد."
    fi
    SWITCHED=0
    SERVICE_STOPPED=0
    if [[ -n $LAST_BACKUP ]]; then
        log "اگر migration جدید با نسخه قبلی ناسازگار است، از این بکاپ بازیابی کنید: ${LAST_BACKUP}"
    fi
}

on_error() {
    local code=$? line="$1"
    trap - ERR
    set +e
    log "مرحله «${STEP}» در خط ${line} با کد ${code} شکست خورد."
    if [[ -n $BUILDING_RELEASE && -d $BUILDING_RELEASE && $BUILDING_RELEASE != "$(readlink -f "$CURRENT_LINK" 2>/dev/null)" ]]; then
        rm -rf -- "$BUILDING_RELEASE"
    fi
    if [[ $SWITCHED -eq 1 || $SERVICE_STOPPED -eq 1 ]]; then
        rollback "خطا در مرحله ${STEP}"
    fi
    if [[ -f $INSTALLER_LOG ]]; then
        log "۱۵ خط آخر لاگ نصب:"
        tail -n 15 "$INSTALLER_LOG" >&2 || true
    fi
    print_recovery_hint
    exit "$code"
}
trap 'on_error $LINENO' ERR

# ----------------------------------------------------------------------------- checks
require_root() {
    [[ ${EUID} -eq 0 ]] || die "این دستور باید با root اجرا شود: sudo bash install.sh ..."
}

check_os() {
    [[ -r /etc/os-release ]] || die "فایل /etc/os-release پیدا نشد؛ سیستم‌عامل قابل تشخیص نیست. هیچ تغییری اعمال نشد."
    local id ver
    id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    ver="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
    case "${id}:${ver}" in
        ubuntu:22.04|ubuntu:24.04|debian:12) log "سیستم‌عامل: ${id} ${ver}" ;;
        *) die "سیستم‌عامل پشتیبانی نمی‌شود (${id:-?} ${ver:-?}). فقط Ubuntu 22.04/24.04 و Debian 12. هیچ تغییری اعمال نشد." ;;
    esac
}

check_systemd() {
    [[ -d /run/systemd/system ]] || die "systemd فعال نیست (کانتینر بدون systemd؟). هیچ تغییری اعمال نشد."
}

check_commands() {
    local c missing=()
    for c in apt-get dpkg systemctl runuser flock install sed grep find sort mktemp tar sha256sum df readlink journalctl; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "ابزارهای لازم پیدا نشدند: ${missing[*]}"
}

check_disk() {
    local path avail
    for path in /opt /var; do
        avail="$(df -Pm "$path" | awk 'NR==2 {print $4}')"
        [[ $avail =~ ^[0-9]+$ ]] || die "فضای دیسک ${path} قابل تشخیص نیست."
        (( avail >= MIN_FREE_MB )) || die "فضای آزاد ${path} کمتر از ${MIN_FREE_MB}MB است (${avail}MB)."
    done
}

acquire_lock() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "نصب‌کننده دیگری در حال اجراست."
}

init_installer_log() {
    if [[ ! -f $INSTALLER_LOG ]]; then
        install -m 0600 -o root -g root /dev/null "$INSTALLER_LOG"
    fi
    chmod 0600 "$INSTALLER_LOG"
}

is_installed() {
    [[ -f $CONF_FILE && -L $CURRENT_LINK ]]
}

# ----------------------------------------------------------------------------- packages / user / dirs
install_packages() {
    STEP="packages"
    log "نصب پیش‌نیازهای سیستم (apt)..."
    export DEBIAN_FRONTEND=noninteractive
    quiet apt-get update -q
    quiet apt-get install -y -q --no-install-recommends \
        python3 python3-venv postgresql postgresql-contrib ca-certificates logrotate util-linux
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
        || die "Python 3.10 یا جدیدتر لازم است."
}

ensure_user() {
    STEP="user"
    if ! getent group "$APP_GROUP" >/dev/null; then
        groupadd --system "$APP_GROUP"
    fi
    if id -u "$APP_USER" >/dev/null 2>&1; then
        local uid
        uid="$(id -u "$APP_USER")"
        (( uid < 1000 )) || die "کاربر ${APP_USER} از قبل وجود دارد اما کاربر سیستمی نیست (uid=${uid}). نصب متوقف شد."
    else
        useradd --system --gid "$APP_GROUP" --home-dir "$DATA_DIR" --no-create-home \
            --shell /usr/sbin/nologin "$APP_USER"
    fi
}

ensure_dirs() {
    STEP="dirs"
    install -d -m 0750 -o root -g "$APP_GROUP" "$BASE_DIR" "$RELEASES_DIR" "$CONF_DIR"
    install -d -m 0750 -o "$APP_USER" -g "$APP_GROUP" "$DATA_DIR" "$LOG_DIR"
    install -d -m 0700 -o root -g root "$BACKUP_DIR"
}

# ----------------------------------------------------------------------------- secrets / config
gen_secret() {
    python3 -c 'import secrets; print(secrets.token_urlsafe(48))'
}

gen_fernet_key() {
    python3 -c 'import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())'
}

valid_token_format() {
    [[ $1 =~ ^[0-9]{5,20}:[A-Za-z0-9_-]{30,64}$ ]]
}

# Token is passed on stdin (never argv/env) to avoid exposure in the process list.
readonly VERIFY_TOKEN_PY='
import json, sys, urllib.request, urllib.error
token = sys.stdin.read().strip()
try:
    with urllib.request.urlopen("https://api.telegram.org/bot%s/getMe" % token, timeout=15) as resp:
        data = json.load(resp)
except urllib.error.HTTPError as exc:
    sys.exit(2 if exc.code in (401, 404) else 3)
except Exception:
    sys.exit(3)
if not data.get("ok") or not data.get("result", {}).get("is_bot"):
    sys.exit(2)
print(data["result"].get("username", ""))
'

tty_print() {
    printf '%s' "$*" >/dev/tty
}

prompt_central_token() {
    local token="" rc username answer
    while true; do
        tty_print "توکن ربات مرکزی (از BotFather؛ نمایش داده نمی‌شود): "
        IFS= read -r -s token </dev/tty || die "خواندن ورودی ممکن نشد."
        tty_print $'\n'
        if ! valid_token_format "$token"; then
            tty_print $'فرمت توکن نادرست است. دوباره وارد کنید.\n'
            continue
        fi
        rc=0
        username="$(printf '%s' "$token" | python3 -c "$VERIFY_TOKEN_PY")" || rc=$?
        if [[ $rc -eq 0 ]]; then
            log "توکن ربات مرکزی تأیید شد: @${username}"
            break
        elif [[ $rc -eq 2 ]]; then
            tty_print $'تلگرام این توکن را نپذیرفت. دوباره وارد کنید.\n'
        else
            tty_print "ارتباط با api.telegram.org برقرار نشد. بدون تأیید آنلاین ادامه می‌دهید؟ [y/N] "
            IFS= read -r answer </dev/tty || answer=""
            [[ $answer =~ ^[Yy]$ ]] && { log "توکن بدون تأیید آنلاین پذیرفته شد."; break; }
            die "نصب متوقف شد؛ پس از رفع اتصال اینترنت دوباره اجرا کنید. هیچ تنظیماتی نوشته نشد."
        fi
    done
    NEW_TOKEN="$token"
}

prompt_owner_id() {
    local first second
    while true; do
        tty_print "آیدی عددی تلگرام مالک (نمایش داده نمی‌شود): "
        IFS= read -r -s first </dev/tty || die "خواندن ورودی ممکن نشد."
        tty_print $'\n'
        tty_print "تکرار آیدی عددی: "
        IFS= read -r -s second </dev/tty || die "خواندن ورودی ممکن نشد."
        tty_print $'\n'
        if [[ ! $first =~ ^[1-9][0-9]{0,18}$ ]]; then
            tty_print $'آیدی باید عدد مثبت باشد.\n'
        elif [[ $first != "$second" ]]; then
            tty_print $'دو مقدار یکسان نیستند.\n'
        else
            break
        fi
    done
    NEW_OWNER="$first"
}

conf_has() {
    grep -q "^$1=" "$CONF_FILE"
}

conf_get() {
    sed -n "s/^$1=//p" "$CONF_FILE" | tail -n 1
}

conf_append() {
    if [[ -s $CONF_FILE && -n "$(tail -c 1 "$CONF_FILE")" ]]; then
        printf '\n' >>"$CONF_FILE"
    fi
    printf '%s=%s\n' "$1" "$2" >>"$CONF_FILE"
    log "کلید تنظیمات جدید اضافه شد: $1"
}

write_new_config() {
    STEP="config"
    [[ ! -e $CONF_FILE ]] || die "فایل تنظیمات وجود دارد؛ بازنویسی نمی‌شود."
    local tmp
    tmp="$(mktemp "${CONF_DIR}/.shopbots.env.XXXXXX")"
    {
        printf '# ShopBots configuration — created %s. Contains secrets; keep mode 0640 root:%s.\n' "$(date '+%F %T')" "$APP_GROUP"
        printf '# Never regenerate SHOPBOTS_FERNET_KEY: stored bot tokens become unreadable.\n'
        printf 'SHOPBOTS_CENTRAL_BOT_TOKEN=%s\n' "$NEW_TOKEN"
        printf 'SHOPBOTS_OWNER_ID=%s\n' "$NEW_OWNER"
        printf 'SHOPBOTS_DB_HOST=127.0.0.1\n'
        printf 'SHOPBOTS_DB_PORT=5432\n'
        printf 'SHOPBOTS_DB_NAME=%s\n' "$DB_NAME"
        printf 'SHOPBOTS_DB_USER=%s\n' "$DB_USER"
        printf 'SHOPBOTS_DB_PASSWORD=%s\n' "$(gen_secret)"
        printf 'SHOPBOTS_FERNET_KEY=%s\n' "$(gen_fernet_key)"
        printf 'SHOPBOTS_TOKEN_HMAC_KEY=%s\n' "$(gen_secret)"
        printf 'SHOPBOTS_LOG_DIR=%s\n' "$LOG_DIR"
        printf 'SHOPBOTS_DATA_DIR=%s\n' "$DATA_DIR"
        printf 'SHOPBOTS_LOG_LEVEL=INFO\n'
        printf 'SHOPBOTS_RECONCILE_INTERVAL=15\n'
    } >"$tmp"
    chown root:"$APP_GROUP" "$tmp"
    chmod 0640 "$tmp"
    mv -n "$tmp" "$CONF_FILE"
    [[ ! -e $tmp ]] || { rm -f -- "$tmp"; die "فایل تنظیمات هم‌زمان ایجاد شد؛ بازنویسی نشد."; }
    NEW_TOKEN=""
    NEW_OWNER=""
    log "فایل تنظیمات با رازهای تولیدشده ایجاد شد: ${CONF_FILE}"
}

ensure_config_keys() {
    STEP="config"
    local key missing=()
    for key in SHOPBOTS_CENTRAL_BOT_TOKEN SHOPBOTS_OWNER_ID SHOPBOTS_DB_PASSWORD SHOPBOTS_FERNET_KEY SHOPBOTS_TOKEN_HMAC_KEY; do
        conf_has "$key" || missing+=("$key")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "کلیدهای ضروری در ${CONF_FILE} نیستند: ${missing[*]}. فایل را از بکاپ (${BACKUP_DIR}/*/config.tar.gz) بازیابی کنید؛ تولید خودکار رازهای جدید باعث از دست رفتن دسترسی به توکن‌های ذخیره‌شده می‌شود."
    fi
    conf_has SHOPBOTS_DB_HOST || conf_append SHOPBOTS_DB_HOST 127.0.0.1
    conf_has SHOPBOTS_DB_PORT || conf_append SHOPBOTS_DB_PORT 5432
    conf_has SHOPBOTS_DB_NAME || conf_append SHOPBOTS_DB_NAME "$DB_NAME"
    conf_has SHOPBOTS_DB_USER || conf_append SHOPBOTS_DB_USER "$DB_USER"
    conf_has SHOPBOTS_LOG_DIR || conf_append SHOPBOTS_LOG_DIR "$LOG_DIR"
    conf_has SHOPBOTS_DATA_DIR || conf_append SHOPBOTS_DATA_DIR "$DATA_DIR"
    conf_has SHOPBOTS_LOG_LEVEL || conf_append SHOPBOTS_LOG_LEVEL INFO
    conf_has SHOPBOTS_RECONCILE_INTERVAL || conf_append SHOPBOTS_RECONCILE_INTERVAL 15
}

fix_config_perms() {
    chown root:"$APP_GROUP" "$CONF_FILE"
    chmod 0640 "$CONF_FILE"
}

# ----------------------------------------------------------------------------- PostgreSQL
pg() {
    runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -q "$@"
}

start_postgres() {
    STEP="postgres"
    quiet systemctl enable --now postgresql
    local i
    for i in $(seq 1 30); do
        if pg -tAc 'SELECT 1' >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    die "PostgreSQL در ۳۰ ثانیه آماده نشد."
}

role_exists() {
    [[ "$(pg -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}'")" == "1" ]]
}

db_exists() {
    [[ "$(pg -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'")" == "1" ]]
}

# Builds a SCRAM-SHA-256 verifier so the plaintext password is never sent to the server
# (not even in a server log if a statement fails). Password comes on stdin.
readonly SCRAM_PY='
import base64, hashlib, hmac, os, sys
pw = sys.stdin.read().strip().encode()
salt = os.urandom(16); it = 4096
salted = hashlib.pbkdf2_hmac("sha256", pw, salt, it)
ck = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
sk = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
b = lambda x: base64.b64encode(x).decode()
print("SCRAM-SHA-256$%d:%s$%s:%s" % (it, b(salt), b(hashlib.sha256(ck).digest()), b(sk)))
'

ensure_database() {
    STEP="database"
    local verifier
    if ! role_exists; then
        verifier="$(conf_get SHOPBOTS_DB_PASSWORD | python3 -c "$SCRAM_PY")"
        pg >/dev/null 2>&1 <<SQL || die "ایجاد نقش پایگاه داده ناموفق بود."
CREATE ROLE ${DB_USER} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD '${verifier}';
SQL
        verifier=""
        log "نقش پایگاه داده ${DB_USER} ایجاد شد."
    fi
    if ! db_exists; then
        quiet pg -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8' TEMPLATE template0"
        log "پایگاه داده ${DB_NAME} ایجاد شد."
    fi
    quiet pg -c "REVOKE ALL ON DATABASE ${DB_NAME} FROM PUBLIC"
    quiet pg -c "GRANT CONNECT, TEMPORARY ON DATABASE ${DB_NAME} TO ${DB_USER}"
    quiet pg -d "$DB_NAME" -c "ALTER SCHEMA public OWNER TO ${DB_USER}"
    quiet pg -d "$DB_NAME" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC"
}

# ----------------------------------------------------------------------------- backup
do_backup() {
    STEP="backup"
    local label="$1" ts dir
    ts="$(date +%Y%m%d-%H%M%S)"
    dir="${BACKUP_DIR}/${ts}-${label}"
    install -d -m 0700 -o root -g root "$dir"
    if db_exists; then
        runuser -u postgres -- pg_dump -Fc "$DB_NAME" >"${dir}/db.dump"
        runuser -u postgres -- pg_restore -l <"${dir}/db.dump" >/dev/null \
            || die "بکاپ پایگاه داده قابل خواندن نیست: ${dir}/db.dump"
    else
        log "پایگاه داده هنوز وجود ندارد؛ فقط تنظیمات بکاپ گرفته می‌شود."
    fi
    if [[ -d $CONF_DIR ]]; then
        tar -C / -czf "${dir}/config.tar.gz" "${CONF_DIR#/}"
    fi
    (cd "$dir" && sha256sum -- * >SHA256SUMS)
    chmod 0600 "$dir"/*
    LAST_BACKUP="$dir"
    log "بکاپ ایجاد شد: ${dir} (بکاپ‌ها خودکار حذف نمی‌شوند)"
}

# ----------------------------------------------------------------------------- release build
run_app() {
    local rel="$1"
    shift
    (
        cd "${rel}/app"
        runuser -u "$APP_USER" -- env -i PATH=/usr/bin:/bin LANG=C.UTF-8 \
            SHOPBOTS_CONFIG="$CONF_FILE" PYTHONDONTWRITEBYTECODE=1 \
            "${rel}/venv/bin/python" "$@"
    )
}

build_release() {
    STEP="build"
    local id rel
    id="$(date +%Y%m%d%H%M%S)-${APP_VERSION}"
    rel="${RELEASES_DIR}/${id}"
    [[ ! -e $rel ]] || die "پوشه نسخه ${rel} از قبل وجود دارد؛ چند ثانیه بعد دوباره تلاش کنید."
    BUILDING_RELEASE="$rel"
    install -d -m 0700 "$rel" "${rel}/app"
    log "نوشتن فایل‌های برنامه در ${rel}..."
    write_project_files "${rel}/app"
    if [[ -f ${BASH_SOURCE[0]} ]]; then
        install -m 0600 "${BASH_SOURCE[0]}" "${rel}/install.sh"
    fi
    log "ساخت محیط مجازی و نصب وابستگی‌ها (چند دقیقه)..."
    quiet python3 -m venv "${rel}/venv"
    quiet "${rel}/venv/bin/python" -m pip install --disable-pip-version-check --no-input -q "pip==${PIP_VERSION}"
    quiet "${rel}/venv/bin/python" -m pip install --disable-pip-version-check --no-input -q \
        --require-virtualenv -r "${rel}/app/requirements.txt"
    quiet "${rel}/venv/bin/python" -m compileall -q "${rel}/app"
    chown -R root:"$APP_GROUP" "$rel"
    chmod -R u=rwX,g=rX,o= "$rel"
    NEW_RELEASE="$rel"
}

verify_release() {
    STEP="verify"
    local rel="$1"
    log "اجرای تست‌ها و بررسی تنظیمات..."
    quiet run_app "$rel" -m unittest discover -s tests -t .
    quiet run_app "$rel" -m shopbots.cli check-config
}

switch_release() {
    local rel="$1"
    ln -sfn "$rel" "${BASE_DIR}/.current.tmp"
    mv -Tf "${BASE_DIR}/.current.tmp" "$CURRENT_LINK"
}

prune_releases() {
    STEP="cleanup"
    local cur r kept=0
    cur="$(readlink -f "$CURRENT_LINK")"
    while IFS= read -r r; do
        [[ $r =~ ^[0-9]{14}-[0-9A-Za-z.]+$ ]] || continue
        [[ "${RELEASES_DIR}/${r}" == "$cur" ]] && continue
        kept=$((kept + 1))
        (( kept < KEEP_RELEASES )) && continue
        rm -rf -- "${RELEASES_DIR:?}/${r}"
        log "کد نسخه قدیمی حذف شد (داده دست‌نخورده): ${r}"
    done < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
}

# ----------------------------------------------------------------------------- systemd / logrotate
write_systemd_unit() {
    STEP="systemd"
    local tmp
    tmp="$(mktemp /etc/systemd/system/.shopbots.service.XXXXXX)"
    cat >"$tmp" <<'UNIT'
[Unit]
Description=ShopBots - Telegram store bots platform
Documentation=file:///opt/shopbots/current/app/docs/README.fa.md
After=network-online.target postgresql.service
Wants=network-online.target postgresql.service
StartLimitIntervalSec=600
StartLimitBurst=20

[Service]
Type=simple
User=shopbots
Group=shopbots
WorkingDirectory=/opt/shopbots/current/app
Environment=SHOPBOTS_CONFIG=/etc/shopbots/shopbots.env
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PYTHONUNBUFFERED=1
Environment=LANG=C.UTF-8
ExecStart=/opt/shopbots/current/venv/bin/python -m shopbots.cli run
Restart=always
RestartSec=5
# 2 = config error, 3 = schema not migrated: restarting cannot fix these.
RestartPreventExitStatus=2 3
TimeoutStopSec=40
KillSignal=SIGTERM
UMask=0027
LimitNOFILE=65536
LogRateLimitIntervalSec=30s
LogRateLimitBurst=1000

NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/shopbots /var/log/shopbots
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
UNIT
    chmod 0644 "$tmp"
    mv -f "$tmp" "$UNIT_FILE"
}

write_logrotate() {
    local tmp
    tmp="$(mktemp /etc/logrotate.d/.shopbots.XXXXXX)"
    cat >"$tmp" <<'ROTATE'
/var/log/shopbots/*.log {
    daily
    rotate 14
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    su shopbots shopbots
    create 0640 shopbots shopbots
}

/var/log/shopbots-installer.log {
    monthly
    rotate 6
    maxsize 10M
    missingok
    notifempty
    compress
    create 0600 root root
}
ROTATE
    chmod 0644 "$tmp"
    mv -f "$tmp" "$LOGROTATE_FILE"
}

# ----------------------------------------------------------------------------- health
health_check() {
    STEP="health"
    local since="$1" i
    log "health check (حداکثر ۹۰ ثانیه)..."
    for i in $(seq 1 30); do
        sleep 3
        if ! systemctl is-active --quiet "$SERVICE_NAME"; then
            systemctl is-failed --quiet "$SERVICE_NAME" && break
            continue
        fi
        if quiet run_app "$CURRENT_LINK" -m shopbots.cli health --max-age 60 --since "$since"; then
            run_app "$CURRENT_LINK" -m shopbots.cli health --max-age 60 >&2 || true
            return 0
        fi
    done
    log "health check ناموفق. آخرین لاگ سرویس:"
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2 || true
    tail -n 30 "${LOG_DIR}/app.log" >&2 2>/dev/null || true
    return 1
}

# ----------------------------------------------------------------------------- flows
deploy_and_activate() {
    build_release
    verify_release "$NEW_RELEASE"
    PREV_RELEASE=""
    if [[ -L $CURRENT_LINK ]]; then
        PREV_RELEASE="$(readlink -f "$CURRENT_LINK")"
    fi
    STEP="stop"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME"
        SERVICE_STOPPED=1
    fi
    STEP="migrate"
    log "اعمال migrationها..."
    run_app "$NEW_RELEASE" -m shopbots.cli migrate >>"$INSTALLER_LOG" 2>&1
    STEP="switch"
    switch_release "$NEW_RELEASE"
    SWITCHED=1
    BUILDING_RELEASE=""
    write_systemd_unit
    write_logrotate
    systemctl daemon-reload
    quiet systemctl enable "$SERVICE_NAME"
    STEP="start"
    local since
    since="$(date +%s)"
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME"
    if ! health_check "$since"; then
        rollback "health check ناموفق"
        print_recovery_hint
        exit 1
    fi
    SWITCHED=0
    SERVICE_STOPPED=0
    prune_releases
}

preflight() {
    STEP="preflight"
    check_commands
    check_disk
}

cmd_install() {
    preflight
    init_installer_log
    local fresh=0
    if [[ -f $CONF_FILE ]]; then
        log "فایل تنظیمات موجود است و بدون تغییر حفظ می‌شود."
    else
        fresh=1
        [[ -r /dev/tty && -w /dev/tty ]] || die "برای دریافت محرمانه توکن، اجرای تعاملی (ترمینال) لازم است."
    fi
    install_packages
    ensure_user
    ensure_dirs
    start_postgres
    if [[ $fresh -eq 1 ]]; then
        if role_exists; then
            die "نقش پایگاه داده ${DB_USER} وجود دارد اما ${CONF_FILE} نیست؛ رمز و کلید رمزنگاری قبلی لازم است. فایل تنظیمات را از ${BACKUP_DIR}/*/config.tar.gz بازیابی کنید (tar -C / -xzf ...) و دوباره install را اجرا کنید. هیچ داده‌ای تغییر نکرد."
        fi
        prompt_central_token
        prompt_owner_id
        write_new_config
    fi
    ensure_config_keys
    fix_config_perms
    ensure_database
    if is_installed; then
        do_backup "pre-install"
    fi
    deploy_and_activate
    log "نصب کامل شد. در ربات مرکزی /start را بفرستید. وضعیت: sudo bash install.sh status"
}

cmd_update() {
    is_installed || die "سامانه نصب نشده است؛ ابتدا: sudo bash install.sh install"
    preflight
    init_installer_log
    install_packages
    ensure_user
    ensure_dirs
    start_postgres
    ensure_config_keys
    fix_config_perms
    ensure_database
    do_backup "pre-update"
    deploy_and_activate
    log "به‌روزرسانی به نسخه ${APP_VERSION} کامل شد. بکاپ پیش از به‌روزرسانی: ${LAST_BACKUP}"
}

cmd_status() {
    is_installed || die "سامانه نصب نشده است."
    printf 'نسخه فعال: %s\n' "$(basename "$(readlink -f "$CURRENT_LINK")")"
    systemctl --no-pager --lines=0 status "$SERVICE_NAME" || true
    run_app "$CURRENT_LINK" -m shopbots.cli health --max-age 60 || true
    local last
    last="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -n 1)"
    printf 'آخرین بکاپ: %s\n' "${last:-ندارد}"
}

cmd_logs() {
    local follow=0 lines=200 arg
    for arg in "$@"; do
        case "$arg" in
            -f|--follow) follow=1 ;;
            ''|*[!0-9]*) die "آرگومان نامعتبر برای logs: ${arg}" ;;
            *) lines="$arg" ;;
        esac
    done
    if [[ $follow -eq 1 ]]; then
        exec tail -n "$lines" -F "${LOG_DIR}/app.log"
    fi
    printf '=== journald (%s) ===\n' "$SERVICE_NAME"
    journalctl -u "$SERVICE_NAME" -n "$lines" --no-pager || true
    printf '\n=== %s/app.log ===\n' "$LOG_DIR"
    tail -n "$lines" "${LOG_DIR}/app.log" 2>/dev/null || printf 'فایل لاگ هنوز ایجاد نشده است.\n'
}

cmd_backup() {
    is_installed || die "سامانه نصب نشده است."
    init_installer_log
    start_postgres
    do_backup "manual"
}

usage() {
    cat <<'USAGE'
ShopBots installer (stage 5, v0.5.0)
  sudo bash install.sh install        نصب یا نصب مجدد امن (داده و تنظیمات حفظ می‌شوند)
  sudo bash install.sh update         به‌روزرسانی با بکاپ خودکار و بازگردانی در صورت خطا
  sudo bash install.sh status         وضعیت سرویس و health check
  sudo bash install.sh logs [-f] [N]  نمایش لاگ‌ها
  sudo bash install.sh backup         بکاپ دستی پایگاه داده و تنظیمات
حذف داده هیچ‌گاه بخشی از این دستورات نیست.
USAGE
}

# ----------------------------------------------------------------------------- embedded project files
# Every project file is embedded below verbatim (quoted heredoc: no shell expansion).
write_project_files() {
    local d="$1"
    install -d -m 0700 "$d/docs"
    install -d -m 0700 "$d/shopbots"
    install -d -m 0700 "$d/shopbots/handlers"
    install -d -m 0700 "$d/shopbots/migrations"
    install -d -m 0700 "$d/shopbots/repo"
    install -d -m 0700 "$d/tests"

# >>> file: docs/README.fa.md
    cat >"$d/docs/README.fa.md" <<'SHOPBOTS_FILE_EOF'
# ShopBots — مرحله ۲ (نسخه 0.2.0)

سامانه مدیریت ربات‌های فروشگاهی تلگرام: یک ربات مرکزی برای مالک، و برای هر فروشنده ربات اختصاصی.
همه ربات‌ها در یک فرایند مشترک اجرا می‌شوند؛ داده هر فروشگاه با کلید `bot_id`/`shop_id` جدا می‌شود
(جداسازی سخت‌گیرانه با Row-Level Security در مرحله ۲ اضافه می‌شود).

## دستورات نصب‌کننده
    sudo bash install.sh install        # نصب یا نصب مجدد امن
    sudo bash install.sh update         # به‌روزرسانی (بکاپ خودکار قبل از تغییر)
    sudo bash install.sh status         # وضعیت سرویس و health check
    sudo bash install.sh logs [-f] [N]  # لاگ‌ها
    sudo bash install.sh backup         # بکاپ دستی

## مسیرها
| مسیر | محتوا | مجوز |
|---|---|---|
| /opt/shopbots/releases/<id> | کد + venv هر نسخه | root:shopbots 0750 |
| /opt/shopbots/current | symlink نسخه فعال | |
| /etc/shopbots/shopbots.env | تنظیمات و رازها | root:shopbots 0640 |
| /var/lib/shopbots | داده برنامه | shopbots 0750 |
| /var/log/shopbots | لاگ برنامه (logrotate روزانه، ۱۴ نسخه، حداکثر 50MB) | shopbots 0750 |
| /var/backups/shopbots | بکاپ DB و تنظیمات | root 0700 |

## دستورات ربات مرکزی (فقط مالک)
/status، /bots، /addbot <توکن>، /disablebot <شناسه>، /enablebot <شناسه>

## بازیابی از بکاپ
    systemctl stop shopbots
    tar -C / -xzf /var/backups/shopbots/<پوشه>/config.tar.gz
    runuser -u postgres -- pg_restore --clean --if-exists -d shopbots < /var/backups/shopbots/<پوشه>/db.dump
    systemctl start shopbots

## مرحله ۲: هسته چندفروشگاهی و مالی
- فروشگاه‌ها، مشتری‌ها، کالاها، قیمت‌ها، تراکنش‌ها، گروه گزارش، تنظیمات و دفتر مالی با `shop_id` جدا می‌شوند.
- همه داده‌های tenant با PostgreSQL RLS و context معتبر سرور محدود می‌شوند؛ ورودی callback یا کاربر هرگز منبع shop نیست.
- پول فقط به ریال و به‌صورت عدد صحیح در DB ذخیره می‌شود؛ نمایش تومان فقط یک تبدیل UI است.
- رویدادهای دفتر مالی immutable هستند و مانده از دفتر قابل بازسازی و تطبیق است.
- tokenها رمزنگاری‌شده‌اند؛ کلیدها جدا از DB نگهداری می‌شوند و لاگ‌ها redact می‌شوند.
- دستورات مرکزی: `/addbot <token> [admin_tg_id]`، `/setadmin <shop_id> <admin_tg_id>`، `/shop <shop_id>`، `/disablebot <bot_id>`، `/enablebot <bot_id>`.

## محدودیت‌های شناخته‌شده مرحله ۱
- ربات فروشنده فقط پیام خوش‌آمد دارد؛ کاتالوگ، سبد، سفارش، پرداخت دستی و گزارش xlsx در مراحل بعد.
- پیام /addbot حاوی توکن پس از دریافت حذف می‌شود، اما تا آن لحظه در سرور تلگرام بوده است.
- وضعیت FSM در حافظه است (مرحله ۴ به PostgreSQL منتقل می‌شود).
- هیچ ادعای ممیزی امنیتی یا آمادگی برای استفاده مالی واقعی وجود ندارد.
SHOPBOTS_FILE_EOF

# >>> file: requirements.txt
    cat >"$d/requirements.txt" <<'SHOPBOTS_FILE_EOF'
# Direct runtime dependencies (pinned). Compatible with Python 3.10 - 3.12
# (Ubuntu 22.04 = 3.10, Debian 12 = 3.11, Ubuntu 24.04 = 3.12).
# aiogram 3.13.1 requires aiohttp>=3.9,<3.11 and pydantic>=2.4.1,<2.10.
aiogram==3.13.1
aiohttp==3.10.10
pydantic==2.9.2
asyncpg==0.29.0
cryptography==43.0.3
SHOPBOTS_FILE_EOF

# >>> file: shopbots/__init__.py
    cat >"$d/shopbots/__init__.py" <<'SHOPBOTS_FILE_EOF'
"""ShopBots: multi-tenant Telegram store bots platform (shared code, isolated shop data)."""

__version__ = "0.3.0"
SHOPBOTS_FILE_EOF

# >>> file: shopbots/backoff.py
    cat >"$d/shopbots/backoff.py" <<'SHOPBOTS_FILE_EOF'
"""Exponential backoff with jitter (no external dependencies, unit-testable)."""

from __future__ import annotations

import random


class Backoff:
    def __init__(self, base: float = 1.0, cap: float = 60.0) -> None:
        if base <= 0 or cap < base:
            raise ValueError("invalid backoff parameters")
        self.base = base
        self.cap = cap
        self.attempt = 0

    def next(self) -> float:
        delay = min(self.cap, self.base * (2 ** min(self.attempt, 30)))
        self.attempt += 1
        return delay * (0.5 + random.random() / 2)

    def reset(self) -> None:
        self.attempt = 0


def restart_delay(failures: int, base: float = 5.0, cap: float = 300.0) -> float:
    """Delay before restarting a crashed bot runner; grows with consecutive failures."""
    return min(cap, base * (2 ** max(0, min(failures - 1, 10))))
SHOPBOTS_FILE_EOF

# >>> file: shopbots/cli.py
    cat >"$d/shopbots/cli.py" <<'SHOPBOTS_FILE_EOF'
"""Command line entry point: python -m shopbots.cli {run,migrate,health,check-config,version}.

Exit codes: 0 ok, 1 health/runtime failure, 2 config error, 3 schema not up to date."""

from __future__ import annotations

import argparse
import asyncio
import logging
import signal
import sys

from . import __version__
from .config import ConfigError, Settings, load_settings
from .logging_setup import redact, setup_console_logging, setup_service_logging

log = logging.getLogger("shopbots")

EXIT_OK, EXIT_FAIL, EXIT_CONFIG, EXIT_SCHEMA = 0, 1, 2, 3


class StartupError(Exception):
    def __init__(self, message: str, code: int = EXIT_FAIL) -> None:
        super().__init__(message)
        self.code = code


# ---- run -------------------------------------------------------------------
async def _run_service(settings: Settings) -> None:
    from . import db, migrate
    from .locks import AdvisoryLockManager
    from .security import TokenVault
    from .supervisor import Supervisor

    try:
        pool = await db.create_pool(settings, min_size=2, max_size=20)
    except Exception as exc:  # noqa: BLE001
        raise StartupError(redact(f"cannot connect to PostgreSQL: {type(exc).__name__}: {exc}")) from None
    locks = AdvisoryLockManager(settings)
    try:
        async with pool.acquire() as conn:
            status = await migrate.check_status(conn)
        if not status.up_to_date:
            raise StartupError(
                f"database schema not up to date (pending={status.pending}, mismatched={status.mismatched}); "
                "run: sudo bash install.sh update",
                EXIT_SCHEMA,
            )
        vault = TokenVault(settings.fernet_key, settings.token_hmac_key)
        supervisor = Supervisor(settings=settings, pool=pool, vault=vault, locks=locks)
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, supervisor.request_stop)
        await supervisor.run()
    finally:
        await locks.close()
        try:
            await asyncio.wait_for(pool.close(), timeout=10)
        except Exception:  # noqa: BLE001
            pool.terminate()


def cmd_run(_args: argparse.Namespace) -> int:
    settings = load_settings()
    setup_service_logging(settings.log_dir, settings.log_level)
    try:
        asyncio.run(_run_service(settings))
    except StartupError as exc:
        log.critical("%s", exc)
        return exc.code
    return EXIT_OK


# ---- migrate ---------------------------------------------------------------
async def _migrate(settings: Settings) -> list[str]:
    from . import db, migrate

    conn = await db.connect(settings)
    try:
        return await migrate.apply_migrations(conn)
    finally:
        await conn.close()


def cmd_migrate(_args: argparse.Namespace) -> int:
    settings = load_settings()
    setup_console_logging("INFO")
    from .migrate import MigrationError

    try:
        applied = asyncio.run(_migrate(settings))
    except MigrationError as exc:
        log.error("migration error: %s", exc)
        return EXIT_SCHEMA
    except Exception as exc:  # noqa: BLE001
        log.error("migration failed: %s", redact(f"{type(exc).__name__}: {exc}"))
        return EXIT_FAIL
    print("migrations applied: " + (", ".join(applied) if applied else "none (already up to date)"))
    return EXIT_OK


# ---- health ----------------------------------------------------------------
async def _health(settings: Settings, max_age: float, since: float | None, strict: bool) -> tuple[int, list[str]]:
    from . import db, migrate
    from .repo import system as system_repo

    lines: list[str] = []
    try:
        conn = await db.connect(settings)
    except Exception as exc:  # noqa: BLE001
        return EXIT_FAIL, [redact(f"FAIL database: {type(exc).__name__}: {exc}")]
    try:
        lines.append("OK   database connection")
        status = await migrate.check_status(conn)
        if not status.up_to_date:
            lines.append(f"FAIL schema: pending={status.pending} mismatched={status.mismatched}")
            return EXIT_SCHEMA, lines
        lines.append(f"OK   schema ({len(status.applied)} migrations)")
        beat = await system_repo.read_heartbeat(conn)
    finally:
        await conn.close()
    if beat is None:
        lines.append("FAIL heartbeat: service has never reported")
        return EXIT_FAIL, lines
    if since is not None and beat["beat_epoch"] < since:
        lines.append("FAIL heartbeat: no report since service (re)start")
        return EXIT_FAIL, lines
    if beat["age"] > max_age:
        lines.append(f"FAIL heartbeat: last report {beat['age']:.0f}s ago (> {max_age:.0f}s)")
        return EXIT_FAIL, lines
    lines.append(
        f"OK   heartbeat {beat['age']:.0f}s ago (pid {beat['pid']}, version {beat['version']}, running bots {beat['running_bots']})"
    )
    details = beat.get("details") or {}
    if details.get("central_running"):
        lines.append("OK   central bot polling")
    else:
        err = details.get("central_error") or "starting"
        lines.append(f"{'FAIL' if strict else 'WARN'} central bot not polling yet: {redact(str(err))[:200]}")
        if strict:
            return EXIT_FAIL, lines
    return EXIT_OK, lines


def cmd_health(args: argparse.Namespace) -> int:
    settings = load_settings()
    logging.disable(logging.CRITICAL)
    code, lines = asyncio.run(_health(settings, args.max_age, args.since, args.strict))
    print("\n".join(lines))
    return code


# ---- misc ------------------------------------------------------------------
def cmd_check_config(_args: argparse.Namespace) -> int:
    from .security import TokenVault

    settings = load_settings()
    TokenVault(settings.fernet_key, settings.token_hmac_key)
    print(f"config OK (owner id set, db {settings.db_user}@{settings.db_host}:{settings.db_port}/{settings.db_name})")
    return EXIT_OK


def cmd_version(_args: argparse.Namespace) -> int:
    print(__version__)
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="shopbots")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("run", help="run the bot supervisor (systemd)").set_defaults(func=cmd_run)
    sub.add_parser("migrate", help="apply pending database migrations").set_defaults(func=cmd_migrate)
    health = sub.add_parser("health", help="check database, schema and service heartbeat")
    health.add_argument("--max-age", type=float, default=60.0)
    health.add_argument("--since", type=float, default=None, help="unix time; heartbeat must be newer")
    health.add_argument("--strict", action="store_true", help="fail if the central bot is not polling")
    health.set_defaults(func=cmd_health)
    sub.add_parser("check-config", help="validate configuration").set_defaults(func=cmd_check_config)
    sub.add_parser("version").set_defaults(func=cmd_version)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except ConfigError as exc:
        print(f"config error: {exc}", file=sys.stderr)
        return EXIT_CONFIG
    except ValueError as exc:
        print(f"config error: {redact(str(exc))}", file=sys.stderr)
        return EXIT_CONFIG


if __name__ == "__main__":
    sys.exit(main())
SHOPBOTS_FILE_EOF

# >>> file: shopbots/config.py
    cat >"$d/shopbots/config.py" <<'SHOPBOTS_FILE_EOF'
"""Configuration loader. Single source of truth: /etc/shopbots/shopbots.env (KEY=VALUE)."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping

from .security import decode_key, validate_token_format

DEFAULT_CONFIG_PATH = "/etc/shopbots/shopbots.env"
_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")

REQUIRED_KEYS = (
    "SHOPBOTS_CENTRAL_BOT_TOKEN",
    "SHOPBOTS_OWNER_ID",
    "SHOPBOTS_DB_PASSWORD",
    "SHOPBOTS_FERNET_KEY",
    "SHOPBOTS_TOKEN_HMAC_KEY",
)
LOG_LEVELS = ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL")


class ConfigError(Exception):
    """Invalid or unreadable configuration. Messages never contain secret values."""


@dataclass(frozen=True)
class Settings:
    central_bot_token: str = field(repr=False)
    owner_id: int
    db_host: str
    db_port: int
    db_name: str
    db_user: str
    db_password: str = field(repr=False)
    fernet_key: str = field(repr=False)
    token_hmac_key: str = field(repr=False)
    log_dir: Path
    data_dir: Path
    log_level: str
    reconcile_interval: float


def parse_env_file(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ConfigError(f"config line {lineno}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if not _KEY_RE.match(key):
            raise ConfigError(f"config line {lineno}: invalid key name")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        result[key] = value
    return result


def _int(values: Mapping[str, str], key: str, lo: int, hi: int, default: str | None = None) -> int:
    raw = values.get(key, default)
    try:
        number = int(raw)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        raise ConfigError(f"{key} must be an integer") from None
    if not lo <= number <= hi:
        raise ConfigError(f"{key} must be between {lo} and {hi}")
    return number


def _float(values: Mapping[str, str], key: str, lo: float, hi: float, default: str) -> float:
    try:
        number = float(values.get(key, default))
    except ValueError:
        raise ConfigError(f"{key} must be a number") from None
    if not lo <= number <= hi:
        raise ConfigError(f"{key} must be between {lo} and {hi}")
    return number


def settings_from_mapping(values: Mapping[str, str]) -> Settings:
    missing = [k for k in REQUIRED_KEYS if not values.get(k)]
    if missing:
        raise ConfigError("missing required config keys: " + ", ".join(missing))
    token = values["SHOPBOTS_CENTRAL_BOT_TOKEN"]
    if not validate_token_format(token):
        raise ConfigError("SHOPBOTS_CENTRAL_BOT_TOKEN has an invalid format")
    for key in ("SHOPBOTS_FERNET_KEY", "SHOPBOTS_TOKEN_HMAC_KEY"):
        try:
            decode_key(values[key], key)
        except ValueError as exc:
            raise ConfigError(str(exc)) from None
    level = values.get("SHOPBOTS_LOG_LEVEL", "INFO").upper()
    if level not in LOG_LEVELS:
        raise ConfigError("SHOPBOTS_LOG_LEVEL must be one of " + ", ".join(LOG_LEVELS))
    return Settings(
        central_bot_token=token,
        owner_id=_int(values, "SHOPBOTS_OWNER_ID", 1, 2**63 - 1),
        db_host=values.get("SHOPBOTS_DB_HOST", "127.0.0.1"),
        db_port=_int(values, "SHOPBOTS_DB_PORT", 1, 65535, default="5432"),
        db_name=values.get("SHOPBOTS_DB_NAME", "shopbots"),
        db_user=values.get("SHOPBOTS_DB_USER", "shopbots"),
        db_password=values["SHOPBOTS_DB_PASSWORD"],
        fernet_key=values["SHOPBOTS_FERNET_KEY"],
        token_hmac_key=values["SHOPBOTS_TOKEN_HMAC_KEY"],
        log_dir=Path(values.get("SHOPBOTS_LOG_DIR", "/var/log/shopbots")),
        data_dir=Path(values.get("SHOPBOTS_DATA_DIR", "/var/lib/shopbots")),
        log_level=level,
        reconcile_interval=_float(values, "SHOPBOTS_RECONCILE_INTERVAL", 2, 300, default="15"),
    )


def load_settings(path: str | None = None) -> Settings:
    cfg_path = Path(path or os.environ.get("SHOPBOTS_CONFIG") or DEFAULT_CONFIG_PATH)
    try:
        text = cfg_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise ConfigError(f"config file not found: {cfg_path}") from None
    except PermissionError:
        raise ConfigError(f"permission denied reading config: {cfg_path}") from None
    return settings_from_mapping(parse_env_file(text))
SHOPBOTS_FILE_EOF

# >>> file: shopbots/db.py
    cat >"$d/shopbots/db.py" <<'SHOPBOTS_FILE_EOF'
"""PostgreSQL connections (asyncpg)."""

from __future__ import annotations

from typing import Any

import asyncpg

from .config import Settings


def connect_kwargs(settings: Settings) -> dict[str, Any]:
    return {
        "host": settings.db_host,
        "port": settings.db_port,
        "user": settings.db_user,
        "password": settings.db_password,
        "database": settings.db_name,
        "timeout": 10,
        "command_timeout": 30,
        "server_settings": {"application_name": "shopbots"},
    }


async def create_pool(settings: Settings, *, min_size: int = 1, max_size: int = 10) -> asyncpg.Pool:
    return await asyncpg.create_pool(min_size=min_size, max_size=max_size, **connect_kwargs(settings))


async def connect(settings: Settings) -> asyncpg.Connection:
    return await asyncpg.connect(**connect_kwargs(settings))
SHOPBOTS_FILE_EOF

# >>> file: shopbots/tenant.py
    cat >"$d/shopbots/tenant.py" <<'SHOPBOTS_FILE_EOF'
"""Trusted tenant context. Only the supervisor injects shop_id from the DB-bound bot slot."""
from __future__ import annotations
from contextlib import asynccontextmanager
import asyncpg

@asynccontextmanager
async def tenant_transaction(pool: asyncpg.Pool, shop_id: int):
    if not isinstance(shop_id, int) or shop_id <= 0:
        raise ValueError("invalid trusted shop id")
    async with pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('shopbots.shop_id', $1, true)", str(shop_id))
            yield conn

async def set_tenant(conn: asyncpg.Connection, shop_id: int) -> None:
    if not isinstance(shop_id, int) or shop_id <= 0:
        raise ValueError("invalid trusted shop id")
    await conn.execute("SELECT set_config('shopbots.shop_id', $1, false)", str(shop_id))
SHOPBOTS_FILE_EOF

# >>> file: shopbots/handlers/__init__.py
    cat >"$d/shopbots/handlers/__init__.py" <<'SHOPBOTS_FILE_EOF'
"""Telegram update handlers (central + seller)."""
SHOPBOTS_FILE_EOF

# >>> file: shopbots/handlers/central.py
    cat >"$d/shopbots/handlers/central.py" <<'SHOPBOTS_FILE_EOF'
"""Central (owner) bot: dynamic registration and control of seller bots."""

from __future__ import annotations

import logging
import time
from typing import TYPE_CHECKING

import asyncpg
from aiogram import Bot, F, Router
from aiogram.exceptions import TelegramAPIError, TelegramUnauthorizedError
from aiogram.filters import Command, CommandObject, CommandStart
from aiogram.types import Message

from .. import __version__
from ..config import Settings
from ..repo import bots as bots_repo
from ..repo import subscriptions
from ..security import TokenVault, bot_id_from_token, validate_token_format

if TYPE_CHECKING:
    from ..supervisor import Supervisor

log = logging.getLogger("shopbots.central")

STATUS_FA = {"active": "فعال", "disabled": "غیرفعال", "invalid_token": "توکن نامعتبر"}
MAX_MESSAGE = 3800

HELP = (
    "پنل مالک سامانه\n\n"
    "/status — وضعیت سرویس\n"
    "/bots — فهرست ربات‌های فروشگاه\n"
    "/addbot <توکن> [admin_tg_id] — افزودن ربات فروشگاه و ثبت ادمین عددی\n"
    "/disablebot <شناسه> — توقف ربات فروشگاه\n"
    "/enablebot <شناسه> — فعال‌سازی دوباره\n\n"
    "پیام حاوی توکن بلافاصله حذف می‌شود."
)


async def _try_delete(message: Message) -> bool:
    try:
        await message.delete()
        return True
    except TelegramAPIError:
        return False


def _chunks(lines: list[str]) -> list[str]:
    chunks, current = [], ""
    for line in lines:
        if len(current) + len(line) + 1 > MAX_MESSAGE and current:
            chunks.append(current)
            current = ""
        current += line + "\n"
    if current:
        chunks.append(current)
    return chunks


def _parse_id(command: CommandObject) -> int | None:
    raw = (command.args or "").strip().lstrip("#")
    return int(raw) if raw.isdigit() and len(raw) < 19 else None


def build_central_router(owner_id: int) -> Router:
    router = Router(name="central")
    router.message.filter(F.chat.type == "private")

    owner = Router(name="central-owner")
    owner.message.filter(F.from_user.id == owner_id)
    guest = Router(name="central-guest")

    @owner.message(CommandStart())
    @owner.message(Command("help"))
    async def cmd_help(message: Message) -> None:
        await message.answer(HELP)

    @owner.message(Command("status"))
    async def cmd_status(message: Message, pool: asyncpg.Pool, supervisor: "Supervisor") -> None:
        counts = await bots_repo.count_by_status(pool)
        snapshot = supervisor.snapshot()
        running = sum(1 for s in snapshot if s["running"] and s["kind"] == "seller")
        uptime = int(time.monotonic() - supervisor.started_monotonic)
        lines = [
            f"نسخه: {__version__}",
            f"مدت اجرا: {uptime // 3600} ساعت و {uptime % 3600 // 60} دقیقه",
            f"ربات‌های فروشگاه در حال اجرا: {running}",
            "ثبت‌شده‌ها: "
            + "، ".join(f"{STATUS_FA[k]} {v}" for k, v in counts.items()),
        ]
        problems = [s for s in snapshot if not s["running"] and s["last_error"]][:10]
        if problems:
            lines.append("\nخطاهای اخیر:")
            lines += [f"• {s['key']}: {s['last_error'][:150]}" for s in problems]
        await message.answer("\n".join(lines))

    @owner.message(Command("bots"))
    async def cmd_bots(message: Message, pool: asyncpg.Pool, supervisor: "Supervisor") -> None:
        records = await bots_repo.list_all(pool)
        if not records:
            await message.answer("هنوز ربات فروشگاهی ثبت نشده است. با /addbot اضافه کنید.")
            return
        running_ids = {s["bot_db_id"] for s in supervisor.snapshot() if s["running"]}
        lines = []
        for r in records:
            state = STATUS_FA.get(r.status, r.status)
            if r.id in running_ids:
                state += " · در حال اجرا"
            lines.append(f"#{r.id} @{r.username or '?'} | {r.shop_title or '-'} | {state}")
            if r.last_error and r.id not in running_ids:
                lines.append(f"   ↳ {r.last_error[:150]}")
        for chunk in _chunks(lines):
            await message.answer(chunk)

    @owner.message(Command("addbot"))
    async def cmd_addbot(
        message: Message, command: CommandObject, pool: asyncpg.Pool, vault: TokenVault, settings: Settings
    ) -> None:
        parts = (command.args or "").strip().split()
        token = parts[0] if parts else ""
        shop_admin_tg_id = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() and int(parts[1]) > 0 else None
        deleted = await _try_delete(message)
        warn = "" if deleted else "\n⚠️ پیام حاوی توکن حذف نشد؛ آن را دستی پاک کنید."
        if not token:
            await message.answer("روش استفاده: /addbot <توکن BotFather>")
            return
        if not validate_token_format(token):
            await message.answer("فرمت توکن نادرست است." + warn)
            return
        if bot_id_from_token(token) == bot_id_from_token(settings.central_bot_token):
            await message.answer("این توکن ربات مرکزی است و نمی‌تواند ربات فروشگاه باشد." + warn)
            return
        probe = Bot(token=token)
        try:
            me = await probe.get_me()
        except TelegramUnauthorizedError:
            await message.answer("تلگرام این توکن را نپذیرفت (نامعتبر یا باطل‌شده)." + warn)
            return
        except TelegramAPIError as exc:
            log.warning("addbot probe failed: %s", type(exc).__name__)
            await message.answer("ارتباط با تلگرام برقرار نشد؛ کمی بعد دوباره تلاش کنید." + warn)
            return
        finally:
            await probe.session.close()
        try:
            record, created = await bots_repo.register_bot(
                pool,
                vault,
                token=token,
                telegram_bot_id=me.id,
                username=me.username,
                display_name=me.full_name,
                actor_tg_id=message.from_user.id,
                shop_admin_tg_id=shop_admin_tg_id,
            )
        except asyncpg.UniqueViolationError:
            await message.answer("ثبت هم‌زمان تکراری رخ داد؛ دوباره تلاش کنید." + warn)
            return
        verb = "ثبت شد" if created else "به‌روزرسانی شد (توکن جایگزین شد، داده فروشگاه حفظ شد)"
        await message.answer(f"ربات @{record.username} با شناسه #{record.id} {verb} و تا چند ثانیه دیگر اجرا می‌شود." + warn)

    async def _change_status(message: Message, command: CommandObject, pool: asyncpg.Pool, status: str) -> None:
        bot_id = _parse_id(command)
        if bot_id is None:
            await message.answer("شناسه عددی ربات را وارد کنید؛ مثلا /disablebot 3")
            return
        record = await bots_repo.set_status(pool, bot_id, status, message.from_user.id)
        if record is None:
            await message.answer(f"ربات #{bot_id} پیدا نشد.")
            return
        await message.answer(f"وضعیت ربات #{record.id} (@{record.username or '?'}): {STATUS_FA[record.status]}")

    @owner.message(Command("disablebot"))
    async def cmd_disable(message: Message, command: CommandObject, pool: asyncpg.Pool) -> None:
        await _change_status(message, command, pool, "disabled")

    @owner.message(Command("enablebot"))
    async def cmd_enable(message: Message, command: CommandObject, pool: asyncpg.Pool) -> None:
        await _change_status(message, command, pool, "active")

    @owner.message(Command("setplan"))
    async def cmd_setplan(message: Message, command: CommandObject, pool: asyncpg.Pool) -> None:
        parts=(command.args or "").split()
        if len(parts)!=4 or not parts[1].isdigit() or parts[2] not in subscriptions.METHODS or not parts[3].isdigit():
            await message.answer("روش: /setplan نام مدت_روز package|daily|custom قیمت_ریال")
            return
        name,days,method,price=parts
        await pool.execute("INSERT INTO subscription_plans(name,duration_days,pricing_method,price_irr) VALUES($1,$2,$3,$4)",name,int(days),method,int(price))
        await message.answer("بسته اشتراک ثبت شد.")

    @owner.message(Command("approve"))
    async def cmd_approve(message: Message, command: CommandObject, pool: asyncpg.Pool) -> None:
        request_id=(command.args or "").strip()
        if not request_id:
            await message.answer("روش: /approve شناسه_درخواست")
            return
        try:
            shop=await subscriptions.approve_subscription(pool,request_id=request_id,actor_tg_id=message.from_user.id)
        except (ValueError, asyncpg.PostgresError):
            await message.answer("درخواست پیدا نشد یا قبلاً تعیین تکلیف شده است.")
            return
        await message.answer(f"اشتراک فروشگاه #{shop['id']} تأیید شد و تمدید آن از پایان اعتبار فعلی محاسبه شد.")

    @owner.message()
    async def owner_fallback(message: Message) -> None:
        await message.answer("دستور شناخته نشد. /help")

    @guest.message()
    async def guest_any(message: Message) -> None:
        await message.answer("این ربات مخصوص مدیریت سامانه است.")

    # Order matters: owner router first, guest catch-all last.
    router.include_router(owner)
    router.include_router(guest)
    return router
SHOPBOTS_FILE_EOF

# >>> file: shopbots/handlers/seller.py
    cat >"$d/shopbots/handlers/seller.py" <<'SHOPBOTS_FILE_EOF'
"""Persian, mobile-first seller menu with operation-level subscription checks."""
from __future__ import annotations
import asyncpg
from aiogram import F, Router
from aiogram.filters import CommandStart, Command
from aiogram.types import Message, ReplyKeyboardMarkup, KeyboardButton
from ..repo import subscriptions

MENU = ReplyKeyboardMarkup(keyboard=[[KeyboardButton(text="فروش نقدی"),KeyboardButton(text="فروش به حساب")],[KeyboardButton(text="حساب مشتری‌ها"),KeyboardButton(text="ثبت مشتری")],[KeyboardButton(text="مدیریت کالاها"),KeyboardButton(text="گزارش‌ها")],[KeyboardButton(text="تنظیمات"),KeyboardButton(text="وضعیت اشتراک")]], resize_keyboard=True)

def build_seller_router() -> Router:
    router=Router(name="seller"); router.message.filter(F.chat.type == "private")
    async def shop_context(pool, bot_id):
        async with pool.acquire() as c:
            row=await c.fetchrow("SELECT s.id,s.title,s.owner_tg_id,s.subscription_status,s.subscription_ends_at FROM shops s WHERE s.bot_id=$1",bot_id)
            if row: await c.execute("SELECT set_config('shopbots.shop_id',$1,true)",str(row['id']))
            return row
    @router.message(CommandStart())
    async def start(message: Message,pool: asyncpg.Pool,shop_bot_id:int):
        row=await shop_context(pool,shop_bot_id)
        await message.answer(f"به «{(row['title'] if row else 'فروشگاه')}» خوش آمدید.\nاز منوی زیر انتخاب کنید.",reply_markup=MENU)
    @router.message(Command("subscribe"))
    async def subscribe(message:Message,command, pool:asyncpg.Pool,shop_bot_id:int):
        row=await shop_context(pool,shop_bot_id); raw=(command.args or "").strip()
        if not row or not raw.isdigit() or int(raw)<=0: return await message.answer("روش: /subscribe تعداد_روز")
        plan=await pool.fetchrow("SELECT * FROM subscription_plans WHERE active=true AND duration_days=$1 ORDER BY id DESC LIMIT 1",int(raw))
        if not plan: return await message.answer("برای این مدت بسته فعالی تنظیم نشده است.")
        price= subscriptions.quote_price(int(raw),pricing_method=plan['pricing_method'],package_price_irr=plan['price_irr'] if plan['pricing_method']=='package' else None,daily_rate_irr=plan['price_irr'] if plan['pricing_method']=='daily' else None,custom_price_irr=plan['price_irr'] if plan['pricing_method']=='custom' else None)
        req=await subscriptions.request_subscription(pool,shop_id=int(row['id']),duration_days=int(raw),quoted_price_irr=price,requested_by=message.from_user.id,request_key=f"{row['id']}:{message.from_user.id}:{raw}")
        await message.answer(f"هزینه اشتراک: {price:,} ریال\nدرخواست ثبت شد و پس از تأیید ادمین مرکزی فعال می‌شود.\nشناسه: {req['id']}")
    @router.message(F.text == "وضعیت اشتراک")
    async def status(message: Message,pool:asyncpg.Pool,shop_bot_id:int):
        row=await shop_context(pool,shop_bot_id)
        end=row['subscription_ends_at'].astimezone().strftime('%Y-%m-%d %H:%M') if row and row['subscription_ends_at'] else 'بدون تاریخ'
        await message.answer(f"وضعیت: {row['subscription_status'] if row else 'نامشخص'}\nپایان اعتبار: {end}")
    @router.message()
    async def menu(message:Message,pool:asyncpg.Pool,shop_bot_id:int):
        row=await shop_context(pool,shop_bot_id)
        if not row: return await message.answer("فروشگاه پیدا نشد.")
        is_owner=message.from_user.id==row['owner_tg_id']
        customer_read=not is_owner
        allowed=await subscriptions.operation_allowed(pool, int(row['id']), customer_read=customer_read)
        if not allowed:
            await message.answer("اشتراک فروشگاه منقضی یا معلق است. مشاهده حساب‌ها و خروجی برای مالک همچنان مجاز است.")
            return
        await message.answer("این بخش در مرحله بعد تکمیل می‌شود و از همین منو متصل خواهد شد.")
    return router
SHOPBOTS_FILE_EOF
# >>> file: shopbots/locks.py
    cat >"$d/shopbots/locks.py" <<'SHOPBOTS_FILE_EOF'
"""Guarantees a single poller per Telegram bot across all processes/hosts sharing the DB.

All session-level advisory locks live on ONE dedicated connection (not one per bot),
so hundreds of bots do not exhaust PostgreSQL connections. If that connection dies,
PostgreSQL releases every lock; the supervisor detects it via ping() and stops all
runners before reconnecting, so two pollers can never run for the same token."""

from __future__ import annotations

import asyncio
import logging

import asyncpg

from . import db
from .config import Settings

log = logging.getLogger("shopbots.locks")


class AdvisoryLockManager:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._conn: asyncpg.Connection | None = None
        self._mutex = asyncio.Lock()
        self._held: set[int] = set()

    @property
    def held(self) -> frozenset[int]:
        return frozenset(self._held)

    async def reconnect(self) -> None:
        async with self._mutex:
            await self._close_locked()
            self._conn = await db.connect(self._settings)
            self._held.clear()
            log.info("advisory lock connection established")

    async def ping(self) -> bool:
        async with self._mutex:
            if self._conn is None or self._conn.is_closed():
                return False
            try:
                await asyncio.wait_for(self._conn.fetchval("SELECT 1"), timeout=5)
                return True
            except (asyncio.TimeoutError, asyncpg.PostgresError, OSError, asyncpg.InterfaceError):
                return False

    async def try_acquire(self, key: int) -> bool:
        async with self._mutex:
            if self._conn is None or self._conn.is_closed():
                raise ConnectionError("advisory lock connection is not available")
            if key in self._held:
                return False  # already polling in this process
            ok = bool(await self._conn.fetchval("SELECT pg_try_advisory_lock($1)", key))
            if ok:
                self._held.add(key)
            return ok

    async def release(self, key: int) -> None:
        async with self._mutex:
            if key not in self._held:
                return
            self._held.discard(key)
            if self._conn is None or self._conn.is_closed():
                return
            await self._conn.fetchval("SELECT pg_advisory_unlock($1)", key)

    async def close(self) -> None:
        async with self._mutex:
            await self._close_locked()

    async def _close_locked(self) -> None:
        if self._conn is not None and not self._conn.is_closed():
            try:
                await asyncio.wait_for(self._conn.close(), timeout=5)
            except Exception:  # noqa: BLE001 - best effort on shutdown
                self._conn.terminate()
        self._conn = None
        self._held.clear()
SHOPBOTS_FILE_EOF

# >>> file: shopbots/logging_setup.py
    cat >"$d/shopbots/logging_setup.py" <<'SHOPBOTS_FILE_EOF'
"""Logging with mandatory secret redaction. Bot tokens never reach log files or journald."""

from __future__ import annotations

import logging
import logging.handlers
import re
import sys
from pathlib import Path

TOKEN_PATTERN = re.compile(r"\d{5,20}:[A-Za-z0-9_-]{30,64}")
REDACTED = "<redacted-token>"


def redact(text: str) -> str:
    return TOKEN_PATTERN.sub(REDACTED, text)


class RedactingFormatter(logging.Formatter):
    """Redacts the fully formatted record, including exception tracebacks."""

    def format(self, record: logging.LogRecord) -> str:
        return redact(super().format(record))


FORMAT = "%(asctime)s %(levelname)s [%(name)s] %(message)s"


def _reset_root(level: str) -> logging.Logger:
    root = logging.getLogger()
    root.setLevel(level)
    for handler in list(root.handlers):
        root.removeHandler(handler)
    # aiogram logs every handled update at INFO; keep it quiet.
    logging.getLogger("aiogram.event").setLevel(logging.WARNING)
    return root


def setup_service_logging(log_dir: Path, level: str, filename: str = "app.log") -> None:
    """File log (rotated by logrotate; WatchedFileHandler reopens) + WARNING+ to journald via stderr."""
    root = _reset_root(level)
    formatter = RedactingFormatter(FORMAT)
    try:
        file_handler = logging.handlers.WatchedFileHandler(log_dir / filename, encoding="utf-8")
        file_handler.setFormatter(formatter)
        root.addHandler(file_handler)
    except OSError as exc:
        print(f"shopbots: cannot open log file in {log_dir}: {exc.strerror}", file=sys.stderr)
    console = logging.StreamHandler(sys.stderr)
    console.setLevel(logging.WARNING)
    console.setFormatter(formatter)
    root.addHandler(console)


def setup_console_logging(level: str = "INFO") -> None:
    root = _reset_root(level)
    console = logging.StreamHandler(sys.stderr)
    console.setFormatter(RedactingFormatter(FORMAT))
    root.addHandler(console)
SHOPBOTS_FILE_EOF

# >>> file: shopbots/migrate.py
    cat >"$d/shopbots/migrate.py" <<'SHOPBOTS_FILE_EOF'
"""Forward-only, checksummed SQL migrations. Each migration runs in its own transaction
under a PostgreSQL advisory lock, so concurrent runs are safe and a failed migration
leaves no partial schema. Applied migrations are never edited (checksum enforced)."""

from __future__ import annotations

import hashlib
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:  # runtime import not needed; keeps discover() testable without the driver
    import asyncpg

log = logging.getLogger("shopbots.migrate")

MIGRATIONS_DIR = Path(__file__).resolve().parent / "migrations"
NAME_RE = re.compile(r"^(\d{4})_([a-z0-9_]+)\.sql$")
# Negative key: never collides with bot polling locks (positive Telegram bot ids).
MIGRATION_LOCK_KEY = -7311000001

_BOOTSTRAP = """
CREATE TABLE IF NOT EXISTS schema_migrations (
    version    text PRIMARY KEY,
    name       text NOT NULL,
    checksum   text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
)
"""


class MigrationError(Exception):
    pass


@dataclass(frozen=True)
class Migration:
    version: str
    name: str
    sql: str = field(repr=False)
    checksum: str


@dataclass(frozen=True)
class MigrationStatus:
    applied: list[str]
    pending: list[str]
    mismatched: list[str]

    @property
    def up_to_date(self) -> bool:
        return not self.pending and not self.mismatched


def discover(directory: Path = MIGRATIONS_DIR) -> list[Migration]:
    migrations: list[Migration] = []
    seen: set[str] = set()
    for path in sorted(directory.iterdir()):
        if path.suffix != ".sql":
            continue
        match = NAME_RE.match(path.name)
        if not match:
            raise MigrationError(f"invalid migration file name: {path.name}")
        version = match.group(1)
        if version in seen:
            raise MigrationError(f"duplicate migration version: {version}")
        seen.add(version)
        data = path.read_bytes()
        migrations.append(
            Migration(version=version, name=match.group(2), sql=data.decode("utf-8"), checksum=hashlib.sha256(data).hexdigest())
        )
    return migrations


async def _applied(conn: asyncpg.Connection) -> dict[str, str]:
    exists = await conn.fetchval("SELECT to_regclass('public.schema_migrations') IS NOT NULL")
    if not exists:
        return {}
    rows = await conn.fetch("SELECT version, checksum FROM schema_migrations")
    return {r["version"]: r["checksum"] for r in rows}


async def check_status(conn: asyncpg.Connection, migrations: list[Migration] | None = None) -> MigrationStatus:
    migrations = discover() if migrations is None else migrations
    applied = await _applied(conn)
    known = {m.version: m for m in migrations}
    mismatched = [v for v, c in applied.items() if v in known and known[v].checksum != c]
    unknown = [v for v in applied if v not in known]
    pending = [m.version for m in migrations if m.version not in applied]
    # A database migrated by a newer release than this code is reported as mismatch.
    return MigrationStatus(applied=sorted(applied), pending=pending, mismatched=sorted(mismatched + unknown))


async def apply_migrations(conn: asyncpg.Connection, migrations: list[Migration] | None = None) -> list[str]:
    migrations = discover() if migrations is None else migrations
    async with conn.transaction():
        await conn.execute("SELECT pg_advisory_xact_lock($1)", MIGRATION_LOCK_KEY)
        await conn.execute(_BOOTSTRAP)
    status = await check_status(conn, migrations)
    if status.mismatched:
        raise MigrationError(
            "applied migrations differ from this release (edited or newer schema): " + ", ".join(status.mismatched)
        )
    done: list[str] = []
    for migration in migrations:
        async with conn.transaction():
            await conn.execute("SELECT pg_advisory_xact_lock($1)", MIGRATION_LOCK_KEY)
            already = await conn.fetchval("SELECT 1 FROM schema_migrations WHERE version = $1", migration.version)
            if already:
                continue
            log.info("applying migration %s_%s", migration.version, migration.name)
            await conn.execute(migration.sql)
            await conn.execute(
                "INSERT INTO schema_migrations (version, name, checksum) VALUES ($1, $2, $3)",
                migration.version,
                migration.name,
                migration.checksum,
            )
            done.append(migration.version)
    return done
SHOPBOTS_FILE_EOF

# >>> file: shopbots/migrations/0001_initial.sql
    cat >"$d/shopbots/migrations/0001_initial.sql" <<'SHOPBOTS_FILE_EOF'
-- 0001_initial: core registry of bots/shops, audit trail and service heartbeat.
-- Rules for all future migrations: additive, never DROP user data, never edit an applied file.

CREATE TABLE app_meta (
    key        text PRIMARY KEY,
    value      text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE bots (
    id                bigserial PRIMARY KEY,
    telegram_bot_id   bigint NOT NULL UNIQUE,
    username          text,
    display_name      text,
    token_encrypted   bytea NOT NULL,
    token_fingerprint text NOT NULL UNIQUE,
    status            text NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'disabled', 'invalid_token')),
    last_error        text,
    last_error_at     timestamptz,
    last_started_at   timestamptz,
    created_by        bigint NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE shops (
    id         bigserial PRIMARY KEY,
    bot_id     bigint NOT NULL UNIQUE REFERENCES bots (id) ON DELETE RESTRICT,
    title      text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 128),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (
    id          bigserial PRIMARY KEY,
    at          timestamptz NOT NULL DEFAULT now(),
    actor_tg_id bigint,
    action      text NOT NULL,
    target      text,
    details     jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX audit_log_at_idx ON audit_log (at);

CREATE TABLE service_heartbeat (
    id           smallint PRIMARY KEY CHECK (id = 1),
    beat_at      timestamptz NOT NULL,
    pid          integer NOT NULL,
    version      text NOT NULL,
    running_bots integer NOT NULL,
    details      jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE FUNCTION shopbots_touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER bots_touch_updated_at BEFORE UPDATE ON bots
    FOR EACH ROW EXECUTE FUNCTION shopbots_touch_updated_at();
CREATE TRIGGER shops_touch_updated_at BEFORE UPDATE ON shops
    FOR EACH ROW EXECUTE FUNCTION shopbots_touch_updated_at();

-- Wake the bot supervisor immediately when the set of runnable bots changes.
CREATE FUNCTION shopbots_notify_bots_changed() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM pg_notify('shopbots_bots_changed', OLD.id::text);
    ELSE
        PERFORM pg_notify('shopbots_bots_changed', NEW.id::text);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER bots_changed_notify
    AFTER INSERT OR DELETE OR UPDATE OF status, token_encrypted, token_fingerprint ON bots
    FOR EACH ROW EXECUTE FUNCTION shopbots_notify_bots_changed();

INSERT INTO app_meta (key, value) VALUES ('schema_created_by', '0.1.0');
SHOPBOTS_FILE_EOF

# >>> file: shopbots/migrations/0002_multitenant_finance.sql
    cat >"$d/shopbots/migrations/0002_multitenant_finance.sql" <<'SHOPBOTS_FILE_EOF'
-- 0002_multitenant_finance: additive tenant boundary, shop settings and financial core.
-- All monetary amounts are integer rial (IRR). Never edit this file after release.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
ALTER TABLE shops ADD COLUMN owner_tg_id bigint;
ALTER TABLE shops ADD COLUMN contact_info text;
ALTER TABLE shops ADD COLUMN report_chat_id bigint;
ALTER TABLE shops ADD COLUMN display_currency text NOT NULL DEFAULT 'IRR' CHECK (display_currency IN ('IRR','IRT'));
ALTER TABLE shops ADD COLUMN timezone text NOT NULL DEFAULT 'Asia/Tehran';
ALTER TABLE shops ADD COLUMN use_jalali boolean NOT NULL DEFAULT true;
ALTER TABLE shops ADD COLUMN notification_settings jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE shops ADD COLUMN rounding_scale smallint NOT NULL DEFAULT 0 CHECK (rounding_scale BETWEEN 0 AND 4);
ALTER TABLE shops ADD COLUMN rounding_mode text NOT NULL DEFAULT 'ROUND_HALF_UP' CHECK (rounding_mode IN ('ROUND_HALF_UP','ROUND_HALF_EVEN','ROUND_DOWN','ROUND_UP'));
ALTER TABLE shops ADD COLUMN subscription_status text NOT NULL DEFAULT 'trial' CHECK (subscription_status IN ('trial','active','past_due','cancelled'));
ALTER TABLE shops ADD COLUMN subscription_ends_at timestamptz;
UPDATE shops SET owner_tg_id = COALESCE(owner_tg_id, (SELECT created_by FROM bots WHERE bots.id = shops.bot_id));
ALTER TABLE shops ALTER COLUMN owner_tg_id SET NOT NULL;
CREATE UNIQUE INDEX shops_owner_bot_idx ON shops(owner_tg_id, bot_id);

CREATE TABLE customers (
 id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
 telegram_user_id bigint, name text, phone text, metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(shop_id, id), UNIQUE(shop_id, telegram_user_id)
);
CREATE TABLE products (
 id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
 sku text, title text NOT NULL, description text, active boolean NOT NULL DEFAULT true,
 metadata jsonb NOT NULL DEFAULT '{}'::jsonb, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(shop_id, id), UNIQUE(shop_id, sku)
);
CREATE TABLE product_prices (
 id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
 product_id bigint NOT NULL, amount_irr bigint NOT NULL CHECK (amount_irr >= 0), valid_from timestamptz NOT NULL DEFAULT now(), valid_to timestamptz,
 FOREIGN KEY(shop_id, product_id) REFERENCES products(shop_id, id) ON DELETE RESTRICT,
 UNIQUE(shop_id, id)
);
CREATE TABLE report_groups (
 id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
 name text NOT NULL, chat_id bigint, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(shop_id,id), UNIQUE(shop_id,name)
);
CREATE TABLE shop_settings (
 shop_id bigint PRIMARY KEY REFERENCES shops(id) ON DELETE CASCADE,
 settings jsonb NOT NULL DEFAULT '{}'::jsonb, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE financial_transactions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
 idempotency_key text NOT NULL, external_ref text, description text, status text NOT NULL DEFAULT 'posted' CHECK(status IN ('pending','posted','void')),
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(shop_id,idempotency_key), UNIQUE(shop_id,id)
);
CREATE TABLE ledger_entries (
 id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
 transaction_id uuid NOT NULL, account text NOT NULL, amount_irr bigint NOT NULL, currency text NOT NULL DEFAULT 'IRR' CHECK(currency='IRR'),
 created_at timestamptz NOT NULL DEFAULT now(), metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
 FOREIGN KEY(shop_id, transaction_id) REFERENCES financial_transactions(shop_id,id) ON DELETE RESTRICT,
 UNIQUE(shop_id,id)
);
CREATE INDEX ledger_entries_shop_account_idx ON ledger_entries(shop_id, account, created_at);
CREATE TABLE financial_outbox (
 id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
 event_type text NOT NULL, aggregate_type text NOT NULL, aggregate_id text NOT NULL, payload jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), published_at timestamptz, attempts integer NOT NULL DEFAULT 0,
 UNIQUE(shop_id,id)
);
CREATE UNIQUE INDEX financial_outbox_dedupe_idx ON financial_outbox(shop_id,event_type,aggregate_type,aggregate_id);

CREATE OR REPLACE FUNCTION shopbots_tenant_id() RETURNS bigint LANGUAGE sql STABLE AS $$
 SELECT NULLIF(current_setting('shopbots.shop_id', true), '')::bigint
$$;
CREATE OR REPLACE FUNCTION shopbots_require_tenant() RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE v bigint := shopbots_tenant_id(); BEGIN IF v IS NULL THEN RAISE EXCEPTION 'tenant context is required'; END IF; RETURN v; END $$;

ALTER TABLE customers ENABLE ROW LEVEL SECURITY; ALTER TABLE products ENABLE ROW LEVEL SECURITY; ALTER TABLE product_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE report_groups ENABLE ROW LEVEL SECURITY; ALTER TABLE shop_settings ENABLE ROW LEVEL SECURITY; ALTER TABLE financial_transactions ENABLE ROW LEVEL SECURITY; ALTER TABLE ledger_entries ENABLE ROW LEVEL SECURITY; ALTER TABLE financial_outbox ENABLE ROW LEVEL SECURITY;
CREATE POLICY customers_tenant ON customers USING (shop_id = shopbots_require_tenant()) WITH CHECK (shop_id = shopbots_require_tenant());
CREATE POLICY products_tenant ON products USING (shop_id = shopbots_require_tenant()) WITH CHECK (shop_id = shopbots_require_tenant());
CREATE POLICY prices_tenant ON product_prices USING (shop_id = shopbots_require_tenant()) WITH CHECK (shop_id = shopbots_require_tenant());
CREATE POLICY groups_tenant ON report_groups USING (shop_id = shopbots_require_tenant()) WITH CHECK (shop_id = shopbots_require_tenant());
CREATE POLICY settings_tenant ON shop_settings USING (shop_id = shopbots_require_tenant()) WITH CHECK (shop_id = shopbots_require_tenant());
CREATE POLICY financial_tx_tenant ON financial_transactions USING (shop_id = shopbots_require_tenant()) WITH CHECK (shop_id = shopbots_require_tenant());
CREATE POLICY ledger_tenant ON ledger_entries USING (shop_id = shopbots_require_tenant()) WITH CHECK (shop_id = shopbots_require_tenant());
CREATE POLICY outbox_tenant ON financial_outbox USING (shop_id = shopbots_require_tenant()) WITH CHECK (shop_id = shopbots_require_tenant());
CREATE TRIGGER shops_touch_updated_at_0002 BEFORE UPDATE ON shops FOR EACH ROW EXECUTE FUNCTION shopbots_touch_updated_at();
SHOPBOTS_FILE_EOF

# >>> file: shopbots/migrations/0003_subscriptions_and_reports.sql
    cat >"$d/shopbots/migrations/0003_subscriptions_and_reports.sql" <<'SHOPBOTS_FILE_EOF'
-- 0003_subscriptions_and_reports: central-admin controlled subscriptions and safe report groups.
-- Additive only. Monetary values remain integer IRR and are never converted in storage.
CREATE TABLE subscription_plans (
 id bigserial PRIMARY KEY, name text NOT NULL, duration_days integer NOT NULL CHECK(duration_days > 0),
 pricing_method text NOT NULL CHECK(pricing_method IN ('package','daily','custom')),
 price_irr bigint NOT NULL CHECK(price_irr >= 0), active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE subscription_requests (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
 plan_id bigint REFERENCES subscription_plans(id) ON DELETE RESTRICT, duration_days integer NOT NULL CHECK(duration_days > 0),
 quoted_price_irr bigint NOT NULL CHECK(quoted_price_irr >= 0), status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','approved','rejected','expired')),
 request_key text NOT NULL, requested_by bigint NOT NULL, approved_by bigint, requested_at timestamptz NOT NULL DEFAULT now(), approved_at timestamptz,
 UNIQUE(shop_id, request_key)
);
CREATE TABLE subscription_events (
 id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
 request_id uuid REFERENCES subscription_requests(id) ON DELETE RESTRICT, event_type text NOT NULL CHECK(event_type IN ('started','renewed','suspended','expired','resumed','price_changed')),
 starts_at timestamptz, ends_at timestamptz, price_irr bigint, actor_tg_id bigint, details jsonb NOT NULL DEFAULT '{}'::jsonb, created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(shop_id, request_id, event_type)
);
CREATE TABLE subscription_payments (
 id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT, request_id uuid NOT NULL REFERENCES subscription_requests(id) ON DELETE RESTRICT,
 amount_irr bigint NOT NULL CHECK(amount_irr >= 0), payment_ref text NOT NULL, paid_at timestamptz NOT NULL DEFAULT now(), UNIQUE(shop_id, request_id), UNIQUE(shop_id, payment_ref)
);
ALTER TABLE shops ADD COLUMN IF NOT EXISTS subscription_suspended boolean NOT NULL DEFAULT false;
ALTER TABLE shops ADD COLUMN IF NOT EXISTS subscription_access_policy text NOT NULL DEFAULT 'owner_read_export' CHECK(subscription_access_policy IN ('owner_read_export','customer_read_only','deny_customer'));
ALTER TABLE shops ADD COLUMN IF NOT EXISTS scheduled_reports_after_expiry boolean NOT NULL DEFAULT false;
ALTER TABLE report_groups ADD COLUMN IF NOT EXISTS confirmed_at timestamptz;
ALTER TABLE report_groups ADD COLUMN IF NOT EXISTS confirmed_by bigint;
ALTER TABLE report_groups ADD COLUMN IF NOT EXISTS bot_verified boolean NOT NULL DEFAULT false;
ALTER TABLE report_groups ADD COLUMN IF NOT EXISTS financial_warning_ack boolean NOT NULL DEFAULT false;
ALTER TABLE report_groups ADD COLUMN IF NOT EXISTS configured_by bigint;
CREATE UNIQUE INDEX subscription_pending_once ON subscription_requests(shop_id) WHERE status='pending';
CREATE INDEX subscription_events_shop_created ON subscription_events(shop_id, created_at DESC);
ALTER TABLE subscription_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscription_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscription_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscription_payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY subscription_plans_tenant ON subscription_plans USING (true) WITH CHECK (true);
CREATE POLICY subscription_requests_tenant ON subscription_requests USING (shop_id = shopbots_require_tenant()) WITH CHECK (shop_id = shopbots_require_tenant());
CREATE POLICY subscription_events_tenant ON subscription_events USING (shop_id = shopbots_require_tenant()) WITH CHECK (shop_id = shopbots_require_tenant());
CREATE POLICY subscription_payments_tenant ON subscription_payments USING (shop_id = shopbots_require_tenant()) WITH CHECK (shop_id = shopbots_require_tenant());
SHOPBOTS_FILE_EOF

# >>> file: shopbots/migrations/0004_catalog_customers_ledger.sql
    cat >"$d/shopbots/migrations/0004_catalog_customers_ledger.sql" <<'SHOPBOTS_FILE_EOF'
-- 0004: catalog, customer accounts, immutable invoice snapshots and reconciliation.
CREATE TYPE product_measure AS ENUM ('unit','weight');
CREATE TABLE IF NOT EXISTS product_categories (id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT, name text NOT NULL, UNIQUE(shop_id,name));
CREATE TABLE IF NOT EXISTS catalog_products (
 id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT, code text NOT NULL, name text NOT NULL,
 category_id bigint REFERENCES product_categories(id) ON DELETE RESTRICT, measure product_measure NOT NULL, cash_price_irr bigint NOT NULL CHECK(cash_price_irr>=0), credit_markup_pct numeric(9,4) NOT NULL DEFAULT 0 CHECK(credit_markup_pct>=0),
 weight_scale smallint NOT NULL DEFAULT 2 CHECK(weight_scale BETWEEN 0 AND 6), active boolean NOT NULL DEFAULT true, archived_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(shop_id,code)
);
CREATE TABLE IF NOT EXISTS customer_sequences(shop_id bigint PRIMARY KEY REFERENCES shops(id) ON DELETE RESTRICT, next_code bigint NOT NULL DEFAULT 1 CHECK(next_code>0));
CREATE TABLE IF NOT EXISTS customers_v4 (
 id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT, code bigint NOT NULL, name text NOT NULL, phone text, phone_fingerprint text, cash_rate numeric(9,4) NOT NULL DEFAULT 0, credit_rate numeric(9,4) NOT NULL DEFAULT 0, note text, credit_limit_irr bigint NOT NULL DEFAULT 0 CHECK(credit_limit_irr>=0), active boolean NOT NULL DEFAULT true, archived_at timestamptz, phone_changed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(shop_id,code), UNIQUE(shop_id,id)
);
CREATE TABLE IF NOT EXISTS customer_opening_balances (id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT, customer_id bigint NOT NULL, amount_irr bigint NOT NULL, title text NOT NULL, balance_date date NOT NULL, description text, created_at timestamptz NOT NULL DEFAULT now(), FOREIGN KEY(shop_id,customer_id) REFERENCES customers_v4(shop_id,id) ON DELETE RESTRICT, UNIQUE(shop_id,customer_id));
CREATE TABLE IF NOT EXISTS account_events (
 id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT, customer_id bigint NOT NULL, event_type text NOT NULL CHECK(event_type IN ('opening_balance','sale','payment','prepayment','adjustment','return')), amount_irr bigint NOT NULL, description text, idempotency_key text NOT NULL, version bigint NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now(), FOREIGN KEY(shop_id,customer_id) REFERENCES customers_v4(shop_id,id) ON DELETE RESTRICT, UNIQUE(shop_id,idempotency_key)
);
CREATE TABLE IF NOT EXISTS invoice_items (
 id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT, account_event_id bigint NOT NULL REFERENCES account_events(id) ON DELETE RESTRICT, product_id bigint NOT NULL, product_code text NOT NULL, product_name text NOT NULL, measure text NOT NULL, quantity numeric(18,6) NOT NULL CHECK(quantity>0), weight_scale smallint NOT NULL, cash_unit_price_irr bigint NOT NULL, credit_markup_pct numeric(9,4) NOT NULL, unit_price_irr bigint NOT NULL, line_total_irr bigint NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), FOREIGN KEY(shop_id,product_id) REFERENCES catalog_products(shop_id,id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS account_events_customer_idx ON account_events(shop_id,customer_id,created_at);
ALTER TABLE catalog_products ENABLE ROW LEVEL SECURITY; ALTER TABLE customers_v4 ENABLE ROW LEVEL SECURITY; ALTER TABLE customer_opening_balances ENABLE ROW LEVEL SECURITY; ALTER TABLE account_events ENABLE ROW LEVEL SECURITY; ALTER TABLE invoice_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY catalog_tenant ON catalog_products USING(shop_id=shopbots_require_tenant()) WITH CHECK(shop_id=shopbots_require_tenant());
CREATE POLICY customers_v4_tenant ON customers_v4 USING(shop_id=shopbots_require_tenant()) WITH CHECK(shop_id=shopbots_require_tenant());
CREATE POLICY opening_tenant ON customer_opening_balances USING(shop_id=shopbots_require_tenant()) WITH CHECK(shop_id=shopbots_require_tenant());
CREATE POLICY account_events_tenant ON account_events USING(shop_id=shopbots_require_tenant()) WITH CHECK(shop_id=shopbots_require_tenant());
CREATE POLICY invoice_items_tenant ON invoice_items USING(shop_id=shopbots_require_tenant()) WITH CHECK(shop_id=shopbots_require_tenant());
SHOPBOTS_FILE_EOF

# >>> file: shopbots/migrations/0005_sales_carts.sql
    cat >"$d/shopbots/migrations/0005_sales_carts.sql" <<'SHOPBOTS_FILE_EOF'
-- 0005: cart checkout and immutable sales. Every sale writes invoice, snapshots, account event and outbox atomically.
CREATE TABLE IF NOT EXISTS carts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT, seller_tg_id bigint NOT NULL, mode text NOT NULL CHECK(mode IN ('cash','account')), customer_id bigint, version bigint NOT NULL DEFAULT 1, status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','confirmed','cancelled')), updated_at timestamptz NOT NULL DEFAULT now(), FOREIGN KEY(shop_id,customer_id) REFERENCES customers_v4(shop_id,id));
CREATE TABLE IF NOT EXISTS cart_items (id bigserial PRIMARY KEY, cart_id uuid NOT NULL REFERENCES carts(id) ON DELETE CASCADE, product_id bigint NOT NULL, quantity numeric(18,6) NOT NULL CHECK(quantity>0), expected_product_updated_at timestamptz NOT NULL, UNIQUE(cart_id,product_id));
CREATE TABLE IF NOT EXISTS sales_invoices (id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT, invoice_no bigint NOT NULL, cart_id uuid NOT NULL UNIQUE, customer_id bigint, mode text NOT NULL CHECK(mode IN ('cash','account')), total_irr bigint NOT NULL CHECK(total_irr>=0), previous_balance_irr bigint NOT NULL DEFAULT 0, credit_used_irr bigint NOT NULL DEFAULT 0, new_balance_irr bigint NOT NULL DEFAULT 0, seller_tg_id bigint NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), FOREIGN KEY(shop_id,customer_id) REFERENCES customers_v4(shop_id,id), UNIQUE(shop_id,invoice_no));
CREATE TABLE IF NOT EXISTS sale_items_snapshot (id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id) ON DELETE RESTRICT, invoice_id bigint NOT NULL REFERENCES sales_invoices(id) ON DELETE RESTRICT, product_id bigint NOT NULL, code text NOT NULL, name text NOT NULL, measure text NOT NULL, quantity numeric(18,6) NOT NULL, cash_unit_price_irr bigint NOT NULL, credit_markup_pct numeric(9,4) NOT NULL, unit_price_irr bigint NOT NULL, line_total_irr bigint NOT NULL);
CREATE TABLE IF NOT EXISTS invoice_sequences (shop_id bigint PRIMARY KEY REFERENCES shops(id) ON DELETE RESTRICT, next_no bigint NOT NULL DEFAULT 1 CHECK(next_no>0));
CREATE UNIQUE INDEX IF NOT EXISTS cart_open_owner ON carts(shop_id,seller_tg_id) WHERE status='open';
CREATE INDEX IF NOT EXISTS invoices_customer_idx ON sales_invoices(shop_id,customer_id,created_at);
ALTER TABLE carts ENABLE ROW LEVEL SECURITY; ALTER TABLE cart_items ENABLE ROW LEVEL SECURITY; ALTER TABLE sales_invoices ENABLE ROW LEVEL SECURITY; ALTER TABLE sale_items_snapshot ENABLE ROW LEVEL SECURITY;
CREATE POLICY carts_tenant ON carts USING(shop_id=shopbots_require_tenant()) WITH CHECK(shop_id=shopbots_require_tenant()); CREATE POLICY cart_items_tenant ON cart_items USING(cart_id IN(SELECT id FROM carts WHERE shop_id=shopbots_require_tenant())) WITH CHECK(cart_id IN(SELECT id FROM carts WHERE shop_id=shopbots_require_tenant())); CREATE POLICY invoices_tenant ON sales_invoices USING(shop_id=shopbots_require_tenant()) WITH CHECK(shop_id=shopbots_require_tenant()); CREATE POLICY snapshots_tenant ON sale_items_snapshot USING(shop_id=shopbots_require_tenant()) WITH CHECK(shop_id=shopbots_require_tenant());
SHOPBOTS_FILE_EOF

# >>> file: shopbots/repo/sales.py
    cat >"$d/shopbots/repo/sales.py" <<'SHOPBOTS_FILE_EOF'
"""Atomic, idempotent checkout. Positive account event means customer owes the shop."""
from __future__ import annotations
from decimal import Decimal, ROUND_HALF_UP

def line_total(quantity, unit_price:int)->int:
    q=Decimal(str(quantity));
    if q<=0 or unit_price<0: raise ValueError('invalid sale amount')
    return int((q*unit_price).quantize(Decimal('1'),rounding=ROUND_HALF_UP))

def account_totals(previous:int, purchase:int, credit_available:int=0):
    credit_used=min(max(previous*-1,0),purchase) if previous<0 else 0
    return credit_used,purchase-credit_used+max(previous,0)

def validate_debt(new_balance:int, limit:int, policy:str, override:bool=False):
    if limit<0 or policy not in ('unlimited','warn','block'): raise ValueError('invalid debt policy')
    if policy=='block' and new_balance>limit: raise PermissionError('credit limit exceeded')
    if policy=='warn' and new_balance>limit and not override: raise PermissionError('seller override required')
    return True

async def checkout(conn, *, shop_id:int, cart_id:str, seller_tg_id:int, expected_version:int, override_limit:bool=False):
    """Locks cart, customer and invoice sequence; retry returns the original invoice."""
    async with conn.transaction():
        await conn.execute("SELECT set_config('shopbots.shop_id',$1,true)",str(shop_id))
        cart=await conn.fetchrow("SELECT * FROM carts WHERE id=$1 AND shop_id=$2 FOR UPDATE",cart_id,shop_id)
        if not cart: raise ValueError('cart not found')
        existing=await conn.fetchrow("SELECT * FROM sales_invoices WHERE cart_id=$1",cart_id)
        if existing: return existing
        if cart['status']!='open' or int(cart['version'])!=expected_version: raise ValueError('cart changed or already confirmed')
        items=await conn.fetch("""SELECT ci.*,p.code,p.name,p.measure,p.cash_price_irr,p.credit_markup_pct,p.updated_at FROM cart_items ci JOIN catalog_products p ON p.id=ci.product_id AND p.shop_id=$1 WHERE ci.cart_id=$2 FOR UPDATE""",shop_id,cart_id)
        if not items: raise ValueError('empty cart')
        total=0; snaps=[]
        for x in items:
            if x['updated_at'] != x['expected_product_updated_at']: raise ValueError('product changed; refresh preview')
            unit=int(x['cash_price_irr']) if cart['mode']=='cash' else int((Decimal(x['cash_price_irr'])*(1+Decimal(x['credit_markup_pct'])/100)).quantize(Decimal('1'),rounding=ROUND_HALF_UP))
            amount=line_total(x['quantity'],unit); total+=amount; snaps.append((x,unit,amount))
        previous=0; limit=0; policy='unlimited'
        if cart['customer_id']:
            customer=await conn.fetchrow("SELECT * FROM customers_v4 WHERE shop_id=$1 AND id=$2 FOR UPDATE",shop_id,cart['customer_id'])
            previous=int(await conn.fetchval("SELECT COALESCE(sum(amount_irr),0) FROM account_events WHERE shop_id=$1 AND customer_id=$2",shop_id,cart['customer_id']))
            limit=int(customer['credit_limit_irr']); policy=(await conn.fetchval("SELECT COALESCE(settings->>'debt_policy','unlimited') FROM shop_settings WHERE shop_id=$1",shop_id)) or 'unlimited'
        credit_used,new_balance=account_totals(previous,total,0)
        if cart['mode']=='cash': new_balance=previous
        validate_debt(new_balance,limit,policy,override_limit)
        seq=await conn.fetchrow("INSERT INTO invoice_sequences(shop_id,next_no) VALUES($1,2) ON CONFLICT(shop_id) DO UPDATE SET next_no=invoice_sequences.next_no+1 RETURNING next_no-1 AS no",shop_id)
        invoice=await conn.fetchrow("INSERT INTO sales_invoices(shop_id,invoice_no,cart_id,customer_id,mode,total_irr,previous_balance_irr,credit_used_irr,new_balance_irr,seller_tg_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING *",shop_id,seq['no'],cart_id,cart['customer_id'],cart['mode'],total,previous,credit_used,new_balance,seller_tg_id)
        for x,unit,amount in snaps:
            await conn.execute("INSERT INTO sale_items_snapshot(shop_id,invoice_id,product_id,code,name,measure,quantity,cash_unit_price_irr,credit_markup_pct,unit_price_irr,line_total_irr) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",shop_id,invoice['id'],x['product_id'],x['code'],x['name'],x['measure'],x['quantity'],x['cash_price_irr'],x['credit_markup_pct'],unit,amount)
        if cart['customer_id']: await conn.execute("INSERT INTO account_events(shop_id,customer_id,event_type,amount_irr,description,idempotency_key) VALUES($1,$2,'sale',$3,$4,$5)",shop_id,cart['customer_id'],(new_balance-previous if cart['mode']=='account' else 0),'فروش نقدی' if cart['mode']=='cash' else 'فروش فاکتور',f'sale:{invoice["id"]}')
        await conn.execute("INSERT INTO financial_outbox(shop_id,event_type,aggregate_type,aggregate_id,payload) VALUES($1,'sale.report_requested','invoice',$2,jsonb_build_object('invoice_id',$2)) ON CONFLICT DO NOTHING",shop_id,str(invoice['id']))
        await conn.execute("INSERT INTO financial_outbox(shop_id,event_type,aggregate_type,aggregate_id,payload) VALUES($1,'sale.customer_notification','invoice',$2,jsonb_build_object('invoice_id',$2)) ON CONFLICT DO NOTHING",shop_id,str(invoice['id']))
        await conn.execute("UPDATE carts SET status='confirmed',version=version+1,updated_at=now() WHERE id=$1",cart_id)
        return invoice
SHOPBOTS_FILE_EOF

# >>> file: shopbots/repo/catalog.py
    cat >"$d/shopbots/repo/catalog.py" <<'SHOPBOTS_FILE_EOF'
"""Tenant-safe catalog with strict quantity validation and historical price snapshots."""
from __future__ import annotations
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

def normalize_quantity(value: str|int|float|Decimal, measure: str, scale: int=2) -> Decimal:
    try: q=Decimal(str(value).replace('٬', '').replace('،','.').replace('٫','.').translate(str.maketrans('۰۱۲۳۴۵۶۷۸۹','0123456789')))
    except (InvalidOperation,ValueError): raise ValueError('invalid quantity')
    if q<=0: raise ValueError('quantity must be positive')
    if measure=='unit' and (q != q.to_integral_value()): raise ValueError('unit quantity must be integer')
    quantum=Decimal(1).scaleb(-scale)
    if q.quantize(quantum,rounding=ROUND_HALF_UP)!=q: raise ValueError('quantity exceeds allowed precision')
    return q

def credit_price(cash_price_irr:int, markup_pct:Decimal|str|int) -> int:
    if cash_price_irr<0 or Decimal(str(markup_pct))<0: raise ValueError('invalid price')
    return int((Decimal(cash_price_irr)*(Decimal(1)+Decimal(str(markup_pct))/100)).quantize(Decimal('1'),rounding=ROUND_HALF_UP))

async def create_product(conn, *, shop_id:int, code:str, name:str, measure:str, cash_price_irr:int, credit_markup_pct, category_id=None, weight_scale:int=2):
    if not code.strip() or not name.strip() or measure not in ('unit','weight'): raise ValueError('invalid product')
    if cash_price_irr<0 or weight_scale<0 or weight_scale>6: raise ValueError('invalid product price or scale')
    return await conn.fetchrow("INSERT INTO catalog_products(shop_id,code,name,category_id,measure,cash_price_irr,credit_markup_pct,weight_scale) VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *",shop_id,code.strip(),name.strip(),category_id,measure,cash_price_irr,credit_markup_pct,weight_scale)

async def list_products(conn, shop_id:int, query:str='', limit:int=20, offset:int=0):
    return await conn.fetch("SELECT * FROM catalog_products WHERE shop_id=$1 AND archived_at IS NULL AND ($2='' OR code ILIKE '%'||$2||'%' OR name ILIKE '%'||$2||'%') ORDER BY id DESC LIMIT $3 OFFSET $4",shop_id,query,limit,offset)
SHOPBOTS_FILE_EOF

# >>> file: shopbots/repo/customers.py
    cat >"$d/shopbots/repo/customers.py" <<'SHOPBOTS_FILE_EOF'
"""Concurrent-safe customer numbering and immutable opening/account events."""
from __future__ import annotations
import hashlib,re

def normalize_phone(value:str)->str:
    x=value.translate(str.maketrans('۰۱۲۳۴۵۶۷۸۹','0123456789')); x=re.sub(r'[^0-9+]','',x)
    if x.startswith('00'): x='+'+x[2:]
    if x.startswith('09'): x='+98'+x[1:]
    if not re.fullmatch(r'\+[1-9][0-9]{7,14}',x): raise ValueError('invalid phone')
    return x

def phone_fingerprint(phone:str)->str: return hashlib.sha256(phone.encode()).hexdigest()

async def create_customer(conn, *, shop_id:int, name:str, phone:str|None=None, cash_rate=0, credit_rate=0, note=None, credit_limit_irr=0, opening_amount_irr=0, opening_title='مانده اول دوره', opening_date=None, opening_description=None):
    async with conn.transaction():
        row=await conn.fetchrow("INSERT INTO customer_sequences(shop_id,next_code) VALUES($1,2) ON CONFLICT(shop_id) DO UPDATE SET next_code=customer_sequences.next_code+1 RETURNING next_code-1 AS code",shop_id)
        norm=normalize_phone(phone) if phone else None
        c=await conn.fetchrow("INSERT INTO customers_v4(shop_id,code,name,phone,phone_fingerprint,cash_rate,credit_rate,note,credit_limit_irr) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *",shop_id,row['code'],name.strip(),norm,phone_fingerprint(norm) if norm else None,cash_rate,credit_rate,note,credit_limit_irr)
        if opening_amount_irr:
            await conn.execute("INSERT INTO customer_opening_balances(shop_id,customer_id,amount_irr,title,balance_date,description) VALUES($1,$2,$3,$4,COALESCE($5::date,current_date),$6)",shop_id,c['id'],opening_amount_irr,opening_title,opening_date,opening_description)
            await conn.execute("INSERT INTO account_events(shop_id,customer_id,event_type,amount_irr,description,idempotency_key) VALUES($1,$2,'opening_balance',$3,$4,$5)",shop_id,c['id'],opening_amount_irr,opening_description,f'opening:{shop_id}:{c["id"]}')
        return c

async def archive_customer(conn, shop_id:int, customer_id:int):
    return await conn.fetchrow("UPDATE customers_v4 SET active=false,archived_at=now() WHERE shop_id=$1 AND id=$2 RETURNING id,code",shop_id,customer_id)

async def account_summary(conn, shop_id:int, customer_id:int):
    row=await conn.fetchrow("SELECT COALESCE(sum(amount_irr),0) AS balance,count(*) AS events FROM account_events WHERE shop_id=$1 AND customer_id=$2",shop_id,customer_id)
    return {'balance':int(row['balance']),'events':int(row['events']),'state':'debtor' if row['balance']>0 else 'creditor' if row['balance']<0 else 'settled'}
SHOPBOTS_FILE_EOF

# >>> file: shopbots/repo/subscriptions.py
    cat >"$d/shopbots/repo/subscriptions.py" <<'SHOPBOTS_FILE_EOF'
"""Idempotent subscription quotes, approvals and lifecycle history."""
from __future__ import annotations
from datetime import datetime, timezone, timedelta
from decimal import Decimal
import asyncpg

METHODS = {"package", "daily", "custom"}

def quote_price(duration_days: int, *, pricing_method: str, package_price_irr: int | None = None, daily_rate_irr: int | None = None, custom_price_irr: int | None = None) -> int:
    if duration_days <= 0 or pricing_method not in METHODS: raise ValueError("invalid subscription quote")
    if pricing_method == "package": price = package_price_irr
    elif pricing_method == "daily": price = duration_days * (daily_rate_irr or 0)
    else: price = custom_price_irr
    if price is None or price < 0: raise ValueError("missing subscription price")
    return int(price)

async def request_subscription(conn: asyncpg.Connection, *, shop_id: int, duration_days: int, quoted_price_irr: int, requested_by: int, request_key: str) -> asyncpg.Record:
    async with conn.transaction():
        await conn.execute("SELECT set_config('shopbots.shop_id',$1,true)", str(shop_id))
        return await conn.fetchrow("""INSERT INTO subscription_requests(shop_id,duration_days,quoted_price_irr,requested_by,request_key)
            VALUES($1,$2,$3,$4,$5) ON CONFLICT(shop_id,request_key) DO UPDATE SET request_key=EXCLUDED.request_key RETURNING *""", shop_id, duration_days, quoted_price_irr, requested_by, request_key)

async def approve_subscription(conn: asyncpg.Connection, *, request_id: str, actor_tg_id: int) -> asyncpg.Record:
    async with conn.transaction():
        req = await conn.fetchrow("SELECT * FROM subscription_requests WHERE id=$1 FOR UPDATE", request_id)
        if not req: raise ValueError("subscription request not found")
        shop_id = int(req["shop_id"]); await conn.execute("SELECT set_config('shopbots.shop_id',$1,true)", str(shop_id))
        if req["status"] == "approved": return await conn.fetchrow("SELECT * FROM shops WHERE id=$1", shop_id)
        if req["status"] != "pending": raise ValueError("subscription request is not pending")
        now = datetime.now(timezone.utc)
        current = await conn.fetchval("SELECT subscription_ends_at FROM shops WHERE id=$1 FOR UPDATE", shop_id)
        start = current if current and current > now else now
        end = start + timedelta(days=int(req["duration_days"]))
        await conn.execute("UPDATE subscription_requests SET status='approved', approved_by=$2, approved_at=now() WHERE id=$1", request_id, actor_tg_id)
        await conn.execute("""UPDATE shops SET subscription_status='active', subscription_suspended=false, subscription_ends_at=$2 WHERE id=$1""", shop_id, end)
        event = 'renewed' if current and current > now else 'started'
        await conn.execute("""INSERT INTO subscription_events(shop_id,request_id,event_type,starts_at,ends_at,price_irr,actor_tg_id)
            VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(shop_id,request_id,event_type) DO NOTHING""", shop_id, request_id, event, start, end, req["quoted_price_irr"], actor_tg_id)
        return await conn.fetchrow("SELECT * FROM shops WHERE id=$1", shop_id)

async def expire_due(conn: asyncpg.Connection) -> int:
    rows = await conn.fetch("""UPDATE shops SET subscription_status='past_due'
        WHERE subscription_status='active' AND subscription_suspended=false AND subscription_ends_at IS NOT NULL AND subscription_ends_at <= now()
        RETURNING id""")
    for row in rows:
        await conn.execute("INSERT INTO subscription_events(shop_id,event_type,ends_at) VALUES($1,'expired',now())", row["id"])
    return len(rows)

async def operation_allowed(conn: asyncpg.Connection, shop_id: int, *, customer_read: bool = False) -> bool:
    row = await conn.fetchrow("SELECT subscription_status,subscription_suspended,subscription_ends_at,subscription_access_policy FROM shops WHERE id=$1", shop_id)
    if not row: return False
    active = row["subscription_status"] == "active" and not row["subscription_suspended"] and (row["subscription_ends_at"] is None or row["subscription_ends_at"] > datetime.now(timezone.utc))
    return active or (customer_read and row["subscription_access_policy"] != "deny_customer")
SHOPBOTS_FILE_EOF

# >>> file: shopbots/repo/finance.py
    cat >"$d/shopbots/repo/finance.py" <<'SHOPBOTS_FILE_EOF'
"""Double-entry financial core. Amounts are integer IRR; posting is idempotent and atomic."""
from __future__ import annotations
from decimal import Decimal, ROUND_HALF_UP
from typing import Any
IRR_PER_TOMAN = 10

def to_irr(value: Decimal | int | str, unit: str) -> int:
    amount = Decimal(str(value))
    if unit == "IRT": amount *= IRR_PER_TOMAN
    elif unit != "IRR": raise ValueError("unit must be IRR or IRT")
    if amount != amount.quantize(Decimal("1"), rounding=ROUND_HALF_UP): raise ValueError("fractional rial is not allowed")
    return int(amount)

def display_amount(amount_irr: int, unit: str) -> Decimal:
    if unit == "IRR": return Decimal(amount_irr)
    if unit == "IRT": return (Decimal(amount_irr) / IRR_PER_TOMAN).quantize(Decimal("0.1"))
    raise ValueError("unit must be IRR or IRT")

async def post_transaction(conn: asyncpg.Connection, *, shop_id: int, idempotency_key: str, description: str, entries: list[dict[str, Any]]) -> str:
    if not entries or sum(int(e["amount_irr"]) for e in entries) != 0: raise ValueError("ledger must balance to zero")
    await conn.execute("SELECT set_config('shopbots.shop_id', $1, true)", str(shop_id))
    async with conn.transaction():
        await conn.execute("SELECT pg_advisory_xact_lock(hashtextextended($1 || ':' || $2, 0))", str(shop_id), idempotency_key)
        row = await conn.fetchrow("SELECT id FROM financial_transactions WHERE shop_id=$1 AND idempotency_key=$2 FOR UPDATE", shop_id, idempotency_key)
        if row: return str(row["id"])
        tx = await conn.fetchval("INSERT INTO financial_transactions(shop_id,idempotency_key,description) VALUES($1,$2,$3) RETURNING id", shop_id, idempotency_key, description)
        for e in entries:
            await conn.execute("INSERT INTO ledger_entries(shop_id,transaction_id,account,amount_irr,metadata) VALUES($1,$2,$3,$4,$5::jsonb)", shop_id, tx, e["account"], int(e["amount_irr"]), __import__('json').dumps(e.get("metadata", {}), ensure_ascii=False))
        await conn.execute("INSERT INTO financial_outbox(shop_id,event_type,aggregate_type,aggregate_id,payload) VALUES($1,'finance.transaction.posted','financial_transaction',$2,$3::jsonb)", shop_id, str(tx), __import__('json').dumps({"transaction_id":str(tx),"idempotency_key":idempotency_key}, ensure_ascii=False))
        return str(tx)

async def account_balance(conn: asyncpg.Connection, *, shop_id: int, account: str) -> int:
    await conn.execute("SELECT set_config('shopbots.shop_id', $1, true)", str(shop_id))
    return int(await conn.fetchval("SELECT COALESCE(sum(amount_irr),0) FROM ledger_entries WHERE shop_id=$1 AND account=$2", shop_id, account))
SHOPBOTS_FILE_EOF

# >>> file: shopbots/repo/__init__.py
    cat >"$d/shopbots/repo/__init__.py" <<'SHOPBOTS_FILE_EOF'
"""Data access layer. All SQL lives here; handlers never build SQL."""
SHOPBOTS_FILE_EOF

# >>> file: shopbots/repo/audit.py
    cat >"$d/shopbots/repo/audit.py" <<'SHOPBOTS_FILE_EOF'
from __future__ import annotations

import json
from typing import Any

import asyncpg


async def write_audit(
    conn: asyncpg.Connection | asyncpg.Pool,
    actor_tg_id: int | None,
    action: str,
    target: str | None,
    details: dict[str, Any] | None = None,
) -> None:
    await conn.execute(
        "INSERT INTO audit_log (actor_tg_id, action, target, details) VALUES ($1, $2, $3, $4::jsonb)",
        actor_tg_id,
        action,
        target,
        json.dumps(details or {}, ensure_ascii=False),
    )
SHOPBOTS_FILE_EOF

# >>> file: shopbots/repo/bots.py
    cat >"$d/shopbots/repo/bots.py" <<'SHOPBOTS_FILE_EOF'
"""Registry of seller bots. Tokens are stored only encrypted; plaintext never touches SQL logs."""

from __future__ import annotations

from dataclasses import dataclass, field

import asyncpg

from ..logging_setup import redact
from ..security import TokenVault, bot_id_from_token
from .audit import write_audit

STATUSES = ("active", "disabled", "invalid_token")
MAX_ERROR_LEN = 500


@dataclass(frozen=True)
class BotRecord:
    id: int
    telegram_bot_id: int
    username: str | None
    display_name: str | None
    status: str
    token_fingerprint: str = field(repr=False)
    token_encrypted: bytes = field(repr=False)
    last_error: str | None
    shop_title: str | None


_SELECT = """
SELECT b.id, b.telegram_bot_id, b.username, b.display_name, b.status,
       b.token_fingerprint, b.token_encrypted, b.last_error, s.title AS shop_title
FROM bots b
LEFT JOIN shops s ON s.bot_id = b.id
"""


def _record(row: asyncpg.Record) -> BotRecord:
    data = dict(row)
    data["token_encrypted"] = bytes(data["token_encrypted"])
    return BotRecord(**data)


def _clean_error(message: str | None) -> str | None:
    if message is None:
        return None
    return redact(message)[:MAX_ERROR_LEN]


async def list_active(pool: asyncpg.Pool) -> list[BotRecord]:
    rows = await pool.fetch(_SELECT + " WHERE b.status = 'active' ORDER BY b.id")
    return [_record(r) for r in rows]


async def list_all(pool: asyncpg.Pool) -> list[BotRecord]:
    rows = await pool.fetch(_SELECT + " ORDER BY b.id")
    return [_record(r) for r in rows]


async def get(pool: asyncpg.Pool, bot_id: int) -> BotRecord | None:
    row = await pool.fetchrow(_SELECT + " WHERE b.id = $1", bot_id)
    return _record(row) if row else None


async def count_by_status(pool: asyncpg.Pool) -> dict[str, int]:
    rows = await pool.fetch("SELECT status, count(*) AS n FROM bots GROUP BY status")
    counts = {s: 0 for s in STATUSES}
    counts.update({r["status"]: r["n"] for r in rows})
    return counts


async def register_bot(
    pool: asyncpg.Pool,
    vault: TokenVault,
    *,
    token: str,
    telegram_bot_id: int,
    username: str | None,
    display_name: str | None,
    actor_tg_id: int,
    shop_admin_tg_id: int | None = None,
) -> tuple[BotRecord, bool]:
    """Insert a new seller bot (+ its shop) or replace the token of an existing one.

    Returns (record, created). Re-registering the same Telegram bot never creates a
    second shop, so a revoked-and-reissued token keeps all shop data.
    """
    if bot_id_from_token(token) != telegram_bot_id:
        raise ValueError("token does not belong to the given Telegram bot id")
    encrypted = vault.encrypt(token)
    fingerprint = vault.fingerprint(token)
    async with pool.acquire() as conn:
        async with conn.transaction():
            existing = await conn.fetchrow("SELECT id FROM bots WHERE telegram_bot_id = $1 FOR UPDATE", telegram_bot_id)
            if existing:
                bot_db_id = existing["id"]
                await conn.execute(
                    """UPDATE bots SET token_encrypted = $2, token_fingerprint = $3, username = $4,
                       display_name = $5, status = 'active', last_error = NULL, last_error_at = NULL
                       WHERE id = $1""",
                    bot_db_id, encrypted, fingerprint, username, display_name,
                )
                created = False
            else:
                bot_db_id = await conn.fetchval(
                    """INSERT INTO bots (telegram_bot_id, username, display_name, token_encrypted,
                                         token_fingerprint, status, created_by)
                       VALUES ($1, $2, $3, $4, $5, 'active', $6) RETURNING id""",
                    telegram_bot_id, username, display_name, encrypted, fingerprint, actor_tg_id,
                )
                title = (display_name or username or f"shop-{bot_db_id}").strip()[:128] or f"shop-{bot_db_id}"
                await conn.execute("INSERT INTO shops (bot_id, title, owner_tg_id) VALUES ($1, $2, $3)", bot_db_id, title, shop_admin_tg_id or actor_tg_id)
                created = True
            await write_audit(
                conn,
                actor_tg_id,
                "bot.registered" if created else "bot.token_replaced",
                f"bot:{bot_db_id}",
                {"telegram_bot_id": telegram_bot_id, "username": username},
            )
            row = await conn.fetchrow(_SELECT + " WHERE b.id = $1", bot_db_id)
    return _record(row), created


async def set_status(pool: asyncpg.Pool, bot_id: int, status: str, actor_tg_id: int | None) -> BotRecord | None:
    if status not in STATUSES:
        raise ValueError(f"unknown status: {status}")
    async with pool.acquire() as conn:
        async with conn.transaction():
            updated = await conn.fetchval(
                """UPDATE bots SET status = $2::text,
                       last_error = CASE WHEN $2::text = 'active' THEN NULL ELSE last_error END
                   WHERE id = $1 RETURNING id""",
                bot_id, status,
            )
            if updated is None:
                return None
            await write_audit(conn, actor_tg_id, f"bot.status.{status}", f"bot:{bot_id}")
            row = await conn.fetchrow(_SELECT + " WHERE b.id = $1", bot_id)
    return _record(row)


async def mark_invalid_token(pool: asyncpg.Pool, bot_id: int, message: str | None) -> None:
    async with pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                """UPDATE bots SET status = 'invalid_token', last_error = $2, last_error_at = now()
                   WHERE id = $1 AND status = 'active'""",
                bot_id, _clean_error(message) or "token rejected by Telegram",
            )
            await write_audit(conn, None, "bot.status.invalid_token", f"bot:{bot_id}")


async def record_runtime_error(pool: asyncpg.Pool, bot_id: int, message: str) -> None:
    await pool.execute(
        "UPDATE bots SET last_error = $2, last_error_at = now() WHERE id = $1",
        bot_id, _clean_error(message),
    )


async def mark_started(pool: asyncpg.Pool, bot_id: int, username: str | None, display_name: str | None) -> None:
    await pool.execute(
        """UPDATE bots SET username = $2, display_name = $3, last_started_at = now(),
               last_error = NULL, last_error_at = NULL
           WHERE id = $1""",
        bot_id, username, display_name,
    )


async def get_shop_title(pool: asyncpg.Pool, bot_id: int) -> str | None:
    return await pool.fetchval("SELECT title FROM shops WHERE bot_id = $1", bot_id)
SHOPBOTS_FILE_EOF

# >>> file: shopbots/repo/system.py
    cat >"$d/shopbots/repo/system.py" <<'SHOPBOTS_FILE_EOF'
from __future__ import annotations

import json
from typing import Any

import asyncpg


async def write_heartbeat(pool: asyncpg.Pool, *, pid: int, version: str, running_bots: int, details: dict[str, Any]) -> None:
    await pool.execute(
        """INSERT INTO service_heartbeat (id, beat_at, pid, version, running_bots, details)
           VALUES (1, now(), $1, $2, $3, $4::jsonb)
           ON CONFLICT (id) DO UPDATE SET beat_at = EXCLUDED.beat_at, pid = EXCLUDED.pid,
               version = EXCLUDED.version, running_bots = EXCLUDED.running_bots, details = EXCLUDED.details""",
        pid, version, running_bots, json.dumps(details),
    )


async def read_heartbeat(conn: asyncpg.Connection) -> dict[str, Any] | None:
    if not await conn.fetchval("SELECT to_regclass('public.service_heartbeat') IS NOT NULL"):
        return None
    row = await conn.fetchrow(
        """SELECT extract(epoch FROM now() - beat_at)::float8 AS age,
                  extract(epoch FROM beat_at)::float8 AS beat_epoch,
                  pid, version, running_bots, details
           FROM service_heartbeat WHERE id = 1"""
    )
    if row is None:
        return None
    data = dict(row)
    data["details"] = json.loads(data["details"]) if isinstance(data["details"], str) else data["details"]
    return data
SHOPBOTS_FILE_EOF

# >>> file: shopbots/runner.py
    cat >"$d/shopbots/runner.py" <<'SHOPBOTS_FILE_EOF'
"""Long-polling runner for a single bot token.

A custom getUpdates loop is used instead of Dispatcher.start_polling because aiogram's
built-in loop retries forever on an invalid token; here a revoked token ends only this
runner and is reported, while every other bot keeps working."""

from __future__ import annotations

import asyncio
import enum
import logging
from dataclasses import dataclass
from typing import Awaitable, Callable

from aiogram import Bot, Dispatcher
from aiogram.exceptions import (
    TelegramAPIError,
    TelegramConflictError,
    TelegramNetworkError,
    TelegramRetryAfter,
    TelegramServerError,
    TelegramUnauthorizedError,
)
from aiogram.types import User

from .backoff import Backoff
from .locks import AdvisoryLockManager
from .logging_setup import redact
from .security import TokenFormatError, bot_id_from_token

POLL_TIMEOUT = 25
HANDLER_TIMEOUT = 60


class Outcome(enum.Enum):
    STOPPED = "stopped"
    INVALID_TOKEN = "invalid_token"
    LOCK_BUSY = "lock_busy"
    CRASHED = "crashed"


@dataclass(frozen=True)
class RunResult:
    outcome: Outcome
    error: str | None = None


class BotRunner:
    def __init__(
        self,
        *,
        name: str,
        token: str,
        locks: AdvisoryLockManager,
        build_dispatcher: Callable[[], Dispatcher],
        on_started: Callable[[User], Awaitable[None]],
        on_runtime_error: Callable[[str], Awaitable[None]],
    ) -> None:
        self._name = name
        self._token = token
        self._locks = locks
        self._build_dispatcher = build_dispatcher
        self._on_started = on_started
        self._on_runtime_error = on_runtime_error
        self._log = logging.getLogger(f"shopbots.runner.{name}")
        self._last_reported: str | None = None

    async def run(self) -> RunResult:
        try:
            lock_key = bot_id_from_token(self._token)
        except TokenFormatError:
            return RunResult(Outcome.INVALID_TOKEN, "malformed token")
        try:
            acquired = await self._locks.try_acquire(lock_key)
        except Exception as exc:  # noqa: BLE001
            return RunResult(Outcome.CRASHED, redact(f"lock error: {type(exc).__name__}: {exc}"))
        if not acquired:
            return RunResult(Outcome.LOCK_BUSY, "another process already polls this bot")
        bot: Bot | None = None
        try:
            bot = Bot(token=self._token)
            me = await bot.get_me()
            await self._on_started(me)
            await bot.delete_webhook(drop_pending_updates=False)
            dispatcher = self._build_dispatcher()
            self._log.info("polling started for @%s", me.username)
            await self._poll(bot, dispatcher)
            return RunResult(Outcome.STOPPED)
        except TelegramUnauthorizedError as exc:
            self._log.error("token rejected by Telegram: %s", exc)
            return RunResult(Outcome.INVALID_TOKEN, redact(str(exc)))
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - isolate failures to this bot
            self._log.exception("runner crashed")
            return RunResult(Outcome.CRASHED, redact(f"{type(exc).__name__}: {exc}"))
        finally:
            if bot is not None:
                try:
                    await bot.session.close()
                except Exception:  # noqa: BLE001
                    self._log.warning("failed to close HTTP session", exc_info=True)
            try:
                await self._locks.release(lock_key)
            except Exception:  # noqa: BLE001
                self._log.warning("failed to release polling lock (connection lost?)", exc_info=True)

    async def _report(self, message: str) -> None:
        message = redact(message)
        if message == self._last_reported:
            return
        self._last_reported = message
        try:
            await self._on_runtime_error(message)
        except Exception:  # noqa: BLE001
            self._log.warning("could not record runtime error", exc_info=True)

    async def _poll(self, bot: Bot, dispatcher: Dispatcher) -> None:
        offset: int | None = None
        backoff = Backoff(base=1.0, cap=60.0)
        allowed = dispatcher.resolve_used_update_types()
        while True:
            try:
                updates = await bot.get_updates(
                    offset=offset,
                    timeout=POLL_TIMEOUT,
                    allowed_updates=allowed,
                    request_timeout=POLL_TIMEOUT + 15,
                )
            except TelegramUnauthorizedError:
                raise
            except TelegramConflictError as exc:
                self._log.warning("getUpdates conflict (token used elsewhere?): %s", exc)
                await self._report(f"conflict: {exc}")
                await asyncio.sleep(backoff.next())
                continue
            except TelegramRetryAfter as exc:
                await asyncio.sleep(exc.retry_after)
                continue
            except (TelegramNetworkError, TelegramServerError, asyncio.TimeoutError) as exc:
                self._log.warning("temporary polling error: %s: %s", type(exc).__name__, exc)
                await asyncio.sleep(backoff.next())
                continue
            except TelegramAPIError as exc:
                self._log.error("polling API error: %s: %s", type(exc).__name__, exc)
                await self._report(f"{type(exc).__name__}: {exc}")
                await asyncio.sleep(backoff.next())
                continue
            backoff.reset()
            self._last_reported = None
            for update in updates:
                offset = update.update_id + 1
                try:
                    await asyncio.wait_for(dispatcher.feed_update(bot, update), timeout=HANDLER_TIMEOUT)
                except asyncio.TimeoutError:
                    self._log.error("update %s handler timed out", update.update_id)
                except asyncio.CancelledError:
                    raise
                except Exception:  # noqa: BLE001 - a bad update must not stop polling
                    self._log.exception("unhandled error while processing update %s", update.update_id)
SHOPBOTS_FILE_EOF

# >>> file: shopbots/security.py
    cat >"$d/shopbots/security.py" <<'SHOPBOTS_FILE_EOF'
"""Bot token validation, encryption at rest and non-reversible fingerprints."""

from __future__ import annotations

import base64
import hashlib
import hmac
import re

TOKEN_RE = re.compile(r"^(\d{5,20}):[A-Za-z0-9_-]{30,64}$")


class TokenFormatError(ValueError):
    """Raised when a string does not look like a Telegram bot token."""


class TokenDecryptError(Exception):
    """Raised when a stored token cannot be decrypted (wrong key or corrupted data)."""


def validate_token_format(token: str) -> bool:
    return bool(TOKEN_RE.fullmatch(token or ""))


def bot_id_from_token(token: str) -> int:
    """Telegram bot id is the numeric prefix of the token; it never changes when the token is revoked."""
    match = TOKEN_RE.fullmatch(token or "")
    if not match:
        raise TokenFormatError("invalid bot token format")
    return int(match.group(1))


def decode_key(value: str, name: str, *, min_len: int = 32) -> bytes:
    try:
        raw = base64.urlsafe_b64decode(value.encode("ascii") + b"=" * (-len(value) % 4))
    except (ValueError, UnicodeEncodeError) as exc:
        raise ValueError(f"{name} is not valid url-safe base64") from exc
    if len(raw) < min_len:
        raise ValueError(f"{name} must decode to at least {min_len} bytes")
    return raw


class TokenVault:
    """Encrypts bot tokens with Fernet (AES-128-CBC + HMAC-SHA256) and fingerprints them with HMAC-SHA256."""

    def __init__(self, fernet_key: str, hmac_key: str) -> None:
        from cryptography.fernet import Fernet

        raw = decode_key(fernet_key, "SHOPBOTS_FERNET_KEY")
        if len(raw) != 32:
            raise ValueError("SHOPBOTS_FERNET_KEY must decode to exactly 32 bytes")
        self._fernet = Fernet(base64.urlsafe_b64encode(raw))
        self._hmac_key = decode_key(hmac_key, "SHOPBOTS_TOKEN_HMAC_KEY")

    def encrypt(self, token: str) -> bytes:
        if not validate_token_format(token):
            raise TokenFormatError("refusing to encrypt a malformed token")
        return self._fernet.encrypt(token.encode("ascii"))

    def decrypt(self, blob: bytes) -> str:
        from cryptography.fernet import InvalidToken

        try:
            token = self._fernet.decrypt(bytes(blob)).decode("ascii")
        except InvalidToken as exc:
            raise TokenDecryptError("cannot decrypt bot token (wrong SHOPBOTS_FERNET_KEY or corrupted data)") from exc
        if not validate_token_format(token):
            raise TokenDecryptError("decrypted value is not a valid bot token")
        return token

    def fingerprint(self, token: str) -> str:
        return hmac.new(self._hmac_key, token.encode("ascii"), hashlib.sha256).hexdigest()

    def __repr__(self) -> str:
        return "TokenVault(<redacted>)"
SHOPBOTS_FILE_EOF

# >>> file: shopbots/supervisor.py
    cat >"$d/shopbots/supervisor.py" <<'SHOPBOTS_FILE_EOF'
"""Dynamic management of all bot runners in one asyncio process.

Desired state = central bot (from config) + every seller bot with status 'active'.
The supervisor reconciles on PostgreSQL NOTIFY (instant) and every
SHOPBOTS_RECONCILE_INTERVAL seconds (safety net), restarts crashed runners with
backoff, marks revoked tokens as invalid_token and writes a heartbeat for health checks."""

from __future__ import annotations

import asyncio
import logging
import os
import time
from dataclasses import dataclass
from functools import partial
from typing import Any

import asyncpg
from aiogram import Dispatcher
from aiogram.types import User

from . import __version__, db
from .backoff import restart_delay
from .config import Settings
from .handlers.central import build_central_router
from .handlers.seller import build_seller_router
from .locks import AdvisoryLockManager
from .logging_setup import redact
from .repo import bots as bots_repo
from .repo import system as system_repo
from .runner import BotRunner, Outcome, RunResult
from .security import TokenDecryptError, TokenVault, bot_id_from_token

log = logging.getLogger("shopbots.supervisor")

NOTIFY_CHANNEL = "shopbots_bots_changed"
CENTRAL_KEY = "central"
LOCK_BUSY_RETRY = 30.0
CENTRAL_INVALID_RETRY = 300.0
DECRYPT_FAIL_RETRY = 600.0


@dataclass
class _Desired:
    kind: str
    fingerprint: str
    bot_db_id: int | None
    token_encrypted: bytes | None


@dataclass
class _Slot:
    key: str
    kind: str
    bot_db_id: int | None
    fingerprint: str
    task: asyncio.Task | None = None
    failures: int = 0
    retry_at: float = 0.0
    started_at: float | None = None
    username: str | None = None
    last_error: str | None = None

    @property
    def running(self) -> bool:
        return self.task is not None and not self.task.done() and self.started_at is not None


class Supervisor:
    def __init__(self, *, settings: Settings, pool: asyncpg.Pool, vault: TokenVault, locks: AdvisoryLockManager) -> None:
        self._settings = settings
        self._pool = pool
        self._vault = vault
        self._locks = locks
        self._slots: dict[str, _Slot] = {}
        self._wake = asyncio.Event()
        self._stopping = False
        self._listener: asyncpg.Connection | None = None
        self._central_tg_id = bot_id_from_token(settings.central_bot_token)
        self._central_fp = vault.fingerprint(settings.central_bot_token)
        self.started_monotonic = time.monotonic()

    # ---- public API -------------------------------------------------------
    def wake(self) -> None:
        self._wake.set()

    def request_stop(self) -> None:
        self._stopping = True
        self._wake.set()

    def snapshot(self) -> list[dict[str, Any]]:
        return [
            {
                "key": s.key,
                "kind": s.kind,
                "bot_db_id": s.bot_db_id,
                "username": s.username,
                "running": s.running,
                "failures": s.failures,
                "last_error": s.last_error,
            }
            for s in self._slots.values()
        ]

    async def run(self) -> None:
        log.info("supervisor started (version %s)", __version__)
        try:
            while not self._stopping:
                try:
                    await self._ensure_listener()
                    await self._ensure_locks()
                    await self._reconcile()
                    await self._heartbeat()
                except Exception:  # noqa: BLE001 - keep supervising through DB hiccups
                    log.exception("supervisor iteration failed; retrying")
                try:
                    await asyncio.wait_for(self._wake.wait(), timeout=self._settings.reconcile_interval)
                except asyncio.TimeoutError:
                    pass
                self._wake.clear()
        finally:
            await self._stop_all()
            await self._close_listener()
            log.info("supervisor stopped")

    # ---- infrastructure ---------------------------------------------------
    def _on_notify(self, *_args: Any) -> None:
        self._wake.set()

    async def _ensure_listener(self) -> None:
        if self._listener is not None and not self._listener.is_closed():
            return
        self._listener = await db.connect(self._settings)
        await self._listener.add_listener(NOTIFY_CHANNEL, self._on_notify)

    async def _close_listener(self) -> None:
        if self._listener is not None and not self._listener.is_closed():
            try:
                await asyncio.wait_for(self._listener.close(), timeout=5)
            except Exception:  # noqa: BLE001
                self._listener.terminate()
        self._listener = None

    async def _ensure_locks(self) -> None:
        if await self._locks.ping():
            return
        if self._slots:
            log.error("polling-lock connection lost: stopping all bots before re-acquiring locks")
        await self._stop_all()
        await self._locks.reconnect()

    async def _heartbeat(self) -> None:
        central = self._slots.get(CENTRAL_KEY)
        await system_repo.write_heartbeat(
            self._pool,
            pid=os.getpid(),
            version=__version__,
            running_bots=sum(1 for s in self._slots.values() if s.running),
            details={
                "central_running": bool(central and central.running),
                "central_error": central.last_error if central else None,
                "slots": len(self._slots),
            },
        )

    # ---- reconciliation ---------------------------------------------------
    async def _desired_state(self) -> dict[str, _Desired]:
        desired = {CENTRAL_KEY: _Desired("central", self._central_fp, None, None)}
        for rec in await bots_repo.list_active(self._pool):
            if rec.telegram_bot_id == self._central_tg_id:
                log.warning("bot #%s uses the central bot token; ignored", rec.id)
                continue
            desired[f"bot:{rec.id}"] = _Desired("seller", rec.token_fingerprint, rec.id, rec.token_encrypted)
        return desired

    async def _reconcile(self) -> None:
        for slot in list(self._slots.values()):
            if slot.task is not None and slot.task.done():
                await self._handle_finished(slot)
        desired = await self._desired_state()
        for key, slot in list(self._slots.items()):
            want = desired.get(key)
            if want is None or want.fingerprint != slot.fingerprint:
                log.info("stopping %s (%s)", key, "removed/disabled" if want is None else "token changed")
                await self._stop_slot(slot)
                del self._slots[key]
        now = time.monotonic()
        for key, want in desired.items():
            slot = self._slots.get(key)
            if slot is None:
                slot = _Slot(key=key, kind=want.kind, bot_db_id=want.bot_db_id, fingerprint=want.fingerprint)
                self._slots[key] = slot
            if slot.task is not None or now < slot.retry_at:
                continue
            token = self._resolve_token(slot, want)
            if token is None:
                slot.retry_at = now + DECRYPT_FAIL_RETRY
                if slot.bot_db_id is not None:
                    await self._safe_record_error(slot, slot.last_error or "token decrypt failed")
                continue
            self._start_slot(slot, token)

    def _resolve_token(self, slot: _Slot, want: _Desired) -> str | None:
        if want.kind == "central":
            return self._settings.central_bot_token
        try:
            assert want.token_encrypted is not None
            return self._vault.decrypt(want.token_encrypted)
        except TokenDecryptError as exc:
            slot.last_error = str(exc)
            log.error("bot #%s: %s", slot.bot_db_id, exc)
            return None

    def _start_slot(self, slot: _Slot, token: str) -> None:
        slot.started_at = None
        runner = BotRunner(
            name=slot.key.replace(":", "-"),
            token=token,
            locks=self._locks,
            build_dispatcher=partial(self._build_dispatcher, slot),
            on_started=partial(self._on_started, slot),
            on_runtime_error=partial(self._on_runtime_error, slot),
        )
        slot.task = asyncio.create_task(runner.run(), name=f"bot-runner:{slot.key}")
        slot.task.add_done_callback(lambda _t: self._wake.set())

    def _build_dispatcher(self, slot: _Slot) -> Dispatcher:
        if slot.kind == "central":
            dispatcher = Dispatcher(pool=self._pool, vault=self._vault, settings=self._settings, supervisor=self)
            dispatcher.include_router(build_central_router(self._settings.owner_id))
        else:
            # Seller dispatchers get no vault/settings: least privilege per tenant.
            dispatcher = Dispatcher(pool=self._pool, shop_bot_id=slot.bot_db_id)
            dispatcher.include_router(build_seller_router())
        return dispatcher

    async def _on_started(self, slot: _Slot, me: User) -> None:
        slot.started_at = time.monotonic()
        slot.username = me.username
        slot.last_error = None
        if slot.bot_db_id is not None:
            try:
                await bots_repo.mark_started(self._pool, slot.bot_db_id, me.username, me.full_name)
            except Exception:  # noqa: BLE001
                log.warning("could not persist start of %s", slot.key, exc_info=True)

    async def _on_runtime_error(self, slot: _Slot, message: str) -> None:
        slot.last_error = message
        await self._safe_record_error(slot, message)

    async def _safe_record_error(self, slot: _Slot, message: str) -> None:
        if slot.bot_db_id is None:
            return
        try:
            await bots_repo.record_runtime_error(self._pool, slot.bot_db_id, message)
        except Exception:  # noqa: BLE001
            log.warning("could not persist error of %s", slot.key, exc_info=True)

    async def _handle_finished(self, slot: _Slot) -> None:
        task, slot.task = slot.task, None
        assert task is not None
        if task.cancelled():
            result = RunResult(Outcome.STOPPED)
        elif task.exception() is not None:
            result = RunResult(Outcome.CRASHED, redact(repr(task.exception())))
        else:
            result = task.result()
        now = time.monotonic()
        was_running = slot.started_at is not None
        slot.started_at = None
        slot.last_error = result.error
        if result.outcome is Outcome.INVALID_TOKEN:
            if slot.kind == "seller" and slot.bot_db_id is not None:
                log.error("bot #%s: token revoked/invalid; marked invalid_token", slot.bot_db_id)
                try:
                    await bots_repo.mark_invalid_token(self._pool, slot.bot_db_id, result.error)
                except Exception:  # noqa: BLE001
                    log.warning("could not mark bot #%s invalid", slot.bot_db_id, exc_info=True)
                slot.retry_at = now + CENTRAL_INVALID_RETRY
            else:
                log.critical("central bot token rejected by Telegram; fix SHOPBOTS_CENTRAL_BOT_TOKEN and restart")
                slot.retry_at = now + CENTRAL_INVALID_RETRY
            return
        if result.outcome is Outcome.LOCK_BUSY:
            log.warning("%s: polling lock busy (another instance running?)", slot.key)
            slot.retry_at = now + LOCK_BUSY_RETRY
            await self._safe_record_error(slot, result.error or "polling lock busy")
            return
        slot.failures = 1 if was_running else slot.failures + 1
        delay = restart_delay(slot.failures)
        log.warning("%s stopped (%s); restart in %.0fs", slot.key, result.error or result.outcome.value, delay)
        slot.retry_at = now + delay
        await self._safe_record_error(slot, result.error or result.outcome.value)

    async def _stop_slot(self, slot: _Slot) -> None:
        task = slot.task
        slot.task = None
        if task is None:
            return
        if not task.done():
            task.cancel()
        done, _ = await asyncio.wait({task}, timeout=15)
        if task in done and not task.cancelled():
            task.exception()  # mark retrieved

    async def _stop_all(self) -> None:
        tasks = [s.task for s in self._slots.values() if s.task is not None]
        for task in tasks:
            if not task.done():
                task.cancel()
        if tasks:
            await asyncio.wait(tasks, timeout=20)
        for task in tasks:
            if task.done() and not task.cancelled():
                task.exception()
        for slot in self._slots.values():
            slot.task = None
            slot.started_at = None
SHOPBOTS_FILE_EOF

# >>> file: tests/test_finance.py
    cat >"$d/tests/test_finance.py" <<'SHOPBOTS_FILE_EOF'
import unittest
from decimal import Decimal
from shopbots.repo.finance import display_amount, to_irr

class FinanceTests(unittest.TestCase):
    def test_fixed_rial_conversion(self):
        self.assertEqual(to_irr("12.5", "IRT"), 125)
        self.assertEqual(display_amount(125, "IRT"), Decimal("12.5"))
        self.assertEqual(to_irr(125, "IRR"), 125)
    def test_fractional_rial_rejected(self):
        with self.assertRaises(ValueError): to_irr("1.1", "IRR")

if __name__ == "__main__": unittest.main()
SHOPBOTS_FILE_EOF

# >>> file: tests/test_subscriptions.py
    cat >"$d/tests/test_subscriptions.py" <<'SHOPBOTS_FILE_EOF'
import unittest
from shopbots.repo.subscriptions import quote_price
class SubscriptionQuoteTests(unittest.TestCase):
    def test_package_daily_custom(self):
        self.assertEqual(quote_price(30,pricing_method="package",package_price_irr=1000),1000)
        self.assertEqual(quote_price(30,pricing_method="daily",daily_rate_irr=20),600)
        self.assertEqual(quote_price(30,pricing_method="custom",custom_price_irr=777),777)
    def test_invalid_quote(self):
        with self.assertRaises(ValueError): quote_price(0,pricing_method="daily",daily_rate_irr=1)
if __name__ == "__main__": unittest.main()
SHOPBOTS_FILE_EOF

# >>> file: tests/test_catalog_customers.py
    cat >"$d/tests/test_catalog_customers.py" <<'SHOPBOTS_FILE_EOF'
import unittest
from decimal import Decimal
from shopbots.repo.catalog import normalize_quantity, credit_price
from shopbots.repo.customers import normalize_phone
class CatalogCustomerTests(unittest.TestCase):
 def test_quantities_and_credit_price(self):
  self.assertEqual(normalize_quantity('۰٫۲۵','weight',2),Decimal('0.25')); self.assertEqual(credit_price(1000,'12.5'),1125)
  with self.assertRaises(ValueError): normalize_quantity('1.2','unit')
  with self.assertRaises(ValueError): normalize_quantity('0.257','weight',2)
 def test_phone(self): self.assertEqual(normalize_phone('۰۹۱۲-۱۲۳-۴۵۶۷'),'+989121234567')
if __name__=='__main__': unittest.main()
SHOPBOTS_FILE_EOF

# >>> file: tests/test_sales.py
    cat >"$d/tests/test_sales.py" <<'SHOPBOTS_FILE_EOF'
import unittest
from shopbots.repo.sales import line_total,account_totals,validate_debt
class SalesTests(unittest.TestCase):
 def test_cash_credit_and_credit(self):
  self.assertEqual(line_total('0.25',1000),250); self.assertEqual(account_totals(-300,1000),(300,700)); self.assertEqual(account_totals(200,1000),(0,1200))
 def test_limits(self):
  with self.assertRaises(PermissionError): validate_debt(110,100,'block')
  with self.assertRaises(PermissionError): validate_debt(110,100,'warn')
  self.assertTrue(validate_debt(110,100,'warn',True))
if __name__=='__main__': unittest.main()
SHOPBOTS_FILE_EOF

# >>> file: tests/__init__.py
    cat >"$d/tests/__init__.py" <<'SHOPBOTS_FILE_EOF'
"""Unit tests (stdlib unittest; run: python -m unittest discover -s tests -t .)."""
SHOPBOTS_FILE_EOF

# >>> file: tests/helpers.py
    cat >"$d/tests/helpers.py" <<'SHOPBOTS_FILE_EOF'
import base64

TOKEN = "123456789:" + "A" * 35
OTHER_TOKEN = "987654321:" + "b" * 35
FERNET_KEY = base64.urlsafe_b64encode(b"\x01" * 32).decode()
HMAC_KEY = base64.urlsafe_b64encode(b"\x02" * 48).decode().rstrip("=")


def valid_mapping(**overrides):
    values = {
        "SHOPBOTS_CENTRAL_BOT_TOKEN": TOKEN,
        "SHOPBOTS_OWNER_ID": "42",
        "SHOPBOTS_DB_PASSWORD": "s3cret-password",
        "SHOPBOTS_FERNET_KEY": FERNET_KEY,
        "SHOPBOTS_TOKEN_HMAC_KEY": HMAC_KEY,
    }
    values.update(overrides)
    return values
SHOPBOTS_FILE_EOF

# >>> file: tests/test_backoff.py
    cat >"$d/tests/test_backoff.py" <<'SHOPBOTS_FILE_EOF'
import unittest

from shopbots.backoff import Backoff, restart_delay


class BackoffTests(unittest.TestCase):
    def test_growth_and_cap(self):
        b = Backoff(base=1, cap=8)
        delays = [b.next() for _ in range(10)]
        self.assertTrue(all(0.5 <= d <= 8 for d in delays))
        self.assertLessEqual(delays[0], 1)
        b.reset()
        self.assertLessEqual(b.next(), 1)

    def test_restart_delay(self):
        self.assertEqual(restart_delay(1), 5)
        self.assertEqual(restart_delay(2), 10)
        self.assertEqual(restart_delay(100), 300)


if __name__ == "__main__":
    unittest.main()
SHOPBOTS_FILE_EOF

# >>> file: tests/test_config.py
    cat >"$d/tests/test_config.py" <<'SHOPBOTS_FILE_EOF'
import unittest

from shopbots.config import ConfigError, parse_env_file, settings_from_mapping
from tests.helpers import TOKEN, valid_mapping


class ParseEnvTests(unittest.TestCase):
    def test_comments_blank_and_quotes(self):
        parsed = parse_env_file("# c\n\nA=1\nB=\"two words\"\nC='x'\nD=a=b\n")
        self.assertEqual(parsed, {"A": "1", "B": "two words", "C": "x", "D": "a=b"})

    def test_invalid_line(self):
        with self.assertRaises(ConfigError):
            parse_env_file("NOT A PAIR\n")

    def test_invalid_key(self):
        with self.assertRaises(ConfigError):
            parse_env_file("lower=1\n")


class SettingsTests(unittest.TestCase):
    def test_valid(self):
        s = settings_from_mapping(valid_mapping())
        self.assertEqual(s.owner_id, 42)
        self.assertEqual(s.db_port, 5432)
        self.assertEqual(s.log_level, "INFO")

    def test_missing_key_named_without_value(self):
        with self.assertRaises(ConfigError) as ctx:
            settings_from_mapping(valid_mapping(SHOPBOTS_DB_PASSWORD=""))
        self.assertIn("SHOPBOTS_DB_PASSWORD", str(ctx.exception))

    def test_bad_token(self):
        with self.assertRaises(ConfigError):
            settings_from_mapping(valid_mapping(SHOPBOTS_CENTRAL_BOT_TOKEN="nope"))

    def test_bad_owner(self):
        for bad in ("abc", "0", "-5"):
            with self.assertRaises(ConfigError):
                settings_from_mapping(valid_mapping(SHOPBOTS_OWNER_ID=bad))

    def test_bad_key(self):
        with self.assertRaises(ConfigError):
            settings_from_mapping(valid_mapping(SHOPBOTS_FERNET_KEY="short"))

    def test_repr_hides_secrets(self):
        text = repr(settings_from_mapping(valid_mapping()))
        self.assertNotIn(TOKEN, text)
        self.assertNotIn("s3cret-password", text)


if __name__ == "__main__":
    unittest.main()
SHOPBOTS_FILE_EOF

# >>> file: tests/test_logging.py
    cat >"$d/tests/test_logging.py" <<'SHOPBOTS_FILE_EOF'
import io
import logging
import unittest

from shopbots.logging_setup import REDACTED, RedactingFormatter, redact
from tests.helpers import TOKEN


class RedactionTests(unittest.TestCase):
    def test_redact_in_url(self):
        text = redact(f"GET https://api.telegram.org/bot{TOKEN}/getMe failed")
        self.assertNotIn(TOKEN, text)
        self.assertIn(REDACTED, text)

    def test_formatter_redacts_message_args_and_traceback(self):
        stream = io.StringIO()
        handler = logging.StreamHandler(stream)
        handler.setFormatter(RedactingFormatter("%(message)s"))
        logger = logging.getLogger("test.redaction")
        logger.propagate = False
        logger.addHandler(handler)
        try:
            raise RuntimeError(f"boom {TOKEN}")
        except RuntimeError:
            logger.exception("token=%s", TOKEN)
        logger.removeHandler(handler)
        self.assertNotIn(TOKEN, stream.getvalue())
        self.assertIn("RuntimeError", stream.getvalue())


if __name__ == "__main__":
    unittest.main()
SHOPBOTS_FILE_EOF

# >>> file: tests/test_migrations.py
    cat >"$d/tests/test_migrations.py" <<'SHOPBOTS_FILE_EOF'
import tempfile
import unittest
from pathlib import Path

from shopbots.migrate import MIGRATION_LOCK_KEY, MigrationError, discover


class DiscoverTests(unittest.TestCase):
    def test_packaged_migrations(self):
        migrations = discover()
        versions = [m.version for m in migrations]
        self.assertGreaterEqual(len(versions), 1)
        self.assertEqual(versions[0], "0001")
        self.assertEqual(versions, sorted(set(versions)))
        for m in migrations:
            self.assertEqual(len(m.checksum), 64)
            self.assertNotRegex(m.sql.upper(), r"\bDROP\s+TABLE\b")

    def test_lock_key_negative(self):
        self.assertLess(MIGRATION_LOCK_KEY, 0)

    def test_rejects_bad_names_and_duplicates(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "1_bad.sql").write_text("SELECT 1;")
            with self.assertRaises(MigrationError):
                discover(Path(tmp))
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "0001_a.sql").write_text("SELECT 1;")
            Path(tmp, "0001_b.sql").write_text("SELECT 2;")
            with self.assertRaises(MigrationError):
                discover(Path(tmp))


if __name__ == "__main__":
    unittest.main()
SHOPBOTS_FILE_EOF

# >>> file: tests/test_security.py
    cat >"$d/tests/test_security.py" <<'SHOPBOTS_FILE_EOF'
import importlib.util
import unittest

from shopbots.security import TokenDecryptError, TokenFormatError, TokenVault, bot_id_from_token, validate_token_format
from tests.helpers import FERNET_KEY, HMAC_KEY, OTHER_TOKEN, TOKEN

HAS_CRYPTO = importlib.util.find_spec("cryptography") is not None


class TokenFormatTests(unittest.TestCase):
    def test_valid(self):
        self.assertTrue(validate_token_format(TOKEN))
        self.assertEqual(bot_id_from_token(TOKEN), 123456789)

    def test_invalid(self):
        for bad in ("", "123:abc", "abc:" + "A" * 35, TOKEN + " ", "12345678:" + "A" * 35 + "!"):
            self.assertFalse(validate_token_format(bad), bad)
        with self.assertRaises(TokenFormatError):
            bot_id_from_token("bad")


@unittest.skipUnless(HAS_CRYPTO, "cryptography not installed")
class VaultTests(unittest.TestCase):
    def setUp(self):
        self.vault = TokenVault(FERNET_KEY, HMAC_KEY)

    def test_roundtrip_and_ciphertext_hides_token(self):
        blob = self.vault.encrypt(TOKEN)
        self.assertNotIn(TOKEN.encode(), blob)
        self.assertEqual(self.vault.decrypt(blob), TOKEN)

    def test_wrong_key(self):
        other = TokenVault("A" * 43 + "=", HMAC_KEY)
        with self.assertRaises(TokenDecryptError):
            other.decrypt(self.vault.encrypt(TOKEN))

    def test_fingerprint(self):
        self.assertEqual(self.vault.fingerprint(TOKEN), self.vault.fingerprint(TOKEN))
        self.assertNotEqual(self.vault.fingerprint(TOKEN), self.vault.fingerprint(OTHER_TOKEN))
        self.assertNotIn("123456789", self.vault.fingerprint(TOKEN))

    def test_refuses_malformed(self):
        with self.assertRaises(TokenFormatError):
            self.vault.encrypt("bad")

    def test_repr(self):
        self.assertNotIn(FERNET_KEY, repr(self.vault))


if __name__ == "__main__":
    unittest.main()
SHOPBOTS_FILE_EOF
}

main() {
    local cmd="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "$cmd" in
        install|update|status|logs|backup) ;;
        help|-h|--help) usage; exit 0 ;;
        *) usage; exit 64 ;;
    esac
    require_root
    check_os
    check_systemd
    cd /
    case "$cmd" in
        install) acquire_lock; cmd_install ;;
        update) acquire_lock; cmd_update ;;
        status) cmd_status ;;
        logs) cmd_logs "$@" ;;
        backup) acquire_lock; cmd_backup ;;
    esac
}

main "$@"
