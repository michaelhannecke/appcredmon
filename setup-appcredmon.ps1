# =============================================================================
# setup-appcredmon.ps1
#
# Deploys the App Registration Credential Monitor infrastructure via az CLI.
#
# Requirements:
#   - Azure CLI (az.cmd on Windows, az on Linux/macOS)
#   - PowerShell 7 (pwsh)
#   - Contributor access on the target subscription
#
# Usage:
#   pwsh -ExecutionPolicy Bypass -File .\setup-appcredmon.ps1
# =============================================================================

# ─── CONFIG – edit these before running ──────────────────────────────────────

$subscriptionId   = "<your-subscription-id>"
$resourceGroup    = "<existing-resource-group>"
$location         = "westeurope"          # westeurope | switzerlandnorth | germanywestcentral
$suffix           = "credmon01"           # lowercase, alphanumeric only, kept short
$mailSender       = "<sender@yourdomain>" # must be a real Exchange Online mailbox
$mailRecipient    = "<recipient@yourdomain>"
$warningDays      = "30"
$timerSchedule    = "0 0 7 * * *"        # cron (6-field, UTC): daily at 07:00

# Optional: override individual resource names
$storageAccount   = "st${suffix}"
$functionApp      = "func-${suffix}"
$keyVaultName     = "kv-${suffix}"
$appInsightsName  = "appi-${suffix}"

# ─── HELPER ──────────────────────────────────────────────────────────────────

function Run {
    param([string]$Description, [scriptblock]$Command)
    Write-Host "`n>>> $Description" -ForegroundColor Cyan
    $result = & $Command
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
        throw "Step failed: $Description"
    }
    return $result
}

# On Windows, use az.cmd. On Linux/macOS, use az.
$azCmd = if ($IsWindows) { "az.cmd" } else { "az" }
function Invoke-Az { & $azCmd @args }

# ─── 0. LOGIN & SUBSCRIPTION ─────────────────────────────────────────────────

Write-Host "`n=== App Credential Monitor Setup ===" -ForegroundColor Yellow

Invoke-Az account set --subscription $subscriptionId
$tenantId = Invoke-Az account show --query tenantId -o tsv
Write-Host "    Tenant  : $tenantId"
Write-Host "    Location: $location"
Write-Host "    Suffix  : $suffix"

# ─── 1. STORAGE ACCOUNT ──────────────────────────────────────────────────────

Run "Create Storage Account: $storageAccount" {
    Invoke-Az storage account create `
        --name              $storageAccount `
        --resource-group    $resourceGroup `
        --location          $location `
        --sku               Standard_LRS `
        --kind              StorageV2 `
        --min-tls-version   TLS1_2 `
        --allow-blob-public-access false `
        --https-only        true `
        --output            none
}

$storageConnStr = Invoke-Az storage account show-connection-string `
    --name           $storageAccount `
    --resource-group $resourceGroup `
    --query          connectionString `
    -o               tsv

# ─── 2. APPLICATION INSIGHTS ─────────────────────────────────────────────────

Run "Create Application Insights: $appInsightsName" {
    Invoke-Az monitor app-insights component create `
        --app            $appInsightsName `
        --resource-group $resourceGroup `
        --location       $location `
        --kind           web `
        --output         none
}

$appInsightsConnStr = Invoke-Az monitor app-insights component show `
    --app            $appInsightsName `
    --resource-group $resourceGroup `
    --query          connectionString `
    -o               tsv

# ─── 3. KEY VAULT ─────────────────────────────────────────────────────────────

Run "Create Key Vault: $keyVaultName" {
    Invoke-Az keyvault create `
        --name                     $keyVaultName `
        --resource-group           $resourceGroup `
        --location                 $location `
        --enable-rbac-authorization true `
        --output                   none
}

$kvId = Invoke-Az keyvault show `
    --name           $keyVaultName `
    --resource-group $resourceGroup `
    --query          id `
    -o               tsv

# Grant Key Vault Admin to current user so we can write secrets
$myObjectId = Invoke-Az ad signed-in-user show --query id -o tsv

Run "Grant Key Vault Admin to current user" {
    Invoke-Az role assignment create `
        --assignee       $myObjectId `
        --role           "Key Vault Administrator" `
        --scope          $kvId `
        --output         none
}

# Wait for RBAC propagation before writing secrets
Write-Host "`n>>> Store secrets in Key Vault" -ForegroundColor Cyan
Write-Host "    Waiting 20s for RBAC propagation..." -ForegroundColor Gray
Start-Sleep -Seconds 20

Invoke-Az keyvault secret set --vault-name $keyVaultName --name "mail-sender"    --value $mailSender    --output none
Invoke-Az keyvault secret set --vault-name $keyVaultName --name "mail-recipient" --value $mailRecipient --output none
Write-Host "    Secrets stored" -ForegroundColor Green

$kvUri = Invoke-Az keyvault show `
    --name           $keyVaultName `
    --resource-group $resourceGroup `
    --query          properties.vaultUri `
    -o               tsv

# ─── 4. FUNCTION APP ─────────────────────────────────────────────────────────

Run "Create Function App: $functionApp" {
    Invoke-Az functionapp create `
        --name                    $functionApp `
        --resource-group          $resourceGroup `
        --consumption-plan-location $location `
        --storage-account         $storageAccount `
        --runtime                 powershell `
        --runtime-version         7.4 `
        --functions-version       4 `
        --app-insights            $appInsightsName `
        --assign-identity         "[system]" `
        --output                  none
}

$miPrincipalId = Invoke-Az functionapp identity show `
    --name           $functionApp `
    --resource-group $resourceGroup `
    --query          principalId `
    -o               tsv

Write-Host "    MI Principal ID: $miPrincipalId" -ForegroundColor Green

# ─── 5. KEY VAULT ACCESS FOR FUNCTION APP MI ─────────────────────────────────

Run "Grant Key Vault Secrets User to Function App MI" {
    Invoke-Az role assignment create `
        --assignee-object-id       $miPrincipalId `
        --assignee-principal-type  ServicePrincipal `
        --role                     "Key Vault Secrets User" `
        --scope                    $kvId `
        --output                   none
}

# ─── 6. APP SETTINGS ─────────────────────────────────────────────────────────
#
# Key Vault References use @Microsoft.KeyVault(...) syntax.
# On Windows, passing @ directly to az breaks silently (cmd.exe file reference).
# We write to a temp JSON file and pass @filepath instead.

Run "Configure Function App settings" {
    $settingsFile = "$env:TEMP\funcsettings_$suffix.json"
    @"
[
  { "name": "MAIL_SENDER",    "value": "@Microsoft.KeyVault(SecretUri=${kvUri}secrets/mail-sender/)" },
  { "name": "MAIL_RECIPIENT", "value": "@Microsoft.KeyVault(SecretUri=${kvUri}secrets/mail-recipient/)" },
  { "name": "WARNING_DAYS",   "value": "$warningDays" },
  { "name": "TIMER_SCHEDULE", "value": "$timerSchedule" }
]
"@ | Set-Content $settingsFile -Encoding UTF8

    Invoke-Az functionapp config appsettings set `
        --name           $functionApp `
        --resource-group $resourceGroup `
        --settings       "@$settingsFile" `
        --output         none

    Remove-Item $settingsFile
}

# Harden: HTTPS only, min TLS 1.2, FTPS disabled
Run "Harden Function App config" {
    Invoke-Az functionapp update `
        --name           $functionApp `
        --resource-group $resourceGroup `
        --set            httpsOnly=true `
        --output         none
}

Invoke-Az functionapp config set `
    --name              $functionApp `
    --resource-group    $resourceGroup `
    --min-tls-version   1.2 `
    --ftps-state        Disabled `
    --output            none

# ─── 7. GRAPH API PERMISSIONS ────────────────────────────────────────────────

Write-Host "`n>>> Assigning Microsoft Graph permissions to Managed Identity" -ForegroundColor Cyan
Write-Host "    Waiting 90s for MI propagation..." -ForegroundColor Gray
Start-Sleep -Seconds 90

$graphSpId    = Invoke-Az ad sp show --id "00000003-0000-0000-c000-000000000000" --query id -o tsv

$roleReadAll  = "9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30"  # Application.Read.All
$roleMailSend = "b633e1c5-b582-4048-a93e-9f11b44c7e96"  # Mail.Send

foreach ($roleId in @($roleReadAll, $roleMailSend)) {
    $roleName = if ($roleId -eq $roleReadAll) { "Application.Read.All" } else { "Mail.Send" }
    Write-Host "    Assigning $roleName ..." -ForegroundColor Gray

    $tmpFile = "$env:TEMP\graphperm_$roleId.json"
    @{ principalId = $miPrincipalId; resourceId = $graphSpId; appRoleId = $roleId } |
        ConvertTo-Json | Set-Content $tmpFile -Encoding UTF8

    Invoke-Az rest `
        --method  POST `
        --url     "https://graph.microsoft.com/v1.0/servicePrincipals/$miPrincipalId/appRoleAssignments" `
        --body    "@$tmpFile" `
        --headers "Content-Type=application/json" `
        --output  none

    Remove-Item $tmpFile
    Write-Host "    $roleName assigned" -ForegroundColor Green
}

# ─── SUMMARY ─────────────────────────────────────────────────────────────────

Write-Host "`n================================================" -ForegroundColor Green
Write-Host "  Setup Complete!" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Resource Group : $resourceGroup"
Write-Host "  Function App   : $functionApp"
Write-Host "  Key Vault      : $keyVaultName"
Write-Host "  MI Principal   : $miPrincipalId"
Write-Host ""
Write-Host "Next: deploy the function code" -ForegroundColor Yellow
Write-Host "  cd function-code"
Write-Host "  Compress-Archive -Path .\* -DestinationPath ..\function.zip -Force"
Write-Host "  az.cmd functionapp deployment source config-zip --name $functionApp --resource-group $resourceGroup --src ..\function.zip"
Write-Host ""
Write-Host "Manual test trigger:" -ForegroundColor Yellow
Write-Host "  See README.md, Step 6"
