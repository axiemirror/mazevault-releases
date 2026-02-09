#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# MazeVault — Air-Gapped / Offline Installer
# Usage: sudo ./install-mazevault-offline.sh [--dir /opt/mazevault]
#
# Expects to be run from inside the extracted tarball directory containing:
#   images/    — *.tar.gz Docker image archives
#   docker-compose.yml
#   .env.example
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="${MAZEVAULT_INSTALL_DIR:-/opt/mazevault}"
COMPOSE_PROJECT="mazevault"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--dir PATH]"
      echo "Run from inside the extracted offline bundle directory."
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
info "MazeVault Offline Installer"
[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root (sudo)."

# Verify bundle contents
[[ -d "${SCRIPT_DIR}/images" ]] || die "images/ directory not found. Run from extracted tarball."

# Detect container runtime
if command -v docker &>/dev/null; then
  RUNTIME="docker"
  COMPOSE_CMD="docker compose"
  docker compose version &>/dev/null || {
    command -v docker-compose &>/dev/null && COMPOSE_CMD="docker-compose" || die "docker compose not found"
  }
elif command -v podman &>/dev/null; then
  RUNTIME="podman"
  COMPOSE_CMD="podman-compose"
  command -v podman-compose &>/dev/null || die "podman-compose not found"
else
  die "Neither docker nor podman found."
fi
ok "Container runtime: ${RUNTIME}"

# ── Load images ─────────────────────────────────────────────────────────────
info "Loading Docker images from tarball..."
for tarball in "${SCRIPT_DIR}"/images/*.tar.gz; do
  [[ -f "$tarball" ]] || continue
  info "  Loading $(basename "$tarball")..."
  ${RUNTIME} load < <(gunzip -c "$tarball")
done
ok "All images loaded"

# ── Create directory structure ──────────────────────────────────────────────
info "Creating install directory: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"/{certs,config,data/{postgres,redis},logs,backups}
chmod 700 "${INSTALL_DIR}/certs" "${INSTALL_DIR}/data"

# ── Copy compose + scripts ──────────────────────────────────────────────────
if [[ -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
  cp "${SCRIPT_DIR}/docker-compose.yml" "${INSTALL_DIR}/"
fi
for script in install-mazevault.sh install-mazevault-offline.sh upgrade-mazevault.sh rollback-mazevault.sh import-cert.sh renew-certs.sh; do
  if [[ -f "${SCRIPT_DIR}/${script}" ]]; then
    cp "${SCRIPT_DIR}/${script}" "${INSTALL_DIR}/"
    chmod +x "${INSTALL_DIR}/${script}"
  fi
done

# ── Generate .env ───────────────────────────────────────────────────────────
generate_secret() { openssl rand -base64 "$1" 2>/dev/null | tr -d '\n/+='; }

ENV_FILE="${INSTALL_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  info "Generating secrets..."
  if [[ -f "${SCRIPT_DIR}/.env.example" ]]; then
    cp "${SCRIPT_DIR}/.env.example" "${ENV_FILE}"
    # Replace placeholder secrets with real ones
    sed -i "s|__POSTGRES_PASSWORD__|$(generate_secret 32)|g" "${ENV_FILE}"
    sed -i "s|__REDIS_PASSWORD__|$(generate_secret 24)|g"    "${ENV_FILE}"
    sed -i "s|__JWT_SECRET__|$(generate_secret 48)|g"        "${ENV_FILE}"
    sed -i "s|__MASTER_KEY__|$(generate_secret 32)|g"        "${ENV_FILE}"
    sed -i "s|__SESSION_SECRET__|$(generate_secret 32)|g"    "${ENV_FILE}"
  else
    # Fallback: generate minimal .env
    cat > "${ENV_FILE}" <<ENVEOF
IMAGE_REGISTRY=ghcr.io/axiemirror
IMAGE_TAG=latest
POSTGRES_USER=mazevault
POSTGRES_PASSWORD=$(generate_secret 32)
POSTGRES_DB=mazevault
REDIS_PASSWORD=$(generate_secret 24)
JWT_SECRET=$(generate_secret 48)
MASTER_KEY=$(generate_secret 32)
SESSION_SECRET=$(generate_secret 32)
MAZEVAULT_TLS_SKIP_INIT=false
MAZEVAULT_DOMAIN=localhost
FRONTEND_PORT=443
BACKEND_PORT=8443
ENVEOF
  fi
  # DATABASE_URL uses the generated password
  if ! grep -q "^DATABASE_URL=" "${ENV_FILE}"; then
    PG_PASS=$(grep '^POSTGRES_PASSWORD=' "${ENV_FILE}" | cut -d= -f2)
    echo "DATABASE_URL=postgres://mazevault:${PG_PASS}@postgres:5432/mazevault?sslmode=disable" >> "${ENV_FILE}"
  fi
  chmod 600 "${ENV_FILE}"
  ok "Generated ${ENV_FILE}"
else
  warn ".env already exists — skipping"
fi

# ── Start ───────────────────────────────────────────────────────────────────
info "Starting MazeVault (offline)..."
cd "${INSTALL_DIR}"
set -a; source "${ENV_FILE}"; set +a
${COMPOSE_CMD} -p "${COMPOSE_PROJECT}" up -d
ok "MazeVault is starting"

# ── Health check ────────────────────────────────────────────────────────────
info "Waiting for services..."
TRIES=0; MAX=30
while [[ $TRIES -lt $MAX ]]; do
  if curl -sk "https://localhost:${FRONTEND_PORT:-443}" &>/dev/null; then
    ok "Frontend responding on https://localhost:${FRONTEND_PORT:-443}"
    break
  fi
  TRIES=$((TRIES+1)); sleep 2
done
[[ $TRIES -ge $MAX ]] && warn "Frontend not responding — check: cd ${INSTALL_DIR} && ${COMPOSE_CMD} logs"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  ✅ MazeVault installed (offline) successfully!"
echo "  URL: https://localhost:${FRONTEND_PORT:-443}"
echo "  Dir: ${INSTALL_DIR}"
echo "═══════════════════════════════════════════════════════════════"
