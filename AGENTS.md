# Agent Safety Rules

This repository exists because broad Git scans can trigger process storms on Windows.

- Do not run broad Git commands unless the user explicitly asks for Git work.
- Avoid `git status`, full-repository `git diff`, `git add -A`, and review commands that enumerate the whole tree.
- Prefer direct file reads and writes against explicit paths.
- If Git is necessary, keep commands path-limited and explain why.
- If `git.exe`, `conhost.exe`, or memory usage starts rising quickly, stop Git work and use the guard/triage workflow.
- Never delete user files as a mitigation. If metadata must be isolated, move it to a timestamped `trash` folder and report the restore path.
