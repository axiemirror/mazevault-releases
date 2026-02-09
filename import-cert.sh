#!/bin/bash
# import-cert.sh — Universal customer certificate import for MazeVault
# Automatically detects format, extracts cert/key/chain, converts
# to canonical files (server.crt, server.key, ca.crt, ca-bundle.crt)
# and restarts services.
#
# Usage:
#   ./import-cert.sh server.pfx                        # PFX/PKCS#12
#   ./import-cert.sh cert.pem key.pem                  # Separate PEM files
#   ./import-cert.sh cert.pem key.pem ca-chain.pem     # PEM + CA chain
#   ./import-cert.sh fullchain.pem key.pem             # PEM bundle + key
#   ./import-cert.sh cert.der key.pem                  # DER cert + PEM key
#   ./import-cert.sh chain.p7b key.pem                 # PKCS7 chain + key
#
# Options:
#   --password <pass>     Password for PFX/encrypted key (or interactive prompt)
#   --no-restart          Don't restart services after import
#   --dry-run             Validate only, no file copy
#   --install-dir <path>  Installation directory (default: /opt/mazevault)
#
# Version: 2.0.0
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/mazevault}"
CERT_VOLUME="mazevault-certs"
DO_RESTART=true
DRY_RUN=false
PFX_PASSWORD=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# ── Parse arguments ──
INPUT_FILES=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --password)    PFX_PASSWORD="$2"; shift 2 ;;
        --no-restart)  DO_RESTART=false; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [options] <file> [file] [file]"
            echo ""
            echo "Examples:"
            echo "  $0 server.pfx                         # PFX (contains everything)"
            echo "  $0 my-cert.crt my-key.key              # Any PEM file names"
            echo "  $0 my-cert.crt my-key.key chain.crt    # Cert + key + CA chain"
            echo "  $0 fullchain.pem privkey.pem            # Let's Encrypt style"
            echo "  $0 cert.der key.pem                    # DER certificate + PEM key"
            echo "  $0 --password 'pass123' bundle.p12     # PFX with password"
            echo ""
            echo "Options:"
            echo "  --password <pass>    Password for PFX/encrypted key"
            echo "  --no-restart         Don't restart services after import"
            echo "  --dry-run            Validate only, no file copy"
            echo "  --install-dir <path> Installation directory (default: /opt/mazevault)"
            exit 0
            ;;
        -*) log_error "Unknown parameter: $1" ;;
        *)  INPUT_FILES+=("$1"); shift ;;
    esac
done

if [ ${#INPUT_FILES[@]} -eq 0 ]; then
    log_error "No file provided. Use --help for usage information."
fi

# ── Working directory ──
WORK_DIR=$(mktemp -d /tmp/mazevault-cert-import.XXXXXX)
trap "rm -rf '$WORK_DIR'" EXIT

# ══════════════════════════════════════════════════════════════
# Format detection
# ══════════════════════════════════════════════════════════════
detect_format() {
    local file="$1"
    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    # PFX/PKCS#12 — binary format
    if [[ "$ext" == "pfx" || "$ext" == "p12" ]]; then
        echo "pkcs12"; return
    fi

    # PKCS#7/P7B
    if [[ "$ext" == "p7b" || "$ext" == "p7c" ]]; then
        echo "pkcs7"; return
    fi

    # PEM vs DER — content-based detection
    if file "$file" | grep -qi "text\|ASCII\|PEM"; then
        if grep -q "PRIVATE KEY" "$file" 2>/dev/null; then
            if grep -q "ENCRYPTED" "$file" 2>/dev/null; then
                echo "pem-encrypted-key"
            else
                echo "pem-key"
            fi
        elif grep -q "PKCS7" "$file" 2>/dev/null; then
            echo "pkcs7-pem"
        elif grep -q "CERTIFICATE" "$file" 2>/dev/null; then
            local cert_count
            cert_count=$(grep -c "BEGIN CERTIFICATE" "$file")
            if [ "$cert_count" -gt 1 ]; then
                echo "pem-bundle"
            else
                echo "pem-cert"
            fi
        else
            echo "unknown"
        fi
    else
        # Binary file — try DER
        if openssl x509 -inform DER -in "$file" -noout 2>/dev/null; then
            echo "der-cert"
        elif openssl rsa -inform DER -in "$file" -noout 2>/dev/null; then
            echo "der-key"
        elif openssl pkcs12 -in "$file" -noout -passin pass: 2>/dev/null || \
             openssl pkcs12 -in "$file" -noout -passin pass:"$PFX_PASSWORD" 2>/dev/null; then
            echo "pkcs12"
        else
            echo "unknown"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════
# Extract from PFX/PKCS#12
# ══════════════════════════════════════════════════════════════
extract_pkcs12() {
    local file="$1"
    local pass_args=()

    if [ -n "$PFX_PASSWORD" ]; then
        pass_args=(-passin "pass:$PFX_PASSWORD")
    else
        if openssl pkcs12 -in "$file" -noout -passin pass: 2>/dev/null; then
            pass_args=(-passin pass:)
        else
            log_info "PFX file is password-protected. Enter password:"
            read -rs PFX_PASSWORD
            echo
            pass_args=(-passin "pass:$PFX_PASSWORD")
        fi
    fi

    log_step "Extracting certificate from PFX..."
    openssl pkcs12 -in "$file" "${pass_args[@]}" -clcerts -nokeys -out "$WORK_DIR/server.crt" 2>/dev/null || \
        log_error "Cannot extract certificate from PFX. Wrong password?"

    log_step "Extracting private key from PFX..."
    openssl pkcs12 -in "$file" "${pass_args[@]}" -nocerts -nodes -out "$WORK_DIR/server.key" 2>/dev/null || \
        log_error "Cannot extract private key from PFX."

    log_step "Extracting CA chain from PFX..."
    if openssl pkcs12 -in "$file" "${pass_args[@]}" -cacerts -nokeys -out "$WORK_DIR/ca.crt" 2>/dev/null; then
        if [ ! -s "$WORK_DIR/ca.crt" ] || ! grep -q "CERTIFICATE" "$WORK_DIR/ca.crt"; then
            rm -f "$WORK_DIR/ca.crt"
            log_warn "PFX does not contain CA chain — ca.crt will not be created."
        fi
    fi
}

# ══════════════════════════════════════════════════════════════
# Split PEM bundle (cert+chain in one file)
# ══════════════════════════════════════════════════════════════
split_pem_bundle() {
    local file="$1"

    log_step "Splitting PEM bundle into leaf cert and CA chain..."

    awk '/-----BEGIN CERTIFICATE-----/{n++} n==1' "$file" > "$WORK_DIR/server.crt"
    awk '/-----BEGIN CERTIFICATE-----/{n++} n>=2' "$file" > "$WORK_DIR/ca.crt"

    if [ ! -s "$WORK_DIR/ca.crt" ]; then
        rm -f "$WORK_DIR/ca.crt"
        log_warn "PEM bundle contains only one certificate — likely self-signed."
    fi
}

# ══════════════════════════════════════════════════════════════
# Convert DER → PEM
# ══════════════════════════════════════════════════════════════
convert_der_cert() {
    local file="$1"
    log_step "Converting DER certificate to PEM..."
    openssl x509 -inform DER -in "$file" -outform PEM -out "$WORK_DIR/server.crt" || \
        log_error "Cannot convert DER certificate."
}

convert_der_key() {
    local file="$1"
    log_step "Converting DER key to PEM..."
    openssl rsa -inform DER -in "$file" -outform PEM -out "$WORK_DIR/server.key" || \
        log_error "Cannot convert DER key."
}

# ══════════════════════════════════════════════════════════════
# Extract from PKCS#7/P7B
# ══════════════════════════════════════════════════════════════
extract_pkcs7() {
    local file="$1"
    local inform="PEM"

    if file "$file" | grep -qi "text\|ASCII\|PEM"; then
        inform="PEM"
    else
        inform="DER"
    fi

    log_step "Extracting certificates from PKCS#7..."
    local all_certs="$WORK_DIR/p7b_all.pem"
    openssl pkcs7 -in "$file" -inform "$inform" -print_certs -out "$all_certs" 2>/dev/null || \
        log_error "Cannot extract certificates from PKCS#7/P7B file."

    awk '/-----BEGIN CERTIFICATE-----/{n++} n==1' "$all_certs" > "$WORK_DIR/server.crt"
    awk '/-----BEGIN CERTIFICATE-----/{n++} n>=2' "$all_certs" > "$WORK_DIR/ca.crt"
    [ ! -s "$WORK_DIR/ca.crt" ] && rm -f "$WORK_DIR/ca.crt"

    log_warn "PKCS#7/P7B does not contain a private key — provide it as a second file."
}

# ══════════════════════════════════════════════════════════════
# Decrypt encrypted PEM key
# ══════════════════════════════════════════════════════════════
decrypt_pem_key() {
    local file="$1"
    log_step "Decrypting encrypted private key..."

    if [ -n "$PFX_PASSWORD" ]; then
        openssl rsa -in "$file" -out "$WORK_DIR/server.key" -passin "pass:$PFX_PASSWORD" || \
            log_error "Cannot decrypt key. Wrong password?"
    else
        log_info "Key is encrypted. Enter password:"
        openssl rsa -in "$file" -out "$WORK_DIR/server.key" || \
            log_error "Cannot decrypt key."
    fi
}

# ══════════════════════════════════════════════════════════════
# MAIN LOGIC — process input files
# ══════════════════════════════════════════════════════════════
log_info "=== MazeVault Certificate Import ==="
log_info "Input files: ${INPUT_FILES[*]}"

for file in "${INPUT_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        log_error "File not found: $file"
    fi

    format=$(detect_format "$file")
    log_info "File '$file' → format: $format"

    case "$format" in
        pkcs12)          extract_pkcs12 "$file" ;;
        pem-bundle)      split_pem_bundle "$file" ;;
        pem-cert)        cp "$file" "$WORK_DIR/server.crt" ;;
        pem-key)         cp "$file" "$WORK_DIR/server.key" ;;
        pem-encrypted-key) decrypt_pem_key "$file" ;;
        der-cert)        convert_der_cert "$file" ;;
        der-key)         convert_der_key "$file" ;;
        pkcs7|pkcs7-pem) extract_pkcs7 "$file" ;;
        unknown)         log_error "Unrecognized file format: $file" ;;
    esac
done

# ══════════════════════════════════════════════════════════════
# VALIDATION — check completeness and key/cert match
# ══════════════════════════════════════════════════════════════
log_step "Validating extracted files..."

if [ ! -f "$WORK_DIR/server.crt" ]; then
    log_error "Certificate (server.crt) was not extracted from provided files."
fi

if [ ! -f "$WORK_DIR/server.key" ]; then
    log_error "Private key (server.key) was not extracted. For PKCS#7/DER cert, provide key as additional file."
fi

log_step "Checking certificate/key match (modulus match)..."
CERT_MOD=$(openssl x509 -in "$WORK_DIR/server.crt" -modulus -noout 2>/dev/null | md5sum | awk '{print $1}')
KEY_MOD=$(openssl rsa -in "$WORK_DIR/server.key" -modulus -noout 2>/dev/null | md5sum | awk '{print $1}')

if [ "$CERT_MOD" != "$KEY_MOD" ]; then
    log_error "Certificate and private key DO NOT MATCH (modulus mismatch)! Check input files."
fi
log_info "✓ Certificate and key match."

log_info "Certificate details:"
openssl x509 -in "$WORK_DIR/server.crt" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null | sed 's/^/  /'

if ! openssl x509 -in "$WORK_DIR/server.crt" -noout -checkend 2592000 2>/dev/null; then
    log_warn "⚠ Certificate expires in less than 30 days!"
fi

if [ -f "$WORK_DIR/ca.crt" ]; then
    cat "$WORK_DIR/server.crt" "$WORK_DIR/ca.crt" > "$WORK_DIR/ca-bundle.crt"
    log_info "✓ ca-bundle.crt created (leaf + CA chain)."
else
    cp "$WORK_DIR/server.crt" "$WORK_DIR/ca-bundle.crt"
    log_warn "CA chain not provided — ca-bundle.crt contains only the leaf cert."
fi

# ══════════════════════════════════════════════════════════════
# DRY-RUN check
# ══════════════════════════════════════════════════════════════
if [ "$DRY_RUN" = true ]; then
    log_info "=== DRY RUN — no files were copied ==="
    log_info "Files prepared in: $WORK_DIR"
    ls -la "$WORK_DIR/"
    exit 0
fi

# ══════════════════════════════════════════════════════════════
# COPY to Docker volume
# ══════════════════════════════════════════════════════════════
log_step "Copying to volume '$CERT_VOLUME'..."

# Detect container runtime
CONTAINER_CMD="podman"
if ! command -v podman &>/dev/null; then
    CONTAINER_CMD="docker"
fi

BACKUP_DIR="$INSTALL_DIR/backups/certs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
VOLUME_PATH=$($CONTAINER_CMD volume inspect "$CERT_VOLUME" --format '{{.Mountpoint}}' 2>/dev/null || echo "")
if [ -z "$VOLUME_PATH" ]; then
    log_info "Volume $CERT_VOLUME does not exist — creating..."
    $CONTAINER_CMD volume create "$CERT_VOLUME"
    VOLUME_PATH=$($CONTAINER_CMD volume inspect "$CERT_VOLUME" --format '{{.Mountpoint}}')
fi

# Backup existing certs
if [ -f "$VOLUME_PATH/server.crt" ]; then
    cp -a "$VOLUME_PATH/"* "$BACKUP_DIR/" 2>/dev/null || true
    log_info "✓ Existing certificates backed up to: $BACKUP_DIR"
fi

# Install new certs
sudo cp "$WORK_DIR/server.crt" "$VOLUME_PATH/server.crt"
sudo cp "$WORK_DIR/server.key" "$VOLUME_PATH/server.key"
sudo cp "$WORK_DIR/ca-bundle.crt" "$VOLUME_PATH/ca-bundle.crt"
[ -f "$WORK_DIR/ca.crt" ] && sudo cp "$WORK_DIR/ca.crt" "$VOLUME_PATH/ca.crt"

# Permissions
sudo chown 70:70 "$VOLUME_PATH/server.key"
sudo chmod 600 "$VOLUME_PATH/server.key"
sudo chmod 644 "$VOLUME_PATH/server.crt"
sudo chmod 644 "$VOLUME_PATH/ca-bundle.crt"
[ -f "$VOLUME_PATH/ca.crt" ] && sudo chmod 644 "$VOLUME_PATH/ca.crt"

log_info "✓ Certificates installed to volume $CERT_VOLUME"

# ══════════════════════════════════════════════════════════════
# RESTART services
# ══════════════════════════════════════════════════════════════
if [ "$DO_RESTART" = true ]; then
    log_step "Restarting services to load new certificates..."
    cd "$INSTALL_DIR"

    COMPOSE_CMD="$CONTAINER_CMD compose"
    if ! $COMPOSE_CMD version &>/dev/null 2>&1; then
        COMPOSE_CMD="${CONTAINER_CMD}-compose"
    fi

    $COMPOSE_CMD restart mazevault-backend mazevault-frontend mazevault-ocsp mazevault-docs 2>/dev/null || \
        log_warn "Services not restarted — do it manually: $COMPOSE_CMD restart"

    sleep 5
    if curl -sf -k https://localhost:443 > /dev/null 2>&1; then
        log_info "✓ Frontend HTTPS OK"
    else
        log_warn "Frontend not yet responding."
    fi
    if curl -sf -k https://localhost:8443/api/v1/health > /dev/null 2>&1; then
        log_info "✓ Backend HTTPS OK"
    else
        log_warn "Backend not yet responding."
    fi
else
    log_info "Services NOT restarted (--no-restart). Do it manually:"
    log_info "  cd $INSTALL_DIR && podman-compose restart"
fi

log_info "=== Certificate import complete ==="
log_info "Backup: $BACKUP_DIR"
log_info "Volume: $CERT_VOLUME"
