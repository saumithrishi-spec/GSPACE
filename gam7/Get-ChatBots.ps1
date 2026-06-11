# ---------------------------------------------------------------
# Get-ChatBots.ps1
# Pulls Google Chat Bot activity directly via GAM Reports API
# then enriches with Space details from GAM Chat API
#
# GAM command used: gam report chat
# This pulls from the same data source as Admin Console Reports
# ---------------------------------------------------------------

# --- CONFIGURATION ---
$AdminEmail  = "admin-narendra@rocheua.com"
$GamPath     = Join-Path $PSScriptRoot "gam.exe"
$CurrentDir  = Get-Location
$Timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"

# Date range for bot activity report (default: last 30 days)
# Change these if you want a specific range e.g. "2026-01-01" "2026-04-10"
$StartDate   = "-30d"   # relative: 30 days ago
$EndDate     = "today"

# --- Temp files ---
$RawChatReportCSV = "$CurrentDir\raw_chat_report.csv"
$RawSpacesCSV     = "$CurrentDir\raw_spaces_bots.csv"

# --- Output files ---
$BotRawCSV    = "$CurrentDir\BOTS_RAW_ACTIVITY_$Timestamp.csv"
$EnrichedCSV  = "$CurrentDir\BOTS_ENRICHED_$Timestamp.csv"
$PerBotCSV    = "$CurrentDir\BOTS_PER_BOT_$Timestamp.csv"
$PerSpaceCSV  = "$CurrentDir\BOTS_PER_SPACE_$Timestamp.csv"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Google Chat Bot Activity Audit (GAM7)   " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Timestamp  : $Timestamp"
Write-Host "Admin      : $AdminEmail"
Write-Host "Date Range : $StartDate -> $EndDate"
Write-Host ""

# ---------------------------------------------------------------
# Helper: Wait for file with timeout
# ---------------------------------------------------------------
function Wait-ForFile($filePath, $timeoutSec = 180) {
    $elapsed = 0
    Write-Host "   Waiting for GAM output..." -NoNewline
    while (-not (Test-Path $filePath)) {
        if ($elapsed -ge $timeoutSec) {
            Write-Host "`nERROR: Timed out after $timeoutSec seconds." -ForegroundColor Red
            exit 1
        }
        Start-Sleep -Seconds 2; $elapsed += 2
        Write-Host "." -NoNewline
    }
    Write-Host " Done." -ForegroundColor Green
}

# ---------------------------------------------------------------
# STEP 1: Pull Chat Activity Report via GAM Reports API
# gam report chat = same data as Admin Console > Reports > Chat
# This includes bot interactions, message events, space events
# ---------------------------------------------------------------
Write-Host "[1/3] Pulling Chat Activity report from Admin Reports API..." -ForegroundColor Yellow
Write-Host "      (covers bot invocations, messages, space events)" -ForegroundColor DarkGray

$gamReportArgs = @(
    "redirect", "csv", $RawChatReportCSV,
    "report", "chat",
    "start", $StartDate,
    "end",   $EndDate
)
& $GamPath @gamReportArgs
Wait-ForFile $RawChatReportCSV

$rawReport = Import-Csv $RawChatReportCSV
if (-not $rawReport -or $rawReport.Count -eq 0) {
    Write-Host "ERROR: No chat activity data returned." -ForegroundColor Red
    Write-Host "       Check that Reports API is enabled for your domain." -ForegroundColor Yellow
    exit 1
}

Write-Host "   Total activity records pulled: $($rawReport.Count)"

# Show what columns GAM returned (helps understand the data structure)
$cols = $rawReport[0].PSObject.Properties.Name
Write-Host "   Columns returned: $($cols -join ', ')" -ForegroundColor DarkGray

# Save raw report as-is for reference
$rawReport | Export-Csv $BotRawCSV -NoTypeInformation
Write-Host "   Raw report saved: $BotRawCSV" -ForegroundColor DarkGray

# ---------------------------------------------------------------
# STEP 2: Pull ALL spaces from GAM to enrich with names
# ---------------------------------------------------------------
Write-Host "[2/3] Fetching all Chat Spaces for name enrichment..." -ForegroundColor Yellow

$gamSpaceArgs = @(
    "redirect", "csv", $RawSpacesCSV,
    "user", $AdminEmail,
    "print", "chatspaces",
    "asadmin",
    "fields", "name,displayname,spacetype,membershipcount"
)
& $GamPath @gamSpaceArgs
Wait-ForFile $RawSpacesCSV

$allSpaces = Import-Csv $RawSpacesCSV
Write-Host "   Spaces loaded: $($allSpaces.Count)"

# Build SpaceID -> details lookup
$spaceLookup = @{}
foreach ($sp in $allSpaces) {
    $spaceLookup[$sp.name] = @{
        DisplayName  = $sp.displayName
        SpaceType    = $sp.spaceType
        MemberCount  = $sp.'membershipCount.joinedDirectHumanUserCount'
    }
}
# Build SpaceName -> SpaceID reverse lookup
$spaceNameLookup = @{}
foreach ($sp in $allSpaces) {
    if ($sp.displayName) {
        $spaceNameLookup[$sp.displayName.Trim().ToLower()] = $sp.name
    }
}
Remove-Item $RawSpacesCSV -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------
# STEP 3: Filter for Bot-related events and enrich with space info
# Chat report events include: bot_added, bot_removed, message_posted etc.
# We look for any event involving a bot (app) actor or bot event type
# ---------------------------------------------------------------
Write-Host "[3/3] Processing bot-related events and enriching..." -ForegroundColor Yellow

# Helper to safely get column value
function Get-Col($row, [string[]]$names) {
    foreach ($n in $names) {
        $v = $row.PSObject.Properties[$n]
        if ($v -and "$($v.Value)".Trim() -ne "") { return "$($v.Value)".Trim() }
    }
    return ""
}

$enriched  = [System.Collections.Generic.List[PSCustomObject]]::new()
$botEvents = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($row in $rawReport) {
    $eventName  = Get-Col $row "events.name","event.name","name"
    $actorEmail = Get-Col $row "actor.email","actor"
    $actorType  = Get-Col $row "actor.callerType","actor.callerType"
    $ipAddress  = Get-Col $row "ipAddress","ip_address"
    $eventTime  = Get-Col $row "id.time","time","eventTime"

    # Extract Chat-specific parameters
    $spaceId    = Get-Col $row "events.parameters.space_id","parameters.space_id","space_id"
    $spaceName  = Get-Col $row "events.parameters.space_name","parameters.space_name","space_name"
    $appName    = Get-Col $row "events.parameters.app_name","parameters.app_name","app_name"
    $appId      = Get-Col $row "events.parameters.app_id","parameters.app_id","app_id"
    $msgType    = Get-Col $row "events.parameters.conversation_type","parameters.conversation_type","conversation_type"

    # Classify event type
    $isBotEvent = $eventName -match "bot|app" -or
                  $actorType -eq "APPLICATION" -or
                  $appName -ne "" -or $appId -ne ""

    if ($isBotEvent) {
        # Try to resolve space name from GAM spaces
        $resolvedSpaceName = ""
        $resolvedSpaceType = ""
        $resolvedMemberCount = ""

        if ($spaceId -and $spaceLookup.ContainsKey($spaceId)) {
            $resolvedSpaceName   = $spaceLookup[$spaceId].DisplayName
            $resolvedSpaceType   = $spaceLookup[$spaceId].SpaceType
            $resolvedMemberCount = $spaceLookup[$spaceId].MemberCount
        } elseif ($spaceName) {
            $resolvedSpaceName = $spaceName
            $key = $spaceName.ToLower()
            if ($spaceNameLookup.ContainsKey($key)) {
                $sid = $spaceNameLookup[$key]
                $resolvedSpaceType   = $spaceLookup[$sid].SpaceType
                $resolvedMemberCount = $spaceLookup[$sid].MemberCount
            }
        }

        $botEvents.Add([PSCustomObject]@{
            EventTime        = $eventTime
            EventName        = $eventName
            ActorEmail       = $actorEmail
            ActorType        = $actorType
            AppName          = $appName
            AppId            = $appId
            SpaceID          = $spaceId
            SpaceName        = if ($resolvedSpaceName) { $resolvedSpaceName } else { $spaceName }
            SpaceType        = $resolvedSpaceType
            MemberCount      = $resolvedMemberCount
            ConversationType = $msgType
            IPAddress        = $ipAddress
        })
    }

    # Also add all records to enriched (full picture)
    $resolvedSpaceName2  = ""
    $resolvedSpaceType2  = ""
    if ($spaceId -and $spaceLookup.ContainsKey($spaceId)) {
        $resolvedSpaceName2 = $spaceLookup[$spaceId].DisplayName
        $resolvedSpaceType2 = $spaceLookup[$spaceId].SpaceType
    }

    $enriched.Add([PSCustomObject]@{
        EventTime        = $eventTime
        EventName        = $eventName
        ActorEmail       = $actorEmail
        ActorType        = $actorType
        AppName          = $appName
        AppId            = $appId
        SpaceID          = $spaceId
        SpaceName        = if ($resolvedSpaceName2) { $resolvedSpaceName2 } else { $spaceName }
        SpaceType        = $resolvedSpaceType2
        ConversationType = $msgType
        IsBotEvent       = $isBotEvent
    })
}

Write-Host "   Total events processed   : $($rawReport.Count)"
Write-Host "   Bot-related events found : $($botEvents.Count)" -ForegroundColor $(if ($botEvents.Count -gt 0) {"Green"} else {"DarkYellow"})

# ---------------------------------------------------------------
# Per-Bot summary (group by AppId/AppName)
# ---------------------------------------------------------------
$perBotRows = $botEvents |
    Group-Object -Property AppId |
    ForEach-Object {
        $g = $_.Group
        [PSCustomObject]@{
            AppId        = $g[0].AppId
            AppName      = $g[0].AppName
            TotalEvents  = $g.Count
            UniqueSpaces = ($g | Where-Object { $_.SpaceID } | Select-Object -ExpandProperty SpaceID -Unique).Count
            EventTypes   = (($g | Select-Object -ExpandProperty EventName -Unique) -join " | ")
            SpacesUsedIn = (($g | Where-Object { $_.SpaceName } | Select-Object -ExpandProperty SpaceName -Unique) -join " | ")
            FirstSeen    = ($g | Select-Object -ExpandProperty EventTime | Sort-Object | Select-Object -First 1)
            LastSeen     = ($g | Select-Object -ExpandProperty EventTime | Sort-Object | Select-Object -Last 1)
        }
    } | Sort-Object TotalEvents -Descending

# Per-Space summary
$perSpaceRows = $botEvents |
    Where-Object { $_.SpaceName -ne "" } |
    Group-Object -Property SpaceName |
    ForEach-Object {
        $g = $_.Group
        [PSCustomObject]@{
            SpaceName    = $g[0].SpaceName
            SpaceID      = $g[0].SpaceID
            SpaceType    = $g[0].SpaceType
            MemberCount  = $g[0].MemberCount
            TotalEvents  = $g.Count
            UniqueBots   = ($g | Where-Object { $_.AppId } | Select-Object -ExpandProperty AppId -Unique).Count
            BotNames     = (($g | Where-Object { $_.AppName } | Select-Object -ExpandProperty AppName -Unique) -join " | ")
        }
    } | Sort-Object TotalEvents -Descending

# ---------------------------------------------------------------
# Export
# ---------------------------------------------------------------
$enriched    | Export-Csv $EnrichedCSV -NoTypeInformation
$perBotRows  | Export-Csv $PerBotCSV  -NoTypeInformation
$perSpaceRows| Export-Csv $PerSpaceCSV -NoTypeInformation

# Cleanup
Remove-Item $RawChatReportCSV -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------
# FINAL OUTPUT
# ---------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "           AUDIT COMPLETE                  " -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Total Chat Events        : $($rawReport.Count)"
Write-Host "Bot-Related Events       : $($botEvents.Count)"
Write-Host "Unique Bots/Apps         : $(($botEvents | Select-Object -ExpandProperty AppId -Unique).Count)"
Write-Host "Unique Spaces with Bots  : $(($botEvents | Where-Object { $_.SpaceID } | Select-Object -ExpandProperty SpaceID -Unique).Count)"
Write-Host ""
Write-Host "Reports saved:" -ForegroundColor Cyan
Write-Host "  Raw Activity   -> $BotRawCSV"
Write-Host "  Enriched Detail-> $EnrichedCSV"
Write-Host "  Per Bot        -> $PerBotCSV"
Write-Host "  Per Space      -> $PerSpaceCSV"

if ($botEvents.Count -eq 0) {
    Write-Host ""
    Write-Host "NOTE: No bot events found. This could mean:" -ForegroundColor DarkYellow
    Write-Host "  1. No bots were active in the last 30 days" -ForegroundColor DarkYellow
    Write-Host "  2. Check raw report columns above - event field names may differ" -ForegroundColor DarkYellow
    Write-Host "  3. Raw report saved to $BotRawCSV - open it to inspect actual column names" -ForegroundColor DarkYellow
}