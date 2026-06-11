# --- CONFIGURATION ---
$AdminEmail = "admin-narendra@rocheua.com"
$GamPath = ".\gam.exe"
$CurrentDir = Get-Location

Write-Host "--- Starting FULL ORGANIZATIONAL Chat Audit ---" -ForegroundColor Cyan

# 1. Extract ALL Spaces
Write-Host "[1/3] Extracting ALL Spaces..." -ForegroundColor Yellow
& $GamPath redirect csv all_spaces.csv multiprocess user $AdminEmail print chatspaces asadmin fields name,displayname,membershipcount

# 2. Extract ALL Members
Write-Host "[2/3] Extracting ALL Memberships..." -ForegroundColor Yellow
& $GamPath redirect csv all_members.csv multiprocess user $AdminEmail print chatmembers asadmin

# 3. Analyze for Orphans
Write-Host "[3/3] Analyzing data for orphaned spaces..." -ForegroundColor Yellow

# Wait specifically for the files to actually exist on the disk
while (-not (Test-Path "$CurrentDir\all_spaces.csv") -or -not (Test-Path "$CurrentDir\all_members.csv")) {
    Start-Sleep -Seconds 2
    Write-Host "." -NoNewline
}

$allSpaces = Import-Csv "$CurrentDir\all_spaces.csv"
$allMembers = Import-Csv "$CurrentDir\all_members.csv"
$orphanReport = @()

foreach ($space in $allSpaces) {
    $spaceID = $space.name
    
    # Check for managers in the membership list
    $managers = $allMembers | Where-Object { $_.space -eq $spaceID -and $_.role -eq "ROLE_MANAGER" }

    if ($null -eq $managers) {
        $orphanObj = [PSCustomObject]@{
            SpaceName    = $space.displayName
            SpaceID      = $spaceID
            # Ensuring we handle different header names if GAM formats them differently
            MemberCount  = $space.'membershipCount.joinedDirectHumanUserCount'
            Remediation  = "Assign Manager / Audit Content"
        }
        $orphanReport += $orphanObj
    }
}

# Save the final report
$orphanReport | Export-Csv "$CurrentDir\ORG_WIDE_ORPHAN_REPORT.csv" -NoTypeInformation

Write-Host "`n`nSUCCESS!" -ForegroundColor Green
Write-Host "Total Spaces Scanned: $($allSpaces.Count)"
Write-Host "Orphaned Spaces Found: $($orphanReport.Count)"
Write-Host "Report saved to: $CurrentDir\ORG_WIDE_ORPHAN_REPORT.csv" -ForegroundColor Cyan