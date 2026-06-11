# ---------------------------------------------------------------
# Get-ChatActivity.ps1
# Pulls Google Chat message activity org-wide using GAM
# Output: Two CSVs - Per User view + Per Space view
# ---------------------------------------------------------------

# --- CONFIGURATION ---
$AdminEmail = "admin-narendra@rocheua.com"
$GamPath    = Join-Path $PSScriptRoot "gam.exe"
$CurrentDir = Get-Location
$Timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"

# --- Raw temp files ---
$RawSpacesCSV   = "$CurrentDir\raw_spaces.csv"
$RawMembersCSV  = "$CurrentDir\raw_members.csv"
$RawMessagesCSV = "$CurrentDir\raw_messages.csv"

# --- Final output files ---
$PerUserCSV  = "$CurrentDir\CHAT_ACTIVITY_PER_USER_$Timestamp.csv"
$PerSpaceCSV = "$CurrentDir\CHAT_ACTIVITY_PER_SPACE_$Timestamp.csv"
$SummaryCSV  = "$CurrentDir\CHAT_ACTIVITY_SUMMARY_$Timestamp.csv"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Google Chat Activity Audit (Migration)  " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Timestamp : $Timestamp"
Write-Host "Admin     : $AdminEmail"
Write-Host ""

# ---------------------------------------------------------------
# Helper: Wait for a file to exist with a timeout
# ---------------------------------------------------------------
function Wait-ForFile($filePath, $timeoutSec = 180) {
    $elapsed = 0
    Write-Host "   Waiting for GAM output..." -NoNewline
    while (-not (Test-Path $filePath)) {
        if ($elapsed -ge $timeoutSec) {
            Write-Host "`nERROR: Timed out after $timeoutSec seconds waiting for: $filePath" -ForegroundColor Red
            exit 1
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
        Write-Host "." -NoNewline
    }
    Write-Host " Done." -ForegroundColor Green
}

# ---------------------------------------------------------------
# STEP 1: Get ALL Chat Spaces (DMs + Rooms + Group chats)
# ---------------------------------------------------------------
Write-Host "[1/4] Fetching all Chat Spaces org-wide..." -ForegroundColor Yellow

$gamSpaceArgs = @(
    "redirect", "csv", $RawSpacesCSV,
    "multiprocess",
    "user", $AdminEmail,
    "print", "chatspaces",
    "asadmin",
    "fields", "name,displayName,spaceType,membershipCount"
)
& $GamPath @gamSpaceArgs
Wait-ForFile $RawSpacesCSV

$allSpaces = Import-Csv $RawSpacesCSV
if (-not $allSpaces -or $allSpaces.Count -eq 0) {
    Write-Host "ERROR: No spaces found." -ForegroundColor Red; exit 1
}
Write-Host "   Total spaces found: $($allSpaces.Count)"

# ---------------------------------------------------------------
# STEP 2: Get ALL Members across ALL Spaces
# ---------------------------------------------------------------
Write-Host "[2/4] Fetching all Chat Members org-wide..." -ForegroundColor Yellow

$gamMemberArgs = @(
    "redirect", "csv", $RawMembersCSV,
    "multiprocess",
    "user", $AdminEmail,
    "print", "chatmembers",
    "asadmin"
)
& $GamPath @gamMemberArgs
Wait-ForFile $RawMembersCSV

$allMembers = Import-Csv $RawMembersCSV
Write-Host "   Total member records found: $($allMembers.Count)"

# ---------------------------------------------------------------
# STEP 3: Get Messages per Space
# GAM can list messages in a space using: print chatmessages
# We loop through each space and collect messages
# ---------------------------------------------------------------
Write-Host "[3/4] Fetching messages from all spaces..." -ForegroundColor Yellow
Write-Host "   NOTE: This may take a while for large orgs." -ForegroundColor DarkYellow

# Collect all messages across spaces into one list
$allMessages = [System.Collections.Generic.List[PSCustomObject]]::new()
$spaceCounter = 0

foreach ($space in $allSpaces) {
    $spaceCounter++
    $spaceId      = $space.name          # e.g. spaces/XXXXXXX
    $spaceName    = $space.displayName
    $spaceType    = $space.spaceType     # SPACE, GROUP_CHAT, DIRECT_MESSAGE

    # Skip unnamed DMs (they have no displayName)
    $spaceLabel = if ($spaceName) { $spaceName } else { "DM ($spaceId)" }

    Write-Host "   [$spaceCounter/$($allSpaces.Count)] $spaceLabel" -NoNewline

    $tempMsgCSV = "$CurrentDir\tmp_msg_$spaceCounter.csv"

    $gamMsgArgs = @(
        "redirect", "csv", $tempMsgCSV,
        "user", $AdminEmail,
        "print", "chatmessages",
        "space", $spaceId,
        "asadmin"
    )

    & $GamPath @gamMsgArgs 2>$null

    # Wait briefly then check
    Start-Sleep -Seconds 1

    if (Test-Path $tempMsgCSV) {
        $msgs = Import-Csv $tempMsgCSV
        if ($msgs -and $msgs.Count -gt 0) {
            foreach ($msg in $msgs) {
                $allMessages.Add([PSCustomObject]@{
                    SpaceID      = $spaceId
                    SpaceName    = $spaceLabel
                    SpaceType    = $spaceType
                    SenderEmail  = $msg.sender           # GAM field: sender (email)
                    SenderName   = $msg.'sender.displayName'
                    MessageTime  = $msg.createTime
                    MessageName  = $msg.name              # internal message ID
                })
            }
            Write-Host " -> $($msgs.Count) messages" -ForegroundColor Green
        } else {
            Write-Host " -> 0 messages" -ForegroundColor DarkGray
        }
        Remove-Item $tempMsgCSV -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host " -> (no access or empty)" -ForegroundColor DarkGray
    }
}

Write-Host "   Total messages collected: $($allMessages.Count)"

# ---------------------------------------------------------------
# STEP 4: Build Per-User and Per-Space reports
# ---------------------------------------------------------------
Write-Host "[4/4] Building reports..." -ForegroundColor Yellow

# --- PER USER report: each row = one user + one space they posted in ---
# Group messages by SenderEmail + SpaceID, count messages
$perUserReport  = [System.Collections.Generic.List[PSCustomObject]]::new()
$perSpaceReport = [System.Collections.Generic.List[PSCustomObject]]::new()

# Group by User -> Space
$byUserSpace = $allMessages | Group-Object -Property SenderEmail, SpaceID

foreach ($group in $byUserSpace) {
    $sample = $group.Group[0]
    $times  = $group.Group | ForEach-Object { $_.MessageTime } | Sort-Object

    $perUserReport.Add([PSCustomObject]@{
        UserEmail      = $sample.SenderEmail
        UserName       = $sample.SenderName
        SpaceName      = $sample.SpaceName
        SpaceID        = $sample.SpaceID
        SpaceType      = $sample.SpaceType
        MessageCount   = $group.Count
        FirstMessageAt = $times | Select-Object -First 1
        LastMessageAt  = $times | Select-Object -Last 1
    })
}

# Sort by user then space
$perUserReport = $perUserReport | Sort-Object UserEmail, SpaceName

# Group by Space -> User
$bySpaceUser = $allMessages | Group-Object -Property SpaceID, SenderEmail

foreach ($group in $bySpaceUser) {
    $sample = $group.Group[0]
    $times  = $group.Group | ForEach-Object { $_.MessageTime } | Sort-Object

    $perSpaceReport.Add([PSCustomObject]@{
        SpaceName      = $sample.SpaceName
        SpaceID        = $sample.SpaceID
        SpaceType      = $sample.SpaceType
        UserEmail      = $sample.SenderEmail
        UserName       = $sample.SenderName
        MessageCount   = $group.Count
        FirstMessageAt = $times | Select-Object -First 1
        LastMessageAt  = $times | Select-Object -Last 1
    })
}

# Sort by space then user
$perSpaceReport = $perSpaceReport | Sort-Object SpaceName, UserEmail

# --- SUMMARY record ---
$totalDMs     = ($allMessages | Where-Object { $_.SpaceType -eq "DIRECT_MESSAGE" }).Count
$totalSpaces  = ($allMessages | Where-Object { $_.SpaceType -eq "SPACE" }).Count
$totalGroups  = ($allMessages | Where-Object { $_.SpaceType -eq "GROUP_CHAT" }).Count
$uniqueUsers  = ($allMessages | Select-Object -ExpandProperty SenderEmail -Unique).Count
$uniqueSpaces = ($allMessages | Select-Object -ExpandProperty SpaceID -Unique).Count

$summaryReport = [PSCustomObject]@{
    ReportDate        = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    TotalMessages     = $allMessages.Count
    UniqueUsers       = $uniqueUsers
    UniqueSpaces      = $uniqueSpaces
    SpaceMessages     = $totalSpaces
    GroupChatMessages = $totalGroups
    DMMessages        = $totalDMs
}

# ---------------------------------------------------------------
# Export all reports
# ---------------------------------------------------------------
$perUserReport  | Export-Csv $PerUserCSV  -NoTypeInformation
$perSpaceReport | Export-Csv $PerSpaceCSV -NoTypeInformation
$summaryReport  | Export-Csv $SummaryCSV  -NoTypeInformation

# Clean up raw temp files
Remove-Item $RawSpacesCSV  -Force -ErrorAction SilentlyContinue
Remove-Item $RawMembersCSV -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------
# FINAL OUTPUT
# ---------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "            AUDIT COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Total Messages Collected : $($allMessages.Count)"
Write-Host "  In Named Spaces        : $totalSpaces"
Write-Host "  In Group Chats         : $totalGroups"
Write-Host "  In Direct Messages     : $totalDMs"
Write-Host "Unique Active Users      : $uniqueUsers"
Write-Host "Unique Active Spaces     : $uniqueSpaces"
Write-Host ""
Write-Host "Reports saved:" -ForegroundColor Cyan
Write-Host "  Per User  -> $PerUserCSV"
Write-Host "  Per Space -> $PerSpaceCSV"
Write-Host "  Summary   -> $SummaryCSV"