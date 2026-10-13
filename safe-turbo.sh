#!/usr/bin/env bash
# Safe Turbo Advisor 1.1 — diagnostic-only, IPv4-only probes.
# Supported: Ubuntu 22.04/24.04 LTS; Debian 12/13. Requires Bash >= 4.
# No package installation, service restart, external telemetry or heavy tests.
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C
umask 077

PROFILE='unset'
SERVICE='unknown'
SERVER_REGION='unknown'
USER_REGION='unknown'
TARGET=''
WORK=''
BEFORE=''
AFTER=''
PING_COUNT=10

say() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
ask() { local value; IFS= read -r -p "$1" value || return 1; REPLY=$value; }
confirm() { ask "$1 [yes/خیر]: " && [[ $REPLY == yes ]]; }
fail() { say "خطا: $*" >&2; exit 1; }
trap 'printf "خطای داخلی در خط %s؛ هیچ تنظیم سیستمی تغییر نکرده است.\n" "$LINENO" >&2' ERR
trap 'printf "\nمتوقف شد؛ هیچ تنظیم سیستمی تغییر نکرده است.\n" >&2; exit 130' INT TERM

check_os() {
    [[ ${BASH_VERSINFO[0]} -ge 4 ]] || fail 'Bash 4 یا جدیدتر لازم است.'
    [[ -r /etc/os-release ]] || fail 'سیستم‌عامل قابل شناسایی نیست.'
    local ID='' VERSION_ID=''
    # This is an OS-owned local file, not a downloaded shell fragment.
    # shellcheck disable=SC1091
    . /etc/os-release
    case "$ID:$VERSION_ID" in
        ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
        *) fail "سیستم پشتیبانی‌نشده: $ID $VERSION_ID؛ توقف بدون تغییر." ;;
    esac
    OS_LABEL="$ID $VERSION_ID"
    local cmd
    for cmd in awk date mktemp mkdir chmod uname sleep diff; do
        have "$cmd" || fail "ابزار ضروری موجود نیست: $cmd (نصب خودکار انجام نمی‌شود)."
    done
    [[ -r /proc/meminfo && -r /proc/stat ]] || fail 'دسترسی به proc کافی نیست.'
}

init_reports() {
    # A private, unpredictable directory; never overwrite existing files.
    [[ -n ${HOME:-} && -d $HOME && -w $HOME ]] || fail 'HOME قابل نوشتن لازم است.'
    WORK=$(mktemp -d "$HOME/safe-turbo.XXXXXXXX")
    chmod 700 "$WORK"
    say "گزارش‌های محلی با دسترسی محدود: $WORK"
    say 'گزارش شامل داده فنی است؛ پیش از اشتراک‌گذاری بررسی شود. هیچ داده‌ای خودکار ارسال نمی‌شود.'
}

select_profile() {
    while true; do
        printf '\n%s\n' \
            '╔══════════════════════════════════════╗' \
            '║       SAFE TURBO — IPv4              ║' \
            '║       بررسی امن؛ بدون حذف اطلاعات   ║' \
            '╠══════════════════════════════════════╣' \
            '║  ۱) سرور ایران                       ║' \
            '║  ۲) سرور خارج                        ║' \
            '║  ۰) خروج                             ║' \
            '╚══════════════════════════════════════╝'
        ask 'محل اجرای این سرور: ' || return 1
        case $REPLY in
            1|۱) PROFILE=iran; SERVER_REGION=Iran; return 0 ;;
            2|۲) PROFILE=international; SERVER_REGION=outside-Iran; return 0 ;;
            0|۰) return 1 ;;
            *) say 'فقط ۱ یا ۲ را انتخاب کنید؛ ۰ برای خروج.' ;;
        esac
    done
}

valid_ipv4() {
    local address=$1 octet
    local -a octets
    [[ $address =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        # Reject leading zeros to avoid octal/implementation ambiguity.
        [[ ${#octet} -eq 1 || $octet != 0* ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

ipv4_status() {
    local -a connection
    say '[IPv4 readiness; read-only, not a connectivity guarantee]'
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        IFS=' ' read -r -a connection <<< "$SSH_CONNECTION"
        if [[ ${connection[0]:-} == *:* || ${connection[2]:-} == *:* ]]; then
            say 'SSH appears to use IPv6: globally disabling IPv6 could disconnect management.'
        else
            say 'SSH environment indicates IPv4; this does not prove emergency access is available.'
        fi
    else
        say 'SSH address family unknown.'
    fi
    say 'Only probes use IPv4. OS, applications, tunnels and client traffic are NOT made IPv4-only.'
}

context() {
    say 'اطلاعات غیرحساس وارد کنید؛ رمز، دامنه محرمانه یا توکن وارد نکنید.'
    ask 'نوع سرویس (مثلاً nginx/vpn/database؛ یا unknown): ' || return 0
    SERVICE=${REPLY:-unknown}
    ask 'کشور سرور (یا unknown): ' || return 0
    SERVER_REGION=${REPLY:-unknown}
    ask 'کشور/اپراتور کاربران (یا unknown): ' || return 0
    USER_REGION=${REPLY:-unknown}
    say 'اطلاعات فقط برای پیشنهاد استفاده می‌شود؛ اعمال تنظیمات در این نسخه قفل است.'
}

cpu_sample() {
    local first second
    first=$(awk '/^cpu / {t=0; for(i=2;i<=9;i++)t+=$i; print t, $5+$6; exit}' /proc/stat)
    sleep 1
    second=$(awk '/^cpu / {t=0; for(i=2;i<=9;i++)t+=$i; print t, $5+$6; exit}' /proc/stat)
    awk -v a="$first" -v b="$second" 'BEGIN {
        split(a,x," "); split(b,y," "); d=y[1]-x[1];
        if(d>0) printf "cpu_busy_pct=%.1f (one-second host sample)\n",100*(d-y[2]+x[2])/d;
        else print "cpu_busy_pct=unavailable"
    }'
}

cgroup_info() {
    local hierarchy controllers relative path file
    if [[ -r /proc/self/cgroup ]]; then
        while IFS=: read -r hierarchy controllers relative; do
            if [[ $hierarchy == 0 && -z $controllers && $relative != *'..'* ]]; then
                path="/sys/fs/cgroup${relative%/}"
                for file in cpu.max memory.max memory.current memory.events pids.max; do
                    if [[ -r $path/$file ]]; then
                        printf 'cgroup.%s=' "$file"
                        awk '{printf "%s; ",$0} END {print ""}' "$path/$file"
                    fi
                done
            fi
        done < /proc/self/cgroup
    fi
    say 'cgroup: only visible v2 leaf limits above; ancestor/provider/v1 limits may be unknown.'
}

snapshot() {
    local output=$1 key path kind
    {
        printf 'timestamp=%s\nos=%s\n' "$(date -Is)" "$OS_LABEL"
        printf 'kernel=%s\narchitecture=%s\n' "$(uname -r)" "$(uname -m)"
        ipv4_status
        if have nproc; then printf 'visible_cpus=%s\n' "$(nproc)"; fi
        if have systemd-detect-virt; then
            printf 'virtualization='; systemd-detect-virt || true
        fi
        printf 'session_nofile_soft=%s\nsession_nofile_hard=%s\n' "$(ulimit -Sn)" "$(ulimit -Hn)"
        say 'These are shell limits, NOT application service limits.'
        awk '{print "loadavg=" $1 " " $2 " " $3}' /proc/loadavg
        cpu_sample
        awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree|Dirty|Writeback):/ {print}' /proc/meminfo
        cgroup_info
        for kind in cpu memory io; do
            path="/proc/pressure/$kind"
            if [[ -r $path ]]; then
                printf 'pressure.%s\n' "$kind"; awk '{print}' "$path"
            fi
        done
        if have df; then say '[root filesystem only]'; df -hP / || true; df -iP / || true; fi
        if have lsblk; then
            say '[block devices: no serials, UUIDs or mount paths]'
            lsblk -dn -o NAME,TYPE,SIZE,ROTA || true
        fi
        if have ip; then
            say '[default interface names only; no IP addresses]'
            ip -4 -o route show default 2>/dev/null |
                awk '{for(i=1;i<=NF;i++)if($i=="dev")print $(i+1)}' || true
        fi
        say '[interfaces: cumulative counters, not proof of current packet loss]'
        for path in /sys/class/net/*; do
            [[ -d $path && ${path##*/} != lo ]] || continue
            printf 'interface=%s\n' "${path##*/}"
            for key in operstate mtu speed statistics/rx_bytes statistics/tx_bytes statistics/rx_errors statistics/tx_errors statistics/rx_dropped statistics/tx_dropped; do
                if [[ -r $path/$key ]]; then
                    printf '%s=' "$key"
                    awk '{print}' "$path/$key" 2>/dev/null || say 'unknown'
                fi
            done
        done
        if have ss; then say '[socket summary only]'; ss -s || true; fi
        if have tc; then
            say '[current qdisc; read-only]'; tc qdisc show 2>/dev/null || true
        fi
        say '[selected live kernel values]'
        for key in net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.rmem_max net.core.wmem_max net.core.somaxconn fs.file-max vm.swappiness; do
            path="/proc/sys/${key//./\/}"
            if [[ -r $path ]]; then printf '%s=' "$key"; awk '{print}' "$path"; fi
        done
        if [[ -r /proc/sys/fs/file-nr ]]; then
            printf 'system_file_handles='; awk '{print}' /proc/sys/fs/file-nr
        fi
    } > "$output"
    say "ثبت شد: $output"
    while IFS= read -r line; do printf '%s\n' "$line"; done < "$output"
}

recommend() {
    local report
    report=$(mktemp "$WORK/advice.XXXXXXXX")
    {
        say "پروفایل انتخابی: $PROFILE"
        say 'وضعیت: فقط تشخیص و پیشنهاد؛ تغییرات قابل اعمال: صفر.'
        say 'تشخیص گلوگاه قطعی نیست؛ یک نمونه کوتاه یا شمارنده تجمعی کافی نیست.'
        if [[ $SERVICE == unknown || $SERVER_REGION == unknown || $USER_REGION == unknown ]]; then
            say 'اطلاعات سرویس یا جغرافیا ناقص است؛ حفظ تنظیمات موجود الزامی است.'
        fi
        case $PROFILE in
            iran)
                say 'اولویت ایران: اندازه‌گیری مسیر کاربران ایران و مسیر تونل به خارج به‌صورت جداگانه.'
                say 'اگر تونل دارید، آزمون انتهابه‌انتها و بررسی افت بسته دو سر تونل لازم است؛ افزایش بافر جای اصلاح مسیر نیست.' ;;
            international)
                say 'اولویت خارج: بررسی مسیر ورودی کاربران/سرور ایران و مسیر خروجی مجاز به‌صورت جداگانه.'
                say 'برای دانلود هم‌زمان، ظرفیت مشترک پورت و هزینه CPU رمزنگاری سنجیده شود؛ ping ظرفیت مسیر را تعیین نمی‌کند.' ;;
            *) say 'هنوز پروفایل انتخاب نشده است.' ;;
        esac
        awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2; ok=1}
            END {if(t && ok && a/t<0.10) print "نشانه فشار حافظه: MemAvailable کمتر از ۱۰٪؛ نیازمند نمونه‌برداری و بررسی برنامه/cgroup، نه افزایش بافر."}' /proc/meminfo
        say 'CPU: مصرف پایدار، CPU throttling و زمان پاسخ برنامه باید با هم سنجیده شوند.'
        say 'حافظه: PSI، محدودیت cgroup و روند Swap بررسی شوند؛ کمبود RAM با افزایش بافر درمان نمی‌شود.'
        say 'دیسک: PSI و فضای آزاد صرفاً نشانه‌اند؛ برای تشخیص تأخیر IO به نمونه‌برداری بیشتر نیاز است.'
        say 'شبکه: اتلاف ICMP ممکن است ناشی از محدودسازی پاسخ باشد؛ خطای رابط هم به‌تنهایی گلوگاه مسیر را ثابت نمی‌کند.'
        say 'برنامه: بدون معیار latency/error و شناخت سرویس، تشخیص گلوگاه برنامه ممکن نیست.'
        say 'BBR: فهرست الگوریتم‌های موجود فقط قابلیت فعلی را نشان می‌دهد؛ مناسب‌بودن نیازمند آزمون کنترل‌شده TCP است.'
        say 'صف، TCP و محدودیت فایل‌ها: هیچ مقدار عمومی توصیه نمی‌شود؛ ابتدا شواهد اشباع و محدودیت واقعی سرویس لازم است.'
        say 'MTU/DNS/IPv6/Swap/SSH/فایروال/TLS/تنظیمات سرویس دست‌نخورده باقی می‌مانند.'
        say 'IPv4: فقط آزمون‌های این ابزار محدود به IPv4 هستند؛ تغییر خروجی سرویس نیازمند شناخت نرم‌افزار و تونل است.'
        say 'چندکاربره: بدون تعداد اتصال فعال، ظرفیت واقعی و مصرف هر کاربر، ظرفیت قابل پشتیبانی مشخص نیست.'
        say 'تلگرام و اینستاگرام: کیفیت به پروتکل، مسیر، محدودیت ارائه‌دهنده و مقصد وابسته است؛ تنظیم ویژه تضمینی وجود ندارد.'
        say 'افزایش عملکرد اندازه‌گیری یا اثبات نشده است.'
    } > "$report"
    while IFS= read -r line; do printf '%s\n' "$line"; done < "$report"
    say "پیشنهادها: $report"
}

network_test() {
    local label=$1 dir rc=0
    have ping && have timeout || { say 'ping یا timeout موجود نیست؛ آزمون رد شد، نصب خودکار نداریم.'; return 0; }
    say 'این آزمون ۱۰ درخواست کوچک IPv4/ICMP دارد؛ آزمون حجیم یا سنجش پهنای باند نیست.'
    say 'فقط IP عددی پذیرفته می‌شود؛ پرس‌وجوی DNS نداریم. مقصد مجاز می‌تواند IPv4 عمومی مبدأ را ببیند.'
    ask 'IPv4 مقصد مجاز (خالی = صرف‌نظر): ' || return 0
    TARGET=$REPLY
    [[ -n $TARGET ]] || return 0
    if ! valid_ipv4 "$TARGET"; then
        say 'IPv4 عددی معتبر وارد کنید؛ دامنه، URL و IPv6 پذیرفته نمی‌شوند.'; return 0
    fi
    confirm 'اجازه ارسال همین آزمون به این مقصد را می‌دهید؟' || return 0
    dir=$(mktemp -d "$WORK/ping-${label}.XXXXXXXX")
    # Keep the target out of saved output (ping normally prints resolved addresses).
    # timeout bounds the full run; no DNS lookups and no bulk transfer.
    timeout --signal=TERM --kill-after=2s 20s ping -4 -n -c "$PING_COUNT" -i 1 -W 2 -w 15 -s 56 -- "$TARGET" 2>&1 |
        awk '/packets transmitted/ || /^(rtt|round-trip)/ {print; found=1}
             END {if(!found) print "No ICMP summary; check permission, DNS, routing or ICMP filtering."}' > "$dir/summary.txt" || rc=$?
    printf 'exit_status=%s\n' "$rc" >> "$dir/summary.txt"
    while IFS= read -r line; do printf '%s\n' "$line"; done < "$dir/summary.txt"
    say 'mdev تقریب پراکندگی RTT است، نه اندازه‌گیری دقیق jitter برنامه. موفقیت ping تضمین سلامت سرویس نیست.'
    say "نتیجه: $dir/summary.txt"
}

comparison() {
    local rc=0 difference
    if [[ -z $BEFORE ]]; then
        BEFORE=$(mktemp "$WORK/before.XXXXXXXX")
        snapshot "$BEFORE"
        network_test before
        say 'خط مبنا ثبت شد. برای نمونه دوم دوباره همین گزینه را انتخاب کنید.'
        say 'اسکریپت تغییری انجام نمی‌دهد؛ این مقایسه دو نمونه زمانی است، نه اثبات اثر توربو.'
    else
        AFTER=$(mktemp "$WORK/after.XXXXXXXX")
        snapshot "$AFTER"
        network_test after
        difference=$(mktemp "$WORK/comparison.XXXXXXXX")
        diff -u "$BEFORE" "$AFTER" > "$difference" || rc=$?
        [[ $rc -le 1 ]] || { say 'مقایسه ناموفق بود.'; return 0; }
        say "اختلاف نمونه‌ها: $difference"
        say 'برای مقایسه شبکه، مقصد، شرایط بار و سمت آزمون باید یکسان باشند؛ نتایج خودکار بهبود اعلام نمی‌کنند.'
    fi
}

main() {
    check_os
    [[ -t 0 && -t 1 ]] || fail 'این نسخه به ترمینال تعاملی نیاز دارد.'
    select_profile || return 0
    init_reports
    say 'Safe Turbo Advisor 1.1 — نسخه ایمن تشخیصی؛ آزمون فقط IPv4'
    say 'IPv6 سرور غیرفعال نمی‌شود؛ این ابزار مسیر ترافیک برنامه یا کاربران را تغییر نمی‌دهد.'
    say 'هیچ تنظیم، فایل کاربر، دیتابیس یا لاگی تغییر/حذف نمی‌شود؛ فقط گزارش جدید ساخته می‌شود.'
    say 'بکاپ تنظیمات جای بکاپ داده نیست؛ پیش از هر تغییر آینده Snapshot معتبر و کنسول اضطراری داشته باشید.'
    local choice file
    while true; do
        printf '\n%s\n' '۱) بررسی وضعیت سرور' '۲) توربو ایران — فقط تحلیل' '۳) توربو خارج — فقط تحلیل' '۴) نمایش پیشنهادها بدون اعمال' '۵) آزمون قبل و بعد' '۶) بازگردانی تنظیمات' '۷) خروج'
        ask 'انتخاب: ' || break
        choice=$REPLY
        case $choice in
            1|۱) file=$(mktemp "$WORK/status.XXXXXXXX"); snapshot "$file" ;;
            2|۲) PROFILE=iran; context; recommend ;;
            3|۳) PROFILE=international; context; recommend ;;
            4|۴) recommend ;;
            5|۵) comparison ;;
            6|۶) say 'هیچ تنظیمی توسط این نسخه اعمال نشده است؛ بازگردانی یا تایمر بازگشت لازم نیست. تغییرات ابزارهای دیگر بازگردانی نمی‌شوند.' ;;
            7|۷) break ;;
            *) say 'گزینه نامعتبر است.' ;;
        esac
    done
    say "گزارش‌ها باقی می‌مانند: $WORK"
}
main "$@"
