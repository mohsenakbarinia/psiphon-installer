#!/usr/bin/env bash
# Safe Net 1.0 — complete single-file program. No downloaded code.
# Requires Linux, Bash, readlink, Python >=3.9 (standard library only).
# No dependency installation, package update, deletion or service restart.
#
# USAGE:
#   bash install.sh --help
#   bash install.sh                         # Iran/outside menu; diagnosis
#   bash install.sh --dry-run --profile iran
#   bash install.sh --diagnose
#   sudo bash install.sh --install          # copies THIS file, no network changes
#   sudo /usr/local/sbin/safe-net
#   sudo /usr/local/sbin/safe-net --status
#   sudo /usr/local/sbin/safe-net --profile outside --tcp-bbr
#   sudo /usr/local/sbin/safe-net --confirm ID [--persist]
#   sudo /usr/local/sbin/safe-net --rollback
#
# Inspect ALL code and verify an independently trusted SHA256 before sudo.
# For GitHub downloads pin a reviewed full commit; do not use curl|bash.
# --install refuses to overwrite another version/launcher; no automatic upgrade.
# Installed file: /usr/local/lib/safe-net/<SHA256>/install.sh; launcher is a symlink.
# Root normal runs may create private reports under /var/lib/safe-net.
# --dry-run/--status/--diagnose do not create reports, locks or settings.
# --probe NUMERIC_IPV4 explicitly permits 5 ping packets to an authorized target.
# dry-run never probes. No DNS-based probes or bandwidth tests are performed.
#
# DEFAULT: preserve network settings. Geography alone cannot justify sysctl tuning.
# Optional --tcp-bbr permits a trial, not a claim of proven improvement.
# Mutation policy: Debian 12/13, Ubuntu 22.04/24.04; root, working systemd,
# known non-container host, one IPv4 default interface, existing root fq,
# already available BBR and sufficient available memory. No kernel/module install.
# This policy does NOT mean these distributions have been integration-tested.
# BBR affects default local TCP for IPv4 AND IPv6, not forwarded TCP or UDP/QUIC.
# IPv6, MTU/MSS, buffers, DNS, SSH, firewall, routing and VPN configs are preserved.
# IPv4-only is NOT enforced. Neither connectivity nor speed is guaranteed.
#
# TIMER: independent systemd rollback is armed before runtime changes. Confirm
# within 180 seconds of creation ONLY after independent SSH/application and
# controlled performance checks. A freeze/systemd failure can delay/prevent it;
# keep a provider console and snapshot. Unconfirmed changes are runtime-only.
# Confirmation is journaled BEFORE optional persistence creation: if interrupted,
# runtime may be confirmed but persistence absent; inspect status and rollback.
# Persistent config: exclusively created /etc/sysctl.d/90-safe-net.conf.
# Rollback archives unmodified owned config as .disabled (does not delete it),
# restores runtime only if matching the tool's value, and preserves conflicts.
# Same-value external writes and simultaneous external tuners cannot be reliably
# detected: Linux sysctl has no compare-and-swap/provenance API. Do not run other
# tuners concurrently. flock serializes only this tool. Backups are NOT data backups.
# Logs/reports: /var/lib/safe-net, root-only. Review before sharing.
# No reports transmitted. No private keys, passwords or process command lines read.
#
# Before production: test on a disposable authorized VPS with a recovery console.
# bash -n checks Bash syntax only; embedded Python needs separate compile/tests.
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077
command -v python3 >/dev/null 2>&1 || {
    printf '%s\n' 'خطا: Python 3.9+ لازم است؛ هیچ بسته‌ای نصب نمی‌شود.' >&2
    exit 1
}
command -v readlink >/dev/null 2>&1 || {
    printf '%s\n' 'خطا: readlink موجود نیست؛ توقف بدون تغییر.' >&2
    exit 1
}
SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
exec python3 -I - "$SELF" "$@" <<'SAFE_NET_PYTHON'
#!/usr/bin/env python3
"""Safe Net 1.0: conservative diagnostics and guarded, opt-in TCP BBR trials.
No third-party imports. No arbitrary sysctl keys or shell evaluation.
"""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid

VERSION = "1.0.0"
SCRIPT = Path(__file__).resolve()
KEY = "net.ipv4.tcp_congestion_control"
STATE = Path("/var/lib/safe-net")
CONFIG = Path("/etc/sysctl.d/90-safe-net.conf")
GUARD_SECONDS = 180
SUPPORTED = {("debian", "12"), ("debian", "13"),
             ("ubuntu", "22.04"), ("ubuntu", "24.04")}
PROFILES = {
    "iran": "اولویت: پایداری و تأخیر؛ مسیر کاربر تا ایران و هر تونل خروجی جدا سنجیده شود.",
    "outside": "اولویت: توان عملیاتی پایدار؛ مسیر ورودی و خروجی و هزینه رمزنگاری جدا سنجیده شود.",
}
KNOWN_SERVICES = {"sshd", "openvpn", "xray", "sing-box", "v2ray", "hysteria",
                  "trojan", "charon", "tailscaled", "headscale", "ss-server",
                  "ocserv", "wireguard-go", "naive", "tuic-server", "docker",
                  "containerd", "podman"}


class SafeError(Exception):
    pass


def text(path, default="unknown"):
    try:
        return Path(path).read_text().strip()
    except (OSError, UnicodeError):
        return default


def run(argv, timeout=8):
    """Never run a shell, and never include raw command output in an error."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"})
        return p.returncode, p.stdout.strip()
    except (OSError, subprocess.TimeoutExpired, UnicodeError):
        return 127, ""


def json_command(argv):
    rc, output = run(argv)
    try:
        value = json.loads(output) if rc == 0 else []
        return value if isinstance(value, list) else []
    except ValueError:
        return []


def os_release():
    result = {}
    for line in text("/etc/os-release", "").splitlines():
        match = re.fullmatch(r'([A-Z_]+)=(.*)', line)
        if match:
            result[match[1]] = match[2].strip('\"\'')
    return result


def sysread(key):
    return text("/proc/sys/" + key.replace(".", "/"))


def secure_dir(path, create=False):
    """Root-owned, non-symlink, non-group/world-writable ancestors only."""
    path = Path(path)
    for part in list(reversed(path.parents)) + [path]:
        if not part.exists() and not part.is_symlink() and create:
            part.mkdir(mode=0o700)
        st = part.lstat()
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
            raise SafeError("مسیر مدیریتی ناامن است؛ هیچ تغییری اعمال نمی‌شود.")


def secure_file(path):
    path = Path(path)
    secure_dir(path.parent)
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
        raise SafeError("فایل اجرایی/وضعیت باید معمولی، متعلق به root و غیرقابل نوشتن برای دیگران باشد.")


def write_new(path, data, mode=0o600):
    """Exclusive create, never truncate an existing file; fsync before proceeding."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "w") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    fsync_dir(Path(path).parent)


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def limits():
    result = {"cgroup_v1": False, "memory_max_bytes": [], "cpu_quotas": []}
    entries = text("/proc/self/cgroup", "").splitlines()
    v2 = next((line[3:] for line in entries if line.startswith("0::")), None)
    if v2 is None:
        result["cgroup_v1"] = bool(entries)
        result["note"] = "v1/host ancestor limits unknown; host tuning blocked in containers"
        return result
    base = Path("/sys/fs/cgroup")
    relative = Path(v2.lstrip("/"))
    # cgroup namespaces can expose a relative path outside the visible mount.
    path = base / relative if ".." not in relative.parts else base
    if not path.is_dir():
        path = base
    while True:
        mem = text(path / "memory.max", "")
        cpu = text(path / "cpu.max", "")
        if mem.isdigit():
            result["memory_max_bytes"].append(int(mem))
        if cpu and not cpu.startswith("max"):
            result["cpu_quotas"].append(cpu)
        if path == base:
            break
        path = path.parent
    result["note"] = "only visible cgroup ancestors; provider limits can be hidden"
    return result


def collect():
    release = os_release()
    routes = json_command(["ip", "-j", "-4", "route", "show", "default"])
    addresses = json_command(["ip", "-j", "address", "show"])
    devices = sorted({r.get("dev", "") for r in routes if r.get("dev")})
    v4 = any(a.get("family") == "inet" and a.get("scope") == "global"
             for interface in addresses for a in interface.get("addr_info", []))
    v6 = any(a.get("family") == "inet6" and a.get("scope") == "global"
             for interface in addresses for a in interface.get("addr_info", []))
    rc, virt = run(["systemd-detect-virt"])
    if rc not in (0, 1) or not virt:
        virt = "unknown"
    rc, container = run(["systemd-detect-virt", "--container"])
    isolated = (Path("/.dockerenv").exists() or Path("/run/.containerenv").exists()
                or rc == 0)
    container_known = rc in (0, 1) and bool(container)
    mem = {}
    for line in text("/proc/meminfo", "").splitlines():
        fields = line.split()
        if fields and fields[0].rstrip(":") in {"MemTotal", "MemAvailable", "SwapTotal", "SwapFree"}:
            mem[fields[0].rstrip(":") + "_KiB"] = int(fields[1])
    qdisc = json_command(["tc", "-j", "qdisc", "show"])
    # Whitelist fields: do not log IPs, command lines, credentials or configs.
    queues = [{k: q[k] for k in ("dev", "kind", "root", "parent") if k in q}
              for q in qdisc]
    services = set()
    for proc in Path("/proc").glob("[0-9]*"):
        name = text(proc / "comm", "")
        if name in KNOWN_SERVICES:
            services.add(name)
    interfaces = []
    for interface in addresses:
        name = interface.get("ifname", "")
        if name and name != "lo":
            counters = {}
            for field in ("rx_dropped", "tx_dropped", "rx_errors", "tx_errors"):
                # Never allow a device name to escape sysfs.
                if re.fullmatch(r"[a-zA-Z0-9_.:@-]+", name):
                    counters[field] = text(Path("/sys/class/net") / name / "statistics" / field)
            interfaces.append({"name": name, "mtu": interface.get("mtu"),
                               "state": interface.get("operstate"), "cumulative": counters})
    keys = [KEY, "net.ipv4.tcp_available_congestion_control", "net.core.default_qdisc",
            "net.ipv4.tcp_rmem", "net.ipv4.tcp_wmem", "net.core.rmem_max",
            "net.core.wmem_max", "net.core.netdev_max_backlog", "net.core.somaxconn",
            "net.netfilter.nf_conntrack_count", "net.netfilter.nf_conntrack_max",
            "net.ipv4.ip_forward", "net.ipv6.conf.all.disable_ipv6",
            "net.ipv6.conf.default.disable_ipv6", "fs.file-max"]
    ssh = os.environ.get("SSH_CONNECTION", "").split()
    ssh_family = "unknown"
    if len(ssh) == 4:
        try:
            ssh_family = "IPv6" if any(ipaddress.ip_address(ssh[i]).version == 6 for i in (0, 2)) else "IPv4"
        except ValueError:
            pass
    return {
        "version": VERSION, "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "os": release.get("ID", "unknown"), "os_version": release.get("VERSION_ID", "unknown"),
        "kernel": os.uname().release, "architecture": os.uname().machine,
        "root": os.geteuid() == 0, "init": text("/proc/1/comm"),
        "package_managers": [p for p in ("apt-get", "dnf", "yum", "zypper", "pacman", "apk") if shutil.which(p)],
        "virtualization": virt, "container": isolated, "container_detection_known": container_known,
        "cpus_visible": len(os.sched_getaffinity(0)), "memory": mem, "cgroup": limits(),
        "load_average": list(os.getloadavg()),
        "pressure": {k: text("/proc/pressure/" + k) for k in ("cpu", "memory", "io")},
        "ipv4_address": v4, "ipv4_default_interfaces": devices,
        "ipv6_global_address": v6, "ssh_family": ssh_family,
        "ipv6_listeners_present": bool(run(["ss", "-H", "-6", "-lntu"])[1]),
        "ipv6_routes_present": bool(json_command(["ip", "-j", "-6", "route", "show"])),
        "ipv6_interface_disable_flags": {p.parent.name: text(p) for p in
                                         Path("/proc/sys/net/ipv6/conf").glob("*/disable_ipv6")},
        "interfaces": interfaces, "active_qdisc": queues,
        "sysctl": {k: sysread(k) for k in keys},
        "file_handles": text("/proc/sys/fs/file-nr"),
        "known_process_names": sorted(services),
        "wireguard_interface_present": any(i.get("linkinfo", {}).get("info_kind") == "wireguard"
             for i in json_command(["ip", "-d", "-j", "link", "show"])),
    }


def blockers(s):
    reasons = []
    if (s["os"], s["os_version"]) not in SUPPORTED:
        reasons.append("این توزیع/نسخه فقط در حالت گزارش پشتیبانی می‌شود.")
    if not s["root"]:
        reasons.append("اعمال تغییر نیازمند root است.")
    if s["container"] or not s["container_detection_known"]:
        reasons.append("کانتینر یا مرز کنترل میزبان نامعلوم: تنظیمات میزبان رد شد.")
    if s["virtualization"] in {"unknown", "openvz", "lxc", "docker", "podman", "systemd-nspawn"}:
        reasons.append("نوع مجازی‌سازی برای تغییر امن احراز نشده است.")
    if s["init"] != "systemd":
        reasons.append("بازگشت زمان‌دار این نسخه به systemd نیاز دارد.")
    if not s["ipv4_address"] or len(s["ipv4_default_interfaces"]) != 1:
        reasons.append("IPv4 و دقیقاً یک رابط پیش‌فرض احراز نشده؛ مسیر چندگانه نیازمند بررسی دستی است.")
    if "bbr" not in s["sysctl"].get("net.ipv4.tcp_available_congestion_control", "").split():
        reasons.append("BBR در الگوریتم‌های هم‌اکنون قابل استفاده نیست؛ ماژول/کرنل نصب یا بارگذاری نمی‌شود.")
    old = s["sysctl"].get(KEY, "unknown")
    if old not in {"cubic", "reno", "bbr"}:
        reasons.append("الگوریتم فعلی سفارشی/ناشناخته است؛ حفظ می‌شود.")
    for dev in s["ipv4_default_interfaces"]:
        roots = [q for q in s["active_qdisc"] if q.get("dev") == dev and q.get("root")]
        if len(roots) != 1 or roots[0].get("kind") != "fq":
            reasons.append("صف ریشه مسیر پیش‌فرض fq نیست/نامعلوم است؛ صف زنده را جایگزین نمی‌کنیم.")
    total = s["memory"].get("MemTotal_KiB", 0)
    available = s["memory"].get("MemAvailable_KiB", 0)
    if not total or available < total * 0.1:
        reasons.append("فشار حافظه یا اطلاعات ناکافی؛ آزمایش تنظیمات رد شد.")
    return reasons


def plan(s, profile, trial=False):
    reasons = blockers(s) if trial else []
    changes = []
    if not trial:
        reasons.append("شواهد آزمون TCP و اجازه آزمایش BBR ارائه نشده؛ مقدار فعلی حفظ شد (آرگومان --tcp-bbr).")
    elif not reasons and s["sysctl"][KEY] != "bbr":
        changes.append({"key": KEY, "old": s["sysctl"][KEY], "new": "bbr",
                        "reason": "آزمایش صریح مدیر؛ BBR موجود و fq فعال، نه ادعای برتری اندازه‌گیری‌شده"})
    elif not reasons:
        reasons.append("BBR از قبل فعال است؛ تغییر تکراری لازم نیست.")
    return {"profile": profile, "profile_reason": PROFILES[profile], "changes": changes,
            "rejected_or_preserved": reasons + [
                "IPv6 غیرفعال نمی‌شود: وابستگی برنامه، تونل، کانتینر و مسیر پشتیبان به‌طور کامل قابل اثبات نیست؛ IPv4-only اجرا نشده است.",
                "بافر TCP/UDP، backlog، fd و conntrack: نمونه کوتاه اثبات اشباع نیست؛ بدون روند بار و بودجه حافظه دست‌نخورده.",
                "qdisc فعال/default، MTU/MSS، DNS، ECN، TFO، keepalive، SSH و فایروال دست‌نخورده.",
                "BBR فقط TCP محلی با انتخاب پیش‌فرض را تحت تأثیر قرار می‌دهد (IPv4 و IPv6)؛ TCP عبوری، UDP، QUIC و الگوریتم اختصاصی برنامه را تنظیم نمی‌کند."]}


class Host:
    def get(self):
        return sysread(KEY)

    def set(self, value):
        if value not in {"cubic", "reno", "bbr"}:
            raise SafeError("مقدار sysctl خارج از فهرست مجاز است.")
        rc, _ = run(["sysctl", "-w", KEY + "=" + value])
        if rc != 0 or self.get() != value:
            raise SafeError("نوشتن/تأیید sysctl ناموفق بود؛ جزئیات حساس چاپ نمی‌شود.")

    def arm(self, ident):
        engine = SCRIPT
        secure_file(engine)
        # Timer must survive the invoking SSH shell; only the installed copy is accepted.
        if not str(engine).startswith("/usr/local/lib/safe-net/"):
            raise SafeError("آزمایش نیازمند نسخه نصب‌شده در /usr/local/lib/safe-net است.")
        bash = Path("/bin/bash").resolve()
        secure_file(bash)
        secure_file(Path(sys.executable).resolve())
        rc, state = run(["systemctl", "is-system-running"])
        if state not in {"running", "degraded"}:
            raise SafeError("systemd برای نگهبان بازگشت آماده نیست.")
        rc, _ = run(["systemd-run", "--quiet", "--unit=safe-net-guard-" + ident,
                     "--on-active=" + str(GUARD_SECONDS) + "s", "--timer-property=AccuracySec=1s",
                     str(bash), str(engine), "--expire", ident], timeout=15)
        if rc != 0:
            raise SafeError("ساخت نگهبان بازگشت ناموفق بود؛ sysctl تغییر نکرد.")
        rc, state = run(["systemctl", "is-active", "safe-net-guard-" + ident + ".timer"])
        if rc != 0 or state != "active":
            raise SafeError("فعال بودن تایمر احراز نشد؛ sysctl تغییر نکرد.")


class Store:
    """Append-only journal. No latest-pointer overwrite and no deletion.

    flock is held across every real mutation. Tests use private fake paths and
    a fake Host through dependency injection, never environment overrides.
    """
    def __init__(self, root=STATE, config=CONFIG, host=None):
        self.root = Path(root)
        self.config = Path(config)
        self.host = host if host is not None else Host()

    @contextlib.contextmanager
    def lock(self, wait=False):
        secure_dir(self.root, create=True)
        fd = os.open(self.root / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            st = os.fstat(fd)
            if st.st_uid != 0 or st.st_mode & 0o077 or not stat.S_ISREG(st.st_mode):
                raise SafeError("قفل ناامن است.")
            deadline = time.monotonic() + 30
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if not wait and time.monotonic() >= deadline:
                        raise SafeError("نمونه دیگری در حال اجراست؛ بعداً تلاش کنید.")
                    time.sleep(0.1)
            yield
        finally:
            os.close(fd)

    def event(self, folder, action, **fields):
        record = {"time_ns": time.time_ns(), "action": action, **fields}
        write_new(folder / (str(record["time_ns"]) + "-" + uuid.uuid4().hex + ".json"),
                  json.dumps(record, ensure_ascii=False, indent=2) + "\n")

    def events(self, folder):
        result = []
        for path in sorted(folder.glob("[0-9]*.json")):
            secure_file(path)
            result.append(json.loads(path.read_text()))
        return result

    def transaction(self, ident):
        if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}", ident):
            raise SafeError("شناسه تراکنش نامعتبر است.")
        folder = self.root / ident
        secure_dir(folder)
        secure_file(folder / "backup.json")
        data = json.loads((folder / "backup.json").read_text())
        if data.get("key") != KEY or data.get("old") not in {"reno", "cubic"} or data.get("new") != "bbr":
            raise SafeError("بکاپ معتبر نیست؛ بازگردانی متوقف شد.")
        return folder, data

    def active(self):
        result = []
        for path in sorted(self.root.glob("*Z-*")):
            folder, data = self.transaction(path.name)
            actions = [e["action"] for e in self.events(folder)]
            if "rolled-back" not in actions:
                result.append((folder, data, actions))
        return result

    def new_report(self, snapshot, proposed):
        folder = self.root / ("report-" + uuid.uuid4().hex)
        folder.mkdir(mode=0o700)
        write_new(folder / "report.json", json.dumps({"before": snapshot, "plan": proposed},
                                                     ensure_ascii=False, indent=2) + "\n")
        return folder

    def apply(self, snapshot, proposed):
        if self.active():
            raise SafeError("تراکنش قبلی هنوز فعال/دارای تعارض است؛ ابتدا --status یا --rollback.")
        if not proposed["changes"]:
            return None
        secure_dir(self.config.parent)
        if self.config.exists() or self.config.is_symlink():
            raise SafeError("فایل اختصاصی sysctl از قبل وجود دارد؛ هرگز بازنویسی نمی‌شود.")
        change = proposed["changes"][0]
        if self.host.get() != change["old"]:
            raise SafeError("مقدار زنده پس از تشخیص تغییر کرده؛ اعمال رد شد.")
        ident = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]
        folder = self.root / ident
        folder.mkdir(mode=0o700)
        data = {**change, "profile": proposed["profile"], "config_previously_absent": True,
                "created_ns": time.time_ns(), "guard_seconds": GUARD_SECONDS}
        write_new(folder / "backup.json", json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        write_new(folder / "before.json", json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n")
        self.event(folder, "prepared", old=data["old"], new=data["new"], reason=data["reason"])
        try:
            self.host.arm(ident)  # Arm first: even SIGKILL leaves an independent guard.
            self.event(folder, "guard-armed")
            if self.host.get() != data["old"]:
                raise SafeError("تعارض هم‌زمان با مدیر/برنامه دیگر؛ اعمال رد شد.")
            self.event(folder, "write-intent", old=data["old"], new=data["new"])
            self.host.set(data["new"])
            self.event(folder, "applied", old=data["old"], new=self.host.get())
        except BaseException:
            self.rollback(ident)
            raise
        return ident

    def expected_config(self, ident):
        return ("# Owned by Safe Net; transaction " + ident + "\n" + KEY + " = bbr\n").encode()

    def confirm(self, ident, persist=False):
        folder, data = self.transaction(ident)
        actions = [e["action"] for e in self.events(folder)]
        if "rolled-back" in actions or "applied" not in actions or "conflict" in actions:
            raise SafeError("تراکنش قابل تأیید نیست.")
        if "confirmed" in actions:
            raise SafeError("قبلاً تأیید شده؛ برای تغییر نوع ماندگاری ابتدا rollback و آزمایش تازه لازم است.")
        if time.time_ns() >= data["created_ns"] + GUARD_SECONDS * 1_000_000_000:
            self.rollback(ident)
            raise SafeError("مهلت آزمایش تمام شده است.")
        if self.host.get() != data["new"]:
            raise SafeError("مقدار زنده تغییر کرده؛ تأیید رد شد.")
        if persist:
            secure_dir(self.config.parent)
            if self.config.exists() or self.config.is_symlink() or persistence_conflicts():
                raise SafeError("فایل هم‌نام/تنظیم پایدار دیگر یا فایل ناخوانا وجود دارد؛ تأیید پایدار رد شد.")
        # This durable confirmation is the commit point. A later interruption
        # cannot leave an unconfirmed persistent setting. If creation fails,
        # runtime is confirmed but persistence may be absent; rollback is safe.
        self.event(folder, "confirmed", persistent_requested=persist)
        if persist:
            payload = self.expected_config(ident)
            self.event(folder, "persist-intent", sha256=hashlib.sha256(payload).hexdigest())
            write_new(self.config, payload.decode(), mode=0o644)
            st = self.config.stat()
            self.event(folder, "persisted", sha256=hashlib.sha256(payload).hexdigest(),
                       identity=[st.st_dev, st.st_ino, st.st_mode, st.st_uid, st.st_gid,
                                 st.st_mtime_ns, st.st_ctime_ns])
        # Do not stop timers: their callback checks the journal while holding lock.
        # This avoids races and unnecessary systemd operations.

    def rollback(self, ident, expired=False):
        folder, data = self.transaction(ident)
        events = self.events(folder)
        actions = [e["action"] for e in events]
        if "rolled-back" in actions:
            return "already-rolled-back"
        if expired and "confirmed" in actions:
            return "confirmed-noop"
        conflicts = []
        persistent_owned = "persist-intent" in actions
        if self.config.exists() or self.config.is_symlink():
            if persistent_owned:
                # If changed, do not touch either config or runtime: preserve later admin intent.
                secure_file(self.config)
                st = self.config.stat()
                identity = [st.st_dev, st.st_ino, st.st_mode, st.st_uid, st.st_gid,
                            st.st_mtime_ns, st.st_ctime_ns]
                saved = next((e.get("identity") for e in reversed(events) if e["action"] == "persisted"), None)
                if self.config.read_bytes() != self.expected_config(ident) or (saved and identity != saved):
                    conflicts.append("فایل اختصاصی بعداً ویرایش شده؛ فایل و مقدار زنده حفظ شدند.")
                else:
                    # Same-directory rename, no deletion; .disabled is ignored by sysctl.d.
                    destination = self.config.parent / ("90-safe-net." + ident + "." + uuid.uuid4().hex + ".disabled")
                    os.rename(self.config, destination)
                    fsync_dir(self.config.parent)
                    self.event(folder, "persistence-disabled", archived=str(destination))
            else:
                conflicts.append("فایل هم‌نامی خارج از این تراکنش ایجاد شده؛ حفظ شد.")
        if not conflicts:
            current = self.host.get()
            if current == data["old"]:
                self.event(folder, "runtime-already-original", value=current)
            elif current == data["new"] and "write-intent" in actions:
                self.event(folder, "restore-intent", old=current, new=data["old"])
                self.host.set(data["old"])
                self.event(folder, "restored", old=current, new=data["old"])
            elif "write-intent" not in actions:
                self.event(folder, "no-runtime-write")
            else:
                conflicts.append("مقدار زنده با مقدار اعمال‌شده برابر نیست؛ تغییر بعدی مدیر حفظ شد.")
        if conflicts:
            self.event(folder, "conflict", reasons=conflicts)
            raise SafeError("بازگردانی کامل نشد: " + " ".join(conflicts))
        self.event(folder, "rolled-back", automatic=expired)
        return "rolled-back"


def persistence_conflicts():
    paths = [Path("/etc/sysctl.conf")]
    for directory in ("/etc/sysctl.d", "/run/sysctl.d", "/usr/local/lib/sysctl.d",
                      "/usr/lib/sysctl.d", "/lib/sysctl.d"):
        paths.extend(Path(directory).glob("*.conf"))
    pattern = re.compile(r"^\s*-?net[./]ipv4[./]tcp_congestion_control\s*=")
    for path in paths:
        if path == CONFIG or not path.exists():
            continue
        try:
            if any(pattern.match(line) for line in path.read_text().splitlines()):
                return True
        except (OSError, UnicodeError):
            return True
    return False


def print_report(s, proposed=None):
    print("╔══════════════════════════════════════════════════╗")
    print("║         Safe Net 1.0 — ایمنی پیش از سرعت          ║")
    print("╚══════════════════════════════════════════════════╝")
    print(json.dumps(s, ensure_ascii=False, indent=2))
    if proposed:
        print("\nطرح/دلایل حفظ تنظیمات:")
        print(json.dumps(proposed, ensure_ascii=False, indent=2))
    print("IPv4 دارای آدرس و مسیر ≠ دسترسی اینترنت اثبات‌شده. IPv6 تغییر نمی‌کند؛ IPv4-only اجرا نشده است.")
    print("شمارنده‌های تجمعی و یک نمونه بار، اثبات گلوگاه یا افزایش سرعت نیستند.")


def probe(address):
    try:
        target = str(ipaddress.IPv4Address(address))
    except ipaddress.AddressValueError as exc:
        raise SafeError("آزمون فقط IPv4 عددی معتبر می‌پذیرد.") from exc
    rc, output = run(["ping", "-4", "-n", "-c", "5", "-i", "1", "-W", "2", "-w", "12", "--", target], timeout=15)
    summary = [line for line in output.splitlines() if "packets transmitted" in line or line.startswith(("rtt ", "round-trip "))]
    print(json.dumps({"probe_exit": rc, "summary": summary, "packets_max": 5}, ensure_ascii=False))
    print("ICMP ممکن است محدود باشد؛ این آزمون ظرفیت، کیفیت VPN یا jitter برنامه را اندازه نمی‌گیرد.")


def choose_profile():
    print("╔══════════════════════════════════════════════════╗")
    print("║ این اسکریپت روی کدام سرور اجرا می‌شود؟           ║")
    print("║ [1] سرور ایران                                  ║")
    print("║ [2] سرور خارج                                   ║")
    print("╚══════════════════════════════════════════════════╝")
    try:
        print("انتخاب: ", end="", flush=True)
        with open("/dev/tty", "r", encoding="utf-8") as terminal:
            answer = terminal.readline().strip()
    except (EOFError, OSError) as exc:
        raise SafeError("ترمینال ندارید؛ --profile iran یا --profile outside بدهید.") from exc
    if answer not in {"1", "۱", "2", "۲"}:
        raise SafeError("گزینه نامعتبر؛ هیچ تغییری انجام نشد.")
    return "iran" if answer in {"1", "۱"} else "outside"


def parser():
    p = argparse.ArgumentParser(description="Safe Net: تشخیص امن و آزمایش اختیاری TCP؛ بدون حذف داده")
    modes = p.add_mutually_exclusive_group()
    modes.add_argument("--install", action="store_true", help="نصب همین فایل؛ بدون دانلود یا تغییر شبکه")
    modes.add_argument("--dry-run", action="store_true", help="طرح بدون نوشتن فایل/تنظیم یا بسته")
    modes.add_argument("--status", action="store_true", help="وضعیت واقعی و تراکنش‌ها")
    modes.add_argument("--diagnose", action="store_true", help="تشخیص فقط خواندنی")
    modes.add_argument("--rollback", action="store_true", help="بازگردانی تراکنش فعال؛ حفظ تعارض‌ها")
    modes.add_argument("--confirm", metavar="ID", help="تأیید آزمایش پس از بررسی اتصال/اندازه‌گیری؛ قبل از ۱۸۰ ثانیه")
    modes.add_argument("--expire", metavar="ID", help=argparse.SUPPRESS)
    p.add_argument("--profile", choices=sorted(PROFILES))
    p.add_argument("--tcp-bbr", action="store_true", help="اجازه آزمایش برگشت‌پذیر BBR؛ فقط با fq فعال و BBR موجود")
    p.add_argument("--persist", action="store_true", help="فقط همراه --confirm؛ ساخت فایل اختصاصی پایدار")
    p.add_argument("--probe", metavar="IPV4", help="اجازه صریح ۵ ping به مقصد عددی مجاز؛ بدون DNS")
    p.add_argument("--version", action="version", version=VERSION)
    return p


def install_self():
    source = SCRIPT.read_bytes()
    if not source.startswith(b"#!/usr/bin/env bash\n") or b"# SAFE_NET_EMBEDDED_END" not in source:
        raise SafeError("ساختار فایل یکپارچه نامعتبر است.")
    digest = hashlib.sha256(source).hexdigest()
    base = Path("/usr/local/lib/safe-net")
    target_dir = base / digest
    launcher = Path("/usr/local/sbin/safe-net")
    secure_dir(base, create=True)
    secure_dir(launcher.parent, create=True)
    target = target_dir / "install.sh"
    if launcher.exists() or launcher.is_symlink():
        if not launcher.is_symlink() or os.readlink(launcher) != str(target):
            raise SafeError("مسیر safe-net موجود و متعلق به نسخه دیگری است؛ بازنویسی ممنوع.")
    secure_dir(target_dir, create=True)
    if target.exists() or target.is_symlink():
        secure_file(target)
        if target.read_bytes() != source:
            raise SafeError("فایل موجود متفاوت است؛ بازنویسی ممنوع.")
    else:
        write_new(target, source.decode("utf-8"), mode=0o700)
    if not launcher.is_symlink():
        os.symlink(str(target), launcher)
        fsync_dir(launcher.parent)
    print("نصب شد (یا همین نسخه قبلاً نصب بود):", launcher)
    print("SHA256:", digest)
    print("هیچ بسته یا تنظیم شبکه‌ای تغییر نکرد. اجرا: sudo /usr/local/sbin/safe-net")


def main(argv=None):
    os.umask(0o077)
    os.environ["PATH"] = "/usr/sbin:/usr/bin:/sbin:/bin"
    os.environ["LC_ALL"] = "C"
    if sys.version_info < (3, 9):
        raise SafeError("Python 3.9+ لازم است.")
    args = parser().parse_args(argv)
    if args.persist and not args.confirm:
        raise SafeError("--persist فقط همراه --confirm مجاز است.")
    maintenance = args.rollback or args.confirm or args.expire or args.install
    if maintenance and (args.profile or args.probe or args.tcp_bbr):
        raise SafeError("آرگومان آزمایش/پروفایل با بازگردانی/تأیید ترکیب نشود.")
    if args.tcp_bbr and (args.status or args.diagnose):
        raise SafeError("--tcp-bbr فقط در dry-run یا اجرای عادی مجاز است.")
    store = Store()
    if maintenance:
        if os.geteuid() != 0:
            raise SafeError("برای بازگردانی/تأیید root لازم است.")
        with store.lock(wait=bool(args.expire)):
            if args.install:
                install_self()
            elif args.confirm:
                store.confirm(args.confirm, persist=args.persist)
                print("تأیید ثبت شد؛ ماندگاری:", bool(args.persist))
            elif args.expire:
                print(store.rollback(args.expire, expired=True))
            else:
                active = store.active()
                if not active:
                    print("تغییر فعال متعلق به ابزار وجود ندارد.")
                for folder, _, _ in reversed(active):
                    print(folder.name, store.rollback(folder.name))
        return 0
    s = collect()
    if args.status or args.diagnose:
        print_report(s)
        if args.status and os.geteuid() == 0 and STATE.exists():
            secure_dir(STATE)
            print("active_transactions (read-only, may race):")
            for folder, _, actions in store.active():
                print(folder.name, actions)
        if args.probe:
            probe(args.probe)
        return 0
    profile = args.profile or choose_profile()
    proposed = plan(s, profile, args.tcp_bbr)
    print_report(s, proposed)
    if args.dry_run:
        print("dry-run: هیچ فایل، بسته، تنظیم یا آزمون شبکه‌ای ایجاد/اجرا نشد.")
        return 0
    if args.probe:
        probe(args.probe)
    if os.geteuid() != 0:
        if args.tcp_bbr:
            raise SafeError("آزمایش بدون root رد شد؛ تشخیص انجام شد.")
        print("حالت محدود بدون root: فقط گزارش روی ترمینال؛ فایل نوشته نشد.")
        return 0
    # Unknown systems and containers remain entirely read-only.
    if (s["os"], s["os_version"]) not in SUPPORTED or s["container"] or not s["container_detection_known"]:
        print("سیستم/محیط فقط در حالت محدود پشتیبانی می‌شود؛ هیچ فایل یا تنظیمی نوشته نشد.")
        return 1 if args.tcp_bbr else 0
    with store.lock():
        report = store.new_report(s, proposed)
        print("گزارش خصوصی:", report)
        if args.tcp_bbr and blockers(s):
            raise SafeError("پیش‌شرط‌های آزمایش برقرار نیست؛ دلایل بالا ثبت شدند.")
        # Refresh plan under lock to detect changes since diagnosis.
        fresh = collect()
        fresh_plan = plan(fresh, profile, args.tcp_bbr)
        if args.tcp_bbr and blockers(fresh):
            raise SafeError("پیش‌شرط‌ها پس از تشخیص تغییر کردند؛ اعمال رد شد.")
        ident = store.apply(fresh, fresh_plan) if fresh_plan["changes"] else None
        after = collect()
        write_new(report / "after.json", json.dumps(after, ensure_ascii=False, indent=2) + "\n")
        print("پس از اجرا:")
        print_report(after)
        if ident:
            print("آزمایش فعال؛ بازگشت خودکار حداکثر حدود ۱۸۰ ثانیه بعد از آغاز (وابسته به اجرای systemd).")
            print("بکاپ و لاگ:", STATE / ident)
            print("پس از آزمون مستقل اتصال و عملکرد، پیش از پایان مهلت:")
            print("sudo safe-net --confirm", ident, "[--persist]")
        else:
            print("تغییر اعمال‌شده: صفر؛ تنظیم فعلی حفظ شد. گزارش:", report)
    print("بازگردانی: sudo safe-net --rollback")
    print("هیچ افزایش سرعتی اثبات نشده؛ مسیر، دیتاسنتر، CPU، پروتکل و سمت کاربر می‌توانند گلوگاه باشند.")
    return 0


def interrupted(signum, _frame):
    raise SafeError("وقفه اجرا؛ در آزمایش فعال، نگهبان مستقل بازگشت باقی می‌ماند (signal %s)." % signum)


if __name__ == "__main__":
    SCRIPT = Path(sys.argv.pop(1)).resolve()
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        sys.exit(main())
    except (SafeError, OSError, ValueError, KeyError) as error:
        # Only our own messages are safe to log. OS/JSON errors can contain arbitrary data.
        message = str(error) if isinstance(error, SafeError) else type(error).__name__ + ": عملیات امن متوقف شد؛ وضعیت/بکاپ را بررسی کنید."
        print("خطا:", message, file=sys.stderr)
        sys.exit(1)

SAFE_NET_PYTHON
# SAFE_NET_EMBEDDED_END
