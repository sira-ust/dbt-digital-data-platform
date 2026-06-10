# dbt-env.ps1 — load dbt venv into current PowerShell session
# Usage: . .\dbt-env.ps1
#
# Dot-sourcing (the leading dot) is required so the env vars persist
# in the calling shell rather than a child process.
#
# This is a workaround for the PowerShell execution policy blocking
# .venv\Scripts\Activate.ps1 on managed machines.

$env:PATH = "$PSScriptRoot\.venv\Scripts;$env:PATH"
$env:DBT_PROFILES_DIR = $PSScriptRoot

Write-Host "dbt env loaded — venv: $PSScriptRoot\.venv" -ForegroundColor Cyan
