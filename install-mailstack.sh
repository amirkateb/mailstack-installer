#!/usr/bin/env bash
# ==============================================================================
# Stalwart + Bulwark Mail Stack Installer for Ubuntu 24.04 LTS
# Fully automated installer + lifecycle manager with Cloudflare DNS automation
# by amirmohammad katebsaber
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_VERSION="5.0.0"
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
FORCE_INSTALL=0
MANAGER_ACTION=""
GITHUB_API="https://api.github.com"
BACKUP_ROOT="${STATE_DIR}/backups"
EXTRA_DOMAINS_DIR="${STATE_DIR}/domains"
EXTRA_CF_TOKENS_DIR="${STATE_DIR}/cloudflare-domains"
EXTRA_STALWART_TOKENS_DIR="/etc/stalwart/cloudflare-tokens"
FULL_BACKUP_DIR="${STATE_DIR}/full-backups"
BACKUP_PASSWORD_FILE="/root/mailstack-backup-passphrase.txt"
ALERTS_CONFIG="${STATE_DIR}/alerts.env"
ALERTS_STATE="${STATE_DIR}/alerts-state"
MANAGER_PERSISTENT="/usr/local/sbin/katebsaber-mailstack-manager"
BACKUP_PATH=""
MANAGER_LOCK="${STATE_DIR}/manager-global.lock"

# Colors
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'
  BOLD='\033[1m'; RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' DIM='' BOLD='' RESET=''
fi

mkdir -p "$STATE_DIR" "$DONE_DIR" "$LOG_DIR" "$BACKUP_ROOT" "$FULL_BACKUP_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

script_identity() {
  local script_path script_hash
  script_path=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
  script_hash=$(sha256sum "$script_path" 2>/dev/null | awk '{print $1}' || true)
  info "Installer version: ${SCRIPT_VERSION}"
  info "Installer path:    ${script_path}"
  [[ -n "$script_hash" ]] && info "Installer SHA-256: ${script_hash}"
}

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
  printf '%b\n' "${RESET}${DIM}Version ${SCRIPT_VERSION} • Ubuntu 24.04 LTS • installer + manager • resumable${RESET}"
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
  printf '%b\n' "${RED}Command:${RESET} [redacted to protect credentials]"
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
  --install           Bypass manager detection and run/resume provisioning.
  --status            On a managed install, print versions/status and exit.
  --update-all        On a managed install, update all safe components and exit.
  --list-domains      List the domains configured in Stalwart.
  --add-domain        Add a new managed mail domain (interactive).
  --remove-domain     Two-stage retirement of a secondary domain (interactive).
  --domain-health     Check DNS and domain management status (read-only).
  --accounts          List/manage mail accounts (interactive).
  --queue             Inspect the outbound queue (read-only).
  --backup-now        Encrypted cold backup of local Stalwart store and mail stack.
  --verify-backup P   Verify the encrypted archive digest and contents.
  --restore-backup P  Confirm and restore a verified local encrypted backup.
  --backup-timer      Install daily backup and health/alert timers.
  --alerts            Configure Telegram alerts (interactive).
  --migration-plan    Create a no-write DNS migration report (interactive).
  --dns-preview       Read-only domain onboarding DNS preview (interactive).
  --test-mail         Test authenticated SMTP submission (interactive).
  --security-review   Read-only credentials/firewall/TLS configuration audit.
  --rotate-cf-token   Rotate primary or secondary Cloudflare token (interactive).
  --cancel-retirement Cancel a pending domain retirement (interactive).
  --advanced-dns     Check MTA-STS, TLS-RPT and autoconfig policies (read-only).
  --virtual-mail      Independent Cloudflare Email Routing manager.
  --virtual-mail-reconcile   Complete verified pending Cloudflare forwards (timer).
  --alert-check       Systemd alert check (non-interactive).
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
      --install) FORCE_INSTALL=1 ;;
      --status) MANAGER_ACTION="status" ;;
      --update-all) MANAGER_ACTION="update-all" ;;
      --list-domains) MANAGER_ACTION="list-domains" ;;
      --add-domain) MANAGER_ACTION="add-domain" ;;
      --remove-domain) MANAGER_ACTION="remove-domain" ;;
      --domain-health) MANAGER_ACTION="domain-health" ;;
      --accounts) MANAGER_ACTION="accounts" ;;
      --queue) MANAGER_ACTION="queue" ;;
      --backup-now) MANAGER_ACTION="backup-now" ;;
      --backup-timer) MANAGER_ACTION="backup-timer" ;;
      --alerts) MANAGER_ACTION="alerts" ;;
      --migration-plan) MANAGER_ACTION="migration-plan" ;;
      --dns-preview) MANAGER_ACTION="dns-preview" ;;
      --test-mail) MANAGER_ACTION="test-mail" ;;
      --security-review) MANAGER_ACTION="security-review" ;;
      --rotate-cf-token) MANAGER_ACTION="rotate-cf-token" ;;
      --cancel-retirement) MANAGER_ACTION="cancel-retirement" ;;
      --advanced-dns) MANAGER_ACTION="advanced-dns" ;;
      --virtual-mail) MANAGER_ACTION="virtual-mail" ;;
      --virtual-mail-reconcile) MANAGER_ACTION="virtual-mail-reconcile" ;;
      --alert-check) MANAGER_ACTION="alert-check" ;;
      --verify-backup|--restore-backup)
        MANAGER_ACTION="${1#--}"; shift
        [[ $# -gt 0 ]] || { err "Backup path is required."; exit 2; }
        BACKUP_PATH="$1" ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown option: $1"; usage; exit 2 ;;
    esac
    shift
  done
}

pause() {
  local prompt=${1:-"Press Enter to continue..."}
  if (( NONINTERACTIVE )); then
    return 0
  fi
  read -r -p "$prompt" _
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
  # Retain previous root-only TXT versions instead of silently discarding
  # user-added notes or saved credentials. This TXT remains by design.
  if [[ -s "$SECRETS_FILE" ]]; then
    install -d -m 0700 "${STATE_DIR}/credential-history"
    cp -p "$SECRETS_FILE" "${STATE_DIR}/credential-history/secrets-$(date +%Y%m%d%H%M%S%N).txt"
  fi
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
Primary Cloudflare API token: $(if [[ -s "$CF_TOKEN_FILE" ]]; then cat "$CF_TOKEN_FILE"; else printf '%s' '(not configured)'; fi)
Root-only token state: ${CF_TOKEN_FILE}
Stalwart token file: ${CF_STALWART_TOKEN_FILE}

Important
---------
The temporary Stalwart recovery credential is intentionally omitted from this file.
It is removed from the Stalwart runtime environment before normal operation.
EOF
  {
    echo
    echo "Secondary Cloudflare domain tokens"
    echo "--------------------------------"
    local tok d
    for tok in "${EXTRA_CF_TOKENS_DIR}"/*.token "${EXTRA_CF_TOKENS_DIR}"/archive/*.token \
      "${EXTRA_CF_TOKENS_DIR}"/*.token.inactive-*; do
      [[ -s "$tok" ]] || continue
      d=$(basename "$tok" .token)
      printf '%s: %s\n' "$d" "$(cat "$tok")"
    done
    if [[ -s "$ALERTS_CONFIG" ]]; then
      echo
      echo "Telegram alert settings: ${ALERTS_CONFIG}"
      # Configuration is sourced from a root-only generated %q file.
      local TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
      source "$ALERTS_CONFIG"
      echo "Telegram Bot Token: ${TELEGRAM_BOT_TOKEN}"
      echo "Telegram Chat ID: ${TELEGRAM_CHAT_ID}"
    fi
    if [[ -s "$BACKUP_PASSWORD_FILE" ]]; then
      echo "Backup encryption passphrase file: ${BACKUP_PASSWORD_FILE}"
      echo "Backup encryption passphrase: $(cat "$BACKUP_PASSWORD_FILE")"
    fi
  } >> "$SECRETS_FILE"
  if [[ -s /root/mailstack-mailboxes.txt ]]; then
    printf '\nManaged mailbox credentials (root-only)\n---------------------------------------\n' >>"$SECRETS_FILE"
    cat /root/mailstack-mailboxes.txt >>"$SECRETS_FILE"
  fi
  # v5: preserve Virtual Mail tokens in the TXT whenever the v4.3 workflow
  # regenerates this file (the original TXT was archived above, too).
  if [[ -d "${STATE_DIR}/virtual-mail/tokens" ]]; then
    printf '\nCloudflare Virtual Mail active tokens (root-only)\n' >>"$SECRETS_FILE"
    local vmt
    for vmt in "${STATE_DIR}/virtual-mail/tokens"/*.token; do
      [[ -s "$vmt" ]] || continue
      printf '%s: %s\n' "$(basename "$vmt" .token)" "$(cat "$vmt")" >>"$SECRETS_FILE"
    done
    printf 'Previous rotated tokens: ${STATE_DIR}/virtual-mail/archive/\n' >>"$SECRETS_FILE"
  fi
  chmod 600 "$SECRETS_FILE"
}

# -----------------------------------------------------------------------------
# Cloudflare API
# -----------------------------------------------------------------------------

cf_api_raw() {
  local method="$1" endpoint="$2" data=${3:-} response
  # Supply Authorization via curl's stdin-config, never process argv or logs.
  [[ "${CF_API_TOKEN:-}" =~ ^[A-Za-z0-9._-]+$ ]] || {
    err "Invalid Cloudflare token format; no request sent."; return 1;
  }
  if [[ -n "$data" ]]; then
    response=$(curl --connect-timeout 8 --max-time 35 -sS --fail-with-body -X "$method" "${CLOUDFLARE_API}${endpoint}" \
      -K - -H 'Content-Type: application/json' \
      --data "$data" <<<"header = \"Authorization: Bearer ${CF_API_TOKEN}\"") || return 1
  else
    response=$(curl --connect-timeout 8 --max-time 35 -sS --fail-with-body -X "$method" "${CLOUDFLARE_API}${endpoint}" \
      -K - -H 'Content-Type: application/json' \
      <<<"header = \"Authorization: Bearer ${CF_API_TOKEN}\"") || return 1
  fi
  jq -e '.success == true' >/dev/null <<<"$response" || {
    jq -r '.errors[]? | "Cloudflare: \(.code): \(.message)"' <<<"$response" >&2 || true
    return 1
  }
  printf '%s' "$response"
}

cf_api_get_query() {
  local endpoint="$1"
  [[ "${CF_API_TOKEN:-}" =~ ^[A-Za-z0-9._-]+$ ]] || {
    err "Invalid Cloudflare token format; no request sent."; return 1;
  }
  shift
  local args=() pair response
  for pair in "$@"; do
    args+=(--data-urlencode "$pair")
  done
  response=$(curl --retry 3 --retry-delay 2 --retry-max-time 90 --connect-timeout 8 --max-time 25 -sS --fail-with-body -G "${CLOUDFLARE_API}${endpoint}" \
    -K - -H 'Content-Type: application/json' \
    "${args[@]}" <<<"header = \"Authorization: Bearer ${CF_API_TOKEN}\"") || return 1
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
      ok "REINSTALL SKIPPED: the existing Stalwart binary will not be overwritten."
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
  STALWART_URL=http://127.0.0.1:8080 \
  STALWART_USER=recovery \
  STALWART_PASSWORD="$STALWART_RECOVERY_PASSWORD" stalwart-cli "$@"
}

stalwart_cli_admin() {
  STALWART_URL=http://127.0.0.1:8080 \
  STALWART_USER="$STALWART_ADMIN_USER" \
  STALWART_PASSWORD="$STALWART_ADMIN_PASSWORD" stalwart-cli "$@"
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
    image: "${BULWARK_IMAGE:-ghcr.io/bulwarkmail/webmail:latest}"
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
  Password:      (stored in ${SECRETS_FILE})

Bulwark Webmail: https://${WEBMAIL_HOST}
  Admin secret:  (stored in ${SECRETS_FILE})

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
  echo
  printf '%b\n' "${CYAN}${BOLD}================ ACCESS CREDENTIALS ================${RESET}"
  printf '%b\n' "${YELLOW}${BOLD}Keep these credentials private.${RESET}"
  echo
  cat "$SECRETS_FILE"
  echo
  printf '%b\n' "${CYAN}${BOLD}====================================================${RESET}"
  info "Credentials are also saved at: ${SECRETS_FILE}"
}


# -----------------------------------------------------------------------------
# Multi-domain lifecycle (v4) — additive, without restarting/reprovisioning mail
#
# Stalwart Domain.dnsManagement -> per-zone Cloudflare DnsServer; all domains
# share the already TLS-enabled MAIL_HOST / WEBMAIL_HOST and the existing PTR.
# A domain is NOT a new SMTP server; no new A, TLS certificate or nginx vhost
# is required. The primary domain, admin and existing mailboxes remain intact.
# -----------------------------------------------------------------------------

multi_domain_preflight() {
  stage "Multi-domain prerequisites"
  local tool
  for tool in jq curl stalwart-cli dig flock; do
    command -v "$tool" >/dev/null 2>&1 || { err "Required command missing: $tool"; return 1; }
  done
  systemctl is-active --quiet stalwart || { err "Stalwart is not running."; return 1; }
  stalwart_cli_admin get SystemSettings --json >/dev/null 2>&1 || {
    err "Could not authenticate to the Stalwart management API. Check stored admin credentials."
    return 1
  }
  install -d -m 0700 "$EXTRA_DOMAINS_DIR" "$EXTRA_CF_TOKENS_DIR"
  install -d -o root -g stalwart -m 0750 "$EXTRA_STALWART_TOKENS_DIR"
}

# Query emits NDJSON. Never assume --json wraps the result in an array.
stalwart_domain_rows() {
  stalwart_cli_admin query Domain --fields id,name --json
}

stalwart_domain_id() {
  local target="$1" rows
  rows=$(stalwart_domain_rows) || return 1
  jq -rs --arg domain "$target" '[.[] | select((.name // "" | ascii_downcase)==$domain) | .id] | if length == 1 then .[0] else empty end' <<<"$rows"
}

multi_domain_state_file() { printf '%s/%s.json' "$EXTRA_DOMAINS_DIR" "$1"; }
multi_domain_token_file() { printf '%s/%s.token' "$EXTRA_CF_TOKENS_DIR" "$1"; }
multi_domain_stalwart_token_file() { printf '%s/%s.token' "$EXTRA_STALWART_TOKENS_DIR" "$1"; }

# Atomic JSON writes avoid losing the recovery journal on interrupted writes.
multi_domain_state_update() {
  local file="$1" filter="$2" tmp
  shift 2
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  if jq "$@" "$filter" "$file" >"$tmp"; then
    chmod 0600 "$tmp"
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

multi_domain_cloudflare_auth() {
  local domain="$1" token_file token response zone_json zone_count candidate origin matched
  token_file=$(multi_domain_token_file "$domain")
  while true; do
    if [[ -s "$token_file" ]]; then
      token=$(<"$token_file")
      info "Using saved restricted Cloudflare token for $domain."
    else
      echo
      printf '%s\n' "Create a NEW Cloudflare API token for this additional domain:"
      printf '  %s\n' "$CLOUDFLARE_TOKEN_URL"
      cat <<EOF
  Name: KatebSaber MailStack - ${domain}
  Permissions: Zone -> DNS -> Edit; Zone -> Zone -> Read
  Zone Resources: Include -> Specific zone containing ${domain}
  For subdomains (e.g. team.example.com), select the authoritative parent zone (example.com).
  Do NOT use a Global API key or the existing primary-domain token.
EOF
      if (( NONINTERACTIVE )); then
        err "A new Cloudflare token is required for $domain (interactive entry)."
        return 1
      fi
      if ! read -r -s -p "Paste API token for ${domain}: " token; then
        echo
        err "Token entry cancelled."
        return 1
      fi
      echo
      [[ -n "$token" ]] || { warn "Empty token."; continue; }
    fi

    # Bash dynamic scoping: CF_API_TOKEN is local to this function; the primary
    # CF token and primary DNS zone are never overwritten in the global state.
    local CF_API_TOKEN="$token"
    response=$(cf_api_raw GET "/user/tokens/verify" 2>/dev/null) || response=""
    if [[ -z "$response" ]] || [[ "$(jq -r '.result.status // ""' <<<"$response")" != "active" ]]; then
      err "The Cloudflare token is invalid or expired."
      if [[ -s "$token_file" ]]; then
        mv "$token_file" "${token_file}.inactive-$(date +%Y%m%d%H%M%S)"
        chmod 600 "${token_file}.inactive-"* 2>/dev/null || true
        warn "Previously saved token archived; it has NOT been erased."
      fi
      (( NONINTERACTIVE )) && return 1
      continue
    fi
    origin="$domain"; zone_json=""; matched=""
    # Select closest authoritative accessible zone, parent for subdomains.
    while [[ "$origin" == *.* ]]; do
      candidate=$(cf_api_get_query "/zones" "name=${origin}" "status=active" "per_page=50" 2>/dev/null) || candidate=""
      zone_count=$(jq -r '.result | length' <<<"$candidate" 2>/dev/null || echo 0)
      if [[ "$zone_count" == 1 ]]; then
        zone_json="$candidate"; matched="$origin"; break
      fi
      origin=${origin#*.}
    done
    if [[ -z "$matched" ]]; then
      err "Token cannot access an ACTIVE authoritative Cloudflare zone for ${domain}."
      if [[ -s "$token_file" ]]; then
        mv "$token_file" "${token_file}.inactive-$(date +%Y%m%d%H%M%S)"
      fi
      (( NONINTERACTIVE )) && return 1
      continue
    fi
    NEW_ZONE_NAME="$matched"
    NEW_ZONE_ID=$(jq -r '.result[0].id' <<<"$zone_json")
    printf '%s' "$token" >"$token_file"
    chmod 0600 "$token_file"
    install -o root -g stalwart -m 0640 "$token_file" "$(multi_domain_stalwart_token_file "$domain")"
    ok "Cloudflare token and parent zone verified for $domain (zone=$NEW_ZONE_NAME)."
    return 0
  done
}

# List a whole zone with pagination; only keep mail-related records belonging
# to THIS domain (never the primary zone or an unrelated customer zone).
# Cloudflare allows per_page up to 5000000 on some endpoints, but 100 is the
# common safe limit. Pagination avoids silently missing DKIM selectors.
cf_domain_dns_snapshot() {
  local domain="$1" zone_id="$2" page=1 resp pages results all='[]'
  while (( page <= 100 )); do
    resp=$(cf_api_get_query "/zones/${zone_id}/dns_records" "page=${page}" "per_page=100") || return 1
    results=$(jq -c '.result // []' <<<"$resp") || return 1
    all=$(jq -cn --argjson a "$all" --argjson b "$results" '$a + $b') || return 1
    pages=$(jq -r '.result_info.total_pages // 1' <<<"$resp")
    [[ "$pages" =~ ^[0-9]+$ ]] || return 1
    (( page >= pages )) && break
    page=$((page+1))
  done
  (( page <= 100 )) || { err "Cloudflare zone has too many DNS pages; cleanup snapshot is not exhaustive."; return 1; }
  jq -c --arg domain "$domain" '
    [ .[] | select(
      (.type == "MX" and .name == $domain) or
      (.type == "TXT" and (
        .name == $domain or .name == ("_dmarc."+$domain) or
        (.name | endswith("._domainkey."+$domain))
      ))
    ) | {id,type,name,content,priority,ttl,proxied,comment} ]
  ' <<<"$all"
}

multi_domain_track_records() {
  local file="$1" domain="$2" zone="$3" token="$4" phase="${5:-ready}" before after records
  before=$(jq -c '.baselineRecords // []' "$file") || return 1
  local CF_API_TOKEN="$token"
  after=$(cf_domain_dns_snapshot "$domain" "$zone") || return 1
  records=$(jq -cn --arg domain "$domain" --arg mx "$MAIL_HOST" \
    --argjson before "$before" --argjson after "$after" '
    [ $after[] | select(
        (.id as $id | ($before | map(.id) | index($id)) == null) and
        (
          (.type == "MX" and .name == $domain and
            (.content | ascii_downcase | rtrimstr(".")) == ($mx | ascii_downcase | rtrimstr("."))) or
          (.type == "TXT" and .name == $domain and (.content | test("^v=spf1"; "i"))) or
          (.type == "TXT" and .name == ("_dmarc." + $domain) and (.content | test("^v=DMARC1"; "i"))) or
          (.type == "TXT" and (.name | endswith("._domainkey." + $domain)) and
            (.content | test("v=DKIM1"; "i")))
        )
      ) ]
  ') || return 1
  local overwrites
  overwrites=$(jq -cn --argjson before "$before" --argjson after "$after" '
    [ $after[] as $now | $before[] |
      select(.id == $now.id and
        ((.content != $now.content) or (.priority != $now.priority) or (.ttl != $now.ttl))) |
      {before:., after:$now}
    ]
  ') || return 1
  # Keep records owned from earlier partial attempts and DKIM rotation; a
  # later retry must not erase the ownership journal.
  multi_domain_state_update "$file" '
    .managedRecords = ([ (.managedRecords // [])[] |
       select(.id as $id | ($records | map(.id) | index($id)) == null) ] + $records) |
    .overwrittenRecords = ((.overwrittenRecords // []) + $overwrites | unique_by(.before.id)) |
    .phase=$phase |
    .verifiedAt=(if $phase=="ready" then $now else null end)
  ' --argjson records "$records" --argjson overwrites "$overwrites" \
    --arg phase "$phase" --arg now "$(date -Is)" || return 1
  ok "Recorded $(jq 'length' <<<"$records") new DNS records and $(jq 'length' <<<"$overwrites") modified pre-existing DNS records."
}

multi_domain_verify_dns() {
  local domain="$1" expected_mx="$2" zonefile domain_id attempt selector selectors spf dmarc mx missing snapshot conflicts
  domain_id=$(stalwart_domain_id "$domain") || return 1
  [[ -n "$domain_id" ]] || return 1
  zonefile=$(stalwart_cli_admin get Domain "$domain_id" --fields dnsZoneFile --json | jq -r '.dnsZoneFile // empty') || return 1
  [[ -n "$zonefile" ]] || { err "Stalwart did not produce a DNS zone for $domain."; return 1; }
  selectors=$(grep -Eio '[a-zA-Z0-9_-]+\._domainkey(\.[a-zA-Z0-9._-]+)?\.?' <<<"$zonefile" | sort -u || true)
  [[ -n "$selectors" ]] || { err "Stalwart zone has no DKIM selectors for $domain."; return 1; }
  for attempt in $(seq 1 30); do
    missing=0
    mx=$(dig +short MX "$domain" @1.1.1.1 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    grep -Eq "^[[:space:]]*[0-9]+[[:space:]]+${expected_mx//./\\.}\\.?$" <<<"$mx" || missing=$((missing+1))
    spf=$(dig +short TXT "$domain" @1.1.1.1 2>/dev/null | tr -d '"' | grep -im1 'v=spf1' || true)
    [[ -n "$spf" ]] || missing=$((missing+1))
    dmarc=$(dig +short TXT "_dmarc.${domain}" @1.1.1.1 2>/dev/null | tr -d '"' | grep -im1 'v=DMARC1' || true)
    [[ -n "$dmarc" ]] || missing=$((missing+1))
    while IFS= read -r selector; do
      selector=${selector%.}
      [[ "$selector" == *".$domain" ]] || selector="${selector}.${domain}"
      dig +short TXT "$selector" @1.1.1.1 2>/dev/null | tr -d '"' | grep -qi 'DKIM' || missing=$((missing+1))
    done <<<"$selectors"
    if (( missing == 0 )); then
      # Public visibility alone is insufficient: two MX providers or multiple
      # SPF policies can still cause misrouting or SPF permerror. Fail closed.
      snapshot=$(cf_domain_dns_snapshot "$domain" "$CF_ZONE_ID") || {
        err "Cannot verify Cloudflare's authoritative mail DNS set."
        return 1
      }
      conflicts=$(jq -n --argjson records "$snapshot" --arg d "$domain" --arg mx "$expected_mx" '
        {
          mx: ([ $records[] | select(.type == "MX" and .name == $d) ] |
            if length == 1 and (.[0].content | ascii_downcase | rtrimstr(".")) == ($mx | ascii_downcase | rtrimstr(".")) then 0 else (length + 1) end),
          spf: ([ $records[] | select(.type == "TXT" and .name == $d and (.content | test("^v=spf1"; "i"))) ] | length),
          dmarc: ([ $records[] | select(.type == "TXT" and .name == ("_dmarc."+$d) and (.content | test("^v=DMARC1"; "i"))) ] | length)
        }
      ') || return 1
      if [[ "$(jq -r '.mx' <<<"$conflicts")" != 0 ]] ||
         [[ "$(jq -r '.spf' <<<"$conflicts")" != 1 ]] ||
         [[ "$(jq -r '.dmarc' <<<"$conflicts")" != 1 ]]; then
        err "DNS conflict for $domain: expected ONE Stalwart MX, ONE SPF and ONE DMARC; observed $(jq -c . <<<"$conflicts")."
        err "Remove competing records at Cloudflare; the domain is NOT marked ready."
        return 1
      fi
      ok "Unique MX, SPF, DMARC and Stalwart DKIM selectors are visible for ${domain}."
      return 0
    fi
    info "Waiting for ${domain} DNS propagation (${attempt}/30, missing=${missing})..."
    sleep 6
  done
  err "Some email DNS records for ${domain} are not yet public. The configuration remains installed; retry Add domain later to finish verification."
  return 1
}

manager_list_domains() {
  stage "Stalwart mail domains"
  local rows domain id path
  rows=$(stalwart_domain_rows) || { err "Could not read Stalwart domains."; return 1; }
  printf '\n%-34s %-18s %s\n' "Mail domain" "Managed by" "Stalwart ID"
  printf '%-34s %-18s %s\n' "----------------------------------" "------------------" "------------"
  while IFS=$'\t' read -r domain id; do
    [[ -n "$domain" && -n "$id" ]] || continue
    if [[ "$domain" == "$DOMAIN" ]]; then
      printf '%-34s %-18s %s\n' "$domain" "PRIMARY (locked)" "$id"
    else
      path=$(multi_domain_state_file "$domain")
      if [[ -s "$path" ]]; then
        printf '%-34s %-18s %s\n' "$domain" "v4 installer" "$id"
      else
        printf '%-34s %-18s %s\n' "$domain" "external/manual" "$id"
      fi
    fi
  done < <(jq -rs '.[] | [.name,.id] | @tsv' <<<"$rows")
  local journal journal_domain journal_phase
  for journal in "$EXTRA_DOMAINS_DIR"/*.json; do
    [[ -s "$journal" ]] || continue
    journal_domain=$(jq -r '.domain // empty' "$journal" 2>/dev/null || true)
    [[ -n "$journal_domain" ]] || continue
    if ! jq -ers --arg d "$journal_domain" 'any(.[]; .name == $d)' <<<"$rows" >/dev/null 2>&1; then
      journal_phase=$(jq -r '.phase // "pending"' "$journal" 2>/dev/null || true)
      printf '%-34s %-18s %s\n' "$journal_domain" "cleanup pending" "${journal_phase}"
    fi
  done
  echo
  info "All domains share SMTP/IMAP: ${MAIL_HOST}; webmail: https://${WEBMAIL_HOST}"
}

multi_domain_write_lock() {
  # The caller runs in a subshell; the lock is released on any return, ERR or signal.
  install -d -m 0700 "$STATE_DIR"
  exec 9>"${STATE_DIR}/multi-domain.lock"
  if ! flock -n 9; then
    err "Another mail-domain change is running. Try again after it finishes."
    return 1
  fi
}

# Reject a domain that is already an alias of another Stalwart domain. Query
# all domains: a Domain.name lookup by itself cannot detect aliases.
multi_domain_assert_not_alias() {
  local target="$1" rows matches
  rows=$(stalwart_cli_admin query Domain --fields id,name,aliases --json) || return 1
  matches=$(jq -rs --arg d "$target" '[.[] | select(
    ((.name // "" | ascii_downcase) != $d) and
    ([ (.aliases // {}) | .. | strings | ascii_downcase ] | index($d) != null)
  ) | .name] | unique' <<<"$rows") || return 1
  if [[ "$(jq 'length' <<<"$matches")" -gt 0 ]]; then
    err "${target} is already an alias of a different Stalwart domain: $(jq -r 'join(", ")' <<<"$matches")"
    return 1
  fi
}

manager_add_domain() (
  manager_backup_lock || return 1
  multi_domain_write_lock || return 1
  multi_domain_preflight || return 1
  manager_list_domains || return 1
  if (( NONINTERACTIVE )); then
    err "Add domain requires an interactive domain name and secret Cloudflare token."
    return 1
  fi
  local new_domain input path existing token zone_id dns_before plan published
  read -r -p "New independent mail domain (e.g., other.com): " input
  new_domain=$(normalize_domain "$input")
  valid_domain "$new_domain" || { err "Invalid domain: $new_domain"; return 1; }
  [[ "$new_domain" != "$DOMAIN" ]] || { err "This is the primary domain; it already exists."; return 1; }
  # Virtual Mail is intentionally independent: never attach the same domain
  # to Stalwart while Cloudflare Email Routing manages its MX.
  if [[ -s "${STATE_DIR}/virtual-mail/zones/${new_domain}.json" ]]; then
    err "This domain is registered in Virtual Mail. Disable Email Routing and detach it manually before Stalwart onboarding."
    return 1
  fi
  # Do not create a domain which is itself the server's public endpoint.
  [[ "$new_domain" != "$MAIL_HOST" && "$new_domain" != "$WEBMAIL_HOST" ]] || {
    err "This name is reserved for the existing server's endpoints."
    return 1
  }
  path=$(multi_domain_state_file "$new_domain")
  existing=$(stalwart_domain_id "$new_domain") || { err "Stalwart domain lookup failed."; return 1; }
  multi_domain_assert_not_alias "$new_domain" || { err "Domain conflicts with an existing alias or domain listing is unavailable."; return 1; }
  if [[ -n "$existing" && ! -s "$path" ]]; then
    err "${new_domain} already exists in Stalwart, but was not added by this manager. It will not be overwritten."
    return 1
  fi
  if [[ -s "$path" ]]; then
    info "Detected unfinished/previous v4 configuration; will resume its transaction."
    [[ "$(jq -r '.domain // ""' "$path")" == "$new_domain" ]] || {
      err "Mismatched state journal. No changes made."; return 1;
    }
    if [[ "$(jq -r '.phase // ""' "$path")" == "retirement-pending" ]]; then
      err "Domain retirement is pending. Cancel retirement before adding/reconfiguring it."
      return 1
    fi
    if [[ -n "$existing" && "$(jq -r '.phase // ""' "$path")" == "ready" ]]; then
      ok "${new_domain} exists; running independent health checks instead of blindly reporting ready."
      manager_domain_check_one "$new_domain" "$path" || return 1
      manager_ensure_postmaster "$new_domain" || return 1
      return 0
    fi
  else
    printf '\nMail domain:    %s\n' "$new_domain"
    printf 'MX/SMTP/IMAP:   %s\n' "$MAIL_HOST"
    printf 'Webmail:       https://%s\n' "$WEBMAIL_HOST"
    printf '%s\n' "This adds an independent mail domain. It does NOT create new server hostnames, a second webmail site, or any mailboxes."
    confirm "Set up this domain and its Cloudflare zone?" N || return 0
  fi
  multi_domain_cloudflare_auth "$new_domain" || return 1
  token=$(<"$(multi_domain_token_file "$new_domain")")
  zone_id="$NEW_ZONE_ID"
  local zone_name="$NEW_ZONE_NAME"
  local CF_API_TOKEN="$token" CF_ZONE_ID="$zone_id" DOMAIN="$new_domain"
  if [[ ! -s "$path" ]]; then
    dns_before=$(cf_domain_dns_snapshot "$new_domain" "$zone_id") || {
      err "Cannot record Cloudflare DNS baseline; refusing to proceed without safe deletion metadata."
      return 1
    }
    jq -nc --arg d "$new_domain" --arg zone "$zone_id" --arg mx "$MAIL_HOST" \
      --arg now "$(date -Is)" --argjson baseline "$dns_before" \
      --arg origin "$zone_name" \
      '{version:43,domain:$d,zoneId:$zone,zoneName:$origin,mailHost:$mx,createdAt:$now,phase:"pending",baselineRecords:$baseline,managedRecords:[],overwrittenRecords:[]}' >"$path"
    chmod 0600 "$path"
    local conflicting_count
    conflicting_count=$(jq '[.baselineRecords[] | select(
      .type == "MX" or
      (.type == "TXT" and ((.content | test("^v=spf1"; "i")) or (.content | test("^v=DMARC1"; "i"))))
    )] | length' "$path")
    if (( conflicting_count > 0 )); then
      warn "Cloudflare already has ${conflicting_count} mail-routing/authentication records in this zone."
      warn "Stalwart automatic DNS could replace their values and disrupt an existing mail provider."
      if ! confirm "Do you intend to migrate this domain to this Stalwart mail server?" N; then
        rm -f "$path"
        info "Cancelled before making DNS/Stalwart changes; saved Cloudflare token is preserved."
        return 0
      fi
    fi
  else
    [[ "$(jq -r '.zoneId // ""' "$path")" == "$zone_id" ]] || {
      err "Cloudflare zone ID changed since the saved transaction. Resolve manually before retrying."; return 1;
    }
  fi
  if [[ -n "$existing" ]] && [[ -s "$path" ]] &&
     [[ "$(jq -r '.phase // ""' "$path")" =~ ^(domain-configured|mx-configured|pending-verification)$ ]]; then
    info "Domain already exists from an earlier attempt; preserving its current Stalwart settings."
    stage "Cloudflare MX for ${new_domain}"
    cf_ensure_mx
    multi_domain_verify_dns "$new_domain" "$MAIL_HOST" || {
      multi_domain_track_records "$path" "$new_domain" "$zone_id" "$token" "pending-verification" || true
      return 1
    }
    multi_domain_track_records "$path" "$new_domain" "$zone_id" "$token" || return 1
    manager_ensure_postmaster "$new_domain" || {
      warn "Required postmaster account missing; retry the Add domain operation after resolving the issue."; return 1;
    }
    write_secrets_summary
    ok "Completed pending DNS verification and postmaster creation for $new_domain."
    return 0
  fi

  stage "Stalwart DNS provider and domain for ${new_domain}"
  # The primary stack has only one public webmail/JMAP/TLS identity.
  # Do NOT advertise per-domain HTTPS MTA-STS or autoconfig endpoints that
  # were never provisioned with certificates / Nginx for secondary domains.
  published='{"dkim":true,"dmarc":true,"mx":true,"spf":true}'
  info "Publishing verified core mail DNS (MX/SPF/DKIM/DMARC); optional per-domain HTTPS endpoints are not advertised."
  plan=$(mktemp "${STATE_DIR}/extra-domain-plan.XXXXXX") || return 1
  chmod 0600 "$plan"
  jq -nc --arg desc "KatebSaber MailStack Cloudflare - ${new_domain}" \
    --arg tok "$(multi_domain_stalwart_token_file "$new_domain")" \
    '{"@type":"upsert","object":"DnsServer","matchOn":["description"],"value":{"dns-extra":{"@type":"Cloudflare","description":$desc,"secret":{"@type":"File","filePath":$tok}}}}' >"$plan"
  jq -nc --arg d "$new_domain" --arg uri "mailto:postmaster@${new_domain}" \
    --arg origin "$zone_name" --argjson records "$published" \
    '{"@type":"upsert","object":"Domain","matchOn":["name"],"value":{"domain-extra":{"name":$d,"aliases":{},"certificateManagement":{"@type":"Manual"},"dkimManagement":{"@type":"Automatic"},"dnsManagement":{"@type":"Automatic","dnsServerId":"#dns-extra","origin":$origin,"publishRecords":$records},"subAddressing":{"@type":"Enabled"},"allowRelaying":false,"reportAddressUri":$uri}}}' >>"$plan"
  if ! stalwart_cli_admin apply --file "$plan" --dry-run >/dev/null; then
    rm -f "$plan"
    err "Stalwart rejected the new domain configuration. The journal and DNS state were retained."
    return 1
  fi
  if ! stalwart_cli_admin apply --file "$plan" --quiet >/dev/null; then
    rm -f "$plan"
    err "Stalwart could not add/reconcile the new domain. Review server logs before retrying."
    return 1
  fi
  rm -f "$plan"
  multi_domain_state_update "$path" '.phase="domain-configured"'
  # Domain/account mutations are immediately visible; settings reload makes
  # newly-created DnsServer credentials visible to the server's DNS worker.
  if ! stalwart_cli_admin create Action/ReloadSettings >/dev/null 2>&1; then
    warn "Settings reload did not confirm; review Stalwart logs if DNS publication fails."
  fi
  existing=$(stalwart_domain_id "$new_domain") || return 1
  [[ -n "$existing" ]] || { err "Stalwart did not return the newly-created domain."; return 1; }
  ok "Stalwart domain created/reconciled: $new_domain (ID $existing)."
  # Do not point public MX to a domain which Stalwart failed to create.
  # Stalwart's automatic DNS also publishes MX; this call normalizes the
  # desired shared endpoint after domain creation.
  stage "Cloudflare MX for ${new_domain}"
  cf_ensure_mx
  multi_domain_state_update "$path" '.phase="mx-configured"'
  if ! multi_domain_verify_dns "$new_domain" "$MAIL_HOST"; then
    # Store any records that have already appeared so eventual deletion can be safe.
    multi_domain_track_records "$path" "$new_domain" "$zone_id" "$token" "pending-verification" || true
    warn "Domain exists but DNS verification is incomplete; inspect Cloudflare and retry using Add domain."
    return 1
  fi
  multi_domain_track_records "$path" "$new_domain" "$zone_id" "$token" || {
    err "Could not finalize DNS ownership journal. Domain remains configured; retry Add domain."
    return 1
  }
  echo
  ok "Additional mail domain ${new_domain} is active."
  info "Create its mailbox(es) in Stalwart Admin: https://${MAIL_HOST}/admin"
  info "Users log in with full addresses like user@${new_domain}."
  info "SMTP/IMAP: ${MAIL_HOST} | Webmail: https://${WEBMAIL_HOST}"
  manager_ensure_postmaster "$new_domain" || {
    warn "DNS/domain is active, but the postmaster mailbox could not be created. Re-run Add domain to retry."
    return 1
  }
  write_secrets_summary
)

multi_domain_check_accounts() {
  local domain_id="$1" rows in_use
  # Querying *all* accounts catches cross-domain aliases referencing this domain.
  rows=$(stalwart_cli_admin query Account --fields id,name,domainId,aliases --json) || {
    err "Cannot read accounts and aliases. Refusing to remove the domain."; return 1;
  }
  in_use=$(jq -rs --arg id "$domain_id" '
    [ .[] | select(
      (.domainId == $id) or
      ([(.aliases // {}) | .. | objects | .domainId? // empty] | index($id) != null)
    ) | {id,name,domainId} ]
  ' <<<"$rows") || return 1
  if [[ "$(jq 'length' <<<"$in_use")" -gt 0 ]]; then
    err "The domain is still referenced by these mail accounts/aliases:"
    jq -r '.[] | "  - \(.name) (id=\(.id))"' <<<"$in_use"
    warn "Migrate/remove accounts and aliases in Stalwart Admin first; mail data is never silently deleted."
    return 1
  fi
}

# DKIM key rotation may publish fresh selectors after onboarding. Before
# deletion, include ONLY public DKIM names that Stalwart currently advertises,
# that were not present in the pre-install snapshot. This cannot claim arbitrary
# new customer TXT records, and the later cleanup still checks exact id/content.
multi_domain_capture_current_dkim() {
  local file="$1" domain="$2" id="$3" zone="$4" token="$5"
  local zonefile selectors selector names='[]' current baseline extra
  zonefile=$(stalwart_cli_admin get Domain "$id" --fields dnsZoneFile --json 2>/dev/null | jq -r '.dnsZoneFile // empty') || return 1
  [[ -n "$zonefile" ]] || return 1
  selectors=$(grep -Eio '[a-zA-Z0-9_-]+\._domainkey(\.[a-zA-Z0-9._-]+)?\.?' <<<"$zonefile" | sort -u || true)
  [[ -n "$selectors" ]] || return 1
  while IFS= read -r selector; do
    selector=${selector%.}
    [[ "$selector" == *".$domain" ]] || selector="${selector}.${domain}"
    names=$(jq -nc --argjson names "$names" --arg name "$selector" '$names + [$name]') || return 1
  done <<<"$selectors"
  local CF_API_TOKEN="$token"
  current=$(cf_domain_dns_snapshot "$domain" "$zone") || return 1
  baseline=$(jq -c '.baselineRecords // []' "$file") || return 1
  extra=$(jq -nc --argjson current "$current" --argjson baseline "$baseline" --argjson names "$names" '
    [ $current[] |
      select(.type == "TXT" and (.name as $n | $names | index($n) != null) and
        (.content | test("v=DKIM1"; "i")) and
        (.id as $id | ($baseline | map(.id) | index($id)) == null)) ]
  ') || return 1
  multi_domain_state_update "$file" '
    .managedRecords = ((.managedRecords // []) + $extra | unique_by(.id))
  ' --argjson extra "$extra"
}

# Restore only records that existed before onboarding and whose current id,
# name, type and value still match what this installer last observed. A record
# changed by a human since installation is NEVER overwritten.
multi_domain_restore_dns() {
  local file="$1" domain="$2" zone="$3" token="$4" changes current row count before after id payload failures=0 restored=0
  changes=$(jq -c '.overwrittenRecords // []' "$file") || return 1
  [[ "$(jq 'length' <<<"$changes")" -gt 0 ]] || return 0
  local CF_API_TOKEN="$token"
  current=$(cf_domain_dns_snapshot "$domain" "$zone") || return 1
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    before=$(jq -c '.before' <<<"$row") || return 1
    after=$(jq -c '.after' <<<"$row") || return 1
    id=$(jq -r '.id' <<<"$before")
    count=$(jq -n --argjson cur "$current" --argjson expected "$after"       '[ $cur[] | select(.id==$expected.id and .type==$expected.type and
        .name==$expected.name and .content==$expected.content and
        .priority==$expected.priority and .ttl==$expected.ttl) ] | length') || return 1
    if [[ "$count" -ne 1 ]]; then
      warn "Original DNS record $id has changed since installation; preservation takes priority over restoration."
      continue
    fi
    payload=$(jq -nc --argjson rec "$before" '
      {type:$rec.type,name:$rec.name,content:$rec.content,ttl:($rec.ttl // 1)} +
      (if $rec.type == "MX" then {priority:($rec.priority // 10)} else {} end)
    ') || return 1
    if cf_api_raw PATCH "/zones/${zone}/dns_records/${id}" "$payload" >/dev/null; then
      restored=$((restored+1))
      multi_domain_state_update "$file" '.overwrittenRecords |= map(select(.before.id != $id))' --arg id "$id" || return 1
    else
      err "Cloudflare failed to restore original DNS record $id. Retry Remove domain."
      failures=$((failures+1))
    fi
  done < <(jq -c '.[]' <<<"$changes")
  (( failures == 0 )) || return 1
  ok "Restored $restored original DNS records (where unchanged since onboarding)."
}

multi_domain_cleanup_dns() {
  local file="$1" domain="$2" zone="$3" token="$4" records current row id match_count failures=0 removed=0
  local CF_API_TOKEN="$token"
  records=$(jq -c '.managedRecords // []' "$file") || return 1
  [[ "$(jq 'length' <<<"$records")" -gt 0 ]] || {
    warn "No owned DNS records are journaled; DNS cleanup is conservative. Inspect MX/SPF/DKIM/DMARC manually."
    return 0
  }
  current=$(cf_domain_dns_snapshot "$domain" "$zone") || {
    err "Cannot read Cloudflare DNS; cleanup can be retried from the Remove domain menu."; return 1;
  }
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    id=$(jq -r '.id' <<<"$row")
    match_count=$(jq -n --argjson cur "$current" --argjson row "$row" \
      '[ $cur[] | select(.id==$row.id and .name==$row.name and .type==$row.type and .content==$row.content) ] | length')
    if (( match_count != 1 )); then
      warn "DNS record $id was changed/deleted since installation; skipping to avoid removing another owner's changes."
      continue
    fi
    if cf_api_raw DELETE "/zones/${zone}/dns_records/${id}" >/dev/null; then
      ok "Removed installer-created $(jq -r '.type' <<<"$row") $(jq -r '.name' <<<"$row")."
      removed=$((removed+1))
      # Update the journal after EACH successful deletion: resumes are safe.
      multi_domain_state_update "$file" '.managedRecords |= map(select(.id != $id))' --arg id "$id" || return 1
    else
      err "Cloudflare DNS deletion failed for record id $id."
      failures=$((failures+1))
    fi
  done < <(jq -c '.[]' <<<"$records")
  (( failures == 0 )) || return 1
  ok "DNS removal pass completed (deleted $removed installer-created records)."
}

manager_remove_domain() (
  manager_backup_lock || return 1
  multi_domain_write_lock || return 1
  multi_domain_preflight || return 1
  manager_list_domains || return 1
  if (( NONINTERACTIVE )); then
    err "Remove domain requires an interactive exact-domain confirmation."
    return 1
  fi
  local input target file id token zone provider_ids dkim_ids signatures
  read -r -p "Exact SECONDARY domain to remove: " input
  target=$(normalize_domain "$input")
  valid_domain "$target" || { err "Invalid domain name."; return 1; }
  [[ "$target" != "$DOMAIN" ]] || {
    err "Primary domain ${DOMAIN} is protected: it owns the admin identity, default hostname, TLS and initial installer state."
    return 1
  }
  file=$(multi_domain_state_file "$target")
  [[ -s "$file" ]] || {
    err "This domain is not managed by v4 (or has already been fully removed). No changes made."
    return 1
  }
  zone=$(jq -r '.zoneId // empty' "$file")
  [[ -n "$zone" ]] || { err "Missing saved Cloudflare zone ID; refusing deletion."; return 1; }
  id=$(stalwart_domain_id "$target") || return 1
  if [[ -n "$id" ]]; then
    local default_domain_id
    default_domain_id=$(stalwart_cli_admin get SystemSettings --fields defaultDomainId --json | jq -r '.defaultDomainId // empty') || {
      err "Cannot check the current default domain; refusing deletion."; return 1;
    }
    [[ "$default_domain_id" != "$id" ]] || {
      err "${target} is currently Stalwart's default domain; change the default first."; return 1;
    }
    multi_domain_check_accounts "$id" || return 1
  fi
  echo
  warn "DELETING ${target} from Stalwart will stop acceptance of new mail for this domain."
  warn "This does not remove any mailbox data; if accounts/aliases exist, deletion is blocked."
  warn "Only installer-created, unchanged Cloudflare DNS records will be deleted."
  warn "Previously existing records changed by the installer will be restored ONLY if not subsequently modified."
  warn "The primary domain, common mail/webmail hostnames and shared services are NOT modified."
  read -r -p "Type DELETE ${target} to proceed: " input
  [[ "$input" == "DELETE ${target}" ]] || { info "Cancelled; no changes made."; return 0; }

  # Two-step retirement: an initial confirmation ONLY records intent.
  # Operators have at least seven days to check routing, queued mail and old DKIM.
  # Short retention windows can break DKIM checks for messages already delivered.
  local retirement_epoch now_epoch
  retirement_epoch=$(jq -r '.retirementRequestedEpoch // 0' "$file")
  now_epoch=$(date +%s)
  if [[ "$retirement_epoch" == 0 ]]; then
    multi_domain_state_update "$file" '.phase="retirement-pending" | .retirementRequestedEpoch=$ts' --argjson ts "$now_epoch" || return 1
    warn "Retirement scheduled; NO domain, mailbox, provider, DNS or token was deleted."
    warn "After 7 days, repeat Remove domain and confirm again to finalize."
    return 0
  fi
  if (( now_epoch - retirement_epoch < 604800 )); then
    err "Seven-day DKIM/DNS review window is still active. No deletion performed."
    return 1
  fi
  # Before deletion, read queue and require zero pending recipients for the
  # domain; a failed query is a hard stop, never assumed empty.
  manager_domain_queue_empty "$target" || return 1
  # Verify Cloudflare access BEFORE removing anything in Stalwart; an expired
  # token can be replaced interactively (including on cleanup retries).
  multi_domain_cloudflare_auth "$target" || return 1
  [[ "$NEW_ZONE_ID" == "$zone" ]] || {
    err "Token resolves to a different Cloudflare zone ID. No deletion performed."; return 1;
  }
  token=$(<"$(multi_domain_token_file "$target")")
  local CF_API_TOKEN="$token"
  cf_domain_dns_snapshot "$target" "$zone" >/dev/null || {
    err "Cloudflare DNS is not readable; no destructive step attempted."; return 1;
  }
  if [[ -n "$id" ]]; then
    multi_domain_capture_current_dkim "$file" "$target" "$id" "$zone" "$token" || \
      warn "Could not capture rotated DKIM selectors; will only clean originally recorded records."
  fi

  stage "Remove secondary domain ${target}"
  # Incomplete operations are resumable. Do not touch unrelated DnsServers.
  if [[ -n "$id" ]]; then
    if ! stalwart_cli_admin update Domain "$id" \
      --field 'dnsManagement={"@type":"Manual"}' \
      --field 'dkimManagement={"@type":"Manual"}' >/dev/null; then
      err "Failed to stop domain DNS/DKIM automation. No destructive step attempted."
      return 1
    fi
    signatures=$(stalwart_cli_admin query DkimSignature --where "domainId=${id}" --fields id,domainId,selector --json) || {
      err "Could not enumerate linked DKIM signatures. Refusing to proceed."; return 1;
    }
    # DKIM signatures are per-domain signing keys, not mailboxes. Domain
    # deletion may fail with objectIsLinked unless these are removed first.
    dkim_ids=$(jq -rs --arg id "$id" '[.[] | select(.domainId == $id) | .id] | join(",")' <<<"$signatures") || return 1
    if [[ -n "$dkim_ids" ]]; then
      if ! stalwart_cli_admin delete DkimSignature --ids "$dkim_ids"; then
        err "Could not remove linked DKIM signatures; domain retained."
        return 1
      fi
    fi
    if ! stalwart_cli_admin delete Domain --ids "$id"; then
      err "Stalwart did not delete ${target}; DNS and tokens were preserved. Check objectIsLinked errors above."
      return 1
    fi
    ok "Removed the Stalwart domain object ${target}."
  else
    info "Domain already absent from Stalwart; resuming pending DNS/provider cleanup."
  fi
  multi_domain_state_update "$file" '.phase="domain-removed"'
  multi_domain_cleanup_dns "$file" "$target" "$zone" "$token" || {
    warn "Stalwart domain was removed; Cloudflare DNS cleanup is pending. Re-run Remove domain to finish."
    return 1
  }
  multi_domain_restore_dns "$file" "$target" "$zone" "$token" || {
    warn "Stalwart domain was removed; prior DNS restoration is pending. Re-run Remove domain to finish."
    return 1
  }

  # Remove only the provider created for this domain; never the dns-main used
  # by the original domain. If any other Domain references it, Stalwart blocks.
  provider_ids=$(stalwart_cli_admin query DnsServer --fields id,description --json | \
    jq -rs --arg desc "KatebSaber MailStack Cloudflare - ${target}" \
      '[.[] | select(.description == $desc) | .id] | join(",")') || {
    err "Could not list managed Stalwart DNS providers. Retry cleanup later."; return 1;
  }
  if [[ -n "$provider_ids" ]]; then
    if ! stalwart_cli_admin delete DnsServer --ids "$provider_ids"; then
      err "DNS provider still referenced or could not be removed; retry later."
      return 1
    fi
  fi
  install -d -m 0700 "${EXTRA_CF_TOKENS_DIR}/archive"
  if [[ -s "$(multi_domain_token_file "$target")" ]]; then
    mv "$(multi_domain_token_file "$target")" "${EXTRA_CF_TOKENS_DIR}/archive/${target}-$(date +%Y%m%d-%H%M%S).token"
  fi
  # Keep historical Stalwart DNS token copy for audit, but revoke its use by removing provider.
  # Its contents are not erased; root-only archives preserve the user's management credentials.
  if [[ -s "$(multi_domain_stalwart_token_file "$target")" ]]; then
    cp -p "$(multi_domain_stalwart_token_file "$target")" "${EXTRA_CF_TOKENS_DIR}/archive/${target}-stalwart-$(date +%Y%m%d-%H%M%S).token"
    rm -f "$(multi_domain_stalwart_token_file "$target")"
  fi
  # Keep an audit record but remove the active state so the domain can be
  # provisioned cleanly again in the future.
  install -d -m 0700 "$EXTRA_DOMAINS_DIR/archive"
  mv -f "$file" "${EXTRA_DOMAINS_DIR}/archive/${target}-$(date +%Y%m%d-%H%M%S).json"
  write_secrets_summary
  ok "The secondary domain ${target} has been removed; primary mail stack is unchanged."
  warn "Review DNS records changed manually during operation; those records are intentionally preserved."
)

# -----------------------------------------------------------------------------
# v4.3 lifecycle: conservative automation, snapshots, tests, operational audit.
# No destructive operation is performed without an explicit interactive gate.
# All credentials remain persisted; /root/mailstack-secrets.txt is NOT removed.
# -----------------------------------------------------------------------------

manager_domain_queue_empty() {
  local domain="$1" messages count
  messages=$(stalwart_cli_admin query QueuedMessage --fields id,recipients,returnPath --json) || {
    err "Cannot inspect queued emails; domain deletion is blocked."; return 1;
  }
  count=$(jq -rs --arg domain "${domain,,}" '
    [ .[] | select((tostring | ascii_downcase) | contains("@"+$domain)) ] | length' <<<"$messages") || return 1
  if (( count > 0 )); then
    err "Outbound queue contains $count messages referencing $domain; wait for completion or resolve safely in Stalwart WebUI."
    return 1
  fi
}

manager_domain_check_one() {
  local domain="$1" journal="${2:-}" id zone token zone_id cf_records mx spf dmarc failed=0
  local zone_file selectors selector public_dkim dkim_found=0
  id=$(stalwart_domain_id "$domain") || return 1
  [[ -n "$id" ]] || { err "Stalwart domain not found: $domain"; return 1; }
  info "Mail domain: $domain | Stalwart ID: $id"
  mx=$(dig +short MX "$domain" @1.1.1.1 2>/dev/null || true)
  if grep -Eq "^[[:space:]]*[0-9]+[[:space:]]+${MAIL_HOST//./\\.}\\.?$" <<<"$mx"; then
    ok "Public MX includes ${MAIL_HOST}."
  else err "Public MX does not route to ${MAIL_HOST}: ${mx:-none}"; failed=1; fi
  spf=$(dig +short TXT "$domain" @1.1.1.1 2>/dev/null | tr -d '"' | grep -i 'v=spf1' || true)
  [[ -n "$spf" ]] && ok "Public SPF: present" || { err "Public SPF: missing"; failed=1; }
  dmarc=$(dig +short TXT "_dmarc.${domain}" @1.1.1.1 2>/dev/null | tr -d '"' | grep -i 'v=DMARC1' || true)
  [[ -n "$dmarc" ]] && ok "Public DMARC: present" || { err "Public DMARC: missing"; failed=1; }
  zone_file=$(stalwart_cli_admin get Domain "$id" --fields dnsZoneFile --json | jq -r '.dnsZoneFile // empty') || {
    err "Cannot retrieve expected DKIM DNS zone from Stalwart."; failed=1; zone_file="";
  }
  selectors=$(grep -Eio '[a-zA-Z0-9_-]+\._domainkey(\.[a-zA-Z0-9._-]+)?\.?' <<<"$zone_file" | sort -u || true)
  if [[ -z "$selectors" ]]; then
    warn "Stalwart does not currently expose a DKIM selector for $domain. Check DKIM configuration."
    failed=1
  else
    while IFS= read -r selector; do
      selector=${selector%.}
      [[ "$selector" == *."$domain" ]] || selector="${selector}.${domain}"
      public_dkim=$(dig +short TXT "$selector" @1.1.1.1 2>/dev/null | tr -d '"' || true)
      if [[ "$public_dkim" == *'DKIM'* ]]; then
        dkim_found=$((dkim_found+1))
      else
        err "DKIM selector absent in public DNS: $selector"; failed=1
      fi
    done <<<"$selectors"
    (( dkim_found > 0 )) && ok "DKIM selectors visible: $dkim_found"
  fi
  if [[ -n "$journal" && -s "$journal" ]]; then
    info "Manager phase: $(jq -r '.phase // "unknown"' "$journal")"
    token=$(multi_domain_token_file "$domain")
    zone_id=$(jq -r '.zoneId // empty' "$journal")
    if [[ -s "$token" && -n "$zone_id" ]]; then
      local CF_API_TOKEN
      CF_API_TOKEN=$(<"$token")
      cf_records=$(cf_domain_dns_snapshot "$domain" "$zone_id") || {
        err "Saved Cloudflare token cannot read DNS; rotate token or check zone permission."; failed=1;
      }
      if [[ -n "${cf_records:-}" ]]; then
        local conflicts
        conflicts=$(jq -n --arg d "$domain" --arg mx "$MAIL_HOST" --argjson r "$cf_records" '
          {mx:([$r[]|select(.type=="MX" and .name==$d)]|length),
           spf:([$r[]|select(.type=="TXT" and .name==$d and (.content|test("^v=spf1";"i")))]|length),
           dmarc:([$r[]|select(.type=="TXT" and .name==( "_dmarc."+$d ) and (.content|test("^v=DMARC1";"i")))]|length)}') || return 1
        if [[ $(jq -r '.mx' <<<"$conflicts") != 1 || $(jq -r '.spf' <<<"$conflicts") != 1 || $(jq -r '.dmarc' <<<"$conflicts") != 1 ]]; then
          err "Cloudflare conflicting mail records: $conflicts"; failed=1
        else ok "Cloudflare has one MX, one SPF, one DMARC."; fi
      fi
    else err "Cloudflare credential/journal missing."; failed=1; fi
  fi
  (( failed == 0 ))
}

manager_domain_health() {
  stage "Read-only per-domain diagnostic"
  multi_domain_preflight || return 1
  local rows domain journal rc=0
  rows=$(stalwart_domain_rows) || return 1
  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    journal=$(multi_domain_state_file "$domain")
    if [[ "$domain" == "$DOMAIN" ]]; then journal=""; fi
    manager_domain_check_one "$domain" "$journal" || rc=1
  done < <(jq -rs '.[].name' <<<"$rows")
  return "$rc"
}

manager_queue_overview() {
  stage "Outbound message queue (read-only)"
  local data
  data=$(stalwart_cli_admin query QueuedMessage --fields id,createdAt,returnPath,nextRetry,size --json) || return 1
  jq -rs '. | if length == 0 then "Queue empty" else (.[0:60][] | "ID=\(.id) From=\(.returnPath // "-") Retry=\(.nextRetry // "-") Size=\(.size // 0)") end' -r <<<"$data"
  info "Inspect, requeue or cancel messages in Stalwart WebUI (no destructive queue commands here)."
}

manager_accounts() {
  stage "Mail accounts"
  multi_domain_preflight || return 1
  local rows domain localpart account_json domid secret output path selection account_id new_alias alias_domain alias_id current updated
  rows=$(stalwart_cli_admin query Account --fields id,name,domainId,emailAddress,usedDiskQuota,aliases --json) || return 1
  if [[ -n "$rows" ]]; then
    jq -rs -r '.[] | "\(.id) | \(.emailAddress // .name) | used: \(.usedDiskQuota // 0) bytes"' <<<"$rows"
  fi
  (( NONINTERACTIVE )) && return 0
  printf '\n1) Create mailbox  2) Add alias  3) Inspect account\n4) Reset password  5) Delete after encrypted backup  0) Back\n'
  read -r -p 'Choose: ' selection
  case "$selection" in
    1)
      read -r -p 'Domain: ' domain; domain=$(normalize_domain "$domain")
      valid_domain "$domain" || { err "Invalid domain."; return 1; }
      domid=$(stalwart_domain_id "$domain") || return 1
      [[ -n "$domid" ]] || { err "Domain not found."; return 1; }
      read -r -p 'Mailbox local part (before @): ' localpart
      [[ "$localpart" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]{0,62}$ ]] || { err "Invalid local part."; return 1; }
      if jq -ers --arg mail "${localpart}@${domain}" 'any(.[]; ((.emailAddress//"")|ascii_downcase)==($mail|ascii_downcase))' <<<"$rows" >/dev/null; then
        err "Account exists; will not overwrite."; return 1
      fi
      confirm "Create ${localpart}@${domain}?" N || return 0
      secret=$(generate_hex_secret 20)
      account_json=$(jq -cn --arg local "$localpart" --arg d "$domid" --arg pass "$secret" '
        {"@type":"User", name:$local,domainId:$d,aliases:{},credentials:{"0":{"@type":"Password",secret:$pass}},
         memberGroupIds:{},roles:{"@type":"User"},permissions:{"@type":"Inherit"},quotas:{},encryptionAtRest:{"@type":"Disabled"}}') || return 1
      if ! stalwart_cli_admin create Account/User --stdin <<<"$account_json" >/dev/null; then
        err "Account creation failed; no credentials saved as active."; return 1
      fi
      path=/root/mailstack-mailboxes.txt
      { printf '\nCreated %s\n' "$(date -Is)"; printf 'Mailbox: %s@%s\nPassword: %s\n' "$localpart" "$domain" "$secret"; } >> "$path"
      chmod 0600 "$path"
      { echo; printf 'Mailbox: %s@%s\nPassword: %s\n' "$localpart" "$domain" "$secret"; } >>"$SECRETS_FILE"
      chmod 600 "$SECRETS_FILE"
      ok "Mailbox created. Credentials saved in root-only $path (not printed to logs)."
      ;;
    2)
      read -r -p 'Mailbox email receiving alias: ' domain
      valid_email "$domain" || { err "Invalid mailbox email."; return 1; }
      account_id=$(jq -rs --arg mail "$domain" '[.[]|select(.emailAddress==$mail)|.id]|first//empty' <<<"$rows")
      [[ -n "$account_id" ]] || { err "Mailbox not found."; return 1; }
      read -r -p 'New alias email: ' new_alias
      valid_email "$new_alias" || { err "Invalid alias address."; return 1; }
      alias_domain=${new_alias#*@}; localpart=${new_alias%@*}
      alias_id=$(stalwart_domain_id "$alias_domain") || return 1
      [[ -n "$alias_id" ]] || { err "Alias domain not found in Stalwart."; return 1; }
      if jq -ers --arg l "$localpart" --arg d "$alias_id" '
        any(.[]; any((.aliases // {})|to_entries[]?; .value.name?==$l and .value.domainId?==$d))' <<<"$rows" >/dev/null 2>&1; then
        err "The alias address already exists on an account; refusing duplicate."; return 1
      fi
      current=$(stalwart_cli_admin get Account "$account_id" --fields aliases --json) || return 1
      # Native CLI objects encode List<EmailAlias> as map-keyed JSON lists.
      updated=$(jq -cn --argjson data "$current" --arg l "$localpart" --arg d "$alias_id" '
        ($data.aliases // {}) as $aliases |
        if ($aliases|type)!="object" then error("Unexpected aliases encoding") else
          $aliases + {((([ $aliases|keys[]?|tonumber?] | max // -1)+1)|tostring):{name:$l,domainId:$d,enabled:true}}
        end') || return 1
      confirm "Attach alias ${new_alias} to ${domain}?" N || return 0
      # JSON-pointer patch adds only the newly allocated index; avoids
      # rewriting unrelated aliases another admin may have edited meanwhile.
      local ix new_alias_value
      ix=$(jq -r 'keys|map(tonumber)|max|tostring' <<<"$updated")
      new_alias_value=$(jq -c --arg k "$ix" '.[$k]' <<<"$updated")
      stalwart_cli_admin update Account "$account_id" --stdin <<<"$(jq -cn --arg key "aliases/${ix}" --argjson value "$new_alias_value" '{($key):$value}')" >/dev/null || return 1
      ok "Alias created. Check delivery with an external test message."
      ;;
    3)
      read -r -p 'Account ID (from list): ' account_id
      [[ "$account_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
      stalwart_cli_admin get Account "$account_id" --fields name,emailAddress,domainId,aliases,usedDiskQuota --json | jq '.'
      ;;
    4) manager_account_reset_password "$rows" ;;
    5) manager_account_delete_safe "$rows" ;;
    0|'') return 0;;
    *) warn "Invalid selection";;
  esac
}

manager_domain_preview() {
  stage "Read-only Cloudflare DNS / migration preview"
  local domain token zone data token_path report
  (( NONINTERACTIVE )) && { err "Domain input required."; return 1; }
  read -r -p 'Mail domain to inspect: ' domain
  domain=$(normalize_domain "$domain")
  valid_domain "$domain" || return 1
  if [[ "$domain" == "$DOMAIN" ]]; then
    token_path="$CF_TOKEN_FILE"
  else
    token_path=$(multi_domain_token_file "$domain")
  fi
  if [[ ! -s "$token_path" ]]; then
    multi_domain_cloudflare_auth "$domain" || return 1
  fi
  token=$(<"$token_path")
  local CF_API_TOKEN="$token"
  if [[ "$domain" == "$DOMAIN" ]]; then
    zone=$(cf_api_get_query "/zones" "name=${DOMAIN}" "status=active") || return 1
    zone=$(jq -r '.result[0].id // empty' <<<"$zone")
  else
    multi_domain_cloudflare_auth "$domain" || return 1
    zone="$NEW_ZONE_ID"
  fi
  [[ -n "$zone" ]] || return 1
  data=$(cf_domain_dns_snapshot "$domain" "$zone") || return 1
  report="${STATE_DIR}/migration-${domain}-$(date +%Y%m%d-%H%M%S).json"
  jq -n --arg d "$domain" --arg mx "$MAIL_HOST" --argjson records "$data" '
    {domain:$d,targetMX:$mx,currentlyConfigured:$records,
     warning:"READ ONLY. Existing provider may be live. Plan staged mailbox migration and lower TTL before MX cutover.",
     steps:["Export/backup mailboxes at old provider", "Provision matching mailboxes in Stalwart", "Copy messages via audited migration tool", "Confirm DKIM/SPF and outbound SMTP", "Schedule MX switch and test inbound delivery", "Monitor previous MX and queues before final retirement"]}' > "$report"
  chmod 600 "$report"
  jq -r '"CURRENT MX and authentication records:",(.currentlyConfigured[] | "\(.type) \(.name) \(.content)"),"Proposed new MX: \(.targetMX)","This preview DID NOT change DNS."' "$report"
  info "Read-only migration plan: $report"
}

manager_rotate_primary_cf_token() {
  # Called with the global manager maintenance lock already acquired.
  local old_token proposed old_response new_response current_zone new_zone status archive
  [[ -s "$CF_TOKEN_FILE" && -s "$CF_STALWART_TOKEN_FILE" ]] || {
    err "Primary token files are missing. No changes made."; return 1;
  }
  old_token=$(<"$CF_TOKEN_FILE")
  local CF_API_TOKEN="$old_token"
  old_response=$(cf_api_get_query "/zones" "name=${DOMAIN}" "status=active") || {
    err "Old primary token cannot read its current Cloudflare zone. Manual recovery required to validate zone identity."; return 1;
  }
  current_zone=$(jq -r 'if (.result|length)==1 then .result[0].id else empty end' <<<"$old_response")
  [[ -n "$current_zone" ]] || { err "Primary zone cannot be identified uniquely."; return 1; }
  echo "Create a NEW restricted Cloudflare token for the primary zone: ${DOMAIN}"
  read -r -s -p 'New primary Cloudflare API token: ' proposed; echo
  [[ "$proposed" =~ ^[A-Za-z0-9._-]+$ ]] || { err "Invalid token characters. No changes made."; return 1; }
  [[ "$proposed" != "$old_token" ]] || { err "New token matches current token."; return 1; }
  CF_API_TOKEN="$proposed"
  new_response=$(cf_api_raw GET "/user/tokens/verify") || {
    err "New token validation failed; primary token remains unchanged."; return 1;
  }
  status=$(jq -r '.result.status // empty' <<<"$new_response")
  [[ "$status" == active ]] || { err "New token is not active."; return 1; }
  new_response=$(cf_api_get_query "/zones" "name=${DOMAIN}" "status=active") || {
    err "New token cannot read the primary zone."; return 1;
  }
  new_zone=$(jq -r 'if (.result|length)==1 then .result[0].id else empty end' <<<"$new_response")
  [[ "$new_zone" == "$current_zone" ]] || {
    err "New token zone differs from existing production zone. Old token preserved."; return 1;
  }
  cf_api_get_query "/zones/${new_zone}/dns_records" 'per_page=1' >/dev/null || {
    err "New primary token has no DNS Read access. Old token preserved."; return 1;
  }
  warn "The primary Cloudflare token will change. Saved passwords and historical TXT will remain accessible."
  confirm "Switch primary Cloudflare token now?" N || return 0
  install -d -m 0700 "${EXTRA_CF_TOKENS_DIR}/archive"
  archive="${EXTRA_CF_TOKENS_DIR}/archive/primary-$(date +%Y%m%d-%H%M%S)-$$.token"
  cp -p "$CF_TOKEN_FILE" "$archive" || return 1
  # Prepare both replacement files BEFORE publishing either.
  printf '%s' "$proposed" >"${CF_TOKEN_FILE}.new" || return 1
  install -o root -g stalwart -m 0640 "${CF_TOKEN_FILE}.new" "${CF_STALWART_TOKEN_FILE}.new" || {
    rm -f "${CF_TOKEN_FILE}.new"; return 1;
  }
  if ! mv -f "${CF_TOKEN_FILE}.new" "$CF_TOKEN_FILE"; then
    rm -f "${CF_STALWART_TOKEN_FILE}.new"; return 1
  fi
  if ! mv -f "${CF_STALWART_TOKEN_FILE}.new" "$CF_STALWART_TOKEN_FILE"; then
    cp -p "$archive" "$CF_TOKEN_FILE"
    err "Failed to update Stalwart's token; primary root token restored."; return 1
  fi
  if ! stalwart_cli_admin create Action/ReloadSettings >/dev/null 2>&1; then
    cp -p "$archive" "$CF_TOKEN_FILE"
    install -o root -g stalwart -m 0640 "$archive" "$CF_STALWART_TOKEN_FILE"
    err "Stalwart settings reload failed. Previous primary token restored in both files."; return 1
  fi
  write_secrets_summary
  ok "Primary token rotated; the previous token remains archived and in root-only credential history."
  warn "Cloudflare DNS Write cannot be verified non-destructively. Validate that permission before the next DNS change."
}

manager_rotate_cf_token() {
  stage "Cloudflare token rotation"
  (( NONINTERACTIVE )) && { err "Interactive token entry required."; return 1; }
  manager_backup_lock || return 1
  local domain path old copied_zone
  read -r -p 'Cloudflare mail domain (primary or secondary): ' domain
  domain=$(normalize_domain "$domain")
  valid_domain "$domain" || return 1
  if [[ "$domain" == "$DOMAIN" ]]; then
    manager_rotate_primary_cf_token
    return $?
  fi
  path=$(multi_domain_state_file "$domain")
  [[ -s "$path" ]] || { err "Not a managed domain."; return 1; }
  old=$(multi_domain_token_file "$domain")
  copied_zone=$(jq -r '.zoneId' "$path")
  local backup
  backup=$(mktemp "${STATE_DIR}/old-token.XXXXXXXX") || return 1
  if [[ -f "$old" ]]; then cp -p "$old" "$backup"; else : >"$backup"; fi
  rm -f "$old"
  if ! multi_domain_cloudflare_auth "$domain"; then
    cp -p "$backup" "$old"
    install -o root -g stalwart -m 0640 "$backup" "$(multi_domain_stalwart_token_file "$domain")"
    rm -f "$backup"
    err "New token validation failed; previous saved token and server-side token restored."; return 1
  fi
  if [[ "$NEW_ZONE_ID" != "$copied_zone" ]]; then
    cp -p "$backup" "$old"
    install -o root -g stalwart -m 0640 "$backup" "$(multi_domain_stalwart_token_file "$domain")"
    rm -f "$backup"
    err "New token points to a different zone. Restored both previous token copies."; return 1
  fi
  rm -f "$backup"
  write_secrets_summary
  ok "Updated root-only Cloudflare token for $domain; the zone identifier is unchanged."
}

manager_security_review() {
  stage "Security posture review (read-only)"
  local file perms
  for file in "$SECRETS_FILE" "$SECRETS_STATE_FILE" "$CF_TOKEN_FILE" "$ALERTS_CONFIG" "$BACKUP_PASSWORD_FILE"; do
    [[ -e "$file" ]] || continue
    perms=$(stat -c %a "$file")
    if (( (8#$perms & 077) != 0 )); then err "$file is too permissive: $perms"; else ok "Root-only: $file ($perms)"; fi
  done
  if [[ -f /etc/stalwart/stalwart.env ]] && grep -Eq '^STALWART_RECOVERY_MODE=' /etc/stalwart/stalwart.env; then
    err "Recovery mode still enabled in runtime environment!"
  else ok "Stalwart recovery mode not configured."; fi
  if command -v ufw >/dev/null; then ufw status verbose | head -n 30; fi
  if command -v certbot >/dev/null; then certbot certificates 2>/dev/null | grep -E 'Certificate Name:|Expiry Date:' || true; fi
  info "Inspect Stalwart WebUI for account MFA, per-account quotas, spam rules, rate limits and access permissions."
  warn "No unreviewed firewall, spam, quota or rate-limit settings were changed."
}

manager_test_smtp() {
  stage "Authenticated SMTP submission test"
  (( NONINTERACTIVE )) && return 1
  local sender dest password payload netrc message_id response
  read -r -p 'Sender mailbox address: ' sender
  valid_email "$sender" || return 1
  read -r -p 'External test recipient address: ' dest
  valid_email "$dest" || return 1
  read -r -s -p "Password for $sender: " password; echo
  [[ -n "$password" && "$password" != *$'\n'* ]] || return 1
  # curl .netrc needs its own quoting rules. Refuse ambiguous values rather
  # than accidentally sending the wrong password or exposing it in process argv.
  [[ "$password" != *$'\r'* && "$password" != *'"'* && "$password" != *'\\'* ]] || {
    err "Password contains characters unsupported by this safe SMTP tester; use your email client instead."; return 1;
  }
  confirm "Send real test email from $sender to $dest?" N || return 0
  netrc=$(mktemp "${STATE_DIR}/smtp-netrc.XXXXXXXX") || return 1
  payload=$(mktemp "${STATE_DIR}/smtp-message.XXXXXXXX") || { rm -f "$netrc"; return 1; }
  # netrc avoids placing the password in the curl process argument list.
  printf 'machine %s login %s password %s\n' "$MAIL_HOST" "$sender" "$password" >"$netrc"
  chmod 600 "$netrc"
  message_id="$(date +%s).$$@${MAIL_HOST}"
  printf 'From: <%s>\r\nTo: <%s>\r\nSubject: MailStack 4.3 SMTP test\r\nMessage-ID: <%s>\r\nDate: %s\r\n\r\nSMTP authenticated submission diagnostic.\r\n' \
     "$sender" "$dest" "$message_id" "$(date -R)" >"$payload"
  if curl --silent --show-error --fail --connect-timeout 10 --max-time 45 --ssl-reqd \
       --netrc-file "$netrc" --mail-from "$sender" --mail-rcpt "$dest" \
       --upload-file "$payload" --resolve "${MAIL_HOST}:587:127.0.0.1" \
       "smtp://${MAIL_HOST}:587" >/dev/null; then
    ok "SMTP server accepted message. This DOES NOT prove final delivery. Message-ID: $message_id"
  else
    err "SMTP test failed."; rm -f "$netrc" "$payload"; return 1
  fi
  rm -f "$netrc" "$payload"
}

# Backup contains a real, consistency-checked offline snapshot of the default
# local RocksDB store, not merely the Stalwart CLI configuration snapshot.
# External DB/blob providers are explicitly refused rather than silently omitted.
manager_backup_require_local_store() {
  local storage blob diskpath configpath
  [[ -s /etc/stalwart/config.json ]] || { err "Stalwart bootstrap storage config unavailable."; return 1; }
  configpath=$(jq -r '.path // empty' /etc/stalwart/config.json 2>/dev/null || true)
  [[ "$(jq -r '."@type" // empty' /etc/stalwart/config.json)" == "RocksDb" ]] || {
    err "Non-RocksDB bootstrap store; full backup needs provider-specific consistent snapshots."; return 1;
  }
  storage=$(stalwart_cli_admin get DataStore --json) || {
    err "Cannot read live DataStore configuration."; return 1;
  }
  blob=$(stalwart_cli_admin get BlobStore --json) || {
    err "Cannot read live BlobStore configuration."; return 1;
  }
  # Strict standard local-only policy. Never pretend a backup of an external
  # S3/SQL store is complete. Paths must be evaluated from live configuration.
  diskpath=$(jq -r '.path // empty' <<<"$storage")
  [[ "$(jq -r '."@type" // empty' <<<"$storage")" == "RocksDb" ]] || {
    err "Live DataStore is not local RocksDB; full backup refused."; return 1;
  }
  if [[ "$diskpath" != "/var/lib/stalwart" && "$diskpath" != "/var/lib/stalwart/" ]]; then
    err "Nonstandard live data path ($diskpath). Full backup refused to prevent incomplete archives."; return 1
  fi
  [[ "$configpath" == "/var/lib/stalwart" || "$configpath" == "/var/lib/stalwart/" ]] || {
    err "Bootstrap store path differs from live/default; inspect manually."; return 1;
  }
  if [[ "$(jq -r '."@type" // empty' <<<"$blob")" != "Default" ]]; then
    err "Blob store is not Default/local: message data may be remote. Full backup refused."; return 1
  fi
  [[ -d /var/lib/stalwart ]] || { err "RocksDB data folder missing."; return 1; }
  [[ ! -L /var/lib/stalwart ]] || {
    err "Mail data folder is a symlink; full backup refuses to silently omit its real target."; return 1;
  }
}

manager_backup_password() {
  if [[ ! -s "$BACKUP_PASSWORD_FILE" ]]; then
    umask 077
    openssl rand -hex 48 >"$BACKUP_PASSWORD_FILE" || return 1
    chmod 600 "$BACKUP_PASSWORD_FILE"
    info "Created root-only backup encryption passphrase at $BACKUP_PASSWORD_FILE."
    # Persist in the existing TXT immediately; do not make backup failure lose it.
    if [[ -n "${STALWART_ADMIN_PASSWORD:-}" && -n "${MAIL_HOST:-}" ]]; then
      write_secrets_summary || warn "Could not refresh the root-only credentials TXT after passphrase creation."
    fi
    warn "Save this passphrase OFF the server, too. Losing it makes encrypted backups unusable."
  fi
}

manager_backup_lock() {
  exec 8>"$MANAGER_LOCK"
  flock -n 8 || { err "A conflicting maintenance/backup operation is running."; return 1; }
}

manager_backup_now() (
  stage "Encrypted cold backup (includes all local message data)"
  manager_backup_lock || return 1
  manager_backup_require_local_store || return 1
  command -v gpg >/dev/null || { err "gpg is required for authenticated AES256 encrypted backups."; return 1; }
  command -v tar >/dev/null || return 1
  command -v sha256sum >/dev/null || return 1
  manager_backup_password || return 1
  install -d -m 0700 "$FULL_BACKUP_DIR"
  local archive tmp items=() file sha was_running=0 bulwark_running=0 bulwark_mode=unknown
  local volume_paths="" mount_path mount_count
  # Mail configuration snapshot complements (but does not replace) the cold
  # RocksDB data copy. Failure is nonfatal because full local storage is copied.
  stalwart_cli_admin snapshot Tenant Domain Directory DkimSignature AcmeProvider Certificate DnsServer Role Account SystemSettings DataRetention BlobStore InMemoryStore SearchStore --allow-unresolved PublicKey --quiet \
      --output "${STATE_DIR}/stalwart-config-snapshot.ndjson" >/dev/null 2>&1 || \
      warn "Could not export the optional JMAP config snapshot; cold RocksDB backup remains authoritative."
  # Bulwark's settings/volumes are not in Stalwart's RocksDB directory.
  if docker inspect bulwark >/dev/null 2>&1; then
    bulwark_mode=docker
    volume_paths=$(docker inspect bulwark --format '{{json .Mounts}}' | jq -r '.[].Source') || return 1
    while IFS= read -r mount_path; do
      [[ -n "$mount_path" ]] || continue
      # Refuse backing up only half of webmail settings from unknown mounts.
      [[ "$mount_path" == /var/lib/docker/volumes/* && -d "$mount_path" ]] || {
        err "Bulwark has a nonstandard volume mount: $mount_path; full backup refused."; return 1;
      }
      items+=("${mount_path#/}")
    done <<<"$volume_paths"
  elif systemctl cat bulwark.service >/dev/null 2>&1; then
    bulwark_mode=native
  fi
  archive="${FULL_BACKUP_DIR}/full-$(date +%Y%m%d-%H%M%S)-$$.tar.gpg"
  tmp="${archive}.partial"
  for file in var/lib/stalwart etc/stalwart etc/nginx etc/letsencrypt var/lib/katebsaber-mailstack-installer root/mailstack-secrets.txt root/mailstack-mailboxes.txt etc/systemd/system/stalwart.service.d etc/systemd/system/stalwart.service etc/systemd/system/bulwark.service etc/bulwark var/lib/bulwark opt/bulwark opt/bulwark-docker usr/local/sbin/katebsaber-mailstack-manager usr/local/sbin/katebsaber-mailstack-virtual-mail etc/systemd/system/katebsaber-mailstack-virtual-mail.service etc/systemd/system/katebsaber-mailstack-virtual-mail.timer etc/systemd/system/katebsaber-mailstack-backup.service etc/systemd/system/katebsaber-mailstack-backup.timer etc/systemd/system/katebsaber-mailstack-health.service etc/systemd/system/katebsaber-mailstack-health.timer; do
    [[ -e "/$file" ]] && items+=("$file")
  done
  (( ${#items[@]} > 0 )) || { err "Nothing to back up."; return 1; }
  systemctl is-active --quiet stalwart && was_running=1
  if [[ "$bulwark_mode" == docker ]] && [[ "$(docker inspect -f '{{.State.Running}}' bulwark)" == true ]]; then
    bulwark_running=1
    docker stop bulwark >/dev/null || { err "Could not stop Bulwark for consistent snapshot."; return 1; }
  elif [[ "$bulwark_mode" == native ]] && systemctl is-active --quiet bulwark; then
    bulwark_running=1
    systemctl stop bulwark || { err "Could not stop Bulwark for consistent snapshot."; return 1; }
  fi
  # Start the service again even if stopping Stalwart fails.
  trap 'if (( was_running )); then systemctl start stalwart || echo "CRITICAL: restart stalwart manually" >&2; fi; if (( bulwark_running )); then if [[ "$bulwark_mode" == docker ]]; then docker start bulwark >/dev/null || true; else systemctl start bulwark || true; fi; fi; rm -f "$tmp"' EXIT
  if (( was_running )); then
    info "Stopping Stalwart briefly for a consistent RocksDB/mailbox archive."
    systemctl stop stalwart || { err "Unable to stop Stalwart; backup refused."; return 1; }
  fi
  # This EXIT handler runs in the function subshell even if tar/GPG fails.
  # Archive does not recursively copy earlier backup archives or history logs.
  if ! tar -C / --exclude='var/lib/katebsaber-mailstack-installer/full-backups' \
       --exclude='var/lib/katebsaber-mailstack-installer/backups' \
       -czf - "${items[@]}" | \
      gpg --batch --yes --pinentry-mode loopback --compress-algo none \
       --symmetric --cipher-algo AES256 --passphrase-file "$BACKUP_PASSWORD_FILE" \
       --output "$tmp" >/dev/null 2>&1; then
    err "Cold backup failed; partial archive removed, service restart will be attempted."; return 1
  fi
  # Restart immediately after snapshot; verify encryption after uptime resumes.
  if (( was_running )); then
    systemctl start stalwart || { err "CRITICAL: Stalwart restart failed after backup."; return 1; }
    was_running=0
  fi
  if (( bulwark_running )); then
    if [[ "$bulwark_mode" == docker ]]; then docker start bulwark >/dev/null || return 1; else systemctl start bulwark || return 1; fi
    bulwark_running=0
  fi
  mv "$tmp" "$archive" || return 1
  chmod 600 "$archive"
  sha=$(sha256sum "$archive" | awk '{print $1}') || return 1
  printf '%s  %s\n' "$sha" "$(basename "$archive")" >"${archive}.sha256"
  chmod 600 "${archive}.sha256"
  printf 'date=%s\nhost=%s\nstore=local-rocksdb\nformat=encrypted-tar-gpg\n' \
    "$(date -Is)" "$(hostname -f)" >"${archive}.meta"
  chmod 600 "${archive}.meta"
  printf '%s\n' "$(date +%s)" >"${FULL_BACKUP_DIR}/last-success.epoch"
  manager_verify_backup "$archive" || { err "Encrypted backup could not be verified."; return 1; }
  ok "Cold backup created and verified: $archive"
  info "Passphrase: $BACKUP_PASSWORD_FILE (preserved, root-only)."
)

manager_verify_backup() {
  local archive="$1" base sumfile expected actual
  [[ -f "$archive" && "$archive" == *.tar.gpg ]] || { err "Encrypted backup archive not found."; return 1; }
  [[ -s "$BACKUP_PASSWORD_FILE" ]] || { err "Backup passphrase file missing."; return 1; }
  sumfile="${archive}.sha256"
  [[ -s "$sumfile" ]] || { err "Backup checksum file missing."; return 1; }
  expected=$(awk 'NR==1{print $1}' "$sumfile")
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || return 1
  actual=$(sha256sum "$archive" | awk '{print $1}') || return 1
  [[ "$expected" == "$actual" ]] || { err "Backup SHA256 mismatch!"; return 1; }
  # Check decompression AND archive readability. GPG detects tampering.
  if ! gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_PASSWORD_FILE" \
        --decrypt "$archive" 2>/dev/null | tar -tzf - >/dev/null; then
    err "Backup decryption / TAR verification failed."; return 1
  fi
  ok "Verified encrypted backup (digest, decryption, archive listing): $archive"
}

manager_restore_backup() (
  stage "Disaster recovery: offline archive restoration"
  (( NONINTERACTIVE )) && { err "Restore requires a real interactive TTY and exact phrase."; return 1; }
  local archive="$1" filename check entry was_running=0 bulwark_running=0 bulwark_mode=unknown
  archive=$(realpath -e "$archive") || return 1
  [[ "$archive" == "$FULL_BACKUP_DIR"/*.tar.gpg ]] || {
    err "Only archives created in the manager backup directory are accepted."; return 1;
  }
  manager_verify_backup "$archive" || return 1
  local listing
  listing=$(gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_PASSWORD_FILE" \
    --decrypt "$archive" 2>/dev/null | tar -tzf -) || return 1
  # Defense against archive traversal and unknown filesystem locations.
  while IFS= read -r entry; do
    [[ "$entry" != /* && "$entry" != *"../"* && "$entry" != ".." ]] || return 1
    case "$entry" in
      var/lib/stalwart|var/lib/stalwart/*|var/lib/docker/volumes/*|\
      etc/stalwart|etc/stalwart/*|etc/nginx|etc/nginx/*|\
      etc/letsencrypt|etc/letsencrypt/*|var/lib/katebsaber-mailstack-installer|\
      var/lib/katebsaber-mailstack-installer/*|root/mailstack-secrets.txt|\
      root/mailstack-mailboxes.txt|etc/systemd/system/stalwart.service|\
      etc/systemd/system/bulwark.service|etc/bulwark|etc/bulwark/*|\
      var/lib/bulwark|var/lib/bulwark/*|opt/bulwark|opt/bulwark/*|\
      opt/bulwark-docker|opt/bulwark-docker/*|etc/systemd/system/stalwart.service.d|\
      etc/systemd/system/stalwart.service.d/*|usr/local/sbin/katebsaber-mailstack-manager|\
      usr/local/sbin/katebsaber-mailstack-virtual-mail|\
      etc/systemd/system/katebsaber-mailstack-virtual-mail.service|\
      etc/systemd/system/katebsaber-mailstack-virtual-mail.timer|\
      etc/systemd/system/katebsaber-mailstack-backup.service|\
      etc/systemd/system/katebsaber-mailstack-backup.timer|\
      etc/systemd/system/katebsaber-mailstack-health.service|\
      etc/systemd/system/katebsaber-mailstack-health.timer) : ;;
      *) err "Unexpected archive entry: $entry"; return 1;;
    esac
  done <<<"$listing"
  [[ -n "$listing" ]] || return 1
  warn "This overwrites current Stalwart data, settings and TXT credentials with backup copies."
  warn "You must also have an independently copied backup and its encryption passphrase."
  warn "Changes made since $(basename "$archive") will NOT survive this restore."
  read -r -p 'Type RESTORE MAIL DATA to continue: ' check
  [[ "$check" == 'RESTORE MAIL DATA' ]] || return 0
  # Make an emergency snapshot *before* allowing the restore. It contains the
  # current data and root-only secrets and can be used to undo the restore.
  manager_backup_now || { err "Pre-restore safety backup failed. Aborted."; return 1; }
  manager_backup_lock || { err "Another maintenance operation began. Restore cancelled."; return 1; }
  systemctl is-active --quiet stalwart && was_running=1
  if docker inspect bulwark >/dev/null 2>&1; then
    bulwark_mode=docker
    [[ "$(docker inspect -f '{{.State.Running}}' bulwark)" == true ]] && bulwark_running=1
  elif systemctl cat bulwark.service >/dev/null 2>&1; then
    bulwark_mode=native
    systemctl is-active --quiet bulwark && bulwark_running=1
  fi
  trap 'if (( was_running )); then systemctl start stalwart || echo "CRITICAL: restart stalwart manually" >&2; fi; if (( bulwark_running )); then if [[ "$bulwark_mode" == docker ]]; then docker start bulwark >/dev/null || true; else systemctl start bulwark || true; fi; fi' EXIT
  if (( bulwark_running )); then
    if [[ "$bulwark_mode" == docker ]]; then docker stop bulwark >/dev/null || return 1
    else systemctl stop bulwark || return 1; fi
  fi
  if (( was_running )); then systemctl stop stalwart || return 1; fi
  if ! gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_PASSWORD_FILE" \
       --decrypt "$archive" 2>/dev/null | tar -C / -xzpf - --no-overwrite-dir; then
    err "Restore failed. Stalwart restart will be attempted; use pre-restore backup for recovery."; return 1
  fi
  systemctl daemon-reload
  if (( was_running )); then systemctl start stalwart || return 1; was_running=0; fi
  if (( bulwark_running )); then
    if [[ "$bulwark_mode" == docker ]]; then docker start bulwark >/dev/null || return 1
    else systemctl start bulwark || return 1; fi
    bulwark_running=0
  fi
  ok "Restored backup content. Verify domain DNS, mailbox access and SMTP/IMAP immediately."
)

manager_backup_timer() {
  stage "Install scheduled encrypted backups and alert checks"
  (( NONINTERACTIVE )) || confirm "Install systemd timers and persistent manager command?" N || return 0
  manager_backup_require_local_store || return 1
  command -v gpg >/dev/null || { err "gpg is required."; return 1; }
  manager_backup_password || return 1
  install -m 0700 "$(readlink -f "${BASH_SOURCE[0]}")" "$MANAGER_PERSISTENT"
  cat >/etc/systemd/system/katebsaber-mailstack-backup.service <<EOF
[Unit]
Description=MailStack encrypted cold backup
[Service]
Type=oneshot
ExecStart=${MANAGER_PERSISTENT} --backup-now --non-interactive
TimeoutStartSec=3h
EOF
  cat >/etc/systemd/system/katebsaber-mailstack-backup.timer <<'EOF'
[Unit]
Description=MailStack daily encrypted backup
[Timer]
OnCalendar=*-*-* 03:10:00
Persistent=true
RandomizedDelaySec=30m
[Install]
WantedBy=timers.target
EOF
  cat >/etc/systemd/system/katebsaber-mailstack-health.service <<EOF
[Unit]
Description=MailStack monitor and alerts
[Service]
Type=oneshot
ExecStart=${MANAGER_PERSISTENT} --alert-check --non-interactive
EOF
  cat >/etc/systemd/system/katebsaber-mailstack-health.timer <<'EOF'
[Unit]
Description=MailStack condition checks
[Timer]
OnCalendar=*:0/15
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now katebsaber-mailstack-backup.timer katebsaber-mailstack-health.timer || return 1
  ok "Daily cold backup and 15-minute monitoring timers installed."
  info "Systemd units point to the versioned manager copy: $MANAGER_PERSISTENT"
}

manager_telegram_post() {
  local token="$1" chat="$2" message="$3" response
  # Bot secret is read via curl config stdin, not a visible command argument.
  response=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" | \
    curl -fsS --connect-timeout 8 --max-time 20 -K - \
      --data-urlencode "chat_id=$chat" --data-urlencode "text=$message" --data-urlencode 'disable_web_page_preview=true') || return 1
  jq -e '.ok == true' <<<"$response" >/dev/null
}

manager_alert_config() {
  stage "Telegram alert configuration"
  (( NONINTERACTIVE )) && return 1
  local token chat
  read -r -s -p 'Telegram Bot Token: ' token; echo
  read -r -p 'Telegram chat ID: ' chat
  [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { err "Invalid bot token format."; return 1; }
  [[ "$chat" =~ ^-?[0-9]+$ ]] || { err "Invalid chat ID."; return 1; }
  if ! manager_telegram_post "$token" "$chat" "MailStack 4.3 alerts configured on $(hostname -f)"; then
    err "Telegram send test failed. Nothing replaced."; return 1
  fi
  { printf 'TELEGRAM_BOT_TOKEN=%q\n' "$token"; printf 'TELEGRAM_CHAT_ID=%q\n' "$chat"; } >"${ALERTS_CONFIG}.new"
  chmod 600 "${ALERTS_CONFIG}.new"
  mv "${ALERTS_CONFIG}.new" "$ALERTS_CONFIG"
  write_secrets_summary
  ok "Telegram token/chat saved root-only; test message delivered to the Telegram API."
}

manager_alert_check() {
  [[ -s "$ALERTS_CONFIG" ]] || { info "No Telegram alert connection configured."; return 0; }
  # shellcheck disable=SC1090
  source "$ALERTS_CONFIG"
  local issues=() key report disk free last now days ssl_epoch
  if ! systemctl is-active --quiet stalwart; then issues+=("Stalwart service is not active"); fi
  if ! systemctl is-active --quiet nginx; then issues+=("Nginx service is not active"); fi
  # Read-only alert checks for outbound backlog and mail-domain DNS. A query
  # failure is itself reported instead of silently treated as an empty queue.
  local queue_data queue_count mx_check journal managed_domain
  if queue_data=$(stalwart_cli_admin query QueuedMessage --fields id --json 2>/dev/null); then
    queue_count=$(jq -rs 'length' <<<"$queue_data" 2>/dev/null || echo 0)
    [[ "$queue_count" =~ ^[0-9]+$ ]] && (( queue_count >= 100 )) && \
      issues+=("SMTP outbound queue has $queue_count messages (threshold 100)")
  else
    issues+=("Cannot read Stalwart outbound message queue")
  fi
  for managed_domain in "$DOMAIN"; do
    mx_check=$(dig +time=2 +tries=1 +short MX "$managed_domain" @1.1.1.1 2>/dev/null || true)
    [[ "${mx_check,,}" == *"${MAIL_HOST,,}"* ]] || issues+=("Domain MX issue: $managed_domain does not route to $MAIL_HOST")
  done
  for journal in "${EXTRA_DOMAINS_DIR}"/*.json; do
    [[ -s "$journal" ]] || continue
    [[ "$(jq -r '.phase // empty' "$journal" 2>/dev/null)" == ready ]] || continue
    managed_domain=$(jq -r '.domain // empty' "$journal" 2>/dev/null || true)
    valid_domain "$managed_domain" || continue
    mx_check=$(dig +time=2 +tries=1 +short MX "$managed_domain" @1.1.1.1 2>/dev/null || true)
    [[ "${mx_check,,}" == *"${MAIL_HOST,,}"* ]] || issues+=("Secondary domain MX issue: $managed_domain")
  done
  disk=$(df -P /var/lib/stalwart | awk 'NR==2 {gsub(/%/,"",$5);print $5}')
  [[ "$disk" =~ ^[0-9]+$ ]] && (( disk >= 85 )) && issues+=("Mail data disk usage is ${disk}%")
  if [[ -s "$FULL_BACKUP_DIR/last-success.epoch" ]]; then
    last=$(<"$FULL_BACKUP_DIR/last-success.epoch")
    now=$(date +%s)
    [[ "$last" =~ ^[0-9]+$ ]] && (( now-last > 172800 )) && issues+=("No successful encrypted backup for 48h")
  else issues+=("No verified encrypted backup yet"); fi
  if [[ -s "/etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem" ]]; then
    ssl_epoch=$(date -d "$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem" | cut -d= -f2-)" +%s 2>/dev/null || echo 0)
    (( ssl_epoch > 0 && ssl_epoch - $(date +%s) < 14*86400 )) && issues+=("Mail TLS certificate expires in under 14 days")
  fi
  if (( ${#issues[@]} == 0 )); then
    rm -f "$ALERTS_STATE"
    return 0
  fi
  report=$(printf '%s\n' "${issues[@]}")
  key=$(printf '%s' "$report" | sha256sum | awk '{print $1}')
  # Send only when health state changes; avoid 15-minute duplicate spam.
  [[ -f "$ALERTS_STATE" && "$(cat "$ALERTS_STATE")" == "$key" ]] && return 0
  if manager_telegram_post "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID" "MailStack alert on $(hostname -f):"$'\n'"$report"; then
    printf '%s' "$key" >"$ALERTS_STATE"; chmod 600 "$ALERTS_STATE"
    ok "Telegram health alert delivered."
  else err "Telegram health alert delivery failed."; return 1; fi
}

manager_cancel_retirement() {
  (( NONINTERACTIVE )) && return 1
  local d file
  read -r -p 'Secondary domain to cancel retirement: ' d
  d=$(normalize_domain "$d")
  valid_domain "$d" || return 1
  file=$(multi_domain_state_file "$d")
  [[ -s "$file" && "$(jq -r '.phase' "$file")" == 'retirement-pending' ]] || return 1
  multi_domain_state_update "$file" 'del(.retirementRequestedEpoch) | .phase="ready"' || return 1
  ok "Retirement cancelled; DNS and Stalwart remain untouched."
}

# Automatically create a standards-required postmaster recipient on new domains.
# It is a real account (not a black-hole alias), with its own saved credentials.
manager_ensure_postmaster() {
  local domain="$1" id rows pwd json archive
  id=$(stalwart_domain_id "$domain") || return 1
  [[ -n "$id" ]] || return 1
  rows=$(stalwart_cli_admin query Account --fields name,domainId --json) || return 1
  if jq -ers --arg id "$id" 'any(.[]; .domainId==$id and (.name|ascii_downcase)=="postmaster")' <<<"$rows" >/dev/null; then
    info "postmaster@$domain mailbox exists."
    return 0
  fi
  pwd=$(generate_hex_secret 24)
  json=$(jq -nc --arg id "$id" --arg pw "$pwd" '
    {"@type":"User",name:"postmaster",domainId:$id,
     credentials:{"0":{"@type":"Password",secret:$pw}},aliases:{},memberGroupIds:{},
     roles:{"@type":"User"},permissions:{"@type":"Inherit"},quotas:{},
     encryptionAtRest:{"@type":"Disabled"}}') || return 1
  if ! stalwart_cli_admin create Account/User --stdin <<<"$json" >/dev/null; then
    err "Could not create required postmaster mailbox for $domain."
    return 1
  fi
  { printf '\nCreated %s\nMailbox: postmaster@%s\nPassword: %s\n' "$(date -Is)" "$domain" "$pwd"; } >>/root/mailstack-mailboxes.txt
  chmod 600 /root/mailstack-mailboxes.txt
  write_secrets_summary
  ok "Created postmaster@$domain; credentials saved root-only."
}

manager_account_reset_password() {
  local rows="$1" email id current position password patch
  read -r -p 'Exact mailbox email for reset: ' email
  valid_email "$email" || return 1
  id=$(jq -rs --arg email "$email" '[.[] | select(.emailAddress==$email) | .id] | first // empty' <<<"$rows") || return 1
  [[ -n "$id" ]] || { err "Mailbox was not found."; return 1; }
  current=$(stalwart_cli_admin get Account "$id" --fields credentials --json) || return 1
  position=$(jq -r '(.credentials // {}) | to_entries | map(select(.value."@type"=="Password")) | if length==1 then .[0].key else empty end' <<<"$current") || return 1
  [[ "$position" =~ ^[0-9]+$ ]] || {
    err "Exactly one password credential is required; refusing to overwrite other credentials."; return 1;
  }
  confirm "Reset password for ${email}, preserving all other credentials?" N || return 0
  password=$(generate_hex_secret 24)
  patch=$(jq -cn --arg key "credentials/${position}/secret" --arg pass "$password" '{($key):$pass}') || return 1
  if ! stalwart_cli_admin update Account "$id" --stdin <<<"$patch" >/dev/null; then
    err "Password update failed; existing credentials retained."; return 1
  fi
  { printf '\nPassword reset %s\nMailbox: %s\nNew password: %s\n' "$(date -Is)" "$email" "$password"; } >>/root/mailstack-mailboxes.txt
  chmod 600 /root/mailstack-mailboxes.txt
  write_secrets_summary
  ok "Password reset successfully; root-only mailbox TXT updated (existing entries preserved)."
}

manager_account_delete_safe() {
  local rows="$1" email id check
  read -r -p 'Exact mailbox email for deletion: ' email
  valid_email "$email" || return 1
  id=$(jq -rs --arg email "$email" '[.[]|select(.emailAddress==$email)|.id]|first//empty' <<<"$rows") || return 1
  [[ -n "$id" ]] || { err "Mailbox not found."; return 1; }
  [[ "$email" != "$STALWART_ADMIN_USER" ]] || { err "Primary administrator cannot be removed."; return 1; }
  warn "Deleting this account removes its mailbox data; its saved passwords TXT will be preserved."
  read -r -p "Type DELETE ACCOUNT $email to confirm: " check
  [[ "$check" == "DELETE ACCOUNT $email" ]] || return 0
  # Prove a restorable encrypted local-data backup exists immediately before
  # destructive mailbox deletion. Fails shut for external data stores.
  manager_backup_now || { err "Mailbox deletion refused: safety backup failed."; return 1; }
  stalwart_cli_admin delete Account --ids "$id" || return 1
  ok "Account deleted. A verified pre-deletion encrypted backup is available."
}

manager_dns_advanced_review() {
  stage "MTA-STS / TLS-RPT / autoconfig read-only review"
  local domain mta record policy tls auto
  local rows
  rows=$(stalwart_domain_rows) || return 1
  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    echo "---- $domain ----"
    mta=$(dig +short TXT "_mta-sts.${domain}" @1.1.1.1 2>/dev/null | tr -d '"' || true)
    tls=$(dig +short TXT "_smtp._tls.${domain}" @1.1.1.1 2>/dev/null | tr -d '"' || true)
    auto=$(dig +short CNAME "autoconfig.${domain}" @1.1.1.1 2>/dev/null || true)
    if [[ "$mta" == *"v=STSv1"* ]]; then
      policy=$(curl --connect-timeout 5 --max-time 10 -fsS "https://mta-sts.${domain}/.well-known/mta-sts.txt" || true)
      if [[ "$policy" == *"version: STSv1"* && "$policy" == *"mx:"* ]]; then
        ok "MTA-STS DNS and HTTPS policy present."
      else err "MTA-STS record exists, but HTTPS policy is inaccessible/incomplete."; fi
    else info "MTA-STS not advertised; no automatic policy activation."; fi
    if [[ "$tls" == *"v=TLSRPTv1"* ]]; then ok "TLS-RPT DNS record present."; else info "TLS-RPT not published."; fi
    [[ -n "$auto" ]] && info "Autoconfig CNAME: $auto" || info "Autoconfig CNAME: not present."
  done < <(jq -rs '.[].name' <<<"$rows")
  info "Optional HTTPS features are NOT published automatically until endpoints and TLS are prepared."
}

# -----------------------------------------------------------------------------
# Lifecycle manager: versions, updates, credentials, health, repair
# -----------------------------------------------------------------------------

managed_stack_exists() {
  [[ -s "$CONFIG_FILE" && -s "$SECRETS_STATE_FILE" ]] || return 1
  stalwart_binary_path >/dev/null 2>&1 || return 1
  stalwart_service_exists || return 1
  return 0
}

load_managed_state() {
  [[ -s "$CONFIG_FILE" ]] || fatal "Managed configuration file is missing: $CONFIG_FILE"
  [[ -s "$SECRETS_STATE_FILE" ]] || fatal "Managed secrets state is missing: $SECRETS_STATE_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$SECRETS_STATE_FILE"
  STALWART_ADMIN_USER="admin@${DOMAIN}"

  if docker inspect bulwark >/dev/null 2>&1; then
    BULWARK_MODE="docker"
  elif systemctl cat bulwark.service >/dev/null 2>&1; then
    BULWARK_MODE="native"
  else
    BULWARK_MODE="unknown"
  fi
}

normalize_version() {
  local v="${1:-}"
  v="${v#v}"
  printf '%s' "$v"
}

version_line() {
  local v
  v=$(normalize_version "${1:-}")
  awk -F. '{print $1"."$2}' <<<"$v"
}

version_is_newer() {
  local latest current
  latest=$(normalize_version "${1:-}")
  current=$(normalize_version "${2:-}")
  [[ -n "$latest" && -n "$current" ]] || return 1
  dpkg --compare-versions "$latest" gt "$current"
}

github_latest_release_json() {
  local repo="$1"
  curl -fsSL --connect-timeout 8 --max-time 25 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${GITHUB_API}/repos/${repo}/releases/latest"
}

github_latest_version() {
  local repo="$1" json
  json=$(github_latest_release_json "$repo" 2>/dev/null || true)
  [[ -n "$json" ]] || return 1
  jq -r '.tag_name // empty' <<<"$json" | sed 's/^v//'
}

stalwart_current_version() {
  local binary out
  binary=$(stalwart_binary_path 2>/dev/null || true)
  [[ -n "$binary" ]] || { printf '%s' "not-installed"; return; }
  out=$("$binary" --version 2>/dev/null | head -n1 || true)
  grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?' <<<"$out" | head -n1 || printf '%s' "unknown"
}

stalwart_cli_current_version() {
  local out
  command -v stalwart-cli >/dev/null 2>&1 || { printf '%s' "not-installed"; return; }
  out=$(stalwart-cli --version 2>/dev/null | head -n1 || true)
  grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?' <<<"$out" | head -n1 || printf '%s' "unknown"
}

bulwark_current_version() {
  local v=""
  if docker inspect bulwark >/dev/null 2>&1; then
    v=$(docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' bulwark 2>/dev/null || true)
    [[ "$v" == "<no value>" ]] && v=""
    if [[ -z "$v" ]]; then
      v=$(docker exec bulwark node -e '
        const fs=require("fs");
        for (const p of ["/app/package.json","/app/.next/standalone/package.json","/app/server/package.json"]) {
          try { const x=JSON.parse(fs.readFileSync(p,"utf8")); if (x.version) { console.log(x.version); process.exit(0); } } catch(e) {}
        }
        process.exit(1);
      ' 2>/dev/null | head -n1 || true)
    fi
  elif [[ -r /opt/bulwark/package.json ]]; then
    v=$(jq -r '.version // empty' /opt/bulwark/package.json 2>/dev/null || true)
  fi
  [[ -n "$v" ]] && printf '%s' "${v#v}" || printf '%s' "unknown"
}

docker_current_version() {
  command -v docker >/dev/null 2>&1 || { printf '%s' "not-installed"; return; }
  docker version --format '{{.Server.Version}}' 2>/dev/null || docker --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || printf '%s' "unknown"
}

nginx_current_version() {
  nginx -v 2>&1 | sed -n 's#.*nginx/##p' | head -n1 || true
}

certbot_current_version() {
  certbot --version 2>/dev/null | awk '{print $2}' | head -n1 || true
}

apt_candidate_version() {
  local pkg="$1"
  apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
}

print_component_versions() {
  stage "Installed and latest versions"
  local sw sw_latest cli cli_latest bw bw_latest dv nv cv
  sw=$(stalwart_current_version)
  cli=$(stalwart_cli_current_version)
  bw=$(bulwark_current_version)
  dv=$(docker_current_version)
  nv=$(nginx_current_version)
  cv=$(certbot_current_version)

  info "Checking official release feeds..."
  sw_latest=$(github_latest_version stalwartlabs/stalwart 2>/dev/null || true)
  cli_latest=$(github_latest_version stalwartlabs/cli 2>/dev/null || true)
  bw_latest=$(github_latest_version bulwarkmail/webmail 2>/dev/null || true)

  printf '\n%-20s %-20s %-20s %s\n' "Component" "Installed" "Latest/Candidate" "State"
  printf '%-20s %-20s %-20s %s\n' "--------------------" "--------------------" "--------------------" "----------"

  component_version_row "Stalwart" "$sw" "${sw_latest:-unavailable}"
  component_version_row "Stalwart CLI" "$cli" "${cli_latest:-unavailable}"
  component_version_row "Bulwark" "$bw" "${bw_latest:-unavailable}"
  printf '%-20s %-20s %-20s %s\n' "Docker" "${dv:-unknown}" "$(apt_candidate_version docker.io || true)" "APT"
  printf '%-20s %-20s %-20s %s\n' "Nginx" "${nv:-unknown}" "$(apt_candidate_version nginx || true)" "APT"
  printf '%-20s %-20s %-20s %s\n' "Certbot" "${cv:-unknown}" "$(apt_candidate_version certbot || true)" "APT"
  printf '%-20s %-20s %-20s %s\n' "Installer" "$SCRIPT_VERSION" "-" "local"
  echo
}

component_version_row() {
  local label="$1" current="$2" latest="$3" state="unknown"
  if [[ "$latest" == "unavailable" || "$latest" == "unknown" || -z "$latest" ]]; then
    state="offline"
  elif [[ "$current" == "not-installed" ]]; then
    state="missing"
  elif [[ "$current" == "unknown" ]]; then
    state="check"
  elif version_is_newer "$latest" "$current"; then
    state="UPDATE"
  else
    state="current"
  fi
  printf '%-20s %-20s %-20s %s\n' "$label" "$current" "$latest" "$state"
}

show_access_information() {
  stage "Access information"
  write_secrets_summary
  if [[ -w /dev/tty ]]; then
    cat "$SECRETS_FILE" >/dev/tty
  else
    warn "No interactive terminal; credentials are available in root-only TXT: $SECRETS_FILE"
  fi
  info "Credentials file (root-only, preserved): $SECRETS_FILE"
}

service_state_word() {
  local unit="$1"
  if systemctl is-active --quiet "$unit" 2>/dev/null; then printf '%s' active; else printf '%s' inactive; fi
}

manager_health_check() {
  stage "Mail stack health check"
  local failures=0 p

  if systemctl is-active --quiet stalwart; then ok "Stalwart service is active."; else err "Stalwart service is not active."; failures=$((failures+1)); fi
  if systemctl is-active --quiet nginx; then ok "Nginx service is active."; else err "Nginx service is not active."; failures=$((failures+1)); fi

  if [[ "${BULWARK_MODE:-unknown}" == "docker" ]]; then
    if docker inspect -f '{{.State.Running}}' bulwark 2>/dev/null | grep -q true; then ok "Bulwark container is running."; else err "Bulwark container is not running."; failures=$((failures+1)); fi
  elif [[ "${BULWARK_MODE:-unknown}" == "native" ]]; then
    if systemctl is-active --quiet bulwark; then ok "Bulwark service is active."; else err "Bulwark service is not active."; failures=$((failures+1)); fi
  else
    err "Bulwark deployment could not be identified."
    failures=$((failures+1))
  fi

  for p in 25 465 587 993; do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"; then
      ok "TCP/${p} is listening."
    else
      err "TCP/${p} is not listening."
      failures=$((failures+1))
    fi
  done

  if curl -fsS --connect-timeout 8 "https://${MAIL_HOST}/.well-known/jmap" >/dev/null 2>&1; then
    ok "Public JMAP endpoint responds."
  else
    err "Public JMAP endpoint failed."
    failures=$((failures+1))
  fi

  if curl -fsS --connect-timeout 8 "https://${WEBMAIL_HOST}/api/health" >/dev/null 2>&1; then
    ok "Public Bulwark health endpoint responds."
  else
    err "Public Bulwark health endpoint failed."
    failures=$((failures+1))
  fi

  if (( failures == 0 )); then
    ok "All manager health checks passed."
  else
    warn "Health check finished with ${failures} problem(s)."
    return 1
  fi
}

backup_metadata_dir() {
  local kind="$1" stamp dir
  stamp=$(date +%Y%m%d-%H%M%S)
  dir="${BACKUP_ROOT}/${kind}-${stamp}"
  mkdir -p "$dir"
  chmod 700 "$dir"
  printf '%s' "$dir"
}

stalwart_release_asset_name() {
  case "$(uname -m)" in
    x86_64) printf '%s' 'stalwart-x86_64-unknown-linux-gnu.tar.gz' ;;
    aarch64|arm64) printf '%s' 'stalwart-aarch64-unknown-linux-gnu.tar.gz' ;;
    *) return 1 ;;
  esac
}

update_stalwart() {
  stage "Update Stalwart"
  local current latest current_line latest_line json asset url digest tmp backup binary newbin
  current=$(stalwart_current_version)
  json=$(github_latest_release_json stalwartlabs/stalwart) || fatal "Could not query the latest Stalwart release."
  latest=$(jq -r '.tag_name // empty' <<<"$json" | sed 's/^v//')
  [[ -n "$latest" ]] || fatal "Latest Stalwart version could not be determined."

  info "Installed Stalwart: ${current}"
  info "Latest Stalwart:    ${latest}"
  if [[ "$current" != "unknown" ]] && ! version_is_newer "$latest" "$current"; then
    ok "Stalwart is already current."
    return 0
  fi

  if [[ "$current" != "unknown" && "$current" != "not-installed" ]]; then
    current_line=$(version_line "$current")
    latest_line=$(version_line "$latest")
    if [[ "$current_line" != "$latest_line" ]]; then
      warn "Stalwart release line changed (${current_line} -> ${latest_line})."
      warn "Automatic cross-line migration is intentionally blocked because Stalwart may require migration steps."
      warn "Review the official UPGRADING documentation before changing release lines."
      return 2
    fi
  fi

  asset=$(stalwart_release_asset_name) || fatal "Unsupported CPU architecture for automatic Stalwart update: $(uname -m)"
  url=$(jq -r --arg a "$asset" '.assets[] | select(.name==$a) | .browser_download_url' <<<"$json" | head -n1)
  digest=$(jq -r --arg a "$asset" '.assets[] | select(.name==$a) | .digest // empty' <<<"$json" | head -n1)
  [[ -n "$url" ]] || fatal "Could not find Stalwart release asset: $asset"

  backup=$(backup_metadata_dir stalwart)
  binary=$(stalwart_binary_path) || fatal "Stalwart binary not found."
  cp -a "$binary" "$backup/stalwart.bin"
  cp -a /etc/stalwart "$backup/etc-stalwart" 2>/dev/null || true
  printf 'version=%s\n' "$current" >"$backup/version.txt"
  info "Backup: $backup"

  tmp=$(mktemp -d)
  curl -fL --retry 3 --connect-timeout 10 --max-time 300 "$url" -o "$tmp/$asset"
  if [[ "$digest" == sha256:* ]]; then
    printf '%s  %s\n' "${digest#sha256:}" "$tmp/$asset" | sha256sum -c - >/dev/null || fatal "Stalwart release SHA-256 verification failed."
  else
    warn "GitHub release metadata did not expose a SHA-256 digest; continuing over HTTPS."
  fi
  tar -xzf "$tmp/$asset" -C "$tmp"
  newbin=$(find "$tmp" -maxdepth 3 -type f -name stalwart -perm -u+x | head -n1 || true)
  [[ -n "$newbin" ]] || fatal "Downloaded Stalwart archive did not contain an executable."

  systemctl stop stalwart
  install -m 0755 "$newbin" "${binary}.new"
  mv -f "${binary}.new" "$binary"
  systemctl start stalwart

  if ! systemctl is-active --quiet stalwart; then
    err "New Stalwart failed to start; rolling back the previous binary."
    systemctl stop stalwart >/dev/null 2>&1 || true
    install -m 0755 "$backup/stalwart.bin" "$binary"
    systemctl start stalwart >/dev/null 2>&1 || true
    rm -rf "$tmp"
    fatal "Stalwart update failed and the previous binary was restored."
  fi

  sleep 3
  local after
  after=$(stalwart_current_version)
  if [[ "$after" != "$latest" ]]; then
    warn "Stalwart restarted, but detected version is ${after}; expected ${latest}."
  else
    ok "Stalwart updated successfully: ${current} -> ${after}"
  fi
  rm -rf "$tmp"
}

update_stalwart_cli() {
  stage "Update Stalwart CLI"
  local current latest script found backup
  current=$(stalwart_cli_current_version)
  latest=$(github_latest_version stalwartlabs/cli) || fatal "Could not query latest Stalwart CLI release."
  info "Installed Stalwart CLI: ${current}"
  info "Latest Stalwart CLI:    ${latest}"
  if [[ "$current" != "unknown" && "$current" != "not-installed" ]] && ! version_is_newer "$latest" "$current"; then
    ok "Stalwart CLI is already current."
    return 0
  fi

  backup=$(backup_metadata_dir stalwart-cli)
  if command -v stalwart-cli >/dev/null 2>&1; then
    cp -a "$(command -v stalwart-cli)" "$backup/stalwart-cli.bin" 2>/dev/null || true
  fi
  script=$(mktemp)
  curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 \
    https://github.com/stalwartlabs/cli/releases/latest/download/stalwart-cli-installer.sh -o "$script"
  sh "$script"
  rm -f "$script"

  if ! command -v stalwart-cli >/dev/null 2>&1; then
    found=$(find /root -type f -name stalwart-cli -perm -u+x 2>/dev/null | head -n1 || true)
    [[ -n "$found" ]] && ln -sfn "$found" /usr/local/bin/stalwart-cli
  fi
  command -v stalwart-cli >/dev/null 2>&1 || fatal "Stalwart CLI update completed but the binary was not found."
  ok "Stalwart CLI is now $(stalwart_cli_current_version)."
}

wait_bulwark_health() {
  local i
  for i in $(seq 1 45); do
    if curl -fsS --connect-timeout 3 http://127.0.0.1:3000/api/health >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

ensure_bulwark_compose_image_variable() {
  local compose=/opt/bulwark-docker/compose.yml
  [[ -f "$compose" ]] || return 0
  if grep -qE '^[[:space:]]*image:[[:space:]]+ghcr\.io/bulwarkmail/webmail:latest[[:space:]]*$' "$compose"; then
    sed -i 's#^\([[:space:]]*image:[[:space:]]*\)ghcr.io/bulwarkmail/webmail:latest[[:space:]]*$#\1"${BULWARK_IMAGE:-ghcr.io/bulwarkmail/webmail:latest}"#' "$compose"
  fi
}

update_bulwark_docker() {
  local current latest backup old_image rollback_tag compose_dir=/opt/bulwark-docker
  current=$(bulwark_current_version)
  latest=$(github_latest_version bulwarkmail/webmail) || fatal "Could not query latest Bulwark release."
  info "Installed Bulwark: ${current}"
  info "Latest Bulwark:    ${latest}"
  if [[ "$current" != "unknown" ]] && ! version_is_newer "$latest" "$current"; then
    ok "Bulwark is already current."
    return 0
  fi

  [[ -f "$compose_dir/compose.yml" ]] || fatal "Bulwark compose file is missing: $compose_dir/compose.yml"
  backup=$(backup_metadata_dir bulwark-docker)
  cp -a "$compose_dir/compose.yml" "$backup/compose.yml"
  [[ -f "$compose_dir/.env" ]] && cp -a "$compose_dir/.env" "$backup/.env" || true
  old_image=$(docker inspect -f '{{.Image}}' bulwark 2>/dev/null || true)
  if [[ -n "$old_image" ]]; then
    rollback_tag="katebsaber/bulwark-rollback:$(date +%Y%m%d%H%M%S)"
    docker tag "$old_image" "$rollback_tag"
    printf '%s\n' "$rollback_tag" >"$backup/rollback-image.txt"
  fi

  ensure_bulwark_compose_image_variable
  rm -f "$compose_dir/.env"
  (cd "$compose_dir" && docker compose pull bulwark && docker compose up -d --force-recreate bulwark)

  if ! wait_bulwark_health; then
    err "Updated Bulwark failed health check; rolling back."
    if [[ -n "${rollback_tag:-}" ]]; then
      printf 'BULWARK_IMAGE=%s\n' "$rollback_tag" >"$compose_dir/.env"
      (cd "$compose_dir" && docker compose up -d --force-recreate bulwark) || true
      wait_bulwark_health || true
    fi
    fatal "Bulwark update failed. A rollback was attempted; backup is at $backup"
  fi

  rm -f "$compose_dir/.env"
  ok "Bulwark updated successfully. Current version: $(bulwark_current_version)"
}

update_bulwark_native() {
  local current latest old_commit backup
  current=$(bulwark_current_version)
  latest=$(github_latest_version bulwarkmail/webmail) || fatal "Could not query latest Bulwark release."
  info "Installed Bulwark: ${current}"
  info "Latest Bulwark:    ${latest}"
  if [[ "$current" != "unknown" ]] && ! version_is_newer "$latest" "$current"; then
    ok "Bulwark is already current."
    return 0
  fi

  [[ -d /opt/bulwark/.git ]] || fatal "Native Bulwark Git checkout was not found."
  backup=$(backup_metadata_dir bulwark-native)
  old_commit=$(git -C /opt/bulwark rev-parse HEAD)
  printf '%s\n' "$old_commit" >"$backup/commit.txt"
  cp -a /etc/bulwark "$backup/etc-bulwark" 2>/dev/null || true

  systemctl stop bulwark
  git -C /opt/bulwark fetch --tags --force origin
  if git -C /opt/bulwark rev-parse "v${latest}^{commit}" >/dev/null 2>&1; then
    git -C /opt/bulwark checkout --detach "v${latest}"
  elif git -C /opt/bulwark rev-parse "${latest}^{commit}" >/dev/null 2>&1; then
    git -C /opt/bulwark checkout --detach "${latest}"
  else
    git -C /opt/bulwark reset --hard origin/HEAD
  fi

  cd /opt/bulwark
  if [[ -f package-lock.json ]]; then npm ci; else npm install; fi
  npm run build
  chown -R bulwark:bulwark /opt/bulwark
  systemctl start bulwark

  if ! wait_bulwark_health; then
    err "Updated native Bulwark failed health check; rolling back source commit."
    systemctl stop bulwark >/dev/null 2>&1 || true
    git -C /opt/bulwark checkout --detach "$old_commit" || true
    cd /opt/bulwark
    if [[ -f package-lock.json ]]; then npm ci || true; else npm install || true; fi
    npm run build || true
    chown -R bulwark:bulwark /opt/bulwark || true
    systemctl start bulwark >/dev/null 2>&1 || true
    fatal "Bulwark update failed; previous commit was restored."
  fi
  ok "Bulwark updated successfully. Current version: $(bulwark_current_version)"
}

update_bulwark() {
  stage "Update Bulwark"
  case "${BULWARK_MODE:-unknown}" in
    docker) update_bulwark_docker ;;
    native) update_bulwark_native ;;
    *) fatal "Cannot determine how Bulwark is deployed." ;;
  esac
}

update_system_components() {
  stage "Update Docker / Nginx / Certbot packages"
  export DEBIAN_FRONTEND=noninteractive
  apt_update_resilient

  local packages=() pkg
  for pkg in docker.io docker-compose-v2 docker-ce docker-ce-cli containerd.io nginx certbot python3-certbot-nginx; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      packages+=("$pkg")
    fi
  done

  if ((${#packages[@]})); then
    apt-get install -y --only-upgrade "${packages[@]}"
  else
    warn "No managed Docker/Nginx/Certbot packages were detected by dpkg."
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart nginx >/dev/null 2>&1 || true
  systemctl restart docker >/dev/null 2>&1 || true
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  ok "System components update pass completed."
}

update_all_safe() {
  stage "Update all mail stack components"
  local failed=0
  update_stalwart || failed=$((failed+1))
  update_stalwart_cli || failed=$((failed+1))
  update_bulwark || failed=$((failed+1))
  update_system_components || failed=$((failed+1))
  load_managed_state
  manager_health_check || failed=$((failed+1))
  if (( failed == 0 )); then
    ok "All safe update operations completed successfully."
  else
    warn "Update-all completed with ${failed} skipped/failed operation(s). Review the messages above."
    return 1
  fi
}

repair_managed_stack() {
  stage "Reconcile managed configuration"
  warn "This reapplies the managed listeners, DNS automation, Nginx config and certificate wiring without deleting mail data."
  confirm "Continue with repair/reconcile?" N || return 0

  install_base_packages
  ensure_cloudflare_token
  cloudflare_find_zone
  cloudflare_bootstrap_dns
  validate_bootstrap_dns
  install_stalwart_cli
  prepare_stalwart_recovery_mode
  apply_stalwart_declarative_config
  configure_stalwart_listeners
  issue_tls_certificate
  configure_stalwart_certificate_in_recovery
  create_certbot_deploy_hook
  write_final_nginx_config
  exit_stalwart_recovery_mode
  validate_stalwart_admin
  install_bulwark
  nginx -t >/dev/null && systemctl reload nginx
  fetch_stalwart_dns_zone
  validate_mail_ports
  manager_health_check
  ok "Managed configuration reconciliation completed."
}

show_recent_manager_log() {
  stage "Recent installer/manager log"
  tail -n 120 "$LOG_FILE" 2>/dev/null || true
}

manager_menu() {
  load_managed_state

  if [[ "$MANAGER_ACTION" == "status" ]]; then
    print_component_versions
    manager_health_check || true
    return 0
  elif [[ "$MANAGER_ACTION" == "update-all" ]]; then
    update_all_safe
    return $?
  elif [[ "$MANAGER_ACTION" == "list-domains" ]]; then
    multi_domain_preflight && manager_list_domains
    return $?
  elif [[ "$MANAGER_ACTION" == "add-domain" ]]; then
    manager_add_domain
    return $?
  elif [[ "$MANAGER_ACTION" == "remove-domain" ]]; then
    manager_remove_domain
    return $?
  elif [[ -n "$MANAGER_ACTION" ]]; then
    case "$MANAGER_ACTION" in
      domain-health) manager_domain_health ;;
      accounts) manager_accounts ;;
      queue) manager_queue_overview ;;
      backup-now) manager_backup_now ;;
      verify-backup) manager_verify_backup "$BACKUP_PATH" ;;
      restore-backup) manager_restore_backup "$BACKUP_PATH" ;;
      backup-timer) manager_backup_timer ;;
      alerts) manager_alert_config ;;
      alert-check) manager_alert_check ;;
      migration-plan|dns-preview) manager_domain_preview ;;
      test-mail) manager_test_smtp ;;
      security-review) manager_security_review ;;
      rotate-cf-token) manager_rotate_cf_token ;;
      cancel-retirement) manager_cancel_retirement ;;
      advanced-dns) manager_dns_advanced_review ;;
      virtual-mail) vm_menu ;;
      virtual-mail-reconcile) vm_reconcile_all ;;
      *) err "Unsupported manager action: $MANAGER_ACTION"; return 2 ;;
    esac
    return $?
  fi

  while true; do
    banner
    printf '%b\n' "${GREEN}${BOLD}Existing managed mail stack detected.${RESET}"
    printf '  Domain:          %s\n' "$DOMAIN"
    printf '  Stalwart Admin:  https://%s/admin\n' "$MAIL_HOST"
    printf '  Bulwark:         https://%s\n' "$WEBMAIL_HOST"
    printf '  Stalwart:        %s\n' "$(service_state_word stalwart)"
    printf '  Nginx:           %s\n' "$(service_state_word nginx)"
    printf '  Bulwark mode:    %s\n' "$BULWARK_MODE"
    printf '  Stalwart ver:    %s\n' "$(stalwart_current_version)"
    printf '  Stalwart CLI:    %s\n' "$(stalwart_cli_current_version)"
    printf '  Bulwark ver:     %s\n' "$(bulwark_current_version)"
    echo
    printf '%b\n' "${WHITE}${BOLD}Mail Stack Manager${RESET}"
    cat <<'MENU'
  1) Show installed + latest versions
  2) Show URLs and login credentials
  3) Health check
  4) Update Stalwart
  5) Update Stalwart CLI
  6) Update Bulwark
  7) Update Docker / Nginx / Certbot packages
  8) Update everything safely
  9) Repair / reconcile configuration, DNS and listeners
 10) Show current install log
 11) Run/resume full provisioning workflow
 12) Show all mail domains
 13) Add another mail domain (Cloudflare + Stalwart)
 14) Retire/remove a secondary domain (7-day safety window)
 15) Full per-domain DNS / Cloudflare health
 16) Mail account listing, mailbox creation, aliases
 17) Outbound email queue (read-only)
 18) Encrypted cold backup of ALL local mail data + credentials
 19) Verify an encrypted backup
 20) Restore encrypted backup (explicit disaster recovery)
 21) Install scheduled backup and health/alert timers
 22) Configure Telegram alerts
 23) Read-only migration/DNS cutover preview
 24) Authenticated SMTP send test
 25) Security / TLS / firewall / secrets review
 26) Rotate a primary or secondary Cloudflare token
 27) Cancel pending secondary-domain retirement
 28) Read-only DNS setup preview
 29) Advanced DNS policies (MTA-STS/TLS-RPT/autoconfig)
 30) Virtual Mail (Cloudflare Email Routing — separate manager)
  0) Exit
MENU
    echo
    local choice
    read -r -p "Choose [0-30]: " choice
    case "$choice" in
      1) print_component_versions; pause "Press Enter to return to the manager..." ;;
      2) show_access_information; pause "Press Enter to return to the manager..." ;;
      3) manager_health_check || true; pause "Press Enter to return to the manager..." ;;
      4) update_stalwart || true; pause "Press Enter to return to the manager..." ;;
      5) update_stalwart_cli || true; pause "Press Enter to return to the manager..." ;;
      6) update_bulwark || true; pause "Press Enter to return to the manager..." ;;
      7) update_system_components || true; pause "Press Enter to return to the manager..." ;;
      8) update_all_safe || true; pause "Press Enter to return to the manager..." ;;
      9) repair_managed_stack || true; load_managed_state; pause "Press Enter to return to the manager..." ;;
      10) show_recent_manager_log; pause "Press Enter to return to the manager..." ;;
      11) FORCE_INSTALL=1; return 10 ;;
      12) multi_domain_preflight && manager_list_domains || true; pause "Press Enter to return to the manager..." ;;
      13) manager_add_domain || true; pause "Press Enter to return to the manager..." ;;
      14) manager_remove_domain || true; pause "Press Enter to return to the manager..." ;;
      15) manager_domain_health || true; pause "Press Enter to return to the manager..." ;;
      16) manager_accounts || true; pause "Press Enter to return to the manager..." ;;
      17) manager_queue_overview || true; pause "Press Enter to return to the manager..." ;;
      18) manager_backup_now || true; pause "Press Enter to return to the manager..." ;;
      19) local backup_pick; read -r -p "Backup archive absolute path: " backup_pick; manager_verify_backup "$backup_pick" || true; pause "Press Enter..." ;;
      20) local restore_pick; read -r -p "Backup archive absolute path: " restore_pick; manager_restore_backup "$restore_pick" || true; pause "Press Enter..." ;;
      21) manager_backup_timer || true; pause "Press Enter to return to the manager..." ;;
      22) manager_alert_config || true; pause "Press Enter to return to the manager..." ;;
      23) manager_domain_preview || true; pause "Press Enter to return to the manager..." ;;
      24) manager_test_smtp || true; pause "Press Enter to return to the manager..." ;;
      25) manager_security_review || true; pause "Press Enter to return to the manager..." ;;
      26) manager_rotate_cf_token || true; pause "Press Enter to return to the manager..." ;;
      27) manager_cancel_retirement || true; pause "Press Enter to return to the manager..." ;;
      28) manager_domain_preview || true; pause "Press Enter to return to the manager..." ;;
      29) manager_dns_advanced_review || true; pause "Press Enter to return to the manager..." ;;
      30) vm_menu || true ;;
      0|q|Q) return 0 ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

main() {
  parse_args "$@"
  banner
  script_identity
  require_root
  validate_ubuntu

  # Manager-only commands must NEVER fall into installation when existing
  # state is missing (especially the unattended Virtual Mail timer).
  if [[ -n "$MANAGER_ACTION" ]] && ! managed_stack_exists; then
    err "Managed MailStack installation not found. Refusing to provision from a manager-only command."
    exit 1
  fi
  if managed_stack_exists && (( FORCE_INSTALL == 0 )); then
    if manager_menu; then
      exit 0
    else
      local manager_rc=$?
      if [[ "$manager_rc" -ne 10 ]]; then
        exit "$manager_rc"
      fi
      info "Continuing into full provisioning workflow from manager option 11."
    fi
  fi

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

# ==============================================================================
# Virtual Mail v5 — independent Cloudflare Email Routing manager
# All API resources and state are separated from Stalwart and the existing CF
# DNS integration. Only explicit user actions mutate Cloudflare Email Routing.
# https://developers.cloudflare.com/api/resources/email_routing/
# ==============================================================================
VIRTUAL_MAIL_HOME="${STATE_DIR}/virtual-mail"
VIRTUAL_MAIL_ZONES="${VIRTUAL_MAIL_HOME}/zones"
VIRTUAL_MAIL_TOKENS="${VIRTUAL_MAIL_HOME}/tokens"
VIRTUAL_MAIL_PENDING="${VIRTUAL_MAIL_HOME}/pending"
VIRTUAL_MAIL_ARCHIVE="${VIRTUAL_MAIL_HOME}/archive"
VIRTUAL_MAIL_LOCK="${VIRTUAL_MAIL_HOME}/lock"
VIRTUAL_MAIL_MANAGER="/usr/local/sbin/katebsaber-mailstack-virtual-mail"
VIRTUAL_MAIL_TOKEN_LINK="https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%2C%7B%22key%22%3A%22dns%22%2C%22type%22%3A%22read%22%7D%2C%7B%22key%22%3A%22zone_settings%22%2C%22type%22%3A%22edit%22%7D%5D&accountId=%2A&zoneId=all&name=MailStack%20Virtual%20Mail"

vm_init() {
  command -v jq >/dev/null && command -v curl >/dev/null && command -v flock >/dev/null || {
    err "Virtual Mail requires curl, jq and flock."; return 1;
  }
  install -d -m 0700 "$VIRTUAL_MAIL_HOME" "$VIRTUAL_MAIL_ZONES" "$VIRTUAL_MAIL_TOKENS" "$VIRTUAL_MAIL_PENDING" "$VIRTUAL_MAIL_ARCHIVE"
  chmod 0700 "$VIRTUAL_MAIL_HOME" "$VIRTUAL_MAIL_ZONES" "$VIRTUAL_MAIL_TOKENS" "$VIRTUAL_MAIL_PENDING" "$VIRTUAL_MAIL_ARCHIVE"
}
vm_safe_name() { valid_domain "$1" && [[ "$1" == "${1,,}" ]]; }
vm_email_valid() {
  local e="$1" user domain
  [[ "$e" != *$'\n'* && "$e" != *$'\r'* && "${#e}" -le 90 ]] || return 1
  valid_email "$e" || return 1
  user="${e%@*}"; domain="${e##*@}"
  [[ "$user" =~ ^[a-zA-Z0-9_+.-]+$ ]] && vm_safe_name "$domain"
}
vm_zone_path() { printf '%s/%s.json' "$VIRTUAL_MAIL_ZONES" "$1"; }
vm_token_path() { printf '%s/%s.token' "$VIRTUAL_MAIL_TOKENS" "$1"; }
vm_pending_path() {
  local sha
  sha=$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)
  printf '%s/%s/%s.json' "$VIRTUAL_MAIL_PENDING" "$1" "$sha"
}
vm_write_atomic() {
  local destination="$1" payload="$2" tmp
  tmp=$(mktemp "${destination}.XXXXXX") || return 1
  printf '%s\n' "$payload" >"$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$destination" || {
    rm -f "$tmp"; return 1;
  }
}
# Credentials intentionally stay in /root/mailstack-secrets.txt, per user
# requirement. The dedicated state files are also root-only. Never echo tokens.
vm_record_token() {
  local zone="$1" token="$2" kind="$3"
  touch "$SECRETS_FILE" && chmod 0600 "$SECRETS_FILE" || return 1
  {
    printf '\nCloudflare Virtual Mail — %s (%s)\n' "$zone" "$kind"
    printf 'Recorded: %s\n' "$(date -Is)"
    printf 'Token: %s\n' "$token"
    printf 'Token file: %s\n' "$(vm_token_path "$zone")"
  } >>"$SECRETS_FILE"
  chmod 0600 "$SECRETS_FILE"
}
vm_guard_stalwart() {
  local zone="$1" state name
  if [[ "$zone" == "${DOMAIN:-}" ]]; then
    err "Refusing Virtual Mail on the main Stalwart mail domain ($zone)."; return 1
  fi
  for state in "$EXTRA_DOMAINS_DIR"/*.json; do
    [[ -f "$state" ]] || continue
    name=$(jq -r '.domain // .name // empty' "$state" 2>/dev/null || true)
    [[ -n "$name" ]] || name=$(basename "$state" .json)
    if [[ "$zone" == "$name" ]]; then
      err "Domain $zone is managed by Stalwart; no Cloudflare Email Routing changes allowed."
      return 1
    fi
  done
  return 0
}
# Distinct token variable (VM_TOKEN) never alters the normal CF_API_TOKEN.
# No retry on writes to avoid duplicate rules after an uncertain timeout.
vm_api() {
  local method="$1" endpoint="$2" body="${3:-}" response code status args=()
  [[ "${VM_TOKEN:-}" =~ ^[A-Za-z0-9._-]+$ ]] || { err "Invalid Virtual Mail token."; return 1; }
  local vm_endpoint_pattern='^/[a-zA-Z0-9/_?=&.%-]+$'
  [[ "$endpoint" =~ $vm_endpoint_pattern && "$endpoint" != *'..'* ]] || {
    err "Unsafe Cloudflare API path."; return 1;
  }
  args=(--silent --show-error --connect-timeout 8 --max-time 35 --request "$method" --header 'Content-Type: application/json' --config -)
  [[ "$method" == GET ]] && args+=(--retry 2 --retry-delay 2 --retry-max-time 80)
  if [[ -n "$body" ]]; then
    args+=(--data-binary "$body")
  fi
  # Token is passed on stdin, never in process argv or verbose logs.
  if ! response=$(curl "${args[@]}" "${CLOUDFLARE_API}${endpoint}" \
      <<<"header = \"Authorization: Bearer ${VM_TOKEN}\""); then
    err "Cloudflare transport failure ($method $endpoint)."; return 1
  fi
  if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$response"; then
    jq -r '.errors[]? | "Cloudflare error \(.code): \(.message)"' <<<"$response" >&2 || true
    err "Cloudflare API request failed: $method $endpoint"
    return 1
  fi
  printf '%s\n' "$response"
}
vm_load_zone() {
  local zone="$1" file tokenfile
  vm_safe_name "$zone" || { err "Invalid zone name."; return 1; }
  file=$(vm_zone_path "$zone"); tokenfile=$(vm_token_path "$zone")
  [[ -s "$file" && -s "$tokenfile" ]] || { err "Virtual Mail zone not configured: $zone"; return 1; }
  VM_ZONE="$zone"
  VM_ZONE_ID=$(jq -r '.zone_id // empty' "$file")
  VM_ACCOUNT_ID=$(jq -r '.account_id // empty' "$file")
  [[ "$VM_ZONE_ID" =~ ^[a-fA-F0-9]{32}$ && "$VM_ACCOUNT_ID" =~ ^[a-fA-F0-9]{32}$ ]] || {
    err "Invalid Virtual Mail state file for $zone."; return 1;
  }
  VM_TOKEN=$(<"$tokenfile")
  [[ "$VM_TOKEN" =~ ^[A-Za-z0-9._-]+$ ]] || { err "Invalid saved token."; return 1; }
}
vm_select_zone() {
  local names=() file index picked
  for file in "$VIRTUAL_MAIL_ZONES"/*.json; do
    [[ -s "$file" ]] || continue
    names+=("$(basename "$file" .json)")
  done
  (( ${#names[@]} )) || { warn "No Virtual Mail domains. Connect a zone first."; return 1; }
  echo "Virtual Mail domains:"
  for index in "${!names[@]}"; do printf '  %d) %s\n' "$((index+1))" "${names[$index]}"; done
  read -r -p 'Choose domain number: ' picked || return 1
  [[ "$picked" =~ ^[0-9]+$ ]] && (( picked>=1 && picked<=${#names[@]} )) || {
    err "Invalid domain selection."; return 1;
  }
  vm_load_zone "${names[$((picked-1))]}"
}
vm_list_api() {
  local endpoint="$1" page=1 total=1 response all='[]' entries
  while (( page <= total && page <= 100 )); do
    response=$(vm_api GET "${endpoint}?page=${page}&per_page=50") || return 1
    entries=$(jq -c '.result // []' <<<"$response") || return 1
    [[ "$(jq -r 'type' <<<"$entries")" == array ]] || return 1
    all=$(jq -cn --argjson a "$all" --argjson b "$entries" '$a+$b') || return 1
    total=$(jq -r '.result_info.total_pages // 1' <<<"$response")
    [[ "$total" =~ ^[0-9]+$ && "$total" -le 100 ]] || { err "Pagination exceeded safety limit."; return 1; }
    page=$((page+1))
  done
  printf '%s\n' "$all"
}
vm_rules() { vm_list_api "/zones/${VM_ZONE_ID}/email/routing/rules"; }
vm_destinations() { vm_list_api "/accounts/${VM_ACCOUNT_ID}/email/routing/addresses"; }
vm_routing_info() { vm_api GET "/zones/${VM_ZONE_ID}/email/routing"; }
vm_dns_mx() { vm_list_api "/zones/${VM_ZONE_ID}/dns_records"; }
# For DNS API: avoid fetching unrelated record types when checking MXs.
vm_existing_mx() {
  local response
  response=$(vm_api GET "/zones/${VM_ZONE_ID}/dns_records?type=MX&name=${VM_ZONE}&per_page=100") || return 1
  [[ "$(jq -r '.result_info.total_pages // 1' <<<"$response")" == 1 ]] &&
  [[ "$(jq -r '.result | type' <<<"$response")" == array ]] || {
    err 'MX record list is incomplete. Refusing to activate.'; return 1;
  }
  jq -c --arg zone "$VM_ZONE" '[.result[]? | select((.name|ascii_downcase)==$zone)]' <<<"$response"
}
vm_routing_ready() {
  local r
  r=$(vm_routing_info) || return 1
  [[ "$(jq -r '.result.enabled // false' <<<"$r")" == true ]] || {
    err "Cloudflare Email Routing is not enabled for $VM_ZONE."; return 1;
  }
}
vm_connect() {
  local zone token verify zones zoneid accountid z state tmp previous
  echo
  printf 'Create a restricted Cloudflare API token: %s\n' "$VIRTUAL_MAIL_TOKEN_LINK"
  cat <<'INSTRUCTIONS'
  Open the link above (USER API token, not Global API key).
  The link pre-fills Zone Read, DNS Read and Zone Settings Edit.
  IMPORTANT: add the TWO Email Routing permissions manually below.
  Permissions (final required list):
    Zone -> Zone -> Read
    Zone -> DNS -> Read
    Zone -> Zone Settings -> Edit
    Zone -> Email Routing Rules -> Edit
    Account -> Email Routing Addresses -> Edit
  Resources: Include the specific Cloudflare zone AND its account.
  Select the zone containing the forwarding domain, e.g. example.com.
  Destination addresses are account-wide; only use your own verified inbox.
INSTRUCTIONS
  read -r -p 'Cloudflare domain/zone (e.g. example.com): ' zone || return 1
  zone=$(normalize_domain "$zone")
  vm_safe_name "$zone" || { err "Invalid zone name."; return 1; }
  vm_guard_stalwart "$zone" || return 1
  if [[ -s "$(vm_token_path "$zone")" ]]; then
    info "Already connected: $zone. Use Rotate token to change its credentials."
    vm_load_zone "$zone" || return 1
  else
    read -r -s -p 'Paste the new Cloudflare API Token: ' token || { echo; return 1; }
    echo
    [[ "$token" =~ ^[A-Za-z0-9._-]+$ ]] || { err "Invalid token format."; return 1; }
    VM_TOKEN="$token"
    verify=$(vm_api GET '/user/tokens/verify') || return 1
    [[ "$(jq -r '.result.status // ""' <<<"$verify")" == active ]] || {
      err "Cloudflare token is not active."; return 1;
    }
    zones=$(vm_api GET "/zones?name=${zone}&status=active&per_page=50") || return 1
    [[ "$(jq -r '.result|length' <<<"$zones")" == 1 ]] || {
      err "Zone unavailable. Check Zone -> Read and zone scope."; return 1;
    }
    zoneid=$(jq -r '.result[0].id // empty' <<<"$zones")
    accountid=$(jq -r '.result[0].account.id // empty' <<<"$zones")
    [[ "$zoneid" =~ ^[a-fA-F0-9]{32}$ && "$accountid" =~ ^[a-fA-F0-9]{32}$ ]] || {
      err "Cloudflare did not provide valid zone/account IDs."; return 1;
    }
    VM_ZONE="$zone"; VM_ZONE_ID="$zoneid"; VM_ACCOUNT_ID="$accountid"
    # Fail before storing credentials when permissions cannot list addresses/rules.
    vm_destinations >/dev/null || { err 'Missing destination-address permission.'; return 1; }
    vm_rules >/dev/null || { err 'Missing routing-rules permission.'; return 1; }
    vm_routing_info >/dev/null || { err 'Missing zone-settings permission.'; return 1; }
    vm_existing_mx >/dev/null || { err 'Missing DNS-read permission.'; return 1; }
    state=$(jq -n --arg zone "$zone" --arg id "$zoneid" --arg acc "$accountid" --arg date "$(date -Is)" '{zone:$zone,zone_id:$id,account_id:$acc,created_at:$date}')
    vm_write_atomic "$(vm_token_path "$zone")" "$token" || return 1
    vm_write_atomic "$(vm_zone_path "$zone")" "$state" || return 1
    vm_record_token "$zone" "$token" 'initial setup' || return 1
    ok "Zone connected and credentials stored privately."
  fi
  vm_activate_routing
}
vm_activate_routing() {
  local setting mx payload result
  vm_guard_stalwart "$VM_ZONE" || return 1
  setting=$(vm_routing_info) || return 1
  if [[ "$(jq -r '.result.enabled // false' <<<"$setting")" == true ]]; then
    ok "Email Routing is already enabled for $VM_ZONE; existing MX stays untouched."
    return 0
  fi
  mx=$(vm_existing_mx) || return 1
  if [[ "$(jq 'length' <<<"$mx")" != 0 ]]; then
    err "Existing MX records detected on $VM_ZONE. Refusing to replace a working mail provider."
    jq -r '.[] | "  MX \(.name) -> \(.content) priority=\(.priority)"' <<<"$mx"
    return 1
  fi
  warn "Cloudflare will CREATE/LOCK MX and mail-authentication DNS records for $VM_ZONE."
  warn 'DNS and Stalwart on all other domains are NOT changed.'
  confirm "Enable Cloudflare Email Routing on $VM_ZONE?" N || return 1
  payload=$(jq -nc --arg name "$VM_ZONE" '{name:$name}')
  vm_api POST "/zones/${VM_ZONE_ID}/email/routing/dns" "$payload" >/dev/null || return 1
  if vm_routing_ready; then
    ok "Email Routing enabled; MX/DNS are managed by Cloudflare."
  else
    warn "Activation accepted but routing is not ready; inspect DNS and Cloudflare status."
    return 1
  fi
}
vm_print_destinations() {
  local ds
  ds=$(vm_destinations) || return 1
  echo "Destination addresses (shared across this Cloudflare account):"
  jq -r '.[] | "  \(.email) — " + (if (.verified // null)!=null and .verified!=false then "VERIFIED" else "PENDING VERIFICATION" end)' <<<"$ds"
}
vm_destination_exists() {
  local ds="$1" email="$2"
  jq -c --arg e "$email" '[.[] | select((.email|ascii_downcase)==$e)] | first // empty' <<<"$ds"
}
vm_confirm_destination() {
  local target="$1" ds found payload
  ds=$(vm_destinations) || return 2
  found=$(vm_destination_exists "$ds" "$target") || return 2
  if [[ -z "$found" ]]; then
    payload=$(jq -nc --arg email "$target" '{email:$email}')
    vm_api POST "/accounts/${VM_ACCOUNT_ID}/email/routing/addresses" "$payload" >/dev/null || return 2
    info "Cloudflare sent a verification email to $target. Open that inbox and verify."
    ds=$(vm_destinations) || return 2
    found=$(vm_destination_exists "$ds" "$target") || { err "Destination not returned by API."; return 2; }
  fi
  [[ -n "$found" ]] || { err "Destination not visible after creation."; return 2; }
  jq -e '(.verified | type)=="string" and (.verified | length)>0' >/dev/null <<<"$found"
}
vm_matching_rules() {
  local email="$1" rules
  rules=$(vm_rules) || return 1
  jq -c --arg email "$email" '[.[] | select(any(.matchers[]?; .type=="literal" and .field=="to" and (.value|ascii_downcase)==$email))]' <<<"$rules"
}
vm_pending_save() {
  local src="$1" dst="$2" path payload
  install -d -m 0700 "$VIRTUAL_MAIL_PENDING/$VM_ZONE"
  path=$(vm_pending_path "$VM_ZONE" "$src")
  payload=$(jq -nc --arg source "$src" --arg dest "$dst" --arg at "$(date -Is)" '{source:$source,destination:$dest,requested_at:$at}')
  vm_write_atomic "$path" "$payload" || return 1
  # Resume pending forwards automatically once Cloudflare destination is verified.
  # Systemd is intentionally isolated from Stalwart/backup timers.
  vm_install_reconcile_timer || warn 'Auto-reconciliation timer unavailable; use Complete pending forwarding from this menu.'
}
vm_pending_archive() {
  local source="$1" file
  file=$(vm_pending_path "$VM_ZONE" "$source")
  [[ -f "$file" ]] || return 0
  install -d -m 0700 "$VIRTUAL_MAIL_ARCHIVE/pending"
  mv -f "$file" "$VIRTUAL_MAIL_ARCHIVE/pending/$(date +%Y%m%d%H%M%S%N)-${VM_ZONE}-$(basename "$file")"
}
vm_create_rule_if_ready() {
  local source="$1" target="$2" matches ds found payload response
  vm_email_valid "$source" && vm_email_valid "$target" || return 1
  [[ "${source##*@}" == "$VM_ZONE" ]] || { err "The source address does not belong to $VM_ZONE"; return 1; }
  vm_guard_stalwart "$VM_ZONE" || return 1
  vm_routing_ready || return 1
  matches=$(vm_matching_rules "$source") || return 1
  if (( $(jq 'length' <<<"$matches") > 0 )); then
    if [[ "$(jq -r --arg dst "$target" 'length == 1 and .[0].actions == [{"type":"forward","value":[$dst]}] and .[0].enabled == true' <<<"$matches")" == true ]]; then
      vm_pending_archive "$source"
      ok "Forward already exists: $source -> $target"
      return 0
    fi
    err "A routing rule already exists for $source. Use Change destination, not Add."
    return 1
  fi
  ds=$(vm_destinations) || return 2
  found=$(vm_destination_exists "$ds" "$target") || return 2
  if [[ -z "$found" ]] || ! jq -e '(.verified | type)=="string" and (.verified | length)>0' >/dev/null <<<"$found"; then
    warn "Destination $target is not verified yet. Keeping the request pending."
    # A timed reconciliation must not rewrite state or reinstall its own
    # systemd unit on every poll; only the initial request installs the timer.
    [[ -s "$(vm_pending_path "$VM_ZONE" "$source")" ]] || vm_pending_save "$source" "$target" || return 1
    return 0
  fi
  payload=$(jq -nc --arg src "$source" --arg dst "$target" \
    '{name:("MailStack Virtual Mail: "+$src),enabled:true,source:"api",matchers:[{type:"literal",field:"to",value:$src}],actions:[{type:"forward",value:[$dst]}]}')
  response=$(vm_api POST "/zones/${VM_ZONE_ID}/email/routing/rules" "$payload") || return 1
  [[ -n "$(jq -r '.result.id // empty' <<<"$response")" ]] || { err "Rule creation was not confirmed."; return 1; }
  vm_pending_archive "$source"
  ok "Active virtual email: $source -> $target"
}
vm_add_forward() {
  local src dst
  vm_select_zone || return 1
  read -r -p "Virtual address (name@${VM_ZONE}): " src || return 1
  src="${src,,}"
  vm_email_valid "$src" && [[ "${src##*@}" == "$VM_ZONE" ]] || { err 'Invalid virtual address or wrong zone.'; return 1; }
  read -r -p 'Destination inbox (e.g. you@gmail.com): ' dst || return 1
  dst="${dst,,}"
  vm_email_valid "$dst" || { err 'Invalid destination email.'; return 1; }
  [[ "$src" != "$dst" ]] || { err 'Forwarding address cannot point to itself.'; return 1; }
  vm_guard_stalwart "$VM_ZONE" || return 1
  vm_routing_ready || return 1
  local verification_rc
  if vm_confirm_destination "$dst"; then
    vm_create_rule_if_ready "$src" "$dst"
  else
    verification_rc=$?
    if (( verification_rc != 1 )); then
      err 'Destination API request failed. No pending request was saved.'; return 1
    fi
    vm_pending_save "$src" "$dst" || return 1
    warn 'Pending: verify destination from the Cloudflare email, then use Complete pending forwards.'
  fi
}
vm_complete_pending() {
  local file src dst found=0 errcount=0
  vm_select_zone || return 1
  for file in "$VIRTUAL_MAIL_PENDING/$VM_ZONE"/*.json; do
    [[ -f "$file" ]] || continue
    found=1
    src=$(jq -r '.source // empty' "$file")
    dst=$(jq -r '.destination // empty' "$file")
    echo "Checking: $src -> $dst"
    if ! vm_create_rule_if_ready "$src" "$dst"; then errcount=$((errcount+1)); fi
  done
  (( found )) || info 'No pending forwarding rules.'
  (( errcount == 0 ))
}
vm_show_forwards() {
  local rules file
  vm_select_zone || return 1
  echo "Active/inactive rules in Cloudflare for $VM_ZONE:"
  rules=$(vm_rules) || return 1
  jq -r '.[] | "  " + ([.matchers[]? | select(.field=="to") | .value] | join(",")) + " -> " + ([.actions[]? | .value[]?] | join(",")) + " [" + (if .enabled then "ON" else "OFF" end) + "] (" + (.id // "?") + ")"' <<<"$rules"
  echo 'Pending requests (destination must be verified):'
  for file in "$VIRTUAL_MAIL_PENDING/$VM_ZONE"/*.json; do
    [[ -f "$file" ]] || continue
    jq -r '"  \(.source) -> \(.destination) [PENDING]"' "$file"
  done
}
vm_remove_forward() {
  local source matches count id confirm_str
  vm_select_zone || return 1
  vm_guard_stalwart "$VM_ZONE" || return 1
  read -r -p "Virtual address to DELETE (name@${VM_ZONE}): " source || return 1
  source="${source,,}"
  vm_email_valid "$source" && [[ "${source##*@}" == "$VM_ZONE" ]] || return 1
  matches=$(vm_matching_rules "$source") || return 1
  count=$(jq 'length' <<<"$matches")
  if (( count == 0 )); then
    [[ -f "$(vm_pending_path "$VM_ZONE" "$source")" ]] || { warn 'No such rule/pending request.'; return 1; }
    read -r -p "Type DELETE $source to cancel pending request: " confirm_str || return 1
    [[ "$confirm_str" == "DELETE $source" ]] || return 1
    vm_pending_archive "$source"
    ok 'Pending request cancelled; destination is preserved.'
    return 0
  fi
  (( count == 1 )) || { err 'Duplicate matching rules; resolve conflicts in Cloudflare dashboard first.'; return 1; }
  id=$(jq -r '.[0].id // empty' <<<"$matches")
  [[ "$id" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || return 1
  read -r -p "Type DELETE $source to confirm: " confirm_str || return 1
  [[ "$confirm_str" == "DELETE $source" ]] || { warn 'Cancelled.'; return 1; }
  vm_api DELETE "/zones/${VM_ZONE_ID}/email/routing/rules/$id" >/dev/null || return 1
  vm_pending_archive "$source"
  ok "Forwarding rule removed; domain, tokens and destination inbox preserved."
}
vm_change_forward() {
  local source target rules matches id ds found payload
  vm_select_zone || return 1
  vm_guard_stalwart "$VM_ZONE" || return 1
  read -r -p 'Existing virtual address: ' source || return 1
  source="${source,,}"
  vm_email_valid "$source" && [[ "${source##*@}" == "$VM_ZONE" ]] || return 1
  matches=$(vm_matching_rules "$source") || return 1
  [[ "$(jq 'length' <<<"$matches")" == 1 ]] || { err 'Expected exactly one existing rule.'; return 1; }
  [[ "$(jq -r '.[0] | (.actions | length)==1 and (.matchers | length)==1 and .actions[0].type=="forward" and (.source // "api")!="wrangler"' <<<"$matches")" == true ]] || {
    err 'This rule uses a custom/Worker action or complex matcher; refusing to overwrite it.'; return 1;
  }
  read -r -p 'New destination inbox: ' target || return 1
  target="${target,,}"
  vm_email_valid "$target" || return 1
  if ! vm_confirm_destination "$target"; then
    warn 'Verify the new inbox first (or investigate an API error). Existing forward is unchanged.'
    return 0
  fi
  id=$(jq -r '.[0].id' <<<"$matches")
  [[ "$id" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || return 1
  payload=$(jq -c --arg to "$target" '.[0] | {name,enabled,source,priority,matchers,actions:[{type:"forward",value:[$to]}]} | with_entries(select(.value!=null))' <<<"$matches")
  confirm "Change $source forwarding to $target?" N || return 1
  vm_api PUT "/zones/${VM_ZONE_ID}/email/routing/rules/$id" "$payload" >/dev/null || return 1
  ok "Forward destination updated; old destination inbox and credentials preserved."
}
vm_catch_all() {
  local action dest info_now payload
  vm_select_zone || return 1
  vm_guard_stalwart "$VM_ZONE" || return 1
  info_now=$(vm_api GET "/zones/${VM_ZONE_ID}/email/routing/rules/catch_all") || return 1
  if [[ "$(jq -r '.result.source // "api"' <<<"$info_now")" == wrangler ]]; then
    err 'This catch-all is controlled by a Worker; refusing to overwrite it.'; return 1
  fi
  echo "Current catch-all: $(jq -r '.result | if .enabled then "ON -> " + ([.actions[]?.value[]?] | join(",")) else "OFF" end' <<<"$info_now")"
  echo '1) Set catch-all forwarding'
  echo '2) Disable catch-all'
  read -r -p 'Choice: ' action || return 1
  if [[ "$action" == 1 ]]; then
    read -r -p 'Verified destination: ' dest || return 1
    dest="${dest,,}"; vm_email_valid "$dest" || return 1
    if ! vm_confirm_destination "$dest"; then
      warn 'Verify the destination first. Catch-all remains unchanged.'; return 0
    fi
    warn 'Catch-all forwards mail to ANY unmatched name on this domain (including spam).'
    confirm "Enable catch-all -> $dest?" N || return 1
    payload=$(jq -nc --arg dst "$dest" '{name:"MailStack Virtual Mail catch-all",enabled:true,source:"api",matchers:[{type:"all"}],actions:[{type:"forward",value:[$dst]}]}')
  elif [[ "$action" == 2 ]]; then
    confirm 'Disable catch-all (other specific forwards remain)?' N || return 1
    payload=$(jq -nc '{name:"MailStack Virtual Mail catch-all",enabled:false,source:"api",matchers:[{type:"all"}],actions:[{type:"drop"}]}')
  else
    return 1
  fi
  vm_api PUT "/zones/${VM_ZONE_ID}/email/routing/rules/catch_all" "$payload" >/dev/null || return 1
  ok 'Catch-all setting updated.'
}
vm_rotate_token() {
  local zone newtoken verify z newzone account previous archived
  vm_select_zone || return 1
  zone="$VM_ZONE"
  printf 'Create a replacement token with the same permissions: %s\n' "$VIRTUAL_MAIL_TOKEN_LINK"
  read -r -s -p 'New Cloudflare token: ' newtoken || { echo; return 1; }
  echo
  [[ "$newtoken" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  VM_TOKEN="$newtoken"
  verify=$(vm_api GET '/user/tokens/verify') || return 1
  [[ "$(jq -r '.result.status // ""' <<<"$verify")" == active ]] || return 1
  z=$(vm_api GET "/zones?name=${zone}&status=active&per_page=50") || return 1
  newzone=$(jq -r '.result[0].id // empty' <<<"$z")
  account=$(jq -r '.result[0].account.id // empty' <<<"$z")
  [[ "$newzone" == "$VM_ZONE_ID" && "$account" == "$VM_ACCOUNT_ID" ]] || {
    err 'Replacement token points to a different zone or account.'; return 1;
  }
  vm_destinations >/dev/null && vm_rules >/dev/null && vm_routing_info >/dev/null && vm_existing_mx >/dev/null || {
    err 'Replacement token lacks one of the necessary permissions. Existing token preserved.'; return 1;
  }
  archived="$VIRTUAL_MAIL_ARCHIVE/$(date +%Y%m%d%H%M%S%N)-${zone}.token"
  cp -p "$(vm_token_path "$zone")" "$archived" || return 1
  vm_write_atomic "$(vm_token_path "$zone")" "$newtoken" || return 1
  vm_record_token "$zone" "$newtoken" 'rotation' || return 1
  ok "New token applied. Previous token securely archived at $archived."
}
vm_health() {
  local setting mx rules ds targets unverified
  vm_select_zone || return 1
  setting=$(vm_routing_info) || return 1
  printf 'Zone: %s | Enabled: %s | Status: %s\n' "$VM_ZONE" \
    "$(jq -r '.result.enabled // false' <<<"$setting")" \
    "$(jq -r '.result.status // "unknown"' <<<"$setting")"
  mx=$(vm_existing_mx) || return 1
  echo 'MX records in Cloudflare DNS:'
  jq -r '.[] | "  \(.content) (priority \(.priority))"' <<<"$mx"
  rules=$(vm_rules) || return 1
  ds=$(vm_destinations) || return 1
  printf 'Routing rules: %s | Destinations: %s\n' "$(jq 'length' <<<"$rules")" "$(jq 'length' <<<"$ds")"
  targets=$(jq -r '[.[] | select(.enabled==true) | .actions[]? | select(.type=="forward") | .value[]?] | unique[]' <<<"$rules")
  unverified=0
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    if ! jq -e --arg target "$t" 'any(.[]; .email==$target and (.verified | type)=="string" and (.verified | length)>0)' >/dev/null <<<"$ds"; then
      warn "Missing/unverified destination: $t"; unverified=$((unverified+1))
    fi
  done <<<"$targets"
  if [[ "$(jq -r '.result.enabled // false' <<<"$setting")" != true ]] || (( unverified )); then
    err 'Virtual Mail has outstanding health issues.'; return 1
  fi
  if ! jq -e 'any(.[]; (.content // "" | ascii_downcase | test("^route[0-9]+\\.mx\\.cloudflare\\.net\\.?$")))' >/dev/null <<<"$mx"; then
    warn 'No Cloudflare Email Routing MX record detected; verify DNS propagation.'; return 1
  fi
  ok 'Cloudflare routing configuration appears healthy; real external delivery is not tested.'
}
vm_disable_zone() {
  local rules catch active confirm_str
  vm_select_zone || return 1
  vm_guard_stalwart "$VM_ZONE" || return 1
  rules=$(vm_rules) || return 1
  active=$(jq '[.[] | select(.enabled==true)] | length' <<<"$rules")
  catch=$(vm_api GET "/zones/${VM_ZONE_ID}/email/routing/rules/catch_all") || return 1
  if (( active > 0 )) || [[ "$(jq -r '.result.enabled // false' <<<"$catch")" == true ]]; then
    err "Routing rules/catch-all are still enabled. Disable/delete them before disabling the zone."
    return 1
  fi
  warn "Disabling routing removes Cloudflare Email Routing DNS (MX) for $VM_ZONE."
  read -r -p "Type DISABLE $VM_ZONE to continue: " confirm_str || return 1
  [[ "$confirm_str" == "DISABLE $VM_ZONE" ]] || return 1
  vm_api DELETE "/zones/${VM_ZONE_ID}/email/routing/dns" >/dev/null || return 1
  ok 'Email Routing disabled. Saved tokens and account-level destinations were not deleted.'
}
vm_zone_summary() {
  local file zone state
  for file in "$VIRTUAL_MAIL_ZONES"/*.json; do
    [[ -f "$file" ]] || continue
    zone=$(basename "$file" .json)
    if vm_load_zone "$zone" && state=$(vm_routing_info 2>/dev/null); then
      printf '  %-35s Enabled=%s Status=%s\n' "$zone" "$(jq -r '.result.enabled' <<<"$state")" "$(jq -r '.result.status // "unknown"' <<<"$state")"
    else
      printf '  %-35s %s\n' "$zone" 'UNKNOWN / unavailable API'
    fi
  done
}

# Standalone service/timer; no Stalwart restart, DNS edits, nor token deletion.
vm_install_reconcile_timer() {
  local src unit timer
  command -v systemctl >/dev/null || return 1
  src=$(readlink -f "${BASH_SOURCE[0]}") || return 1
  [[ -f "$src" && -s "$src" ]] || return 1
  local staged
  staged=$(mktemp "${VIRTUAL_MAIL_MANAGER}.XXXXXXXX") || return 1
  if ! install -m 0700 "$src" "$staged" || ! mv -f "$staged" "$VIRTUAL_MAIL_MANAGER"; then
    rm -f "$staged"; return 1
  fi
  unit='/etc/systemd/system/katebsaber-mailstack-virtual-mail.service'
  timer='/etc/systemd/system/katebsaber-mailstack-virtual-mail.timer'
  cat > "$unit" <<EOF
[Unit]
Description=Reconcile verified Cloudflare Virtual Mail forwarding
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
User=root
ExecStart=$VIRTUAL_MAIL_MANAGER --virtual-mail-reconcile --non-interactive
NoNewPrivileges=true
PrivateTmp=true
EOF
  cat > "$timer" <<'EOF'
[Unit]
Description=Check pending Cloudflare Virtual Mail forwards every 10 minutes
[Timer]
OnBootSec=5min
OnUnitInactiveSec=10min
Persistent=true
Unit=katebsaber-mailstack-virtual-mail.service
[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$unit" "$timer"
  systemctl daemon-reload >/dev/null || return 1
  systemctl enable --now katebsaber-mailstack-virtual-mail.timer >/dev/null || return 1
  info 'Automatic pending-forward reconciliation enabled (every ~10 minutes).'
}
vm_reconcile_all() (
  vm_init || return 1
  exec 9>"$VIRTUAL_MAIL_LOCK"
  flock -n 9 || { info 'Virtual Mail is in an interactive management session; skipping this check.'; return 0; }
  local file zone pending src dst errors=0
  for file in "$VIRTUAL_MAIL_ZONES"/*.json; do
    [[ -s "$file" ]] || continue
    zone=$(basename "$file" .json)
    vm_load_zone "$zone" || { errors=$((errors+1)); continue; }
    for pending in "$VIRTUAL_MAIL_PENDING/$zone"/*.json; do
      [[ -s "$pending" ]] || continue
      src=$(jq -r '.source // empty' "$pending")
      dst=$(jq -r '.destination // empty' "$pending")
      if ! vm_create_rule_if_ready "$src" "$dst"; then
        warn "Cannot reconcile $src; retained pending state for retry."
        errors=$((errors+1))
      fi
    done
  done
  (( errors == 0 ))
)

vm_menu() (
  vm_init || return 1
  exec 9>"$VIRTUAL_MAIL_LOCK"
  flock -n 9 || { err 'Another Virtual Mail management session is active.'; return 1; }
  while true; do
    echo
    echo '=============== Virtual Mail (Cloudflare only) ==============='
    echo '  1) Connect domain + token; enable Cloudflare Email Routing'
    echo '  2) Show connected virtual domains and routing status'
    echo '  3) Add virtual email forward (source -> destination)'
    echo '  4) List forwarding rules and pending requests'
    echo '  5) Complete forwarding after destination verification'
    echo '  6) Change an existing forwarding destination'
    echo '  7) Delete a virtual email forwarding rule'
    echo '  8) List destinations / verification status'
    echo '  9) Configure catch-all forwarding'
    echo ' 10) Rotate Cloudflare token (archive old one)'
    echo ' 11) Health check and MX routing status'
    echo ' 12) Disable routing on an unused domain (guarded)'
    echo '  0) Return to main menu'
    local choice
    read -r -p 'Virtual Mail choice [0-12]: ' choice || return 0
    case "$choice" in
      1) vm_connect || true ;;
      2) vm_zone_summary || true ;;
      3) vm_add_forward || true ;;
      4) vm_show_forwards || true ;;
      5) vm_complete_pending || true ;;
      6) vm_change_forward || true ;;
      7) vm_remove_forward || true ;;
      8) if vm_select_zone; then vm_print_destinations || true; fi ;;
      9) vm_catch_all || true ;;
      10) vm_rotate_token || true ;;
      11) vm_health || true ;;
      12) vm_disable_zone || true ;;
      0|q|Q) return 0 ;;
      *) warn 'Invalid choice.' ;;
    esac
  done
)


main "$@"
