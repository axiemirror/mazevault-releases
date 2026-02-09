#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# MazeVault — Rollback Script
# Usage: sudo ./rollback-mazevault.sh /opt/mazevault/backups/pre-upgrade_20260115_123456
#
# Restores: .env, docker-compose, database, certificates → restart
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="${MAZEVAULT_INSTALL_DIR:-/opt/mazevault}"
COMPOSE_PROJECT="mazevault"

# ── Parse args ──────────────────────────────────────────────────────────────
BACKUP_PATH="${1:-}"
[[ $# -gt 0 ]] && shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)  INSTALL_DIR="$2"; shift 2 ;;
    --skip-db) SKIP_DB=true; shift ;;
    --help|-h)
      echo "Usage: $0 BACKUP_PATH [--dir PATH] [--skip-db]"
      echo "  BACKUP_PATH: directory from a previous upgrade backup"
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
[[ -n "${BACKUP_PATH}" ]] || die "Backup path required. Usage: $0 BACKUP_PATH"
[[ -d "${BACKUP_PATH}" ]] || die "Backup directory not found: ${BACKUP_PATH}"
[[ -f "${BACKUP_PATH}/.env" ]] || die "No .env in backup directory"

# Detect runtime
if command -v docker &>/dev/null; then
  COMPOSE_CMD="docker compose"
  docker compose version &>/dev/null || COMPOSE_CMD="docker-compose"
elif command -v podman &>/dev/null; then
  COMPOSE_CMD="podman-compose"
else
  die "No container runtime found."
fi

OLD_VERSION=$(cat "${BACKUP_PATH}/version.txt" 2>/dev/null || echo "unknown")
info "Rolling back MazeVault to version: ${OLD_VERSION}"
info "Backup source: ${BACKUP_PATH}"

# ── Step 1: Stop services ──────────────────────────────────────────────────
cd "${INSTALL_DIR}"
info "Stopping services..."
${COMPOSE_CMD} -p "${COMPOSE_PROJECT}" down || warn "Services may already be stopped"

# ── Step 2: Restore configuration ──────────────────────────────────────────
info "Restoring .env..."
cp "${BACKUP_PATH}/.env" "${INSTALL_DIR}/.env"
chmod 600 "${INSTALL_DIR}/.env"

if [[ -f "${BACKUP_PATH}/docker-compose.yml" ]]; then
  info "Restoring docker-compose.yml..."
  cp "${BACKUP_PATH}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
fi

# ── Step 3: Restore certificates ────────────────────────────────────────────
if [[ -d "${BACKUP_PATH}/certs" ]]; then
  info "Restoring certificates..."
  cp -r "${BACKUP_PATH}/certs/"* "${INSTALL_DIR}/certs/" 2>/dev/null || true
  chmod 600 "${INSTALL_DIR}/certs/"*.key 2>/dev/null || true
fi

# ── Step 4: Restore database ───────────────────────────────────────────────
set -a; source "${INSTALL_DIR}/.env"; set +a

if [[ "${SKIP_DB:-false}" != "true" ]] && [[ -f "${BACKUP_PATH}/db_backup.sql.gz" ]]; then
  info "Restoring database (this will DROP and recreate)..."

  # Start only postgres
  ${COMPOSE_CMD} -p "${COMPOSE_PROJECT}" up -d postgres
  sleep 5  # wait for postgres to be ready

  # Drop and restore
  ${COMPOSE_CMD} -p "${COMPOSE_PROJECT}" exec -T postgres \
    psql -U "${POSTGRES_USER}" -c "DROP DATABASE IF EXISTS ${POSTGRES_DB};" 2>/dev/null || true
  ${COMPOSE_CMD} -p "${COMPOSE_PROJECT}" exec -T postgres \
    psql -U "${POSTGRES_USER}" -c "CREATE DATABASE ${POSTGRES_DB};" 2>/dev/null || true

  gunzip -c "${BACKUP_PATH}/db_backup.sql.gz" | \
    ${COMPOSE_CMD} -p "${COMPOSE_PROJECT}" exec -T postgres \
    psql -U "${POSTGRES_USER}" "${POSTGRES_DB}"

  ok "Database restored"
else
  if [[ "${SKIP_DB:-false}" == "true" ]]; then
    info "Skipping database restore (--skip-db)"
  else
    warn "No database backup found — skipping DB restore"
  fi
fi

# ── Step 5: Pull old images and restart ─────────────────────────────────────
info "Starting services with rolled-back configuration..."
${COMPOSE_CMD} -p "${COMPOSE_PROJECT}" up -d

# ── Step 6: Health check ───────────────────────────────────────────────────
info "Verifying health..."
TRIES=0; MAX=30
while [[ $TRIES -lt $MAX ]]; do
  if curl -sk "https://localhost:${FRONTEND_PORT:-443}" &>/dev/null; then
    ok "Services healthy after rollback"
    break
  fi
  TRIES=$((TRIES+1)); sleep 2
done
[[ $TRIES -ge $MAX ]] && warn "Health check timed out — check: ${COMPOSE_CMD} logs"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  ✅ Rollback complete → ${OLD_VERSION}"
echo "═══════════════════════════════════════════════════════════════"
