[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$AksName,

    [Parameter(Mandatory = $true)]
    [string]$AcrName,

    [Parameter(Mandatory = $true)]
    [string]$AcrRepository,

    [Parameter(Mandatory = $true)]
    [string]$ImageTag,

    [Parameter(Mandatory = $true)]
    [string]$PrimaryBackendUrl,

    [Parameter(Mandatory = $true)]
    [string]$GatewayBootstrapToken,

    [Parameter(Mandatory = $true)]
    [string]$PostgresServerName,

    [Parameter(Mandatory = $true)]
    [string]$PostgresAdminUser,

    [Parameter(Mandatory = $true)]
    [string]$PostgresAdminPassword,

    [Parameter(Mandatory = $true)]
    [string]$RedisName,

    [Parameter(Mandatory = $true)]
    [string]$SqlServerName,

    [Parameter(Mandatory = $true)]
    [string]$SqlAdminUser,

    [Parameter(Mandatory = $true)]
    [string]$SqlAdminPassword,

    [string]$SubscriptionId,
    [string]$Namespace = "mazevault-lab",
    [string]$ServiceAccountName = "mazevault-gateway-lab",
    [string]$DeploymentName = "mazevault-gateway-lab",
    [string]$GatewayName = "mazevault-gateway-lab-01",
    [string]$GatewayEnvironment = "NPR",
    [ValidateSet("primary", "dr-standby")]
    [string]$GatewayRole = "primary",
    [string]$IdentityName = "id-mazevault-gateway-lab",
    [string]$KeyVaultName,
    [string]$PostgresDatabaseName = "mazevault_gateway",
    [string]$SqlDatabaseName = "mazevault-rotation-lab",
    [string]$MazeVaultVersion = "lab",
    [string]$MazeVaultRegion = "EU",
    [string]$CustomerName = "MazeVault Lab",
    [string]$CustomerEmail = "lab@example.invalid",
    [string]$CompanyId = "LAB-001",
    [string]$ImagePullPolicy = "Always",
    [switch]$RunSmokeTest,
    [switch]$SkipPostgresCreate,
    [switch]$SkipRedisCreate,
    [switch]$SkipSqlCreate
)

$ErrorActionPreference = "Stop"

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

function Test-AzCommand {
    param([string[]]$Arguments)
    try {
        $null = Invoke-AzText -Arguments $Arguments
        return $true
    }
    catch {
        return $false
    }
}

function New-Base64Key {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes)
}

function Quote-YamlValue {
    param([string]$Value)
    if ($null -eq $Value) {
        return "''"
    }

    return "'" + $Value.Replace("'", "''") + "'"
}

function Ensure-Command {
    param([string]$CommandName)
    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw ("Required command not found in PATH: {0}" -f $CommandName)
    }
}

function Ensure-AzureContext {
    if ($SubscriptionId) {
        Invoke-AzText -Arguments @("account", "set", "--subscription", $SubscriptionId)
    }

    $account = Invoke-AzJson -Arguments @("account", "show", "-o", "json")
    Write-Success ("Using Azure subscription {0}" -f $account.name)
}

function Ensure-ResourceExists {
    param(
        [string]$Description,
        [string[]]$Arguments
    )

    if (-not (Test-AzCommand -Arguments $Arguments)) {
        throw ("Required resource missing: {0}" -f $Description)
    }

    Write-Success ("Verified {0}" -f $Description)
}

function Ensure-AksAccess {
    Write-Info "Preparing AKS access"
    $null = Invoke-AzText -Arguments @("aks", "update", "--resource-group", $ResourceGroup, "--name", $AksName, "--enable-oidc-issuer", "--enable-workload-identity")
    $null = Invoke-AzText -Arguments @("aks", "update", "--resource-group", $ResourceGroup, "--name", $AksName, "--attach-acr", $AcrName)
    $null = Invoke-AzText -Arguments @("aks", "get-credentials", "--resource-group", $ResourceGroup, "--name", $AksName, "--overwrite-existing")
    $null = & kubectl get nodes 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to reach AKS after get-credentials"
    }
    Write-Success "AKS context is ready"
}

function Ensure-Postgres {
    if (Test-AzCommand -Arguments @("postgres", "flexible-server", "show", "--resource-group", $ResourceGroup, "--name", $PostgresServerName, "-o", "json")) {
        Write-Success "Azure PostgreSQL Flexible Server already exists"
    }
    elseif (-not $SkipPostgresCreate) {
        Write-Info "Creating Azure PostgreSQL Flexible Server"
        $null = Invoke-AzText -Arguments @(
            "postgres", "flexible-server", "create",
            "--resource-group", $ResourceGroup,
            "--name", $PostgresServerName,
            "--location", $Location,
            "--admin-user", $PostgresAdminUser,
            "--admin-password", $PostgresAdminPassword,
            "--sku-name", "Standard_B1ms",
            "--tier", "Burstable",
            "--storage-size", "32",
            "--version", "16",
            "--public-access", "0.0.0.0"
        )
        Write-Success "Azure PostgreSQL Flexible Server created"
    }
    else {
        throw "Azure PostgreSQL Flexible Server is missing and creation was skipped"
    }

    if (-not (Test-AzCommand -Arguments @("postgres", "flexible-server", "db", "show", "--resource-group", $ResourceGroup, "--server-name", $PostgresServerName, "--database-name", $PostgresDatabaseName, "-o", "json"))) {
        Write-Info "Creating PostgreSQL database"
        $null = Invoke-AzText -Arguments @(
            "postgres", "flexible-server", "db", "create",
            "--resource-group", $ResourceGroup,
            "--server-name", $PostgresServerName,
            "--database-name", $PostgresDatabaseName
        )
    }

    if (-not (Test-AzCommand -Arguments @("postgres", "flexible-server", "firewall-rule", "show", "--resource-group", $ResourceGroup, "--name", $PostgresServerName, "--rule-name", "AllowAzureServices", "-o", "json"))) {
        $null = Invoke-AzText -Arguments @(
            "postgres", "flexible-server", "firewall-rule", "create",
            "--resource-group", $ResourceGroup,
            "--name", $PostgresServerName,
            "--rule-name", "AllowAzureServices",
            "--start-ip-address", "0.0.0.0",
            "--end-ip-address", "0.0.0.0"
        )
    }

    return Invoke-AzJson -Arguments @("postgres", "flexible-server", "show", "--resource-group", $ResourceGroup, "--name", $PostgresServerName, "-o", "json")
}

function Ensure-Redis {
    if (Test-AzCommand -Arguments @("redis", "show", "--resource-group", $ResourceGroup, "--name", $RedisName, "-o", "json")) {
        Write-Success "Azure Cache for Redis already exists"
    }
    elseif (-not $SkipRedisCreate) {
        Write-Info "Creating Azure Cache for Redis"
        $null = Invoke-AzText -Arguments @(
            "redis", "create",
            "--resource-group", $ResourceGroup,
            "--name", $RedisName,
            "--location", $Location,
            "--sku", "Basic",
            "--vm-size", "c0",
            "--minimum-tls-version", "1.2",
            "--enable-non-ssl-port", "false"
        )
        Write-Success "Azure Cache for Redis created"
    }
    else {
        throw "Azure Cache for Redis is missing and creation was skipped"
    }

    return Invoke-AzJson -Arguments @("redis", "show", "--resource-group", $ResourceGroup, "--name", $RedisName, "-o", "json")
}

function Ensure-Sql {
    if (Test-AzCommand -Arguments @("sql", "server", "show", "--resource-group", $ResourceGroup, "--name", $SqlServerName, "-o", "json")) {
        Write-Success "Azure SQL server already exists"
    }
    elseif (-not $SkipSqlCreate) {
        Write-Info "Creating Azure SQL logical server"
        $null = Invoke-AzText -Arguments @(
            "sql", "server", "create",
            "--resource-group", $ResourceGroup,
            "--name", $SqlServerName,
            "--location", $Location,
            "--admin-user", $SqlAdminUser,
            "--admin-password", $SqlAdminPassword
        )
        Write-Success "Azure SQL logical server created"
    }
    else {
        throw "Azure SQL logical server is missing and creation was skipped"
    }

    if (-not (Test-AzCommand -Arguments @("sql", "db", "show", "--resource-group", $ResourceGroup, "--server", $SqlServerName, "--name", $SqlDatabaseName, "-o", "json"))) {
        Write-Info "Creating Azure SQL database"
        $null = Invoke-AzText -Arguments @(
            "sql", "db", "create",
            "--resource-group", $ResourceGroup,
            "--server", $SqlServerName,
            "--name", $SqlDatabaseName,
            "--service-objective", "Basic"
        )
    }

    if (-not (Test-AzCommand -Arguments @("sql", "server", "firewall-rule", "show", "--resource-group", $ResourceGroup, "--server", $SqlServerName, "--name", "AllowAzureServices", "-o", "json"))) {
        $null = Invoke-AzText -Arguments @(
            "sql", "server", "firewall-rule", "create",
            "--resource-group", $ResourceGroup,
            "--server", $SqlServerName,
            "--name", "AllowAzureServices",
            "--start-ip-address", "0.0.0.0",
            "--end-ip-address", "0.0.0.0"
        )
    }

    return Invoke-AzJson -Arguments @("sql", "server", "show", "--resource-group", $ResourceGroup, "--name", $SqlServerName, "-o", "json")
}

function Ensure-ManagedIdentity {
    if (-not (Test-AzCommand -Arguments @("identity", "show", "--resource-group", $ResourceGroup, "--name", $IdentityName, "-o", "json"))) {
        Write-Info "Creating user-assigned managed identity"
        $null = Invoke-AzText -Arguments @("identity", "create", "--resource-group", $ResourceGroup, "--name", $IdentityName, "--location", $Location)
    }

    return Invoke-AzJson -Arguments @("identity", "show", "--resource-group", $ResourceGroup, "--name", $IdentityName, "-o", "json")
}

function Ensure-FederatedCredential {
    param(
        [string]$IssuerUrl,
        [string]$CredentialName,
        [string]$Subject
    )

    $existing = Invoke-AzJson -Arguments @("identity", "federated-credential", "list", "--resource-group", $ResourceGroup, "--identity-name", $IdentityName, "-o", "json")
    if ($existing -and (@($existing | Where-Object { $_.name -eq $CredentialName }).Count -gt 0)) {
        Write-Success ("Federated credential {0} already exists" -f $CredentialName)
        return
    }

    Write-Info ("Creating federated credential {0}" -f $CredentialName)
    $null = Invoke-AzText -Arguments @(
        "identity", "federated-credential", "create",
        "--resource-group", $ResourceGroup,
        "--identity-name", $IdentityName,
        "--name", $CredentialName,
        "--issuer", $IssuerUrl,
        "--subject", $Subject,
        "--audiences", "api://AzureADTokenExchange"
    )
}

function Ensure-KeyVaultRoleAssignment {
    param(
        [string]$PrincipalId,
        [string]$RoleName,
        [string]$Scope
    )

    $assignments = Invoke-AzJson -Arguments @(
        "role", "assignment", "list",
        "--assignee-object-id", $PrincipalId,
        "--scope", $Scope,
        "--role", $RoleName,
        "-o", "json"
    )

    if ($assignments -and @($assignments).Count -gt 0) {
        Write-Success ("Role {0} already assigned on Key Vault" -f $RoleName)
        return
    }

    Write-Info ("Assigning role {0} on Key Vault" -f $RoleName)
    $null = Invoke-AzText -Arguments @(
        "role", "assignment", "create",
        "--assignee-object-id", $PrincipalId,
        "--assignee-principal-type", "ServicePrincipal",
        "--role", $RoleName,
        "--scope", $Scope
    )
}

function Ensure-NamespaceAndServiceAccount {
    param([string]$ManagedIdentityClientId)

    $nsYaml = @"
apiVersion: v1
kind: Namespace
metadata:
  name: $Namespace
"@

    $saYaml = @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $ServiceAccountName
  namespace: $Namespace
  annotations:
    azure.workload.identity/client-id: $ManagedIdentityClientId
"@

    $tmp = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tmp -Value ($nsYaml + "`n---`n" + $saYaml) -Encoding UTF8
    try {
        & kubectl apply -f $tmp | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "kubectl apply failed for namespace/service account"
        }
    }
    finally {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Apply-LabDeployment {
    param(
        [string]$Image,
        [string]$ManagedIdentityClientId,
        [string]$DatabaseUrl,
        [string]$RedisUrl,
        [string]$MasterKey,
        [string]$JwtKey
    )

    $secretYaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: ${DeploymentName}-env
  namespace: $Namespace
type: Opaque
stringData:
  DATABASE_URL: $(Quote-YamlValue $DatabaseUrl)
  REDIS_URL: $(Quote-YamlValue $RedisUrl)
  PRIMARY_BACKEND_URL: $(Quote-YamlValue $PrimaryBackendUrl)
  GATEWAY_BOOTSTRAP_TOKEN: $(Quote-YamlValue $GatewayBootstrapToken)
  MAZEVAULT_MASTER_KEY: $(Quote-YamlValue $MasterKey)
  MAZEVAULT_JWT_KEY: $(Quote-YamlValue $JwtKey)
  AZURE_MANAGED_IDENTITY_CLIENT_ID: $(Quote-YamlValue $ManagedIdentityClientId)
"@

    $manifestYaml = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DeploymentName
  namespace: $Namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DeploymentName
  template:
    metadata:
      labels:
        app: $DeploymentName
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: $ServiceAccountName
      securityContext:
        fsGroup: 1000
      containers:
        - name: mazevault-gateway
          image: $Image
          imagePullPolicy: $ImagePullPolicy
          ports:
            - containerPort: 8080
              name: http
          env:
            - name: MAZEVAULT_MODE
              value: gateway
            - name: MAZEVAULT_GATEWAY_ENVIRONMENT
              value: $GatewayEnvironment
            - name: MAZEVAULT_GATEWAY_ROLE
              value: $GatewayRole
            - name: GATEWAY_NAME
              value: $GatewayName
            - name: MAZEVAULT_REGION
              value: $MazeVaultRegion
            - name: MAZEVAULT_VERSION
              value: $MazeVaultVersion
            - name: MAZEVAULT_GATEWAY_STATE_FILE
              value: /data/gateway-state.json
            - name: MAZEVAULT_TLS_ENABLED
              value: "false"
            - name: GIN_MODE
              value: release
            - name: RUN_MIGRATIONS
              value: "true"
            - name: ENABLE_LICENSE_CHECK
              value: "false"
            - name: MAZEVAULT_ORCHESTRATOR_MODE
              value: "false"
            - name: MAZEVAULT_CUSTOMER_NAME
              value: $CustomerName
            - name: MAZEVAULT_CUSTOMER_EMAIL
              value: $CustomerEmail
            - name: MAZEVAULT_COMPANY_ID
              value: $CompanyId
          envFrom:
            - secretRef:
                name: ${DeploymentName}-env
          volumeMounts:
            - name: gateway-state
              mountPath: /data
            - name: gateway-bootstrap-material
              mountPath: /etc/mazevault
          readinessProbe:
            httpGet:
              path: /api/v1/health
              port: 8080
              scheme: HTTP
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /api/v1/health
              port: 8080
              scheme: HTTP
            initialDelaySeconds: 30
            periodSeconds: 15
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 1Gi
      volumes:
        - name: gateway-state
          emptyDir: {}
        - name: gateway-bootstrap-material
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: $DeploymentName
  namespace: $Namespace
spec:
  selector:
    app: $DeploymentName
  ports:
    - name: http
      port: 8080
      targetPort: 8080
  type: ClusterIP
"@

    $tmp = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tmp -Value ($secretYaml + "`n---`n" + $manifestYaml) -Encoding UTF8
    try {
        & kubectl apply -f $tmp | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "kubectl apply failed for lab deployment"
        }
    }
    finally {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SmokeTest {
    $portForward = Start-Process -FilePath "kubectl" -ArgumentList @("-n", $Namespace, "port-forward", "service/$DeploymentName", "18080:8080") -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Seconds 8
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:18080/api/v1/health" -Method Get -TimeoutSec 20
        Write-Success ("Health endpoint reachable: {0}" -f ($response | ConvertTo-Json -Depth 4 -Compress))
    }
    finally {
        if ($portForward -and -not $portForward.HasExited) {
            Stop-Process -Id $portForward.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

Ensure-Command -CommandName "az"
Ensure-Command -CommandName "kubectl"

Ensure-AzureContext
Ensure-ResourceExists -Description "resource group" -Arguments @("group", "show", "--name", $ResourceGroup, "-o", "json")
Ensure-ResourceExists -Description "AKS cluster" -Arguments @("aks", "show", "--resource-group", $ResourceGroup, "--name", $AksName, "-o", "json")
Ensure-ResourceExists -Description "ACR" -Arguments @("acr", "show", "--resource-group", $ResourceGroup, "--name", $AcrName, "-o", "json")

Ensure-AksAccess

$postgres = Ensure-Postgres
$redis = Ensure-Redis
$sql = Ensure-Sql
$identity = Ensure-ManagedIdentity

$oidcIssuerUrl = Invoke-AzText -Arguments @("aks", "show", "--resource-group", $ResourceGroup, "--name", $AksName, "--query", "oidcIssuerProfile.issuerUrl", "-o", "tsv")
if ([string]::IsNullOrWhiteSpace($oidcIssuerUrl)) {
    throw "OIDC issuer URL is empty; workload identity is not ready"
}

Ensure-FederatedCredential -IssuerUrl $oidcIssuerUrl -CredentialName ("{0}-fic" -f $ServiceAccountName) -Subject ("system:serviceaccount:{0}:{1}" -f $Namespace, $ServiceAccountName)

if ($KeyVaultName) {
    $keyVault = Invoke-AzJson -Arguments @("keyvault", "show", "--resource-group", $ResourceGroup, "--name", $KeyVaultName, "-o", "json")
    Ensure-KeyVaultRoleAssignment -PrincipalId $identity.principalId -RoleName "Key Vault Secrets User" -Scope $keyVault.id
}

Ensure-NamespaceAndServiceAccount -ManagedIdentityClientId $identity.clientId

$redisKeys = Invoke-AzJson -Arguments @("redis", "list-keys", "--resource-group", $ResourceGroup, "--name", $RedisName, "-o", "json")
$acr = Invoke-AzJson -Arguments @("acr", "show", "--resource-group", $ResourceGroup, "--name", $AcrName, "-o", "json")

$databaseUrl = "host={0} user={1} password={2} dbname={3} port=5432 sslmode=require" -f $postgres.fullyQualifiedDomainName, $PostgresAdminUser, $PostgresAdminPassword, $PostgresDatabaseName
$redisUrl = "rediss://:{0}@{1}:6380/0" -f $redisKeys.primaryKey, $redis.hostName
$masterKey = New-Base64Key
$jwtKey = New-Base64Key
$image = "{0}/{1}:{2}" -f $acr.loginServer, $AcrRepository, $ImageTag

Write-Info "Applying Kubernetes secret, deployment, and service"
Apply-LabDeployment -Image $image -ManagedIdentityClientId $identity.clientId -DatabaseUrl $databaseUrl -RedisUrl $redisUrl -MasterKey $masterKey -JwtKey $jwtKey

& kubectl rollout status deployment/$DeploymentName -n $Namespace --timeout=240s | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Deployment rollout did not complete successfully"
}

if ($RunSmokeTest) {
    Invoke-SmokeTest
}

Write-Success "MazeVault AKS lab setup completed"
Write-Host ""
Write-Host "Next values to keep:" -ForegroundColor Cyan
Write-Host ("  Namespace:            {0}" -f $Namespace)
Write-Host ("  Deployment:           {0}" -f $DeploymentName)
Write-Host ("  ServiceAccount:       {0}" -f $ServiceAccountName)
Write-Host ("  Managed Identity:     {0}" -f $identity.clientId)
Write-Host ("  PostgreSQL FQDN:      {0}" -f $postgres.fullyQualifiedDomainName)
Write-Host ("  Redis Host:           {0}" -f $redis.hostName)
Write-Host ("  Azure SQL Server:     {0}.database.windows.net" -f $SqlServerName)
Write-Host ("  Azure SQL Database:   {0}" -f $SqlDatabaseName)
Write-Host ""
Write-Host "Quick checks:" -ForegroundColor Cyan
Write-Host ("  kubectl get pods -n {0}" -f $Namespace)
Write-Host ("  kubectl port-forward -n {0} service/{1} 18080:8080" -f $Namespace, $DeploymentName)
Write-Host "  Open http://127.0.0.1:18080/api/v1/health"
