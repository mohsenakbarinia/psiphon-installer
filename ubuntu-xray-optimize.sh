#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Safe Ubuntu/Xray optimizer. Conservative by design: it never changes SSH ports,
# firewall policy, panel/Xray configs, kernels, or inbounds automatically.
NAME="ubuntu-xray-optimize"
VERSION="1.0.0"
BASE=/root/backup-optimize
STATE=/var/lib/ubuntu-xray-optimize
LOG=/var/log/optimize.log
CONF=/etc/sysctl.d/99-ubuntu-xray-optimize.conf
LIMITS=/etc/security/limits.d/99-ubuntu-xray-optimize.conf
SYSTEMD_DIR=/etc/systemd/system
WATCHDOG="$SYSTEMD_DIR/xray-resource-watchdog.service"
WATCHDOG_TIMER="$SYSTEMD_DIR/xray-resource-watchdog.timer"
BACKUP_DIR=""
DRY_RUN=0
ASSUME_YES=0
MODE="full"
ROLLBACK_ID=""
NO_IPV6=0

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
exec > >(tee -a "$LOG") 2>&1

C_RESET='\033[0m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[34m'
log(){ printf '%b[%s] %s%b\n' "$C_BLUE" "$(date '+%F %T')" "$*" "$C_RESET"; }
ok(){ printf '%b[OK] %s%b\n' "$C_GREEN" "$*" "$C_RESET"; }
warn(){ printf '%b[WARN] %s%b\n' "$C_YELLOW" "$*" "$C_RESET"; }
die(){ printf '%b[ERROR] %s%b\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
run(){ if (( DRY_RUN )); then log "DRY-RUN: $*"; else "$@"; fi; }
write_file(){ local f="$1"; shift; if (( DRY_RUN )); then log "DRY-RUN: write $f"; else install -d -m 0755 "$(dirname "$f")"; printf '%s\n' "$*" > "$f"; fi; }

usage(){ cat <<EOF
$NAME $VERSION
Usage: sudo bash $0 [--dry-run] [--yes] [--rollback [ID]] [--status] [--no-ipv6]

No option starts an interactive menu. --yes accepts safe changes, but never enables
optional service disabling, SSH-port changes, kernel installs, or Xray replacement.
EOF
}

root_check(){ (( EUID == 0 )) || die "Run as root: sudo bash $0"; command -v systemctl >/dev/null || die "systemd is required"; }
os_check(){ [[ -r /etc/os-release ]] || die "Cannot identify the operating system"; . /etc/os-release; [[ ${ID:-} == ubuntu ]] || die "Ubuntu is required (detected ${PRETTY_NAME:-unknown})"; }
init_info(){
  ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
  KERNEL=$(uname -r); VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
  log "Ubuntu ${VERSION_ID:-unknown}, arch=$ARCH, kernel=$KERNEL, virt=$VIRT, init=$(ps -p 1 -o comm=)"
  if [[ ${VERSION_ID:-0} < 18.04 ]]; then warn "Ubuntu older than 18.04 is unsupported"; fi
}
confirm(){ local q="$1"; (( ASSUME_YES )) && return 0; read -r -p "$q [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
latest_backup(){ ls -1dt "$BASE"/* 2>/dev/null | head -1 || true; }

backup(){
  BACKUP_DIR="$BASE/$(date +%Y%m%d-%H%M%S)"
  run mkdir -p "$BACKUP_DIR"
  local files=(/etc/sysctl.conf /etc/security/limits.conf /etc/resolv.conf /etc/fstab /etc/hosts /etc/hostname /etc/netplan /etc/network/interfaces /etc/network/interfaces.d /etc/ufw /etc/nftables.conf /etc/iptables/rules.v4 /etc/iptables/rules.v6 /etc/systemd/resolved.conf /etc/systemd/system /etc/default/irqbalance)
  for f in "${files[@]}"; do [[ -e "$f" || -L "$f" ]] && { run cp -a --parents "$f" "$BACKUP_DIR" 2>/dev/null || true; }; done
  run sh -c 'sysctl -a 2>/dev/null > "$1/sysctl.before"' sh "$BACKUP_DIR"
  run sh -c 'ip addr > "$1/ip.addr.before"; ip route > "$1/ip.route.before"; ss -lntup > "$1/listening.before"' sh "$BACKUP_DIR"
  run sh -c 'command -v nft >/dev/null && nft list ruleset > "$1/nft.before" || true' sh "$BACKUP_DIR"
  run sh -c 'command -v iptables-save >/dev/null && iptables-save > "$1/iptables.before" || true' sh "$BACKUP_DIR"
  local found=0
  for p in /etc/x-ui /usr/local/x-ui /opt/3x-ui /etc/3x-ui /root/3x-ui; do if [[ -d "$p" ]]; then run cp -a "$p" "$BACKUP_DIR/"; found=1; fi; done
  while IFS= read -r p; do [[ -f "$p" ]] && { run cp -a --parents "$p" "$BACKUP_DIR"; found=1; }; done < <(find / -xdev -type f \( -name x-ui.db -o -name config.json \) 2>/dev/null | head -100)
  (( found )) || warn "No common panel/Xray directory found; configs were not located automatically"
  write_file "$BACKUP_DIR/manifest" "created=$(date -Is)\nversion=$VERSION\nubuntu=${VERSION_ID:-unknown}\narch=$ARCH\nkernel=$KERNEL\nvirt=$VIRT"
  [[ -e "$STATE/last-backup" ]] || run mkdir -p "$STATE"
  write_file "$STATE/last-backup" "$BACKUP_DIR"
  ok "Backup: $BACKUP_DIR"
}

wait_apt(){
  local i=0
  while pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null; do
    ((i++)); (( i > 120 )) && { warn "Package manager stayed locked for 10 minutes; skipping packages"; return 1; }
    sleep 5
  done
  return 0
}
apt_install(){ wait_apt || return 0; export DEBIAN_FRONTEND=noninteractive; run apt-get update -o Acquire::Retries=3 || warn "apt update failed; continuing"; run apt-get install -y --no-install-recommends "$@" || warn "Could not install: $*"; }

sysctl_apply(){
  local ram_kb; ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo); local conn=$(( ram_kb / 8 )); (( conn < 16384 )) && conn=16384; (( conn > 262144 )) && conn=262144
  local lowat=16384; (( ram_kb < 1048576 )) && lowat=8192
  local data="net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\nnet.ipv4.tcp_fastopen=3\nnet.ipv4.tcp_slow_start_after_idle=0\nnet.ipv4.tcp_mtu_probing=1\nnet.ipv4.tcp_tw_reuse=1\nnet.ipv4.tcp_notsent_lowat=$lowat\nnet.ipv4.tcp_rmem=4096 131072 16777216\nnet.ipv4.tcp_wmem=4096 16384 16777216\nnet.core.rmem_max=16777216\nnet.core.wmem_max=16777216\nnet.core.netdev_max_backlog=16384\nnet.core.somaxconn=4096\nnet.ipv4.ip_local_port_range=10240 65535\nnet.netfilter.nf_conntrack_max=$conn\nvm.swappiness=15\nvm.vfs_cache_pressure=100"
  if [[ "$NO_IPV6" == 1 ]]; then data+="\nnet.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1"; fi
  write_file "$CONF" "$data"
  (( DRY_RUN )) || { sysctl --system >/dev/null 2>&1 || warn "Some sysctl values were unsupported and were skipped"; }
  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] && grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then ok "BBR available and enabled"; else warn "BBR unavailable on this kernel; leaving congestion control unchanged"; fi
  if [[ -r /proc/sys/net/core/default_qdisc ]] && [[ $(cat /proc/sys/net/core/default_qdisc 2>/dev/null) == fq ]]; then ok "fq qdisc enabled"; else warn "fq qdisc unavailable; cake was not forced"; fi
}

limits_apply(){
  write_file "$LIMITS" '* soft nofile 262144\n* hard nofile 262144\n* soft nproc 65536\n* hard nproc 65536\nroot soft nofile 262144\nroot hard nofile 262144'
  local d="$SYSTEMD_DIR/xray-resource-limits.conf"
  write_file "$d" '[Service]\nLimitNOFILE=262144\nLimitNPROC=65536'
  ok "nofile/nproc limits prepared for new sessions and Xray override"
}

dns_apply(){
  if systemctl is-active --quiet systemd-resolved 2>/dev/null && command -v resolvectl >/dev/null; then
    run resolvectl dns "$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')" 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 || true
    run resolvectl flush-caches || true
    ok "DNS set through systemd-resolved; existing resolv.conf was preserved"
  else
    warn "systemd-resolved is not active; preserving resolv.conf to avoid breaking panel/Xray"
  fi
}

nic_apply(){
  local nic; nic=$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')
  [[ -n "$nic" ]] || { warn "Default NIC not found"; return; }
  command -v ethtool >/dev/null || apt_install ethtool
  if command -v ethtool >/dev/null; then
    for feat in tso gso gro; do run ethtool -K "$nic" "$feat" on 2>/dev/null || true; done
    run ip link set dev "$nic" txqueuelen 1000 2>/dev/null || true
    ok "Safe NIC offloads enabled where supported on $nic"
  fi
}

swap_apply(){
  [[ -e /swapfile || -n "$(swapon --show --noheadings 2>/dev/null)" ]] && { ok "Existing swap preserved"; return; }
  local ram_mb; ram_mb=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo); local size=$((ram_mb/2)); (( size < 512 )) && size=512; (( size > 4096 )) && size=4096
  confirm "Create a ${size} MB /swapfile?" || { warn "Swap creation skipped"; return; }
  run fallocate -l "${size}M" /swapfile || run dd if=/dev/zero of=/swapfile bs=1M count="$size" status=none
  run chmod 600 /swapfile; run mkswap /swapfile; run swapon /swapfile
  grep -qE '^/swapfile[[:space:]]' /etc/fstab || { (( DRY_RUN )) || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab; }
  ok "Swap configured"
}

services_apply(){
  apt_install irqbalance fail2ban curl ca-certificates
  systemctl enable --now irqbalance 2>/dev/null || warn "irqbalance unavailable or not permitted"
  systemctl enable --now fail2ban 2>/dev/null || warn "fail2ban unavailable; no firewall policy was changed"
}

watchdog_apply(){
  local script=/usr/local/sbin/xray-resource-watchdog
  write_file "$script" '#!/usr/bin/env bash
set -u
SERVICE=""
for s in xray x-ui 3x-ui; do systemctl cat "$s" >/dev/null 2>&1 && { SERVICE="$s"; break; }; done
[[ -n "$SERVICE" ]] || exit 0
state=/run/xray-resource-watchdog
mkdir -p "$state"
now=$(date +%s); lock="$state/last-restart"; count="$state/count"
pid=$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || echo 0)
[[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || exit 0
rss=$(awk "/^VmRSS:/{print \$2}" "/proc/$pid/status" 2>/dev/null || echo 0)
ram=$(awk "/MemTotal/{print \$2}" /proc/meminfo)
max=$((ram/2)); (( max < 262144 )) && max=262144
if (( rss > max )); then
  last=$(cat "$lock" 2>/dev/null || echo 0); n=$(cat "$count" 2>/dev/null || echo 0)
  (( now-last < 3600 )) && exit 0; (( n >= 3 )) && exit 0
  systemctl restart "$SERVICE"; echo "$now" > "$lock"; echo $((n+1)) > "$count"
fi'
  run chmod 0755 /usr/local/sbin/xray-resource-watchdog
  write_file "$WATCHDOG" '[Unit]\nDescription=Conservative Xray memory watchdog\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/xray-resource-watchdog'
  write_file "$WATCHDOG_TIMER" '[Unit]\nDescription=Run Xray memory watchdog\n[Timer]\nOnBootSec=10min\nOnUnitActiveSec=5min\nRandomizedDelaySec=60\n[Install]\nWantedBy=timers.target'
  run systemctl daemon-reload; run systemctl enable --now xray-resource-watchdog.timer
  ok "Watchdog installed with a 3 restarts/hour guard"
}

cleanup(){
  confirm "Clean apt cache, old journals, and temporary files?" || { warn "Cleanup skipped"; return; }
  run journalctl --vacuum-time=14d || true
  run apt-get clean || true
  run find /tmp -xdev -type f -mtime +7 -delete 2>/dev/null || true
  mkdir -p /etc/systemd/journald.conf.d
  write_file /etc/systemd/journald.conf.d/99-resource-limits.conf '[Journal]\nSystemMaxUse=200M\nRuntimeMaxUse=100M\nMaxRetentionSec=14day'
  run systemctl restart systemd-journald || true
  ok "Conservative cleanup complete"
}

report(){
  echo; log "STATUS REPORT"
  free -h; uptime; echo "Processes: $(ps -e --no-headers 2>/dev/null | wc -l)"
  echo "BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unavailable)"
  echo "Qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unavailable)"
  echo "DNS: $(resolvectl status 2>/dev/null | awk '/DNS Servers/{print; exit}' || grep -E '^(nameserver|search)' /etc/resolv.conf 2>/dev/null || true)"
  for host in instagram.com google.com youtube.com; do printf '%-15s ' "$host"; curl -4IsS --connect-timeout 5 --max-time 8 "https://$host" >/dev/null 2>&1 && echo reachable || echo failed; done
  systemctl --no-pager --type=service --state=running 2>/dev/null | sed -n '1,12p'
}

rollback(){
  [[ -n "$ROLLBACK_ID" ]] || ROLLBACK_ID=$(latest_backup)
  [[ -d "$ROLLBACK_ID" ]] || die "No backup found"
  confirm "Rollback from $ROLLBACK_ID?" || exit 0
  run rm -f "$CONF" "$LIMITS" "$SYSTEMD_DIR/xray-resource-limits.conf" "$WATCHDOG" "$WATCHDOG_TIMER" /usr/local/sbin/xray-resource-watchdog
  run systemctl disable --now xray-resource-watchdog.timer 2>/dev/null || true
  run systemctl daemon-reload
  for root in etc; do [[ -d "$ROLLBACK_ID/$root" ]] && run cp -a "$ROLLBACK_ID/$root/." /; done
  (( DRY_RUN )) || sysctl --system >/dev/null 2>&1 || true
  ok "Rollback restored backed-up files; reboot if a kernel/network service still has old state"
}

status(){ report; echo "Last backup: $(cat "$STATE/last-backup" 2>/dev/null || echo none)"; echo "Config: $CONF"; }

network(){ sysctl_apply; dns_apply; nic_apply; }
full(){ backup; network; limits_apply; swap_apply; services_apply; watchdog_apply; cleanup; report; }
menu(){
  cat <<'EOF'
1) Full safe install
2) Network only
3) DNS only
4) RAM/CPU cleanup
5) Monitoring/watchdog + backup foundation
6) Rollback latest
7) Show status
0) Exit
EOF
  read -r -p 'Choose: ' c
  case "$c" in 1) full;; 2) backup; network;; 3) backup; dns_apply;; 4) backup; cleanup; swap_apply;; 5) backup; services_apply; watchdog_apply;; 6) rollback;; 7) status;; 0) exit 0;; *) die 'Invalid choice';; esac
}

while (($#)); do case "$1" in
  --dry-run) DRY_RUN=1;; --yes) ASSUME_YES=1;; --no-ipv6) NO_IPV6=1;; --status) MODE=status;; --rollback) MODE=rollback; [[ ${2:-} != --* && -n ${2:-} ]] && { ROLLBACK_ID="$2"; shift; };; -h|--help) usage; exit 0;; *) die "Unknown option: $1";; esac; shift; done
root_check; os_check; init_info
case "$MODE" in status) status;; rollback) backup >/dev/null 2>&1 || true; rollback;; full) menu;; esac
