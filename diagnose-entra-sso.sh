#!/usr/bin/env bash
# =============================================================================
# MazeVault EntraID SSO Role Mapping Diagnostic Tool (Bash)
# =============================================================================
# Usage:
#   ./diagnose-entra-sso.sh [OPTIONS]
#
# Options:
#   --tenant-id ID        Azure AD Tenant ID
#   --client-id ID        App Registration Client ID
#   --mazevault-url URL   MazeVault backend URL
#   --token JWT           Pre-existing JWT ID token to decode
#   --db-uri URI          PostgreSQL connection URI for DB validation
#   --help                Show this help
#
# Examples:
#   ./diagnose-entra-sso.sh --tenant-id "abc-123" --client-id "def-456"
#   ./diagnose-entra-sso.sh --token "eyJ0eXAiOiJKV1Qi..."
#   ./diagnose-entra-sso.sh --mazevault-url https://mazevault.company.com
#   ./diagnose-entra-sso.sh --db-uri "postgresql://user:pass@localhost:5432/mazevault"
#
# Version: 1.0.0
# For MazeVault Client v4.x+
# Requires: bash 4+, curl, base64 (python3/jq optional but recommended)
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# Counters
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
declare -a ISSUES=()
declare -a WARNINGS=()

# =============================================================================
# Parsing arguments
# =============================================================================

TENANT_ID=""
CLIENT_ID=""
MAZEVAULT_URL=""
TOKEN=""
DB_URI=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --tenant-id)  TENANT_ID="$2";     shift 2 ;;
        --client-id)  CLIENT_ID="$2";     shift 2 ;;
        --mazevault-url) MAZEVAULT_URL="$2"; shift 2 ;;
        --token)      TOKEN="$2";          shift 2 ;;
        --db-uri)     DB_URI="$2";         shift 2 ;;
        --help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Helper functions
# =============================================================================

header() {
    echo ""
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}======================================================================${NC}"
}

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    ((PASS_COUNT++))
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    ((FAIL_COUNT++))
    ISSUES+=("$1")
}

warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
    ((WARN_COUNT++))
    WARNINGS+=("$1")
}

info() {
    echo -e "  ${WHITE}[INFO]${NC} $1"
}

# Decode JWT payload (base64url → JSON)
# Uses python3 if available, falls back to base64 + sed
decode_jwt_payload() {
    local jwt="$1"
    local payload
    payload=$(echo "$jwt" | cut -d'.' -f2)

    # Pad to multiple of 4
    local pad=$(( 4 - (${#payload} % 4) ))
    if [[ $pad -ne 4 ]]; then
        payload="${payload}$(printf '%0.s=' $(seq 1 $pad))"
    fi
    # base64url → base64
    payload=$(echo "$payload" | tr '_-' '/+')

    if command -v python3 &>/dev/null; then
        echo "$payload" | python3 -c "
import sys, base64, json
data = sys.stdin.read().strip()
decoded = base64.b64decode(data)
parsed = json.loads(decoded)
print(json.dumps(parsed, indent=2))
"
    else
        echo "$payload" | base64 -d 2>/dev/null
    fi
}

decode_jwt_header() {
    local jwt="$1"
    local header
    header=$(echo "$jwt" | cut -d'.' -f1)

    local pad=$(( 4 - (${#header} % 4) ))
    if [[ $pad -ne 4 ]]; then
        header="${header}$(printf '%0.s=' $(seq 1 $pad))"
    fi
    header=$(echo "$header" | tr '_-' '/+')

    if command -v python3 &>/dev/null; then
        echo "$header" | python3 -c "
import sys, base64, json
data = sys.stdin.read().strip()
decoded = base64.b64decode(data)
parsed = json.loads(decoded)
print(json.dumps(parsed, indent=2))
"
    else
        echo "$header" | base64 -d 2>/dev/null
    fi
}

# Extract a JSON field using python3 or jq
json_get() {
    local json="$1"
    local field="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r ".$field // empty" 2>/dev/null
    elif command -v python3 &>/dev/null; then
        echo "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    keys = '$field'.split('.')
    val = data
    for k in keys:
        if isinstance(val, dict):
            val = val.get(k)
        else:
            val = None
            break
    if val is not None:
        if isinstance(val, (list, dict)):
            print(json.dumps(val))
        else:
            print(val)
except:
    pass
"
    else
        echo "(install jq or python3 for JSON parsing)"
    fi
}

json_array_count() {
    local json="$1"
    local field="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r "if .$field then (.$field | length) else 0 end" 2>/dev/null
    elif command -v python3 &>/dev/null; then
        echo "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    arr = data.get('$field', [])
    print(len(arr) if isinstance(arr, list) else 0)
except:
    print(0)
"
    else
        echo "0"
    fi
}

json_array_items() {
    local json="$1"
    local field="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r ".$field[]? // empty" 2>/dev/null
    elif command -v python3 &>/dev/null; then
        echo "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    arr = data.get('$field', [])
    if isinstance(arr, list):
        for item in arr:
            print(item)
except:
    pass
"
    fi
}

# =============================================================================
# Section 1: OIDC Discovery Connectivity
# =============================================================================

test_oidc_discovery() {
    header "1. OIDC Discovery & Connectivity"

    if [[ -z "$TENANT_ID" ]]; then
        warn "TenantId not provided — skipping OIDC discovery test."
        return
    fi

    local oidc_url="https://login.microsoftonline.com/${TENANT_ID}/v2.0/.well-known/openid-configuration"
    info "Testing: $oidc_url"

    local response
    if response=$(curl -sfS --connect-timeout 10 "$oidc_url" 2>&1); then
        pass "OIDC metadata endpoint reachable"

        local issuer
        issuer=$(json_get "$response" "issuer")
        info "  issuer: $issuer"
        info "  token_endpoint: $(json_get "$response" "token_endpoint")"
        info "  jwks_uri: $(json_get "$response" "jwks_uri")"

        local expected="https://login.microsoftonline.com/${TENANT_ID}/v2.0"
        if [[ "$issuer" == "$expected" ]]; then
            pass "Issuer matches expected v2.0 format"
        else
            warn "Issuer is '$issuer' (expected '$expected')"
            info "  MazeVault accepts both v1 and v2 issuers"
        fi

        # Test JWKS
        local jwks_uri
        jwks_uri=$(json_get "$response" "jwks_uri")
        if [[ -n "$jwks_uri" ]]; then
            if curl -sfS --connect-timeout 10 "$jwks_uri" -o /dev/null 2>&1; then
                pass "JWKS endpoint reachable"
            else
                fail "JWKS endpoint unreachable"
            fi
        fi
    else
        fail "OIDC metadata endpoint unreachable: $response"
        info "  Check network/firewall access to login.microsoftonline.com"
    fi
}

# =============================================================================
# Section 2: Token Decoding & Claim Analysis
# =============================================================================

analyze_token() {
    header "2. Token Claims Analysis"

    if [[ -z "$TOKEN" ]]; then
        warn "No token provided — skipping claim analysis."
        info "  Provide --token parameter with a raw ID token to analyze."
        info "  Extract from browser DevTools > Network > token response > id_token"
        return
    fi

    local header_json payload_json
    header_json=$(decode_jwt_header "$TOKEN" 2>/dev/null) || true
    payload_json=$(decode_jwt_payload "$TOKEN" 2>/dev/null) || true

    if [[ -z "$payload_json" ]]; then
        fail "Failed to decode token — ensure it's a valid JWT"
        return
    fi

    DECODED_CLAIMS="$payload_json"

    info "JWT Algorithm: $(json_get "$header_json" "alg")"
    echo ""

    # Standard claims
    info "--- Standard Claims ---"
    info "  iss (issuer):    $(json_get "$payload_json" "iss")"
    info "  aud (audience):  $(json_get "$payload_json" "aud")"
    info "  sub (subject):   $(json_get "$payload_json" "sub")"
    info "  oid (object id): $(json_get "$payload_json" "oid")"
    info "  email:           $(json_get "$payload_json" "email")"
    info "  name:            $(json_get "$payload_json" "name")"

    # Expiration
    local exp
    exp=$(json_get "$payload_json" "exp")
    if [[ -n "$exp" ]]; then
        local exp_date now_epoch
        now_epoch=$(date +%s)
        if (( exp < now_epoch )); then
            warn "Token is EXPIRED (exp: $(date -d "@$exp" 2>/dev/null || date -r "$exp" 2>/dev/null || echo "$exp"))"
        else
            pass "Token is valid (expires: $(date -d "@$exp" 2>/dev/null || date -r "$exp" 2>/dev/null || echo "$exp"))"
        fi
    fi

    # Groups claim
    echo ""
    info "--- Groups Claim (Security Groups) ---"
    local groups_count
    groups_count=$(json_array_count "$payload_json" "groups")
    if (( groups_count > 0 )); then
        pass "groups claim present: ${groups_count} group(s)"
        json_array_items "$payload_json" "groups" | while read -r g; do
            info "    Group Object ID: $g"
        done
    else
        warn "groups claim is EMPTY or MISSING"
        info "  Fix: Azure Portal > App Registration > Token Configuration >"
        info "       Add optional claim > ID token > groups"
    fi

    # Groups overage
    echo ""
    info "--- Groups Overage Check ---"
    local claim_names
    claim_names=$(json_get "$payload_json" "_claim_names")
    if [[ -n "$claim_names" ]] && echo "$claim_names" | grep -q "groups"; then
        warn "Groups OVERAGE detected — user has >150 groups"
        info "  MazeVault falls back to Graph API (/me/memberOf)"
        info "  REQUIRED: App Registration needs 'GroupMember.Read.All' permission!"
    else
        pass "No groups overage"
    fi

    # App Roles claim
    echo ""
    info "--- Roles Claim (Azure AD App Roles) ---"
    local roles_count
    roles_count=$(json_array_count "$payload_json" "roles")
    if (( roles_count > 0 )); then
        pass "roles claim present: ${roles_count} App Role(s)"
        json_array_items "$payload_json" "roles" | while read -r r; do
            info "    App Role Value: $r"
        done
        info ""
        info "  These are matched against group_display_name in MazeVault mappings."
    else
        warn "roles claim is EMPTY or MISSING"
        info "  No App Roles defined/assigned. Using Security Groups only."
        info "  You can configure App Roles in App Registration > App roles."
    fi

    # Summary
    echo ""
    info "--- MazeVault Role Mapping Summary ---"
    local total=$(( groups_count + roles_count ))
    if (( total == 0 )); then
        fail "NO identifiers available for role mapping!"
        info "  User will get default 'viewer' role."
    else
        pass "${total} identifier(s) available for role matching"
        info "  MazeVault matches against group_role_mappings table (case-insensitive)"
    fi
}

# =============================================================================
# Section 3: MazeVault API Health & SSO Config
# =============================================================================

test_mazevault_api() {
    header "3. MazeVault API Health & SSO Config"

    if [[ -z "$MAZEVAULT_URL" ]]; then
        warn "MazeVaultUrl not provided — skipping API tests."
        info "  Provide --mazevault-url parameter"
        return
    fi

    local base="${MAZEVAULT_URL%/}"

    # Health check
    local health
    if health=$(curl -sfSk --connect-timeout 10 "${base}/api/v1/health" 2>&1); then
        pass "Health endpoint reachable"
        local status
        status=$(json_get "$health" "status")
        if [[ "$status" == "ok" || "$status" == "healthy" ]]; then
            pass "Backend status: $status"
        else
            warn "Backend status: $status"
        fi
    else
        fail "Health endpoint unreachable: $health"
    fi

    # SSO login endpoint
    local http_code redirect_url
    http_code=$(curl -sfSk --connect-timeout 10 -o /dev/null -w '%{http_code}' -L --max-redirs 0 "${base}/api/v1/auth/sso/entra/login" 2>/dev/null || true)
    if [[ "$http_code" == "302" || "$http_code" == "307" ]]; then
        redirect_url=$(curl -sfSk --connect-timeout 10 -o /dev/null -w '%{redirect_url}' "${base}/api/v1/auth/sso/entra/login" 2>/dev/null || true)
        if echo "$redirect_url" | grep -q "login.microsoftonline.com"; then
            pass "SSO login endpoint redirects to Entra ($http_code)"
        else
            warn "SSO login redirects to unexpected URL"
        fi
    else
        warn "SSO login endpoint returned HTTP $http_code (expected 302)"
    fi
}

# =============================================================================
# Section 4: Database Validation (optional)
# =============================================================================

test_database() {
    header "4. Database Validation"

    if [[ -z "$DB_URI" ]]; then
        warn "DB URI not provided — skipping database validation."
        info "  Provide --db-uri to validate role mapping configuration directly."
        info "  Or run: psql -f diagnose-role-mapping.sql"
        return
    fi

    if ! command -v psql &>/dev/null; then
        warn "psql not found — cannot query database"
        info "  Install postgresql-client or run diagnose-role-mapping.sql manually"
        return
    fi

    info "Checking identity_providers..."
    local providers
    providers=$(psql "$DB_URI" -t -c "
        SELECT id, type, status, config->>'tenant_id' AS tenant
        FROM identity_providers
        WHERE type IN ('entra_id','entra','azure_ad')
          AND deleted_at IS NULL
        ORDER BY created_at ASC;
    " 2>&1) || true

    if [[ -n "$providers" && "$providers" != *"0 rows"* ]]; then
        pass "Active Entra provider found in identity_providers"
        echo "$providers" | head -5 | while read -r line; do
            info "  $line"
        done
    else
        fail "No active Entra provider in identity_providers!"
        info "  Configure SSO in Organization Settings > SSO"
    fi

    info ""
    info "Checking group_role_mappings..."
    local mappings
    mappings=$(psql "$DB_URI" -t -c "
        SELECT grm.group_external_id, grm.group_display_name, r.name AS role_name, grm.source, grm.provider_id
        FROM group_role_mappings grm
        JOIN roles r ON r.id = grm.role_id
        WHERE grm.source = 'entra'
        ORDER BY r.name;
    " 2>&1) || true

    if [[ -n "$mappings" && "$mappings" != *"0 rows"* ]]; then
        pass "Entra role mappings found"
        echo "$mappings" | while read -r line; do
            info "  $line"
        done
    else
        fail "No group_role_mappings with source='entra'!"
        info "  Configure in Access Control > Groups"
    fi
}

# =============================================================================
# Section 5: Role Matching Simulation
# =============================================================================

simulate_matching() {
    header "5. Role Matching Simulation"

    if [[ -z "${DECODED_CLAIMS:-}" ]]; then
        warn "No decoded claims — skipping simulation."
        return
    fi

    local groups_count roles_count
    groups_count=$(json_array_count "$DECODED_CLAIMS" "groups")
    roles_count=$(json_array_count "$DECODED_CLAIMS" "roles")
    local total=$(( groups_count + roles_count ))

    if (( total == 0 )); then
        fail "No identifiers to match — default 'viewer' role"
        return
    fi

    info "Identifiers to match ($total total):"
    if (( groups_count > 0 )); then
        json_array_items "$DECODED_CLAIMS" "groups" | while read -r g; do
            info "  [groups]  $g"
        done
    fi
    if (( roles_count > 0 )); then
        json_array_items "$DECODED_CLAIMS" "roles" | while read -r r; do
            info "  [roles]   $r"
        done
    fi

    echo ""
    info "--- How MazeVault Matches ---"
    info "For each group_role_mapping in database:"
    info "  IF identifier matches group_external_id (case-insensitive)"
    info "  OR identifier matches group_display_name (case-insensitive)"
    info "  THEN assign the mapped role to the user"
    echo ""
    info "All matched roles are COMBINED (union of permissions)."
    info "User.Role field shows the HIGHEST priority role:"
    info "  viewer(1) < user(2) < finance(3) < auditor(4)"
    info "  < certificate_manager(5) = secret_manager(5) = ssh_admin(5)"
    info "  < project_admin(6) < admin(7)"
    echo ""
    info "IMPORTANT: Even if User.Role shows 'certificate_manager',"
    info "the user STILL has all permissions from 'secret_manager' too"
    info "(if both roles are assigned). Permissions are combined."
}

# =============================================================================
# Summary
# =============================================================================

show_summary() {
    header "DIAGNOSTIC SUMMARY"

    echo -e "  ${GREEN}Passed:   ${PASS_COUNT}${NC}"
    echo -e "  ${YELLOW}Warnings: ${WARN_COUNT}${NC}"
    echo -e "  ${RED}Issues:   ${FAIL_COUNT}${NC}"

    if (( ${#WARNINGS[@]} > 0 )); then
        echo ""
        for w in "${WARNINGS[@]}"; do
            echo -e "  ${YELLOW}- $w${NC}"
        done
    fi

    if (( ${#ISSUES[@]} > 0 )); then
        echo ""
        for i in "${ISSUES[@]}"; do
            echo -e "  ${RED}- $i${NC}"
        done
    fi

    echo ""
    echo -e "  ${WHITE}Next steps:${NC}"
    echo -e "  ${GRAY}1. Check backend logs: docker logs mazevault-backend 2>&1 | grep '[EntraSSO]'${NC}"
    echo -e "  ${GRAY}2. Run SQL diagnostic: psql -f diagnose-role-mapping.sql${NC}"
    echo -e "  ${GRAY}3. Test SSO login and check /api/v1/auth/me/permissions response${NC}"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

DECODED_CLAIMS=""

echo ""
echo -e "${MAGENTA}================================================================${NC}"
echo -e "${MAGENTA}  MazeVault EntraID SSO Role Mapping Diagnostic${NC}"
echo -e "${MAGENTA}  Version 1.0.0 | $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${MAGENTA}================================================================${NC}"

test_oidc_discovery
analyze_token
test_mazevault_api
test_database
simulate_matching
show_summary
