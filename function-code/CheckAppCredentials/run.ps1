param($Timer)

Write-Host "AppCredential Monitor started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"

# ─── Configuration from App Settings ─────────────────────────────────────────
$mailSender    = $env:MAIL_SENDER
$mailRecipient = $env:MAIL_RECIPIENT
$warnDays      = if ($env:WARNING_DAYS) { [int]$env:WARNING_DAYS } else { 30 }

# ─── Acquire Graph API Token via Managed Identity (Functions MSI endpoint) ────
function Get-GraphToken {
    $endpoint = $env:IDENTITY_ENDPOINT
    $header   = $env:IDENTITY_HEADER

    if (-not $endpoint -or -not $header) {
        throw "Managed Identity not available. IDENTITY_ENDPOINT or IDENTITY_HEADER missing."
    }

    $response = Invoke-RestMethod `
        -Uri     "${endpoint}?resource=https://graph.microsoft.com/&api-version=2019-08-01" `
        -Headers @{ "X-IDENTITY-HEADER" = $header } `
        -Method  GET

    return $response.access_token
}

# ─── Get all App Registrations with pagination ────────────────────────────────
function Get-AllApplications {
    param($Headers)

    $apps = @()
    $uri  = "https://graph.microsoft.com/v1.0/applications" +
            "?`$select=displayName,appId,passwordCredentials,keyCredentials" +
            "&`$top=999"

    do {
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method GET
        $apps    += $response.value
        $uri      = $response.'@odata.nextLink'
    } while ($uri)

    Write-Host "Retrieved $($apps.Count) App Registrations"
    return $apps
}

# ─── Build expiry list ────────────────────────────────────────────────────────
function Build-ExpiryList {
    param($Apps, $Today)

    $list = @()

    foreach ($app in $Apps) {

        # Client Secrets (passwordCredentials)
        foreach ($secret in $app.passwordCredentials) {
            if (-not $secret.endDateTime) { continue }
            $expiry   = [DateTime]::Parse($secret.endDateTime).ToUniversalTime()
            $daysLeft = [Math]::Floor(($expiry - $Today).TotalDays)
            $list += [PSCustomObject]@{
                AppName    = $app.displayName
                AppId      = $app.appId
                CredType   = "Secret"
                CredName   = if ($secret.displayName) { $secret.displayName } else { "(unnamed)" }
                ExpiryDate = $expiry
                DaysLeft   = $daysLeft
            }
        }

        # Certificates (keyCredentials)
        foreach ($cert in $app.keyCredentials) {
            if (-not $cert.endDateTime) { continue }
            $expiry   = [DateTime]::Parse($cert.endDateTime).ToUniversalTime()
            $daysLeft = [Math]::Floor(($expiry - $Today).TotalDays)
            $list += [PSCustomObject]@{
                AppName    = $app.displayName
                AppId      = $app.appId
                CredType   = "Certificate"
                CredName   = if ($cert.displayName) { $cert.displayName } else { "(unnamed)" }
                ExpiryDate = $expiry
                DaysLeft   = $daysLeft
            }
        }
    }

    return $list | Sort-Object ExpiryDate
}

# ─── Build HTML Table Rows ────────────────────────────────────────────────────
function Build-HtmlRows {
    param($Items, $WarnDays)

    $sb = [System.Text.StringBuilder]::new()

    foreach ($item in $Items) {
        if ($item.DaysLeft -lt 0) {
            $rowStyle = 'background-color:#8B0000; color:white;'
            $badge    = 'EXPIRED'
        } elseif ($item.DaysLeft -lt $WarnDays) {
            $rowStyle = 'background-color:#FFF3CD;'
            $badge    = "EXPIRING: $($item.DaysLeft)d"
        } else {
            $rowStyle = ''
            $badge    = "$($item.DaysLeft)d"
        }

        [void]$sb.Append(@"
<tr style="$rowStyle">
    <td style="padding:6px 10px;">$($item.AppName)</td>
    <td style="padding:6px 10px; font-family:monospace; font-size:12px;">$($item.AppId)</td>
    <td style="padding:6px 10px;">$($item.CredType)</td>
    <td style="padding:6px 10px;">$($item.CredName)</td>
    <td style="padding:6px 10px;">$($item.ExpiryDate.ToString('yyyy-MM-dd'))</td>
    <td style="padding:6px 10px; text-align:center; font-weight:bold;">$badge</td>
</tr>
"@)
    }

    return $sb.ToString()
}

# ─── Build full HTML email ────────────────────────────────────────────────────
function Build-HtmlEmail {
    param($SortedList, $Today, $WarnDays)

    $critical = $SortedList | Where-Object { $_.DaysLeft -lt $WarnDays -and $_.DaysLeft -ge 0 }
    $expired  = $SortedList | Where-Object { $_.DaysLeft -lt 0 }

    $warningBanner = ""
    if ($expired.Count -gt 0 -or $critical.Count -gt 0) {
        $expiredNote  = if ($expired.Count -gt 0)  { "<li><strong>$($expired.Count) credential(s) already EXPIRED</strong></li>" } else { "" }
        $criticalNote = if ($critical.Count -gt 0) { "<li><strong>$($critical.Count) credential(s) expire within $WarnDays days</strong></li>" } else { "" }

        $warningBanner = @"
<div style="background-color:#dc3545; color:white; padding:15px 20px; border-radius:6px; margin-bottom:20px;">
    <h2 style="margin:0 0 8px 0;">Action Required</h2>
    <ul style="margin:0; padding-left:20px;">
        $expiredNote
        $criticalNote
    </ul>
</div>
"@
    }

    $tableRows = Build-HtmlRows -Items $SortedList -WarnDays $WarnDays

    return @"
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body style="font-family:Segoe UI, Arial, sans-serif; color:#333; max-width:900px; margin:0 auto; padding:20px;">
    <h1 style="color:#0066cc; border-bottom:2px solid #0066cc; padding-bottom:10px;">
        App Registration Credential Expiry Report
    </h1>
    <p style="color:#666;">Generated: <strong>$($Today.ToString('yyyy-MM-dd HH:mm')) UTC</strong>
       &nbsp;|&nbsp; Total credentials: <strong>$($SortedList.Count)</strong></p>

    $warningBanner

    <table style="width:100%; border-collapse:collapse; border:1px solid #ddd;">
        <thead>
            <tr style="background-color:#0066cc; color:white;">
                <th style="padding:8px 10px; text-align:left;">App Name</th>
                <th style="padding:8px 10px; text-align:left;">App ID</th>
                <th style="padding:8px 10px; text-align:left;">Type</th>
                <th style="padding:8px 10px; text-align:left;">Credential Name</th>
                <th style="padding:8px 10px; text-align:left;">Expires</th>
                <th style="padding:8px 10px; text-align:center;">Days Left</th>
            </tr>
        </thead>
        <tbody>
            $tableRows
        </tbody>
    </table>

    <p style="margin-top:20px; font-size:12px; color:#999;">
        Red = Expired | Yellow = Expires within $WarnDays days | White = OK
    </p>
</body>
</html>
"@
}

# ─── Send mail via Graph API ──────────────────────────────────────────────────
function Send-GraphMail {
    param($Headers, $Sender, $Recipient, $Subject, $HtmlBody)

    $payload = @{
        message = @{
            subject = $Subject
            body    = @{
                contentType = "HTML"
                content     = $HtmlBody
            }
            toRecipients = @(
                @{ emailAddress = @{ address = $Recipient } }
            )
        }
        saveToSentItems = $false
    } | ConvertTo-Json -Depth 10

    Invoke-RestMethod `
        -Uri         "https://graph.microsoft.com/v1.0/users/$Sender/sendMail" `
        -Headers     $Headers `
        -Method      POST `
        -Body        $payload `
        -ContentType "application/json; charset=utf-8"

    Write-Host "Mail sent to $Recipient"
}

# ─── Main ────────────────────────────────────────────────────────────────────
try {
    $today   = [DateTime]::UtcNow
    $token   = Get-GraphToken
    $headers = @{ Authorization = "Bearer $token" }

    $apps       = Get-AllApplications -Headers $headers
    $expiryList = Build-ExpiryList -Apps $apps -Today $today

    if ($expiryList.Count -eq 0) {
        Write-Host "No credentials found. Exiting."
        return
    }

    $htmlEmail = Build-HtmlEmail -SortedList $expiryList -Today $today -WarnDays $warnDays

    $criticalCount = ($expiryList | Where-Object { $_.DaysLeft -lt $warnDays }).Count
    $subject = if ($criticalCount -gt 0) {
        "[$criticalCount CRITICAL] App Registration Expiry Report - $($today.ToString('yyyy-MM-dd'))"
    } else {
        "[OK] App Registration Expiry Report - $($today.ToString('yyyy-MM-dd'))"
    }

    Send-GraphMail `
        -Headers   $headers `
        -Sender    $mailSender `
        -Recipient $mailRecipient `
        -Subject   $subject `
        -HtmlBody  $htmlEmail

    Write-Host "Done. Processed $($expiryList.Count) credentials across $($apps.Count) App Registrations."

} catch {
    Write-Error "Fatal error: $_"
    throw
}
