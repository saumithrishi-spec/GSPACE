# --- CONFIGURATION ---
$AdminEmail = "admin-narendra@rocheua.com"
$GamPath    = Join-Path $PSScriptRoot "gam.exe"
$CurrentDir = Get-Location
$Timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"

# Output file paths
$RawUsersCSV = "$CurrentDir\raw_all_users.csv"
$DetailedCSV = "$CurrentDir\USER_DETAILED_REPORT_$Timestamp.csv"
$SummaryCSV  = "$CurrentDir\USER_SUMMARY_REPORT_$Timestamp.csv"

Write-Host "--- Starting Full Org User Audit ---" -ForegroundColor Cyan
Write-Host "Timestamp: $Timestamp"
Write-Host ""

# ---------------------------------------------------------------
# STEP 1: Pull ALL users (active + suspended) via GAM
# FIX: Use valid GAM field names (flat, no dot-notation, no quoting issues)
#      Pass arguments as an array via splatting to avoid PowerShell quoting problems
# ---------------------------------------------------------------
Write-Host "[1/3] Fetching all users from Google Workspace..." -ForegroundColor Yellow

$gamArgs = @(
    "redirect", "csv", $RawUsersCSV,
    "multiprocess",
    "user", $AdminEmail,
    "print", "users",
    "fields", "primaryEmail,fullname,firstname,lastname,orgunitpath,suspended,archived,isadmin,isdelegatedadmin,lastlogintime,creationtime,isenrolledin2sv,isenforcedin2sv"
)
& $GamPath @gamArgs

# Wait for file with timeout
$timeout = 120
$elapsed = 0
Write-Host "   Waiting for GAM to finish..." -NoNewline
while (-not (Test-Path $RawUsersCSV)) {
    if ($elapsed -ge $timeout) {
        Write-Host "`nERROR: Timed out waiting for GAM output after $timeout seconds." -ForegroundColor Red
        exit 1
    }
    Start-Sleep -Seconds 2
    $elapsed += 2
    Write-Host "." -NoNewline
}
Write-Host " Done." -ForegroundColor Green

# ---------------------------------------------------------------
# STEP 2: Import and validate raw data
# ---------------------------------------------------------------
Write-Host "[2/3] Processing user data..." -ForegroundColor Yellow

$rawUsers = Import-Csv $RawUsersCSV

if (-not $rawUsers -or $rawUsers.Count -eq 0) {
    Write-Host "ERROR: No user data found in the exported CSV." -ForegroundColor Red
    exit 1
}

# Peek at actual column names GAM produced (helps debug future field name issues)
Write-Host "   Columns in raw CSV: $($rawUsers[0].PSObject.Properties.Name -join ', ')"
Write-Host "   Total users loaded: $($rawUsers.Count)"

# ---------------------------------------------------------------
# STEP 3: Build Detailed + Summary reports
# FIX: GAM outputs column names in its own casing (e.g. "name.fullName", "primaryEmail")
#      We use a helper function to safely read a column regardless of case
# ---------------------------------------------------------------
function Get-Field($obj, [string[]]$names) {
    foreach ($n in $names) {
        $val = $obj.PSObject.Properties[$n]
        if ($val -and $val.Value -ne '') { return $val.Value }
    }
    return ""
}

$detailedReport = [System.Collections.Generic.List[PSCustomObject]]::new()
$summaryReport  = [System.Collections.Generic.List[PSCustomObject]]::new()

$countActive    = 0
$countSuspended = 0
$countArchived  = 0
$countAdmin     = 0
$count2SVOn     = 0

foreach ($user in $rawUsers) {

    # GAM may return "True"/"False" or "true"/"false" - use case-insensitive compare
    $isSuspended = (Get-Field $user "suspended")                              -ieq "True"
    $isArchived  = (Get-Field $user "archived")                               -ieq "True"
    $isAdmin     = ((Get-Field $user "isAdmin","isadmin")                     -ieq "True") -or
                   ((Get-Field $user "isDelegatedAdmin","isdelegatedadmin")   -ieq "True")
    $is2SVOn     = (Get-Field $user "isEnrolledIn2Sv","isenrolledin2sv")      -ieq "True"
    $is2SVForced = (Get-Field $user "isEnforcedIn2Sv","isenforcedin2sv")      -ieq "True"

    $statusLabel = if ($isSuspended) { "Suspended" } elseif ($isArchived) { "Archived" } else { "Active" }

    if ($isSuspended)    { $countSuspended++ }
    elseif ($isArchived) { $countArchived++  }
    else                 { $countActive++    }
    if ($isAdmin)  { $countAdmin++  }
    if ($is2SVOn)  { $count2SVOn++  }

    $detailedReport.Add([PSCustomObject]@{
        FullName       = Get-Field $user "name.fullName","fullName","fullname"
        FirstName      = Get-Field $user "name.givenName","givenName","firstname","givenname"
        LastName       = Get-Field $user "name.familyName","familyName","lastname","familyname"
        PrimaryEmail   = Get-Field $user "primaryEmail","primaryemail"
        OrgUnit        = Get-Field $user "orgUnitPath","orgunitpath"
        AccountStatus  = $statusLabel
        Suspended      = $isSuspended
        Archived       = $isArchived
        IsAdmin        = $isAdmin
        MFA_Enrolled   = $is2SVOn
        MFA_Enforced   = $is2SVForced
        LastLogin      = Get-Field $user "lastLoginTime","lastlogintime"
        AccountCreated = Get-Field $user "creationTime","creationtime"
    })
}

# Summary record
$summaryReport.Add([PSCustomObject]@{
    ReportDate        = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    TotalUsers        = $rawUsers.Count
    ActiveUsers       = $countActive
    SuspendedUsers    = $countSuspended
    ArchivedUsers     = $countArchived
    AdminUsers        = $countAdmin
    MFA_EnrolledUsers = $count2SVOn
    MFA_NotEnrolled   = ($rawUsers.Count - $count2SVOn)
})

# ---------------------------------------------------------------
# STEP 4: Export reports
# ---------------------------------------------------------------
Write-Host "[3/3] Saving reports..." -ForegroundColor Yellow

$detailedReport | Export-Csv $DetailedCSV -NoTypeInformation
$summaryReport  | Export-Csv $SummaryCSV  -NoTypeInformation

# Clean up raw file
Remove-Item $RawUsersCSV -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------
# FINAL OUTPUT
# ---------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "          AUDIT COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total Users Scanned  : $($rawUsers.Count)"
Write-Host "  Active             : $countActive"
Write-Host "  Suspended          : $countSuspended"
Write-Host "  Archived           : $countArchived"
Write-Host "  Admins             : $countAdmin"
Write-Host "  MFA Enrolled       : $count2SVOn"
Write-Host "  MFA NOT Enrolled   : $($rawUsers.Count - $count2SVOn)"
Write-Host ""
Write-Host "Reports saved:"
Write-Host "  Detailed -> $DetailedCSV" -ForegroundColor Cyan
Write-Host "  Summary  -> $SummaryCSV"  -ForegroundColor Cyan