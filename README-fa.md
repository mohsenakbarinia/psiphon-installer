# MAXNET6G — نصب و مدیریت Psiphon روی Ubuntu

اسکریپت `install-psiphon.sh` یک نصب‌کننده و مدیر **چند-instance** برای
`psiphon-tunnel-core` است. این اسکریپت برای هر کشور یک سرویس `systemd` و یک
پروکسی محلی **SOCKS5** و **HTTP** روی `127.0.0.1` می‌سازد؛ بدون نیاز به ویرایش
دستی و کاملاً idempotent (اجرای تکراری مشکلی ایجاد نمی‌کند).

---

## معرفی

- هر کشور = یک instance از `psiphon-tunnel-core` با `EgressRegion` مخصوص خودش.
- هر instance یک سرویس systemd مستقل با نام `psiphon-<CC>.service` دارد.
- هر instance یک پورت SOCKS5 و یک پورت HTTP محلی (فقط روی loopback) دارد.
- پورت هر کشور به‌صورت پایدار در فایل mapping ذخیره می‌شود و پس از اجرای مجدد
  تغییر نمی‌کند.
- نصب، به‌روزرسانی، تست سلامت و حذف همه خودکار هستند.

## معماری

```
COUNTRIES=(US DE JP ...)
   │
   ├─ /etc/psiphon/US.json        ← کانفیگ JSON هر کشور (EgressRegion=US)
   ├─ psiphon-US.service          ← سرویس systemd، User=psiphon
   │     ExecStart=/opt/psiphon/bin/psiphon-tunnel-core -config /etc/psiphon/US.json
   │
   ├─ SOCKS5  → 127.0.0.1:10800+  (پایه 10800)
   └─ HTTP    → 127.0.0.1:10900+  (پایه 10900)
```

هر instance مستقل بالا می‌آید و خروجی هر پورت، IP مربوط به همان کشور است
(توسط شبکه Psiphon انتخاب می‌شود).

## پیش‌نیازها

- Ubuntu نسخه‌های صریحاً پشتیبانی‌شده: **20.04 / 22.04 / 24.04 / 25.04 / 25.10 / 26.04**
  (سایر توزیع‌های مبتنی بر Ubuntu/Debian فقط با هشدار ادامه می‌دهند).
- **Bash نسخه 4.4 یا بالاتر** و **systemd**.
- معماری **amd64** یا **arm64**.
- پیش‌نیازهای نرم‌افزاری (`curl`, `jq`, `wget`, `ufw`, `iproute2`, ...) در صورت
  نبود، خودکار توسط اسکریپت نصب می‌شوند.

## نصب سریع (یک‌خطی)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/install-psiphon.sh)"
```

> ⚠️ **مهم:** قبل از اجرا، `YOUR_USERNAME/YOUR_REPO` را با نام کاربری و نام
> ریپازیتوری خودتان در GitHub جایگزین کنید. این URL باید به **آدرس raw (خام)**
> فایل `install-psiphon.sh` در ریپازیتوری منتشرشده اشاره کند، نه به صفحه HTML
> گیت‌هاب.

## نصب محلی

اگر فایل را دانلود کرده‌اید، [فایل نصب محلی `install-psiphon-v3_2_0-fixed.md`](install-psiphon-v3_2_0-fixed.md) را در GitHub کنار README قرار دهید؛ سپس آن را با نام اجرایی دلخواه (برای نمونه `install-psiphon.sh`) ذخیره کنید و اجرا کنید:

```bash
sudo bash install-psiphon.sh
```

نصب کاملاً خودکار است: پیش‌نیازها نصب، باینری دانلود، کانفیگ‌ها و سرویس‌های
systemd ساخته و تست سلامت انجام می‌شود.

## اجرای dry-run

برای دیدن کارهایی که اسکریپت انجام می‌دهد، **بدون اعمال هیچ تغییری**:

```bash
sudo bash install-psiphon.sh --dry-run
```

## مدیریت

گزینه‌های اصلی خط فرمان:

```text
--install  --update  --status  --dry-run  --uninstall [--yes]
--turbo  --turbo-revert  --net-doctor  --net-doctor-revert  --bot-setup  --help
```

```bash
sudo bash install-psiphon.sh --status      # وضعیت سرویس‌ها و سلامت instanceها
sudo bash install-psiphon.sh --update      # به‌روزرسانی با rollback خودکار
```

> برای توضیح دقیق هر گزینه (turbo، net-doctor، bot-setup و...) حتماً اجرا کنید:
>
> ```bash
> ./install-psiphon.sh --help
> ```

## پورت‌ها و مسیرها

| مورد | مقدار / مسیر |
|---|---|
| پورت SOCKS5 (پایه) | `10800` و بعدی |
| پورت HTTP (پایه) | `10900` و بعدی |
| فایل کانفیگ هر کشور | `/etc/psiphon/<CC>.json` |
| فایل mapping متنی | `/etc/psiphon/mapping.txt` |
| فایل mapping JSON | `/etc/psiphon/mapping.json` |
| باینری | `/opt/psiphon/bin/psiphon-tunnel-core` |
| سرویس systemd | `psiphon-<CC>.service` |
| لاگ نصب | `/var/log/psiphon-install.log` |
| داده و لاگ‌های پروژه | `/var/log/psiphon` |

## پورت‌ها و اتصال

- Listener **فقط روی `127.0.0.1` / loopback** bind می‌شود؛ دسترسی بیرونی
  **عمداً بسته** است و bind روی `0.0.0.0` (`any`) در اسکریپت ممنوع شده است.
- اگر `ufw` فعال باشد، ruleهای deny برای رنج پورت‌ها اضافه می‌شود؛ اما
  اسکریپت **`ufw` را خودکار enable نمی‌کند** (تا اتصال SSH قطع نشود).
- برای استفاده از پروکسی، برنامه‌تان باید روی همان سرور اجرا شود یا از طریق
  تونل SSH به آن وصل شوید.

## تست

نمونه تست یک instance با curl از SOCKS:

```bash
curl --socks5-hostname 127.0.0.1:10800 https://ipinfo.io/json
```

پورت دقیق هر کشور را از `/etc/psiphon/mapping.txt` یا `mapping.json` بگیرید.
تست داخلی اسکریپت سخت‌گیرانه است و در فیلد پاسخ وجود `ip` و `country` را
انتظار دارد؛ اگر کشور پاسخ با کد کشور instance نخواند، instance fail محسوب
و پس از ریستارت دوباره تست می‌شود.

## لاگ و عیب‌یابی

```bash
# لاگ نصب
sudo tail -f /var/log/psiphon-install.log

# لاگ زنده یک کشور از journal
journalctl -u psiphon-US.service -f

# وضعیت همه سرویس‌ها
sudo bash install-psiphon.sh --status
```

- لاگ‌های سرویس‌ها در **journal** هستند (SyslogIdentifier: `psiphon-<CC>`).
- داده‌ها و لاگ‌های پروژه در `/var/log/psiphon` نگهداری می‌شوند.

## تنظیم کشورها

کشورها در آرایه `COUNTRIES` در بالای اسکریپت تعریف می‌شوند و باید **کد
دوحرفی ISO با حروف بزرگ** باشند:

```bash
COUNTRIES=(AT AU BE BG BR CA CH CZ DE DK EE ES FI FR GB HU IE IN IT JP LV NL NO PL RO RS SE SG SK US)
```

- کشور اضافه/حذف کنید و نصب را دوباره اجرا کنید؛ پورت کشورهای قبلی حفظ می‌شود.
- mapping نهایی هر کشور در `/etc/psiphon/mapping.txt` و `/etc/psiphon/mapping.json`
  نوشته می‌شود (این فایل‌ها را دستی ویرایش نکنید؛ تولید خودکار هستند).

## امنیت

- همه پورت‌ها فقط روی loopback شنیده می‌شوند؛ از بیرون قابل دسترسی نیستند.
- سرویس‌ها با کاربر سیستمی اختصاصی `psiphon` و سخت‌سازی systemd
  (`NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, ...) اجرا می‌شوند.
- اگر `ufw` فعال باشد، ruleهای deny با کامنت `psiphon-local-only` اضافه می‌شود.
- UFW هرگز به‌طور خودکار فعال نمی‌شود.

## محدودیت‌ها

- این اسکریپت **Xray، Backhaul، TUN/TAP، policy routing، NAT، reverse tunnel
  یا انتقال کل ترافیک سیستم را پیاده‌سازی نمی‌کند**؛ خروجی آن فقط پروکسی
  محلی SOCKS5/HTTP روی loopback است.
- **IP خروجی ثابت نیست** و توسط شبکه Psiphon انتخاب می‌شود.
- قابلیت‌هایی مثل ping radar، daily test، health report و auto-heal به
  **تنظیمات ربات تلگرام** وابسته‌اند و بخشی از نصب پایه تضمینی نیستند.

## حذف

```bash
sudo bash install-psiphon.sh --uninstall          # با تأیید
sudo bash install-psiphon.sh --uninstall --yes    # بدون سؤال
```

حذف شامل سرویس‌های systemd، فایل‌ها، mapping و کاربر `psiphon` است.

## مجوز / یادداشت

- این پروژه صرفاً یک نصب‌کننده و مدیر برای باینری رسمی
  `psiphon-tunnel-core` است؛ سرویس تونل توسط Psiphon Inc. ارائه می‌شود.
- استفاده مسئولانه و مطابق قوانین محل خودتان بر عهده کاربر است.
- برای جزئیات هر گزینه، همیشه `./install-psiphon.sh --help` را ببینید.

## منابع داخل اسکریپت

بخش‌های اصلی `install-psiphon.sh` برای مطالعه بیشتر:

- خطوط **3-7**: سربرگ و معرفی کلی اسکریپت
- خطوط **24-52**: بخش متغیرهای قابل ویرایش (COUNTRIES، پورت‌ها، مقادیر سایفون)
- خطوط **125-131**: سیستم‌عامل‌های پشتیبانی‌شده و پیش‌نیازها
- خطوط **153-185**: usage و پارس آرگومان‌های خط فرمان
- خطوط **359-392**: بررسی معماری، سیستم‌عامل، Bash و systemd
- خطوط **410-458**: اعتبارسنجی پیکربندی و نصب پیش‌نیازها
- خطوط **541-627**: تخصیص پایدار پورت‌ها و نوشتن mapping
- خطوط **630-719**: ساخت کانفیگ JSON هر کشور و سرویس systemd
- خطوط **774-840**: تست سلامت موازی و ریستارت خراب‌ها
- خطوط **865-897**: فایروال (UFW) و تأیید listen فقط روی 127.0.0.1
