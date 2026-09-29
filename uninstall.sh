#!/usr/bin/env bash
# =====================================================================
#  psiphon-multi-region :: uninstall.sh
#  حذف کامل: سرویس‌ها، کاربر، پوشه‌ها، اینترفیس/IP لوکال، psictl، logrotate
#  License: MIT
# =====================================================================
set -Eeuo pipefail

readonly INSTALL_DIR="/opt/psiphon-multi-region"
readonly SVC_USER="psiphon"
readonly DUMMY_IF="psi0"
readonly LOG_FILE="/var/log/psiphon-installer.log"
readonly SYSTEMD_DIR="/etc/systemd/system"

ASSUME_YES=0
PURGE_LOGS=0

C_RED=""; C_GRN=""; C_YLW=""; C_RST=""
if [[ -t 1 ]]; then C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_RST=$'\e[0m'; fi
ok()   { printf '%s[✔]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[✘]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
trap 'printf "%s[✘] uninstall error line %s: %s%s\n" "$C_RED" "$LINENO" "$BASH_COMMAND" "$C_RST" >&2' ERR

while [[ $# -gt 0 ]]; do
  case $1 in
    -y|--yes)     ASSUME_YES=1; shift ;;
    --purge-logs) PURGE_LOGS=1; shift ;;
    -h|--help)    echo "Usage: uninstall.sh [--yes] [--purge-logs]"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "با sudo اجرا کنید / run as root"

if (( ASSUME_YES == 0 )); then
  [[ -t 0 ]] || die "حالت غیرتعاملی: --yes لازم است / use --yes"
  read -r -p "همه‌چیز psiphon-multi-region حذف شود؟ / Remove everything? [y/N]: " ans
  [[ ${ans:-} =~ ^[Yy]$ ]] || die "لغو شد / aborted"
fi

# ۱) توقف و غیرفعال‌سازی اینستنس‌ها
mapfile -t units < <(
  {
    systemctl list-units --all --plain --no-legend 'psiphon@*.service' 2>/dev/null | awk '{print $1}'
    for f in "$SYSTEMD_DIR"/multi-user.target.wants/psiphon@*.service; do
      if [[ -e $f || -L $f ]]; then basename "$f"; fi
    done
  } | sort -u
)
for u in "${units[@]}"; do
  [[ -n $u ]] || continue
  systemctl disable --now "$u" >/dev/null 2>&1 || true
  ok "stopped $u"
done

# ۲) سرویس‌های جانبی
for u in psiphon-healthcheck.timer psiphon-healthcheck.service psiphon-xray.service psiphon-net.service; do
  systemctl disable --now "$u" >/dev/null 2>&1 || true
done
ok "سرویس‌های جانبی متوقف شد / auxiliary units stopped"

# ۳) حذف unit فایل‌ها
rm -f "$SYSTEMD_DIR/psiphon@.service" \
      "$SYSTEMD_DIR/psiphon-xray.service" \
      "$SYSTEMD_DIR/psiphon-net.service" \
      "$SYSTEMD_DIR/psiphon-healthcheck.service" \
      "$SYSTEMD_DIR/psiphon-healthcheck.timer"
rm -f "$SYSTEMD_DIR"/multi-user.target.wants/psiphon@*.service
systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true
ok "unit فایل‌ها حذف شد / unit files removed"

# ۴) اینترفیس dummy و IP لوکال
if ip link show "$DUMMY_IF" >/dev/null 2>&1; then
  ip link del "$DUMMY_IF" || warn "حذف $DUMMY_IF ناموفق / failed to delete $DUMMY_IF"
fi
ok "IP لوکال 127.20.0.1 حذف شد / local IP removed"

# ۵) فایل‌ها و پوشه‌ها
rm -f /usr/local/bin/psictl /etc/logrotate.d/psiphon-multi-region
if [[ $INSTALL_DIR == "/opt/psiphon-multi-region" && -d $INSTALL_DIR ]]; then
  rm -rf --one-file-system "$INSTALL_DIR"
fi
ok "پوشه‌ها حذف شد / files removed"

# ۶) کاربر سیستمی
if id -u "$SVC_USER" >/dev/null 2>&1; then
  userdel "$SVC_USER" 2>/dev/null || warn "userdel $SVC_USER ناموفق / failed"
fi
if getent group "$SVC_USER" >/dev/null 2>&1; then groupdel "$SVC_USER" 2>/dev/null || true; fi
ok "کاربر $SVC_USER حذف شد / user removed"

if (( PURGE_LOGS == 1 )); then
  rm -f "$LOG_FILE" "$LOG_FILE".*
  ok "لاگ نصب حذف شد / installer log removed"
else
  warn "لاگ نصب نگه داشته شد / installer log kept: $LOG_FILE (--purge-logs)"
fi

ok "حذف کامل شد / Uninstall complete."
