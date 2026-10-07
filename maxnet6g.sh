#!/usr/bin/env bash
# =============================================================================
#   __  __    _    __  __ _   _ _____ _____ __    ____
#  |  \/  |  / \   \ \/ /| \ | | ____|_   _/ /_  / ___|
#  | |\/| | / _ \   \  / |  \| |  _|   | || '_ \| |  _
#  | |  | |/ ___ \  /  \ | |\  | |___  | || (_) | |_| |
#  |_|  |_/_/   \_\/_/\_\|_| \_|_____| |_| \___/ \____|
#
#  MAXNET6G - Ultimate Server Optimizer | Speed • Gaming • Streaming
#
#  Supported : Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12
#              CentOS Stream / AlmaLinux / Rocky 8-9 (best effort)
#  Usage     : chmod +x maxnet6g.sh && ./maxnet6g.sh
#  CLI       : ./maxnet6g.sh [--iran|--abroad|--status|--rollback] [--yes] [--lang fa|en]
#  Log       : /var/log/maxnet6g.log
#  Backups   : /root/maxnet6g-backup/<date>/
# =============================================================================

# NOTE: no 'set -e' on purpose: one failing step must never abort the whole run.
set -o pipefail
umask 022

# ----------------------------------------------------------------------------
# Global constants
# ----------------------------------------------------------------------------
readonly VERSION="1.0.0"
readonly LOG_FILE="/var/log/maxnet6g.log"
readonly BACKUP_ROOT="/root/maxnet6g-backup"
readonly STATE_DIR="/var/lib/maxnet6g"
readonly SYSCTL_FILE="/etc/sysctl.d/99-maxnet6g.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-maxnet6g.conf"
readonly SYSTEMD_SYS_CONF="/etc/systemd/system.conf.d/99-maxnet6g.conf"
readonly SYSTEMD_USER_CONF="/etc/systemd/user.conf.d/99-maxnet6g.conf"
readonly JOURNALD_CONF="/etc/systemd/journald.conf.d/99-maxnet6g.conf"
readonly RESOLVED_CONF="/etc/systemd/resolved.conf.d/99-maxnet6g.conf"
readonly UDEV_IO_RULE="/etc/udev/rules.d/60-maxnet6g-io.rules"
readonly MODULES_FILE="/etc/modules-load.d/maxnet6g.conf"
readonly MODPROBE_FILE="/etc/modprobe.d/maxnet6g.conf"
readonly BOOT_SCRIPT="/usr/local/sbin/maxnet6g-boot.sh"
readonly BOOT_SERVICE="/etc/systemd/system/maxnet6g-boot.service"
readonly SWAPFILE="/swapfile-maxnet6g"
readonly XANMOD_LIST="/etc/apt/sources.list.d/xanmod-release.list"

# Files/dirs that get backed up before ANY change
readonly BACKUP_TARGETS=(
  /etc/sysctl.conf /etc/sysctl.d
  /etc/security/limits.conf /etc/security/limits.d
  /etc/resolv.conf /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d
  /etc/apt/sources.list /etc/apt/sources.list.d
  /etc/yum.repos.d
  /etc/fstab /etc/hosts
  /etc/systemd/system.conf /etc/systemd/system.conf.d
  /etc/systemd/user.conf /etc/systemd/user.conf.d
  /etc/systemd/journald.conf /etc/systemd/journald.conf.d
  /etc/default/zramswap
  /etc/chrony /etc/chrony.conf
  /etc/pam.d/common-session
  /etc/modules-load.d /etc/modprobe.d
  /etc/udev/rules.d
  /etc/fail2ban/jail.local
)

# Non-interactive package management (also silences needrestart prompts on Ubuntu 22+)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
readonly APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o Acquire::Retries=3)

# Use a UTF-8 locale if one exists (for box-drawing / Persian), otherwise stay with C
if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then export LC_ALL=C.UTF-8; fi

# ----------------------------------------------------------------------------
# Colors
# ----------------------------------------------------------------------------
R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; B=$'\e[1;34m'
M=$'\e[1;35m'; C=$'\e[1;36m'; W=$'\e[1;37m'; D=$'\e[2m'; N=$'\e[0m'

# ----------------------------------------------------------------------------
# Runtime state (filled later)
# ----------------------------------------------------------------------------
UI_LANG=""            # fa | en
AUTO_YES=0            # --yes: accept defaults for every question
CLI_ACTION=""         # iran | abroad | status | rollback
PROFILE=""            # iran | abroad
BACKUP_DIR=""
OS_ID=""; OS_VER=""; OS_NAME=""; OS_CODENAME=""; OS_LIKE=""; PKG="unknown"
KERNEL=""; KVER_MAJ=0; KVER_MIN=0; ARCH=""
CPU_CORES=1; CPU_MODEL=""; RAM_KB=0; RAM_MB=0
IFACE=""; VIRT="none"; IS_CONTAINER=0
CC_ALGO="cubic"       # chosen TCP congestion control
TARGET_MTU=""         # empty = do not touch MTU
SELECTED_MIRROR=""
DNS_SERVERS=""; DNS_NAME=""; DNS_MODE="auto"; DNS_CUSTOM=""
# user choices (asked up front, so long steps run unattended)
OPT_TIMEZONE=""; OPT_DISABLE_SERVICES=0; OPT_IP_FORWARD=0; OPT_FAIL2BAN=0
OPT_SWAP_MODE="skip"; OPT_NOATIME=0; OPT_TUNED_PROFILE="throughput-performance"
OPT_XANMOD=0; OPT_DROP_CACHES=0
SERVICES_TO_DISABLE=()

SUMMARY_OK=(); SUMMARY_FAIL=(); SUMMARY_SKIP=()

# Ping targets used by status / before-after snapshots  (name|ip)
PING_TARGETS=("Google|8.8.8.8" "Cloudflare|1.1.1.1" "Telegram|149.154.167.51" "Iran-Shecan|178.22.122.100")

# ============================================================================
# Section 0: helpers (i18n, logging, printing, prompts, spinner)
# ============================================================================

# t "<farsi>" "<english>"  -> prints the string for the selected language
t() { if [[ $UI_LANG == fa ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# Write a timestamped line to the log file
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null; }

info() { printf "  ${B}ℹ${N} %s\n" "$*"; log "INFO: $*"; }
ok()   { printf "  ${G}✔${N} %s\n" "$*"; log "OK: $*"; }
warn() { printf "  ${Y}⚠${N} %s\n" "$*"; log "WARN: $*"; }
err()  { printf "  ${R}✘${N} %s\n" "$*"; log "ERROR: $*"; }

# Section title bar
title() {
  printf "\n${M}┌──────────────────────────────────────────────────────────────────┐${N}\n"
  printf "${M}│${N} ${W}%s${N}\n" "$*"
  printf "${M}└──────────────────────────────────────────────────────────────────┘${N}\n"
  log "===== $* ====="
}

# Read from the real terminal so the script also works with: curl ... | bash
read_tty() { local __p="$1" __v; if [[ -r /dev/tty ]]; then read -r -p "$__p" __v </dev/tty; else read -r -p "$__p" __v; fi; printf '%s' "$__v"; }

# ask_yn "question" <default y|n>  -> returns 0 for yes
ask_yn() {
  local q="$1" def="${2:-n}" ans hint
  [[ $def == y ]] && hint="[Y/n]" || hint="[y/N]"
  if (( AUTO_YES )); then [[ $def == y ]]; return; fi
  ans=$(read_tty "  ${C}?${N} ${q} ${D}${hint}${N} ")
  ans=${ans,,}; [[ -z $ans ]] && ans=$def
  [[ $ans == y || $ans == yes || $ans == "بله" || $ans == "ب" ]]
}

# ask_input "question" "default" -> echoes answer
ask_input() {
  local q="$1" def="$2" ans
  if (( AUTO_YES )); then printf '%s' "$def"; return; fi
  ans=$(read_tty "  ${C}?${N} ${q} ${D}[${def}]${N} ")
  printf '%s' "${ans:-$def}"
}

# run_step "description" function [args...]
# Runs the function in background (output -> log), shows a spinner, records result.
# Function return codes: 0 = success, 2 = skipped (not applicable), other = failure
run_step() {
  local msg="$1"; shift
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0 rc pid
  log "STEP START: $msg"
  ( "$@" ) >>"$LOG_FILE" 2>&1 &
  pid=$!
  if [[ -t 1 ]]; then
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
      printf "\r  ${C}%s${N} %s " "${frames[i++ % 10]}" "$msg"
      sleep 0.12
    done
    tput cnorm 2>/dev/null
  fi
  wait "$pid"; rc=$?
  case $rc in
    0) printf "\r\033[K  ${G}✔${N} %s\n" "$msg"; SUMMARY_OK+=("$msg"); log "STEP OK: $msg" ;;
    2) printf "\r\033[K  ${Y}⊘${N} %s ${D}(%s)${N}\n" "$msg" "$(t 'رد شد' 'skipped')"; SUMMARY_SKIP+=("$msg"); log "STEP SKIPPED: $msg" ;;
    *) printf "\r\033[K  ${R}✘${N} %s ${D}(%s)${N}\n" "$msg" "$(t 'ناموفق، جزئیات در لاگ' 'failed, see log')"; SUMMARY_FAIL+=("$msg"); log "STEP FAILED($rc): $msg" ;;
  esac
  return "$rc"
}

# Package install wrapper for apt / dnf / yum
pkg_install() {
  case $PKG in
    apt)     apt-get install "${APT_OPTS[@]}" "$@" ;;
    dnf|yum) "$PKG" install -y -q "$@" ;;
    *)       return 1 ;;
  esac
}

pkg_installed() { command -v "$1" >/dev/null 2>&1; }

# Restore cursor on exit / Ctrl+C
cleanup() { tput cnorm 2>/dev/null; }
trap cleanup EXIT
trap 'echo; err "$(t "توسط کاربر متوقف شد" "Interrupted by user")"; exit 130' INT TERM

# ============================================================================
# Section 1: base checks, detection, backup
# ============================================================================

# The script must run as root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    printf "${R}✘ %s${N}\n" "This script must be run as root.  /  این اسکریپت باید با کاربر root اجرا شود."
    printf "${Y}  sudo -i   then   ./maxnet6g.sh${N}\n"
    exit 1
  fi
  mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  log "========== MAXNET6G v$VERSION started (pid $$) =========="
}

# Detect distro, kernel, CPU, RAM, main interface and virtualization type
detect_system() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID,,}"; OS_VER="$VERSION_ID"; OS_NAME="$PRETTY_NAME"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"; OS_LIKE="${ID_LIKE,,}"
  else
    OS_ID="unknown"; OS_NAME="Unknown Linux"
  fi
  case $OS_ID in
    ubuntu|debian) PKG=apt ;;
    centos|almalinux|rocky|rhel|ol|fedora) PKG=dnf; command -v dnf >/dev/null || PKG=yum ;;
    *) if [[ $OS_LIKE == *debian* ]]; then PKG=apt
       elif [[ $OS_LIKE == *rhel* || $OS_LIKE == *fedora* ]]; then PKG=dnf; command -v dnf >/dev/null || PKG=yum
       fi ;;
  esac
  [[ -z $OS_CODENAME && $PKG == apt ]] && OS_CODENAME=$(lsb_release -sc 2>/dev/null)

  KERNEL=$(uname -r); ARCH=$(uname -m)
  KVER_MAJ=$(echo "$KERNEL" | cut -d. -f1); KVER_MIN=$(echo "$KERNEL" | cut -d. -f2 | grep -oE '^[0-9]+')
  CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
  CPU_MODEL=$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//; s/  */ /g')
  [[ -z $CPU_MODEL ]] && CPU_MODEL="$ARCH CPU"
  RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo); RAM_MB=$(( RAM_KB / 1024 ))
  IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
  [[ -z $IFACE ]] && IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}' | cut -d@ -f1)

  VIRT=$(systemd-detect-virt 2>/dev/null); [[ -z $VIRT ]] && VIRT="none"
  [[ -d /proc/vz && ! -d /proc/bc ]] && VIRT="openvz"
  case $VIRT in openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn|wsl|rkt) IS_CONTAINER=1 ;; *) IS_CONTAINER=0 ;; esac
  log "Detected: os=$OS_NAME pkg=$PKG kernel=$KERNEL arch=$ARCH cores=$CPU_CORES ram=${RAM_MB}MB iface=$IFACE virt=$VIRT container=$IS_CONTAINER"
}

# Warn about unsupported environments
check_environment() {
  if [[ $PKG == unknown ]]; then
    warn "$(t 'توزیع ناشناخته؛ فقط تنظیمات عمومی اعمال می‌شود.' 'Unknown distro: only generic tuning will be applied.')"
  fi
  if (( IS_CONTAINER )); then
    warn "$(t "سرور از نوع $VIRT است: تغییر کرنل، swap، دیسک و بعضی sysctlها رد می‌شوند." "This is a $VIRT container: kernel, swap, disk and some sysctl tweaks will be skipped.")"
  fi
}

# Backup every config file we may touch into /root/maxnet6g-backup/<date>/
backup_configs() {
  BACKUP_DIR="$BACKUP_ROOT/$(date +%F_%H-%M-%S)"
  mkdir -p "$BACKUP_DIR/files"
  local f
  for f in "${BACKUP_TARGETS[@]}"; do
    if [[ -e $f || -L $f ]]; then cp -a --parents "$f" "$BACKUP_DIR/files/" 2>/dev/null; fi
  done
  cat /etc/resolv.conf >"$BACKUP_DIR/resolv.conf.content" 2>/dev/null       # real resolver content (even if symlink)
  sysctl -a >"$BACKUP_DIR/sysctl-runtime.txt" 2>/dev/null                   # runtime values for reference
  cat >"$BACKUP_DIR/info" <<EOF
date=$(date '+%F %T')
profile=$PROFILE
kernel=$KERNEL
os=$OS_NAME
iface=$IFACE
mtu=$(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null)
EOF
  [[ -d $BACKUP_DIR/files/etc ]]
}

# ============================================================================
# Section 2: UI (banner, system info box, menu)
# ============================================================================

# Gradient ASCII banner (cyan -> blue -> purple, 256-color ANSI)
show_banner() {
  clear 2>/dev/null
  local colors=(51 45 39 63 99 129) i=0 line
  local art=(
    "  ███╗   ███╗ █████╗ ██╗  ██╗███╗   ██╗███████╗████████╗ ██████╗  ██████╗ "
    "  ████╗ ████║██╔══██╗╚██╗██╔╝████╗  ██║██╔════╝╚══██╔══╝██╔════╝ ██╔════╝ "
    "  ██╔████╔██║███████║ ╚███╔╝ ██╔██╗ ██║█████╗     ██║   ███████╗ ██║  ███╗"
    "  ██║╚██╔╝██║██╔══██║ ██╔██╗ ██║╚██╗██║██╔══╝     ██║   ██╔═══██╗██║   ██║"
    "  ██║ ╚═╝ ██║██║  ██║██╔╝ ██╗██║ ╚████║███████╗   ██║   ╚██████╔╝╚██████╔╝"
    "  ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝  ╚═════╝ "
  )
  echo
  for line in "${art[@]}"; do printf '\e[1;38;5;%sm%s\e[0m\n' "${colors[i++]}" "$line"; done
  printf "\n      ${W}Ultimate Server Optimizer${N} ${D}|${N} ${C}Speed${N} • ${B}Gaming${N} • ${M}Streaming${N}   ${D}v%s${N}\n\n" "$VERSION"
}

# Public IP with several fallbacks and short timeouts (no hard dependency on any single site)
get_public_ip() {
  local ip u
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://ipinfo.io/ip; do
    ip=$(curl -4 -fsS --max-time 3 "$u" 2>/dev/null | tr -d '[:space:]')
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
  done
  ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1 | sed 's/$/ (local)/'
}

box_top()    { printf "${C}╔%s╗${N}\n" "$(printf '═%.0s' $(seq 1 66))"; }
box_mid()    { printf "${C}╠%s╣${N}\n" "$(printf '═%.0s' $(seq 1 66))"; }
box_bottom() { printf "${C}╚%s╝${N}\n" "$(printf '═%.0s' $(seq 1 66))"; }
box_line()   { local v="$2"; printf "${C}║${N} ${Y}%-16s${N} ${W}%-47s${N} ${C}║${N}\n" "$1" "${v:0:47}"; }

# System information box
show_sysinfo() {
  local mem_free disk cc uptime_s pubip
  mem_free=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
  disk=$(df -h / 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$5" used)"}')
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  uptime_s=$(uptime -p 2>/dev/null | sed 's/^up //')
  pubip=$(get_public_ip)
  box_top
  printf "${C}║${N} ${W}%-64s${N} ${C}║${N}\n" "                     SYSTEM INFORMATION"
  box_mid
  box_line "OS"          "$OS_NAME"
  box_line "Kernel"      "$KERNEL ($ARCH)"
  box_line "CPU"         "$CPU_MODEL"
  box_line "CPU Cores"   "$CPU_CORES"
  box_line "RAM"         "${RAM_MB} MB total / ${mem_free} MB available"
  box_line "Disk (/)"    "$disk"
  box_line "Public IP"   "${pubip:-N/A}"
  box_line "Interface"   "${IFACE:-N/A} (MTU $(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null))"
  box_line "Virtualizer" "$VIRT"
  box_line "Uptime"      "${uptime_s:-N/A}"
  box_line "TCP Algo"    "${cc:-N/A} / qdisc $(sysctl -n net.core.default_qdisc 2>/dev/null)"
  box_bottom
}

# Main menu (left-bordered so emoji / Persian width does not break the frame)
show_menu() {
  printf "\n${B}╔══════════════════════════════════════════════════════════════════${N}\n"
  printf "${B}║${N}  ${W}%s${N}\n" "$(t 'منوی اصلی' 'MAIN MENU')"
  printf "${B}╠══════════════════════════════════════════════════════════════════${N}\n"
  printf "${B}║${N}  ${G}[1]${N} 🇮🇷  %s\n" "$(t 'بهینه‌سازی سرور ایران' 'Optimize IRAN server')"
  printf "${B}║${N}  ${G}[2]${N} 🌍  %s\n" "$(t 'بهینه‌سازی سرور خارج' 'Optimize ABROAD (foreign) server')"
  printf "${B}║${N}  ${G}[3]${N} 📊  %s\n" "$(t 'نمایش وضعیت فعلی و تست سرعت' 'Show current status & speed test')"
  printf "${B}║${N}  ${G}[4]${N} ♻️   %s\n" "$(t 'بازگردانی تنظیمات از بکاپ (Rollback)' 'Rollback from backup')"
  printf "${B}║${N}  ${R}[0]${N} ❌  %s\n" "$(t 'خروج' 'Exit')"
  printf "${B}╚══════════════════════════════════════════════════════════════════${N}\n"
}

# Language picker
choose_language() {
  [[ -n $UI_LANG ]] && return
  if (( AUTO_YES )); then UI_LANG=en; return; fi
  printf "\n  ${C}Language / زبان:${N}  ${G}[1]${N} فارسی   ${G}[2]${N} English\n"
  case $(read_tty "  > ") in 1) UI_LANG=fa ;; *) UI_LANG=en ;; esac
}

# ============================================================================
# Section 3: repositories (Iran mirrors / global mirrors)
# ============================================================================

# Measure a mirror: echo milliseconds to fetch the Release file, 99999 on failure
mirror_latency() {
  local url="$1" out code tt
  out=$(curl -o /dev/null -s -L -w '%{http_code} %{time_total}' --connect-timeout 3 --max-time 10 "$url" 2>/dev/null)
  code=${out%% *}; tt=${out#* }
  if [[ $code == 200 ]]; then awk -v t="$tt" 'BEGIN{printf "%d", t*1000}'; else echo 99999; fi
}

# Test candidate mirrors (foreground, prints a small table) and set SELECTED_MIRROR
select_fastest_mirror() {
  SELECTED_MIRROR=""
  [[ $PKG != apt ]] && return 2
  [[ $ARCH != x86_64 && $ARCH != amd64 ]] && { warn "$(t 'معماری غیر amd64: میرورها تغییر نمی‌کنند.' 'Non-amd64 arch: mirrors left unchanged.')"; return 2; }
  [[ -z $OS_CODENAME ]] && return 2
  local mirrors=() m ms best=99999 path
  if [[ $OS_ID == ubuntu ]]; then
    path="ubuntu"
    if [[ $PROFILE == iran ]]; then
      mirrors=(https://mirror.arvancloud.ir/ubuntu http://mirror.iranserver.com/ubuntu https://archive.ubuntu.petiak.ir/ubuntu http://ir.archive.ubuntu.com/ubuntu)
    else
      mirrors=(http://archive.ubuntu.com/ubuntu http://mirrors.edge.kernel.org/ubuntu http://mirror.leaseweb.net/ubuntu http://mirror.hetzner.com/ubuntu/packages)
    fi
  elif [[ $OS_ID == debian ]]; then
    path="debian"
    if [[ $PROFILE == iran ]]; then
      mirrors=(https://mirror.arvancloud.ir/debian http://mirror.iranserver.com/debian http://deb.debian.org/debian)
    else
      mirrors=(http://deb.debian.org/debian http://mirrors.edge.kernel.org/debian http://ftp.debian.org/debian)
    fi
  else
    return 2
  fi
  info "$(t 'تست سرعت میرورها...' 'Testing mirror speed...')"
  for m in "${mirrors[@]}"; do
    ms=$(mirror_latency "$m/dists/$OS_CODENAME/Release")
    if (( ms < 99999 )); then printf "     ${D}%-48s${N} ${G}%6s ms${N}\n" "$m" "$ms"; else printf "     ${D}%-48s${N} ${R}%9s${N}\n" "$m" "fail"; fi
    log "mirror $m -> $ms"
    if (( ms < best )); then best=$ms; SELECTED_MIRROR=$m; fi
  done
  : "$path"
  if [[ -z $SELECTED_MIRROR ]]; then warn "$(t 'هیچ میروری در دسترس نبود؛ مخزن فعلی حفظ می‌شود.' 'No mirror reachable; keeping current repositories.')"; return 2; fi
  ok "$(t 'سریع‌ترین میرور:' 'Fastest mirror:') $SELECTED_MIRROR (${best} ms)"
}

# Write the new sources (deb822 on Ubuntu 24.04+, classic sources.list otherwise)
apply_mirror() {
  [[ -z $SELECTED_MIRROR ]] && return 2
  local m="$SELECTED_MIRROR" c="$OS_CODENAME" sec comps
  if [[ $OS_ID == ubuntu ]]; then
    comps="main restricted universe multiverse"
    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
      cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
# Generated by MAXNET6G $(date '+%F %T') - original saved in $BACKUP_DIR
Types: deb
URIs: $m/
Suites: $c $c-updates $c-backports $c-security
Components: $comps
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
      echo "# Managed by MAXNET6G: see /etc/apt/sources.list.d/ubuntu.sources" >/etc/apt/sources.list
    else
      cat >/etc/apt/sources.list <<EOF
# Generated by MAXNET6G $(date '+%F %T') - original saved in $BACKUP_DIR
deb $m $c $comps
deb $m $c-updates $comps
deb $m $c-backports $comps
deb $m $c-security $comps
EOF
    fi
  else
    # Debian: 12+ has non-free-firmware component
    if [[ ${OS_VER%%.*} -ge 12 ]]; then comps="main contrib non-free non-free-firmware"; else comps="main contrib non-free"; fi
    if [[ $m == *arvancloud* ]]; then sec="${m%/debian}/debian-security"; else sec="http://security.debian.org/debian-security"; fi
    [[ -f /etc/apt/sources.list.d/debian.sources ]] && mv /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/debian.sources.maxnet6g-disabled
    cat >/etc/apt/sources.list <<EOF
# Generated by MAXNET6G $(date '+%F %T') - original saved in $BACKUP_DIR
deb $m $c $comps
deb $m $c-updates $comps
deb $sec $c-security $comps
EOF
  fi
  # Verify; on failure restore the original repo files from backup
  if ! apt-get update -o Acquire::Retries=2 -o Acquire::http::Timeout=15; then
    echo "apt-get update failed with new mirror, restoring original sources"
    cp -a "$BACKUP_DIR/files/etc/apt/." /etc/apt/ 2>/dev/null
    rm -f /etc/apt/sources.list.d/debian.sources.maxnet6g-disabled
    apt-get update
    return 1
  fi
}

# ============================================================================
# Section 4: DNS (Iran: Shecan/403/Electro, Abroad: Cloudflare/Google/Quad9)
# ============================================================================

# Provider list for the current profile:  "Name|ip1 ip2"
dns_providers() {
  if [[ $PROFILE == iran ]]; then
    printf '%s\n' "Shecan|178.22.122.100 185.51.200.2" "403.online|10.202.10.202 10.202.10.102" \
                  "Electro|78.157.42.100 78.157.42.101" "Begzar|185.55.226.26 185.55.225.25"
  else
    printf '%s\n' "Cloudflare|1.1.1.1 1.0.0.1" "Google|8.8.8.8 8.8.4.4" "Quad9|9.9.9.9 149.112.112.112"
  fi
}

# Average ping in ms (9999 if unreachable)
ping_ms() {
  local r
  r=$(ping -c 3 -W 2 -i 0.3 -q "$1" 2>/dev/null | awk -F'/' '/^(rtt|round-trip)/{printf "%d", $5}')
  [[ -n $r ]] && echo "$r" || echo 9999
}

# Does this resolver actually answer? (skipped if dig not installed yet)
dns_answers() {
  command -v dig >/dev/null 2>&1 || return 0
  dig +short +time=2 +tries=1 @"$1" google.com A 2>/dev/null | grep -qE '^[0-9.]+$'
}

# Ask the user which DNS to use (stored in DNS_MODE / DNS_SERVERS)
ask_dns_choice() {
  local i=1 line name ips choice
  local -a names=() ipsets=()
  while IFS= read -r line; do names+=("${line%%|*}"); ipsets+=("${line#*|}"); done < <(dns_providers)
  printf "\n  ${W}%s${N}\n" "$(t 'انتخاب DNS:' 'DNS selection:')"
  printf "     ${G}[0]${N} %s\n" "$(t 'خودکار: تست پینگ و انتخاب سریع‌ترین (پیشنهادی)' 'Auto: ping test & pick the fastest (recommended)')"
  for i in "${!names[@]}"; do printf "     ${G}[%d]${N} %-12s ${D}%s${N}\n" "$((i+1))" "${names[i]}" "${ipsets[i]}"; done
  printf "     ${G}[c]${N} %s\n" "$(t 'DNS دلخواه' 'Custom DNS')"
  printf "     ${G}[s]${N} %s\n" "$(t 'تغییر نده' 'Do not change DNS')"
  choice=$(ask_input "$(t 'انتخاب شما' 'Your choice')" "0")
  case $choice in
    0) DNS_MODE=auto ;;
    s|S) DNS_MODE=skip ;;
    c|C) DNS_MODE=custom
         DNS_CUSTOM=$(ask_input "$(t 'آی‌پی DNSها با فاصله' 'DNS IPs separated by space')" "1.1.1.1 8.8.8.8")
         DNS_SERVERS="$DNS_CUSTOM"; DNS_NAME="Custom" ;;
    *) if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
         DNS_MODE=fixed; DNS_NAME="${names[choice-1]}"; DNS_SERVERS="${ipsets[choice-1]}"
       else DNS_MODE=auto; fi ;;
  esac
}

# Run the ping test (foreground) when DNS_MODE=auto
resolve_dns_choice() {
  [[ $DNS_MODE == skip ]] && return 2
  if [[ $DNS_MODE == auto ]]; then
    local line name ips first ms best=9999
    info "$(t 'تست پینگ DNSها...' 'Pinging DNS providers...')"
    while IFS= read -r line; do
      name="${line%%|*}"; ips="${line#*|}"; first="${ips%% *}"
      ms=$(ping_ms "$first")
      if (( ms < 9999 )) && ! dns_answers "$first"; then ms=9999; fi
      if (( ms < 9999 )); then printf "     ${D}%-12s %-32s${N} ${G}%5s ms${N}\n" "$name" "$ips" "$ms"
      else printf "     ${D}%-12s %-32s${N} ${R}%8s${N}\n" "$name" "$ips" "fail"; fi
      if (( ms < best )); then best=$ms; DNS_NAME=$name; DNS_SERVERS=$ips; fi
    done < <(dns_providers)
    if [[ -z $DNS_SERVERS ]]; then warn "$(t 'هیچ DNSی پاسخ نداد؛ DNS تغییر نمی‌کند.' 'No DNS answered; DNS left unchanged.')"; return 2; fi
    ok "$(t 'سریع‌ترین DNS:' 'Fastest DNS:') $DNS_NAME ($DNS_SERVERS, ${best} ms)"
  fi
  return 0
}

# Apply DNS via systemd-resolved (with cache) or a locked /etc/resolv.conf
apply_dns() {
  [[ -z $DNS_SERVERS ]] && return 2
  local fallback ip
  if [[ $PROFILE == iran ]]; then fallback="178.22.122.100 1.1.1.1"; else fallback="1.1.1.1 8.8.8.8"; fi
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p "$(dirname "$RESOLVED_CONF")"
    cat >"$RESOLVED_CONF" <<EOF
# MAXNET6G DNS ($DNS_NAME)
[Resolve]
# Global resolvers
DNS=$DNS_SERVERS
# Used only if the resolvers above are down
FallbackDNS=$fallback
# Route ALL domains to the global resolvers (overrides DHCP-provided DNS)
Domains=~.
# Local DNS cache: faster page loads for browsing/streaming clients
Cache=yes
DNSStubListener=yes
EOF
    chattr -i /etc/resolv.conf 2>/dev/null
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved || return 1
    resolvectl flush-caches 2>/dev/null
  else
    # No systemd-resolved: write resolv.conf and lock it (chattr +i) so DHCP/NM can't overwrite it
    chattr -i /etc/resolv.conf 2>/dev/null
    rm -f /etc/resolv.conf
    {
      echo "# MAXNET6G DNS ($DNS_NAME) - locked with chattr +i (chattr -i /etc/resolv.conf to edit)"
      for ip in $DNS_SERVERS; do echo "nameserver $ip"; done
      echo "options timeout:2 attempts:2 rotate"
    } >/etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null
    # Local DNS cache with nscd when available
    if ! pkg_installed nscd; then pkg_install nscd >/dev/null 2>&1; fi
    systemctl enable --now nscd 2>/dev/null
  fi
  sleep 1
  getent hosts google.com >/dev/null || getent hosts debian.org >/dev/null
}

# ============================================================================
# Section 5: MTU discovery (Iran profile)
# ============================================================================

# Binary search the largest payload that passes with DF bit, return MTU
detect_best_mtu() {
  local target="" t lo=1200 hi=1472 mid best=0 cur
  for t in 178.22.122.100 185.51.200.2 8.8.8.8 1.1.1.1; do
    ping -c 2 -W 2 -i 0.3 "$t" >/dev/null 2>&1 && { target=$t; break; }
  done
  [[ -z $target ]] && { warn "$(t 'مقصدی برای تست MTU در دسترس نیست.' 'No target reachable for MTU test.')"; return 2; }
  info "$(t 'تست MTU با' 'Testing MTU against') $target ..."
  while (( lo <= hi )); do
    mid=$(( (lo + hi) / 2 ))
    if ping -M do -s "$mid" -c 2 -i 0.2 -W 2 "$target" >/dev/null 2>&1; then best=$mid; lo=$((mid + 1)); else hi=$((mid - 1)); fi
  done
  (( best == 0 )) && { warn "$(t 'تست MTU نتیجه نداد.' 'MTU test inconclusive.')"; return 2; }
  cur=$(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null)
  local found=$(( best + 28 ))
  if [[ -n $cur ]] && (( found < cur )); then
    TARGET_MTU=$found
    ok "$(t "بهترین MTU: $found (فعلی: $cur) → اعمال می‌شود" "Best MTU: $found (current $cur) → will be applied")"
  else
    ok "$(t "MTU فعلی ($cur) مناسب است." "Current MTU ($cur) is already optimal.")"
  fi
}

# ============================================================================
# Section 6: common software tasks (5.1)
# ============================================================================

# Full system update
system_update() {
  case $PKG in
    apt) apt-get update -o Acquire::Retries=3 && apt-get upgrade "${APT_OPTS[@]}" && apt-get autoremove -y -q && apt-get autoclean -q ;;
    dnf|yum) "$PKG" -y -q upgrade && "$PKG" -y -q autoremove && "$PKG" clean all ;;
    *) return 2 ;;
  esac
}

# Install essential tools one by one (a missing package never breaks the step)
install_essentials() {
  local p failed=()
  local pkgs=(curl wget ca-certificates gnupg htop btop iftop nload net-tools iperf3 irqbalance tuned chrony ethtool iproute2 bc)
  if [[ $PKG == apt ]]; then
    pkgs+=(dnsutils speedtest-cli zram-tools lsb-release)
    apt-get update -q >/dev/null 2>&1
  elif [[ $PKG == dnf || $PKG == yum ]]; then
    "$PKG" install -y -q epel-release >/dev/null 2>&1
    pkgs=("${pkgs[@]/iproute2/iproute}"); pkgs+=(bind-utils python3-pip)
  else
    return 2
  fi
  pkg_install "${pkgs[@]}" >/dev/null 2>&1 || for p in "${pkgs[@]}"; do pkg_install "$p" || failed+=("$p"); done
  # speedtest-cli fallback via pip (works when the distro does not ship it)
  if ! pkg_installed speedtest-cli && pkg_installed pip3; then pip3 install -q speedtest-cli 2>/dev/null || pip3 install -q --break-system-packages speedtest-cli 2>/dev/null; fi
  printf '%s\n' "${failed[@]}" >"$STATE_DIR/failed_pkgs"
  echo "failed packages: ${failed[*]:-none}"
  return 0
}

# Time sync with chrony (Iran gets ir.pool.ntp.org as extra source)
setup_chrony() {
  pkg_installed chronyd || pkg_installed chronyc || return 1
  local conf=/etc/chrony/chrony.conf; [[ -f $conf ]] || conf=/etc/chrony.conf
  if [[ $PROFILE == iran ]] && ! grep -q 'ir.pool.ntp.org' "$conf" 2>/dev/null; then
    if [[ -d /etc/chrony/sources.d ]]; then echo "pool ir.pool.ntp.org iburst maxsources 3" >/etc/chrony/sources.d/maxnet6g.sources
    else echo "pool ir.pool.ntp.org iburst maxsources 3   # added by MAXNET6G" >>"$conf"; fi
  fi
  systemctl disable --now systemd-timesyncd 2>/dev/null
  systemctl enable chrony 2>/dev/null || systemctl enable chronyd 2>/dev/null
  systemctl restart chrony 2>/dev/null || systemctl restart chronyd 2>/dev/null || return 1
  sleep 2; chronyc -a makestep >/dev/null 2>&1
  return 0
}

# Timezone
set_timezone() {
  [[ -z $OPT_TIMEZONE ]] && return 2
  timedatectl set-timezone "$OPT_TIMEZONE" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$OPT_TIMEZONE" /etc/localtime
}

# Disable unnecessary services chosen by the user
disable_services() {
  (( OPT_DISABLE_SERVICES )) || return 2
  local s
  for s in "${SERVICES_TO_DISABLE[@]}"; do systemctl disable --now "$s" 2>/dev/null && echo "disabled $s"; done
  return 0
}

# Build the list of existing unnecessary services
find_unneeded_services() {
  local s
  SERVICES_TO_DISABLE=()
  for s in snapd.service snapd.socket cups.service cups-browsed.service bluetooth.service avahi-daemon.service avahi-daemon.socket ModemManager.service whoopsie.service apport.service; do
    systemctl list-unit-files "$s" 2>/dev/null | grep -q "^$s" && SERVICES_TO_DISABLE+=("$s")
  done
}

# ============================================================================
# Section 7: kernel / sysctl (5.2 network, 5.3 gaming, 5.4 streaming, 5.5 RAM,
#            5.6 CPU scheduler, 5.7 limits, 5.9 security)
# ============================================================================

# Pick BBR if the kernel supports it (needs >= 4.9), fallback cubic
prepare_bbr() {
  modprobe tcp_bbr 2>/dev/null
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    CC_ALGO=bbr
    (( IS_CONTAINER )) || echo "tcp_bbr" >"$MODULES_FILE"
    ok "$(t 'BBR پشتیبانی می‌شود و فعال خواهد شد.' 'BBR is supported and will be enabled.')"
  else
    CC_ALGO=cubic
    warn "$(t 'کرنل از BBR پشتیبانی نمی‌کند؛ cubic حفظ می‌شود.' 'Kernel has no BBR support; staying on cubic.')"
  fi
  # conntrack module must be loaded so its sysctls exist; hashsize = max/4
  if (( ! IS_CONTAINER )); then
    modprobe nf_conntrack 2>/dev/null && echo "nf_conntrack" >>"$MODULES_FILE"
  fi
}

# Generate /etc/sysctl.d/99-maxnet6g.conf with RAM-aware values
write_sysctl() {
  local buf_max pages tm_low tm_pr tm_high ct_max min_free ka_time ka_intvl ka_probes
  # Max socket buffer by RAM (bigger RAM -> bigger windows -> more throughput on high-BDP paths)
  if   (( RAM_MB <= 1024 )); then buf_max=16777216    # 16 MB
  elif (( RAM_MB <= 4096 )); then buf_max=33554432    # 32 MB
  elif (( RAM_MB <= 8192 )); then buf_max=67108864    # 64 MB
  else                            buf_max=134217728   # 128 MB
  fi
  # Abroad servers carry long international paths (high BDP) -> double the buffers
  [[ $PROFILE == abroad ]] && buf_max=$(( buf_max * 2 ))
  (( buf_max > 268435456 )) && buf_max=268435456
  pages=$(( RAM_KB / 4 ))                                     # 4 KB pages
  tm_low=$(( pages * 4 / 100 )); tm_pr=$(( pages * 6 / 100 )); tm_high=$(( pages * 10 / 100 ))
  ct_max=$(( RAM_MB * 64 )); (( ct_max < 131072 )) && ct_max=131072; (( ct_max > 2097152 )) && ct_max=2097152
  min_free=$(( RAM_KB / 100 )); (( min_free < 16384 )) && min_free=16384; (( min_free > 262144 )) && min_free=262144
  if [[ $PROFILE == iran ]]; then ka_time=120; ka_intvl=15; ka_probes=5; else ka_time=600; ka_intvl=30; ka_probes=5; fi

  # conntrack hash size via module option (buckets = max / 4)
  (( IS_CONTAINER )) || echo "options nf_conntrack hashsize=$(( ct_max / 4 ))" >"$MODPROBE_FILE"

  {
  cat <<EOF
# =====================================================================
#  MAXNET6G kernel tuning - profile: $PROFILE - generated $(date '+%F %T')
#  RAM=${RAM_MB}MB cores=$CPU_CORES kernel=$KERNEL virt=$VIRT
#  Remove this file + 'sysctl --system' (or use MAXNET6G rollback) to revert
# =====================================================================

# ---------------- 5.2 Network core & congestion control ----------------
# fq qdisc: per-flow fair queueing + pacing (required companion of BBR)
net.core.default_qdisc = fq
# BBR: model-based congestion control, much better on lossy / long links
net.ipv4.tcp_congestion_control = $CC_ALGO
# TCP Fast Open for both client and server (saves 1 RTT on reconnects)
net.ipv4.tcp_fastopen = 3
# Probe path MTU when ICMP is blocked (black-hole detection)
net.ipv4.tcp_mtu_probing = 1
# Start MSS used by MTU probing
net.ipv4.tcp_base_mss = 1024
# Don't shrink cwnd after an idle period (keeps streams fast after pauses)
net.ipv4.tcp_slow_start_after_idle = 0
# Don't reuse cached metrics of old connections (avoids stale bad ssthresh)
net.ipv4.tcp_no_metrics_save = 1
# Reuse TIME_WAIT sockets for new outgoing connections
net.ipv4.tcp_tw_reuse = 1
# Release FIN_WAIT2 sockets faster
net.ipv4.tcp_fin_timeout = 15
# Cap TIME_WAIT buckets
net.ipv4.tcp_max_tw_buckets = 262144
# Wider ephemeral port range for many outgoing connections (proxies/VPN)
net.ipv4.ip_local_port_range = 10240 65535
# Bigger accept queue for busy services
net.core.somaxconn = 65535
# Bigger SYN queue
net.ipv4.tcp_max_syn_backlog = 65535
# Packets queued on input when the kernel is slower than the NIC
net.core.netdev_max_backlog = 32768
# Packets processed per NAPI poll cycle
net.core.netdev_budget = 600
# Ancillary socket buffer
net.core.optmem_max = 81920
# Global RFS table (Receive Flow Steering, per-queue values set by boot script)
net.core.rps_sock_flow_entries = 32768

# ---------------- 5.2 / 5.4 Buffers (RAM-aware, max=${buf_max} bytes) ----------------
# Max receive / send buffer any socket may request
net.core.rmem_max = $buf_max
net.core.wmem_max = $buf_max
# Default buffer for sockets that don't set one (UDP apps, VPN)
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
# TCP auto-tuning: min / default / max  (large max = high throughput downloads/streams)
net.ipv4.tcp_rmem = 4096 131072 $buf_max
net.ipv4.tcp_wmem = 4096 65536 $buf_max
# Total TCP memory in pages: low / pressure / high (~4% / 6% / 10% of RAM)
net.ipv4.tcp_mem = $tm_low $tm_pr $tm_high
# Total UDP memory in pages
net.ipv4.udp_mem = $tm_low $tm_pr $tm_high
# Let the kernel auto-grow receive windows
net.ipv4.tcp_moderate_rcvbuf = 1
# Window scaling: windows > 64KB (mandatory for high throughput)
net.ipv4.tcp_window_scaling = 1
# Selective ACK / duplicate SACK: recover from loss without resending everything
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
# Timestamps: accurate RTT measurement + PAWS
net.ipv4.tcp_timestamps = 1

# ---------------- 5.3 Gaming / low latency ----------------
# Minimum UDP buffers (game traffic, QUIC, WireGuard)
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
# Legacy low-latency flag (no-op on kernels >= 4.14, harmless)
net.ipv4.tcp_low_latency = 1
# Limit unsent data in socket queue -> lower latency & less bufferbloat
net.ipv4.tcp_notsent_lowat = 16384
# Busy polling (microseconds): lower latency at the cost of a bit of CPU
net.core.busy_poll = 50
net.core.busy_read = 50
# NOTE: Nagle cannot be disabled system-wide; apps must use TCP_NODELAY.
#       tcp_notsent_lowat + fq pacing give the closest kernel-level effect.

# ---------------- 5.4 Long-lived connections (Telegram, streams) ----------------
# Send keepalive after ${ka_time}s idle, every ${ka_intvl}s, drop after ${ka_probes} misses
net.ipv4.tcp_keepalive_time = $ka_time
net.ipv4.tcp_keepalive_intvl = $ka_intvl
net.ipv4.tcp_keepalive_probes = $ka_probes

# ---------------- 5.9 Basic security (no speed cost) ----------------
# SYN flood protection
net.ipv4.tcp_syncookies = 1
# Protect against TIME_WAIT assassination
net.ipv4.tcp_rfc1337 = 1
# Ignore ICMP redirects (MITM protection)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
# Don't send redirects (we're not a router for the LAN)
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# Ignore broadcast pings & bogus ICMP errors
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF

  if [[ $PROFILE == iran ]]; then
  cat <<EOF

# ---------------- Iran: unstable links / high packet loss ----------------
# Give up on dead connections after ~2 min instead of ~15 min
net.ipv4.tcp_retries2 = 8
# Fewer SYN retries -> fail fast and let the app retry
net.ipv4.tcp_syn_retries = 4
net.ipv4.tcp_synack_retries = 3
# Detect spurious retransmission timeouts (common on jittery mobile/ISP links)
net.ipv4.tcp_frto = 2
# RACK-based loss detection (faster recovery on reordering)
net.ipv4.tcp_recovery = 1
# Tail Loss Probe: recover lost tail packets without waiting for RTO
net.ipv4.tcp_early_retrans = 3
# ECN off: some ISP middleboxes drop ECN-marked packets
net.ipv4.tcp_ecn = 0
EOF
  else
  cat <<EOF

# ---------------- Abroad: high-BDP international paths ----------------
# ECN negotiated only when requested by the peer (safe default)
net.ipv4.tcp_ecn = 2
# RACK-based loss detection
net.ipv4.tcp_recovery = 1
# Tail Loss Probe
net.ipv4.tcp_early_retrans = 3
EOF
  fi

  if (( OPT_IP_FORWARD )); then
  cat <<EOF

# ---------------- IP forwarding (VPN / tunnels) ----------------
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
# Keep accepting IPv6 router advertisements even with forwarding on
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.${IFACE//./\/}.accept_ra = 2
EOF
  fi

  if (( ! IS_CONTAINER )); then
  cat <<EOF

# ---------------- Conntrack (NAT / VPN / many connections) ----------------
# Max tracked connections (RAM-aware)
net.netfilter.nf_conntrack_max = $ct_max
# Established TCP entries expire after 2h instead of 5 days
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
# Fast cleanup for closing states
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
# UDP: one-shot 30s, streams (VPN/QUIC/games) 180s
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
# Generic protocols
net.netfilter.nf_conntrack_generic_timeout = 120

# ---------------- 5.5 Memory ----------------
# Prefer RAM, swap only under real pressure
vm.swappiness = 10
# Keep dentry/inode cache longer (faster file access)
vm.vfs_cache_pressure = 50
# Start background writeback at 5% dirty, block writers at 20%
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20
# Reserve free memory for network bursts / atomic allocations (~1% RAM)
vm.min_free_kbytes = $min_free
# More memory map areas (databases, Java, browsers)
vm.max_map_count = 262144

# ---------------- 5.6 CPU scheduler ----------------
# Autogroup is for desktops; servers get fairer scheduling without it
kernel.sched_autogroup_enabled = 0
# Keep tasks on their CPU longer (better cache use; ignored on kernels >= 5.13)
kernel.sched_migration_cost_ns = 5000000
# More PIDs for many processes/threads
kernel.pid_max = 4194304

# ---------------- 5.7 File / inotify limits ----------------
# System-wide open file handles
fs.file-max = 2097152
# Per-process ceiling (must be >= nofile in limits.conf)
fs.nr_open = 2097152
# inotify watchers/instances (panels, log watchers, sync tools)
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
fs.inotify.max_queued_events = 32768
EOF
  fi
  } >"$SYSCTL_FILE"

  # -e: ignore keys this kernel doesn't know; errors are logged but never fatal
  sysctl -e -p "$SYSCTL_FILE"
  [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == "$CC_ALGO" ]] || (( IS_CONTAINER ))
}

# limits.conf + systemd default limits (nofile / nproc = 1048576)
set_limits() {
  cat >"$LIMITS_FILE" <<'EOF'
# MAXNET6G: raise open files / processes (wildcard does not cover root, so root is listed)
*     soft  nofile  1048576
*     hard  nofile  1048576
*     soft  nproc   1048576
*     hard  nproc   1048576
root  soft  nofile  1048576
root  hard  nofile  1048576
root  soft  nproc   1048576
root  hard  nproc   1048576
EOF
  # Make sure PAM applies limits to login sessions (Debian/Ubuntu)
  if [[ -f /etc/pam.d/common-session ]] && ! grep -q pam_limits /etc/pam.d/common-session; then
    echo "session required pam_limits.so   # added by MAXNET6G" >>/etc/pam.d/common-session
  fi
  # systemd services ignore limits.conf -> set defaults for them too
  mkdir -p "$(dirname "$SYSTEMD_SYS_CONF")" "$(dirname "$SYSTEMD_USER_CONF")"
  printf '# MAXNET6G\n[Manager]\nDefaultLimitNOFILE=1048576\nDefaultLimitNPROC=1048576\n' >"$SYSTEMD_SYS_CONF"
  printf '# MAXNET6G\n[Manager]\nDefaultLimitNOFILE=1048576\n' >"$SYSTEMD_USER_CONF"
  systemctl daemon-reexec 2>/dev/null
  return 0
}

# ============================================================================
# Section 8: NIC, RPS/RFS, qdisc, THP, CPU governor (persistent boot script)
# ============================================================================

# Writes /usr/local/sbin/maxnet6g-boot.sh + systemd unit, then runs it now
setup_boot_tuning() {
  cat >"$BOOT_SCRIPT" <<EOF
#!/usr/bin/env bash
# MAXNET6G boot-time tuning (runtime settings that sysctl can't persist)
# generated $(date '+%F %T') - profile $PROFILE
IFACE="$IFACE"
TARGET_MTU="$TARGET_MTU"
IS_CONTAINER=$IS_CONTAINER
EOF
  cat >>"$BOOT_SCRIPT" <<'EOF'
[ -z "$IFACE" ] && IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')
[ -z "$IFACE" ] && exit 0

# CPU bitmask for all cores (comma separated 32-bit groups, as sysfs expects)
cpu_mask() {
  local n=$1 out="" full rem i
  full=$(( n / 32 )); rem=$(( n % 32 ))
  (( rem > 0 )) && out=$(printf '%x' $(( (1 << rem) - 1 )))
  for (( i = 0; i < full; i++ )); do out="${out:+$out,}ffffffff"; done
  echo "$out"
}

# 1) MTU found by the DF-ping test (only ever lowered, never raised)
[ -n "$TARGET_MTU" ] && ip link set dev "$IFACE" mtu "$TARGET_MTU"

# 2) fq qdisc on the main NIC: fair queueing + pacing -> lower jitter for games/VoIP
tc qdisc replace dev "$IFACE" root fq 2>/dev/null

if [ "$IS_CONTAINER" = "0" ]; then
  # 3) NIC ring buffers to hardware maximum (fewer drops on bursts) + offloads
  if command -v ethtool >/dev/null 2>&1; then
    rx_max=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Pre-set maximums/{f=1} f&&/^RX:/{print $2; exit}')
    tx_max=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Pre-set maximums/{f=1} f&&/^TX:/{print $2; exit}')
    rx_cur=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Current hardware/{f=1} f&&/^RX:/{print $2; exit}')
    tx_cur=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Current hardware/{f=1} f&&/^TX:/{print $2; exit}')
    [[ $rx_max =~ ^[0-9]+$ && $rx_cur =~ ^[0-9]+$ && $rx_cur -lt $rx_max ]] && ethtool -G "$IFACE" rx "$rx_max" 2>/dev/null
    [[ $tx_max =~ ^[0-9]+$ && $tx_cur =~ ^[0-9]+$ && $tx_cur -lt $tx_max ]] && ethtool -G "$IFACE" tx "$tx_max" 2>/dev/null
    # GRO/GSO/TSO: let the NIC / kernel batch packets (less CPU per Gbit)
    for o in gro gso tso; do ethtool -K "$IFACE" "$o" on 2>/dev/null; done
  fi

  # 4) RPS/RFS: spread receive processing over all cores
  cores=$(nproc)
  if (( cores > 1 )); then
    mask=$(cpu_mask "$cores")
    qn=$(ls -d /sys/class/net/"$IFACE"/queues/rx-* 2>/dev/null | wc -l)
    (( qn < 1 )) && qn=1
    flow=$(( 32768 / qn ))
    for q in /sys/class/net/"$IFACE"/queues/rx-*; do
      [ -w "$q/rps_cpus" ] && echo "$mask" >"$q/rps_cpus" 2>/dev/null
      [ -w "$q/rps_flow_cnt" ] && echo "$flow" >"$q/rps_flow_cnt" 2>/dev/null
    done
  fi

  # 5) Transparent Huge Pages only when apps ask for it (madvise): no latency spikes
  [ -w /sys/kernel/mm/transparent_hugepage/enabled ] && echo madvise >/sys/kernel/mm/transparent_hugepage/enabled
  [ -w /sys/kernel/mm/transparent_hugepage/defrag ] && echo madvise >/sys/kernel/mm/transparent_hugepage/defrag

  # 6) CPU governor -> performance (only if the VM/host exposes cpufreq)
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$g" ] || continue
    grep -qw performance "${g%/*}/scaling_available_governors" 2>/dev/null && echo performance >"$g"
  done
fi
exit 0
EOF
  chmod 755 "$BOOT_SCRIPT"
  cat >"$BOOT_SERVICE" <<EOF
[Unit]
Description=MAXNET6G boot-time network/CPU tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BOOT_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable maxnet6g-boot.service
  "$BOOT_SCRIPT"
}

# irqbalance spreads hardware interrupts across cores
setup_irqbalance() {
  (( IS_CONTAINER )) && return 2
  (( CPU_CORES < 2 )) && return 2
  pkg_installed irqbalance || return 1
  systemctl enable --now irqbalance
}

# tuned profile (network-latency for gaming, throughput-performance for downloads)
setup_tuned() {
  (( IS_CONTAINER )) && return 2
  pkg_installed tuned-adm || return 1
  systemctl enable --now tuned || return 1
  sleep 1
  tuned-adm profile "$OPT_TUNED_PROFILE" || return 1
  # tuned re-applies /etc/sysctl.d after its own profile (reapply_sysctl=1), so our values win;
  # re-assert anyway, plus our THP=madvise choice
  sysctl -e -p "$SYSCTL_FILE" >/dev/null
  "$BOOT_SCRIPT" >/dev/null 2>&1
  return 0
}

# ============================================================================
# Section 9: RAM (swap / zram / cache)
# ============================================================================
setup_swap() {
  (( IS_CONTAINER )) && return 2
  case $OPT_SWAP_MODE in
    zram)
      if [[ $PKG == apt ]]; then
        pkg_installed zramswap || pkg_install zram-tools || return 1
        modprobe zram 2>/dev/null || return 1
        cat >/etc/default/zramswap <<'EOF'
# MAXNET6G: compressed swap in RAM (zstd, 50% of RAM, higher priority than disk swap)
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
        systemctl enable zramswap && systemctl restart zramswap || return 1
        touch "$STATE_DIR/zram_enabled"
      else
        pkg_install zram-generator || return 1
        printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n' >/etc/systemd/zram-generator.conf
        systemctl daemon-reload && systemctl start systemd-zram-setup@zram0.service || return 1
        touch "$STATE_DIR/zram_enabled"
      fi ;;
    file)
      swapon --show --noheadings 2>/dev/null | grep -q . && { echo "swap already present"; return 2; }
      local size_mb avail_mb
      if (( RAM_MB <= 2048 )); then size_mb=2048; else size_mb=4096; fi
      avail_mb=$(df -Pm / | awk 'NR==2{print $4}')
      (( avail_mb > size_mb + 1024 )) || { echo "not enough disk for swap"; return 1; }
      fallocate -l "${size_mb}M" "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size_mb" status=none || return 1
      chmod 600 "$SWAPFILE" && mkswap "$SWAPFILE" && swapon "$SWAPFILE" || { rm -f "$SWAPFILE"; return 1; }
      grep -q "$SWAPFILE" /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >>/etc/fstab
      touch "$STATE_DIR/swapfile_created" ;;
    *) return 2 ;;
  esac
}

# Drop page cache (optional, harmless, frees cache after the big upgrade)
drop_caches() {
  (( OPT_DROP_CACHES )) || return 2
  (( IS_CONTAINER )) && return 2
  sync && echo 3 >/proc/sys/vm/drop_caches
}

# ============================================================================
# Section 10: disk (I/O scheduler, noatime, fstrim, journald)
# ============================================================================
setup_io_scheduler() {
  (( IS_CONTAINER )) && return 2
  # Persistent rule: NVMe -> none, SATA/virtio -> mq-deadline
  cat >"$UDEV_IO_RULE" <<'EOF'
# MAXNET6G I/O schedulers: NVMe has its own deep queues -> none, others -> mq-deadline
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]*|vd[a-z]*|xvd[a-z]*", ATTR{queue/scheduler}="mq-deadline"
EOF
  udevadm control --reload-rules 2>/dev/null
  # Apply now
  local d s want
  for d in /sys/block/*; do
    s="$d/queue/scheduler"; [[ -w $s ]] || continue
    case ${d##*/} in nvme*) want=none ;; sd*|vd*|xvd*) want=mq-deadline ;; *) continue ;; esac
    grep -qw "$want" "$s" && echo "$want" >"$s" && echo "${d##*/} -> $want"
  done
  return 0
}

# Add noatime to ext4/xfs/btrfs entries in fstab (validated before install)
setup_noatime() {
  (( OPT_NOATIME )) || return 2
  (( IS_CONTAINER )) && return 2
  local tmp; tmp=$(mktemp)
  awk 'BEGIN{OFS="\t"}
       /^[[:space:]]*#/ || NF < 4 {print; next}
       ($3 ~ /^(ext4|ext3|xfs|btrfs)$/) && ($4 !~ /noatime/) {
         o=$4; gsub(/(^|,)(relatime|strictatime|atime)/, "", o); sub(/^,/, "", o)
         if (o == "") o="defaults"; $4=o",noatime" }
       {print}' /etc/fstab >"$tmp"
  if command -v findmnt >/dev/null && ! findmnt --verify --tab-file "$tmp" >/dev/null 2>&1; then
    echo "fstab verification failed, not changed"; rm -f "$tmp"; return 1
  fi
  cat "$tmp" >/etc/fstab; rm -f "$tmp"
  systemctl daemon-reload 2>/dev/null
  mount -o remount,noatime / 2>/dev/null
  return 0
}

# Weekly TRIM for SSD/NVMe
setup_fstrim() {
  (( IS_CONTAINER )) && return 2
  systemctl list-unit-files fstrim.timer >/dev/null 2>&1 || return 2
  systemctl enable --now fstrim.timer
}

# journald size cap (100M) + vacuum old logs
setup_journald() {
  mkdir -p "$(dirname "$JOURNALD_CONF")"
  printf '# MAXNET6G: cap journal size\n[Journal]\nSystemMaxUse=100M\nSystemMaxFileSize=20M\nRuntimeMaxUse=50M\n' >"$JOURNALD_CONF"
  systemctl restart systemd-journald
  journalctl --vacuum-size=100M >/dev/null 2>&1
  return 0
}

# ============================================================================
# Section 11: security
# ============================================================================
setup_fail2ban() {
  (( OPT_FAIL2BAN )) || return 2
  pkg_install fail2ban || return 1
  [[ $PKG == apt ]] && pkg_install python3-systemd >/dev/null 2>&1
  local port; port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}'); port=${port:-22}
  cat >/etc/fail2ban/jail.local <<EOF
# MAXNET6G fail2ban: ban SSH brute-force sources for 1h after 5 failures in 10m
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = $port
EOF
  systemctl enable fail2ban && systemctl restart fail2ban
}

# Warn (never change) when SSH listens on 22 with password auth
check_ssh_security() {
  command -v sshd >/dev/null || return 0
  local cfg port pass root
  cfg=$(sshd -T 2>/dev/null)
  port=$(awk '/^port /{print $2; exit}' <<<"$cfg")
  pass=$(awk '/^passwordauthentication /{print $2; exit}' <<<"$cfg")
  root=$(awk '/^permitrootlogin /{print $2; exit}' <<<"$cfg")
  if [[ $port == 22 && $pass == yes ]]; then
    warn "$(t 'SSH روی پورت 22 با ورود رمزی باز است! پیشنهاد: کلید SSH، تغییر پورت، یا fail2ban.' 'SSH is on port 22 with password login! Use SSH keys, change the port, or enable fail2ban.')"
  fi
  [[ $root == yes && $pass == yes ]] && warn "$(t 'ورود root با رمز مجاز است.' 'Root login with password is allowed.')"
  return 0
}

# ============================================================================
# Section 12: XanMod kernel (abroad + KVM only)
# ============================================================================
install_xanmod() {
  (( OPT_XANMOD )) || return 2
  [[ $PKG == apt && $ARCH == x86_64 ]] || return 2
  local lvl pkgname flags
  flags=$(grep -m1 '^flags' /proc/cpuinfo)
  if [[ $flags == *avx2* && $flags == *bmi2* && $flags == *fma* && $flags == *movbe* ]]; then lvl=v3
  elif [[ $flags == *sse4_2* && $flags == *popcnt* && $flags == *ssse3* ]]; then lvl=v2
  else echo "CPU too old for XanMod x64v2"; return 1; fi
  pkgname="linux-xanmod-x64$lvl"
  pkg_install gnupg curl >/dev/null 2>&1
  mkdir -p /etc/apt/keyrings
  curl -fsSL --max-time 30 https://dl.xanmod.org/archive.key | gpg --dearmor --yes -o /etc/apt/keyrings/xanmod-archive-keyring.gpg || return 1
  echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" >"$XANMOD_LIST"
  if ! { apt-get update -q && apt-get install "${APT_OPTS[@]}" "$pkgname"; }; then
    # older repo layout used the distro codename
    echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org $OS_CODENAME main" >"$XANMOD_LIST"
    apt-get update -q && apt-get install "${APT_OPTS[@]}" "$pkgname" || { rm -f "$XANMOD_LIST"; apt-get update -q; return 1; }
  fi
  # BBR (v3 in XanMod) loads after reboot into the new kernel
  echo "tcp_bbr" >>"$MODULES_FILE"
  touch "$STATE_DIR/xanmod_installed"
}

# ============================================================================
# Section 13: status, ping tests, speed test, before/after snapshots
# ============================================================================

# "avg_ms/loss%" for a host
ping_stats() {
  local out avg loss
  out=$(ping -c 4 -W 2 -i 0.3 -q "$1" 2>/dev/null)
  loss=$(grep -oE '[0-9.]+% packet loss' <<<"$out" | cut -d% -f1)
  avg=$(awk -F'/' '/^(rtt|round-trip)/{printf "%.1f", $5}' <<<"$out")
  [[ -z $avg ]] && echo "timeout/100%" || echo "${avg}ms/${loss:-0}%"
}

current_dns() {
  if systemctl is-active --quiet systemd-resolved 2>/dev/null && command -v resolvectl >/dev/null; then
    resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 && $2!=""{print $2}' | tr '\n' ' ' | cut -c1-60
  else
    awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf
  fi
}

# Save a key=value snapshot (used for before/after comparison)
take_snapshot() {
  local f="$1" item
  {
    echo "date=$(date '+%F %T')"
    echo "tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo "rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null)"
    echo "swappiness=$(sysctl -n vm.swappiness 2>/dev/null)"
    echo "file_max=$(sysctl -n fs.file-max 2>/dev/null)"
    echo "mtu=$(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null)"
    echo "dns=$(current_dns)"
    for item in "${PING_TARGETS[@]}"; do echo "ping_${item%%|*}=$(ping_stats "${item#*|}")"; done
  } >"$f"
}

# Before/after table
show_comparison() {
  local b="$STATE_DIR/before.txt" a="$STATE_DIR/after.txt" k
  [[ -f $b && -f $a ]] || { info "$(t 'هنوز داده قبل/بعد ذخیره نشده.' 'No before/after data saved yet.')"; return; }
  title "$(t 'مقایسه قبل و بعد از بهینه‌سازی' 'Before vs After optimization')"
  printf "  ${W}%-18s %-32s %-32s${N}\n" "Key" "Before" "After"
  while IFS='=' read -r k _; do
    printf "  ${Y}%-18s${N} %-32s ${G}%-32s${N}\n" "$k" "$(grep "^$k=" "$b" | cut -d= -f2- | cut -c1-32)" "$(grep "^$k=" "$a" | cut -d= -f2- | cut -c1-32)"
  done <"$b"
}

# Speedtest (Iran: also Iranian servers)
run_speedtest() {
  if ! pkg_installed speedtest-cli; then
    info "$(t 'نصب speedtest-cli...' 'Installing speedtest-cli...')"
    pkg_install speedtest-cli >/dev/null 2>&1 || pip3 install -q speedtest-cli >/dev/null 2>&1
  fi
  pkg_installed speedtest-cli || { err "speedtest-cli $(t 'در دسترس نیست' 'not available')"; return 1; }
  info "$(t 'تست سرعت با نزدیک‌ترین سرور...' 'Speed test with the nearest server...')"
  timeout 120 speedtest-cli --secure --simple 2>&1 | sed 's/^/     /'
  local prof; prof=$(cat "$STATE_DIR/profile" 2>/dev/null)
  if [[ $prof == iran ]] || ask_yn "$(t 'سرورهای داخلی ایران هم تست شوند؟' 'Also test Iranian speedtest servers?')" n; then
    local ids id
    ids=$(timeout 60 speedtest-cli --secure --list 2>/dev/null | grep -iE 'iran|tehran|mashhad|tabriz|isfahan|shiraz' | head -3 | awk -F')' '{print $1}' | tr -d ' ')
    [[ -z $ids ]] && { warn "$(t 'سرور ایرانی پیدا نشد.' 'No Iranian server found.')"; return 0; }
    for id in $ids; do
      info "Server #$id"
      timeout 120 speedtest-cli --secure --simple --server "$id" 2>&1 | sed 's/^/     /'
    done
  fi
}

# Option 3
show_status() {
  title "$(t 'وضعیت فعلی سیستم' 'Current system status')"
  local thp gov swap
  thp=$(grep -oE '\[[a-z]+\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | tr -d '[]')
  gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "n/a (VM)")
  swap=$(swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr '\n' ' ')
  box_top
  box_line "TCP congestion" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  box_line "Default qdisc"  "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  box_line "NIC qdisc"      "$(tc qdisc show dev "$IFACE" 2>/dev/null | head -1 | awk '{print $2}')"
  box_line "Swappiness"     "$(sysctl -n vm.swappiness 2>/dev/null)"
  box_line "Swap"           "${swap:-none}"
  box_line "DNS"            "$(current_dns)"
  box_line "MTU ($IFACE)"   "$(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null)"
  box_line "CPU governor"   "$gov"
  box_line "THP"            "${thp:-n/a}"
  box_line "rmem_max"       "$(sysctl -n net.core.rmem_max 2>/dev/null)"
  box_line "file-max"       "$(sysctl -n fs.file-max 2>/dev/null)"
  box_line "Optimized"      "$(cat "$STATE_DIR/profile" 2>/dev/null || echo no)"
  box_bottom

  title "$(t 'تست پینگ' 'Ping test')"
  local item
  for item in "${PING_TARGETS[@]}"; do printf "  ${Y}%-14s${N} %-16s ${G}%s${N}\n" "${item%%|*}" "${item#*|}" "$(ping_stats "${item#*|}")"; done

  show_comparison
  if ask_yn "$(t 'تست سرعت (speedtest) اجرا شود؟' 'Run a speedtest now?')" y; then title "Speedtest"; run_speedtest; fi
}

# ============================================================================
# Section 14: rollback (option 4)
# ============================================================================
do_rollback() {
  title "$(t 'بازگردانی تنظیمات' 'Rollback')"
  local -a backups=(); local i choice dir
  mapfile -t backups < <(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sed 's#/$##' | sort -r)
  (( ${#backups[@]} )) || { warn "$(t 'هیچ بکاپی پیدا نشد.' 'No backups found.')"; return; }
  for i in "${!backups[@]}"; do
    printf "  ${G}[%d]${N} %s  ${D}%s${N}\n" "$((i+1))" "${backups[i]##*/}" "$(grep '^profile=' "${backups[i]}/info" 2>/dev/null)"
  done
  info "$(t 'قدیمی‌ترین بکاپ = وضعیت اولیه سرور' 'Oldest backup = original server state')"
  choice=$(ask_input "$(t 'شماره بکاپ' 'Backup number')" "${#backups[@]}")
  [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#backups[@]} )) || { err "$(t 'انتخاب نامعتبر' 'Invalid choice')"; return; }
  dir="${backups[choice-1]}"
  ask_yn "$(t "بازگردانی از $dir ؟ مطمئنی؟" "Restore from $dir? Are you sure?")" n || { info "$(t 'لغو شد' 'Cancelled')"; return; }
  run_step "$(t 'بازگردانی فایل‌ها و حذف تنظیمات MAXNET6G' 'Restore files & remove MAXNET6G settings')" rollback_worker "$dir"
  ok "$(t 'برای برگشت کامل مقادیر runtime (MTU، ethtool، BBR) ریبوت لازم است.' 'Reboot to fully revert runtime values (MTU, ethtool, BBR).')"
  ask_reboot
}

rollback_worker() {
  local dir="$1"
  chattr -i /etc/resolv.conf 2>/dev/null
  # remove disk swap / zram we created
  if [[ -f $STATE_DIR/swapfile_created ]]; then swapoff "$SWAPFILE" 2>/dev/null; rm -f "$SWAPFILE" "$STATE_DIR/swapfile_created"; fi
  if [[ -f $STATE_DIR/zram_enabled ]]; then systemctl disable --now zramswap 2>/dev/null; rm -f /etc/systemd/zram-generator.conf "$STATE_DIR/zram_enabled"; fi
  systemctl disable --now maxnet6g-boot.service 2>/dev/null
  # restore backed-up files
  [[ -e $dir/files/etc/resolv.conf || -L $dir/files/etc/resolv.conf ]] && rm -f /etc/resolv.conf
  cp -a "$dir/files/." / || return 1
  [[ -f /etc/apt/sources.list.d/debian.sources.maxnet6g-disabled ]] && mv /etc/apt/sources.list.d/debian.sources.maxnet6g-disabled /etc/apt/sources.list.d/debian.sources
  # remove every file MAXNET6G creates
  rm -f "$SYSCTL_FILE" "$LIMITS_FILE" "$SYSTEMD_SYS_CONF" "$SYSTEMD_USER_CONF" "$JOURNALD_CONF" "$RESOLVED_CONF" \
        "$UDEV_IO_RULE" "$MODULES_FILE" "$MODPROBE_FILE" "$BOOT_SCRIPT" "$BOOT_SERVICE" "$XANMOD_LIST" \
        /etc/chrony/sources.d/maxnet6g.sources
  sed -i '/added by MAXNET6G/d' /etc/pam.d/common-session /etc/chrony/chrony.conf /etc/chrony.conf 2>/dev/null
  systemctl daemon-reload; systemctl daemon-reexec
  sysctl --system
  systemctl is-active --quiet systemd-resolved && systemctl restart systemd-resolved
  systemctl restart systemd-journald
  udevadm control --reload-rules 2>/dev/null
  [[ $PKG == apt ]] && apt-get update -q
  rm -f "$STATE_DIR/profile" "$STATE_DIR/after.txt"
  return 0
}

# ============================================================================
# Section 15: questions asked up front + the optimization pipeline
# ============================================================================
ask_questions() {
  title "$(t 'تنظیمات قبل از شروع' 'Pre-flight questions')"
  ask_dns_choice

  local def_tz; [[ $PROFILE == iran ]] && def_tz="Asia/Tehran" || def_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)
  OPT_TIMEZONE=$(ask_input "$(t 'منطقه زمانی' 'Timezone')" "$def_tz")
  if command -v timedatectl >/dev/null && ! timedatectl list-timezones 2>/dev/null | grep -qx "$OPT_TIMEZONE"; then
    warn "$(t 'منطقه زمانی نامعتبر؛ تغییر نمی‌کند.' 'Invalid timezone; it will not change.')"; OPT_TIMEZONE=""
  fi

  find_unneeded_services
  if (( ${#SERVICES_TO_DISABLE[@]} )); then
    info "$(t 'سرویس‌های غیرضروری:' 'Unneeded services:') ${SERVICES_TO_DISABLE[*]}"
    ask_yn "$(t 'این سرویس‌ها غیرفعال شوند؟' 'Disable these services?')" n && OPT_DISABLE_SERVICES=1
  fi

  ask_yn "$(t 'فعال‌سازی IP Forwarding (لازم برای VPN/تانل)؟' 'Enable IP forwarding (needed for VPN/tunnels)?')" y && OPT_IP_FORWARD=1

  printf "\n  ${W}%s${N}\n" "$(t 'پروفایل tuned:' 'tuned profile:')"
  printf "     ${G}[1]${N} %s\n" "$(t 'دانلود/استریم/VPN (throughput-performance)' 'Download/stream/VPN (throughput-performance)')"
  printf "     ${G}[2]${N} %s\n" "$(t 'گیمینگ/کمترین تأخیر (network-latency)' 'Gaming/lowest latency (network-latency)')"
  [[ $(ask_input "$(t 'انتخاب' 'Choice')" "1") == 2 ]] && OPT_TUNED_PROFILE="network-latency" || OPT_TUNED_PROFILE="throughput-performance"

  if (( ! IS_CONTAINER )); then
    if ! swapon --show --noheadings 2>/dev/null | grep -q .; then
      printf "\n  ${W}%s${N}\n" "$(t 'سرور swap ندارد:' 'No swap found:')"
      printf "     ${G}[1]${N} swapfile   ${G}[2]${N} zram (%s)   ${G}[3]${N} %s\n" "$(t 'فشرده در رم' 'compressed RAM')" "$(t 'هیچکدام' 'none')"
      case $(ask_input "$(t 'انتخاب' 'Choice')" "1") in 1) OPT_SWAP_MODE=file ;; 2) OPT_SWAP_MODE=zram ;; *) OPT_SWAP_MODE=skip ;; esac
    else
      ask_yn "$(t 'swap وجود دارد. zram هم اضافه شود؟' 'Swap exists. Add zram as well?')" n && OPT_SWAP_MODE=zram
    fi
    ask_yn "$(t 'افزودن noatime به fstab (با بکاپ و تست)؟' 'Add noatime to fstab (backed up & verified)?')" y && OPT_NOATIME=1
  fi

  ask_yn "$(t 'نصب fail2ban برای محافظت SSH؟' 'Install fail2ban to protect SSH?')" y && OPT_FAIL2BAN=1
  ask_yn "$(t 'پاک‌سازی کش رم در پایان؟' 'Drop RAM caches at the end?')" n && OPT_DROP_CACHES=1

  if [[ $PROFILE == abroad && $PKG == apt && $ARCH == x86_64 ]]; then
    if [[ $VIRT == kvm || $VIRT == qemu ]]; then
      ask_yn "$(t 'نصب کرنل XanMod برای BBRv3؟ (نیاز به ریبوت)' 'Install XanMod kernel for BBRv3? (needs reboot)')" n && OPT_XANMOD=1
    else
      info "$(t "XanMod فقط روی KVM پیشنهاد می‌شود (فعلی: $VIRT)." "XanMod is offered only on KVM (this is $VIRT).")"
    fi
  fi
}

# Steps shared by both profiles (section 5)
common_optimizations() {
  title "$(t '۵.۱ نرم‌افزار' '5.1 Software')"
  run_step "$(t 'آپدیت کامل سیستم' 'Full system update')" system_update
  run_step "$(t 'نصب ابزارهای ضروری' 'Install essential tools')" install_essentials
  [[ -s $STATE_DIR/failed_pkgs ]] && warn "$(t 'نصب نشد:' 'Not installed:') $(tr '\n' ' ' <"$STATE_DIR/failed_pkgs")"
  run_step "$(t 'همگام‌سازی زمان با chrony' 'Time sync with chrony')" setup_chrony
  run_step "$(t 'تنظیم منطقه زمانی' 'Set timezone') ${OPT_TIMEZONE}" set_timezone
  run_step "$(t 'غیرفعال‌سازی سرویس‌های غیرضروری' 'Disable unneeded services')" disable_services

  title "$(t '۵.۲-۵.۴ شبکه، گیمینگ، استریم' '5.2-5.4 Network, gaming, streaming')"
  prepare_bbr
  run_step "$(t 'اعمال sysctl (BBR، بافرها، conntrack، keepalive، امنیت)' 'Apply sysctl (BBR, buffers, conntrack, keepalive, security)')" write_sysctl
  run_step "$(t 'کارت شبکه: ring buffer، offload، RPS/RFS، fq، THP، governor' 'NIC: ring buffer, offloads, RPS/RFS, fq, THP, governor')" setup_boot_tuning

  title "$(t '۵.۵-۵.۷ رم، CPU، محدودیت‌ها' '5.5-5.7 RAM, CPU, limits')"
  run_step "$(t 'swap / zram' 'swap / zram')" setup_swap
  run_step "$(t 'فعال‌سازی irqbalance' 'Enable irqbalance')" setup_irqbalance
  run_step "$(t 'پروفایل tuned:' 'tuned profile:') $OPT_TUNED_PROFILE" setup_tuned
  run_step "$(t 'افزایش nofile/nproc و محدودیت‌های systemd' 'Raise nofile/nproc & systemd limits')" set_limits

  title "$(t '۵.۸ دیسک' '5.8 Disk')"
  run_step "$(t 'زمان‌بند I/O مناسب SSD/NVMe' 'I/O scheduler for SSD/NVMe')" setup_io_scheduler
  run_step "$(t 'افزودن noatime به fstab' 'Add noatime to fstab')" setup_noatime
  run_step "$(t 'فعال‌سازی fstrim.timer' 'Enable fstrim.timer')" setup_fstrim
  run_step "$(t 'محدود کردن journald به 100M' 'Limit journald to 100M')" setup_journald

  title "$(t '۵.۹ امنیت پایه' '5.9 Basic security')"
  run_step "$(t 'نصب و تنظیم fail2ban' 'Install & configure fail2ban')" setup_fail2ban
  check_ssh_security
}

# Full pipeline for option 1 (iran) / option 2 (abroad)
optimize() {
  PROFILE="$1"
  SUMMARY_OK=(); SUMMARY_FAIL=(); SUMMARY_SKIP=()
  TARGET_MTU=""; SELECTED_MIRROR=""; DNS_SERVERS=""; DNS_NAME=""
  check_environment
  ask_questions

  title "$(t 'بکاپ و اندازه‌گیری اولیه' 'Backup & baseline')"
  run_step "$(t 'بکاپ تنظیمات در' 'Backup configs to') $BACKUP_ROOT" backup_configs || { err "$(t 'بکاپ ناموفق بود؛ برای امنیت ادامه نمی‌دهیم.' 'Backup failed; aborting for safety.')"; return 1; }
  ok "$(t 'محل بکاپ:' 'Backup:') $BACKUP_DIR"
  [[ -f $STATE_DIR/before.txt ]] || run_step "$(t 'ذخیره وضعیت قبل (پینگ و تنظیمات)' 'Save BEFORE snapshot (ping & settings)')" take_snapshot "$STATE_DIR/before.txt"

  if [[ $PROFILE == iran ]]; then
    title "$(t '🇮🇷 بهینه‌سازی مخصوص ایران' '🇮🇷 Iran-specific tuning')"
  else
    title "$(t '🌍 بهینه‌سازی مخصوص سرور خارج' '🌍 Abroad-specific tuning')"
  fi
  select_fastest_mirror && run_step "$(t 'تغییر مخزن به' 'Switch repositories to') $SELECTED_MIRROR" apply_mirror
  resolve_dns_choice && run_step "$(t 'تنظیم DNS' 'Configure DNS') ($DNS_NAME)" apply_dns
  [[ $PROFILE == iran ]] && detect_best_mtu

  common_optimizations

  if [[ $PROFILE == abroad ]]; then
    title "$(t 'کرنل' 'Kernel')"
    run_step "$(t 'نصب کرنل XanMod (BBRv3)' 'Install XanMod kernel (BBRv3)')" install_xanmod
  fi
  run_step "$(t 'پاک‌سازی کش رم' 'Drop RAM caches')" drop_caches

  echo "$PROFILE" >"$STATE_DIR/profile"
  run_step "$(t 'ذخیره وضعیت بعد' 'Save AFTER snapshot')" take_snapshot "$STATE_DIR/after.txt"
  show_summary
  show_comparison
  ask_reboot
}

# Colored summary of everything applied
show_summary() {
  local s
  printf "\n${G}╔══════════════════════════════════════════════════════════════════${N}\n"
  printf "${G}║${N}  ${W}%s${N}  ${D}(%s)${N}\n" "$(t 'خلاصه تغییرات' 'SUMMARY')" "$PROFILE"
  printf "${G}╠══════════════════════════════════════════════════════════════════${N}\n"
  for s in "${SUMMARY_OK[@]}";   do printf "${G}║${N}  ${G}✔${N} %s\n" "$s"; done
  for s in "${SUMMARY_SKIP[@]}"; do printf "${G}║${N}  ${Y}⊘${N} %s\n" "$s"; done
  for s in "${SUMMARY_FAIL[@]}"; do printf "${G}║${N}  ${R}✘${N} %s\n" "$s"; done
  printf "${G}╠══════════════════════════════════════════════════════════════════${N}\n"
  printf "${G}║${N}  ${G}%d %s${N}  ${Y}%d %s${N}  ${R}%d %s${N}\n" "${#SUMMARY_OK[@]}" "$(t 'موفق' 'ok')" "${#SUMMARY_SKIP[@]}" "$(t 'رد شده' 'skipped')" "${#SUMMARY_FAIL[@]}" "$(t 'ناموفق' 'failed')"
  printf "${G}║${N}  ${D}TCP: %s | qdisc: %s | DNS: %s${N}\n" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "$(sysctl -n net.core.default_qdisc 2>/dev/null)" "$(current_dns)"
  printf "${G}║${N}  ${D}Log: %s | Backup: %s${N}\n" "$LOG_FILE" "$BACKUP_DIR"
  printf "${G}╚══════════════════════════════════════════════════════════════════${N}\n"
}

ask_reboot() {
  if ask_yn "$(t 'سرور الان ریبوت شود؟' 'Reboot the server now?')" n; then
    log "Reboot requested by user"; info "$(t 'ریبوت تا ۵ ثانیه دیگر...' 'Rebooting in 5 seconds...')"; sleep 5; reboot
  fi
}

# ============================================================================
# Section 16: entry point
# ============================================================================
usage() {
  cat <<EOF
MAXNET6G v$VERSION - Ultimate Server Optimizer
Usage: $0 [options]
  --iran        optimize as an Iran server
  --abroad      optimize as a foreign server
  --status      show status & speed test
  --rollback    restore from backup
  --yes, -y     accept default answers (unattended)
  --lang fa|en  UI language
  --help        this help
EOF
}

parse_args() {
  while (( $# )); do
    case $1 in
      --iran) CLI_ACTION=iran ;; --abroad) CLI_ACTION=abroad ;;
      --status) CLI_ACTION=status ;; --rollback) CLI_ACTION=rollback ;;
      -y|--yes) AUTO_YES=1 ;;
      --lang) shift; UI_LANG="$1" ;;
      -h|--help) usage; exit 0 ;;
      -v|--version) echo "$VERSION"; exit 0 ;;
      *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
  done
  [[ $UI_LANG == fa || $UI_LANG == en || -z $UI_LANG ]] || UI_LANG=en
}

pause() { (( AUTO_YES )) || read_tty "  $(t 'برای ادامه Enter بزنید...' 'Press Enter to continue...')" >/dev/null; }

main() {
  parse_args "$@"
  check_root
  detect_system
  show_banner
  choose_language
  case $CLI_ACTION in
    iran|abroad) show_sysinfo; optimize "$CLI_ACTION"; exit 0 ;;
    status) show_status; exit 0 ;;
    rollback) do_rollback; exit 0 ;;
  esac
  while true; do
    show_banner
    show_sysinfo
    show_menu
    case $(read_tty "  $(t 'گزینه را انتخاب کنید' 'Select an option') > ") in
      1) optimize iran; pause ;;
      2) optimize abroad; pause ;;
      3) show_status; pause ;;
      4) do_rollback; pause ;;
      0|q|Q) echo; ok "$(t 'خدانگهدار!' 'Bye!')"; log "exit"; exit 0 ;;
      *) warn "$(t 'گزینه نامعتبر' 'Invalid option')"; sleep 1 ;;
    esac
  done
}

main "$@"
