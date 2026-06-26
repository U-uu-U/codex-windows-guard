param(
    [int]$IntervalSeconds = 20,
    [double]$KillBelowAvailableGB = 1.0,
    [int]$KillAboveCodexGitCount = 0,
    [double]$WarnBelowAvailableGB = 1.5,
    [string]$LogRoot = "$env:LOCALAPPDATA\CodexWindowsGuard\logs",
    [int]$MaxAncestorDepth = 12,
    [switch]$KillAllGit,
    [switch]$DryRun,
    [switch]$Once
)

$ErrorActionPreference = "Continue"

if ([string]::IsNullOrWhiteSpace($LogRoot)) {
    $LogRoot = Join-Path $PSScriptRoot "..\logs"
}

function Convert-ToGB([Nullable[double]]$Bytes) {
    if ($null -eq $Bytes) { return $null }
    return [math]::Round(([double]$Bytes) / 1GB, 3)
}

function Get-CounterValue([string]$Path) {
    try {
        return (Get-Counter $Path -ErrorAction Stop).CounterSamples[0].CookedValue
    } catch {
        return $null
    }
}

function Initialize-LogSession([string]$RequestedLogRoot) {
    $fallbackLogRoot = Join-Path $env:TEMP "CodexWindowsGuard\logs"

    foreach ($candidateRoot in @($RequestedLogRoot, $fallbackLogRoot)) {
        if ([string]::IsNullOrWhiteSpace($candidateRoot)) { continue }

        try {
            New-Item -ItemType Directory -Force -Path $candidateRoot -ErrorAction Stop | Out-Null
            $candidateSession = Join-Path $candidateRoot (Get-Date -Format "yyyyMMdd-HHmmss")
            New-Item -ItemType Directory -Force -Path $candidateSession -ErrorAction Stop | Out-Null

            return [pscustomobject]@{
                LogRoot = $candidateRoot
                Session = $candidateSession
            }
        } catch {
            Write-Warning "Cannot write logs to '$candidateRoot': $($_.Exception.Message)"
        }
    }

    throw "No writable log directory found. Try passing -LogRoot with a writable path."
}

function New-ProcessMap($ProcessRows) {
    $processByPid = @{}
    foreach ($row in $ProcessRows) {
        $processByPid[[int]$row.ProcessId] = $row
    }
    return $processByPid
}

function Get-AncestorChain($ProcessRow, [hashtable]$ProcessByPid, [int]$MaxDepth) {
    $chain = New-Object System.Collections.Generic.List[string]
    $parentId = [int]$ProcessRow.ParentProcessId

    for ($i = 0; $i -lt $MaxDepth -and $parentId -gt 0; $i++) {
        if (-not $ProcessByPid.ContainsKey($parentId)) { break }
        $parent = $ProcessByPid[$parentId]
        $chain.Add(("{0}:{1}" -f $parent.Name, $parent.ProcessId)) | Out-Null
        $parentId = [int]$parent.ParentProcessId
    }

    return $chain.ToArray()
}

function Test-HasAncestorProcessName(
    $ProcessRow,
    [hashtable]$ProcessByPid,
    [string[]]$Names,
    [int]$MaxDepth
) {
    $parentId = [int]$ProcessRow.ParentProcessId

    for ($i = 0; $i -lt $MaxDepth -and $parentId -gt 0; $i++) {
        if (-not $ProcessByPid.ContainsKey($parentId)) { return $false }
        $parent = $ProcessByPid[$parentId]

        foreach ($name in $Names) {
            if ($parent.Name -ieq $name) { return $true }
        }

        $parentId = [int]$parent.ParentProcessId
    }

    return $false
}

function Get-TargetGitProcesses(
    $ProcessRows,
    [hashtable]$ProcessByPid,
    [switch]$KillAll,
    [int]$MaxDepth
) {
    $codexAncestorNames = @("Codex.exe", "codex.exe")
    $gitRows = @($ProcessRows | Where-Object { $_.Name -ieq "git.exe" })

    foreach ($gitRow in $gitRows) {
        $ancestorChain = @(Get-AncestorChain -ProcessRow $gitRow -ProcessByPid $ProcessByPid -MaxDepth $MaxDepth)
        $isCodexGit = Test-HasAncestorProcessName `
            -ProcessRow $gitRow `
            -ProcessByPid $ProcessByPid `
            -Names $codexAncestorNames `
            -MaxDepth $MaxDepth

        if ($KillAll -or $isCodexGit) {
            [pscustomobject]@{
                ProcessId = [int]$gitRow.ProcessId
                ParentProcessId = [int]$gitRow.ParentProcessId
                Name = $gitRow.Name
                IsCodexGit = $isCodexGit
                Reason = if ($KillAll) { "KillAllGit" } else { "CodexAncestor" }
                AncestorChain = ($ancestorChain -join " <- ")
                CommandLine = $gitRow.CommandLine
            }
        }
    }
}

function Get-SumGB($Processes, [string]$PropertyName) {
    $sum = ($Processes | Measure-Object $PropertyName -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [math]::Round(([double]$sum) / 1GB, 3)
}

function Get-MemorySnapshot($Processes, $ProcessRows) {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue

    $availableBytes = Get-CounterValue "\Memory\Available Bytes"
    $commitBytes = Get-CounterValue "\Memory\Committed Bytes"
    $commitLimitBytes = Get-CounterValue "\Memory\Commit Limit"
    $poolNonpagedBytes = Get-CounterValue "\Memory\Pool Nonpaged Bytes"
    $poolPagedBytes = Get-CounterValue "\Memory\Pool Paged Bytes"

    $standbyCoreBytes = Get-CounterValue "\Memory\Standby Cache Core Bytes"
    $standbyNormalBytes = Get-CounterValue "\Memory\Standby Cache Normal Priority Bytes"
    $standbyReserveBytes = Get-CounterValue "\Memory\Standby Cache Reserve Bytes"
    $standbyBytes = 0
    foreach ($value in @($standbyCoreBytes, $standbyNormalBytes, $standbyReserveBytes)) {
        if ($null -ne $value) { $standbyBytes += [double]$value }
    }

    $totalGB = if ($cs) { [double]$cs.TotalPhysicalMemory / 1GB } else { $null }
    $availableGB = if ($os -and $null -ne $os.FreePhysicalMemory) {
        [double]($os.FreePhysicalMemory * 1KB) / 1GB
    } elseif ($null -ne $availableBytes) {
        [double]$availableBytes / 1GB
    } else {
        $null
    }
    $committedGB = if ($null -ne $commitBytes) { [double]$commitBytes / 1GB } else { $null }
    $commitLimitGB = if ($null -ne $commitLimitBytes) { [double]$commitLimitBytes / 1GB } else { $null }

    [pscustomobject]@{
        Timestamp = (Get-Date).ToString("o")
        UsedGB = if ($null -ne $totalGB -and $null -ne $availableGB) { [math]::Round($totalGB - $availableGB, 3) } else { $null }
        AvailableGB = if ($null -ne $availableGB) { [math]::Round($availableGB, 3) } else { $null }
        CommittedGB = if ($null -ne $committedGB) { [math]::Round($committedGB, 3) } else { $null }
        CommitLimitGB = if ($null -ne $commitLimitGB) { [math]::Round($commitLimitGB, 3) } else { $null }
        CommitPct = if ($commitLimitGB -gt 0) { [math]::Round(($committedGB / $commitLimitGB) * 100, 2) } else { $null }
        PoolNonpagedGB = Convert-ToGB $poolNonpagedBytes
        PoolPagedGB = Convert-ToGB $poolPagedBytes
        StandbyGB = if ($standbyBytes -gt 0) { [math]::Round($standbyBytes / 1GB, 3) } else { $null }
        ProcessPrivateGB = Get-SumGB -Processes $Processes -PropertyName "PrivateMemorySize64"
        ProcessWorkingSetGB = Get-SumGB -Processes $Processes -PropertyName "WorkingSet64"
        GitCount = @($ProcessRows | Where-Object { $_.Name -ieq "git.exe" }).Count
        ConhostCount = @($ProcessRows | Where-Object { $_.Name -ieq "conhost.exe" }).Count
        PowerShellCount = @($ProcessRows | Where-Object { $_.Name -in @("powershell.exe", "pwsh.exe") }).Count
        CodexCount = @($ProcessRows | Where-Object { $_.Name -in @("Codex.exe", "codex.exe") }).Count
        NodeCount = @($ProcessRows | Where-Object { $_.Name -ieq "node.exe" }).Count
    }
}

function Stop-TargetGitProcesses($Targets, [switch]$DryRunMode) {
    foreach ($target in $Targets) {
        $targetPid = [int]$target.ProcessId

        if ($DryRunMode) {
            [pscustomobject]@{
                Timestamp = (Get-Date).ToString("o")
                ProcessId = $targetPid
                Action = "would_stop"
                Reason = $target.Reason
                IsCodexGit = $target.IsCodexGit
                AncestorChain = $target.AncestorChain
                Error = $null
            }
            continue
        }

        try {
            Stop-Process -Id $targetPid -Force -ErrorAction Stop
            [pscustomobject]@{
                Timestamp = (Get-Date).ToString("o")
                ProcessId = $targetPid
                Action = "stopped"
                Reason = $target.Reason
                IsCodexGit = $target.IsCodexGit
                AncestorChain = $target.AncestorChain
                Error = $null
            }
        } catch {
            [pscustomobject]@{
                Timestamp = (Get-Date).ToString("o")
                ProcessId = $targetPid
                Action = "failed"
                Reason = $target.Reason
                IsCodexGit = $target.IsCodexGit
                AncestorChain = $target.AncestorChain
                Error = $_.Exception.Message
            }
        }
    }
}

$logSession = Initialize-LogSession -RequestedLogRoot $LogRoot
$LogRoot = $logSession.LogRoot
$session = $logSession.Session

$summaryCsv = Join-Path $session "guard-summary.csv"
$eventsLog = Join-Path $session "events.log"
$stopCsv = Join-Path $session "git-stop-actions.csv"

Set-Content -LiteralPath (Join-Path $LogRoot "current-session.txt") -Value $session -Encoding UTF8

$policy = if ($KillAllGit) { "KillAllGit" } else { "CodexAncestorOnly" }
"Started Codex Windows Git guard at $(Get-Date -Format o)" | Add-Content -LiteralPath $eventsLog -Encoding UTF8
"Policy: $policy; DryRun=$DryRun; KillAboveCodexGitCount=$KillAboveCodexGitCount; KillBelowAvailableGB=$KillBelowAvailableGB" |
    Add-Content -LiteralPath $eventsLog -Encoding UTF8

do {
    $processRows = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $processes = @(Get-Process -ErrorAction SilentlyContinue)
    $processByPid = New-ProcessMap -ProcessRows $processRows
    $targets = @(Get-TargetGitProcesses `
        -ProcessRows $processRows `
        -ProcessByPid $processByPid `
        -KillAll:$KillAllGit `
        -MaxDepth $MaxAncestorDepth)

    $snapshot = Get-MemorySnapshot -Processes $processes -ProcessRows $processRows
    $action = "none"
    $stopResults = @()

    $countTrip = $targets.Count -gt $KillAboveCodexGitCount
    $memoryTrip = (
        $KillBelowAvailableGB -gt 0 -and
        $null -ne $snapshot.AvailableGB -and
        $snapshot.AvailableGB -lt $KillBelowAvailableGB -and
        $targets.Count -gt 0
    )

    if ($countTrip -or $memoryTrip) {
        $stopResults = @(Stop-TargetGitProcesses -Targets $targets -DryRunMode:$DryRun)
        if ($stopResults.Count -gt 0) {
            $actionVerb = if ($DryRun) { "would_stop_git" } else { "stopped_git" }
            $action = "$actionVerb`:ids=" + (($stopResults | ForEach-Object { $_.ProcessId }) -join ",")
            if (Test-Path -LiteralPath $stopCsv) {
                $stopResults | Export-Csv -LiteralPath $stopCsv -NoTypeInformation -Append
            } else {
                $stopResults | Export-Csv -LiteralPath $stopCsv -NoTypeInformation
            }
        } else {
            $action = "triggered_no_target_git"
        }
    } elseif (
        $WarnBelowAvailableGB -gt 0 -and
        $null -ne $snapshot.AvailableGB -and
        $snapshot.AvailableGB -lt $WarnBelowAvailableGB
    ) {
        $action = "warn_low_memory"
    }

    $row = $snapshot | Select-Object *, `
        @{Name = "TargetGitCount"; Expression = { $targets.Count }}, `
        @{Name = "Policy"; Expression = { $policy }}, `
        @{Name = "DryRun"; Expression = { [bool]$DryRun }}, `
        @{Name = "Action"; Expression = { $action }}

    if (Test-Path -LiteralPath $summaryCsv) {
        $row | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Append
    } else {
        $row | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation
    }

    if ($action -ne "none") {
        ("{0} {1} AvailableGB={2} GitCount={3} TargetGitCount={4} CommitPct={5}" -f `
            $snapshot.Timestamp, $action, $snapshot.AvailableGB, $snapshot.GitCount, $targets.Count, $snapshot.CommitPct) |
            Add-Content -LiteralPath $eventsLog -Encoding UTF8
    }

    Write-Output ("{0} AvailableGB={1} GitCount={2} TargetGitCount={3} Action={4}" -f `
        $snapshot.Timestamp, $snapshot.AvailableGB, $snapshot.GitCount, $targets.Count, $action)

    if (-not $Once) {
        Start-Sleep -Seconds $IntervalSeconds
    }
} while (-not $Once)

Write-Output "SESSION=$session"
Write-Output "SUMMARY=$summaryCsv"
Write-Output "EVENTS=$eventsLog"
Write-Output "STOP_ACTIONS=$stopCsv"
