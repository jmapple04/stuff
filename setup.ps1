#Requires -Version 5.1
<#
.SYNOPSIS
  Stands up a two-node Vault Transit auto-unseal PoC locally on Windows.

  Unseal node  : http://127.0.0.1:8200  (Shamir, hosts transit engine)
  Service node : http://127.0.0.1:8100  (auto-unsealed via the unseal node)

.DESCRIPTION
  Run .\teardown.ps1 to stop both, or .\teardown.ps1 -Wipe to also delete state.
  Requires only the 'vault' CLI on PATH — JSON is parsed natively, no jq needed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\setup.ps1
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Anchor everything to the script's own folder.
$BaseDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $BaseDir

$UnsealAddr  = 'http://127.0.0.1:8200'
$ServiceAddr = 'http://127.0.0.1:8100'
$ConfigDir   = Join-Path $BaseDir 'config'
$DataDir     = Join-Path $BaseDir 'data'
$LogDir      = Join-Path $BaseDir 'logs'
$CredDir     = Join-Path $BaseDir 'credentials'
$PidDir      = Join-Path $BaseDir 'pids'

function Say  { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Info { param([string]$Msg) Write-Host "    $Msg" }
function Die  { param([string]$Msg) Write-Host "`nERROR: $Msg" -ForegroundColor Red; exit 1 }

# --- preflight ----------------------------------------------------------------
if (-not (Get-Command vault -ErrorAction SilentlyContinue)) {
  Die "vault not found on PATH. Install it: winget install Hashicorp.Vault  (see README for alternatives)"
}

$unsealPidFile = Join-Path $PidDir 'unseal.pid'
if (Test-Path $unsealPidFile) {
  $existing = Get-Content $unsealPidFile -ErrorAction SilentlyContinue
  if ($existing -and (Get-Process -Id $existing -ErrorAction SilentlyContinue)) {
    Die "The PoC looks like it's already running (pid $existing). Run .\teardown.ps1 first."
  }
}
if ((Test-Path (Join-Path $DataDir 'unseal')) -and
    (Get-ChildItem (Join-Path $DataDir 'unseal') -ErrorAction SilentlyContinue)) {
  Die "Existing state in $DataDir. Run .\teardown.ps1 -Wipe for a clean start."
}

foreach ($d in @((Join-Path $DataDir 'unseal'), (Join-Path $DataDir 'service'), $LogDir, $CredDir, $PidDir)) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# Wait until a Vault server is reachable. vault status exits 0 (unsealed) or 2 (sealed).
function Wait-Vault {
  param([string]$Addr)
  $env:VAULT_ADDR = $Addr
  for ($i = 0; $i -lt 60; $i++) {
    vault status *> $null
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 2) { return }
    Start-Sleep -Milliseconds 500
  }
  Die "Timed out waiting for Vault at $Addr (check $LogDir)."
}

# Launch a vault server in the background, record its PID.
function Start-Node {
  param([string]$Name, [string]$ConfigFile)
  $p = Start-Process -FilePath 'vault' `
        -ArgumentList @('server', "-config=$ConfigFile") `
        -RedirectStandardOutput (Join-Path $LogDir "$Name.out.log") `
        -RedirectStandardError  (Join-Path $LogDir "$Name.err.log") `
        -WindowStyle Hidden -PassThru
  $p.Id | Out-File -Encoding ascii (Join-Path $PidDir "$Name.pid")
  return $p
}

# --- 1. unseal node -----------------------------------------------------------
Say "Starting unseal node on $UnsealAddr"
Start-Node -Name 'unseal' -ConfigFile (Join-Path $ConfigDir 'unseal-vault.hcl') | Out-Null
Wait-Vault $UnsealAddr

$env:VAULT_ADDR = $UnsealAddr

Say "Initializing + unsealing the unseal node (1 key share for PoC simplicity)"
$unsealInitRaw = vault operator init -key-shares=1 -key-threshold=1 -format=json
$unsealInitRaw | Out-File -Encoding utf8 (Join-Path $CredDir 'unseal-init.json')
$unsealInit = $unsealInitRaw | ConvertFrom-Json
$unsealKey  = $unsealInit.unseal_keys_b64[0]
$unsealRoot = $unsealInit.root_token
vault operator unseal $unsealKey | Out-Null
$env:VAULT_TOKEN = $unsealRoot
Info "unseal node root token + key saved to credentials\unseal-init.json"

# --- 2. transit engine, key, policy, token ------------------------------------
Say "Enabling transit engine and creating the autounseal key"
vault secrets enable transit *> $null   # ignore 'already enabled' on re-run
vault write -f transit/keys/autounseal | Out-Null

Say "Writing a least-privilege policy + an orphan, periodic token for the service node"
$policy = @'
path "transit/encrypt/autounseal" {
  capabilities = ["update"]
}
path "transit/decrypt/autounseal" {
  capabilities = ["update"]
}
'@
$policy | vault policy write autounseal - | Out-Null

# -orphan so it survives the root token; -period so it stays renewable forever
# as long as the service node keeps renewing it (Vault does this automatically).
$autounsealToken = (vault token create -orphan -period=24h -policy=autounseal -field=token).Trim()

# --- 3. service node ----------------------------------------------------------
Say "Rendering service node config with the autounseal token"
$tmpl = Get-Content (Join-Path $ConfigDir 'service-vault.hcl.tmpl') -Raw
$tmpl.Replace('AUTOUNSEAL_TOKEN_PLACEHOLDER', $autounsealToken) |
  Set-Content -Encoding ascii (Join-Path $ConfigDir 'service-vault.hcl')

Say "Starting service node on $ServiceAddr"
Start-Node -Name 'service' -ConfigFile (Join-Path $ConfigDir 'service-vault.hcl') | Out-Null
Wait-Vault $ServiceAddr

$env:VAULT_ADDR = $ServiceAddr
Remove-Item Env:\VAULT_TOKEN -ErrorAction SilentlyContinue

Say "Initializing the service node (auto-seal => recovery keys, no unseal keys)"
$svcInitRaw = vault operator init -recovery-shares=1 -recovery-threshold=1 -format=json
$svcInitRaw | Out-File -Encoding utf8 (Join-Path $CredDir 'service-init.json')
Start-Sleep -Seconds 1   # give it a moment to auto-unseal after init

# --- 4. verify ----------------------------------------------------------------
Say "Verifying the service node auto-unsealed"
$env:VAULT_ADDR = $ServiceAddr
$status = vault status -format=json | ConvertFrom-Json
if ($status.type -eq 'transit' -and -not $status.sealed) {
  Info "Seal type: transit   Sealed: false   <- auto-unseal working"
} else {
  Die "Service node did not auto-unseal (type=$($status.type) sealed=$($status.sealed)). See $LogDir\service.err.log"
}

# --- summary ------------------------------------------------------------------
Write-Host "`nPoC is up." -ForegroundColor Green
@"

  Unseal node   $UnsealAddr     UI: $UnsealAddr/ui
  Service node  $ServiceAddr     UI: $ServiceAddr/ui

  Talk to the service node:
    `$env:VAULT_ADDR  = '$ServiceAddr'
    `$env:VAULT_TOKEN = (Get-Content credentials\service-init.json | ConvertFrom-Json).root_token
    vault secrets enable -path=secret kv-v2
    vault kv put secret/hello msg=world
    vault kv get secret/hello

  Prove auto-unseal end to end:
    Stop-Process -Id (Get-Content pids\service.pid)                   # stop service node
    Start-Process vault -ArgumentList 'server','-config=config\service-vault.hcl' -WindowStyle Hidden
    `$env:VAULT_ADDR='$ServiceAddr'; vault status                       # Sealed: false, no keys entered

  Show the dependency (the "who unseals the unsealer" problem):
    Stop-Process -Id (Get-Content pids\unseal.pid),(Get-Content pids\service.pid)
    Start-Process vault -ArgumentList 'server','-config=config\service-vault.hcl' -WindowStyle Hidden
    `$env:VAULT_ADDR='$ServiceAddr'; vault status                       # stays Sealed until unseal node is back

  Stop everything:    .\teardown.ps1
  Stop + wipe state:  .\teardown.ps1 -Wipe

  Credentials (PLAINTEXT — PoC only): .\credentials\
"@ | Write-Host
