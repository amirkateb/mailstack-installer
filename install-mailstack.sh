#!/usr/bin/env bash
# ==============================================================================
# Stalwart + Bulwark Mail Stack Installer for Ubuntu 24.04 LTS
# by amirmohammad katebsaber
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0.0"
STATE_DIR="/var/lib/katebsaber-mailstack-installer"
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/katebsaber-mailstack-installer-$(date +%Y%m%d-%H%M%S).log"
SECRETS_FILE="/root/mailstack-secrets.txt"
DNS_ZONE_FILE="/root/stalwart-dns-zone.txt"
INSTALL_STAGE="startup"

# Colors
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'
  CYAN='\033[0;36m'
  WHITE='\033[1;37m'
  DIM='\033[2m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' DIM='' BOLD='' RESET=''
fi

mkdir -p "$STATE_DIR" "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

banner() {
  clear 2>/dev/null || true
  printf '%b\n' "${CYAN}${BOLD}"
  cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║              STALWART + BULWARK MAIL STACK INSTALLER                 ║
║                                                                      ║
║                    by amirmohammad katebsaber                        ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
  printf '%b\n' "${RESET}${DIM}Version ${SCRIPT_VERSION} • Ubuntu 24.04 LTS • Interactive production setup${RESET}"
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
  info "Full log: ${LOG_FILE}"
  echo
  warn "Last log lines:"
  tail -n 25 "$LOG_FILE" 2>/dev/null || true
  exit "$exit_code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

pause() {
  local prompt=${1:-"Press Enter to continue..."}
  read -r -p "$prompt" _
}

confirm() {
  local prompt="$1"
  local default=${2:-Y}
  local answer
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
  local ip=""
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

get_ssh_client_ip() {
  local ip=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ip=$(awk '{print $1}' <<<"$SSH_CONNECTION")
  fi
  printf '%s' "$ip"
}

port_owner() {
  local port="$1"
  ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print; found=1} END{if(!found) exit 1}' || true
}

check_initial_port_conflicts() {
  local port owner
  local ports=(25 465 587 993)
  for port in "${ports[@]}"; do
    owner=$(port_owner "$port")
    if [[ -n "$owner" ]] && ! grep -qi stalwart <<<"$owner"; then
      err "Port ${port} is already in use:"
      echo "$owner"
      fatal "A mail port is occupied by another service. This installer expects a fresh mail server."
    fi
  done
}

collect_configuration() {
  stage "Configuration"

  local input default_mail default_webmail
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

  SERVER_IP=$(get_public_ipv4 || true)
  if [[ -n "$SERVER_IP" ]]; then
    info "Detected public IPv4: $SERVER_IP"
    read -r -p "Public IPv4 [${SERVER_IP}]: " input
    SERVER_IP=${input:-$SERVER_IP}
  else
    read -r -p "Public IPv4 address of this server: " SERVER_IP
  fi
  [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fatal "Invalid IPv4 address: $SERVER_IP"

  SSH_PORT=$(get_ssh_port)
  SSH_CLIENT_IP=$(get_ssh_client_ip)

  echo
  printf '%b\n' "${WHITE}${BOLD}Configuration summary${RESET}"
  printf '  Domain:          %s\n' "$DOMAIN"
  printf '  Mail hostname:   %s\n' "$MAIL_HOST"
  printf '  Webmail:         %s\n' "$WEBMAIL_HOST"
  printf '  Public IPv4:     %s\n' "$SERVER_IP"
  printf '  SSH port:        %s\n' "$SSH_PORT"
  printf '  ACME email:      %s\n' "$LE_EMAIL"
  echo

  confirm "Continue with this configuration?" Y || fatal "Cancelled by user."

  cat >"$STATE_DIR/config.env" <<EOF
DOMAIN='$DOMAIN'
MAIL_HOST='$MAIL_HOST'
WEBMAIL_HOST='$WEBMAIL_HOST'
SERVER_IP='$SERVER_IP'
LE_EMAIL='$LE_EMAIL'
SSH_PORT='$SSH_PORT'
EOF
  chmod 600 "$STATE_DIR/config.env"
}

print_initial_dns() {
  stage "DNS requirements"
  cat <<EOF
Before installation can continue, create these DNS records at your DNS provider.
If you use Cloudflare, set both A records to DNS Only (grey cloud).

1) Mail server A record
   Type:   A
   Name:   ${MAIL_HOST%.${DOMAIN}}
   Value:  ${SERVER_IP}
   Proxy:  OFF / DNS Only

2) Webmail A record
   Type:   A
   Name:   ${WEBMAIL_HOST%.${DOMAIN}}
   Value:  ${SERVER_IP}
   Proxy:  OFF / DNS Only during setup

3) Mail exchanger
   Type:      MX
   Name:      @
   Priority:  10
   Target:    ${MAIL_HOST}

4) Reverse DNS / PTR (set this in the VPS provider panel, not normal DNS)
   IP:        ${SERVER_IP}
   PTR:       ${MAIL_HOST}

Do NOT invent DKIM values. Stalwart will generate the authoritative DKIM, SPF,
DMARC, MTA-STS, TLS-RPT, SRV and autoconfiguration records after its setup.
EOF
  echo
  pause "Press Enter after the A, MX and PTR records above are configured..."
}

dns_a_contains_ip() {
  local host="$1" ip="$2"
  dig +short A "$host" 2>/dev/null | grep -Fxq "$ip"
}

check_dns_prerequisites() {
  stage "DNS preflight validation"
  local failures=0 mx ptr

  if dns_a_contains_ip "$MAIL_HOST" "$SERVER_IP"; then
    ok "$MAIL_HOST resolves to $SERVER_IP"
  else
    err "$MAIL_HOST does not resolve to $SERVER_IP"
    info "Current A answers: $(dig +short A "$MAIL_HOST" | paste -sd ', ' - || true)"
    failures=$((failures+1))
  fi

  if dns_a_contains_ip "$WEBMAIL_HOST" "$SERVER_IP"; then
    ok "$WEBMAIL_HOST resolves to $SERVER_IP"
  else
    err "$WEBMAIL_HOST does not resolve to $SERVER_IP"
    info "Current A answers: $(dig +short A "$WEBMAIL_HOST" | paste -sd ', ' - || true)"
    failures=$((failures+1))
  fi

  mx=$(dig +short MX "$DOMAIN" 2>/dev/null | awk '{print tolower($2)}' | sed 's/\.$//' || true)
  if grep -Fxq "$MAIL_HOST" <<<"$mx"; then
    ok "$DOMAIN MX points to $MAIL_HOST"
  else
    err "$DOMAIN MX does not point to $MAIL_HOST"
    info "Current MX answers: $(dig +short MX "$DOMAIN" | paste -sd ', ' - || true)"
    failures=$((failures+1))
  fi

  ptr=$(dig +short -x "$SERVER_IP" 2>/dev/null | head -n1 | tr '[:upper:]' '[:lower:]' | sed 's/\.$//' || true)
  if [[ "$ptr" == "$MAIL_HOST" ]]; then
    ok "PTR is correct: $SERVER_IP -> $MAIL_HOST"
  else
    err "PTR is not correct. Expected: $SERVER_IP -> $MAIL_HOST"
    info "Current PTR: ${ptr:-none}"
    failures=$((failures+1))
  fi

  if (( failures > 0 )); then
    fatal "DNS preflight failed with ${failures} problem(s). Fix the records, wait for propagation, then run the installer again."
  fi
}

apt_backup_once() {
  local backup="$STATE_DIR/apt-sources-backup.tar.gz"
  if [[ ! -f "$backup" ]]; then
    tar -czf "$backup" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true
    chmod 600 "$backup" 2>/dev/null || true
  fi
}

probe_ubuntu_mirror() {
  local base="$1"
  local code
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
  local mirror=""

  for candidate in "${candidates[@]}"; do
    info "Testing Ubuntu mirror: $candidate"
    if probe_ubuntu_mirror "$candidate"; then
      mirror="$candidate"
      ok "Selected Ubuntu mirror: $mirror"
      break
    fi
  done

  [[ -n "$mirror" ]] || fatal "No tested Ubuntu mirror is reachable from this server."

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
  apt-get update || fatal "APT still fails after switching to the tested Ubuntu mirror: $mirror"
  ok "APT is working through $mirror"
}

apt_update_resilient() {
  stage "APT connectivity"
  if apt-get update; then
    ok "APT repositories are reachable."
  else
    warn "The current Ubuntu repositories failed. Trying tested fallback mirrors."
    configure_ubuntu_mirror_fallback
  fi
}

install_base_packages() {
  stage "Base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y \
    ca-certificates curl wget gnupg jq git xz-utils unzip \
    dnsutils netcat-openbsd openssl ufw nginx certbot \
    python3-certbot-nginx >/dev/null
  ok "Base packages installed."
  systemctl disable --now nginx >/dev/null 2>&1 || true
}

check_outbound_smtp() {
  stage "Outbound SMTP port 25 test"
  local targets=("gmail-smtp-in.l.google.com" "mx1.hotmail.com")
  local host
  for host in "${targets[@]}"; do
    info "Testing TCP/25 to $host ..."
    if nc -4 -z -w 8 "$host" 25 >/dev/null 2>&1; then
      ok "Outbound TCP/25 is open."
      return 0
    fi
  done
  fatal "Outbound TCP/25 appears blocked. Ask the VPS provider to enable outbound port 25 before hosting a direct-delivery mail server."
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

install_docker_from_ubuntu() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y docker.io docker-compose-v2
}

install_docker_official_fallback() {
  stage "Docker official repository fallback"
  local arch
  arch=$(dpkg --print-architecture)
  info "Ubuntu Docker packages failed. Testing download.docker.com ..."
  if ! curl -fsSI --connect-timeout 6 --max-time 10 https://download.docker.com/linux/ubuntu/dists/noble/InRelease >/dev/null; then
    return 1
  fi

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
  local available=()
  local m code
  for m in "${candidates[@]}"; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "${m}/v2/" 2>/dev/null || true)
    if [[ "$code" == "200" || "$code" == "401" ]]; then
      available+=("$m")
    fi
  done

  ((${#available[@]} > 0)) || return 1

  mkdir -p /etc/docker
  local mirrors_json existing tmp
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

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "Docker is already installed and running."
  else
    info "Trying Ubuntu 24.04 Docker packages first..."
    if install_docker_from_ubuntu; then
      ok "Docker installed from Ubuntu repositories."
    else
      warn "Ubuntu Docker package installation failed. Trying Docker's official repository."
      install_docker_official_fallback || fatal "Docker could not be installed from Ubuntu repositories or the official Docker repository."
    fi
  fi

  systemctl enable --now docker
  docker info >/dev/null || fatal "Docker daemon is installed but not operational."

  if ! docker compose version >/dev/null 2>&1; then
    warn "Docker Compose v2 is missing; trying to install it."
    apt-get install -y docker-compose-v2 >/dev/null 2>&1 || true
  fi
  docker compose version >/dev/null 2>&1 || fatal "Docker Compose v2 could not be installed."

  ok "$(docker --version)"
  ok "$(docker compose version)"

  info "Testing Docker Hub pull..."
  if docker pull hello-world:latest >/dev/null 2>&1; then
    ok "Docker Hub pull works directly."
    docker image rm hello-world:latest >/dev/null 2>&1 || true
  else
    warn "Docker Hub direct pull failed. Trying reachable Iranian registry mirrors."
    if select_dockerhub_mirrors && docker pull hello-world:latest >/dev/null 2>&1; then
      ok "Docker Hub pull works through the configured mirror."
      docker image rm hello-world:latest >/dev/null 2>&1 || true
    else
      warn "Docker Hub still cannot be pulled. This is not fatal yet because Bulwark is hosted on GHCR."
    fi
  fi
}

install_stalwart() {
  stage "Stalwart installation"
  if systemctl list-unit-files 2>/dev/null | grep -q '^stalwart\.service'; then
    ok "Stalwart service already exists; skipping binary installation."
    systemctl enable --now stalwart
    return
  fi

  local installer=/tmp/stalwart-install.sh
  info "Downloading the official Stalwart installer..."
  curl --proto '=https' --tlsv1.2 -fsS --connect-timeout 10 --max-time 60 \
    https://get.stalw.art/install.sh -o "$installer" || \
    fatal "Cannot download the official Stalwart installer from get.stalw.art."

  sh "$installer"
  rm -f "$installer"
  systemctl enable --now stalwart
  systemctl is-active --quiet stalwart || fatal "Stalwart service did not start. Check: journalctl -u stalwart -n 100"
  ok "Stalwart installed and running."
}

install_stalwart_cli() {
  stage "Stalwart CLI"
  if command -v stalwart-cli >/dev/null 2>&1; then
    ok "Stalwart CLI is already installed."
    return
  fi

  local script=/tmp/stalwart-cli-installer.sh
  curl -fsSL --connect-timeout 10 --max-time 60 \
    https://github.com/stalwartlabs/cli/releases/latest/download/stalwart-cli-installer.sh \
    -o "$script" || fatal "Cannot download stalwart-cli from GitHub Releases."
  sh "$script"
  rm -f "$script"

  if ! command -v stalwart-cli >/dev/null 2>&1; then
    local found
    found=$(find /root -type f -name stalwart-cli -perm -u+x 2>/dev/null | head -n1 || true)
    [[ -n "$found" ]] && ln -sf "$found" /usr/local/bin/stalwart-cli
  fi
  command -v stalwart-cli >/dev/null 2>&1 || fatal "stalwart-cli installer completed but the binary was not found."
  ok "Stalwart CLI installed."
}

show_stalwart_bootstrap_credentials() {
  local block
  block=$(journalctl -u stalwart -n 250 --no-pager 2>/dev/null | grep -A12 -B2 'bootstrap mode' | tail -n 30 || true)
  if [[ -n "$block" ]]; then
    echo
    printf '%b\n' "${WHITE}${BOLD}Stalwart bootstrap credentials from service log:${RESET}"
    echo "$block"
  else
    warn "Bootstrap credentials were not found in the latest journal output."
    info "Run manually if needed: journalctl -u stalwart -n 250 --no-pager"
  fi
}

open_temporary_bootstrap_access() {
  if [[ -n "$SSH_CLIENT_IP" && "$SSH_CLIENT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    ufw allow from "$SSH_CLIENT_IP" to any port 8080 proto tcp comment 'temporary-stalwart-bootstrap' >/dev/null
    TEMP_8080_RULE="client"
    ok "Temporarily allowed port 8080 only from SSH client IP: $SSH_CLIENT_IP"
  else
    ufw allow 8080/tcp comment 'temporary-stalwart-bootstrap' >/dev/null
    TEMP_8080_RULE="global"
    warn "Could not determine the SSH client IP; port 8080 is temporarily public until the wizard is completed."
  fi
}

close_temporary_bootstrap_access() {
  if [[ "${TEMP_8080_RULE:-}" == "client" ]]; then
    ufw delete allow from "$SSH_CLIENT_IP" to any port 8080 proto tcp >/dev/null 2>&1 || true
  elif [[ "${TEMP_8080_RULE:-}" == "global" ]]; then
    ufw delete allow 8080/tcp >/dev/null 2>&1 || true
  fi
  ok "Temporary public access to port 8080 has been removed."
}

stalwart_needs_wizard() {
  [[ ! -s /etc/stalwart/config.json ]]
}

run_stalwart_wizard_phase() {
  stage "Stalwart first-time setup"

  if stalwart_needs_wizard; then
    open_temporary_bootstrap_access
    show_stalwart_bootstrap_credentials
    echo
    cat <<EOF
Open this URL in your browser:

  http://${SERVER_IP}:8080/admin

Complete the Stalwart wizard with these values:

  Server hostname:                 ${MAIL_HOST}
  Default email domain:            ${DOMAIN}
  Automatically obtain TLS:        OFF
  Generate email signing keys:     ON
  Storage:                         Keep the default RocksDB choices
  Account directory:               Internal Directory
  Logging:                         Log File
  DNS management:                  Manual DNS Server Management

IMPORTANT:
  On the final Stalwart screen, save the permanent administrator email and
  password. The password is shown only once.
EOF
    echo
    pause "Press Enter only after the Stalwart wizard is fully completed..."
    systemctl restart stalwart
    sleep 3
    close_temporary_bootstrap_access
  else
    ok "Stalwart already has config.json; first-time wizard appears completed."
  fi

  echo
  read -r -p "Permanent Stalwart administrator username/email: " STALWART_ADMIN_USER
  read -r -s -p "Permanent Stalwart administrator password: " STALWART_ADMIN_PASSWORD
  echo
  [[ -n "$STALWART_ADMIN_USER" && -n "$STALWART_ADMIN_PASSWORD" ]] || fatal "Stalwart administrator credentials are required to finish automated configuration."
}

stalwart_cli_local() {
  stalwart-cli \
    --url "${STALWART_CLI_URL:-https://127.0.0.1:443}" \
    --insecure \
    --user "$STALWART_ADMIN_USER" \
    --password "$STALWART_ADMIN_PASSWORD" \
    "$@"
}

validate_stalwart_credentials() {
  stage "Stalwart administrator validation"
  local candidate
  for candidate in \
    "https://127.0.0.1:443" \
    "https://127.0.0.1:10443" \
    "http://127.0.0.1:8080"; do
    STALWART_CLI_URL="$candidate"
    if stalwart_cli_local get SystemSettings --json >/dev/null 2>&1; then
      ok "Stalwart administrator credentials are valid via ${candidate}."
      return
    fi
  done

  fatal "Cannot authenticate to Stalwart with the provided permanent administrator credentials."
}

rebind_stalwart_web_listeners() {
  stage "Stalwart reverse-proxy listener configuration"
  local listeners ids id bind protocol
  listeners=$(stalwart_cli_local query NetworkListener --fields id,name,protocol,bind --json)

  ids=$(jq -r 'select(.protocol=="http") | select([(.bind // {} | keys[]) | test(":443$")] | any) | .id' <<<"$listeners" || true)
  if [[ -n "$ids" ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      info "Moving Stalwart HTTPS listener $id from public :443 to 127.0.0.1:10443"
      stalwart_cli_local update NetworkListener "$id" --field 'bind={"127.0.0.1:10443":true}' >/dev/null
    done <<<"$ids"
  else
    info "No Stalwart HTTP listener currently bound to public :443."
  fi

  ids=$(jq -r 'select(.protocol=="http") | select([(.bind // {} | keys[]) | test(":8080$")] | any) | .id' <<<"$listeners" || true)
  if [[ -n "$ids" ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      info "Binding Stalwart HTTP listener $id to loopback only: 127.0.0.1:8080"
      stalwart_cli_local update NetworkListener "$id" --field 'bind={"127.0.0.1:8080":true}' >/dev/null
    done <<<"$ids"
  fi

  stalwart_cli_local update Http --field useXForwarded=true --field usePermissiveCors=true >/dev/null

  if grep -q '^STALWART_PUBLIC_URL=' /etc/stalwart/stalwart.env 2>/dev/null; then
    sed -i "s|^STALWART_PUBLIC_URL=.*|STALWART_PUBLIC_URL=https://${MAIL_HOST}|" /etc/stalwart/stalwart.env
  else
    printf '\nSTALWART_PUBLIC_URL=https://%s\n' "$MAIL_HOST" >>/etc/stalwart/stalwart.env
  fi

  systemctl restart stalwart
  sleep 3

  # Prefer the loopback HTTP management/API listener after moving public HTTPS
  # behind Nginx. Fall back to the internal HTTPS listener if required.
  STALWART_CLI_URL="http://127.0.0.1:8080"
  if ! stalwart_cli_local get SystemSettings --json >/dev/null 2>&1; then
    STALWART_CLI_URL="https://127.0.0.1:10443"
    stalwart_cli_local get SystemSettings --json >/dev/null 2>&1 || \
      fatal "Stalwart management API is unreachable after listener reconfiguration."
  fi

  curl -kfsS --connect-timeout 5 "https://127.0.0.1:10443/" >/dev/null 2>&1 || \
    warn "Internal Stalwart HTTPS port 10443 did not answer a root HTTP request; continuing because the HTTP upstream on 8080 is what Nginx will use."

  curl -fsS --connect-timeout 5 "http://127.0.0.1:8080/.well-known/jmap" >/dev/null 2>&1 || \
    fatal "Stalwart HTTP upstream on 127.0.0.1:8080 is not responding after listener reconfiguration."

  ok "Stalwart web listeners are ready for Nginx."
}

write_nginx_bootstrap_config() {
  mkdir -p /var/www/letsencrypt/.well-known/acme-challenge
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
    ok "An existing Let's Encrypt certificate for $MAIL_HOST was found."
  else
    certbot certonly \
      --webroot -w /var/www/letsencrypt \
      -d "$MAIL_HOST" -d "$WEBMAIL_HOST" \
      --non-interactive --agree-tos --email "$LE_EMAIL" \
      --preferred-challenges http
  fi

  [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]] || fatal "Let's Encrypt did not produce the expected certificate files."
  ok "TLS certificate is available for $MAIL_HOST and $WEBMAIL_HOST."
}

configure_stalwart_certificate() {
  stage "Stalwart TLS certificate"
  local cert_src="/etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem"
  local key_src="/etc/letsencrypt/live/${MAIL_HOST}/privkey.pem"
  local cert_id=""

  install -d -o root -g stalwart -m 0750 /etc/stalwart/certs
  install -o root -g stalwart -m 0640 "$cert_src" /etc/stalwart/certs/fullchain.pem
  install -o root -g stalwart -m 0640 "$key_src" /etc/stalwart/certs/privkey.pem

  cert_id=$(stalwart_cli_local query Certificate --where "subjectAlternativeNames=${MAIL_HOST}" --fields id --json 2>/dev/null | jq -r '.id' | head -n1 || true)

  if [[ -n "$cert_id" && "$cert_id" != "null" ]]; then
    info "Updating existing Stalwart certificate object: $cert_id"
    stalwart_cli_local update Certificate "$cert_id" \
      --field 'certificate={"@type":"File","filePath":"/etc/stalwart/certs/fullchain.pem"}' \
      --field 'privateKey={"@type":"File","filePath":"/etc/stalwart/certs/privkey.pem"}' >/dev/null
  else
    info "Creating Stalwart certificate object from managed certificate files."
    stalwart_cli_local create Certificate \
      --field 'certificate={"@type":"File","filePath":"/etc/stalwart/certs/fullchain.pem"}' \
      --field 'privateKey={"@type":"File","filePath":"/etc/stalwart/certs/privkey.pem"}' >/dev/null
    sleep 1
    cert_id=$(stalwart_cli_local query Certificate --where "subjectAlternativeNames=${MAIL_HOST}" --fields id --json | jq -r '.id' | head -n1)
  fi

  [[ -n "$cert_id" && "$cert_id" != "null" ]] || fatal "Stalwart certificate object was created but its ID could not be found."
  stalwart_cli_local update SystemSettings --field "defaultCertificateId=${cert_id}" >/dev/null
  systemctl restart stalwart
  sleep 3
  ok "Stalwart is configured to use the Let's Encrypt certificate on SMTP/IMAP TLS listeners."
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
  ok "Certificate renewal will refresh Stalwart and Nginx automatically."
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
  systemctl reload nginx
  ok "Nginx is serving $MAIL_HOST and $WEBMAIL_HOST over HTTPS."
}

generate_secret() {
  openssl rand -base64 48 | tr -d '\n' | tr '/+' '_-'
}

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
  ok "Applied the existing shell proxy to the Docker daemon."
}

try_bulwark_ghcr() {
  docker pull ghcr.io/bulwarkmail/webmail:latest
}

install_node22_binary() {
  local arch node_arch base index version tarball tmp expected actual
  arch=$(uname -m)
  case "$arch" in
    x86_64) node_arch="x64" ;;
    aarch64|arm64) node_arch="arm64" ;;
    *) fatal "Native Bulwark fallback does not support CPU architecture: $arch" ;;
  esac

  local bases=(
    "https://nodejs.org/dist"
    "https://npmmirror.com/mirrors/node"
  )
  base=""
  for candidate in "${bases[@]}"; do
    if curl -fsS --connect-timeout 8 --max-time 20 "${candidate}/index.json" -o /tmp/node-index.json; then
      base="$candidate"
      break
    fi
  done
  [[ -n "$base" ]] || fatal "Cannot reach nodejs.org or the Node.js fallback mirror."

  version=$(jq -r '[.[] | select(.version | startswith("v22."))][0].version // empty' /tmp/node-index.json)
  [[ -n "$version" ]] || fatal "Could not determine the latest Node.js 22 release."
  tarball="node-${version}-linux-${node_arch}.tar.xz"
  tmp=$(mktemp -d)

  info "Downloading Node.js ${version} from ${base}"
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
  node --version | grep -q '^v22\.' || fatal "Node.js 22 installation verification failed."
  ok "Installed $(node --version) for native Bulwark fallback."
}

install_bulwark_native() {
  stage "Bulwark native fallback"
  warn "GHCR image pull failed. Falling back to the official source-based deployment path."

  command -v node >/dev/null 2>&1 && [[ "$(node -p 'process.versions.node.split(`.`)[0]' 2>/dev/null || echo 0)" -ge 20 ]] || install_node22_binary

  if ! git ls-remote https://github.com/bulwarkmail/webmail.git HEAD >/dev/null 2>&1; then
    fatal "GHCR is unavailable and GitHub source access also failed. Configure an outbound proxy, then run the installer again."
  fi

  if ! curl -fsSI --connect-timeout 8 --max-time 15 https://registry.npmjs.org/ >/dev/null 2>&1; then
    warn "registry.npmjs.org is not reachable; switching npm to npmmirror.com."
    npm config set registry https://registry.npmmirror.com
  fi

  rm -rf /opt/bulwark
  git clone --depth 1 https://github.com/bulwarkmail/webmail.git /opt/bulwark
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
ExecStart=/usr/local/bin/node .next/standalone/server.js
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/bulwark

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now bulwark
  BULWARK_MODE="native"
}

install_bulwark_docker() {
  stage "Bulwark Docker deployment"
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
  (cd /opt/bulwark-docker && docker compose up -d)
  BULWARK_MODE="docker"
}

install_bulwark() {
  stage "Bulwark availability test"
  BULWARK_SESSION_SECRET=$(generate_secret)
  BULWARK_ADMIN_PASSWORD=$(generate_secret | cut -c1-32)

  if try_bulwark_ghcr; then
    ok "GHCR is reachable; using the official Bulwark container image."
    install_bulwark_docker
  else
    warn "Direct GHCR pull failed."
    if configure_docker_proxy_from_environment && try_bulwark_ghcr; then
      ok "GHCR pull succeeded after applying the existing proxy to Docker."
      install_bulwark_docker
    else
      install_bulwark_native
    fi
  fi

  sleep 5
  if curl -fsS --connect-timeout 5 http://127.0.0.1:3000/api/health >/dev/null; then
    ok "Bulwark health endpoint is responding on 127.0.0.1:3000."
  else
    if [[ "$BULWARK_MODE" == "docker" ]]; then
      docker logs --tail 80 bulwark || true
    else
      journalctl -u bulwark -n 80 --no-pager || true
    fi
    fatal "Bulwark started but its health endpoint is not healthy."
  fi

  cat >"$SECRETS_FILE" <<EOF
Mail Stack Secrets
==================
Generated by: by amirmohammad katebsaber installer
Generated at: $(date -Is)

Bulwark URL: https://${WEBMAIL_HOST}
Bulwark admin password: ${BULWARK_ADMIN_PASSWORD}
Bulwark deployment mode: ${BULWARK_MODE}

Stalwart admin credentials are intentionally NOT stored here.
Use the permanent credentials you saved from the Stalwart wizard.
EOF
  chmod 0600 "$SECRETS_FILE"
  ok "Bulwark deployment mode: $BULWARK_MODE"
  info "Generated Bulwark admin secret saved to: $SECRETS_FILE"
}

fetch_stalwart_dns_zone() {
  stage "Stalwart authoritative DNS zone"
  local domain_id zone
  domain_id=$(stalwart_cli_local query Domain --where "name=${DOMAIN}" --fields id,name --json | jq -r 'select(.name=="'"$DOMAIN"'") | .id' | head -n1)
  [[ -n "$domain_id" && "$domain_id" != "null" ]] || fatal "Could not find Stalwart domain object for $DOMAIN."

  zone=$(stalwart_cli_local get Domain "$domain_id" --fields dnsZoneFile --json | jq -r '.dnsZoneFile // empty')
  [[ -n "$zone" ]] || fatal "Stalwart returned an empty DNS zone file for $DOMAIN."

  printf '%s\n' "$zone" >"$DNS_ZONE_FILE"
  chmod 0600 "$DNS_ZONE_FILE"

  echo
  printf '%b\n' "${WHITE}${BOLD}Add every record below to your DNS provider exactly as Stalwart generated it:${RESET}"
  echo
  cat "$DNS_ZONE_FILE"
  echo
  info "A copy was saved to: $DNS_ZONE_FILE"
  warn "Do not modify DKIM public keys, selectors, SPF or DMARC values."
}

verify_auth_dns() {
  stage "SPF / DKIM / DMARC validation"
  local attempt=0 spf dmarc selectors selector query_name missing

  selectors=$(grep -Eio '[A-Za-z0-9_-]+\._domainkey(\.[A-Za-z0-9._-]+)?\.?' "$DNS_ZONE_FILE" | sort -u || true)

  while true; do
    attempt=$((attempt+1))
    missing=0
    echo
    info "DNS verification attempt ${attempt}"

    spf=$(dig +short TXT "$DOMAIN" 2>/dev/null | tr -d '"' | grep -m1 'v=spf1' || true)
    if [[ -n "$spf" ]]; then ok "SPF record detected."; else err "SPF record is not visible yet."; missing=$((missing+1)); fi

    dmarc=$(dig +short TXT "_dmarc.${DOMAIN}" 2>/dev/null | tr -d '"' | grep -m1 -i 'v=DMARC1' || true)
    if [[ -n "$dmarc" ]]; then ok "DMARC record detected."; else err "DMARC record is not visible yet."; missing=$((missing+1)); fi

    if [[ -n "$selectors" ]]; then
      while IFS= read -r selector; do
        [[ -n "$selector" ]] || continue
        selector=${selector%.}
        if [[ "$selector" == *".${DOMAIN}" ]]; then
          query_name="$selector"
        else
          query_name="${selector}.${DOMAIN}"
        fi
        if dig +short TXT "$query_name" 2>/dev/null | tr -d '"' | grep -qi 'DKIM'; then
          ok "DKIM record detected: $query_name"
        else
          err "DKIM record is not visible yet: $query_name"
          missing=$((missing+1))
        fi
      done <<<"$selectors"
    else
      warn "Could not parse DKIM selector names from the generated zone; verify the displayed zone manually."
    fi

    if (( missing == 0 )); then
      ok "Required sender-authentication DNS records are visible."
      return 0
    fi

    echo
    read -r -p "Add/fix the DNS records, then type R to retry or Q to stop safely [R/q]: " answer
    answer=${answer:-R}
    if [[ "$answer" =~ ^[Qq]$ ]]; then
      fatal "Stopped while waiting for SPF/DKIM/DMARC DNS propagation. The installed services are preserved; rerun this installer after DNS is ready."
    fi
  done
}

validate_mail_ports() {
  stage "Mail listener validation"
  local p
  for p in 25 465 587 993; do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"; then
      ok "TCP/${p} is listening."
    else
      fatal "Stalwart is not listening on required TCP/${p}. Open Stalwart Admin > Settings > Network > Listeners and verify the standard mail listeners."
    fi
  done
}

final_health_checks() {
  stage "Final health checks"

  curl -fsS --connect-timeout 10 "https://${MAIL_HOST}/.well-known/jmap" >/dev/null || fatal "Public Stalwart JMAP endpoint failed: https://${MAIL_HOST}/.well-known/jmap"
  ok "Public JMAP discovery works."

  curl -fsS --connect-timeout 10 "https://${WEBMAIL_HOST}/api/health" >/dev/null || fatal "Public Bulwark health endpoint failed: https://${WEBMAIL_HOST}/api/health"
  ok "Public Bulwark health endpoint works."

  if openssl s_client -connect "${MAIL_HOST}:993" -servername "$MAIL_HOST" -verify_return_error </dev/null 2>/dev/null | grep -q 'Verify return code: 0'; then
    ok "IMAPS 993 presents a valid TLS certificate."
  else
    fatal "IMAPS 993 TLS verification failed. Check the Stalwart certificate object and listener."
  fi

  if openssl s_client -connect "${MAIL_HOST}:465" -servername "$MAIL_HOST" -verify_return_error </dev/null 2>/dev/null | grep -q 'Verify return code: 0'; then
    ok "SMTPS 465 presents a valid TLS certificate."
  else
    fatal "SMTPS 465 TLS verification failed. Check the Stalwart certificate object and listener."
  fi

  nginx -t >/dev/null
  systemctl is-active --quiet nginx || fatal "Nginx is not active."
  systemctl is-active --quiet stalwart || fatal "Stalwart is not active."
  if [[ "$BULWARK_MODE" == "docker" ]]; then
    docker inspect -f '{{.State.Running}}' bulwark 2>/dev/null | grep -q true || fatal "Bulwark Docker container is not running."
  else
    systemctl is-active --quiet bulwark || fatal "Bulwark native service is not active."
  fi

  ok "All primary services are healthy."
}

print_final_summary() {
  stage "Installation complete"
  cat <<EOF

Everything is installed and the main health checks passed.

Web interfaces
--------------
Stalwart Admin:  https://${MAIL_HOST}/admin
Bulwark Webmail: https://${WEBMAIL_HOST}

Mail client settings
--------------------
IMAP server:        ${MAIL_HOST}
IMAP port:          993
IMAP security:      SSL/TLS

SMTP server:        ${MAIL_HOST}
SMTP port:          465
SMTP security:      SSL/TLS

Alternative SMTP:   ${MAIL_HOST}:587 with STARTTLS
Username:           Full email address

Important files
---------------
Installer log:      ${LOG_FILE}
DNS zone copy:      ${DNS_ZONE_FILE}
Bulwark secrets:    ${SECRETS_FILE}
Stalwart config:    /etc/stalwart/config.json
Nginx config:       /etc/nginx/sites-available/mailstack

Deployment
----------
Stalwart:           Native systemd service
Bulwark:            ${BULWARK_MODE}
Reverse proxy:      Nginx
TLS:                Let's Encrypt / Certbot

Recommended final test
----------------------
1. Create a normal mailbox in Stalwart Admin.
2. Sign in to Bulwark with that mailbox.
3. Send one message to Gmail and one to Outlook.
4. In Gmail, use "Show original" and confirm SPF=PASS, DKIM=PASS, DMARC=PASS.

Security reminder
-----------------
Port 8080 and Bulwark port 3000 are not public. Only Nginx can reach them locally.
The Stalwart administrator password was never written to the installer secrets file.

by amirmohammad katebsaber
EOF
  echo
  ok "Mail stack installation finished successfully."
}

main() {
  banner
  require_root
  validate_ubuntu

  warn "This installer is designed for a fresh Ubuntu 24.04 mail server."
  warn "It will install and configure UFW, Nginx, Docker, Stalwart, Certbot and Bulwark."
  echo
  confirm "Start the installation?" Y || exit 0

  collect_configuration
  print_initial_dns
  apt_update_resilient
  install_base_packages
  check_dns_prerequisites
  check_initial_port_conflicts
  check_outbound_smtp
  hostnamectl set-hostname "$MAIL_HOST"
  configure_firewall
  install_and_test_docker
  install_stalwart
  install_stalwart_cli
  run_stalwart_wizard_phase
  validate_stalwart_credentials
  rebind_stalwart_web_listeners
  issue_tls_certificate
  configure_stalwart_certificate
  create_certbot_deploy_hook
  write_final_nginx_config
  install_bulwark
  # Reload Nginx after Bulwark is ready.
  nginx -t >/dev/null && systemctl reload nginx
  fetch_stalwart_dns_zone
  verify_auth_dns
  validate_mail_ports
  final_health_checks
  print_final_summary
}

main "$@"
