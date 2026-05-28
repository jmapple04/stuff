#Requires -Version 5.1
<#
.SYNOPSIS
  Stops the two Vault nodes started by setup.ps1.

.PARAMETER Wipe
  Also delete all state, credentials, logs, and the generated service config.

.EXAMPLE
  .\teardown.ps1
.EXAMPLE
  .\teardown.ps1 -Wipe
#>
param([switch]$Wipe)

Set-StrictMode -Version Latest

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $BaseDir
$PidDir = Join-Path $BaseDir 'pids'

# Stop service node first, then the unseal node it depends on.
foreach ($node in @('service', 'unseal')) {
  $pidFile = Join-Path $PidDir "$node.pid"
  if (Test-Path $pidFile) {
    $procId = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($procId -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
      Write-Host "Stopping $node node (pid $procId)"
      Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
  }
}

if ($Wipe) {
  Write-Host "Wiping state, credentials, logs, and generated config"
  foreach ($d in @('data', 'credentials', 'logs', 'pids')) {
    Remove-Item (Join-Path $BaseDir $d) -Recurse -Force -ErrorAction SilentlyContinue
  }
  Remove-Item (Join-Path $BaseDir 'config\service-vault.hcl') -Force -ErrorAction SilentlyContinue
}

Write-Host "Done."
