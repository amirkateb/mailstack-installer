#!/usr/bin/env bash
# ==============================================================================
# Stalwart + Bulwark Mail Stack Installer for Ubuntu 24.04 LTS
# Fully automated / resumable edition with Cloudflare DNS automation
# by amirmohammad katebsaber
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_VERSION="2.0.2"
STATE_DIR="/var/lib/katebsaber-mailstack-installer"
DONE_DIR="${STATE_DIR}/done"
CONFIG_FILE="${STATE_DIR}/config.env"
SECRETS_STATE_FILE="${STATE_DIR}/secrets.env"
CF_TOKEN_FILE="${STATE_DIR}/cloudflare-token"
CF_STALWART_TOKEN_FILE="/etc/stalwart/cloudflare-token"
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/katebsaber-mailstack-installer-$(date +%Y%m%d-%H%M%S).log"
SECRETS_FILE="/root/mailstack-secrets.txt"
DNS_ZONE_FILE="/root/stalwart-dns-zone.txt"
STALWART_PLAN="${STATE_DIR}/stalwart-plan.ndjson"
INSTALL_STAGE="startup"
CLOUDFLARE_API="https://api.cloudflare.com/client/v4"
CLOUDFLARE_TOKEN_URL="https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22dns%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%5D&accountId=%2A&zoneId=all&name=KatebSaber%20MailStack%20DNS"

RECONFIGURE=0
RESET_PROGRESS=0
SKIP_PTR_CHECK=0
DNS_PROFILE="core"
DNS_PROFILE_OVERRIDE=""
NONINTERACTIVE=0

# Colors
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'
  BOLD='\033[1m'; RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' DIM='' BOLD='' RESET=''
fi

mkdir -p "$STATE_DIR" "$DONE_DIR" "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

banner() {
  clear 2>/dev/null || true
  printf '%b\n' "${CYAN}${BOLD}"
  cat <<'BANNER'
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║              STALWART + BULWARK MAIL STACK INSTALLER                 ║
║                                                                      ║
║                    by amirmohammad katebsaber                        ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
BANNER
  printf '%b\n' "${RESET}${DIM}Version ${SCRIPT_VERSION} • Ubuntu 24.04 LTS • Cloudflare automation • resumable${RESET}"
  echo
}

line() { printf '%*s\n' "${COLUMNS:-72}" '' | tr ' ' '─'; }
info() { printf '%b\n' "${BLUE}ℹ${RESET}  $*"; }
ok() { printf '%b\n' "${GREEN}✔${RESET}  $*"; }
warn() { printf '%b\n' "${YELLOW}⚠${RESET}  $*"; }
err() { printf '%b\n' "${RED}✖${RESET}  $*"; }

stage() {
  INSTALL_STAGE="$1"
  echo
  line
  printf '%b\n' "${MAGENTA}${BOLD}▶ $1${RESET}"
  line
}

fatal() {
  local msg="$1"
  echo
  err "$msg"
  err "Installation stopped at stage: ${INSTALL_STAGE}"
  info "State is preserved. Run this same installer again to continue."
  info "Log file: ${LOG_FILE}"
  exit 1
}

on_error() {
  local exit_code=$?
  local line_no=$1
  local cmd=${2:-unknown}
  echo
  err "Unexpected command failure."
  printf '%b\n' "${RED}Stage:${RESET} ${INSTALL_STAGE}"
  printf '%b\n' "${RED}Line:${RESET}  ${line_no}"
  printf '%b\n' "${RED}Exit:${RESET}  ${exit_code}"
  printf '%b\n' "${RED}Command:${RESET} ${cmd}"
  info "State is preserved; re-running the installer resumes safely."
  info "Full log: ${LOG_FILE}"
  echo
  warn "Last log lines:"
  tail -n 25 "$LOG_FILE" 2>/dev/null || true
  exit "$exit_code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

on_interrupt() {
  echo
  warn "Interrupted. Installation state and generated secrets were preserved."
  warn "If Stalwart was in recovery mode, simply run this installer again; it will reconcile and continue."
  info "Log file: ${LOG_FILE}"
  exit 130
}
trap on_interrupt INT TERM

usage() {
  cat <<EOF
Usage: sudo bash $0 [options]

Options:
  --reconfigure       Ask for domain/host/IP/email again.
  --reset-progress    Clear only completed-step markers; keep config/secrets.
  --full-dns          Let Stalwart publish its full recommended DNS set.
  --core-dns          Publish only core mail auth DNS (MX/SPF/DKIM/DMARC). Default.
  --skip-ptr-check    Continue even if reverse DNS/PTR is not correct (not recommended).
  --non-interactive   Never wait for manual retry prompts; fail and preserve state instead.
  -h, --help          Show this help.
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --reconfigure) RECONFIGURE=1 ;;
      --reset-progress) RESET_PROGRESS=1 ;;
      --full-dns) DNS_PROFILE="full"; DNS_PROFILE_OVERRIDE="full" ;;
      --core-dns) DNS_PROFILE="core"; DNS_PROFILE_OVERRIDE="core" ;;
      --skip-ptr-check) SKIP_PTR_CHECK=1 ;;
      --non-interactive) NONINTERACTIVE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown option: $1"; usage; exit 2 ;;
    esac
    shift
  done
}

confirm() {
  local prompt="$1" default=${2:-Y} answer
  if (( NONINTERACTIVE )); then
    [[ "$default" == "Y" ]]
    return
  fi
  if [[ "$default" == "Y" ]]; then
    read -r -p "$prompt [Y/n]: " answer
    answer=${answer:-Y}
  else
    read -r -p "$prompt [y/N]: " answer
    answer=${answer:-N}
  fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

require_root() {
  [[ $EUID -eq 0 ]] || fatal "Run this installer as root: sudo bash $0"
}

validate_ubuntu() {
  [[ -r /etc/os-release ]] || fatal "Cannot detect the operating system."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fatal "This installer supports Ubuntu only. Detected: ${ID:-unknown}"
  [[ "${VERSION_ID:-}" == "24.04" ]] || fatal "This installer is designed for Ubuntu 24.04 LTS. Detected: ${VERSION_ID:-unknown}"
  ok "Detected Ubuntu ${VERSION_ID} (${VERSION_CODENAME:-noble})."
}

valid_domain() {
  local d="$1"
  [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

valid_email() {
  local e="$1"
  [[ "$e" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

normalize_domain() {
  local d="$1"
  d=${d#http://}
  d=${d#https://}
  d=${d%%/*}
  d=${d%.}
  printf '%s' "${d,,}"
}

get_public_ipv4() {
  local ip="" endpoint
  local endpoints=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://ifconfig.me/ip"
  )
  for endpoint in "${endpoints[@]}"; do
    ip=$(curl -4fsS --connect-timeout 5 --max-time 8 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

get_ssh_port() {
  local p=""
  p=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true)
  [[ "$p" =~ ^[0-9]+$ ]] || p=22
  printf '%s' "$p"
}

save_config() {
  {
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'MAIL_HOST=%q\n' "$MAIL_HOST"
    printf 'WEBMAIL_HOST=%q\n' "$WEBMAIL_HOST"
    printf 'SERVER_IP=%q\n' "$SERVER_IP"
    printf 'LE_EMAIL=%q\n' "$LE_EMAIL"
    printf 'SSH_PORT=%q\n' "$SSH_PORT"
    printf 'DNS_PROFILE=%q\n' "$DNS_PROFILE"
  } >"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

collect_configuration() {
  stage "Configuration"

  if [[ -s "$CONFIG_FILE" && $RECONFIGURE -eq 0 ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    [[ -n "$DNS_PROFILE_OVERRIDE" ]] && DNS_PROFILE="$DNS_PROFILE_OVERRIDE"
    ok "Loaded saved configuration for resume."
    printf '  Domain:          %s\n' "$DOMAIN"
    printf '  Mail hostname:   %s\n' "$MAIL_HOST"
    printf '  Webmail:         %s\n' "$WEBMAIL_HOST"
    printf '  Public IPv4:     %s\n' "$SERVER_IP"
    printf '  DNS profile:     %s\n' "$DNS_PROFILE"
    return
  fi

  local input default_mail default_webmail detected_ip
  while true; do
    read -r -p "Primary mail domain (example.com): " input
    DOMAIN=$(normalize_domain "$input")
    valid_domain "$DOMAIN" && break
    err "Invalid domain name. Example: example.com"
  done

  default_mail="mail.${DOMAIN}"
  read -r -p "Mail server hostname [${default_mail}]: " input
  MAIL_HOST=$(normalize_domain "${input:-$default_mail}")
  valid_domain "$MAIL_HOST" || fatal "Invalid mail server hostname: $MAIL_HOST"

  default_webmail="webmail.${DOMAIN}"
  read -r -p "Webmail hostname [${default_webmail}]: " input
  WEBMAIL_HOST=$(normalize_domain "${input:-$default_webmail}")
  valid_domain "$WEBMAIL_HOST" || fatal "Invalid webmail hostname: $WEBMAIL_HOST"

  while true; do
    read -r -p "Let's Encrypt notification email: " LE_EMAIL
    valid_email "$LE_EMAIL" && break
    err "Invalid email address."
  done

  detected_ip=$(get_public_ipv4 || true)
  if [[ -n "$detected_ip" ]]; then
    info "Detected public IPv4: $detected_ip"
    read -r -p "Public IPv4 [${detected_ip}]: " input
    SERVER_IP=${input:-$detected_ip}
  else
    read -r -p "Public IPv4 address of this server: " SERVER_IP
  fi
  [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fatal "Invalid IPv4 address: $SERVER_IP"

  SSH_PORT=$(get_ssh_port)

  echo
  printf '%b\n' "${WHITE}${BOLD}Configuration summary${RESET}"
  printf '  Domain:          %s\n' "$DOMAIN"
  printf '  Mail hostname:   %s\n' "$MAIL_HOST"
  printf '  Webmail:         %s\n' "$WEBMAIL_HOST"
  printf '  Public IPv4:     %s\n' "$SERVER_IP"
  printf '  SSH port:        %s\n' "$SSH_PORT"
  printf '  ACME email:      %s\n' "$LE_EMAIL"
  printf '  DNS profile:     %s\n' "$DNS_PROFILE"
  echo

  confirm "Continue with this configuration?" Y || fatal "Cancelled by user."
  save_config

  # Cloudflare tokens are deliberately zone-scoped. A reconfiguration may point
  # at a different zone, so force a fresh validation/paste instead of silently
  # reusing a token that may have permissions for the previous domain only.
  if (( RECONFIGURE )); then
    rm -f "$CF_TOKEN_FILE"
  fi
}

generate_hex_secret() {
  openssl rand -hex "${1:-24}"
}

load_or_create_secrets() {
  stage "Installer secrets"
  if [[ -s "$SECRETS_STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_STATE_FILE"
    ok "Loaded saved secrets for safe resume."
  else
    STALWART_RECOVERY_PASSWORD=$(generate_hex_secret 24)
    STALWART_ADMIN_PASSWORD=$(generate_hex_secret 24)
    BULWARK_SESSION_SECRET=$(generate_hex_secret 48)
    BULWARK_ADMIN_PASSWORD=$(generate_hex_secret 24)
    {
      printf 'STALWART_RECOVERY_PASSWORD=%q\n' "$STALWART_RECOVERY_PASSWORD"
      printf 'STALWART_ADMIN_PASSWORD=%q\n' "$STALWART_ADMIN_PASSWORD"
      printf 'BULWARK_SESSION_SECRET=%q\n' "$BULWARK_SESSION_SECRET"
      printf 'BULWARK_ADMIN_PASSWORD=%q\n' "$BULWARK_ADMIN_PASSWORD"
    } >"$SECRETS_STATE_FILE"
    chmod 600 "$SECRETS_STATE_FILE"
    ok "Generated persistent installer secrets."
  fi
  STALWART_ADMIN_USER="admin@${DOMAIN}"
}

write_secrets_summary() {
  cat >"$SECRETS_FILE" <<EOF
Mail Stack Secrets
==================
Generated/managed by: katebsaber mail stack installer v${SCRIPT_VERSION}
Last updated: $(date -Is)

Stalwart Admin
--------------
URL:      https://${MAIL_HOST}/admin
Username: ${STALWART_ADMIN_USER}
Password: ${STALWART_ADMIN_PASSWORD}

Bulwark
-------
URL:            https://${WEBMAIL_HOST}
Admin password: ${BULWARK_ADMIN_PASSWORD}

Mail client
-----------
IMAP: ${MAIL_HOST}:993 (SSL/TLS)
SMTP: ${MAIL_HOST}:465 (SSL/TLS)
SMTP: ${MAIL_HOST}:587 (STARTTLS)
Username for normal mailboxes: full email address

Cloudflare
----------
API token itself is NOT copied here.
Root-only token state: ${CF_TOKEN_FILE}
Stalwart token file: ${CF_STALWART_TOKEN_FILE}

Important
---------
The temporary Stalwart recovery credential is intentionally omitted from this file.
It is removed from the Stalwart runtime environment before normal operation.
EOF
  chmod 600 "$SECRETS_FILE"
}

# -----------------------------------------------------------------------------
# Cloudflare API
# -----------------------------------------------------------------------------

cf_api_raw() {
  local method="$1" endpoint="$2" data=${3:-} response
  if [[ -n "$data" ]]; then
    response=$(curl -sS --fail-with-body -X "$method" "${CLOUDFLARE_API}${endpoint}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H 'Content-Type: application/json' \
      --data "$data") || return 1
  else
    response=$(curl -sS --fail-with-body -X "$method" "${CLOUDFLARE_API}${endpoint}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H 'Content-Type: application/json') || return 1
  fi
  jq -e '.success == true' >/dev/null <<<"$response" || {
    jq -r '.errors[]? | "Cloudflare: \(.code): \(.message)"' <<<"$response" >&2 || true
    return 1
  }
  printf '%s' "$response"
}

cf_api_get_query() {
  local endpoint="$1"
  shift
  local args=() pair response
  for pair in "$@"; do
    args+=(--data-urlencode "$pair")
  done
  response=$(curl -sS --fail-with-body -G "${CLOUDFLARE_API}${endpoint}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H 'Content-Type: application/json' \
    "${args[@]}") || return 1
  jq -e '.success == true' >/dev/null <<<"$response" || return 1
  printf '%s' "$response"
}

ensure_cloudflare_token() {
  stage "Cloudflare API token"

  while true; do
    if [[ -s "$CF_TOKEN_FILE" ]]; then
      CF_API_TOKEN=$(<"$CF_TOKEN_FILE")
      info "Using saved Cloudflare token from root-only state."
    else
      echo
      printf '%b\n' "${WHITE}${BOLD}Create a restricted Cloudflare API Token:${RESET}"
      echo "  ${CLOUDFLARE_TOKEN_URL}"
      echo
      cat <<EOF
Create Token -> Custom token

Token name:
  KatebSaber MailStack - ${DOMAIN}

Permissions:
  Zone -> DNS  -> Edit
  Zone -> Zone -> Read

Zone Resources:
  IMPORTANT: change the pre-filled scope from All zones to:
  Include -> Specific zone -> ${DOMAIN}

The link pre-fills the two required permissions; you still restrict it to this one zone.
Do not use the Global API Key.
EOF
      echo
      (( NONINTERACTIVE )) && fatal "Cloudflare token is required. Create it at ${CLOUDFLARE_TOKEN_URL} and rerun without --non-interactive."
      read -r -s -p "Paste Cloudflare API Token: " CF_API_TOKEN
      echo
      [[ -n "$CF_API_TOKEN" ]] || {
        err "Token cannot be empty."
        continue
      }
    fi

    local verify
    verify=$(cf_api_raw GET "/user/tokens/verify" 2>/dev/null || true)
    if [[ -n "$verify" ]] && [[ "$(jq -r '.result.status // empty' <<<"$verify")" == "active" ]]; then
      printf '%s' "$CF_API_TOKEN" >"$CF_TOKEN_FILE"
      chmod 600 "$CF_TOKEN_FILE"
      ok "Cloudflare API Token is valid and active."
      break
    fi

    err "Cloudflare token validation failed."
    rm -f "$CF_TOKEN_FILE"
    unset CF_API_TOKEN
    (( NONINTERACTIVE )) && fatal "Cloudflare token is invalid or expired."
  done
}

cloudflare_find_zone() {
  stage "Cloudflare zone validation"
  local response count status
  response=$(cf_api_get_query "/zones" "name=${DOMAIN}" "status=active" "per_page=50") || \
    fatal "Could not list Cloudflare zones. Verify Zone -> Zone -> Read permission."
  count=$(jq '.result | length' <<<"$response")
  [[ "$count" -eq 1 ]] || fatal "Expected exactly one active Cloudflare zone named ${DOMAIN}; found ${count}."
  CF_ZONE_ID=$(jq -r '.result[0].id' <<<"$response")
  status=$(jq -r '.result[0].status' <<<"$response")
  [[ -n "$CF_ZONE_ID" && "$status" == "active" ]] || fatal "Cloudflare zone ${DOMAIN} is not active."
  ok "Cloudflare zone found: ${DOMAIN} (${CF_ZONE_ID})"
}

cf_list_record() {
  local type="$1" name="$2"
  cf_api_get_query "/zones/${CF_ZONE_ID}/dns_records" "type=${type}" "name=${name}" "per_page=100"
}

cf_check_cname_conflict() {
  local name="$1" response
  response=$(cf_list_record CNAME "$name") || fatal "Could not inspect Cloudflare DNS for ${name}."
  if [[ "$(jq '.result | length' <<<"$response")" -gt 0 ]]; then
    fatal "Cloudflare has a CNAME at ${name}; it conflicts with the required A record. Remove/rename that CNAME and rerun."
  fi
}

cf_upsert_a() {
  local name="$1" ip="$2" response count id current proxied payload
  cf_check_cname_conflict "$name"
  response=$(cf_list_record A "$name") || fatal "Could not read A record ${name}."
  count=$(jq '.result | length' <<<"$response")
  payload=$(jq -nc --arg name "$name" --arg content "$ip" \
    '{type:"A",name:$name,content:$content,ttl:1,proxied:false,comment:"Managed by KatebSaber MailStack Installer"}')

  if [[ "$count" -eq 0 ]]; then
    cf_api_raw POST "/zones/${CF_ZONE_ID}/dns_records" "$payload" >/dev/null || fatal "Could not create A ${name}."
    ok "Created A ${name} -> ${ip} (DNS only)."
  elif [[ "$count" -eq 1 ]]; then
    id=$(jq -r '.result[0].id' <<<"$response")
    current=$(jq -r '.result[0].content' <<<"$response")
    proxied=$(jq -r '.result[0].proxied // false' <<<"$response")
    if [[ "$current" == "$ip" && "$proxied" == "false" ]]; then
      ok "A ${name} is already correct and DNS only."
    else
      cf_api_raw PATCH "/zones/${CF_ZONE_ID}/dns_records/${id}" "$payload" >/dev/null || fatal "Could not update A ${name}."
      ok "Updated A ${name} -> ${ip} and forced DNS only."
    fi
  else
    fatal "Multiple A records exist for ${name}. Refusing to guess which one to modify."
  fi
}

cf_ensure_mx() {
  local response exact_id payload existing_other
  response=$(cf_list_record MX "$DOMAIN") || fatal "Could not read MX records for ${DOMAIN}."
  exact_id=$(jq -r --arg target "$MAIL_HOST" '
    .result[] |
    select((.content | ascii_downcase | rtrimstr(".")) == ($target | ascii_downcase | rtrimstr("."))) |
    .id
  ' <<<"$response" | head -n1 || true)

  payload=$(jq -nc --arg name "$DOMAIN" --arg content "$MAIL_HOST" \
    '{type:"MX",name:$name,content:$content,ttl:1,priority:10,comment:"Managed by KatebSaber MailStack Installer"}')

  if [[ -n "$exact_id" ]]; then
    cf_api_raw PATCH "/zones/${CF_ZONE_ID}/dns_records/${exact_id}" "$payload" >/dev/null || fatal "Could not normalize MX record."
    ok "MX ${DOMAIN} -> ${MAIL_HOST} priority 10 is present."
  else
    existing_other=$(jq '.result | length' <<<"$response")
    if [[ "$existing_other" -gt 0 ]]; then
      warn "Other MX records already exist. They are preserved; adding the Stalwart MX without deleting them."
    fi
    cf_api_raw POST "/zones/${CF_ZONE_ID}/dns_records" "$payload" >/dev/null || fatal "Could not create MX record."
    ok "Created MX ${DOMAIN} -> ${MAIL_HOST} priority 10."
  fi
}

cloudflare_bootstrap_dns() {
  stage "Cloudflare bootstrap DNS"
  cf_upsert_a "$MAIL_HOST" "$SERVER_IP"
  cf_upsert_a "$WEBMAIL_HOST" "$SERVER_IP"
  cf_ensure_mx
  ok "Bootstrap A/MX DNS is reconciled. Stalwart will maintain SPF/DKIM/DMARC itself."
}

wait_for_a_record() {
  local host="$1" expected="$2" i
  for i in $(seq 1 36); do
    if dig +short A "$host" @1.1.1.1 2>/dev/null | grep -Fxq "$expected"; then
      ok "$host publicly resolves to $expected"
      return 0
    fi
    sleep 5
  done
  return 1
}

validate_bootstrap_dns() {
  stage "Public DNS propagation"
  wait_for_a_record "$MAIL_HOST" "$SERVER_IP" || fatal "$MAIL_HOST does not resolve to $SERVER_IP publicly yet. Rerun after propagation."
  wait_for_a_record "$WEBMAIL_HOST" "$SERVER_IP" || fatal "$WEBMAIL_HOST does not resolve to $SERVER_IP publicly yet. Rerun after propagation."
}

validate_ptr() {
  stage "Reverse DNS / PTR validation"
  local ptr answer
  while true; do
    ptr=$(dig +short -x "$SERVER_IP" @1.1.1.1 2>/dev/null | head -n1 | tr '[:upper:]' '[:lower:]' | sed 's/\.$//' || true)
    if [[ "$ptr" == "$MAIL_HOST" ]]; then
      ok "PTR is correct: $SERVER_IP -> $MAIL_HOST"
      return
    fi

    if (( SKIP_PTR_CHECK )); then
      warn "PTR mismatch ignored because --skip-ptr-check was supplied. Current PTR: ${ptr:-none}"
      return
    fi

    err "PTR is not correct."
    echo "  Required at your VPS provider:"
    echo "  ${SERVER_IP} -> ${MAIL_HOST}"
    echo "  Current PTR: ${ptr:-none}"
    warn "PTR/reverse DNS belongs to the IP/VPS provider, not Cloudflare."

    (( NONINTERACTIVE )) && fatal "PTR must be fixed at the VPS provider before continuing."
    read -r -p "Fix PTR at the VPS provider, then type R to retry or Q to stop [R/q]: " answer
    answer=${answer:-R}
    [[ "$answer" =~ ^[Qq]$ ]] && fatal "Stopped while waiting for PTR."
  done
}

# -----------------------------------------------------------------------------
# Ubuntu / packages / firewall
# -----------------------------------------------------------------------------

apt_backup_once() {
  local backup="$STATE_DIR/apt-sources-backup.tar.gz"
  if [[ ! -f "$backup" ]]; then
    tar -czf "$backup" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true
    chmod 600 "$backup" 2>/dev/null || true
  fi
}

probe_ubuntu_mirror() {
  local base="$1" code
  code=$(curl -fsS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "${base}/dists/noble/InRelease" 2>/dev/null || true)
  [[ "$code" == "200" ]]
}

configure_ubuntu_mirror_fallback() {
  stage "Ubuntu repository fallback"
  apt_backup_once

  local candidates=(
    "https://repo.linuxmirrors.ir/ubuntu"
    "https://mirror.arvancloud.ir/ubuntu"
    "https://mirror.iranserver.com/ubuntu"
    "https://archive.ubuntu.com/ubuntu"
  )
  local mirror="" candidate

  for candidate in "${candidates[@]}"; do
    info "Testing Ubuntu mirror: $candidate"
    if probe_ubuntu_mirror "$candidate"; then
      mirror="$candidate"
      break
    fi
  done
  [[ -n "$mirror" ]] || fatal "No tested Ubuntu mirror is reachable."
  ok "Selected Ubuntu mirror: $mirror"

  mkdir -p /etc/apt/sources.list.d
  if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
    mv /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.katebsaber-disabled
  fi
  if [[ -s /etc/apt/sources.list ]]; then
    mv /etc/apt/sources.list /etc/apt/sources.list.katebsaber-disabled
    : >/etc/apt/sources.list
  fi

  cat >/etc/apt/sources.list.d/katebsaber-ubuntu.sources <<EOF
Types: deb
URIs: ${mirror}
Suites: noble noble-updates noble-backports noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  apt-get clean
  apt-get update || fatal "APT still fails after switching Ubuntu mirror."
}

install_base_packages() {
  stage "Base packages"
  if [[ -f "$DONE_DIR/base-packages" ]] && command -v dig >/dev/null && command -v nginx >/dev/null && command -v jq >/dev/null; then
    ok "Base package step already completed."
    return
  fi

  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get update; then
    warn "Current Ubuntu repositories failed. Trying fallback mirrors."
    configure_ubuntu_mirror_fallback
  fi

  apt-get install -y \
    ca-certificates curl wget gnupg jq git xz-utils unzip \
    dnsutils netcat-openbsd openssl ufw nginx certbot \
    python3-certbot-nginx >/dev/null

  systemctl disable --now nginx >/dev/null 2>&1 || true
  touch "$DONE_DIR/base-packages"
  ok "Base packages installed."
}

port_owner() {
  local port="$1"
  ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print; found=1} END{if(!found) exit 1}' || true
}

check_initial_port_conflicts() {
  stage "Initial port conflict check"
  local port owner
  for port in 25 465 587 993; do
    owner=$(port_owner "$port")
    if [[ -n "$owner" ]] && ! grep -qi stalwart <<<"$owner"; then
      err "Port ${port} is already used by another service:"
      echo "$owner"
      fatal "Mail port conflict detected."
    fi
  done
  ok "No conflicting non-Stalwart mail listeners detected."
}

check_outbound_smtp() {
  stage "Outbound SMTP port 25 test"
  local targets=("gmail-smtp-in.l.google.com" "mx1.hotmail.com") host
  for host in "${targets[@]}"; do
    info "Testing outbound TCP/25 to $host ..."
    if nc -4 -z -w 8 "$host" 25 >/dev/null 2>&1; then
      ok "Outbound TCP/25 is open."
      return 0
    fi
  done
  fatal "Outbound TCP/25 appears blocked. This is a VPS/provider restriction and cannot be fixed by Cloudflare or Stalwart."
}

configure_firewall() {
  stage "Firewall"
  ufw allow "${SSH_PORT}/tcp" >/dev/null
  for p in 25 80 443 465 587 993; do
    ufw allow "${p}/tcp" >/dev/null
  done
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null
  ok "UFW enabled. Public TCP ports: ${SSH_PORT}, 25, 80, 443, 465, 587, 993."
}

# -----------------------------------------------------------------------------
# Docker
# -----------------------------------------------------------------------------

install_docker_from_ubuntu() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y docker.io docker-compose-v2
}

install_docker_official_fallback() {
  local arch
  arch=$(dpkg --print-architecture)
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

select_dockerhub_mirrors() {
  local candidates=(
    "https://docker.arvancloud.ir"
    "https://registry.docker.ir"
  )
  local available=() m code mirrors_json existing tmp

  for m in "${candidates[@]}"; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "${m}/v2/" 2>/dev/null || true)
    if [[ "$code" == "200" || "$code" == "401" ]]; then
      available+=("$m")
    fi
  done
  ((${#available[@]} > 0)) || return 1

  mkdir -p /etc/docker
  mirrors_json=$(printf '%s\n' "${available[@]}" | jq -R . | jq -s .)
  existing='{}'
  if [[ -s /etc/docker/daemon.json ]] && jq empty /etc/docker/daemon.json >/dev/null 2>&1; then
    existing=$(cat /etc/docker/daemon.json)
  fi
  tmp=$(mktemp)
  jq --argjson mirrors "$mirrors_json" '. + {"registry-mirrors": $mirrors}' <<<"$existing" >"$tmp"
  install -m 0644 "$tmp" /etc/docker/daemon.json
  rm -f "$tmp"
  systemctl restart docker
  ok "Configured reachable Docker Hub mirror(s): ${available[*]}"
}

install_and_test_docker() {
  stage "Docker installation"

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker and Compose are already operational."
    touch "$DONE_DIR/docker"
    return
  fi

  if install_docker_from_ubuntu; then
    ok "Docker installed from Ubuntu repositories."
  else
    warn "Ubuntu Docker packages failed; trying Docker official repository."
    install_docker_official_fallback || fatal "Docker installation failed."
  fi

  systemctl enable --now docker
  docker info >/dev/null || fatal "Docker daemon is not operational."
  docker compose version >/dev/null 2>&1 || fatal "Docker Compose v2 is not available."

  if docker pull hello-world:latest >/dev/null 2>&1; then
    docker image rm hello-world:latest >/dev/null 2>&1 || true
  else
    warn "Direct Docker Hub pull failed; testing registry mirrors."
    select_dockerhub_mirrors || true
  fi

  touch "$DONE_DIR/docker"
  ok "$(docker --version)"
  ok "$(docker compose version)"
}

# -----------------------------------------------------------------------------
# Stalwart installation + declarative provisioning
# -----------------------------------------------------------------------------

stalwart_binary_path() {
  # The official Linux installer uses /usr/local/bin/stalwart.  Do not rely
  # exclusively on PATH: sudo/non-login shells can have a reduced PATH.
  if [[ -x /usr/local/bin/stalwart ]]; then
    printf '%s' /usr/local/bin/stalwart
    return 0
  fi

  local candidate=""
  candidate=$(command -v stalwart 2>/dev/null || true)
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  return 1
}

stalwart_service_exists() {
  # `systemctl list-unit-files | grep` proved too brittle across systemd output
  # variants. `systemctl cat` directly asks systemd whether the unit resolves.
  systemctl cat stalwart.service >/dev/null 2>&1
}

install_stalwart() {
  stage "Stalwart installation"

  local binary="" installer=/tmp/stalwart-install.sh
  binary=$(stalwart_binary_path || true)

  if [[ -n "$binary" ]]; then
    if stalwart_service_exists; then
      ok "Existing Stalwart installation detected: $binary"
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable stalwart.service >/dev/null 2>&1 || true
      if ! systemctl is-active --quiet stalwart.service; then
        info "Stalwart is installed but not running; starting it."
        systemctl start stalwart.service || \
          fatal "Stalwart is installed but its service could not be started. Check: journalctl -u stalwart -n 100 --no-pager"
      fi
      systemctl is-active --quiet stalwart.service || \
        fatal "Stalwart service is not active after start attempt."
      touch "$DONE_DIR/stalwart-binary"
      ok "Stalwart is installed and running; binary reinstall skipped."
      return 0
    fi

    # Never run the upstream installer over an existing binary blindly. If the
    # executable is currently mapped by a process, Linux returns ETXTBSY when
    # the installer tries to replace it. More importantly, an orphaned binary
    # may belong to a non-standard installation that we should not overwrite.
    fatal "Found an existing Stalwart binary at $binary but no stalwart.service unit. Refusing to overwrite it automatically."
  fi

  # A running process without a discoverable standard binary is also treated
  # as an existing/non-standard install rather than something safe to replace.
  if pgrep -x stalwart >/dev/null 2>&1; then
    fatal "A Stalwart process is already running but its binary/service could not be identified safely. Refusing to reinstall over a running process."
  fi

  info "No existing Stalwart installation detected; installing from the official installer."
  curl --proto '=https' --tlsv1.2 -fsS --connect-timeout 10 --max-time 60 \
    https://get.stalw.art/install.sh -o "$installer" || \
    fatal "Cannot download the official Stalwart installer."
  sh "$installer"
  rm -f "$installer"

  binary=$(stalwart_binary_path || true)
  [[ -n "$binary" ]] || fatal "The official installer completed but the Stalwart binary was not found."
  stalwart_service_exists || fatal "The official installer completed but stalwart.service was not found."

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now stalwart.service >/dev/null 2>&1 || \
    fatal "Stalwart was installed but stalwart.service could not be enabled/started."
  systemctl is-active --quiet stalwart.service || \
    fatal "Stalwart service is not active after installation."

  touch "$DONE_DIR/stalwart-binary"
  ok "Stalwart binary and service installed."
}

install_stalwart_cli() {
  stage "Stalwart CLI"
  if command -v stalwart-cli >/dev/null 2>&1; then
    ok "Stalwart CLI is already installed."
    touch "$DONE_DIR/stalwart-cli"
    return
  fi

  local script=/tmp/stalwart-cli-installer.sh found
  curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 \
    https://github.com/stalwartlabs/cli/releases/latest/download/stalwart-cli-installer.sh \
    -o "$script" || fatal "Cannot download stalwart-cli."
  sh "$script"
  rm -f "$script"

  if ! command -v stalwart-cli >/dev/null 2>&1; then
    found=$(find /root -type f -name stalwart-cli -perm -u+x 2>/dev/null | head -n1 || true)
    [[ -n "$found" ]] && ln -sfn "$found" /usr/local/bin/stalwart-cli
  fi
  command -v stalwart-cli >/dev/null 2>&1 || fatal "stalwart-cli installer completed but the binary was not found."
  touch "$DONE_DIR/stalwart-cli"
  ok "Stalwart CLI installed."
}

set_env_kv() {
  local file="$1" key="$2" value="$3" tmp
  mkdir -p "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file"
  tmp=$(mktemp)
  grep -v -E "^${key}=" "$file" >"$tmp" || true
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
}

unset_env_kv() {
  local file="$1" key="$2" tmp
  [[ -f "$file" ]] || return 0
  tmp=$(mktemp)
  grep -v -E "^${key}=" "$file" >"$tmp" || true
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
}

ensure_stalwart_env_loaded_by_systemd() {
  mkdir -p /etc/systemd/system/stalwart.service.d
  cat >/etc/systemd/system/stalwart.service.d/10-katebsaber-env.conf <<'EOF'
[Service]
EnvironmentFile=-/etc/stalwart/stalwart.env
EOF
  systemctl daemon-reload
}

prepare_stalwart_recovery_mode() {
  stage "Stalwart automated recovery/bootstrap mode"

  systemctl stop stalwart >/dev/null 2>&1 || true
  id -u stalwart >/dev/null 2>&1 || useradd --system --home /var/lib/stalwart --shell /usr/sbin/nologin stalwart
  install -d -o stalwart -g stalwart -m 0750 /var/lib/stalwart
  install -d -o root -g stalwart -m 0750 /etc/stalwart

  if [[ ! -s /etc/stalwart/config.json ]]; then
    cat >/etc/stalwart/config.json <<'EOF'
{"@type":"RocksDb","path":"/var/lib/stalwart/"}
EOF
    chown root:stalwart /etc/stalwart/config.json
    chmod 0640 /etc/stalwart/config.json
    ok "Created minimal declarative RocksDB config.json."
  else
    ok "Existing Stalwart config.json preserved."
  fi

  printf '%s' "$CF_API_TOKEN" >"$CF_STALWART_TOKEN_FILE"
  chown root:stalwart "$CF_STALWART_TOKEN_FILE"
  chmod 0640 "$CF_STALWART_TOKEN_FILE"

  ensure_stalwart_env_loaded_by_systemd
  set_env_kv /etc/stalwart/stalwart.env STALWART_RECOVERY_MODE 1
  set_env_kv /etc/stalwart/stalwart.env STALWART_RECOVERY_MODE_PORT 8080
  set_env_kv /etc/stalwart/stalwart.env STALWART_RECOVERY_ADMIN "recovery:${STALWART_RECOVERY_PASSWORD}"
  set_env_kv /etc/stalwart/stalwart.env STALWART_PUBLIC_URL "https://${MAIL_HOST}"

  systemctl start stalwart

  local i
  for i in $(seq 1 30); do
    nc -z 127.0.0.1 8080 >/dev/null 2>&1 && break
    sleep 1
  done
  nc -z 127.0.0.1 8080 >/dev/null 2>&1 || fatal "Stalwart recovery API did not start on 127.0.0.1:8080."
  ok "Stalwart recovery API is available locally."
}

stalwart_cli_recovery() {
  stalwart-cli \
    --url http://127.0.0.1:8080 \
    --user recovery \
    --password "$STALWART_RECOVERY_PASSWORD" \
    "$@"
}

stalwart_cli_admin() {
  stalwart-cli \
    --url http://127.0.0.1:8080 \
    --user "$STALWART_ADMIN_USER" \
    --password "$STALWART_ADMIN_PASSWORD" \
    "$@"
}

build_stalwart_plan() {
  local publish_records
  if [[ "$DNS_PROFILE" == "full" ]]; then
    publish_records='{"autoConfig":true,"autoConfigLegacy":true,"autoDiscover":true,"caa":true,"dkim":true,"dmarc":true,"mtaSts":true,"mx":true,"spf":true,"srv":true,"tlsRpt":true}'
  else
    publish_records='{"dkim":true,"dmarc":true,"mx":true,"spf":true}'
  fi

  jq -nc \
    --arg desc "Cloudflare DNS for ${DOMAIN}" \
    --arg token_path "$CF_STALWART_TOKEN_FILE" \
    '{"@type":"upsert","object":"DnsServer","matchOn":["description"],"value":{"dns-main":{"@type":"Cloudflare","description":$desc,"secret":{"@type":"File","filePath":$token_path}}}}' \
    >"$STALWART_PLAN"

  jq -nc \
    --arg domain "$DOMAIN" \
    --arg report "mailto:postmaster@${DOMAIN}" \
    --argjson publish "$publish_records" \
    '{"@type":"upsert","object":"Domain","matchOn":["name"],"value":{"domain-main":{"name":$domain,"aliases":{},"certificateManagement":{"@type":"Manual"},"dkimManagement":{"@type":"Automatic"},"dnsManagement":{"@type":"Automatic","dnsServerId":"#dns-main","origin":$domain,"publishRecords":$publish},"subAddressing":{"@type":"Enabled"},"allowRelaying":false,"reportAddressUri":$report}}}' \
    >>"$STALWART_PLAN"

  jq -nc \
    --arg password "$STALWART_ADMIN_PASSWORD" \
    '{"@type":"upsert","object":"Account","matchOn":["name","domainId"],"value":{"admin-main":{"@type":"User","name":"admin","domainId":"#domain-main","credentials":{"0":{"@type":"Password","secret":$password}},"memberGroupIds":{},"roles":{"@type":"Admin"},"permissions":{"@type":"Inherit"},"quotas":{},"aliases":{"0":{"name":"postmaster","domainId":"#domain-main","enabled":true},"1":{"name":"abuse","domainId":"#domain-main","enabled":true}},"encryptionAtRest":{"@type":"Disabled"},"description":"Mail system administrator"}}}' \
    >>"$STALWART_PLAN"

  jq -nc \
    --arg host "$MAIL_HOST" \
    '{"@type":"update","object":"SystemSettings","value":{"defaultHostname":$host,"defaultDomainId":"#domain-main"}}' \
    >>"$STALWART_PLAN"

  jq -nc \
    '{"@type":"update","object":"Http","value":{"useXForwarded":true,"usePermissiveCors":true}}' \
    >>"$STALWART_PLAN"

  chmod 600 "$STALWART_PLAN"
}

apply_stalwart_declarative_config() {
  stage "Declarative Stalwart configuration"
  build_stalwart_plan
  stalwart_cli_recovery apply --file "$STALWART_PLAN" --dry-run >/dev/null || \
    fatal "Stalwart declarative plan failed schema validation."
  stalwart_cli_recovery apply --file "$STALWART_PLAN" --json \
    | tee "$STATE_DIR/stalwart-apply-result.ndjson" >/dev/null
  ok "Domain, Cloudflare DNS provider, admin account and core server settings were applied idempotently."
}

listener_query_json() {
  stalwart_cli_recovery query NetworkListener \
    --fields id,name,protocol,bind,useTls,tlsImplicit --json
}

find_listener_by_name_or_port() {
  local json="$1" name="$2" protocol="$3" port="$4" id

  # Prefer the stable Stalwart listener name. This lets a re-run repair a
  # listener even if its bind address/port was changed manually.
  id=$(jq -r --arg name "$name" 'select(.name == $name) | .id' <<<"$json" | head -n1 || true)
  if [[ -n "$id" && "$id" != "null" ]]; then
    printf '%s' "$id"
    return 0
  fi

  # Backward-compatibility: adopt an existing listener on the desired port even
  # if it has a non-standard name, instead of creating a duplicate bind.
  id=$(jq -r --arg proto "$protocol" --arg suffix ":${port}" '
    select(.protocol == $proto) |
    select((((.bind // {}) | keys | map(endswith($suffix))) | any)) |
    .id
  ' <<<"$json" | head -n1 || true)

  [[ -n "$id" && "$id" != "null" ]] && printf '%s' "$id"
}

create_listener_upsert() {
  local name="$1" protocol="$2" bind="$3" implicit="$4" use_tls="$5"

  # NetworkListener names are the stable natural key used by Stalwart's
  # declarative API. Using upsert keeps this safe to re-run and, critically,
  # supplies the listener name on creation (required by the server).
  jq -nc \
    --arg name "$name" \
    --arg protocol "$protocol" \
    --arg bind "$bind" \
    --argjson implicit "$implicit" \
    --argjson use_tls "$use_tls" \
    '{
      "@type":"upsert",
      "object":"NetworkListener",
      "matchOn":["name"],
      "value":{
        "listener":{
          "name":$name,
          "protocol":$protocol,
          "bind":{($bind):true},
          "useTls":$use_tls,
          "tlsImplicit":$implicit,
          "overrideProxyTrustedNetworks":{},
          "tlsDisableCipherSuites":{},
          "tlsDisableProtocols":{}
        }
      }
    }' | stalwart_cli_recovery apply --stdin --quiet >/dev/null
}

ensure_listener() {
  local json="$1" name="$2" protocol="$3" port="$4" bind="$5" implicit="$6" use_tls="$7" id
  id=$(find_listener_by_name_or_port "$json" "$name" "$protocol" "$port" || true)

  if [[ -n "$id" ]]; then
    stalwart_cli_recovery update NetworkListener "$id" \
      --field "bind={\"${bind}\":true}" \
      --field "protocol=${protocol}" \
      --field "useTls=${use_tls}" \
      --field "tlsImplicit=${implicit}" >/dev/null
    ok "Reconciled listener '${name}' on TCP/${port}."
  else
    create_listener_upsert "$name" "$protocol" "$bind" "$implicit" "$use_tls"
    ok "Created listener '${name}' on TCP/${port}."
  fi
}

configure_stalwart_listeners() {
  stage "Stalwart mail listeners"
  local listeners id

  listeners=$(listener_query_json)
  ensure_listener "$listeners" smtp smtp 25 '[::]:25' false true

  listeners=$(listener_query_json)
  ensure_listener "$listeners" submissions smtp 465 '[::]:465' true true

  listeners=$(listener_query_json)
  ensure_listener "$listeners" submission smtp 587 '[::]:587' false true

  listeners=$(listener_query_json)
  ensure_listener "$listeners" imaps imap 993 '[::]:993' true true

  # Normal-mode HTTP API/WebUI is loopback-only.
  listeners=$(listener_query_json)
  ensure_listener "$listeners" management http 8080 '127.0.0.1:8080' false false

  # If an older Stalwart setup owns public :443, move it away so Nginx owns :443.
  listeners=$(listener_query_json)
  id=$(jq -r '
    select(.protocol == "http") |
    select((((.bind // {}) | keys | map(endswith(":443"))) | any)) |
    .id
  ' <<<"$listeners" | head -n1 || true)

  if [[ -n "$id" ]]; then
    stalwart_cli_recovery update NetworkListener "$id" \
      --field 'bind={"127.0.0.1:10443":true}' \
      --field 'useTls=true' \
      --field 'tlsImplicit=true' >/dev/null
    ok "Moved existing Stalwart public :443 listener to loopback :10443 for Nginx."
  fi

  ok "SMTP 25/465/587 and IMAP 993 listeners are configured automatically."
}

# -----------------------------------------------------------------------------
# Nginx + Let's Encrypt + Stalwart TLS certificate
# -----------------------------------------------------------------------------

write_nginx_bootstrap_config() {
  install -d -m 0755 /var/www/letsencrypt/.well-known/acme-challenge
  rm -f /etc/nginx/sites-enabled/default

  cat >/etc/nginx/sites-available/mailstack <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${MAIL_HOST} ${WEBMAIL_HOST};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type text/plain;
    }

    location / {
        return 503 "TLS certificate provisioning in progress.\\n";
        add_header Content-Type text/plain;
    }
}
EOF
  ln -sfn /etc/nginx/sites-available/mailstack /etc/nginx/sites-enabled/mailstack
  nginx -t
  systemctl enable --now nginx
}

issue_tls_certificate() {
  stage "Let's Encrypt TLS certificate"
  write_nginx_bootstrap_config

  local cert_dir="/etc/letsencrypt/live/${MAIL_HOST}"
  if [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]]; then
    ok "Existing Let's Encrypt certificate found."
  else
    certbot certonly \
      --webroot -w /var/www/letsencrypt \
      -d "$MAIL_HOST" -d "$WEBMAIL_HOST" \
      --non-interactive --agree-tos --email "$LE_EMAIL" \
      --preferred-challenges http
  fi

  [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]] || \
    fatal "Let's Encrypt certificate files are missing."
  ok "TLS certificate covers $MAIL_HOST and $WEBMAIL_HOST."
}

configure_stalwart_certificate_in_recovery() {
  stage "Stalwart TLS certificate object"

  local cert_src="/etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem"
  local key_src="/etc/letsencrypt/live/${MAIL_HOST}/privkey.pem"
  local cert_id=""

  install -d -o root -g stalwart -m 0750 /etc/stalwart/certs
  install -o root -g stalwart -m 0640 "$cert_src" /etc/stalwart/certs/fullchain.pem
  install -o root -g stalwart -m 0640 "$key_src" /etc/stalwart/certs/privkey.pem

  cert_id=$(stalwart_cli_recovery query Certificate \
    --where "subjectAlternativeNames=${MAIL_HOST}" --fields id --json 2>/dev/null \
    | jq -r '.id' | head -n1 || true)

  if [[ -n "$cert_id" && "$cert_id" != "null" ]]; then
    stalwart_cli_recovery update Certificate "$cert_id" \
      --field 'certificate={"@type":"File","filePath":"/etc/stalwart/certs/fullchain.pem"}' \
      --field 'privateKey={"@type":"File","filePath":"/etc/stalwart/certs/privkey.pem"}' >/dev/null
    ok "Updated existing Stalwart certificate object."
  else
    stalwart_cli_recovery create Certificate \
      --field 'certificate={"@type":"File","filePath":"/etc/stalwart/certs/fullchain.pem"}' \
      --field 'privateKey={"@type":"File","filePath":"/etc/stalwart/certs/privkey.pem"}' >/dev/null
    sleep 1
    cert_id=$(stalwart_cli_recovery query Certificate \
      --where "subjectAlternativeNames=${MAIL_HOST}" --fields id --json \
      | jq -r '.id' | head -n1)
    ok "Created Stalwart certificate object."
  fi

  [[ -n "$cert_id" && "$cert_id" != "null" ]] || fatal "Could not determine Stalwart certificate ID."
  stalwart_cli_recovery update SystemSettings --field "defaultCertificateId=${cert_id}" >/dev/null
  ok "Configured certificate as Stalwart default TLS certificate."
}

create_certbot_deploy_hook() {
  stage "Automatic TLS renewal hook"
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy

  cat >/etc/letsencrypt/renewal-hooks/deploy/20-katebsaber-stalwart.sh <<EOF
#!/bin/sh
set -eu
MAIL_HOST='${MAIL_HOST}'

case " \${RENEWED_DOMAINS:-} " in
  *" \${MAIL_HOST} "*) ;;
  *) exit 0 ;;
esac

install -d -o root -g stalwart -m 0750 /etc/stalwart/certs
install -o root -g stalwart -m 0640 "\${RENEWED_LINEAGE}/fullchain.pem" /etc/stalwart/certs/fullchain.pem
install -o root -g stalwart -m 0640 "\${RENEWED_LINEAGE}/privkey.pem" /etc/stalwart/certs/privkey.pem
systemctl restart stalwart
nginx -t
systemctl reload nginx
EOF
  chmod 0750 /etc/letsencrypt/renewal-hooks/deploy/20-katebsaber-stalwart.sh
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  ok "Certbot renewals will refresh Stalwart and Nginx automatically."
}

write_final_nginx_config() {
  stage "Nginx reverse proxy"

  cat >/etc/nginx/sites-available/mailstack <<EOF
map \$http_upgrade \$katebsaber_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${MAIL_HOST} ${WEBMAIL_HOST};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${MAIL_HOST};

    ssl_certificate     /etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${MAIL_HOST}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    add_header Strict-Transport-Security "max-age=31536000" always;
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$katebsaber_connection_upgrade;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${WEBMAIL_HOST};

    ssl_certificate     /etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${MAIL_HOST}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    add_header Strict-Transport-Security "max-age=31536000" always;
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$katebsaber_connection_upgrade;
        proxy_buffering off;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  ok "Nginx is configured for Stalwart Admin/JMAP and Bulwark Webmail."
}

exit_stalwart_recovery_mode() {
  stage "Activate normal Stalwart services"

  unset_env_kv /etc/stalwart/stalwart.env STALWART_RECOVERY_MODE
  unset_env_kv /etc/stalwart/stalwart.env STALWART_RECOVERY_MODE_PORT
  unset_env_kv /etc/stalwart/stalwart.env STALWART_RECOVERY_ADMIN
  set_env_kv /etc/stalwart/stalwart.env STALWART_PUBLIC_URL "https://${MAIL_HOST}"

  systemctl restart stalwart

  local i
  for i in $(seq 1 30); do
    if nc -z 127.0.0.1 8080 >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  systemctl is-active --quiet stalwart || fatal "Stalwart failed to start in normal mode."
  nc -z 127.0.0.1 8080 >/dev/null 2>&1 || fatal "Normal Stalwart HTTP listener is not available on loopback:8080."
  ok "Recovery backdoor credentials were removed and Stalwart restarted normally."
}

validate_stalwart_admin() {
  stage "Stalwart permanent administrator validation"
  stalwart_cli_admin get SystemSettings --json >/dev/null 2>&1 || \
    fatal "Permanent Stalwart administrator login failed: ${STALWART_ADMIN_USER}"
  ok "Permanent Stalwart administrator is valid: ${STALWART_ADMIN_USER}"
}

# -----------------------------------------------------------------------------
# Bulwark
# -----------------------------------------------------------------------------

configure_docker_proxy_from_environment() {
  local proxy="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
  [[ -n "$proxy" ]] || return 1
  mkdir -p /etc/systemd/system/docker.service.d
  cat >/etc/systemd/system/docker.service.d/10-katebsaber-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${proxy}"
Environment="HTTPS_PROXY=${proxy}"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
EOF
  systemctl daemon-reload
  systemctl restart docker
  ok "Applied existing shell proxy to Docker daemon."
}

install_node22_binary() {
  local arch node_arch base="" candidate version tarball tmp expected actual
  arch=$(uname -m)
  case "$arch" in
    x86_64) node_arch="x64" ;;
    aarch64|arm64) node_arch="arm64" ;;
    *) fatal "Native Bulwark fallback does not support architecture: $arch" ;;
  esac

  for candidate in "https://nodejs.org/dist" "https://npmmirror.com/mirrors/node"; do
    if curl -fsS --connect-timeout 8 --max-time 20 "${candidate}/index.json" -o /tmp/node-index.json; then
      base="$candidate"
      break
    fi
  done
  [[ -n "$base" ]] || fatal "Cannot reach Node.js distribution servers."

  version=$(jq -r '[.[] | select(.version | startswith("v22."))][0].version // empty' /tmp/node-index.json)
  [[ -n "$version" ]] || fatal "Could not determine the latest Node.js 22 release."
  tarball="node-${version}-linux-${node_arch}.tar.xz"
  tmp=$(mktemp -d)

  curl -fL --retry 3 --connect-timeout 10 --max-time 300 "${base}/${version}/${tarball}" -o "${tmp}/${tarball}"
  curl -fL --retry 3 --connect-timeout 10 --max-time 60 "${base}/${version}/SHASUMS256.txt" -o "${tmp}/SHASUMS256.txt"
  expected=$(awk -v f="$tarball" '$2==f {print $1}' "${tmp}/SHASUMS256.txt")
  actual=$(sha256sum "${tmp}/${tarball}" | awk '{print $1}')
  [[ -n "$expected" && "$expected" == "$actual" ]] || fatal "Node.js SHA-256 verification failed."

  rm -rf "/opt/node-${version}"
  mkdir -p "/opt/node-${version}"
  tar -xJf "${tmp}/${tarball}" --strip-components=1 -C "/opt/node-${version}"
  for bin in node npm npx corepack; do
    [[ -x "/opt/node-${version}/bin/${bin}" ]] && ln -sfn "/opt/node-${version}/bin/${bin}" "/usr/local/bin/${bin}"
  done
  rm -rf "$tmp" /tmp/node-index.json
  ok "Installed $(node --version)."
}

install_bulwark_docker() {
  mkdir -p /opt/bulwark-docker

  cat >/opt/bulwark-docker/compose.yml <<EOF
services:
  bulwark:
    image: ghcr.io/bulwarkmail/webmail:latest
    container_name: bulwark
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      HOSTNAME: "0.0.0.0"
      PORT: "3000"
      JMAP_SERVER_URL: "https://${MAIL_HOST}"
      SESSION_SECRET: "${BULWARK_SESSION_SECRET}"
      ADMIN_PASSWORD: "${BULWARK_ADMIN_PASSWORD}"
      SETTINGS_SYNC_ENABLED: "true"
      BULWARK_TELEMETRY: "off"
    volumes:
      - bulwark-settings:/app/data/settings
      - bulwark-config:/app/data/admin
      - bulwark-state:/app/data/admin-state
      - bulwark-telemetry:/app/data/telemetry

volumes:
  bulwark-settings:
  bulwark-config:
  bulwark-state:
  bulwark-telemetry:
EOF

  chmod 0600 /opt/bulwark-docker/compose.yml
  (cd /opt/bulwark-docker && docker compose pull && docker compose up -d)
  BULWARK_MODE="docker"
}

install_bulwark_native() {
  stage "Bulwark native fallback"

  if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -lt 20 ]]; then
    install_node22_binary
  fi

  if ! curl -fsSI --connect-timeout 8 --max-time 15 https://registry.npmjs.org/ >/dev/null 2>&1; then
    npm config set registry https://registry.npmmirror.com
  fi

  if [[ ! -d /opt/bulwark/.git ]]; then
    rm -rf /opt/bulwark
    git clone --depth 1 https://github.com/bulwarkmail/webmail.git /opt/bulwark
  else
    git -C /opt/bulwark fetch --depth 1 origin HEAD
    git -C /opt/bulwark reset --hard FETCH_HEAD
  fi

  cd /opt/bulwark
  if [[ -f package-lock.json ]]; then
    npm ci
  else
    npm install
  fi
  npm run build

  id -u bulwark >/dev/null 2>&1 || useradd --system --home /var/lib/bulwark --shell /usr/sbin/nologin bulwark
  install -d -o bulwark -g bulwark -m 0750 \
    /var/lib/bulwark/admin \
    /var/lib/bulwark/admin-state \
    /var/lib/bulwark/settings \
    /var/lib/bulwark/telemetry
  install -d -m 0750 /etc/bulwark
  chown -R bulwark:bulwark /opt/bulwark

  cat >/etc/bulwark/bulwark.env <<EOF
NODE_ENV=production
HOSTNAME=127.0.0.1
PORT=3000
JMAP_SERVER_URL=https://${MAIL_HOST}
SESSION_SECRET=${BULWARK_SESSION_SECRET}
ADMIN_PASSWORD=${BULWARK_ADMIN_PASSWORD}
SETTINGS_SYNC_ENABLED=true
BULWARK_TELEMETRY=off
ADMIN_CONFIG_DIR=/var/lib/bulwark/admin
ADMIN_STATE_DIR=/var/lib/bulwark/admin-state
SETTINGS_DATA_DIR=/var/lib/bulwark/settings
TELEMETRY_DATA_DIR=/var/lib/bulwark/telemetry
EOF
  chmod 0640 /etc/bulwark/bulwark.env
  chown root:bulwark /etc/bulwark/bulwark.env

  cat >/etc/systemd/system/bulwark.service <<'EOF'
[Unit]
Description=Bulwark Webmail
After=network-online.target nginx.service stalwart.service
Wants=network-online.target

[Service]
Type=simple
User=bulwark
Group=bulwark
WorkingDirectory=/opt/bulwark
EnvironmentFile=/etc/bulwark/bulwark.env
ExecStart=/usr/local/bin/npm start
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/bulwark /opt/bulwark/.next

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now bulwark
  BULWARK_MODE="native"
}

install_bulwark() {
  stage "Bulwark deployment"

  if docker inspect bulwark >/dev/null 2>&1; then
    if [[ -f /opt/bulwark-docker/compose.yml ]]; then
      (cd /opt/bulwark-docker && docker compose up -d)
    else
      docker start bulwark >/dev/null 2>&1 || true
    fi
    BULWARK_MODE="docker"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^bulwark\.service'; then
    systemctl enable --now bulwark
    BULWARK_MODE="native"
  else
    if docker pull ghcr.io/bulwarkmail/webmail:latest >/dev/null 2>&1; then
      install_bulwark_docker
    elif configure_docker_proxy_from_environment && docker pull ghcr.io/bulwarkmail/webmail:latest >/dev/null 2>&1; then
      install_bulwark_docker
    else
      warn "GHCR unavailable; using the official Bulwark source as native fallback."
      install_bulwark_native
    fi
  fi

  local i
  for i in $(seq 1 30); do
    if curl -fsS --connect-timeout 3 http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if ! curl -fsS --connect-timeout 5 http://127.0.0.1:3000/api/health >/dev/null; then
    if [[ "$BULWARK_MODE" == "docker" ]]; then
      docker logs --tail 100 bulwark || true
    else
      journalctl -u bulwark -n 100 --no-pager || true
    fi
    fatal "Bulwark health endpoint is not healthy."
  fi

  ok "Bulwark is healthy on loopback port 3000 (${BULWARK_MODE})."
  write_secrets_summary
}

# -----------------------------------------------------------------------------
# Stalwart-managed DNS verification
# -----------------------------------------------------------------------------

fetch_stalwart_dns_zone() {
  stage "Stalwart generated DNS zone"
  local domain_id zone

  domain_id=$(stalwart_cli_admin query Domain --where "name=${DOMAIN}" --fields id,name --json \
    | jq -r --arg domain "$DOMAIN" 'select(.name == $domain) | .id' | head -n1)
  [[ -n "$domain_id" && "$domain_id" != "null" ]] || fatal "Could not find Stalwart domain object for ${DOMAIN}."

  zone=$(stalwart_cli_admin get Domain "$domain_id" --fields dnsZoneFile --json | jq -r '.dnsZoneFile // empty')
  [[ -n "$zone" ]] || fatal "Stalwart returned an empty DNS zone for ${DOMAIN}."

  printf '%s\n' "$zone" >"$DNS_ZONE_FILE"
  chmod 600 "$DNS_ZONE_FILE"
  ok "Stalwart DNS zone snapshot saved to ${DNS_ZONE_FILE}."
}

verify_auth_dns() {
  stage "SPF / DKIM / DMARC validation"
  local attempt spf dmarc selectors selector query_name missing

  selectors=$(grep -Eio '[A-Za-z0-9_-]+\._domainkey(\.[A-Za-z0-9._-]+)?\.?' "$DNS_ZONE_FILE" | sort -u || true)

  for attempt in $(seq 1 36); do
    missing=0

    spf=$(dig +short TXT "$DOMAIN" @1.1.1.1 2>/dev/null | tr -d '"' | grep -m1 'v=spf1' || true)
    [[ -n "$spf" ]] || missing=$((missing+1))

    dmarc=$(dig +short TXT "_dmarc.${DOMAIN}" @1.1.1.1 2>/dev/null | tr -d '"' | grep -m1 -i 'v=DMARC1' || true)
    [[ -n "$dmarc" ]] || missing=$((missing+1))

    if [[ -n "$selectors" ]]; then
      while IFS= read -r selector; do
        [[ -n "$selector" ]] || continue
        selector=${selector%.}
        if [[ "$selector" == *".${DOMAIN}" ]]; then
          query_name="$selector"
        else
          query_name="${selector}.${DOMAIN}"
        fi
        if ! dig +short TXT "$query_name" @1.1.1.1 2>/dev/null | tr -d '"' | grep -qi 'DKIM'; then
          missing=$((missing+1))
        fi
      done <<<"$selectors"
    else
      missing=$((missing+1))
    fi

    if (( missing == 0 )); then
      ok "SPF, DMARC and all generated DKIM selectors are publicly visible."
      return
    fi

    info "Waiting for Stalwart-managed sender-auth DNS to become publicly visible (attempt ${attempt})..."
    sleep 5
  done

  fatal "Stalwart DNS automation did not become publicly visible. Check Cloudflare token permissions and Stalwart DNS task logs."
}

validate_mail_ports() {
  stage "Mail listener validation"
  local p
  for p in 25 465 587 993; do
    if ss -ltnp 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"; then
      ok "TCP/${p} is listening."
    else
      fatal "Stalwart is not listening on TCP/${p}; automatic listener reconciliation failed."
    fi
  done
}

final_health_checks() {
  stage "Final health checks"

  curl -fsS --connect-timeout 10 "https://${MAIL_HOST}/.well-known/jmap" >/dev/null || \
    fatal "Public Stalwart JMAP endpoint failed."
  ok "Public JMAP discovery works."

  curl -fsS --connect-timeout 10 "https://${WEBMAIL_HOST}/api/health" >/dev/null || \
    fatal "Public Bulwark health endpoint failed."
  ok "Public Bulwark health endpoint works."

  if openssl s_client -connect "${MAIL_HOST}:993" -servername "$MAIL_HOST" -verify_return_error </dev/null 2>/dev/null \
      | grep -q 'Verify return code: 0'; then
    ok "IMAPS 993 presents a valid TLS certificate."
  else
    fatal "IMAPS 993 TLS verification failed."
  fi

  if openssl s_client -connect "${MAIL_HOST}:465" -servername "$MAIL_HOST" -verify_return_error </dev/null 2>/dev/null \
      | grep -q 'Verify return code: 0'; then
    ok "SMTPS 465 presents a valid TLS certificate."
  else
    fatal "SMTPS 465 TLS verification failed."
  fi

  if openssl s_client -starttls smtp -connect "${MAIL_HOST}:587" -servername "$MAIL_HOST" -verify_return_error </dev/null 2>/dev/null \
      | grep -q 'Verify return code: 0'; then
    ok "SMTP submission 587 STARTTLS presents a valid TLS certificate."
  else
    fatal "SMTP submission 587 STARTTLS verification failed."
  fi

  nginx -t >/dev/null
  systemctl is-active --quiet nginx || fatal "Nginx is not active."
  systemctl is-active --quiet stalwart || fatal "Stalwart is not active."

  if [[ "$BULWARK_MODE" == "docker" ]]; then
    docker inspect -f '{{.State.Running}}' bulwark 2>/dev/null | grep -q true || fatal "Bulwark container is not running."
  else
    systemctl is-active --quiet bulwark || fatal "Bulwark service is not active."
  fi

  ok "All primary services are healthy."
}

print_final_summary() {
  stage "Installation complete"
  write_secrets_summary

  cat <<EOF

Everything is installed and the primary health checks passed.

Web interfaces
--------------
Stalwart Admin:  https://${MAIL_HOST}/admin
  Username:      ${STALWART_ADMIN_USER}
  Password:      ${STALWART_ADMIN_PASSWORD}

Bulwark Webmail: https://${WEBMAIL_HOST}
  Admin secret:  ${BULWARK_ADMIN_PASSWORD}

Mail client settings
--------------------
IMAP server:        ${MAIL_HOST}
IMAP port:          993
IMAP security:      SSL/TLS

SMTP server:        ${MAIL_HOST}
SMTP port:          465
SMTP security:      SSL/TLS

Alternative SMTP:   ${MAIL_HOST}:587
Security:           STARTTLS
Username:           Full email address

Automation
----------
Cloudflare bootstrap A/MX records: reconciled automatically
Stalwart SPF/DKIM/DMARC:           maintained automatically through Cloudflare
Stalwart listeners incl. 587:      reconciled automatically
Let's Encrypt renewal:             automatic via certbot.timer
Installer resume state:            ${STATE_DIR}

Important files
---------------
Installer log:      ${LOG_FILE}
DNS zone snapshot:  ${DNS_ZONE_FILE}
Credentials:        ${SECRETS_FILE}
Stalwart config:    /etc/stalwart/config.json
Nginx config:       /etc/nginx/sites-available/mailstack
Cloudflare token:   ${CF_TOKEN_FILE} (root-only)

Recommended final delivery test
-------------------------------
1. Sign in to Stalwart Admin with the credentials above.
2. Create a normal mailbox.
3. Sign in to Bulwark with that mailbox.
4. Send one message to Gmail and one to Outlook.
5. In Gmail -> Show original, confirm SPF=PASS, DKIM=PASS and DMARC=PASS.

Security
--------
The Cloudflare token is restricted to DNS write + zone read for one zone.
The Stalwart recovery credential is removed from the service environment after provisioning.
Ports 8080 and 3000 are loopback-only; Nginx is the public HTTPS entry point.

by amirmohammad katebsaber
EOF

  echo
  ok "Mail stack installation finished successfully."
}

main() {
  parse_args "$@"
  banner
  require_root
  validate_ubuntu

  if (( RESET_PROGRESS )); then
    rm -f "$DONE_DIR"/* 2>/dev/null || true
    info "Completed-step markers cleared; configuration and secrets were preserved."
  fi

  warn "Designed for Ubuntu 24.04. Existing Stalwart data/config is preserved and reconciled; it is not wiped."
  echo
  confirm "Start/resume the installation?" Y || exit 0

  collect_configuration
  load_or_create_secrets
  write_secrets_summary

  # DNS bootstrap is intentionally before certificate issuance.
  install_base_packages
  ensure_cloudflare_token
  cloudflare_find_zone
  cloudflare_bootstrap_dns
  validate_bootstrap_dns
  validate_ptr

  check_initial_port_conflicts
  check_outbound_smtp
  hostnamectl set-hostname "$MAIL_HOST"
  configure_firewall
  install_and_test_docker

  # Fully non-interactive Stalwart provisioning via recovery API + declarative plan.
  install_stalwart
  install_stalwart_cli
  prepare_stalwart_recovery_mode
  apply_stalwart_declarative_config
  configure_stalwart_listeners

  # TLS is provisioned before normal Stalwart mode so implicit TLS listeners
  # never need to start without a real certificate.
  issue_tls_certificate
  configure_stalwart_certificate_in_recovery
  create_certbot_deploy_hook
  write_final_nginx_config

  exit_stalwart_recovery_mode
  validate_stalwart_admin

  install_bulwark
  nginx -t >/dev/null && systemctl reload nginx

  # Automatic DNS jobs run in normal Stalwart mode.
  fetch_stalwart_dns_zone
  verify_auth_dns
  validate_mail_ports
  final_health_checks
  print_final_summary
}

main "$@"
