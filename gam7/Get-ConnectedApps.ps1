# ---------------------------------------------------------------
# Get-ConnectedApps.ps1
# Audits all Connected Apps & Integrations across Google Workspace
# Covers: OAuth Apps, Marketplace Apps, Service Accounts
# Flags:  Risky scopes, Stale apps (90d), Sensitive data access
# ---------------------------------------------------------------

# --- CONFIGURATION ---
$AdminEmail   = "admin-narendra@rocheua.com"
$GamPath      = Join-Path $PSScriptRoot "gam.exe"
$CurrentDir   = Get-Location
$Timestamp    = Get-Date -Format "yyyyMMdd_HHmmss"
$StaleThresh  = 90   # days - apps not used within this are flagged stale

# --- Sensitive OAuth scopes to flag ---
$SensitiveScopes = @(
    "https://www.googleapis.com/auth/gmail",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/contacts",
    "https://www.googleapis.com/auth/admin",
    "https://www.googleapis.com/auth/cloud-platform",
    "https://mail.google.com",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/docs"
)

# --- Broad/risky scope keywords ---
$RiskyKeywords = @(
    "auth/admin",
    "cloud-platform",
    "auth/gmail",
    "auth/drive",
    "auth/contacts",
    "readonly",         # broad read access
    "auth/calendar",
    "https://mail.google.com"
)

# --- Raw temp files ---
$RawOAuthCSV       = "$CurrentDir\raw_oauth_tokens.csv"
$RawMarketplaceCSV = "$CurrentDir\raw_marketplace_apps.csv"
$RawServiceAccCSV  = "$CurrentDir\raw_service_accounts.csv"

# --- Final output files ---
$OAuthReportCSV       = "$CurrentDir\APPS_OAuth_$Timestamp.csv"
$MarketplaceReportCSV = "$CurrentDir\APPS_Marketplace_$Timestamp.csv"
$ServiceAccReportCSV  = "$CurrentDir\APPS_ServiceAccounts_$Timestamp.csv"
$RiskReportCSV        = "$CurrentDir\APPS_RISK_FLAGGED_$Timestamp.csv"
$SummaryCSV           = "$CurrentDir\APPS_SUMMARY_$Timestamp.csv"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Connected Apps & Integration Audit      " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Timestamp  : $Timestamp"
Write-Host "Admin      : $AdminEmail"
Write-Host "Stale Threshold : $StaleThresh days"
Write-Host ""

# ---------------------------------------------------------------
# Helper: Wait for file with timeout
# ---------------------------------------------------------------
function Wait-ForFile($filePath, $timeoutSec = 180) {
    $elapsed = 0
    Write-Host "   Waiting for GAM output..." -NoNewline
    while (-not (Test-Path $filePath)) {
        if ($elapsed -ge $timeoutSec) {
            Write-Host "`nERROR: Timed out after $timeoutSec seconds: $filePath" -ForegroundColor Red
            exit 1
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
        Write-Host "." -NoNewline
    }
    Write-Host " Done." -ForegroundColor Green
}

# ---------------------------------------------------------------
# Helper: Classify risk level based on scopes
# ---------------------------------------------------------------
function Get-RiskLevel($scopes) {
    if (-not $scopes) { return "Unknown" }
    $s = $scopes.ToLower()
    # Check for admin/cloud-platform = Critical
    if ($s -match "auth/admin" -or $s -match "cloud-platform") { return "Critical" }
    # Check for Gmail/Drive full access = High
    if (($s -match "auth/gmail[^.]") -or ($s -match "auth/drive[^.]") -or ($s -match "mail\.google\.com")) { return "High" }
    # Check for sensitive but scoped = Medium
    if ($s -match "auth/drive" -or $s -match "auth/calendar" -or $s -match "auth/contacts" -or $s -match "auth/spreadsheets") { return "Medium" }
    return "Low"
}

# ---------------------------------------------------------------
# Helper: Check if scopes touch sensitive services
# ---------------------------------------------------------------
function Get-SensitiveServices($scopes) {
    if (-not $scopes) { return "" }
    $found = @()
    if ($scopes -match "gmail|mail\.google")   { $found += "Gmail" }
    if ($scopes -match "drive|spreadsheets|docs") { $found += "Drive/Docs" }
    if ($scopes -match "calendar")             { $found += "Calendar" }
    if ($scopes -match "contacts")             { $found += "Contacts" }
    if ($scopes -match "admin")                { $found += "Admin SDK" }
    if ($scopes -match "cloud-platform")       { $found += "Cloud Platform" }
    return ($found -join ", ")
}

# ---------------------------------------------------------------
# STEP 1: OAuth Tokens (3rd party apps authorized by users)
# ---------------------------------------------------------------
Write-Host "[1/3] Fetching OAuth authorized tokens (per user)..." -ForegroundColor Yellow

$gamOAuthArgs = @(
    "redirect", "csv", $RawOAuthCSV,
    "multiprocess",
    "all", "users",
    "print", "tokens"
)
& $GamPath @gamOAuthArgs
Wait-ForFile $RawOAuthCSV

$rawOAuth = Import-Csv $RawOAuthCSV
Write-Host "   Raw OAuth token records: $($rawOAuth.Count)"

$oauthReport = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($row in $rawOAuth) {
    $scopes       = $row.scopes
    $lastUsed     = $row.lastTimeUsed
    $riskLevel    = Get-RiskLevel $scopes
    $sensitiveHit = Get-SensitiveServices $scopes

    # Stale check
    $isStale = $false
    if ($lastUsed) {
        try {
            $lastUsedDate = [datetime]::Parse($lastUsed)
            $isStale = ((Get-Date) - $lastUsedDate).Days -gt $StaleThresh
        } catch { $isStale = $false }
    }

    # Broad scope check
    $isBroad = $false
    foreach ($kw in $RiskyKeywords) {
        if ($scopes -match [regex]::Escape($kw)) { $isBroad = $true; break }
    }

    $oauthReport.Add([PSCustomObject]@{
        Type             = "OAuth"
        UserEmail        = $row.userKey
        AppName          = $row.displayText
        AppID            = $row.clientId
        Scopes           = $scopes
        SensitiveAccess  = $sensitiveHit
        RiskLevel        = $riskLevel
        BroadScope       = $isBroad
        LastUsed         = $lastUsed
        IsStale          = $isStale
        Anonymous        = $row.anonymous
        NativeApp        = $row.nativeApp
    })
}

$oauthReport | Export-Csv $OAuthReportCSV -NoTypeInformation
Write-Host "   OAuth apps processed: $($oauthReport.Count)" -ForegroundColor Green

# ---------------------------------------------------------------
# STEP 2: Marketplace Apps (org-installed)
# ---------------------------------------------------------------
Write-Host "[2/3] Fetching Marketplace Apps..." -ForegroundColor Yellow

$gamMktArgs = @(
    "redirect", "csv", $RawMarketplaceCSV,
    "user", $AdminEmail,
    "print", "appsactivity"         # GAM command for installed marketplace apps
)

# Note: Some GAM versions use 'print installedapps' - try both
$gamMktArgs2 = @(
    "redirect", "csv", $RawMarketplaceCSV,
    "user", $AdminEmail,
    "print", "installedapps"
)

& $GamPath @gamMktArgs 2>$null
Start-Sleep -Seconds 3

if (-not (Test-Path $RawMarketplaceCSV) -or (Get-Item $RawMarketplaceCSV).Length -eq 0) {
    Write-Host "   Trying alternate GAM command for Marketplace..." -ForegroundColor DarkYellow
    & $GamPath @gamMktArgs2 2>$null
    Start-Sleep -Seconds 3
}

$marketplaceReport = [System.Collections.Generic.List[PSCustomObject]]::new()

if (Test-Path $RawMarketplaceCSV) {
    $rawMkt = Import-Csv $RawMarketplaceCSV
    Write-Host "   Raw Marketplace records: $($rawMkt.Count)"

    foreach ($row in $rawMkt) {
        $marketplaceReport.Add([PSCustomObject]@{
            Type        = "Marketplace"
            AppName     = if ($row.displayText) { $row.displayText } else { $row.applicationId }
            AppID       = if ($row.applicationId) { $row.applicationId } else { $row.clientId }
            InstalledBy = $row.userKey
            OrgUnit     = $row.orgUnitPath
            Scopes      = $row.scopes
            SensitiveAccess = Get-SensitiveServices $row.scopes
            RiskLevel   = Get-RiskLevel $row.scopes
        })
    }
    $marketplaceReport | Export-Csv $MarketplaceReportCSV -NoTypeInformation
    Write-Host "   Marketplace apps processed: $($marketplaceReport.Count)" -ForegroundColor Green
} else {
    Write-Host "   WARNING: Could not retrieve Marketplace apps. May require super admin audit scope." -ForegroundColor DarkYellow
    # Write empty file so the summary doesn't fail
    [PSCustomObject]@{ Note = "No data retrieved" } | Export-Csv $MarketplaceReportCSV -NoTypeInformation
}

# ---------------------------------------------------------------
# STEP 3: Service Accounts with Domain-Wide Delegation
# ---------------------------------------------------------------
Write-Host "[3/3] Fetching Service Accounts (Domain-Wide Delegation)..." -ForegroundColor Yellow

$gamSvcArgs = @(
    "redirect", "csv", $RawServiceAccCSV,
    "user", $AdminEmail,
    "print", "domainwidedelegation"
)
& $GamPath @gamSvcArgs 2>$null
Start-Sleep -Seconds 3

$serviceAccReport = [System.Collections.Generic.List[PSCustomObject]]::new()

if (Test-Path $RawServiceAccCSV) {
    $rawSvc = Import-Csv $RawServiceAccCSV
    Write-Host "   Raw Service Account records: $($rawSvc.Count)"

    foreach ($row in $rawSvc) {
        $scopes    = $row.scopes
        $riskLevel = Get-RiskLevel $scopes

        $serviceAccReport.Add([PSCustomObject]@{
            Type            = "ServiceAccount"
            ClientName      = $row.displayText
            ClientID        = $row.clientId
            Scopes          = $scopes
            SensitiveAccess = Get-SensitiveServices $scopes
            RiskLevel       = $riskLevel
            BroadScope      = ($riskLevel -in @("High", "Critical"))
        })
    }
    $serviceAccReport | Export-Csv $ServiceAccReportCSV -NoTypeInformation
    Write-Host "   Service accounts processed: $($serviceAccReport.Count)" -ForegroundColor Green
} else {
    Write-Host "   WARNING: Could not retrieve Service Accounts. Check admin privileges." -ForegroundColor DarkYellow
    [PSCustomObject]@{ Note = "No data retrieved" } | Export-Csv $ServiceAccReportCSV -NoTypeInformation
}

# ---------------------------------------------------------------
# STEP 4: Build consolidated RISK FLAGGED report
# (All app types - flagged as Stale, Risky, or Sensitive)
# ---------------------------------------------------------------
Write-Host ""
Write-Host "[+] Building Risk Flagged consolidated report..." -ForegroundColor Yellow

$riskReport = [System.Collections.Generic.List[PSCustomObject]]::new()

# From OAuth
foreach ($app in $oauthReport) {
    $flags = @()
    if ($app.RiskLevel -in @("High","Critical"))  { $flags += "Risky Scopes" }
    if ($app.IsStale)                              { $flags += "Stale (90d+)" }
    if ($app.SensitiveAccess)                      { $flags += "Sensitive: $($app.SensitiveAccess)" }

    if ($flags.Count -gt 0) {
        $riskReport.Add([PSCustomObject]@{
            AppType         = "OAuth"
            AppName         = $app.AppName
            AppID           = $app.AppID
            UserEmail       = $app.UserEmail
            RiskLevel       = $app.RiskLevel
            Flags           = ($flags -join " | ")
            SensitiveAccess = $app.SensitiveAccess
            LastUsed        = $app.LastUsed
            IsStale         = $app.IsStale
            Scopes          = $app.Scopes
        })
    }
}

# From Service Accounts
foreach ($app in $serviceAccReport) {
    $flags = @()
    if ($app.RiskLevel -in @("High","Critical")) { $flags += "Risky Scopes" }
    if ($app.SensitiveAccess)                    { $flags += "Sensitive: $($app.SensitiveAccess)" }

    if ($flags.Count -gt 0) {
        $riskReport.Add([PSCustomObject]@{
            AppType         = "ServiceAccount"
            AppName         = $app.ClientName
            AppID           = $app.ClientID
            UserEmail       = "N/A (Domain-Wide)"
            RiskLevel       = $app.RiskLevel
            Flags           = ($flags -join " | ")
            SensitiveAccess = $app.SensitiveAccess
            LastUsed        = "N/A"
            IsStale         = $false
            Scopes          = $app.Scopes
        })
    }
}

$riskReport = $riskReport | Sort-Object RiskLevel, AppType, AppName
$riskReport | Export-Csv $RiskReportCSV -NoTypeInformation
Write-Host "   Risk-flagged entries: $($riskReport.Count)" -ForegroundColor $(if ($riskReport.Count -gt 0) { "Red" } else { "Green" })

# ---------------------------------------------------------------
# STEP 5: Summary
# ---------------------------------------------------------------
$criticalCount = ($riskReport | Where-Object { $_.RiskLevel -eq "Critical" }).Count
$highCount     = ($riskReport | Where-Object { $_.RiskLevel -eq "High" }).Count
$staleCount    = ($oauthReport | Where-Object { $_.IsStale }).Count
$sensitiveCount= ($riskReport | Where-Object { $_.SensitiveAccess -ne "" }).Count

$summary = [PSCustomObject]@{
    ReportDate            = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    TotalOAuthApps        = $oauthReport.Count
    TotalMarketplaceApps  = $marketplaceReport.Count
    TotalServiceAccounts  = $serviceAccReport.Count
    TotalRiskFlagged      = $riskReport.Count
    CriticalRisk          = $criticalCount
    HighRisk              = $highCount
    StaleApps_90d         = $staleCount
    SensitiveDataAccess   = $sensitiveCount
}
$summary | Export-Csv $SummaryCSV -NoTypeInformation

# Cleanup temp files
Remove-Item $RawOAuthCSV       -Force -ErrorAction SilentlyContinue
Remove-Item $RawMarketplaceCSV -Force -ErrorAction SilentlyContinue
Remove-Item $RawServiceAccCSV  -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------
# FINAL OUTPUT
# ---------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "           AUDIT COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "OAuth Apps Found         : $($oauthReport.Count)"
Write-Host "Marketplace Apps Found   : $($marketplaceReport.Count)"
Write-Host "Service Accounts Found   : $($serviceAccReport.Count)"
Write-Host ""
Write-Host "--- Risk Summary ---" -ForegroundColor Yellow
Write-Host "  Critical Risk          : $criticalCount"  -ForegroundColor $(if ($criticalCount -gt 0) {"Red"} else {"Green"})
Write-Host "  High Risk              : $highCount"      -ForegroundColor $(if ($highCount -gt 0) {"DarkYellow"} else {"Green"})
Write-Host "  Stale Apps (90d+)      : $staleCount"     -ForegroundColor $(if ($staleCount -gt 0) {"DarkYellow"} else {"Green"})
Write-Host "  Sensitive Data Access  : $sensitiveCount" -ForegroundColor $(if ($sensitiveCount -gt 0) {"DarkYellow"} else {"Green"})
Write-Host ""
Write-Host "Reports saved:" -ForegroundColor Cyan
Write-Host "  OAuth Apps     -> $OAuthReportCSV"
Write-Host "  Marketplace    -> $MarketplaceReportCSV"
Write-Host "  Service Accts  -> $ServiceAccReportCSV"
Write-Host "  RISK FLAGGED   -> $RiskReportCSV" -ForegroundColor Red
Write-Host "  Summary        -> $SummaryCSV"
