<#
  register-task.ps1 - register (or remove) the daily soft-updater task.

  The task runs update-all.ps1 -Auto -Notify once a day at the given time
  (default 02:00) in the current user's session, hidden, with no network
  requirement set (the script itself fails over across mirrors).

  Usage:
    powershell -ExecutionPolicy Bypass -File register-task.ps1
    ... register-task.ps1 -Time 09:30
    ... register-task.ps1 -Unregister

  A daily trigger is used because ONLOGON triggers were rejected on this
  machine (0x80070005); a daily trigger plus the script's own daily
  throttle gives the same "once per day" behaviour.

  NOTE: Keep this file ASCII-only so it parses under every codepage on
  Windows PowerShell 5.1.
#>

param(
    [string]$Time = "02:00",
    [switch]$Unregister,
    [string]$TaskName = "soft-updater"
)

$ErrorActionPreference = "Stop"
$Root     = $PSScriptRoot
$Script   = Join-Path $Root "update-all.ps1"

if (-not (Test-Path $Script)) { throw "update-all.ps1 not found next to this script: $Script" }

if ($Unregister) {
    schtasks.exe /Delete /TN $TaskName /F | Out-Null
    Write-Host "[done] task '$TaskName' removed."
    exit 0
}

$powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$action = "`"$powershell`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`" -Auto -Notify"
$runAs  = "$env:USERDOMAIN\$env:USERNAME"

$create = @(
    '/Create', '/TN', $TaskName, '/SC', 'DAILY', '/ST', $Time,
    '/TR', $action, '/RU', $runAs, '/RL', 'LIMITED', '/F'
)
$out = schtasks.exe @create 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "schtasks failed ($LASTEXITCODE): $out"
}
Write-Host "[done] task '$TaskName' registered: daily at $Time as $runAs"
Write-Host "       action: $action"
Write-Host "       log:    $(Join-Path $Root 'update.log')"
Write-Host "       remove: powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Unregister"
