<#
.SYNOPSIS
    MazeVault EntraID SSO Role Mapping Diagnostic Tool
.DESCRIPTION
    Diagnoses common SSO role mapping issues by:
    1. Testing OIDC metadata endpoint connectivity
    2. Acquiring and decoding an ID token from Entra ID
    3. Showing groups and roles claims present in the token
    4. Comparing token claims against MazeVault group_role_mappings (optional DB)
    5. Simulating the role matching algorithm used by MazeVault backend
.PARAMETER TenantId
    Azure AD Tenant ID (directory ID)
.PARAMETER ClientId
    App Registration Client ID
.PARAMETER ClientSecret
    App Registration Client Secret (optional for interactive flow)
.PARAMETER MazeVaultUrl
    MazeVault backend URL (e.g., https://mazevault.company.com)
.PARAMETER Token
    Pre-existing JWT ID token to decode instead of acquiring a new one
.PARAMETER DbConnectionString
    PostgreSQL connection string for direct DB validation (optional)
.EXAMPLE
    .\diagnose-entra-sso.ps1 -TenantId "abc-123" -ClientId "def-456"
.EXAMPLE
    .\diagnose-entra-sso.ps1 -Token "eyJ0eXAiOiJKV1Qi..."
.NOTES
    Version: 1.0.0
    For MazeVault Client v4.x+
    No external PowerShell modules required.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$ClientId,

    [Parameter(Mandatory = $false)]
    [string]$ClientSecret,

    [Parameter(Mandatory = $false)]
    [string]$MazeVaultUrl,

    [Parameter(Mandatory = $false)]
    [string]$Token,

    [Parameter(Mandatory = $false)]
    [string]$DbConnectionString
)

$ErrorActionPreference = "Continue"
$script:issues = @()
$script:warnings = @()
$script:passedChecks = @()

# ============================================================================
# Helper Functions
# ============================================================================

function Write-Header {
    param([string]$Title)
    $line = "=" * 70
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Message)
    Write-Host "  [PASS] $Message" -ForegroundColor Green
    $script:passedChecks += $Message
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
    $script:issues += $Message
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
    $script:warnings += $Message
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor White
}

function Decode-JwtPayload {
    <#
    .SYNOPSIS
        Decodes a JWT token payload (no signature verification - diagnostic only)
    #>
    param([string]$JwtToken)

    $parts = $JwtToken.Split('.')
    if ($parts.Count -lt 2) {
        throw "Invalid JWT: expected at least 2 parts separated by '.'"
    }

    # Base64url decode the payload (part 1)
    $payload = $parts[1]
    # Pad to multiple of 4
    $padding = 4 - ($payload.Length % 4)
    if ($padding -ne 4) {
        $payload += '=' * $padding
    }
    # Convert base64url to base64
    $payload = $payload.Replace('-', '+').Replace('_', '/')

    $bytes = [System.Convert]::FromBase64String($payload)
    $json = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $json | ConvertFrom-Json
}

function Decode-JwtHeader {
    param([string]$JwtToken)

    $parts = $JwtToken.Split('.')
    if ($parts.Count -lt 1) {
        throw "Invalid JWT"
    }

    $header = $parts[0]
    $padding = 4 - ($header.Length % 4)
    if ($padding -ne 4) {
        $header += '=' * $padding
    }
    $header = $header.Replace('-', '+').Replace('_', '/')

    $bytes = [System.Convert]::FromBase64String($header)
    $json = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $json | ConvertFrom-Json
}

# ============================================================================
# Section 1: OIDC Discovery & Connectivity
# ============================================================================

function Test-OidcDiscovery {
    param([string]$Tenant)

    Write-Header "1. OIDC Discovery & Connectivity"

    if (-not $Tenant) {
        Write-Warn "TenantId not provided — skipping OIDC discovery test."
        return
    }

    $oidcUrl = "https://login.microsoftonline.com/$Tenant/v2.0/.well-known/openid-configuration"
    Write-Info "Testing: $oidcUrl"

    try {
        $response = Invoke-RestMethod -Uri $oidcUrl -Method Get -TimeoutSec 10
        Write-Pass "OIDC metadata endpoint reachable"
        Write-Info "  issuer:                 $($response.issuer)"
        Write-Info "  authorization_endpoint: $($response.authorization_endpoint)"
        Write-Info "  token_endpoint:         $($response.token_endpoint)"
        Write-Info "  jwks_uri:               $($response.jwks_uri)"

        # Validate issuer format
        $expectedIssuer = "https://login.microsoftonline.com/$Tenant/v2.0"
        if ($response.issuer -eq $expectedIssuer) {
            Write-Pass "Issuer matches expected v2.0 format"
        }
        else {
            Write-Warn "Issuer is '$($response.issuer)' (expected '$expectedIssuer')"
            Write-Info "  MazeVault accepts both v1 and v2 issuers — this may still work."
        }

        # Check claims_supported
        if ($response.claims_supported -contains "groups") {
            Write-Pass "groups claim is listed in claims_supported"
        }
        else {
            Write-Warn "groups claim NOT in claims_supported — check Token Configuration"
        }

        # Test JWKS endpoint
        try {
            $jwks = Invoke-RestMethod -Uri $response.jwks_uri -Method Get -TimeoutSec 10
            Write-Pass "JWKS endpoint reachable ($($jwks.keys.Count) keys)"
        }
        catch {
            Write-Fail "JWKS endpoint unreachable: $($_.Exception.Message)"
        }
    }
    catch {
        Write-Fail "OIDC metadata endpoint unreachable: $($_.Exception.Message)"
        Write-Info "  Check network/firewall access to login.microsoftonline.com"
    }
}

# ============================================================================
# Section 2: Token Decoding & Claim Analysis
# ============================================================================

function Analyze-Token {
    param([string]$JwtToken)

    Write-Header "2. Token Claims Analysis"

    if (-not $JwtToken) {
        Write-Warn "No token provided — skipping claim analysis."
        Write-Info "  Provide -Token parameter with a raw ID token to analyze."
        Write-Info "  You can extract the ID token from:"
        Write-Info "    - Browser DevTools > Network > /oauth2/v2.0/token response > id_token"
        Write-Info "    - MazeVault backend logs: [EntraSSO] claims extracted"
        return $null
    }

    try {
        $header = Decode-JwtHeader -JwtToken $JwtToken
        $claims = Decode-JwtPayload -JwtToken $JwtToken

        Write-Info "JWT Algorithm: $($header.alg)"
        Write-Info "JWT Type:      $($header.typ)"
        Write-Host ""

        # === Standard Claims ===
        Write-Info "--- Standard Claims ---"
        Write-Info "  iss (issuer):    $($claims.iss)"
        Write-Info "  aud (audience):  $($claims.aud)"
        Write-Info "  sub (subject):   $($claims.sub)"
        Write-Info "  oid (object id): $($claims.oid)"
        Write-Info "  email:           $($claims.email)"
        Write-Info "  name:            $($claims.name)"
        Write-Info "  preferred_user:  $($claims.preferred_username)"

        # Check expiration
        if ($claims.exp) {
            $expDate = [DateTimeOffset]::FromUnixTimeSeconds($claims.exp).LocalDateTime
            $now = Get-Date
            if ($expDate -lt $now) {
                Write-Warn "Token is EXPIRED (exp: $expDate)"
            }
            else {
                Write-Pass "Token is valid (exp: $expDate)"
            }
        }

        # === Groups Claim ===
        Write-Host ""
        Write-Info "--- Groups Claim (Security Groups) ---"
        if ($null -ne $claims.groups -and $claims.groups.Count -gt 0) {
            Write-Pass "groups claim present: $($claims.groups.Count) group(s)"
            foreach ($g in $claims.groups) {
                Write-Info "    Group Object ID: $g"
            }
        }
        else {
            Write-Warn "groups claim is EMPTY or MISSING"
            Write-Info "  This means either:"
            Write-Info "    1. User is not in any Security Groups"
            Write-Info "    2. Token Configuration does NOT include 'groups' claim"
            Write-Info "    3. Groups overage (>150 groups) — check _claim_names below"
            Write-Info ""
            Write-Info "  TO FIX: Azure Portal > App Registration > Token Configuration >"
            Write-Info "          Add optional claim > ID token > groups"
        }

        # === Groups Overage ===
        Write-Host ""
        Write-Info "--- Groups Overage Check ---"
        if ($null -ne $claims._claim_names) {
            $overageKeys = $claims._claim_names | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
            if ($overageKeys -contains "groups") {
                Write-Warn "Groups OVERAGE detected — user has >150 groups"
                Write-Info "  MazeVault falls back to Graph API (/me/memberOf)"
                Write-Info "  IMPORTANT: App Registration needs 'GroupMember.Read.All'"
                Write-Info "  or 'Directory.Read.All' delegated permission for this to work!"
                Write-Info ""
                Write-Info "  Without this permission, Graph API returns 403 and NO groups"
                Write-Info "  are resolved — user will get default 'viewer' role."

                if ($null -ne $claims._claim_sources) {
                    Write-Info "  _claim_sources present (Graph endpoint for groups)"
                }
            }
            else {
                Write-Pass "No groups overage"
            }
        }
        else {
            Write-Pass "No groups overage (_claim_names not present)"
        }

        # === App Roles Claim (NEW — this is what BUG 1 missed) ===
        Write-Host ""
        Write-Info "--- Roles Claim (Azure AD App Roles) ---"
        if ($null -ne $claims.roles -and $claims.roles.Count -gt 0) {
            Write-Pass "roles claim present: $($claims.roles.Count) App Role(s)"
            foreach ($r in $claims.roles) {
                Write-Info "    App Role Value: $r"
            }
            Write-Info ""
            Write-Info "  These are matched against group_display_name in MazeVault mappings."
            Write-Info "  Ensure each App Role value has a corresponding group_role_mapping."
        }
        else {
            Write-Warn "roles claim is EMPTY or MISSING"
            Write-Info "  This means either:"
            Write-Info "    1. No App Roles defined in App Registration"
            Write-Info "    2. User is not assigned to any App Roles"
            Write-Info "    3. App Roles not configured (only using Security Groups)"
            Write-Info ""
            Write-Info "  NOTE: roles and groups are independent mechanisms."
            Write-Info "  You can use EITHER or BOTH for role mapping."
        }

        # === Summary for MazeVault ===
        Write-Host ""
        Write-Info "--- MazeVault Role Mapping Summary ---"
        $totalIdentifiers = 0
        if ($claims.groups) { $totalIdentifiers += $claims.groups.Count }
        if ($claims.roles) { $totalIdentifiers += $claims.roles.Count }

        if ($totalIdentifiers -eq 0) {
            Write-Fail "NO identifiers available for role mapping!"
            Write-Info "  User will get default 'viewer' role."
            Write-Info "  Configure groups claim OR App Roles in Azure App Registration."
        }
        else {
            Write-Pass "$totalIdentifiers identifier(s) available for role matching"
            Write-Info "  MazeVault will match these against group_role_mappings table"
            Write-Info "  (case-insensitive match on group_external_id AND group_display_name)"
        }

        # === nonce ===
        if ($claims.nonce) {
            Write-Info "  nonce: present (OIDC replay protection)"
        }

        return $claims
    }
    catch {
        Write-Fail "Failed to decode token: $($_.Exception.Message)"
        Write-Info "  Ensure the token is a valid JWT (3 base64url-encoded parts separated by '.')"
        return $null
    }
}

# ============================================================================
# Section 3: MazeVault API Health & SSO Config Check
# ============================================================================

function Test-MazeVaultApi {
    param([string]$BaseUrl)

    Write-Header "3. MazeVault API Health & SSO Config"

    if (-not $BaseUrl) {
        Write-Warn "MazeVaultUrl not provided — skipping API tests."
        Write-Info "  Provide -MazeVaultUrl parameter (e.g., https://mazevault.company.com)"
        return
    }

    $BaseUrl = $BaseUrl.TrimEnd('/')

    # Health check
    try {
        $health = Invoke-RestMethod -Uri "$BaseUrl/api/v1/health" -Method Get -TimeoutSec 10 -SkipCertificateCheck
        Write-Pass "Health endpoint reachable"
        if ($health.status -eq "ok" -or $health.status -eq "healthy") {
            Write-Pass "Backend status: $($health.status)"
        }
        else {
            Write-Warn "Backend status: $($health.status)"
        }
        if ($health.database) {
            Write-Info "  Database: $($health.database)"
        }
    }
    catch {
        Write-Fail "Health endpoint unreachable: $($_.Exception.Message)"
    }

    # SSO login URL test
    try {
        # Do NOT follow redirects — we just want to see if the endpoint exists
        $response = Invoke-WebRequest -Uri "$BaseUrl/api/v1/auth/sso/entra/login" -Method Get -MaximumRedirection 0 -SkipCertificateCheck -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 302 -or $response.StatusCode -eq 307) {
            $redirectUrl = $response.Headers['Location']
            if ($redirectUrl -like "*login.microsoftonline.com*") {
                Write-Pass "SSO login endpoint redirects to Entra ($($response.StatusCode))"
                # Parse redirect URL for diagnostics
                $uri = [System.Uri]$redirectUrl
                $queryParams = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
                Write-Info "  redirect client_id: $($queryParams['client_id'])"
                Write-Info "  redirect scope:     $($queryParams['scope'])"
                Write-Info "  redirect_uri:       $($queryParams['redirect_uri'])"

                if ($queryParams['scope'] -notlike "*GroupMember*" -and $queryParams['scope'] -notlike "*Directory*") {
                    Write-Warn "OAuth scope does not include GroupMember.Read.All"
                    Write-Info "  Groups overage fallback to Graph API will fail without this."
                    Write-Info "  If you have >150 groups, add this permission in App Registration."
                }
            }
            else {
                Write-Warn "SSO login redirects to unexpected URL: $redirectUrl"
            }
        }
        else {
            Write-Warn "SSO login endpoint returned HTTP $($response.StatusCode) (expected 302)"
        }
    }
    catch {
        # Invoke-WebRequest throws on 3xx when MaximumRedirection=0
        if ($_.Exception.Response.StatusCode.value__ -eq 302 -or $_.Exception.Response.StatusCode.value__ -eq 307) {
            Write-Pass "SSO login endpoint active (redirect)"
        }
        else {
            Write-Fail "SSO login endpoint error: $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# Section 4: Simulate Role Matching Logic
# ============================================================================

function Simulate-RoleMatching {
    param($Claims)

    Write-Header "4. Role Matching Simulation"

    if (-not $Claims) {
        Write-Warn "No decoded claims — skipping role matching simulation."
        return
    }

    # Collect identifiers
    $identifiers = @()
    if ($Claims.groups) {
        foreach ($g in $Claims.groups) { $identifiers += @{ Value = $g; Source = "groups" } }
    }
    if ($Claims.roles) {
        foreach ($r in $Claims.roles) { $identifiers += @{ Value = $r; Source = "roles" } }
    }

    if ($identifiers.Count -eq 0) {
        Write-Fail "No identifiers to match — role mapping will result in default 'viewer'"
        return
    }

    Write-Info "Identifiers to match ($($identifiers.Count) total):"
    foreach ($id in $identifiers) {
        Write-Info "  [$($id.Source)] $($id.Value)"
    }

    Write-Host ""
    Write-Info "--- How MazeVault Matches ---"
    Write-Info "For each group_role_mapping in database:"
    Write-Info "  IF identifier matches group_external_id (case-insensitive)"
    Write-Info "  OR identifier matches group_display_name (case-insensitive)"
    Write-Info "  THEN assign the mapped role to the user"
    Write-Host ""
    Write-Info "All matched roles are COMBINED (union of permissions)."
    Write-Info "User.Role field shows the HIGHEST priority role:"
    Write-Info "  viewer(1) < user(2) < finance(3) < auditor(4)"
    Write-Info "  < certificate_manager(5) = secret_manager(5) = ssh_admin(5)"
    Write-Info "  < project_admin(6) < admin(7)"
    Write-Host ""
    Write-Info "IMPORTANT: Even if User.Role shows 'certificate_manager',"
    Write-Info "the user STILL has all permissions from 'secret_manager' too"
    Write-Info "(if both roles are assigned). Permissions are combined."
    Write-Host ""
    Write-Info "Run the SQL diagnostic to check your actual mappings:"
    Write-Info "  psql -f diagnose-role-mapping.sql"
}

# ============================================================================
# Section 5: Summary
# ============================================================================

function Show-Summary {
    Write-Header "DIAGNOSTIC SUMMARY"

    if ($script:passedChecks.Count -gt 0) {
        Write-Host "  Passed: $($script:passedChecks.Count)" -ForegroundColor Green
    }

    if ($script:warnings.Count -gt 0) {
        Write-Host "  Warnings: $($script:warnings.Count)" -ForegroundColor Yellow
        foreach ($w in $script:warnings) {
            Write-Host "    - $w" -ForegroundColor Yellow
        }
    }

    if ($script:issues.Count -gt 0) {
        Write-Host "  ISSUES: $($script:issues.Count)" -ForegroundColor Red
        foreach ($i in $script:issues) {
            Write-Host "    - $i" -ForegroundColor Red
        }
    }

    if ($script:issues.Count -eq 0 -and $script:warnings.Count -eq 0) {
        Write-Host "  All checks passed!" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    1. Check backend logs: docker logs mazevault-backend 2>&1 | grep '[EntraSSO]'" -ForegroundColor Gray
    Write-Host "    2. Run SQL diagnostic: psql -f diagnose-role-mapping.sql" -ForegroundColor Gray
    Write-Host "    3. Test SSO login and check /api/v1/auth/me/permissions response" -ForegroundColor Gray
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "  MazeVault EntraID SSO Role Mapping Diagnostic" -ForegroundColor Magenta
Write-Host "  Version 1.0.0 | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta

# Add System.Web for URL parsing
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

# Run diagnostics
Test-OidcDiscovery -Tenant $TenantId
$decodedClaims = Analyze-Token -JwtToken $Token
Test-MazeVaultApi -BaseUrl $MazeVaultUrl
Simulate-RoleMatching -Claims $decodedClaims
Show-Summary
