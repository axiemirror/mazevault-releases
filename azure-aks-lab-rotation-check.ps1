[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JwtToken,

    [string]$BaseUrl = "http://127.0.0.1:18080",
    [string]$SecretId,
    [string]$ConfigId,
    [string]$Reason = "AKS lab validation",
    [int]$PollIntervalSeconds = 5,
    [int]$TimeoutSeconds = 600,
    [switch]$Force
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

function Invoke-MazeVaultApi {
    param(
        [string]$Method,
        [string]$Uri,
        [object]$Body
    )

    $headers = @{ Authorization = "Bearer $JwtToken" }
    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 6)
    }

    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

if ([string]::IsNullOrWhiteSpace($SecretId) -and [string]::IsNullOrWhiteSpace($ConfigId)) {
    throw "Provide either -SecretId or -ConfigId"
}

if (-not [string]::IsNullOrWhiteSpace($SecretId) -and -not [string]::IsNullOrWhiteSpace($ConfigId)) {
    throw "Use only one of -SecretId or -ConfigId"
}

$body = @{ reason = $Reason; force = [bool]$Force }
if ($SecretId) {
    $triggerUri = "{0}/api/v1/secrets/{1}/rotate" -f $BaseUrl.TrimEnd("/"), $SecretId
}
else {
    $triggerUri = "{0}/api/v1/rotation/configs/{1}/trigger" -f $BaseUrl.TrimEnd("/"), $ConfigId
}

Write-Info ("Triggering rotation via {0}" -f $triggerUri)
$trigger = Invoke-MazeVaultApi -Method "POST" -Uri $triggerUri -Body $body
if (-not $trigger.execution_id) {
    throw "Rotation did not return execution_id"
}

$executionUri = "{0}/api/v1/rotation/executions/{1}" -f $BaseUrl.TrimEnd("/"), $trigger.execution_id
$stepsUri = "{0}/api/v1/rotation/executions/{1}/steps" -f $BaseUrl.TrimEnd("/"), $trigger.execution_id
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

Write-Info ("Execution {0} started with status {1}" -f $trigger.execution_id, $trigger.status)

do {
    Start-Sleep -Seconds $PollIntervalSeconds
    $execution = Invoke-MazeVaultApi -Method "GET" -Uri $executionUri -Body $null
    Write-Host (("[POLL] status={0} started_at={1}" -f $execution.status, $execution.started_at)) -ForegroundColor Yellow

    if ($execution.status -in @("completed", "failed", "canceled", "timed_out")) {
        $steps = Invoke-MazeVaultApi -Method "GET" -Uri $stepsUri -Body $null
        Write-Host ""
        Write-Host "Execution summary:" -ForegroundColor Cyan
        $execution | ConvertTo-Json -Depth 8
        Write-Host ""
        Write-Host "Execution steps:" -ForegroundColor Cyan
        $steps | ConvertTo-Json -Depth 8

        if ($execution.status -eq "completed") {
            Write-Success "Rotation completed successfully"
            exit 0
        }

        throw ("Rotation finished with terminal status: {0}" -f $execution.status)
    }
}
while ((Get-Date) -lt $deadline)

throw ("Timed out waiting for rotation execution {0}" -f $trigger.execution_id)
