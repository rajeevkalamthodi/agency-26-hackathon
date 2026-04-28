#Requires -Version 7.0
<#
  Per-team app deployment for Agency-26 Hackathon.
  Reads `.env` at the repo root and:
    1. `az acr build`s the dashboard + dossier images into the shared ACR
    2. Creates / updates two Container Apps in the platform Container Apps Env
       with secrets injected directly (no Key Vault wiring required)
  This script NEVER modifies APIM, Foundry, ACR, KV, or the Container Apps Env.

  Usage:
    pwsh ./deploy-app.ps1                       # build + deploy with .env values
    pwsh ./deploy-app.ps1 -SkipBuild            # just (re)deploy from existing :latest
    pwsh ./deploy-app.ps1 -SkipDeploy           # just rebuild images
    pwsh ./deploy-app.ps1 -Tag v1.0.0           # use a specific image tag
#>
[CmdletBinding()]
param(
  [string] $EnvFile = (Join-Path $PSScriptRoot '.env'),
  [string] $Tag,
  [switch] $SkipBuild,
  [switch] $SkipDeploy
)

$ErrorActionPreference = 'Stop'

# ---------- Load .env ---------------------------------------------------------
if (-not (Test-Path $EnvFile)) {
  throw "Missing $EnvFile. Copy .env.example to .env and fill in the values."
}
$cfg = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)\s*$') {
    $cfg[$Matches[1]] = $Matches[2].Trim('"').Trim("'")
  }
}
function Need($key) {
  if (-not $cfg[$key]) { throw "Set $key in $EnvFile" }
  return $cfg[$key]
}

$subId       = Need 'AZURE_SUBSCRIPTION_ID'
$prefix      = Need 'AZURE_PREFIX'
$platformRg  = Need 'PLATFORM_RG'
$acrName     = Need 'ACR_NAME'
$acrServer   = Need 'ACR_LOGIN_SERVER'
$caeName     = Need 'CONTAINER_APPS_ENV'
$apimGw      = Need 'APIM_GATEWAY_URL'
$apimKey     = Need 'APIM_SUBSCRIPTION_KEY'
$dbConn      = Need 'DB_CONNECTION_STRING'
$dashName    = $cfg['DASHBOARD_APP_NAME']; if (-not $dashName) { $dashName = "ca-$prefix-dashboard" }
$dossName    = $cfg['DOSSIER_APP_NAME'];   if (-not $dossName) { $dossName = "ca-$prefix-dossier"   }
$anthroKey   = $cfg['ANTHROPIC_API_KEY']  # optional

if (-not $Tag) {
  $Tag = $cfg['APP_IMAGE_TAG']
  if (-not $Tag) {
    try { $Tag = (git -C $PSScriptRoot rev-parse --short HEAD).Trim() } catch { $Tag = $null }
    if (-not $Tag) { $Tag = (Get-Date -Format 'yyyyMMddHHmm') }
  }
}

Write-Host "→ Using subscription $subId" -ForegroundColor Cyan
az account set --subscription $subId | Out-Null

# ---------- 1. Build images via ACR Tasks ------------------------------------
if (-not $SkipBuild) {
  Write-Host "→ Building agency26/dashboard:$Tag in $acrName" -ForegroundColor Cyan
  az acr build `
    --registry $acrName `
    --image "agency26/dashboard:$Tag" `
    --image "agency26/dashboard:latest" `
    --file (Join-Path $PSScriptRoot 'infra/docker/Dockerfile.dashboard') `
    $PSScriptRoot

  Write-Host "→ Building agency26/dossier:$Tag in $acrName" -ForegroundColor Cyan
  az acr build `
    --registry $acrName `
    --image "agency26/dossier:$Tag" `
    --image "agency26/dossier:latest" `
    --file (Join-Path $PSScriptRoot 'infra/docker/Dockerfile.dossier') `
    $PSScriptRoot
}

if ($SkipDeploy) { Write-Host "Skipping deploy." -ForegroundColor Yellow; exit 0 }

# ---------- 2. Ensure ACR pull permission for the apps -----------------------
# Use admin credentials (simplest, no extra UAMI). Enable admin temporarily
# only for the deploy; the apps themselves use the registry password secret.
Write-Host "→ Enabling ACR admin (needed for containerapp create with --registry-password)" -ForegroundColor Cyan
az acr update -n $acrName --admin-enabled true --output none
$acrUser = az acr credential show -n $acrName --query username -o tsv
$acrPass = az acr credential show -n $acrName --query 'passwords[0].value' -o tsv

$dashImage = "$acrServer/agency26/dashboard:$Tag"
$dossImage = "$acrServer/agency26/dossier:$Tag"
$caeId = az containerapp env show -n $caeName -g $platformRg --query id -o tsv

# ---------- 3. Deploy / update Dashboard -------------------------------------
function Deploy-App {
  param([string]$Name, [string]$Image, [int]$TargetPort)

  $exists = az containerapp show -n $Name -g $platformRg --query name -o tsv 2>$null

  $envVars = @(
    "PORT=$TargetPort",
    "APIM_GATEWAY_URL=$apimGw",
    "APIM_SUBSCRIPTION_KEY=secretref:apim-subscription-key",
    "DB_CONNECTION_STRING=secretref:db-connection-string"
  )
  $secrets = @(
    "apim-subscription-key=$apimKey",
    "db-connection-string=$dbConn"
  )
  if ($anthroKey) {
    $envVars += "ANTHROPIC_API_KEY=secretref:anthropic-api-key"
    $secrets += "anthropic-api-key=$anthroKey"
  }

  if (-not $exists) {
    Write-Host "→ Creating $Name" -ForegroundColor Cyan
    az containerapp create `
      --name $Name `
      --resource-group $platformRg `
      --environment $caeId `
      --image $Image `
      --registry-server $acrServer `
      --registry-username $acrUser `
      --registry-password $acrPass `
      --target-port $TargetPort `
      --ingress external `
      --min-replicas 1 --max-replicas 2 `
      --cpu 0.5 --memory 1.0Gi `
      --secrets @secrets `
      --env-vars @envVars `
      --output none
  } else {
    Write-Host "→ Updating $Name" -ForegroundColor Cyan
    # Refresh secrets in case values changed.
    az containerapp secret set `
      --name $Name --resource-group $platformRg `
      --secrets @secrets --output none
    az containerapp registry set `
      --name $Name --resource-group $platformRg `
      --server $acrServer --username $acrUser --password $acrPass --output none
    az containerapp update `
      --name $Name `
      --resource-group $platformRg `
      --image $Image `
      --set-env-vars @envVars `
      --output none
  }
}

Deploy-App -Name $dashName -Image $dashImage -TargetPort 3800
Deploy-App -Name $dossName -Image $dossImage -TargetPort 3801

# ---------- 4. Print FQDNs ----------------------------------------------------
$dashFqdn = az containerapp show -n $dashName -g $platformRg --query 'properties.configuration.ingress.fqdn' -o tsv
$dossFqdn = az containerapp show -n $dossName -g $platformRg --query 'properties.configuration.ingress.fqdn' -o tsv
Write-Host "`n→ Deployed:" -ForegroundColor Green
Write-Host "  Dashboard: https://$dashFqdn"
Write-Host "  Dossier  : https://$dossFqdn"
