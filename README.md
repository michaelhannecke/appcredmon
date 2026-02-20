# appcredmon — App Registration Credential Monitor

A lightweight Azure Function that monitors App Registration credential expiry across your Entra ID tenant and sends a weekly HTML email report. No dashboards. No manual checks. Just a boring, reliable email that tells you when something needs attention.

Built with PowerShell 7.4, Managed Identity authentication, and Microsoft Graph API. Runs on the Consumption plan — cost is negligible.

---

## How It Works

```
Azure Function App (Timer Trigger)
        │
        ├── Managed Identity
        │       ├── Graph API: Application.Read.All  (read-only)
        │       └── Graph API: Mail.Send
        │
        └── Key Vault
                ├── mail-sender
                └── mail-recipient
```

The function runs on a configurable schedule, queries all App Registrations via Graph API (with pagination), checks both **client secrets** and **certificates**, and sends a colour-coded HTML report:

- **Red** — already expired
- **Yellow** — expiring within your warning window
- **White** — healthy

Subject line: `[3 CRITICAL] App Registration Expiry Report - 2026-02-20` (or `[OK] ...` when nothing is urgent).

---

## Prerequisites

- Azure CLI (`az.cmd` on Windows, `az` on Linux/macOS)
- PowerShell 7 (`pwsh`) — not Windows PowerShell 5.1
- Contributor access on the target Azure subscription
- Microsoft 365 / Exchange Online with a mailbox for sending mail

> **Recommended:** Create a [Shared Mailbox](https://admin.microsoft.com) as the sender. It requires no additional license and is purpose-built for automated notifications.

---

## Repo Structure

```
appcredmon/
├── setup-appcredmon.ps1            # Infrastructure deployment script (az CLI)
├── function-code/
│   ├── host.json
│   ├── profile.ps1                 # Minimal stub — overrides default Az module calls
│   ├── requirements.psd1
│   └── CheckAppCredentials/
│       ├── function.json           # Timer trigger definition
│       └── run.ps1                 # Function logic
└── README.md
```

---

## Deployment

### Step 1 — Configure

Open `setup-appcredmon.ps1` and set the variables at the top:

```powershell
$subscriptionId   = "<your-subscription-id>"
$resourceGroup    = "<existing-resource-group>"
$location         = "westeurope"          # westeurope | switzerlandnorth | germanywestcentral
$suffix           = "credmon01"           # used for all resource names
$mailSender       = "monitoring@yourdomain.com"
$mailRecipient    = "security@yourdomain.com"
$warningDays      = "30"
$timerSchedule    = "0 0 7 * * *"        # daily at 07:00 UTC
```

### Step 2 — Run the Infrastructure Script

```powershell
az login
az account set --subscription "<your-subscription-id>"
pwsh -ExecutionPolicy Bypass -File .\setup-appcredmon.ps1
```

This creates: Storage Account, Application Insights, Key Vault (with mail secrets), Function App (with System-assigned Managed Identity), Key Vault RBAC, and Graph API permissions (`Application.Read.All` + `Mail.Send`).

### Step 3 — Set Mail Settings

> **Windows gotcha:** App Setting values containing `@` (like Key Vault References) break when passed directly to `az` on Windows. Always use the JSON file method:

```powershell
$settingsFile = "$env:TEMP\mailsettings.json"
@"
[
  { "name": "MAIL_SENDER",    "value": "monitoring@yourdomain.com" },
  { "name": "MAIL_RECIPIENT", "value": "security@yourdomain.com" }
]
"@ | Set-Content $settingsFile -Encoding UTF8

az.cmd functionapp config appsettings set `
    --name           func-credmon01 `
    --resource-group <your-resource-group> `
    --settings       "@$settingsFile"

Remove-Item $settingsFile
```

If you prefer Key Vault References, wait 90 seconds after the script completes and restart the Function App. Check the Portal under Environment Variables — a lock icon confirms the reference is resolved. Use plaintext as fallback if it doesn't resolve.

### Step 4 — Deploy Function Code

```powershell
cd function-code

Remove-Item ..\function.zip -ErrorAction SilentlyContinue
Compress-Archive -Path .\* -DestinationPath ..\function.zip -Force

az.cmd functionapp deployment source config-zip `
    --name           func-credmon01 `
    --resource-group <your-resource-group> `
    --src            ..\function.zip
```

### Step 5 — Verify Graph Permissions

```powershell
$miPrincipalId = az.cmd functionapp identity show `
    --name func-credmon01 --resource-group <rg> --query principalId -o tsv

az.cmd rest `
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$miPrincipalId/appRoleAssignments" `
    --query "value[].appRoleId"
```

Expected:
- `9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30` — Application.Read.All
- `b633e1c5-b582-4048-a93e-9f11b44c7e96` — Mail.Send

### Step 6 — Test

Timer triggers can't be invoked with `az functionapp function invoke` — that only works for HTTP triggers. Use the admin endpoint instead:

```powershell
$masterKey = az.cmd rest `
    --method POST `
    --url "https://management.azure.com/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Web/sites/func-credmon01/host/default/listkeys?api-version=2022-03-01" `
    --query "masterKey" --output tsv

Invoke-RestMethod `
    -Uri     "https://func-credmon01.azurewebsites.net/admin/functions/CheckAppCredentials" `
    -Method  POST `
    -Headers @{ "x-functions-key" = $masterKey; "Content-Type" = "application/json" } `
    -Body    '{}'
```

No output is normal. Check **Function App → CheckAppCredentials → Monitor** in the Portal for logs.

---

## Configuration Reference

All configuration is managed via App Settings — no redeployment needed to change them.

| Setting | Description | Example |
|---------|-------------|---------|
| `MAIL_SENDER` | Exchange Online mailbox to send from | `monitoring@yourdomain.com` |
| `MAIL_RECIPIENT` | Recipient(s), comma-separated | `security@yourdomain.com` |
| `WARNING_DAYS` | Days before expiry to flag as warning | `30` |
| `TIMER_SCHEDULE` | 6-field cron expression (UTC, seconds first) | `0 0 7 * * *` |

**Cron examples:**

```
0 0 7 * * *      → daily at 07:00 UTC
0 0 7 * * 1-5   → Mon–Fri at 07:00 UTC
0 0 6,14 * * *  → twice daily at 06:00 and 14:00 UTC
```

Azure Functions always runs in UTC. CET = UTC+1, CEST = UTC+2.

---

## Deploying to Additional Tenants

Change `$suffix` (and optionally resource name variables) in `setup-appcredmon.ps1` and run it against the new subscription. Each deployment is fully independent.

---

## Common Issues

| Error | Cause | Fix |
|-------|-------|-----|
| `Get-AzAccessToken not recognized` | Old `run.ps1` deployed | Redeploy with current version |
| `Access forbidden (socket)` | IMDS endpoint blocked on Consumption plan | Current `run.ps1` uses `IDENTITY_ENDPOINT` — redeploy |
| `ErrorInvalidUser` on sendMail | `MAIL_SENDER` is not a real Exchange Online mailbox | Use an existing licensed user or Shared Mailbox |
| `users//sendMail` (double slash) | `MAIL_SENDER` App Setting is empty | Set value via JSON file method |
| KV Reference not resolved | RBAC not fully propagated | Wait 90s, restart Function App, click "Pull reference values" in Portal |
| `profile.ps1` Az module errors | Default profile tries to load Az module | Ensure minimal `profile.ps1` stub is included in deployment zip |
| `Failed to load python executable` | Azure CLI Python installation corrupt | `winget upgrade Microsoft.AzureCLI`, open new terminal |

---

## Security Notes

- No credentials stored in code or environment variables
- Managed Identity handles all authentication — no client secrets on the Function App itself
- Graph permissions are least-privilege: `Application.Read.All` (read-only) + `Mail.Send`
- Key Vault uses RBAC mode; the Function MI has `Key Vault Secrets User` only
- HTTPS enforced, TLS 1.2 minimum, FTPS disabled


