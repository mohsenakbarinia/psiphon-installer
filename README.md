# psiphon-multi-region

> 🇮🇷 فارسی | 🇬🇧 English below

خروجی سرور لینوکسی (مثلاً VPS آلمان) را از طریق **Psiphon** به کشورهای مختلف (US, NL, GB, FR, JP, ...) ببرید.
هر کشور = یک اینستنس Psiphon با پورت SOCKS5 و HTTP جدا + یک inbound در **Xray** برای مسیریابی راحت.

```
کلاینت/اپ ──► Xray inbound 127.20.0.1:20001 ──► Psiphon[US] SOCKS 127.20.0.1:10801 ──► اینترنت (IP آمریکا)
            ──► Xray inbound 127.20.0.1:20002 ──► Psiphon[NL] SOCKS 127.20.0.1:10802 ──► اینترنت (IP هلند)
```

---

## ⚠️ قبل از هر چیز: کانفیگ شبکه Psiphon

طبق مستندات رسمی `psiphon-tunnel-core`، مقادیر `PropagationChannelId`، `SponsorId`،
`RemoteServerListURLs` و `RemoteServerListSignaturePublicKey` **توسط Psiphon Inc. ارائه می‌شوند**
(تماس: `developer-support@psiphon.ca`). این پروژه این مقادیر را **حدس نمی‌زند** و در قالب با
`TODO_VERIFY_*` مشخص شده‌اند. تا وقتی جایگزین نشوند، نصب کامل انجام می‌شود ولی سرویس‌های Psiphon اجرا نمی‌شوند.

یک فایل مثل `psiphon-network.json` بسازید (مقادیر واقعی خودتان):

```json
{
  "PropagationChannelId": "YOUR_PROPAGATION_CHANNEL_ID",
  "SponsorId": "YOUR_SPONSOR_ID",
  "RemoteServerListSignaturePublicKey": "YOUR_PUBLIC_KEY",
  "RemoteServerListURLs": [
    { "URL": "BASE64_OF_YOUR_SERVER_LIST_URL", "OnlyAfterAttempts": 0, "SkipVerify": false }
  ]
}
```

> فیلد `URL` در `RemoteServerListURLs` به صورت **base64** است (نیاز به راستی‌آزمایی با نسخه فعلی Psiphon).
> تبدیل: `printf '%s' 'https://example/server_list' | base64 -w0`

سپس یکی از این روش‌ها:

```bash
# هنگام نصب
bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/install.sh) --psiphon-config /root/psiphon-network.json --yes
# یا بعد از نصب
sudo psictl import-config /root/psiphon-network.json
# یا با متغیر محیطی (بدون ذخیره در ریپو)
PSIPHON_PROPAGATION_CHANNEL_ID=... PSIPHON_SPONSOR_ID=... PSIPHON_RSL_PUBKEY=... PSIPHON_RSL_URL=https://... \
  bash install.sh --yes
```

---

## پیش‌نیازها

| مورد | مقدار |
|---|---|
| سیستم‌عامل | Ubuntu 24.04 LTS (فقط) |
| معماری | x86_64 |
| دسترسی | root (یا `sudo -i`) |
| دیسک | حداقل 500MB آزاد |
| اینترنت | دسترسی به github.com |

## نصب یک‌خطی

> قبل از انتشار، در `install.sh` مقدار `REPO_RAW_BASE` را از `USERNAME/REPO` به ریپوی خودتان تغییر دهید
> (و همین را در این README هم جایگزین کنید).

```bash
# تعاملی (به‌عنوان root)
bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/install.sh)

# غیرتعاملی
bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/install.sh) --regions "US,NL,GB,FR,JP" --yes

# اگر root نیستید (process substitution با sudo کار نمی‌کند):
curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/install.sh | sudo bash -s -- --regions "US,NL" --yes
```

## پارامترها

| پارامتر | پیش‌فرض | توضیح |
|---|---|---|
| `--regions "US,NL,..."` | 20 کشور پیش‌فرض | کدهای ISO 3166-1 alpha-2 |
| `--instances N` | `20` | N کشور اول از لیست پیش‌فرض (اگر `--regions` ندهید) |
| `--socks-base N` | `10800` | اینستنس i ← `N+i` |
| `--http-base N` | `10900` | اینستنس i ← `N+i` |
| `--xray-base N` | `20000` | inbound Xray برای اینستنس i ← `N+i` |
| `--bind-mode` | `dummy` | `dummy`=127.20.0.1، `loopback`=127.0.0.1، `any`=0.0.0.0 ⚠️ |
| `--listen-any` | - | معادل `--bind-mode any` (پروکسی باز! فقط با فایروال) |
| `--psiphon-config FILE` | - | JSON مقادیر شبکه Psiphon |
| `--skip-upgrade` | - | اجرا نکردن `apt upgrade` |
| `--wait-timeout SEC` | `180` | صبر برای بالا آمدن تونل‌ها |
| `--yes` / `-y` | - | بدون سوال |
| `--update` | - | نصب مجدد با حفظ تنظیمات |
| `--status` | - | نمایش وضعیت |
| `--uninstall` | - | حذف کامل |

لیست پیش‌فرض: `US,NL,GB,FR,JP,CA,DE,SE,CH,SG,AT,BE,ES,IT,NO,DK,FI,PL,RO,IN`
(در دسترس بودن هر کشور به شبکه Psiphon بستگی دارد؛ نیاز به راستی‌آزمایی).

ایندکس‌ها از 1 شروع می‌شوند: اولین کشور ← SOCKS `10801`، HTTP `10901`، Xray `20001`.

## استفاده

```bash
psictl list                       # کشورها و پورت‌ها
psictl status                     # وضعیت سرویس‌ها
psictl test                       # IP و کشور خروجی همه (✔ / ⚠ / ✘)
psictl test US
sudo psictl add-region CA
sudo psictl remove-region FR
psictl logs US                    # لاگ زنده یک کشور
sudo psictl restart NL
sudo psictl update
sudo psictl uninstall
```

### curl

```bash
curl --socks5-hostname 127.20.0.1:10801 https://ipinfo.io/json
curl -x http://127.20.0.1:10901 https://ipinfo.io/json
curl --socks5-hostname 127.20.0.1:20001 https://ipinfo.io/json   # از طریق Xray
```

### Xray

فایل تولیدشده: `/opt/psiphon-multi-region/config/xray.json`. برای هر کشور:
- inbound با tag `in-CC` روی `127.20.0.1:(20000+i)`
- outbound با tag `out-CC` از نوع socks به `127.20.0.1:(10800+i)`
- rule: `inboundTag: in-CC → outboundTag: out-CC`

اگر Xray اصلی خودتان (مثلاً VLESS برای کاربران) روی همین سرور است، کافیست در آن یک outbound socks
به پورت کشور موردنظر اضافه کنید و بر اساس `user`/`inboundTag` مسیریابی کنید:

```json
{
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "via-US", "protocol": "socks",
      "settings": { "servers": [ { "address": "127.20.0.1", "port": 10801 } ] } }
  ],
  "routing": {
    "rules": [
      { "type": "field", "user": ["us-user@example.com"], "outboundTag": "via-US" }
    ]
  }
}
```

## عیب‌یابی

| مشکل | راه‌حل |
|---|---|
| `base config: TODO_VERIFY` | بخش «کانفیگ شبکه Psiphon» بالا |
| `/dev/fd/63: No such file` با sudo | با `sudo -i` root شوید یا از `curl ... \| sudo bash -s --` استفاده کنید |
| ✘ FAIL در تست | `psictl logs CC`؛ ممکن است Psiphon برای آن کشور سرور نداشته باشد یا هنوز در حال اتصال باشد |
| ⚠ MISMATCH | GeoIP سایت تست با Psiphon فرق دارد؛ با `PSICTL_TEST_URL=https://ifconfig.co/json psictl test` مقایسه کنید |
| `psi0` ساخته نشد | installer خودکار به `loopback` برمی‌گردد؛ `lsmod \| grep dummy` و `journalctl -u psiphon-net` |
| پورت اشغال است | `ss -ltnp \| grep 108`؛ با `--socks-base/--http-base` پایه دیگری بدهید |
| ipinfo rate-limit | `PSICTL_TEST_URL` را عوض کنید |
| لاگ نصب | `/var/log/psiphon-installer.log` |

## حذف

```bash
sudo psictl uninstall            # یا
bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/install.sh) --uninstall --yes
sudo /opt/psiphon-multi-region/scripts/uninstall.sh --yes --purge-logs
```

## ⚖️ هشدار حقوقی

- استفاده از شبکه Psiphon تابع [شرایط استفاده Psiphon](https://psiphon.ca/en/license.html) است؛ اجرای کلاینت روی سرور و
  اشتراک آن با دیگران ممکن است مجاز نباشد (**نیاز به راستی‌آزمایی** با Psiphon).
- قوانین کشور محل سرور، کشور شما و شرایط ارائه‌دهنده VPS را رعایت کنید.
- هرگز پروکسی بدون احراز هویت روی `0.0.0.0` باز نکنید.
- این نرم‌افزار «همان‌طور که هست» (MIT) ارائه می‌شود و مسئولیت استفاده با کاربر است.

---

# English

Route a Linux VPS's outbound traffic through **Psiphon** so it egresses from a chosen country.
Each country is its own `psiphon-tunnel-core` instance (`psiphon@CC.service`) exposing a local SOCKS5 and HTTP proxy,
plus an **Xray** inbound per country routed by `inboundTag`.

## Psiphon network config (required)

Per the official `psiphon-tunnel-core` docs, `PropagationChannelId`, `SponsorId`, `RemoteServerListURLs` and
`RemoteServerListSignaturePublicKey` are supplied by Psiphon Inc. (`developer-support@psiphon.ca`).
They are **not guessed** here: the template contains `TODO_VERIFY_*` placeholders, and Psiphon instances will not
start until you supply real values via `--psiphon-config FILE`, `sudo psictl import-config FILE`,
or env vars `PSIPHON_PROPAGATION_CHANNEL_ID`, `PSIPHON_SPONSOR_ID`, `PSIPHON_RSL_PUBKEY`, `PSIPHON_RSL_URL`.

## Requirements
Ubuntu 24.04 x86_64, root, 500MB free disk, access to github.com.

## Install
Replace `USERNAME/REPO` in `install.sh` (`REPO_RAW_BASE`) and in this README, then:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/install.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/install.sh) --regions "US,NL,GB,FR,JP" --yes
```

See the parameter table above. Re-running the installer is safe (idempotent): regions, port indices and
Psiphon values are preserved; binaries are refreshed.

## Layout on the server

```
/opt/psiphon-multi-region/
├── bin/        psiphon-tunnel-core, xray, geoip.dat, geosite.dat
├── config/     settings.env, regions.conf, base.json, instances/CC.json, xray.json, iso3166.txt
├── data/       CC/ (Psiphon DataRootDirectory per instance), .health/
├── logs/       psiphon-CC.log, xray.log, health.log
├── scripts/    uninstall.sh
└── templates/  psiphon.config.tpl.json, xray.config.tpl.json
/usr/local/bin/psictl
/etc/systemd/system/{psiphon@.service, psiphon-xray.service, psiphon-net.service, psiphon-healthcheck.{service,timer}}
/etc/logrotate.d/psiphon-multi-region
```

## Why a dummy interface?
Psiphon's `ListenInterface` takes an **interface name** and binds to that interface's IPv4 (empty = 127.0.0.1,
`any` = 0.0.0.0). An alias on `lo` would still resolve to 127.0.0.1, so the installer creates dummy interface `psi0`
holding `127.20.0.1/32`. If that fails, it falls back to `127.0.0.1`. (Needs verification against the Psiphon version you run.)

## Disclaimer
Use of the Psiphon network is subject to Psiphon's terms. Comply with local laws and your VPS provider's ToS.
Provided "as is" under the MIT license.
