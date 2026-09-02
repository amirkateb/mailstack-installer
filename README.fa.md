# MailStack Installer

[![English README](https://img.shields.io/badge/README-English-blue)](README.md)
[![زبان فارسی](https://img.shields.io/badge/زبان-فارسی-green)](#)
[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Bash](https://img.shields.io/badge/Bash-Installer-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![GitHub](https://img.shields.io/badge/GitHub-amirkateb-181717?logo=github)](https://github.com/amirkateb)

> 🇬🇧 **English documentation:** [README.md](README.md)

یک نصب‌کننده تعاملی و مناسب محیط Production برای راه‌اندازی **Stalwart Mail Server + Bulwark Webmail** روی **Ubuntu 24.04 LTS**.

این پروژه بخش بزرگی از مراحل مورد نیاز برای راه‌اندازی یک Mail Server مدرن را به‌صورت خودکار انجام می‌دهد؛ از جمله بررسی DNS، نصب Docker و مسیرهای جایگزین، TLS، تنظیم Nginx، فایروال و راهنمای تنظیم SPF، DKIM و DMARC.

> ساخته شده توسط **amirmohammad katebsaber**

---

## معرفی

MailStack Installer یک استک کامل ایمیل را با استفاده از اجزای زیر راه‌اندازی می‌کند:

- **Stalwart Mail Server**
- **Bulwark Webmail**
- **Nginx**
- **Let's Encrypt**
- **Docker / Docker Compose**
- **Ubuntu 24.04 LTS**

اسکریپت، کاربر را مرحله‌به‌مرحله در فرایند راه‌اندازی همراهی می‌کند، پیش‌نیازهای مهم را بررسی می‌کند و اگر با یک خطای حیاتی مواجه شود، با نمایش علت دقیق مشکل متوقف می‌شود.

---

# معماری

```text
                         Internet
                            │
              ┌─────────────┴─────────────┐
              │                           │
        SMTP / IMAP                  HTTPS / Web
              │                           │
              ▼                           ▼
          Stalwart                      Nginx
                                             │
                               ┌─────────────┴─────────────┐
                               │                           │
                     mail.example.com          webmail.example.com
                               │                           │
                          Stalwart UI                  Bulwark
                          JMAP / API                   Webmail
```

پورت‌های عمومی:

```text
25    SMTP
465   SMTPS
587   SMTP Submission
993   IMAPS
80    HTTP
443   HTTPS
```

سرویس‌های داخلی:

```text
127.0.0.1:8080   Stalwart HTTP/JMAP
127.0.0.1:3000   Bulwark Webmail
```

---

# قابلیت‌ها

## نصب تعاملی

Installer دامنه اصلی را از شما می‌گیرد و hostnameهای موردنیاز را به‌صورت خودکار می‌سازد.

```text
Domain:
example.com

Mail hostname:
mail.example.com

Webmail hostname:
webmail.example.com
```

## بررسی DNS

قبل از نصب Mail Server موارد زیر بررسی می‌شوند:

- IPv4 عمومی سرور
- A Record مربوط به Mail Server
- A Record مربوط به Webmail
- MX
- PTR / Reverse DNS
- تطابق hostname و IP

اگر یک رکورد ضروری اشتباه باشد، Installer دقیقاً اعلام می‌کند چه چیزی باید اصلاح شود و سپس به‌صورت امن متوقف می‌شود.

## SPF، DKIM و DMARC

MailStack Installer مقدار DKIM را حدس نمی‌زند.

بعد از اینکه Stalwart دامنه و کلیدهای امضای ایمیل را ایجاد کرد، اسکریپت رکوردهای تولیدشده توسط خود Stalwart را دریافت می‌کند و همان مقادیر واقعی را برای اضافه‌کردن به DNS نمایش می‌دهد.

این رکوردها می‌توانند شامل موارد زیر باشند:

- SPF
- DKIM
- DMARC
- MX
- MTA-STS
- Autoconfiguration
- سایر رکوردهای مورد نیاز Stalwart

## نصب Docker با روش‌های جایگزین

مسیر اصلی:

```bash
apt install docker.io docker-compose-v2
```

قبل از ادامه، Docker و Docker Compose بررسی می‌شوند.

اگر روش اصلی شکست بخورد، Installer می‌تواند مسیرهای جایگزین را امتحان کند.

## پشتیبانی از شبکه‌های محدود

MailStack Installer برای سرورهایی که دسترسی محدود یا ناپایداری به repositoryها و registryهای بین‌المللی دارند نیز در نظر گرفته شده است.

قابلیت‌ها:

- بررسی Repositoryهای Ubuntu
- تشخیص Mirrorهای غیرقابل دسترس
- تست Mirrorهای جایگزین
- Backup گرفتن از تنظیمات Repository
- بررسی Docker Hub
- تنظیم Docker Registry Mirror
- بررسی GitHub Container Registry
- استفاده از نصب Native برای Bulwark در صورت نیاز

## مسیر جایگزین نصب Bulwark

Image رسمی Bulwark روی:

```text
ghcr.io
```

قرار دارد.

Installer ابتدا اجرا می‌کند:

```bash
docker pull ghcr.io/bulwarkmail/webmail:latest
```

اگر GHCR در دسترس نباشد، Bulwark می‌تواند با این روش نصب شود:

```text
Node.js
npm
systemd
```

## TLS خودکار

Certificateهای Let's Encrypt برای:

```text
mail.example.com
webmail.example.com
```

دریافت می‌شوند.

Certificateها برای HTTPS و پروتکل‌های Mail استفاده می‌شوند.

همچنین یک Certbot deployment hook برای همگام‌سازی Certificate مورد استفاده Stalwart پس از Renewal ایجاد می‌شود.

## Reverse Proxy با Nginx

Stalwart:

```text
https://mail.example.com
        │
        ▼
      Nginx
        │
        ▼
127.0.0.1:8080
        │
        ▼
    Stalwart
```

Bulwark:

```text
https://webmail.example.com
        │
        ▼
      Nginx
        │
        ▼
127.0.0.1:3000
        │
        ▼
     Bulwark
```

## تنظیم فایروال

پورت‌های عمومی:

```text
SSH
25
80
443
465
587
993
```

پورت‌های داخلی:

```text
3000
8080
```

## مدیریت خطا

اگر یک عملیات حیاتی شکست بخورد، Installer ادامه نمی‌دهد و اطلاعاتی مانند این‌ها را نمایش می‌دهد:

- مرحله نصب
- فرمان ناموفق
- شماره خط
- علت خطا
- مسیر فایل Log

---

# پیش‌نیازها

حداقل منابع پیشنهادی:

```text
Operating System: Ubuntu Server 24.04 LTS
CPU:              2 vCPU
RAM:              2-4 GB
Storage:          40+ GB SSD
IPv4:             Static public address
Access:           Root or sudo
```

همچنین نیاز دارید به:

- دامنه
- دسترسی مدیریت DNS
- امکان تنظیم PTR / Reverse DNS
- باز بودن Port 25 ورودی
- باز بودن Port 25 خروجی

---

# نصب

## روش اول — Clone کردن Repository

```bash
ssh root@YOUR_SERVER_IP
apt update
apt install -y git
git clone https://github.com/amirkateb/mailstack-installer.git
cd mailstack-installer
chmod +x install-mailstack.sh
./install-mailstack.sh
```

## روش دوم — دانلود مستقیم Installer

```bash
curl -fsSL \
https://raw.githubusercontent.com/amirkateb/mailstack-installer/main/install-mailstack.sh \
-o install-mailstack.sh

chmod +x install-mailstack.sh
sudo ./install-mailstack.sh
```

---

# مراحل نصب

```text
1. بررسی سیستم
2. دریافت دامنه
3. تشخیص IP عمومی
4. نمایش DNS اولیه
5. بررسی A Recordها
6. بررسی MX
7. بررسی PTR
8. تست SMTP خروجی
9. بررسی Repositoryهای Ubuntu
10. نصب Docker
11. تست Docker Registry
12. نصب Stalwart
13. تنظیم Stalwart
14. نصب Bulwark
15. نصب Nginx
16. دریافت Let's Encrypt
17. تنظیم TLS برای SMTP و IMAP
18. دریافت DNS Zone از Stalwart
19. بررسی SPF / DKIM / DMARC
20. Health Check نهایی
```

---

# تنظیم اولیه DNS

فرض کنید:

```text
Domain: example.com
Server IPv4: 203.0.113.10
```

رکورد Mail:

```text
Type: A
Name: mail
Value: 203.0.113.10
```

رکورد Webmail:

```text
Type: A
Name: webmail
Value: 203.0.113.10
```

MX:

```text
Type: MX
Name: @
Priority: 10
Value: mail.example.com
```

---

# Reverse DNS

در پنل VPS Provider باید PTR را تنظیم کنید:

```text
203.0.113.10 → mail.example.com
```

در جهت برعکس نیز:

```text
mail.example.com → 203.0.113.10
```

PTR صحیح نقش مهمی در اعتبار Mail Server و تحویل ایمیل دارد.

---

# کاربران Cloudflare

اگر DNS دامنه روی Cloudflare است، hostname مربوط به Mail Server باید معمولاً روی:

```text
DNS Only
```

باشد.

پیشنهاد هنگام نصب:

```text
mail.example.com       DNS Only
webmail.example.com    DNS Only
```

SMTP و IMAP را از Proxy معمولی Cloudflare عبور ندهید.

---

# بعد از نصب

پنل مدیریت Stalwart:

```text
https://mail.example.com/admin
```

Webmail:

```text
https://webmail.example.com
```

---

# تنظیم Mail Client

## IMAP

```text
Server:         mail.example.com
Port:           993
Security:       SSL/TLS
Username:       user@example.com
Authentication: Password
```

## SMTP

```text
Server:         mail.example.com
Port:           465
Security:       SSL/TLS
Username:       user@example.com
Authentication: Password
```

یا:

```text
Port:     587
Security: STARTTLS
```

---

# تست Deliverability

بعد از نصب، برای Gmail، Outlook و Yahoo ایمیل آزمایشی بفرستید.

در حالت ایده‌آل:

```text
SPF:   PASS
DKIM:  PASS
DMARC: PASS
```

باشد.

PASS بودن این موارد تضمین نمی‌کند که ایمیل حتماً وارد Inbox شود.

اعتبار IP، اعتبار دامنه، حجم ارسال، Complaint Rate، محتوا، PTR و Blacklistها نیز مؤثر هستند.

---

# دستورات کاربردی

Stalwart:

```bash
systemctl status stalwart
systemctl restart stalwart
journalctl -u stalwart -f
```

Docker:

```bash
systemctl status docker
docker ps
docker logs -f bulwark
```

Nginx:

```bash
nginx -t
systemctl reload nginx
```

شبکه:

```bash
ss -lntp
```

تست Port 25 خروجی:

```bash
nc -vz -w 8 gmail-smtp-in.l.google.com 25
```

DNS:

```bash
dig +short A mail.example.com
dig +short MX example.com
dig -x YOUR_SERVER_IP +short
dig TXT example.com
dig TXT _dmarc.example.com
```

TLS:

```bash
openssl s_client -connect mail.example.com:993 -servername mail.example.com
openssl s_client -connect mail.example.com:465 -servername mail.example.com
```

---

# بروزرسانی Bulwark

در نصب Docker:

```bash
cd /opt/bulwark
docker compose pull
docker compose up -d
docker compose ps
```

---

# Backup

مسیرهای مهم:

```text
/etc/stalwart
/var/lib/stalwart
/etc/nginx
/etc/letsencrypt
/opt/bulwark
```

همچنین Docker Volumeهای مرتبط را Backup بگیرید.

حداقل یک Backup باید خارج از خود Mail Server نگهداری شود.

---

# توصیه‌های امنیتی

- Ubuntu را به‌روز نگه دارید
- Stalwart را به‌روز نگه دارید
- Bulwark را به‌روز نگه دارید
- Docker را به‌روز نگه دارید
- از Passwordهای قوی استفاده کنید
- در صورت امکان MFA را فعال کنید
- Logها را بررسی کنید
- Disk Usage را مانیتور کنید
- Backup منظم داشته باشید
- پورت‌های داخلی را Public نکنید
- ارسال‌های غیرعادی SMTP را بررسی کنید
- Rate Limit مناسب تنظیم کنید
- هرگز Open Relay ایجاد نکنید

---

# رفع مشکلات

## Docker Pull کار نمی‌کند

```bash
docker pull hello-world
docker pull ghcr.io/bulwarkmail/webmail:latest
```

اگر Docker Hub کار می‌کند ولی GHCR کار نمی‌کند، مشکل ممکن است فقط مربوط به GitHub Container Registry باشد.

## Port 25 بسته است

```bash
nc -vz -w 8 gmail-smtp-in.l.google.com 25
```

اگر Timeout شد، با VPS Provider تماس بگیرید.

## PTR اشتباه است

```bash
dig -x YOUR_SERVER_IP +short
```

باید نتیجه مشابه این باشد:

```text
mail.example.com.
```

## Bulwark خطای 502 می‌دهد

```bash
docker ps
curl http://127.0.0.1:3000/api/health
nginx -t
```

## پنل Stalwart باز نمی‌شود

```bash
systemctl status stalwart
curl http://127.0.0.1:8080
journalctl -u stalwart -n 200
```

---

# پروژه

Repository:

https://github.com/amirkateb/mailstack-installer

نسخه انگلیسی:

[README.md](README.md)

---

# سازنده

**amirmohammad katebsaber**

GitHub:

https://github.com/amirkateb

---

# License

برای این پروژه می‌توانید از License آزادی مانند **MIT License** استفاده کنید.

---

# سلب مسئولیت

راه‌اندازی Mail Server شخصی نیازمند نگهداری مداوم، مدیریت DNS، امنیت، Backup، مانیتورینگ، Reputation Management و جلوگیری از سوءاستفاده است.

MailStack Installer مراحل نصب را ساده‌تر می‌کند، اما نمی‌تواند تحویل قطعی ایمیل یا ورود آن به Inbox را تضمین کند.
