param(
    [switch]$NoLaunch,
    [switch]$DryRun,
    [switch]$KillAllGit,
    [int]$IntervalSeconds = 20,
    [double]$KillBelowAvailableGB = 1.0,
    [int]$KillAboveCodexGitCount = 0
)

$ErrorActionPreference = "Continue"

function Convert-ToInvariantString([object]$Value) {
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function Get-CodexAppId {
    $defaultAppId = "OpenAI.Codex_2p2nqsd0c76g0!App"

    try {
        $apps = @(Get-StartApps -ErrorAction Stop | Where-Object {
            $_.Name -match "Codex" -or $_.AppID -match "OpenAI\.Codex"
        })

        $preferred = $apps | Where-Object { $_.AppID -match "OpenAI\.Codex" } | Select-Object -First 1
        if ($preferred) { return $preferred.AppID }

        if ($apps.Count -gt 0) { return $apps[0].AppID }
    } catch {
    }

    return $defaultAppId
}

$guardScript = Join-Path $PSScriptRoot "Start-CodexGitGuard.ps1"
if (-not (Test-Path -LiteralPath $guardScript)) {
    throw "Guard script not found: $guardScript"
}

$resolvedGuardScript = (Resolve-Path -LiteralPath $guardScript).Path
$existingGuard = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -in @("powershell.exe", "pwsh.exe") -and
    $_.CommandLine -match [regex]::Escape($resolvedGuardScript)
})

if (-not $existingGuard) {
    $guardArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$resolvedGuardScript`"",
        "-IntervalSeconds", (Convert-ToInvariantString $IntervalSeconds),
        "-KillBelowAvailableGB", (Convert-ToInvariantString $KillBelowAvailableGB),
        "-KillAboveCodexGitCount", (Convert-ToInvariantString $KillAboveCodexGitCount)
    )

    if ($DryRun) { $guardArgs += "-DryRun" }
    if ($KillAllGit) { $guardArgs += "-KillAllGit" }

    Start-Process -FilePath "powershell.exe" -ArgumentList $guardArgs -WindowStyle Hidden
    Write-Output "Started Codex Windows Git guard."
} else {
    Write-Output "Codex Windows Git guard is already running."
}

if (-not $NoLaunch) {
    $appId = Get-CodexAppId
    Start-Process "shell:AppsFolder\$appId"
    Write-Output "Launched Codex with app id: $appId"
} else {
    Write-Output "NoLaunch set; Codex was not launched."
}
