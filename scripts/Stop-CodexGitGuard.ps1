param(
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"

$guardScript = Join-Path $PSScriptRoot "Start-CodexGitGuard.ps1"
$resolvedGuardScript = if (Test-Path -LiteralPath $guardScript) {
    (Resolve-Path -LiteralPath $guardScript).Path
} else {
    $guardScript
}

$guardProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -in @("powershell.exe", "pwsh.exe") -and
    $_.CommandLine -match [regex]::Escape($resolvedGuardScript)
})

if ($guardProcesses.Count -eq 0) {
    Write-Output "No Codex Windows Git guard process found."
    return
}

foreach ($guardProcess in $guardProcesses) {
    $guardProcessId = [int]$guardProcess.ProcessId

    if ($DryRun) {
        Write-Output "Would stop guard process $guardProcessId"
        continue
    }

    try {
        Stop-Process -Id $guardProcessId -Force -ErrorAction Stop
        Write-Output "Stopped guard process $guardProcessId"
    } catch {
        Write-Warning "Failed to stop guard process $guardProcessId`: $($_.Exception.Message)"
    }
}
