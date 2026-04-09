[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$AksName,

    [Parameter(Mandatory = $true)]
    [string]$AcrName,

    [Parameter(Mandatory = $true)]
    [string]$AcrRepository,

    [Parameter(Mandatory = $true)]
    [string]$ImageTag,

    [string]$SubscriptionId,
    [string]$Namespace = "mazevault-lab",
    [string]$KeyVaultName,
    [string]$IdentityName,
    [string]$PostgresServerName,
    [string]$RedisName,
    [string]$SqlServerName,
    [string]$ReportPath = ".\mazevault-aks-lab-preflight.json"
)

$ErrorActionPreference = "Stop"
$script:HasCriticalFailure = $false
$report = [ordered]@{
    timestamp = (Get-Date).ToString("o")
    subscription = $null
    resourceGroup = $ResourceGroup
    aks = $AksName
    acr = $AcrName
    namespace = $Namespace
    checks = @()
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK]   $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-ErrorLine {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Add-Check {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Details,
        [bool]$Critical = $false
    )

    $report.checks += [pscustomobject]@{
        name = $Name
        status = $Status
        critical = $Critical
        details = $Details
    }

    if ($Critical -and $Status -eq "FAIL") {
        $script:HasCriticalFailure = $true
    }
}

function Invoke-AzText {
    param([string[]]$Arguments)

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (("az {0} failed: {1}" -f ($Arguments -join " "), ($output -join " `n")))
    }

    return ($output -join "`n").Trim()
}

function Invoke-AzJson {
    param([string[]]$Arguments)

    $text = Invoke-AzText -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text | ConvertFrom-Json
}

function Test-CommandExists {
    param([string]$CommandName)
    return $null -ne (Get-Command $CommandName -ErrorAction SilentlyContinue)
}

function Test-AzResource {
    param([string[]]$Arguments)
    try {
        $null = Invoke-AzText -Arguments $Arguments
        return $true
    }
    catch {
        return $false
    }
}

Write-Info "Checking required local tools"
foreach ($tool in @("az", "kubectl")) {
    if (Test-CommandExists -CommandName $tool) {
        Add-Check -Name "tool:$tool" -Status "PASS" -Details "Command is available" -Critical $true
        Write-Success "$tool is installed"
    }
    else {
        Add-Check -Name "tool:$tool" -Status "FAIL" -Details "Command not found in PATH" -Critical $true
        Write-ErrorLine "$tool is missing"
    }
}

if (Test-CommandExists -CommandName "sqlcmd") {
    Add-Check -Name "tool:sqlcmd" -Status "PASS" -Details "sqlcmd is available for Azure SQL validation" -Critical $false
}
else {
    Add-Check -Name "tool:sqlcmd" -Status "WARN" -Details "sqlcmd not found; Azure SQL login test will be manual" -Critical $false
}

Write-Info "Checking Azure login context"
try {
    $account = Invoke-AzJson -Arguments @("account", "show", "-o", "json")
    if ($SubscriptionId) {
        Invoke-AzText -Arguments @("account", "set", "--subscription", $SubscriptionId)
        $account = Invoke-AzJson -Arguments @("account", "show", "-o", "json")
    }

    $report.subscription = $account.id
    Add-Check -Name "azure:login" -Status "PASS" -Details ("Logged in as {0}" -f $account.user.name) -Critical $true
    Add-Check -Name "azure:subscription" -Status "PASS" -Details ("Using subscription {0} ({1})" -f $account.name, $account.id) -Critical $true
    Write-Success ("Azure subscription set to {0}" -f $account.name)
}
catch {
    Add-Check -Name "azure:login" -Status "FAIL" -Details $_.Exception.Message -Critical $true
    Write-ErrorLine "Azure login check failed"
}

Write-Info "Checking Azure resources"
foreach ($resourceCheck in @(
    @{ Name = "resource-group"; Args = @("group", "show", "--name", $ResourceGroup, "-o", "json") },
    @{ Name = "aks"; Args = @("aks", "show", "--resource-group", $ResourceGroup, "--name", $AksName, "-o", "json") },
    @{ Name = "acr"; Args = @("acr", "show", "--resource-group", $ResourceGroup, "--name", $AcrName, "-o", "json") }
)) {
    if (Test-AzResource -Arguments $resourceCheck.Args) {
        Add-Check -Name ("azure:{0}" -f $resourceCheck.Name) -Status "PASS" -Details "Resource exists" -Critical $true
        Write-Success ("{0} exists" -f $resourceCheck.Name)
    }
    else {
        Add-Check -Name ("azure:{0}" -f $resourceCheck.Name) -Status "FAIL" -Details "Resource not found" -Critical $true
        Write-ErrorLine ("{0} not found" -f $resourceCheck.Name)
    }
}

if ($KeyVaultName) {
    if (Test-AzResource -Arguments @("keyvault", "show", "--resource-group", $ResourceGroup, "--name", $KeyVaultName, "-o", "json")) {
        Add-Check -Name "azure:keyvault" -Status "PASS" -Details ("Key Vault {0} exists" -f $KeyVaultName) -Critical $false
        Write-Success "Key Vault exists"
    }
    else {
        Add-Check -Name "azure:keyvault" -Status "FAIL" -Details ("Key Vault {0} not found" -f $KeyVaultName) -Critical $false
        Write-Warn "Key Vault not found"
    }
}

if ($IdentityName) {
    if (Test-AzResource -Arguments @("identity", "show", "--resource-group", $ResourceGroup, "--name", $IdentityName, "-o", "json")) {
        Add-Check -Name "azure:managed-identity" -Status "PASS" -Details ("Managed identity {0} exists" -f $IdentityName) -Critical $false
    }
    else {
        Add-Check -Name "azure:managed-identity" -Status "WARN" -Details ("Managed identity {0} does not exist yet" -f $IdentityName) -Critical $false
    }
}

foreach ($optionalResource in @(
    @{ Name = "postgres"; Value = $PostgresServerName; Args = @("postgres", "flexible-server", "show", "--resource-group", $ResourceGroup, "--name", $PostgresServerName, "-o", "json") },
    @{ Name = "redis"; Value = $RedisName; Args = @("redis", "show", "--resource-group", $ResourceGroup, "--name", $RedisName, "-o", "json") },
    @{ Name = "sql"; Value = $SqlServerName; Args = @("sql", "server", "show", "--resource-group", $ResourceGroup, "--name", $SqlServerName, "-o", "json") }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalResource.Value)) {
        if (Test-AzResource -Arguments $optionalResource.Args) {
            Add-Check -Name ("azure:{0}" -f $optionalResource.Name) -Status "PASS" -Details "Resource exists" -Critical $false
        }
        else {
            Add-Check -Name ("azure:{0}" -f $optionalResource.Name) -Status "WARN" -Details "Resource does not exist yet; setup script can create it" -Critical $false
        }
    }
}

Write-Info "Checking ACR image availability"
try {
    $tags = Invoke-AzText -Arguments @("acr", "repository", "show-tags", "--name", $AcrName, "--repository", $AcrRepository, "--top", "200", "-o", "tsv")
    $tagList = @()
    if (-not [string]::IsNullOrWhiteSpace($tags)) {
        $tagList = $tags -split "`n"
    }

    if ($tagList -contains $ImageTag) {
        Add-Check -Name "acr:image-tag" -Status "PASS" -Details ("Found {0}:{1}" -f $AcrRepository, $ImageTag) -Critical $true
        Write-Success "ACR image tag found"
    }
    else {
        Add-Check -Name "acr:image-tag" -Status "FAIL" -Details ("Tag {0} not found in repository {1}" -f $ImageTag, $AcrRepository) -Critical $true
        Write-ErrorLine "ACR image tag not found"
    }
}
catch {
    Add-Check -Name "acr:image-tag" -Status "FAIL" -Details $_.Exception.Message -Critical $true
    Write-ErrorLine "Unable to inspect ACR tags"
}

Write-Info "Checking AKS connectivity"
try {
    $null = Invoke-AzText -Arguments @("aks", "get-credentials", "--resource-group", $ResourceGroup, "--name", $AksName, "--overwrite-existing")
    $nodesJson = & kubectl get nodes -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($nodesJson -join "`n")
    }

    $nodes = ($nodesJson -join "`n") | ConvertFrom-Json
    $readyNodes = @($nodes.items | Where-Object {
        @($_.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }).Count -gt 0
    }).Count

    Add-Check -Name "aks:kubeconfig" -Status "PASS" -Details "Credentials merged into local kubeconfig" -Critical $true
    Add-Check -Name "aks:nodes" -Status "PASS" -Details ("Cluster reachable; ready nodes: {0}" -f $readyNodes) -Critical $true
    Write-Success ("AKS reachable with {0} ready node(s)" -f $readyNodes)
}
catch {
    Add-Check -Name "aks:kubeconfig" -Status "FAIL" -Details $_.Exception.Message -Critical $true
    Write-ErrorLine "AKS connectivity check failed"
}

try {
    $aks = Invoke-AzJson -Arguments @("aks", "show", "--resource-group", $ResourceGroup, "--name", $AksName, "-o", "json")
    $oidcEnabled = $false
    $wiEnabled = $false

    if ($aks.oidcIssuerProfile) {
        $oidcEnabled = [bool]$aks.oidcIssuerProfile.enabled
    }
    if ($aks.securityProfile -and $aks.securityProfile.workloadIdentity) {
        $wiEnabled = [bool]$aks.securityProfile.workloadIdentity.enabled
    }

    Add-Check -Name "aks:oidc-issuer" -Status ($(if ($oidcEnabled) { "PASS" } else { "WARN" })) -Details ("OIDC issuer enabled: {0}" -f $oidcEnabled) -Critical $false
    Add-Check -Name "aks:workload-identity" -Status ($(if ($wiEnabled) { "PASS" } else { "WARN" })) -Details ("Workload identity enabled: {0}" -f $wiEnabled) -Critical $false
}
catch {
    Add-Check -Name "aks:identity-profile" -Status "WARN" -Details $_.Exception.Message -Critical $false
}

try {
    $nsOutput = & kubectl get namespace $Namespace -o name 2>&1
    if ($LASTEXITCODE -eq 0) {
        Add-Check -Name "k8s:namespace" -Status "PASS" -Details ("Namespace {0} already exists" -f $Namespace) -Critical $false
    }
    else {
        Add-Check -Name "k8s:namespace" -Status "WARN" -Details ("Namespace {0} does not exist yet; setup script will create it" -f $Namespace) -Critical $false
    }
}
catch {
    Add-Check -Name "k8s:namespace" -Status "WARN" -Details $_.Exception.Message -Critical $false
}

$report.summary = [pscustomobject]@{
    totalChecks = $report.checks.Count
    failedCritical = @($report.checks | Where-Object { $_.critical -and $_.status -eq "FAIL" }).Count
    warnings = @($report.checks | Where-Object { $_.status -eq "WARN" }).Count
    status = $(if ($script:HasCriticalFailure) { "BLOCKED" } else { "READY_OR_NEEDS_SETUP" })
}

$report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8

Write-Info ("Preflight report written to {0}" -f (Resolve-Path -Path $ReportPath))

if ($script:HasCriticalFailure) {
    Write-ErrorLine "Preflight completed with blocking failures"
    exit 1
}

Write-Success "Preflight completed without blocking failures"
