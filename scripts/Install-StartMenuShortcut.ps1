param(
    [string]$ShortcutName = "Codex Safe.lnk",
    [switch]$Desktop
)

$ErrorActionPreference = "Continue"

function Find-CodexIconLocation {
    try {
        $package = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($package) {
            $codexExe = Join-Path $package.InstallLocation "Codex.exe"
            if (Test-Path -LiteralPath $codexExe) { return $codexExe }

            $candidate = Get-ChildItem -LiteralPath $package.InstallLocation -Filter "*.exe" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "Codex" } |
                Select-Object -First 1
            if ($candidate) { return $candidate.FullName }
        }
    } catch {
    }

    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

$launcher = Join-Path $PSScriptRoot "Start-CodexSafe.ps1"
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher not found: $launcher"
}

$destinations = New-Object System.Collections.Generic.List[string]
$startMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$destinations.Add($startMenuDir) | Out-Null

if ($Desktop) {
    $desktopDir = [Environment]::GetFolderPath("Desktop")
    if (-not [string]::IsNullOrWhiteSpace($desktopDir)) {
        $destinations.Add($desktopDir) | Out-Null
    }
}

$powershellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
$iconLocation = Find-CodexIconLocation
$wshShell = New-Object -ComObject WScript.Shell

foreach ($destination in $destinations) {
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    $shortcutPath = Join-Path $destination $ShortcutName
    $shortcut = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powershellPath
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$launcher`""
    $shortcut.WorkingDirectory = Split-Path -Parent $PSScriptRoot
    $shortcut.IconLocation = $iconLocation
    $shortcut.Description = "Start the Codex Windows Git guard, then launch Codex."
    $shortcut.Save()
    Write-Output "Created shortcut: $shortcutPath"
}

Write-Output "IconLocation=$iconLocation"
