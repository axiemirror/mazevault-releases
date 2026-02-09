#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# MazeVault — Upgrade Script
# Usage: sudo ./upgrade-mazevault.sh [--version v1.3.0] [--dir /opt/mazevault]
#
# Performs: backup → pull/load images → rolling restart → health check
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="${MAZEVAULT_INSTALL_DIR:-/opt/mazevault}"
TARGET_VERSION="${1:-}"
COMPOSE_PROJECT="mazevault"
BACKUP_DIR="${INSTALL_DIR}/backups"

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) TARGET_VERSION="$2"; shift 2 ;;
    --dir)     INSTALL_DIR="$2"; shift 2 ;;
    --offline) OFFLINE_BUNDLE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 --version TAG [--dir PATH] [--offline /path/to/bundle.tar.gz]"
      exit 0 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# ── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; RST='\033[0m'
info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[OK]${RST}    $*"; }
warn()  { echo -e "${YLW}[WARN]${RST}  $*"; }
die()   { echo -e "${RED}[ERR]${RST}   $*" >&2; exit 1; }

# ── Pre-flight ──────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || die "Run as root."
[[ -d "${INSTALL_DIR}" ]] || die "Install dir ${INSTALL_DIR} not found."
[[ -f "${INSTALL_DIR}/.env" ]] || die ".env not found in ${INSTALL_DIR}"

# Detect runtime
if command -v docker &>/dev/null; then
  COMPOSE_CMD="docker compose"
  docker compose version &>/dev/null || COMPOSE_CMD="docker-compose"
elif command -v podman &>/dev/null; then
  COMPOSE_CMD="podman-compose"
else
  die "No container runtime found."
fi

cd "${INSTALL_DIR}"
set -a; source .env; set +a

CURRENT_VERSION="${IMAGE_TAG:-unknown}"
[[ -n "${TARGET_VERSION}" ]] || die "Target version required. Use --version v1.3.0"

info "Upgrading MazeVault: ${CURRENT_VERSION} → ${TARGET_VERSION}"

# ── Step 1: Pre-upgrade backup ─────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/pre-upgrade_${TIMESTAMP}"
mkdir -p "${BACKUP_PATH}"

info "Backing up configuration..."
cp .env "${BACKUP_PATH}/.env"
cp docker-compose.yml "${BACKUP_PATH}/docker-compose.yml" 2>/dev/null || true
echo "${CURRENT_VERSION}" > "${BACKUP_PATH}/version.txt"

info "Backing up database..."
${COMPOSE_CMD} -p "${COMPOSE_PROJECT}" exec -T postgres \
  pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" | gzip > "${BACKUP_PATH}/db_backup.sql.gz" 2>/dev/null || {
  warn "Database backup failed — continuing (non-fatal)"
}

info "Backing up certificates..."
cp -r certs/ "${BACKUP_PATH}/certs/" 2>/dev/null || true

ok "Backup saved to ${BACKUP_PATH}"

# ── Step 2: Pull/load new images ───────────────────────────────────────────
if [[ -n "${OFFLINE_BUNDLE:-}" ]]; then
  info "Loading images from offline bundle: ${OFFLINE_BUNDLE}"
  TMPDIR=$(mktemp -d)
  tar xzf "${OFFLINE_BUNDLE}" -C "${TMPDIR}"
  for tarball in "${TMPDIR}"/images/*.tar.gz; do
    [[ -f "$tarball" ]] || continue
    info "  Loading $(basename "$tarball")..."
    docker load < <(gunzip -c "$tarball")
  done
  rm -rf "${TMPDIR}"
else
  info "Pulling images for ${TARGET_VERSION}..."
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${TARGET_VERSION}/" .env
  set -a; source .env; set +a
  ${COMPOSE_CMD} -p "${COMPOSE_PROJECT}" pull
fi

# ── Step 3: Update .env version ────────────────────────────────────────────
sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${TARGET_VERSION}/" .env

# ── Step 4: Rolling restart ────────────────────────────────────────────────
info "Restarting services..."
${COMPOSE_CMD} -p "${COMPOSE_PROJECT}" up -d --remove-orphans

# ── Step 5: Health check ───────────────────────────────────────────────────
info "Verifying health..."
TRIES=0; MAX=30
while [[ $TRIES -lt $MAX ]]; do
  if curl -sk "https://localhost:${FRONTEND_PORT:-443}/api/v1/health" 2>/dev/null | grep -q "ok"; then
    ok "Services healthy after upgrade"
    break
  fi
  TRIES=$((TRIES+1)); sleep 2
done
if [[ $TRIES -ge $MAX ]]; then
  warn "Health check failed — consider rollback: ./rollback-mazevault.sh ${BACKUP_PATH}"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  ✅ Upgrade complete: ${CURRENT_VERSION} → ${TARGET_VERSION}"
echo "  Rollback: sudo ./rollback-mazevault.sh ${BACKUP_PATH}"
echo "═══════════════════════════════════════════════════════════════"
