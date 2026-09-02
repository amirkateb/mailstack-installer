MailStack Installer

🇬🇧 English documentation: README.md

نصب‌کننده MailStack

یک نصب‌کننده تعاملی و مناسب محیط Production برای راه‌اندازی Stalwart Mail Server + Bulwark Webmail روی Ubuntu 24.04 LTS.

این پروژه بخش بزرگی از مراحل مورد نیاز برای راه‌اندازی یک Mail Server مدرن را به‌صورت خودکار انجام می‌دهد؛ از جمله بررسی DNS، نصب Docker و مسیرهای جایگزین، راه‌اندازی TLS، تنظیم Nginx، فایروال و راهنمای تنظیم SPF، DKIM و DMARC.

ساخته شده توسط amirmohammad katebsaber

⸻

معرفی

MailStack Installer یک استک کامل ایمیل را با استفاده از اجزای زیر راه‌اندازی می‌کند:

* Stalwart Mail Server
* Bulwark Webmail
* Nginx
* Let’s Encrypt
* Docker / Docker Compose
* Ubuntu 24.04 LTS

اسکریپت نصب، مرحله به مرحله کاربر را در فرایند راه‌اندازی همراهی می‌کند.

قبل از ادامه، تنظیمات مهم را بررسی می‌کند و اگر با خطای جدی و غیرقابل بازیابی مواجه شود، با نمایش علت دقیق مشکل متوقف می‌شود.

⸻

معماری

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

پورت‌های عمومی:

25    SMTP
465   SMTPS
587   SMTP Submission
993   IMAPS
80    HTTP
443   HTTPS

سرویس‌هایی که فقط روی Localhost در دسترس هستند:

127.0.0.1:8080   Stalwart HTTP/JMAP
127.0.0.1:3000   Bulwark Webmail

⸻

قابلیت‌ها

نصب تعاملی

نصب‌کننده دامنه اصلی را از شما دریافت می‌کند و hostnameهای موردنیاز را به‌صورت خودکار می‌سازد.

برای مثال:

Domain:
example.com
Mail hostname:
mail.example.com
Webmail hostname:
webmail.example.com

⸻

بررسی DNS

قبل از نصب Mail Server، تنظیمات مهم DNS بررسی می‌شوند.

این بررسی‌ها شامل موارد زیر است:

* تشخیص IPv4 عمومی سرور
* بررسی A Record مربوط به Mail Server
* بررسی A Record مربوط به Webmail
* بررسی MX
* بررسی PTR / Reverse DNS
* بررسی تطابق hostname با IP

نمونه:

mail.example.com      → 203.0.113.10
webmail.example.com   → 203.0.113.10
example.com MX        → mail.example.com
203.0.113.10 PTR      → mail.example.com

اگر یکی از رکوردهای ضروری اشتباه باشد، نصب‌کننده دقیقاً مشخص می‌کند چه چیزی باید اصلاح شود و سپس به‌صورت امن متوقف می‌شود.

⸻

SPF، DKIM و DMARC

MailStack Installer هیچ‌وقت مقدار DKIM را حدس نمی‌زند.

بعد از اینکه Stalwart دامنه و کلیدهای امضای ایمیل را ایجاد کرد، اسکریپت رکوردهای DNS تولیدشده توسط Stalwart را دریافت می‌کند و دقیقاً همان رکوردهایی را که باید در DNS Provider اضافه شوند نمایش می‌دهد.

این رکوردها می‌توانند شامل موارد زیر باشند:

* SPF
* DKIM
* DMARC
* MX
* MTA-STS
* Autoconfiguration
* سایر رکوردهای مورد نیاز Stalwart

⸻

نصب Docker با روش‌های جایگزین

مسیر اصلی نصب Docker از repository خود Ubuntu است:

apt install docker.io docker-compose-v2

قبل از ادامه، اسکریپت موارد زیر را بررسی می‌کند:

docker --version
docker compose version
systemctl status docker

اگر روش اصلی نصب شکست بخورد، Installer می‌تواند مسیرهای جایگزین را بررسی کند.

⸻

پشتیبانی از شبکه‌های محدود

این Installer برای سرورهایی که دسترسی محدود یا ناپایداری به repositoryها و registryهای بین‌المللی دارند نیز طراحی شده است.

قابلیت‌ها شامل:

* بررسی repositoryهای Ubuntu
* تشخیص Mirror خراب یا غیرقابل دسترس
* بررسی Mirrorهای جایگزین
* Backup گرفتن از تنظیمات repository قبل از تغییر
* بررسی دسترسی به Docker Hub
* تنظیم Docker Registry Mirror
* بررسی GitHub Container Registry
* استفاده از روش جایگزین برای نصب Bulwark

این قابلیت مخصوصاً روی VPSهایی که در شبکه‌های محدود قرار دارند می‌تواند مفید باشد.

⸻

مسیر جایگزین نصب Bulwark

Image رسمی Bulwark در این Registry قرار دارد:

ghcr.io

در ابتدا Installer تلاش می‌کند:

docker pull ghcr.io/bulwarkmail/webmail:latest

را اجرا کند.

اگر GHCR در دسترس نباشد، Bulwark می‌تواند بدون Docker و با استفاده از موارد زیر نصب شود:

Node.js
npm
systemd

به این ترتیب محدودیت Container Registry الزاماً باعث شکست کامل نصب نمی‌شود.

⸻

TLS خودکار

Certificateهای Let’s Encrypt برای این hostnameها دریافت می‌شوند:

mail.example.com
webmail.example.com

Certificateها برای موارد زیر استفاده می‌شوند:

* HTTPS
* SMTP
* SMTPS
* SMTP Submission
* IMAPS

همچنین یک Certbot Deployment Hook ایجاد می‌شود تا پس از تمدید خودکار Certificate، نسخه مورد استفاده Stalwart نیز به‌روز شود.

⸻

Reverse Proxy با Nginx

Nginx ورودی عمومی سرویس‌های Web است.

برای Stalwart:

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

برای Bulwark:

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

پورت‌های داخلی برنامه مستقیماً روی اینترنت منتشر نمی‌شوند.

⸻

تنظیم فایروال

Installer از UFW استفاده می‌کند.

قبل از فعال‌سازی فایروال، پورت SSH فعلی سرور را تشخیص می‌دهد تا احتمال قطع دسترسی SSH کاهش پیدا کند.

پورت‌های عمومی:

SSH
25
80
443
465
587
993

پورت‌های داخلی:

3000
8080

⸻

مدیریت خطا

اگر یک عملیات حیاتی شکست بخورد، Installer ادامه نمی‌دهد.

اطلاعات خطا می‌تواند شامل موارد زیر باشد:

مرحله نصب
فرمان ناموفق
شماره خط
علت خطا
مسیر فایل Log

نمونه:

[ERROR] Installation stopped.
Stage:
Final TLS validation
Reason:
IMAPS TLS verification failed.
Log:
/var/log/mailstack-installer-20260902.log

⸻

پیش‌نیازها

حداقل منابع پیشنهادی:

Operating System: Ubuntu Server 24.04 LTS
CPU:              2 vCPU
RAM:              2-4 GB
Storage:          40+ GB SSD
IPv4:             Static public address
Access:           Root or sudo

همچنین به موارد زیر نیاز دارید:

* یک دامنه
* دسترسی مدیریت DNS
* امکان تنظیم PTR / Reverse DNS
* باز بودن Port 25 ورودی
* باز بودن Port 25 خروجی

⸻

نصب

روش اول — Clone کردن Repository

وارد سرور شوید:

ssh root@YOUR_SERVER_IP

در صورت نیاز Git را نصب کنید:

apt update
apt install -y git

Repository را Clone کنید:

git clone https://github.com/amirkateb/mailstack-installer.git

وارد پوشه پروژه شوید:

cd mailstack-installer

Permission اجرا بدهید:

chmod +x install-mailstack.sh

Installer را اجرا کنید:

./install-mailstack.sh

⸻

روش دوم — دانلود مستقیم Installer

curl -fsSL \
https://raw.githubusercontent.com/amirkateb/mailstack-installer/main/install-mailstack.sh \
-o install-mailstack.sh

Permission:

chmod +x install-mailstack.sh

اجرا:

sudo ./install-mailstack.sh

⸻

مراحل نصب

Installer تقریباً این مراحل را انجام می‌دهد:

1. بررسی سیستم
2. دریافت دامنه
3. تشخیص IP عمومی
4. نمایش DNS اولیه
5. بررسی A Recordها
6. بررسی MX
7. بررسی PTR
8. تست SMTP خروجی
9. بررسی repositoryهای Ubuntu
10. نصب Docker
11. تست Registryهای Docker
12. نصب Stalwart
13. تنظیم Stalwart
14. نصب Bulwark
15. نصب Nginx
16. دریافت Let's Encrypt Certificate
17. تنظیم TLS برای SMTP و IMAP
18. دریافت DNS Zone از Stalwart
19. بررسی SPF / DKIM / DMARC
20. Health Check نهایی

⸻

تنظیم اولیه DNS

فرض کنید:

Domain:
example.com
Server IPv4:
203.0.113.10

رکوردهای اولیه:

Mail A Record

Type: A
Name: mail
Value: 203.0.113.10

Webmail A Record

Type: A
Name: webmail
Value: 203.0.113.10

MX Record

Type: MX
Name: @
Priority: 10
Value: mail.example.com

⸻

Reverse DNS

در پنل VPS Provider باید PTR را به این صورت تنظیم کنید:

203.0.113.10
        │
        ▼
mail.example.com

در جهت برعکس نیز:

mail.example.com
        │
        ▼
203.0.113.10

PTR صحیح نقش مهمی در اعتبار Mail Server و تحویل ایمیل دارد.

⸻

کاربران Cloudflare

اگر DNS دامنه روی Cloudflare است، hostname مربوط به Mail Server باید معمولاً روی:

DNS Only

باشد.

برای مثال:

mail.example.com       DNS Only
webmail.example.com    DNS Only

SMTP و IMAP را نباید از Proxy معمولی Cloudflare عبور دهید.

⸻

بعد از نصب

پنل مدیریت Stalwart

https://mail.example.com/admin

Webmail

https://webmail.example.com

⸻

تنظیم Mail Client

IMAP

Server:         mail.example.com
Port:           993
Security:       SSL/TLS
Username:       user@example.com
Authentication: Password

SMTP

Server:         mail.example.com
Port:           465
Security:       SSL/TLS
Username:       user@example.com
Authentication: Password

یا:

Port:     587
Security: STARTTLS

⸻

تست Deliverability

بعد از نصب یک ایمیل آزمایشی برای سرویس‌هایی مثل موارد زیر بفرستید:

* Gmail
* Outlook
* Yahoo

نتیجه Authentication باید در حالت ایده‌آل:

SPF:   PASS
DKIM:  PASS
DMARC: PASS

باشد.

البته PASS بودن این سه مورد تضمین نمی‌کند ایمیل حتماً وارد Inbox شود.

موارد دیگری نیز مؤثر هستند:

* اعتبار IP
* اعتبار دامنه
* حجم ارسال
* Complaint Rate
* محتوای ایمیل
* PTR
* Blacklistها

⸻

دستورات کاربردی

وضعیت Stalwart

systemctl status stalwart

Restart

systemctl restart stalwart

Log

journalctl -u stalwart -f

⸻

Docker

وضعیت:

systemctl status docker

Containerها:

docker ps

Logهای Bulwark:

docker logs -f bulwark

⸻

Nginx

بررسی Configuration:

nginx -t

Reload:

systemctl reload nginx

⸻

بررسی شبکه

ss -lntp

پورت‌های عمومی معمولاً:

0.0.0.0:25
0.0.0.0:80
0.0.0.0:443
0.0.0.0:465
0.0.0.0:587
0.0.0.0:993

سرویس‌های داخلی:

127.0.0.1:3000
127.0.0.1:8080

⸻

تست Port 25 خروجی

nc -vz -w 8 gmail-smtp-in.l.google.com 25

نتیجه موفق مشابه:

Connection to gmail-smtp-in.l.google.com 25 port [tcp/smtp] succeeded!

اگر Timeout دریافت کردید، احتمالاً شرکت ارائه‌دهنده VPS پورت SMTP خروجی را مسدود کرده است.

⸻

تست DNS

A Record:

dig +short A mail.example.com

MX:

dig +short MX example.com

PTR:

dig -x YOUR_SERVER_IP +short

SPF:

dig TXT example.com

DMARC:

dig TXT _dmarc.example.com

⸻

تست TLS

IMAPS:

openssl s_client \
-connect mail.example.com:993 \
-servername mail.example.com

SMTPS:

openssl s_client \
-connect mail.example.com:465 \
-servername mail.example.com

Certificate باید معتبر و Publicly Trusted باشد.

⸻

بروزرسانی Bulwark

اگر Bulwark با Docker نصب شده است:

cd /opt/bulwark
docker compose pull
docker compose up -d
docker compose ps

⸻

Backup

مسیرهای مهم Stalwart:

/etc/stalwart
/var/lib/stalwart

همچنین پیشنهاد می‌شود از این موارد Backup گرفته شود:

/etc/nginx
/etc/letsencrypt
/opt/bulwark

و Docker Volumeهای مرتبط.

حداقل یک Backup باید خارج از خود Mail Server نگهداری شود.

⸻

توصیه‌های امنیتی

Mail Server عمومی نیازمند نگهداری دائمی است.

پیشنهاد می‌شود:

* Ubuntu را به‌روز نگه دارید
* Stalwart را به‌روز نگه دارید
* Bulwark را به‌روز نگه دارید
* Docker را به‌روز نگه دارید
* از Passwordهای قوی استفاده کنید
* در صورت امکان MFA را فعال کنید
* Logها را بررسی کنید
* Disk Usage را مانیتور کنید
* Backup منظم داشته باشید
* پورت‌های داخلی را Public نکنید
* ارسال‌های غیرعادی SMTP را بررسی کنید
* Rate Limit مناسب تنظیم کنید
* هرگز Open Relay ایجاد نکنید

⸻

رفع مشکلات

Docker Pull کار نمی‌کند

ابتدا:

docker pull hello-world

بعد:

docker pull ghcr.io/bulwarkmail/webmail:latest

اگر Docker Hub کار می‌کند ولی GHCR کار نمی‌کند، ممکن است مشکل فقط مربوط به GitHub Container Registry باشد.

Installer می‌تواند از مسیر جایگزین برای نصب Bulwark استفاده کند.

⸻

Port 25 بسته است

nc -vz -w 8 gmail-smtp-in.l.google.com 25

اگر Timeout شد، با VPS Provider تماس بگیرید.

⸻

PTR اشتباه است

dig -x YOUR_SERVER_IP +short

باید نتیجه مشابه:

mail.example.com.

باشد.

⸻

Bulwark خطای 502 می‌دهد

docker ps

سپس:

curl http://127.0.0.1:3000/api/health

بعد:

nginx -t

⸻

پنل Stalwart باز نمی‌شود

systemctl status stalwart

سپس:

curl http://127.0.0.1:8080

و:

journalctl -u stalwart -n 200

⸻

پروژه

Repository:

https://github.com/amirkateb/mailstack-installer

نسخه انگلیسی:

README.md

⸻

سازنده

amirmohammad katebsaber

GitHub:

https://github.com/amirkateb

⸻

License

برای این پروژه می‌توانید از یک License آزاد مانند MIT License استفاده کنید.

⸻

سلب مسئولیت

راه‌اندازی Mail Server شخصی نیازمند نگهداری مداوم، مدیریت DNS، امنیت، Backup، مانیتورینگ، Reputation Management و جلوگیری از سوءاستفاده است.

MailStack Installer مراحل نصب را ساده‌تر می‌کند، اما نمی‌تواند تحویل قطعی ایمیل یا ورود آن به Inbox را تضمین کند.
