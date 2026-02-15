#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# MazeVault — Online Installer (GHCR pull)
# Usage: sudo ./install-mazevault.sh [--version v1.2.0] [--registry ghcr.io/axiemirror]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
VERSION="${MAZEVAULT_VERSION:-latest}"
REGISTRY="${MAZEVAULT_REGISTRY:-ghcr.io/axiemirror}"
INSTALL_DIR="${MAZEVAULT_INSTALL_DIR:-/opt/mazevault}"
DATA_DIR="${MAZEVAULT_DATA_DIR:-/opt/mazevault/data}"
COMPOSE_PROJECT="mazevault"

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  VERSION="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --dir)      INSTALL_DIR="$2"; shift 2 ;;
    --user)     GITHUB_USER="$2"; shift 2 ;;
    --token)    GITHUB_TOKEN="$2"; shift 2 ;;
    --domain)   MAZEVAULT_DOMAIN="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--version TAG] [--registry REGISTRY] [--dir PATH] [--user USERNAME] [--token TOKEN] [--domain DOMAIN]"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; RST='\033[0m'
info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[OK]${RST}    $*"; }
warn()  { echo -e "${YLW}[WARN]${RST}  $*"; }
die()   { echo -e "${RED}[ERR]${RST}   $*" >&2; exit 1; }

# ── Pre-flight ──────────────────────────────────────────────────────────────
info "MazeVault Online Installer — version ${VERSION}"

# Check root
[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root (sudo)."

# Detect container runtime
if command -v docker &>/dev/null; then
  RUNTIME="docker"
  COMPOSE_CMD="docker compose"
  if ! docker compose version &>/dev/null; then
    if command -v docker-compose &>/dev/null; then
      COMPOSE_CMD="docker-compose"
    else
      die "docker compose plugin or docker-compose not found."
    fi
  fi
elif command -v podman &>/dev/null; then
  RUNTIME="podman"
  COMPOSE_CMD="podman-compose"
  command -v podman-compose &>/dev/null || die "podman-compose not found."
else
  die "Neither docker nor podman found. Please install a container runtime first."
fi
ok "Container runtime: ${RUNTIME} (${COMPOSE_CMD})"

# ── Create directory structure ──────────────────────────────────────────────
info "Creating install directory: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"/{certs,config,data/{postgres,redis},logs,backups}
chmod 700 "${INSTALL_DIR}/certs" "${INSTALL_DIR}/data"

# ── Generate secrets ────────────────────────────────────────────────────────
generate_secret() { openssl rand -base64 "$1" 2>/dev/null | tr -d '\n/+='; }
generate_master_key() { openssl rand -base64 32; }

# ── Interactive Configuration ───────────────────────────────────────────────
if [[ -z "${MAZEVAULT_DOMAIN:-}" ]]; then
  read -p "Enter domain name (default: localhost): " INPUT_DOMAIN
  MAZEVAULT_DOMAIN="${INPUT_DOMAIN:-localhost}"
fi

if [[ -z "${MAZEVAULT_ORCHESTRATOR_MODE:-}" ]]; then
  read -p "Enable Orchestrator Mode? (y/N): " INPUT_ORCHESTRATOR
  if [[ "${INPUT_ORCHESTRATOR,,}" =~ ^(y|yes)$ ]]; then
    MAZEVAULT_ORCHESTRATOR_MODE="true"
  else
    MAZEVAULT_ORCHESTRATOR_MODE="false"
  fi
fi

ENV_FILE="${INSTALL_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  info ".env already exists — updating version to ${VERSION}..."
  # Update IMAGE_TAG and IMAGE_REGISTRY in existing .env
  if grep -q "IMAGE_TAG=" "${ENV_FILE}"; then
    sed -i "s|IMAGE_TAG=.*|IMAGE_TAG=${VERSION}|" "${ENV_FILE}"
  else
    echo "IMAGE_TAG=${VERSION}" >> "${ENV_FILE}"
  fi
  
  if grep -q "IMAGE_REGISTRY=" "${ENV_FILE}"; then
    sed -i "s|IMAGE_REGISTRY=.*|IMAGE_REGISTRY=${REGISTRY}|" "${ENV_FILE}"
  else
    echo "IMAGE_REGISTRY=${REGISTRY}" >> "${ENV_FILE}"
  fi

  # Ensure Orchestrator Mode is present
  if ! grep -q "MAZEVAULT_ORCHESTRATOR_MODE=" "${ENV_FILE}"; then
    echo "MAZEVAULT_ORCHESTRATOR_MODE=${MAZEVAULT_ORCHESTRATOR_MODE}" >> "${ENV_FILE}"
  fi

  # Ensure Domain is present/updated if provided
  if grep -q "MAZEVAULT_DOMAIN=" "${ENV_FILE}"; then
     # Only update if explicitly changed or needed? For now, let's respect existing unless empty
     :
  else
     echo "MAZEVAULT_DOMAIN=${MAZEVAULT_DOMAIN}" >> "${ENV_FILE}"
  fi

  ok "Updated .env with version ${VERSION}"
else
  info "Generating secrets and .env file..."
  
  # Calculate Allowed Origins
  if [[ "${MAZEVAULT_DOMAIN}" == "localhost" ]]; then
    ALLOWED_ORIGINS="http://localhost,https://localhost,http://localhost:3000,http://localhost:8080"
    COOKIE_SECURE="false"
    FRONTEND_URL="https://localhost"
  else
    ALLOWED_ORIGINS="http://${MAZEVAULT_DOMAIN},https://${MAZEVAULT_DOMAIN},http://${MAZEVAULT_DOMAIN}:3000,http://${MAZEVAULT_DOMAIN}:8080"
    COOKIE_SECURE="true"
    FRONTEND_URL="https://${MAZEVAULT_DOMAIN}"
  fi

  cat > "${ENV_FILE}" <<ENVEOF
# ── MazeVault Configuration ─────────────────────────────────
# Generated by install-mazevault.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)

# Image versions
IMAGE_REGISTRY=${REGISTRY}
IMAGE_TAG=${VERSION}

# Environment
# Local deployment flag
#LOCAL_DEPLOYMENT=true
MAZEVAULT_ENV=production
MAZEVAULT_ORCHESTRATOR_MODE=${MAZEVAULT_ORCHESTRATOR_MODE}
GIN_MODE=release

# Domain & Networking
MAZEVAULT_DOMAIN=${MAZEVAULT_DOMAIN}
FRONTEND_URL=${FRONTEND_URL}
OCSP_URL="http://ocsp-responder:8081"


# Customer name for local production deployment
MAZEVAULT_CUSTOMER_NAME="Customer Name"
 # REQUIRED: Contact email (for license registration and notifications)
MAZEVAULT_CUSTOMER_EMAIL="Customer email"
# REQUIRED: Company ID (IČO) or VAT ID (DIČ) - at least one must be provided
MAZEVAULT_COMPANY_ID=12345678
# MAZEVAULT_VAT_ID=CZ12345678  # Alternative to companyId

# Database
POSTGRES_USER=mazevault
POSTGRES_PASSWORD=$(generate_secret 32)
POSTGRES_DB=mazevault
DATABASE_URL=postgres://mazevault:\${POSTGRES_PASSWORD}@postgres:5432/mazevault?sslmode=disable
RUN_MIGRATIONS=true

# Redis
REDIS_PASSWORD=$(generate_secret 24)

# Application secrets
JWT_SECRET=$(generate_secret 48)
MASTER_KEY=$(generate_master_key)
SESSION_SECRET=$(generate_secret 32)
# JWT signing key (separate from master key)
MAZEVAULT_JWT_KEY=$(generate_secret 32)

# TLS (leave empty to auto-generate self-signed)
MAZEVAULT_TLS_ENABLED=true
MAZEVAULT_TLS_SKIP_INIT=false
MAZEVAULT_TLS_CERT_PATH=/certs
COOKIE_SECURE=${COOKIE_SECURE}
ALLOWED_ORIGINS=${ALLOWED_ORIGINS}
CORS_ALLOWED_ORIGINS=${ALLOWED_ORIGINS}
# TLS_CERT_FILE=
# TLS_KEY_FILE=

# HTTPS port mapping
FRONTEND_PORT=443
BACKEND_PORT=8443
 
# OPTIONAL: Unique instance identifier (auto-generated if not set)
#MAZEVAULT_INSTANCE_ID=(uuid generate32)

# OPTIONAL: Geographic region for license compliance (default: EU)
# Options: EU, US, APAC
MAZEVAULT_REGION=EU

# MazeVault License Configuration
# ============================================================================
# LICENSE SERVER CONFIGURATION
# ============================================================================
# License server endpoints
LICENSE_SERVER_URL=https://mazevault-license-server-811835508818.europe-west1.run.app
# Enable license checking
ENABLE_LICENSE_CHECK=true
# Build Authentication Secret - SAME FOR ALL BUILDS
# Used ONLY during initial license enrollment
BUILD_AUTH_SECRET="admin only"
ENVEOF
  chmod 600 "${ENV_FILE}"
  ok "Generated ${ENV_FILE}"
fi

# ── Write docker-compose.yml ────────────────────────────────────────────────
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
info "Writing ${COMPOSE_FILE}..."
cat > "${COMPOSE_FILE}" <<'COMPOSEEOF'
# MazeVault Production Compose — HTTPS-first
# Generated by install-mazevault.sh

services:
  init-certs:
    image: ${IMAGE_REGISTRY}/mazevault-init-certs:${IMAGE_TAG}
    restart: "no"
    volumes:
      - certs:/certs
    environment:
      - MAZEVAULT_TLS_SKIP_INIT=${MAZEVAULT_TLS_SKIP_INIT:-false}
      - MAZEVAULT_DOMAIN=${MAZEVAULT_DOMAIN:-localhost}
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - internal
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: >
      redis-server
      --requirepass ${REDIS_PASSWORD}
      --maxmemory 256mb
      --maxmemory-policy allkeys-lru
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - internal
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  backend:
    image: ${IMAGE_REGISTRY}/mazevault-backend:${IMAGE_TAG}
    restart: unless-stopped
    depends_on:
      init-certs:
        condition: service_completed_successfully
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      # App settings
      DATABASE_URL: ${DATABASE_URL}
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      OCSP_URL: ${OCSP_URL:-http://ocsp-responder:8081}
      MAZEVAULT_ENV: ${MAZEVAULT_ENV}
      MAZEVAULT_ORCHESTRATOR_MODE: ${MAZEVAULT_ORCHESTRATOR_MODE}
      FRONTEND_URL: ${FRONTEND_URL}
      GIN_MODE: ${GIN_MODE:-release}
      RUN_MIGRATIONS: ${RUN_MIGRATIONS:-true}
      #MAZEVAULT_INSTANCE_ID: ${MAZEVAULT_INSTANCE_ID}
      #Secrets
      MAZEVAULT_JWT_KEY: ${JWT_SECRET}
      MAZEVAULT_MASTER_KEY: ${MASTER_KEY}
      MAZEVAULT_SESSION_SECRET: ${SESSION_SECRET}
      # TLS
      MAZEVAULT_TLS_CERT_PATH: ${MAZEVAULT_TLS_CERT_PATH:-/certs}
      PORT: ${BACKEND_PORT:-8443}
      COOKIE_SECURE: ${COOKIE_SECURE}
      ALLOWED_ORIGINS: ${ALLOWED_ORIGINS}
      CORS_ALLOWED_ORIGINS: ${CORS_ALLOWED_ORIGINS}
      # Customer
      MAZEVAULT_CUSTOMER_NAME: ${MAZEVAULT_CUSTOMER_NAME}
      MAZEVAULT_CUSTOMER_EMAIL: ${MAZEVAULT_CUSTOMER_EMAIL}
      MAZEVAULT_COMPANY_ID: ${MAZEVAULT_COMPANY_ID}
      MAZEVAULT_REGION: ${MAZEVAULT_REGION:-EU}
      #License
      LICENSE_SERVER_URL: ${LICENSE_SERVER_URL}
      BUILD_AUTH_SECRET: ${BUILD_AUTH_SECRET}
      ENABLE_LICENSE_CHECK: ${ENABLE_LICENSE_CHECK:-true}
    volumes:
      - certs:/certs:ro
    ports:
      - "${BACKEND_PORT:-8443}:8443"
    healthcheck:
      test: ["CMD", "curl", "-f", "-k", "https://localhost:8443/api/v1/health"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 90s
    networks:
      - internal
      - frontend
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  ocsp:
    image: ${IMAGE_REGISTRY}/mazevault-ocsp:${IMAGE_TAG}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_started
      redis:
        condition: service_started
    environment:
      DB_CONNECTION: ${DATABASE_URL}
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      MAZEVAULT_MASTER_KEY: ${MASTER_KEY}
      MAZEVAULT_TLS_CERT_PATH: /certs
      SERVER_PORT: 8081
    ports:
      - "8081:8081"
    networks:
      - internal
      - frontend
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  docs:
    image: ${IMAGE_REGISTRY}/mazevault-docs:${IMAGE_TAG}
    restart: unless-stopped
    ports:
      - "8080:80"
    networks:
      - frontend
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  frontend:
    image: ${IMAGE_REGISTRY}/mazevault-frontend:${IMAGE_TAG}
    restart: unless-stopped
    depends_on:
      init-certs:
        condition: service_completed_successfully
      backend:
        condition: service_healthy
    volumes:
      - certs:/etc/nginx/certs:ro
    environment:
      BACKEND_HOST: backend
      MAZEVAULT_DOMAIN: ${MAZEVAULT_DOMAIN}
      MAZEVAULT_ORCHESTRATOR_MODE: ${MAZEVAULT_ORCHESTRATOR_MODE}
      VITE_API_URL: https://${MAZEVAULT_DOMAIN}:8443
    ports:
      - "${FRONTEND_PORT:-443}:443"
    networks:
      - frontend
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  certs:
  pgdata:
  backend_data:

networks:
  internal:
    driver: bridge
    internal: true
  frontend:
    driver: bridge
COMPOSEEOF
ok "Compose file written"

# ── Pull images ─────────────────────────────────────────────────────────────
info "Pulling images from ${REGISTRY}..."
cd "${INSTALL_DIR}"

# Try to login if credentials are provided
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  if [[ -z "${GITHUB_USER:-}" ]]; then
    warn "GITHUB_TOKEN is set but --user is missing. Cannot auto-login."
    warn "Please run: echo \$GITHUB_TOKEN | $RUNTIME login $REGISTRY -u YOUR_USERNAME --password-stdin"
  else
    info "Logging in to $REGISTRY as $GITHUB_USER..."
    echo "$GITHUB_TOKEN" | $RUNTIME login "$REGISTRY" -u "$GITHUB_USER" --password-stdin || warn "Login failed, continuing..."
  fi
fi

# Export vars for compose
set -a; source "${ENV_FILE}"; set +a

${COMPOSE_CMD} -p "${COMPOSE_PROJECT}" pull || die "Failed to pull images. If using private registry, ensure you are logged in."
ok "All images pulled"

# ── Start services ──────────────────────────────────────────────────────────
info "Starting MazeVault..."
${COMPOSE_CMD} -p "${COMPOSE_PROJECT}" up -d
ok "MazeVault is starting up"

# ── Health check ────────────────────────────────────────────────────────────
info "Waiting for services to become healthy..."
TRIES=0; MAX=30
while [[ $TRIES -lt $MAX ]]; do
  if curl -sk "https://localhost:${FRONTEND_PORT:-443}" &>/dev/null; then
    ok "Frontend is responding on https://localhost:${FRONTEND_PORT:-443}"
    break
  fi
  TRIES=$((TRIES+1))
  sleep 2
done
if [[ $TRIES -ge $MAX ]]; then
  warn "Frontend not responding yet — check logs with: cd ${INSTALL_DIR} && ${COMPOSE_CMD} logs"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
# Resolve display domain from .env
DISPLAY_DOMAIN="${MAZEVAULT_DOMAIN:-localhost}"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  ✅ MazeVault installed successfully!"
echo ""
echo "  URL:      https://${DISPLAY_DOMAIN}:${FRONTEND_PORT:-443}"
echo "  API:      https://${DISPLAY_DOMAIN}:${BACKEND_PORT:-8443}/api/v1"
echo "  Install:  ${INSTALL_DIR}"
echo "  Config:   ${ENV_FILE}"
echo ""
echo "  Manage:   cd ${INSTALL_DIR} && ${COMPOSE_CMD} [logs|stop|restart]"
echo "  Import cert: ${INSTALL_DIR}/import-cert.sh --help"
echo "═══════════════════════════════════════════════════════════════"

