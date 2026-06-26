# Codex Windows Guard

Small PowerShell tools for reducing Windows memory pressure caused by Codex-triggered Git process storms.

This is an unofficial community tool. It does not modify Codex, delete user files, or fix the root cause inside Codex. It gives Windows users a safer guardrail while working in large folders that can make Git scans expensive.

## What Problem It Targets

Some Windows users see memory usage climb quickly after opening Codex in large workspaces. A common pattern is:

- Codex opens or remembers a large Git workspace.
- Codex launches repeated `git.exe` commands for review, branch, diff, status, or metadata checks.
- `git.exe`, `conhost.exe`, and commit/memory pressure rise quickly.
- Windows stays under pressure even after the initial Git burst stops.

The default guard only stops `git.exe` processes whose parent/ancestor process is Codex. It does not stop unrelated Git work by default.

## Quick Start

From an elevated or normal PowerShell prompt:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-CodexGitGuard.ps1
```

Dry run first if you want to see what would happen:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-CodexGitGuard.ps1 -Once -DryRun
```

Start the guard and then launch Codex:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-CodexSafe.ps1
```

Install a Start Menu shortcut:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-StartMenuShortcut.ps1 -Desktop
```

Stop the background guard:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Stop-CodexGitGuard.ps1
```

## Tools

- `scripts/Start-CodexGitGuard.ps1`: monitors memory and Git process counts, then stops only Codex-owned `git.exe` processes by default.
- `scripts/Start-CodexSafe.ps1`: starts the guard and launches Codex.
- `scripts/Stop-CodexGitGuard.ps1`: stops the background guard process.
- `scripts/Invoke-SafeMemoryRelease.ps1`: trims process working sets with Windows `EmptyWorkingSet`; it does not intentionally close apps.
- `scripts/Install-StartMenuShortcut.ps1`: creates a Start Menu shortcut, and optionally a Desktop shortcut.

## Safety Model

Default behavior:

- Stops only `git.exe` processes with `Codex.exe` or `codex.exe` in their ancestor process chain.
- Writes logs under `%LOCALAPPDATA%\CodexWindowsGuard`.
- Does not delete files.
- Does not archive Codex threads.
- Does not stop `node.exe`, app servers, browser processes, or unrelated Git processes.

Opt-in behavior:

- `-KillAllGit` stops all visible `git.exe` processes. Use it only during an active storm.
- `Invoke-SafeMemoryRelease.ps1` can make apps reload memory later because it trims working sets.

## Suggested Large-Workspace Hygiene

Before opening huge generated folders in Git-aware tools, make sure build output, browser profiles, render folders, and caches are ignored. See:

```text
docs/gitignore-snippet.md
```

## Logs

The guard writes:

```text
%LOCALAPPDATA%\CodexWindowsGuard\logs\<timestamp>\guard-summary.csv
%LOCALAPPDATA%\CodexWindowsGuard\logs\<timestamp>\events.log
%LOCALAPPDATA%\CodexWindowsGuard\logs\<timestamp>\git-stop-actions.csv
```

These logs help distinguish a Git process storm from a normal process memory leak.

## Disclaimer

This project is not affiliated with OpenAI. Codex is a trademark of its owner. The shortcut installer may reference the locally installed Codex app icon when Windows exposes it, but this repository does not include or redistribute Codex branding assets.
