#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# MazeVault — Mirror GHCR Images to Private Registry
# Usage: ./mirror-to-registry.sh --version v1.2.0 --target registry.corp.com/mazevault
#
# For air-gapped environments with a private Nexus/Harbor/GitLab Container Registry
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SOURCE_REGISTRY="${MAZEVAULT_REGISTRY:-ghcr.io/axiemirror}"
TARGET_REGISTRY=""
VERSION="${MAZEVAULT_VERSION:-latest}"
IMAGES=("mazevault-backend" "mazevault-frontend" "mazevault-init-certs")
INCLUDE_INFRA=false

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  VERSION="$2"; shift 2 ;;
    --source)   SOURCE_REGISTRY="$2"; shift 2 ;;
    --target)   TARGET_REGISTRY="$2"; shift 2 ;;
    --include-infra) INCLUDE_INFRA=true; shift ;;
    --help|-h)
      cat <<EOF
Usage: $0 --version TAG --target REGISTRY [--source REGISTRY] [--include-infra]

Options:
  --version TAG       Image tag to mirror (default: latest)
  --target REGISTRY   Target registry URL (required)
  --source REGISTRY   Source registry (default: ghcr.io/axiemirror)
  --include-infra     Also mirror postgres:15-alpine and redis:7-alpine

Example:
  $0 --version v1.2.0 --target harbor.corp.com/mazevault
  $0 --version v1.2.0 --target nexus.internal:8443/mazevault --include-infra
EOF
      exit 0 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# ── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; CYN='\033[0;36m'; RST='\033[0m'
info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[OK]${RST}    $*"; }
die()   { echo -e "${RED}[ERR]${RST}   $*" >&2; exit 1; }

# ── Validate ────────────────────────────────────────────────────────────────
[[ -n "${TARGET_REGISTRY}" ]] || die "Target registry required. Use --target REGISTRY"
command -v docker &>/dev/null || die "docker CLI required"

info "Mirroring MazeVault ${VERSION}"
info "  Source: ${SOURCE_REGISTRY}"
info "  Target: ${TARGET_REGISTRY}"

# ── Mirror MazeVault images ────────────────────────────────────────────────
for img in "${IMAGES[@]}"; do
  SRC="${SOURCE_REGISTRY}/${img}:${VERSION}"
  DST="${TARGET_REGISTRY}/${img}:${VERSION}"

  info "Pulling  ${SRC}..."
  docker pull "${SRC}"

  info "Tagging  ${DST}..."
  docker tag "${SRC}" "${DST}"

  info "Pushing  ${DST}..."
  docker push "${DST}"

  # Also tag as latest
  DST_LATEST="${TARGET_REGISTRY}/${img}:latest"
  docker tag "${SRC}" "${DST_LATEST}"
  docker push "${DST_LATEST}"

  ok "${img}:${VERSION} → ${TARGET_REGISTRY}"
done

# ── Optionally mirror infra images ─────────────────────────────────────────
if [[ "${INCLUDE_INFRA}" == "true" ]]; then
  INFRA_IMAGES=("postgres:15-alpine" "redis:7-alpine")
  for img in "${INFRA_IMAGES[@]}"; do
    DST="${TARGET_REGISTRY}/${img}"
    info "Pulling  ${img}..."
    docker pull "${img}"
    docker tag "${img}" "${DST}"
    docker push "${DST}"
    ok "${img} → ${TARGET_REGISTRY}"
  done
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  ✅ All images mirrored to ${TARGET_REGISTRY}"
echo ""
echo "  Update your .env:"
echo "    IMAGE_REGISTRY=${TARGET_REGISTRY}"
echo "    IMAGE_TAG=${VERSION}"
echo "═══════════════════════════════════════════════════════════════"
