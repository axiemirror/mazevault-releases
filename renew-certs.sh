#!/bin/bash
# renew-certs.sh — TLS Certificate Rotation for MazeVault
# Validates new cert, backs up old, installs new, restarts services.
#
# Usage: ./renew-certs.sh <server.crt> <server.key> [ca.crt]
# Example: ./renew-certs.sh /tmp/new-cert.pem /tmp/new-key.pem /tmp/ca-chain.pem
#
# Version: 2.0.0
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/mazevault}"
CERT_VOLUME="mazevault-certs"
BACKUP_DIR="$INSTALL_DIR/backups/certs_$(date +%Y%m%d_%H%M%S)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

NEW_CERT="${1:-}"
NEW_KEY="${2:-}"
NEW_CA="${3:-}"

if [ -z "$NEW_CERT" ] || [ -z "$NEW_KEY" ]; then
    echo "Usage: $0 <server.crt> <server.key> [ca.crt]"
    echo "Example: $0 /tmp/new-cert.pem /tmp/new-key.pem /tmp/ca-chain.pem"
    exit 1
fi

# Detect container runtime
CONTAINER_CMD="podman"
if ! command -v podman &>/dev/null; then
    CONTAINER_CMD="docker"
fi

COMPOSE_CMD="$CONTAINER_CMD compose"
if ! $COMPOSE_CMD version &>/dev/null 2>&1; then
    COMPOSE_CMD="${CONTAINER_CMD}-compose"
fi

# 1. Validate new certificate
log_info "Validating new certificate..."
if ! openssl x509 -in "$NEW_CERT" -noout 2>/dev/null; then
    log_error "Invalid certificate: $NEW_CERT"
fi
if ! openssl rsa -in "$NEW_KEY" -check -noout 2>/dev/null; then
    log_error "Invalid private key: $NEW_KEY"
fi

CERT_MOD=$(openssl x509 -in "$NEW_CERT" -modulus -noout | md5sum)
KEY_MOD=$(openssl rsa -in "$NEW_KEY" -modulus -noout | md5sum)
if [ "$CERT_MOD" != "$KEY_MOD" ]; then
    log_error "Certificate and key do not match (modulus mismatch)!"
fi
log_info "✓ Certificate and key are valid and match."

# Show cert details
log_info "New certificate details:"
openssl x509 -in "$NEW_CERT" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null | sed 's/^/  /'

# Check expiry warning
if ! openssl x509 -in "$NEW_CERT" -noout -checkend 2592000 2>/dev/null; then
    log_warn "⚠ New certificate expires in less than 30 days!"
fi

# 2. Backup existing certificates
log_info "Backing up existing certificates to $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"
VOLUME_PATH=$($CONTAINER_CMD volume inspect "$CERT_VOLUME" --format '{{.Mountpoint}}' 2>/dev/null || echo "")
if [ -n "$VOLUME_PATH" ] && [ -d "$VOLUME_PATH" ]; then
    cp -a "$VOLUME_PATH/"* "$BACKUP_DIR/" 2>/dev/null || true
    log_info "✓ Backup created: $BACKUP_DIR"
else
    log_warn "Cannot access volume $CERT_VOLUME — skipping backup."
fi

# 3. Copy new certificates to volume
log_info "Copying new certificates..."
CERT_DIR="${VOLUME_PATH:-/tmp/mazevault-certs}"

sudo cp "$NEW_CERT" "$CERT_DIR/server.crt"
sudo cp "$NEW_KEY" "$CERT_DIR/server.key"
if [ -n "$NEW_CA" ]; then
    sudo cp "$NEW_CA" "$CERT_DIR/ca.crt"
    cat "$CERT_DIR/server.crt" "$CERT_DIR/ca.crt" | sudo tee "$CERT_DIR/ca-bundle.crt" > /dev/null
else
    log_warn "CA certificate not provided — ca-bundle.crt will contain only server cert."
    sudo cp "$CERT_DIR/server.crt" "$CERT_DIR/ca-bundle.crt"
fi

# 4. Permissions
sudo chown 70:70 "$CERT_DIR/server.key" 2>/dev/null || true
sudo chmod 600 "$CERT_DIR/server.key"
sudo chmod 644 "$CERT_DIR/server.crt"
[ -f "$CERT_DIR/ca.crt" ] && sudo chmod 644 "$CERT_DIR/ca.crt"
sudo chmod 644 "$CERT_DIR/ca-bundle.crt"
log_info "✓ Permissions set."

# 5. Restart services
log_info "Restarting services to load new certificates..."
cd "$INSTALL_DIR"
$COMPOSE_CMD restart mazevault-backend mazevault-frontend mazevault-ocsp mazevault-docs 2>/dev/null || \
    $COMPOSE_CMD restart client-backend client-frontend client-ocsp-responder 2>/dev/null || \
    log_warn "Services not restarted — do it manually."

# 6. Health check
log_info "Verifying HTTPS connectivity..."
sleep 5
if curl -sf -k https://localhost:443 > /dev/null 2>&1; then
    log_info "✓ Frontend HTTPS OK (port 443)"
else
    log_warn "Frontend HTTPS not yet responding — service may still be initializing."
fi
if curl -sf -k https://localhost:8443/api/v1/health > /dev/null 2>&1; then
    log_info "✓ Backend HTTPS OK (port 8443)"
else
    log_warn "Backend HTTPS not yet responding — service may still be initializing."
fi

log_info "=== Certificate rotation complete ==="
log_info "Previous certificates backed up to: $BACKUP_DIR"
