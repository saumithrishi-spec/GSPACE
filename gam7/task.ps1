# ============================================================
# GAM - Tasks Report with Creator & Assignee Details
# ============================================================

$GAM = "C:\Users\v-nmahanthi\OneDrive - Microsoft\Documents\gam7\gam.exe"
$OutputDir = "C:\GAMReports"
$TasksCSV  = "$OutputDir\all_tasks.csv"
$UsersCSV  = "$OutputDir\all_users.csv"
$ReportCSV = "$OutputDir\tasks_report_final.csv"

# Create output directory if it doesn't exist
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

# Verify GAM executable exists
if (-not (Test-Path $GAM)) {
    Write-Host "ERROR: GAM executable not found at: $GAM" -ForegroundColor Red
    Write-Host "Please verify the path and try again." -ForegroundColor Yellow
    exit
}

# ============================================================
# STEP 1: Export all tasks for all users
# ============================================================
Write-Host "Fetching tasks for all users..." -ForegroundColor Cyan
& $GAM all users print tasks > $TasksCSV

if (-not (Test-Path $TasksCSV) -or (Get-Item $TasksCSV).Length -eq 0) {
    Write-Host "ERROR: Tasks file is empty or missing. Check GAM permissions." -ForegroundColor Red
    exit
}
Write-Host "Tasks exported to $TasksCSV" -ForegroundColor Green

# ============================================================
# STEP 2: Export all user details (email, name, ID)
# ============================================================
Write-Host "Fetching all user details..." -ForegroundColor Cyan
& $GAM print users fields primaryEmail,name,id > $UsersCSV

if (-not (Test-Path $UsersCSV) -or (Get-Item $UsersCSV).Length -eq 0) {
    Write-Host "ERROR: Users file is empty or missing. Check GAM permissions." -ForegroundColor Red
    exit
}
Write-Host "Users exported to $UsersCSV" -ForegroundColor Green

# ============================================================
# STEP 3: Load CSVs
# ============================================================
$tasks = Import-Csv $TasksCSV
$users = Import-Csv $UsersCSV

Write-Host "Loaded $($tasks.Count) tasks and $($users.Count) users." -ForegroundColor White

# Build lookup hashtables
$userById    = @{}
$userByEmail = @{}

foreach ($user in $users) {
    if ($user.id) {
        $userById[$user.id] = $user
    }
    if ($user.primaryEmail) {
        $userByEmail[$user.primaryEmail.ToLower()] = $user
    }
}

# ============================================================
# STEP 4: Merge and enrich task data
# ============================================================
Write-Host "Merging task and user data..." -ForegroundColor Cyan

$report = foreach ($task in $tasks) {

    # Resolve Creator (email based)
    $creatorEmail = $task.creator
    $creatorName  = ""
    if ($creatorEmail -and $userByEmail.ContainsKey($creatorEmail.ToLower())) {
        $u = $userByEmail[$creatorEmail.ToLower()]
        $creatorName = "$($u.'name.givenName') $($u.'name.familyName')".Trim()
    }

    # Resolve Assignee (ID based)
    $assigneeId    = $task.assignee
    $assigneeEmail = ""
    $assigneeName  = ""
    if ($assigneeId -and $userById.ContainsKey($assigneeId)) {
        $u = $userById[$assigneeId]
        $assigneeEmail = $u.primaryEmail
        $assigneeName  = "$($u.'name.givenName') $($u.'name.familyName')".Trim()
    }

    [PSCustomObject]@{
        TaskOwner     = $task.User
        TaskID        = $task.id
        TaskTitle     = $task.title
        Status        = $task.status
        Due           = $task.due
        CreatorEmail  = $creatorEmail
        CreatorName   = $creatorName
        AssigneeID    = $assigneeId
        AssigneeEmail = $assigneeEmail
        AssigneeName  = $assigneeName
    }
}

# ============================================================
# STEP 5: Export final report
# ============================================================
if ($report.Count -eq 0) {
    Write-Host "WARNING: No tasks found. The report will be empty." -ForegroundColor Yellow
} else {
    $report | Export-Csv $ReportCSV -NoTypeInformation
    Write-Host ""
    Write-Host "Final report saved to : $ReportCSV" -ForegroundColor Yellow
    Write-Host "Total tasks processed : $($report.Count)" -ForegroundColor White
}