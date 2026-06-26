param(
    [switch]$SkipCodex,
    [switch]$DryRun,
    [string]$LogRoot = "$env:LOCALAPPDATA\CodexWindowsGuard\memory-release"
)

$ErrorActionPreference = "Continue"

if ([string]::IsNullOrWhiteSpace($LogRoot)) {
    $LogRoot = Join-Path $PSScriptRoot "..\logs\memory-release"
}

if (-not $DryRun -and -not ("WorkingSetTools" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class WorkingSetTools {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(UInt32 dwDesiredAccess, bool bInheritHandle, UInt32 dwProcessId);

    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
"@
}

function Get-CounterValue([string]$Path) {
    try {
        return (Get-Counter $Path -ErrorAction Stop).CounterSamples[0].CookedValue
    } catch {
        return $null
    }
}

function Initialize-LogSession([string]$RequestedLogRoot) {
    $fallbackLogRoot = Join-Path $env:TEMP "CodexWindowsGuard\memory-release"

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

function Convert-ToGB([Nullable[double]]$Bytes) {
    if ($null -eq $Bytes) { return $null }
    return [math]::Round(([double]$Bytes) / 1GB, 3)
}

function Get-MemorySnapshot([string]$Label) {
    $processes = @(Get-Process -ErrorAction SilentlyContinue)
    $processRows = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue

    $availableBytes = Get-CounterValue "\Memory\Available Bytes"
    $commitBytes = Get-CounterValue "\Memory\Committed Bytes"
    $commitLimitBytes = Get-CounterValue "\Memory\Commit Limit"
    $poolNonpagedBytes = Get-CounterValue "\Memory\Pool Nonpaged Bytes"
    $poolPagedBytes = Get-CounterValue "\Memory\Pool Paged Bytes"

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
        Label = $Label
        Timestamp = (Get-Date).ToString("o")
        AvailableGB = if ($null -ne $availableGB) { [math]::Round($availableGB, 3) } else { $null }
        UsedGB = if ($null -ne $totalGB -and $null -ne $availableGB) { [math]::Round($totalGB - $availableGB, 3) } else { $null }
        CommittedGB = if ($null -ne $committedGB) { [math]::Round($committedGB, 3) } else { $null }
        CommitPct = if ($commitLimitGB -gt 0) { [math]::Round(($committedGB / $commitLimitGB) * 100, 2) } else { $null }
        PoolNonpagedGB = Convert-ToGB $poolNonpagedBytes
        PoolPagedGB = Convert-ToGB $poolPagedBytes
        ProcessPrivateGB = [math]::Round((($processes | Measure-Object PrivateMemorySize64 -Sum).Sum) / 1GB, 3)
        ProcessWorkingSetGB = [math]::Round((($processes | Measure-Object WorkingSet64 -Sum).Sum) / 1GB, 3)
        GitCount = @($processRows | Where-Object { $_.Name -ieq "git.exe" }).Count
        CodexCount = @($processRows | Where-Object { $_.Name -in @("Codex.exe", "codex.exe") }).Count
        NodeCount = @($processRows | Where-Object { $_.Name -ieq "node.exe" }).Count
    }
}

$logSession = Initialize-LogSession -RequestedLogRoot $LogRoot
$LogRoot = $logSession.LogRoot
$session = $logSession.Session

$csv = Join-Path $session "memory-release.csv"
$details = Join-Path $session "trimmed-processes.csv"
Set-Content -LiteralPath (Join-Path $LogRoot "current-session.txt") -Value $session -Encoding UTF8

$before = Get-MemorySnapshot "before"
$before | Export-Csv -LiteralPath $csv -NoTypeInformation

$PROCESS_SET_QUOTA = 0x0100
$PROCESS_QUERY_INFORMATION = 0x0400
$access = $PROCESS_SET_QUOTA -bor $PROCESS_QUERY_INFORMATION
$currentProcessId = $PID
$skipNames = @("Idle", "System", "Secure System", "Registry", "Memory Compression")
$trimmed = New-Object System.Collections.Generic.List[object]

foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
    if ($process.Id -le 4 -or $process.Id -eq $currentProcessId) { continue }
    if ($skipNames -contains $process.ProcessName) { continue }
    if ($SkipCodex -and $process.ProcessName -in @("Codex", "codex")) { continue }

    $beforeWs = $process.WorkingSet64

    if ($DryRun) {
        $trimmed.Add([pscustomobject]@{
            ProcessName = $process.ProcessName
            Id = $process.Id
            BeforeWorkingSetMB = [math]::Round($beforeWs / 1MB, 2)
            Action = "would_trim"
        }) | Out-Null
        continue
    }

    $handle = [WorkingSetTools]::OpenProcess($access, $false, [uint32]$process.Id)
    if ($handle -eq [IntPtr]::Zero) { continue }

    try {
        $ok = [WorkingSetTools]::EmptyWorkingSet($handle)
        if ($ok) {
            $trimmed.Add([pscustomobject]@{
                ProcessName = $process.ProcessName
                Id = $process.Id
                BeforeWorkingSetMB = [math]::Round($beforeWs / 1MB, 2)
                Action = "trimmed"
            }) | Out-Null
        }
    } finally {
        [void][WorkingSetTools]::CloseHandle($handle)
    }
}

if (-not $DryRun) {
    Start-Sleep -Seconds 5
}

$after = Get-MemorySnapshot $(if ($DryRun) { "after-dry-run" } else { "after-trim" })
$after | Export-Csv -LiteralPath $csv -NoTypeInformation -Append
$trimmed | Sort-Object BeforeWorkingSetMB -Descending | Export-Csv -LiteralPath $details -NoTypeInformation

Write-Output "SESSION=$session"
Write-Output "CSV=$csv"
Write-Output "DETAILS=$details"
Write-Output "Before:"
$before | Format-List
Write-Output "After:"
$after | Format-List
Write-Output "ProcessCount=$($trimmed.Count)"
Write-Output "DryRun=$DryRun"
