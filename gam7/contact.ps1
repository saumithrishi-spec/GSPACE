param(
    [string]$OutputCsv = ".\ContactDelegates_Final.csv",
    [string]$WorkingFolder = ".\GAM_ContactDelegates_Work",
    [string]$GamExe = ""
)

$ErrorActionPreference = "Stop"

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Resolve-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot $Path))
}

$WorkingFolder = Resolve-AbsolutePath -Path $WorkingFolder
$OutputCsv = Resolve-AbsolutePath -Path $OutputCsv

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Confirm-Folder {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Resolve-GamExe {
    param([string]$GamExe)

    $Candidates = New-Object System.Collections.Generic.List[string]

    if ($GamExe) {
        $Candidates.Add($GamExe)
    }

    if ($PSScriptRoot) {
        $Candidates.Add((Join-Path $PSScriptRoot "gam.exe"))
    }

    $Candidates.Add("C:\GAM7\gam.exe")
    $Candidates.Add("C:\GAMADV-XTD3\gam.exe")
    $Candidates.Add("C:\Users\v-nmahanthi\OneDrive - Microsoft\Documents\gam7\gam.exe")

    foreach ($Candidate in ($Candidates | Select-Object -Unique)) {
        if ($Candidate -and (Test-Path -LiteralPath $Candidate)) {
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }

    $Cmd = Get-Command gam -ErrorAction SilentlyContinue
    if ($Cmd) {
        return $Cmd.Source
    }

    throw "GAM executable not found."
}

function Join-NativeArguments {
    param([string[]]$Arguments)

    $Escaped = foreach ($Arg in $Arguments) {
        if ($null -eq $Arg) {
            '""'
        }
        elseif ($Arg -match '[\s"]') {
            '"' + ($Arg -replace '"', '\"') + '"'
        }
        else {
            $Arg
        }
    }

    return ($Escaped -join ' ')
}

function Invoke-Gam {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $ArgString = Join-NativeArguments -Arguments $Arguments
    Write-Log ("Running: " + $script:GamExeResolved + " " + $ArgString)

    $Psi = New-Object System.Diagnostics.ProcessStartInfo
    $Psi.FileName = $script:GamExeResolved
    $Psi.Arguments = $ArgString
    $Psi.WorkingDirectory = $ScriptRoot
    $Psi.RedirectStandardOutput = $true
    $Psi.RedirectStandardError = $true
    $Psi.UseShellExecute = $false
    $Psi.CreateNoWindow = $true

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $Psi

    $null = $Process.Start()

    # Read stderr asynchronously so its buffer never fills and causes a deadlock
    # while ReadToEnd() is blocking on stdout (classic two-stream deadlock pattern).
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    $Stdout = $Process.StandardOutput.ReadToEnd()
    $Process.WaitForExit()
    $Stderr = $StderrTask.GetAwaiter().GetResult()

    # Only log on failure to avoid printing every GAM progress line to the console.
    if ($Process.ExitCode -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($Stderr)) {
            ($Stderr -split "`r?`n") | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_)) { Write-Log "STDERR: $_" }
            }
        }
        throw "GAM command failed with exit code $($Process.ExitCode).`nCommand: $script:GamExeResolved $ArgString`nSTDERR:`n$Stderr`nSTDOUT:`n$Stdout"
    }

    return [PSCustomObject]@{
        ExitCode = $Process.ExitCode
        StdOut   = $Stdout
        StdErr   = $Stderr
    }
}

function Get-FirstExistingPropertyName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string[]]$CandidateNames
    )

    $Props = $Object.PSObject.Properties.Name

    foreach ($Name in $CandidateNames) {
        if ($Props -contains $Name) {
            return $Name
        }
    }

    foreach ($Candidate in $CandidateNames) {
        $Match = $Props | Where-Object { $_.ToLower() -eq $Candidate.ToLower() } | Select-Object -First 1
        if ($Match) {
            return $Match
        }
    }

    return $null
}

function New-EmptyOutput {
    param([string]$Path)

    @() | Select-Object `
    @{Name = 'UserDisplayName'; Expression = { '' } }, `
    @{Name = 'UserEmailAddress'; Expression = { '' } }, `
    @{Name = 'DelegateAddress'; Expression = { '' } }, `
    @{Name = 'DelegateName'; Expression = { '' } }, `
    @{Name = 'Count'; Expression = { 0 } } |
    Select-Object -First 0 |
    Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Get-DelegateColumns {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SampleObject,
        [Parameter(Mandatory = $true)]
        [string]$OwnerColumn
    )

    $Props = $SampleObject.PSObject.Properties.Name

    $Preferred = $Props | Where-Object {
        $_ -ne $OwnerColumn -and (
            $_ -match '(?i)delegate' -or
            $_ -match '(?i)contactdelegate'
        )
    }

    if ($Preferred -and $Preferred.Count -gt 0) {
        return $Preferred
    }

    return ($Props | Where-Object { $_ -ne $OwnerColumn })
}

function Get-EmailsFromText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $EmailMatches = [regex]::Matches(
        $Text,
        "(?i)[A-Z0-9._%+\-']+@[A-Z0-9.\-]+\.[A-Z]{2,}"
    )

    $Emails = foreach ($M in $EmailMatches) {
        $M.Value.Trim()
    }

    return $Emails | Sort-Object -Unique
}

function Get-DelegateEmailsFromRow {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row,
        [Parameter(Mandatory = $true)]
        [string[]]$DelegateColumns
    )

    $Emails = New-Object System.Collections.Generic.List[string]

    foreach ($Col in $DelegateColumns) {
        $Value = [string]$Row.$Col
        if ([string]::IsNullOrWhiteSpace($Value)) {
            continue
        }

        $Found = Get-EmailsFromText -Text $Value
        foreach ($Email in $Found) {
            if (-not [string]::IsNullOrWhiteSpace($Email)) {
                $Emails.Add($Email.Trim())
            }
        }
    }

    return $Emails | Sort-Object -Unique
}

$script:GamExeResolved = Resolve-GamExe -GamExe $GamExe
Write-Log "Using GAM executable: $script:GamExeResolved"

Write-Log "Validating GAM executable..."
Invoke-Gam -Arguments @("version") | Out-Null

Confirm-Folder -Path $WorkingFolder

$UsersCsv = Join-Path $WorkingFolder "Users.csv"
$DelegatesCsv = Join-Path $WorkingFolder "ContactDelegates.csv"

if (Test-Path -LiteralPath $UsersCsv) { Remove-Item -LiteralPath $UsersCsv     -Force }
if (Test-Path -LiteralPath $DelegatesCsv) { Remove-Item -LiteralPath $DelegatesCsv -Force }
if (Test-Path -LiteralPath $OutputCsv) { Remove-Item -LiteralPath $OutputCsv    -Force }

# GAM's contactdelegates output does not include the owner's display name,
# so we fetch users separately to populate 'UserDisplayName'.
Write-Log "Exporting users (for display name lookup)..."
Invoke-Gam -Arguments @(
    "redirect", "csv", $UsersCsv,
    "print", "users", "name"
) | Out-Null

Write-Log "Exporting contact delegates (shownames for delegate display name)..."
Invoke-Gam -Arguments @(
    "redirect", "csv", $DelegatesCsv,
    "all", "users", "print", "contactdelegates", "shownames"
) | Out-Null

if (-not (Test-Path -LiteralPath $UsersCsv)) {
    throw "Users export file was not created: $UsersCsv"
}
if (-not (Test-Path -LiteralPath $DelegatesCsv)) {
    throw "Contact delegates export file was not created: $DelegatesCsv"
}

$Users = Import-Csv -LiteralPath $UsersCsv
$Delegates = Import-Csv -LiteralPath $DelegatesCsv

if (-not $Delegates -or $Delegates.Count -eq 0) {
    Write-Log "No contact delegates found. Writing empty output."
    New-EmptyOutput -Path $OutputCsv
    exit 0
}

# Detect columns — GAM7 actual column names confirmed from live output:
#   User, delegateAddress, delegateName
$OwnerColumn = Get-FirstExistingPropertyName -Object $Delegates[0] -CandidateNames @(
    "User", "user", "primaryEmail", "PrimaryEmail", "owner", "Owner"
)

# GAM outputs 'delegateAddress' (not 'delegateEmail') for the delegate's email.
$DelegateEmailColumn = Get-FirstExistingPropertyName -Object $Delegates[0] -CandidateNames @(
    "delegateAddress", "DelegateAddress", "delegateEmail", "DelegateEmail", "delegate", "email"
)

# 'shownames' adds delegateName for the delegate's display name.
$DelegateNameColumn = Get-FirstExistingPropertyName -Object $Delegates[0] -CandidateNames @(
    "delegateName", "DelegateName", "delegateDisplayName"
)

if (-not $OwnerColumn -or -not $DelegateEmailColumn) {
    $FoundCols = ($Delegates[0].PSObject.Properties.Name) -join ", "
    throw "Could not detect required columns. Columns found in CSV: $FoundCols"
}

# Build owner display-name lookup from the separate users export.
$UserEmailCol = Get-FirstExistingPropertyName -Object $Users[0] -CandidateNames @(
    "primaryEmail", "PrimaryEmail", "email", "Email"
)
$UserNameCol = Get-FirstExistingPropertyName -Object $Users[0] -CandidateNames @(
    "name.fullName", "Name.FullName", "fullName", "FullName", "name", "Name"
)

$UserLookup = @{}
foreach ($U in $Users) {
    $UEmail = [string]$U.$UserEmailCol
    if ([string]::IsNullOrWhiteSpace($UEmail)) { continue }
    $UKey = $UEmail.Trim().ToLower()
    $UName = if ($UserNameCol) { [string]$U.$UserNameCol } else { "" }
    $UserLookup[$UKey] = if ($UName) { $UName } else { $UEmail.Trim() }
}

$Normalized = New-Object System.Collections.Generic.List[object]

# Use a HashSet to deduplicate: same owner + same delegate should never produce two rows.
$Seen = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($Row in $Delegates) {
    $OwnerEmail = ([string]$Row.$OwnerColumn).Trim()
    if ([string]::IsNullOrWhiteSpace($OwnerEmail)) { continue }

    $DelEmail = ([string]$Row.$DelegateEmailColumn).Trim()
    if ([string]::IsNullOrWhiteSpace($DelEmail)) { continue }

    # Skip duplicates — Count will then always equal the number of visible rows.
    $PairKey = "$OwnerEmail|$DelEmail"
    if (-not $Seen.Add($PairKey)) { continue }

    $DelName = if ($DelegateNameColumn) { ([string]$Row.$DelegateNameColumn).Trim() } else { "" }

    $Normalized.Add([PSCustomObject]@{
            OwnerEmail    = $OwnerEmail
            DelegateEmail = $DelEmail
            DelegateName  = $DelName
        })
}

if ($Normalized.Count -eq 0) {
    Write-Log "No usable delegate relationships found after normalization. Writing empty output."
    New-EmptyOutput -Path $OutputCsv
    exit 0
}

# One row per owner: group all delegates so Count always equals the number of
# semicolon-separated values visible in 'DelegateAddress' and 'DelegateName'.
$Result = $Normalized |
Group-Object -Property OwnerEmail |
ForEach-Object {
    $OwnerEmail = $_.Name
    $OwnerKey = $OwnerEmail.ToLower()
    $SortedGroup = $_.Group | Sort-Object DelegateEmail

    [PSCustomObject]@{
        UserDisplayName  = $UserLookup[$OwnerKey]
        UserEmailAddress = $OwnerEmail
        DelegateAddress  = ($SortedGroup | ForEach-Object { $_.DelegateEmail }) -join "; "
        DelegateName     = ($SortedGroup | ForEach-Object { $_.DelegateName }) -join "; "
        Count            = $_.Group.Count
    }
}

$Result |
Sort-Object UserEmailAddress |
Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Log "Completed successfully."
Write-Log "Output file: $OutputCsv"