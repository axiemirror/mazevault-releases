#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# MazeVault — Configuration Drift Checker
# Compares installed .env + docker-compose.yml against the reference
# templates from install-mazevault.sh and reports missing keys,
# services, volume mounts, dependencies and port mappings.
#
# Usage: sudo ./check-config.sh [--dir /opt/mazevault]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="/opt/mazevault"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --help|-h) echo "Usage: $0 [--dir /opt/mazevault]"; exit 0 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'
BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

ok()   { echo -e "  ${GRN}✔${RST} $*"; }
miss() { echo -e "  ${RED}✘${RST} $*"; ISSUES=$((ISSUES+1)); }
warn() { echo -e "  ${YLW}⚠${RST} $*"; }
info() { echo -e "  ${CYN}ℹ${RST} $*"; }
hdr()  { echo -e "\n${BLD}${CYN}── $* ──${RST}"; }

ISSUES=0

# ── Validate ────────────────────────────────────────────────────────────────
# ═════════════════════════════════════════════════════════════════════════════
# 0. Systemd & Docker Daemon Validation
# ═════════════════════════════════════════════════════════════════════════════
hdr "Systemd & Docker Daemon"

# Check systemd service
if systemctl list-unit-files | grep -q '^mazevault.service'; then
  if systemctl is-enabled mazevault &>/dev/null; then
    ok "mazevault.service is enabled"
  else
    miss "mazevault.service exists but is not enabled"
  fi
else
  miss "mazevault.service does not exist"
fi

# Check Docker daemon
if systemctl list-unit-files | grep -q '^docker.service'; then
  if systemctl is-enabled docker &>/dev/null; then
    ok "docker.service is enabled"
  else
    miss "docker.service exists but is not enabled"
  fi
  if systemctl is-active docker &>/dev/null; then
    ok "docker.service is running"
  else
    miss "docker.service is not running"
  fi
else
  miss "docker.service does not exist"
fi

# Paths used by all subsequent checks
ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE="${INSTALL_DIR}/docker-compose.yml"

# Check restart policies in compose
hdr "Restart policies"
RESTART_OK=0; RESTART_MISS=0
if [[ ! -f "${COMPOSE}" ]]; then
  miss "docker-compose.yml not found at ${COMPOSE} — skipping restart policy check"
else
for s in init-certs postgres redis backend ocsp docs frontend; do
  if grep -A 10 "^  ${s}:" "${COMPOSE}" | grep -q 'restart:'; then
    policy=$(grep -A 10 "^  ${s}:" "${COMPOSE}" | grep 'restart:' | head -1 | awk '{print $2}' | tr -d '"')
    if [[ "$s" == "init-certs" && "$policy" == "no" ]]; then
      ok "${s}: restart: no"
      RESTART_OK=$((RESTART_OK+1))
    elif [[ "$s" != "init-certs" && "$policy" == "unless-stopped" ]]; then
      ok "${s}: restart: unless-stopped"
      RESTART_OK=$((RESTART_OK+1))
    else
      miss "${s}: restart policy is $policy (should be 'unless-stopped' or 'no')"
      RESTART_MISS=$((RESTART_MISS+1))
    fi
  else
    miss "${s}: missing restart policy"
    RESTART_MISS=$((RESTART_MISS+1))
  fi
done
fi
if [[ $RESTART_MISS -eq 0 ]]; then
  ok "All restart policies correct"
else
  echo -e "  ${DIM}${RESTART_OK} ok, ${RED}${RESTART_MISS} missing/incorrect${RST}"
fi
[[ -f "${ENV_FILE}" ]]  || { echo -e "${RED}ERR${RST} ${ENV_FILE} not found";  exit 1; }
[[ -f "${COMPOSE}" ]]   || { echo -e "${RED}ERR${RST} ${COMPOSE} not found";   exit 1; }

# Read installed version
INSTALLED_TAG=$(grep -oP '^IMAGE_TAG=\K.*' "${ENV_FILE}" 2>/dev/null || echo "?")
echo -e "${BLD}MazeVault Config Check${RST}  ${DIM}${INSTALL_DIR}  IMAGE_TAG=${INSTALLED_TAG}${RST}"

# ── Helper: extract compose block for a service ─────────────────────────────
# Prints lines from "  <svc>:" until next top-level service or section
svc_block() {
  awk -v svc="  ${1}:" '
    $0 == svc || $0 ~ "^"svc"$" || $0 ~ "^  "$1":$" { found=1; next }
    found && /^  [a-z]/ { exit }
    found && /^[a-z]|^volumes:|^networks:/ { exit }
    found { print }
  ' "${COMPOSE}"
}

# ═════════════════════════════════════════════════════════════════════════════
# 1. .env keys
# ═════════════════════════════════════════════════════════════════════════════
hdr ".env keys"

REF_ENV_KEYS=(
  IMAGE_REGISTRY IMAGE_TAG APP_VERSION
  MAZEVAULT_ENV MAZEVAULT_ORCHESTRATOR_MODE GIN_MODE
  MAZEVAULT_DOMAIN FRONTEND_URL OCSP_URL
  MAZEVAULT_CUSTOMER_NAME MAZEVAULT_CUSTOMER_EMAIL MAZEVAULT_COMPANY_ID
  POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB DATABASE_URL RUN_MIGRATIONS
  REDIS_PASSWORD
  JWT_SECRET MASTER_KEY SESSION_SECRET MAZEVAULT_JWT_KEY
  MAZEVAULT_TLS_ENABLED MAZEVAULT_TLS_SKIP_INIT MAZEVAULT_TLS_CERT_PATH
  COOKIE_SECURE ALLOWED_ORIGINS CORS_ALLOWED_ORIGINS
  FRONTEND_PORT BACKEND_PORT DOCS_PORT DOCS_URL
  MAZEVAULT_REGION
  LICENSE_SERVER_URL ENABLE_LICENSE_CHECK BUILD_AUTH_SECRET
  SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_FROM
)

# Optional keys — reported as info, not errors
OPTIONAL_ENV_KEYS=(
  ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET ENTRA_TENANT_ID ENTRA_REDIRECT_URI
  MAZEVAULT_ENFORCE_OIDC_NONCE
  AZURE_AD_TENANT_ID AZURE_AD_ALLOWED_TENANTS AZURE_AD_JWKS_CACHE_TTL
  AZURE_MANAGED_IDENTITY_CLIENT_ID AZURE_TENANT_ID AZURE_DEPLOYMENT
  O365_EMAIL_ENABLED O365_TENANT_ID O365_CLIENT_ID O365_CLIENT_SECRET
  O365_SENDER_EMAIL O365_AUTH_METHOD O365_CERTIFICATE_PATH
  O365_CERTIFICATE_PASSWORD O365_MANAGED_IDENTITY_CLIENT_ID
  AGENT_BINARY_GITHUB_TOKEN AGENT_BINARY_CACHE_DIR AGENT_BINARY_RELEASE_API_URL
  AGENT_ROLLOUT_PERCENTAGE AGENT_MAX_CONCURRENT_DOWNLOADS
  AGENT_DOWNLOAD_BASE_URL AGENT_VERSION
  MAZEVAULT_MODE PRIMARY_BACKEND_URL GATEWAY_BOOTSTRAP_TOKEN GATEWAY_NAME
  MAZEVAULT_GATEWAY_ENVIRONMENT MAZEVAULT_GATEWAY_ENVIRONMENTS MAZEVAULT_GATEWAY_ROLE MAZEVAULT_GATEWAY_STATE_FILE MAZEVAULT_VERSION
  MAZEVAULT_PRIMARY_ENVIRONMENTS
  MAZEVAULT_AGENT_INSTALL_CHAIN_TO_TRUSTSTORE MAZEVAULT_AGENT_TRUST_STORE_PATH
  MAZEVAULT_ACME_DNS_PROVIDER MAZEVAULT_ACME_DNS_API_TOKEN
  MAZEVAULT_KEYTAB_ENABLED MAZEVAULT_KEYTAB_MAX_SIZE_MB MAZEVAULT_KEYTAB_DEFAULT_EXPIRY_DAYS
)

env_ok=0; env_miss=0
for k in "${REF_ENV_KEYS[@]}"; do
  if grep -q "^${k}=" "${ENV_FILE}" 2>/dev/null; then
    env_ok=$((env_ok+1))
  else
    miss "${k}"
    env_miss=$((env_miss+1))
  fi
done

env_opt=0; env_opt_miss=0
for k in "${OPTIONAL_ENV_KEYS[@]}"; do
  if grep -q "^${k}=" "${ENV_FILE}" 2>/dev/null || grep -q "^# *${k}=" "${ENV_FILE}" 2>/dev/null; then
    env_opt=$((env_opt+1))
  else
    info "${k} (optional — not configured)"
    env_opt_miss=$((env_opt_miss+1))
  fi
done

if [[ ${env_miss} -eq 0 ]]; then
  ok "All ${env_ok} required keys present"
else
  echo -e "  ${DIM}${env_ok} ok, ${RED}${env_miss} missing${RST}"
fi
if [[ ${env_opt_miss} -gt 0 ]]; then
  echo -e "  ${DIM}${env_opt} optional configured, ${CYN}${env_opt_miss} not set${RST}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 2. Compose services
# ═════════════════════════════════════════════════════════════════════════════
hdr "Services"

REF_SERVICES=(init-certs postgres redis backend ocsp docs frontend)
for s in "${REF_SERVICES[@]}"; do
  if grep -qE "^  ${s}:" "${COMPOSE}"; then
    ok "${s}"
  else
    miss "${s}  ${DIM}service missing${RST}"
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
# 3. Certificate volume mounts
# ═════════════════════════════════════════════════════════════════════════════
hdr "Cert volumes"

declare -A CERT_EXPECT=(
  [backend]="certs:/certs"
  [ocsp]="certs:/certs"
  [docs]="certs:/etc/nginx/certs"
  [frontend]="certs:/etc/nginx/certs"
)
for s in backend ocsp docs frontend; do
  pat="${CERT_EXPECT[$s]}"
  if svc_block "$s" | grep -q "${pat}"; then
    ok "${s} → ${pat}"
  else
    miss "${s} → ${pat}  ${DIM}not mounted${RST}"
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
# 4. depends_on init-certs
# ═════════════════════════════════════════════════════════════════════════════
hdr "init-certs dependency"

for s in backend docs frontend; do
  if svc_block "$s" | grep -q "init-certs"; then
    ok "${s}"
  else
    miss "${s}  ${DIM}missing depends_on init-certs${RST}"
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
# 5. Port mappings (container-side)
# ═════════════════════════════════════════════════════════════════════════════
hdr "Ports"

declare -A PORT_EXPECT=(
  [backend]=8443
  [ocsp]=8081
  [docs]=443
  [frontend]=443
)
for s in backend ocsp docs frontend; do
  cp="${PORT_EXPECT[$s]}"
  if svc_block "$s" | grep -qE ":${cp}\"?\s*$"; then
    ok "${s} → :${cp}"
  else
    miss "${s} → expected container port ${cp}"
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
# 6. Backend env vars in compose
# ═════════════════════════════════════════════════════════════════════════════
hdr "Backend env"

REF_BE_VARS=(
  DATABASE_URL REDIS_URL
  MAZEVAULT_JWT_KEY MAZEVAULT_MASTER_KEY MAZEVAULT_SESSION_SECRET MAZEVAULT_TLS_CERT_PATH
  MAZEVAULT_ENV MAZEVAULT_ORCHESTRATOR_MODE APP_VERSION
  COOKIE_SECURE FRONTEND_URL ALLOWED_ORIGINS CORS_ALLOWED_ORIGINS OCSP_URL
  GIN_MODE RUN_MIGRATIONS LOG_LEVEL
  SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_FROM
  O365_EMAIL_ENABLED O365_TENANT_ID O365_CLIENT_ID O365_CLIENT_SECRET
  O365_SENDER_EMAIL O365_AUTH_METHOD
  MAZEVAULT_CUSTOMER_NAME MAZEVAULT_CUSTOMER_EMAIL MAZEVAULT_COMPANY_ID MAZEVAULT_REGION
  LICENSE_SERVER_URL BUILD_AUTH_SECRET ENABLE_LICENSE_CHECK
  AGENT_BINARY_GITHUB_TOKEN AGENT_BINARY_CACHE_DIR AGENT_BINARY_RELEASE_API_URL
  AGENT_ROLLOUT_PERCENTAGE AGENT_MAX_CONCURRENT_DOWNLOADS
  AGENT_DOWNLOAD_BASE_URL AGENT_VERSION
  MAZEVAULT_MODE PRIMARY_BACKEND_URL GATEWAY_BOOTSTRAP_TOKEN GATEWAY_NAME
  MAZEVAULT_GATEWAY_ENVIRONMENT MAZEVAULT_GATEWAY_ENVIRONMENTS MAZEVAULT_GATEWAY_ROLE MAZEVAULT_GATEWAY_STATE_FILE MAZEVAULT_VERSION
  MAZEVAULT_PRIMARY_ENVIRONMENTS
  MAZEVAULT_ACME_DNS_PROVIDER MAZEVAULT_ACME_DNS_API_TOKEN
  MAZEVAULT_KEYTAB_ENABLED MAZEVAULT_KEYTAB_MAX_SIZE_MB MAZEVAULT_KEYTAB_DEFAULT_EXPIRY_DAYS
)

BE_BLOCK=$(svc_block backend)
be_ok=0; be_miss=0
for v in "${REF_BE_VARS[@]}"; do
  if echo "${BE_BLOCK}" | grep -q "${v}"; then
    be_ok=$((be_ok+1))
  else
    miss "${v}"
    be_miss=$((be_miss+1))
  fi
done
if [[ ${be_miss} -eq 0 ]]; then
  ok "All ${be_ok} vars present"
else
  echo -e "  ${DIM}${be_ok} ok, ${RED}${be_miss} missing${RST}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 7. Volumes & networks
# ═════════════════════════════════════════════════════════════════════════════
hdr "Volumes & networks"

for v in certs pgdata backend_data; do
  if grep -qE "^  ${v}:" "${COMPOSE}"; then ok "vol ${v}"; else miss "vol ${v}"; fi
done
for n in internal frontend; do
  if grep -qE "^  ${n}:" "${COMPOSE}"; then ok "net ${n}"; else miss "net ${n}"; fi
done

# ═════════════════════════════════════════════════════════════════════════════
# 8. Healthchecks
# ═════════════════════════════════════════════════════════════════════════════
hdr "Healthchecks"

for s in postgres redis backend docs; do
  if svc_block "$s" | grep -q "healthcheck"; then
    ok "${s}"
  else
    warn "${s}  ${DIM}no healthcheck${RST}"
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BLD}═══════════════════════════════════════════════════════════${RST}"
if [[ ${ISSUES} -eq 0 ]]; then
  echo -e "  ${GRN}✔ Config matches reference — no drift detected${RST}"
else
  echo -e "  ${RED}✘ ${ISSUES} issue(s) found${RST} — review items above"
  echo -e "  ${DIM}Fix: re-run install-mazevault.sh or apply missing values manually${RST}"
fi
echo -e "${BLD}═══════════════════════════════════════════════════════════${RST}"

exit ${ISSUES}
