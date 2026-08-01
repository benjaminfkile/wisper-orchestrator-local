# orchestrator.ps1 - local orchestrator, wired to the wisper stack this folder runs.
#
#   .\orchestrator.ps1 -Init <branch>      cold start: clone + build from <branch>
#   .\orchestrator.ps1                     start (API + web UI)
#   .\orchestrator.ps1 -Refetch <branch>   pull, rebuild, restart
#   .\orchestrator.ps1 -Down               stop orchestrator only
#   .\orchestrator.ps1 -Status             health overview
#
# What it runs (loopback-only, no services):
#   orchestrator API   http://127.0.0.1:3010   (SQLite; knex migrations run at boot)
#   orchestrator web   http://localhost:4400   (Vite dev server, proxies /api -> 3010)
#
# Wisper wiring (v1 consumer surface - the authenticated path):
#   WISPER_MODE=v1, WISPER_BASE_URL=http://127.0.0.1:3006, WISPER_HOST_ID=local-host.
#   On every start the wck_ API key from state\stack-state.json is seeded into the
#   orchestrator secret store as WISPER_API_KEY (PUT /api/secrets - value never logged).
#   Leasing needs the manager (.\wisper.ps1) AND the host (.\host.ps1) up; the
#   orchestrator itself boots fine without them (dispatches fail, boot does not).
#
# The orchestrator's native port is 3007, which this stack gives to wisper-web -
# so the API runs on 3010 here, and the web UI gets an UNTRACKED local vite
# config (web\vite.config.local.ts, regenerated on every install/refetch) whose
# /api proxy targets 3010. Untracked means -Refetch's --ff-only pull never
# conflicts with it.
#
# Shares this folder: repos\ (adds orchestrator), logs\, state\stack-state.json
# (wck key), own pid file (state\orch-pids.json). The SQLite DB is
# kept in state\orchestrator.sqlite via ORCH_DB_PATH. NOTE: the orchestrator's
# encrypted secret store + dispatch logs live in %APPDATA%\orchestrator (its
# design; master key in the OS keychain) - deleting this folder does not remove
# those.

[CmdletBinding()]
param(
    [string]$Init = "",         # branch for a cold start (also refetches if installed)
    [string]$Refetch = "",      # branch: pull, rebuild, restart
    [switch]$Down,
    [switch]$Status,
    [int]$OrchPort = 3010,
    [int]$WebUiPort = 4400,
    [int]$ApiPort = 3006,       # the local wisper-api (see wisper.ps1)
    # How long the orchestrator waits for wisper's create-lease call (ms).
    # Lease creation is SYNCHRONOUS through the container's entire userdata
    # provision (fx-sandbox-base builds ~6 min, worst case much longer); the
    # orchestrator's built-in default is a fatal 150s. Keep below the playbook's
    # ttl_seconds - 60 dispatch deadline - see LEASE-TIMEOUTS-RUNBOOK.md.
    [int]$CreateLeaseTimeoutMs = 3000000
)

$ErrorActionPreference = "Stop"

# $PSScriptRoot is empty in param defaults under `powershell -File` - resolve here.
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$Dirs = @{
    Repos = Join-Path $Root "repos"
    Logs  = Join-Path $Root "logs"
    State = Join-Path $Root "state"
}
$StateFile = Join-Path $Dirs.State "stack-state.json"
$PidsFile  = Join-Path $Dirs.State "orch-pids.json"
$GitHubUser = "benjaminfkile"
$OrchUrl   = "http://127.0.0.1:$OrchPort"
$WisperUrl = "http://127.0.0.1:$ApiPort"
$RepoDir   = Join-Path $Dirs.Repos "orchestrator"

# ------------------------------------------------------------------ helpers

function Get-State {
    if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json } else { $null }
}
function Save-State($State) {
    [System.IO.File]::WriteAllText($StateFile, ($State | ConvertTo-Json -Depth 10))
}
function Set-StateProp($State, [string]$Name, $Value) {
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}
function Invoke-Quiet([string]$File, [string[]]$Arguments = @()) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & $File @Arguments 2>&1 | Out-Null; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $eap }
}
function Test-HttpOk([string]$Url) {
    try { Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 4 | Out-Null; $true } catch { $false }
}
function Wait-Http([string]$Url, [int]$TimeoutSec, [string]$Name) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-HttpOk $Url) { return }
        Start-Sleep -Milliseconds 800
    }
    throw "$Name did not become healthy at $Url within ${TimeoutSec}s (see $($Dirs.Logs))"
}
function Format-Arg([string]$Arg) { if ($Arg -match "\s") { '"' + $Arg + '"' } else { $Arg } }

# Hidden cmd.exe wrapper (visible-console / redirect gotcha) - see wisper.ps1.
function Start-Svc {
    param([string]$Name, [string]$File, [string[]]$Arguments = @(), [string]$Cwd, [hashtable]$Env = @{})
    $saved = @{}
    foreach ($k in $Env.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, "Process")
        [Environment]::SetEnvironmentVariable($k, [string]$Env[$k], "Process")
    }
    try {
        $outLog = Join-Path $Dirs.Logs "$Name.out.log"
        $errLog = Join-Path $Dirs.Logs "$Name.err.log"
        $argStr = ($Arguments | ForEach-Object { Format-Arg $_ }) -join " "
        $cmdLine = '"' + $File + '" ' + $argStr + ' 1>"' + $outLog + '" 2>"' + $errLog + '"'
        $p = Start-Process -FilePath "cmd.exe" -WindowStyle Hidden -PassThru `
            -WorkingDirectory $Cwd -ArgumentList ('/s /c "' + $cmdLine + '"')
        Write-Host ("  started {0} (pid {1})" -f $Name, $p.Id)
        return @{ pid = $p.Id; proc = $p.ProcessName }
    } finally {
        foreach ($k in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($k, $saved[$k], "Process")
        }
    }
}
function Read-Pids { if (Test-Path $PidsFile) { Get-Content $PidsFile -Raw | ConvertFrom-Json } else { $null } }
function Save-Pids([hashtable]$Map) { [System.IO.File]::WriteAllText($PidsFile, ($Map | ConvertTo-Json -Depth 5)) }
function Test-SvcAlive($Entry) {
    if ($null -eq $Entry -or $null -eq $Entry.pid) { return $false }
    $p = Get-Process -Id $Entry.pid -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $false }
    ($null -eq $Entry.proc) -or ($p.ProcessName -eq $Entry.proc)
}
function Stop-Orch {
    $pids = Read-Pids
    if ($null -ne $pids) {
        foreach ($p in $pids.PSObject.Properties) {
            if (Test-SvcAlive $p.Value) {
                Write-Host "  stopping $($p.Name) (pid $($p.Value.pid))"
                Invoke-Quiet "taskkill" @("/PID", "$($p.Value.pid)", "/T", "/F") | Out-Null
            }
        }
        Remove-Item $PidsFile -Force -ErrorAction SilentlyContinue
    }
}
# The untracked vite override: same shape as web\vite.config.ts but with this
# stack's /api proxy target. Regenerated on every build so port params stick.
function Write-ViteLocalConfig {
    $cfg = Join-Path $RepoDir "web\vite.config.local.ts"
    [System.IO.File]::WriteAllText($cfg, @"
// Generated by orchestrator.ps1 - untracked local override; do not commit.
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: $WebUiPort,
    strictPort: true,
    proxy: {
      "/api": {
        target: "http://127.0.0.1:$OrchPort",
        changeOrigin: true,
      },
    },
  },
});
"@)
    Write-Host "  wrote web\vite.config.local.ts (ui $WebUiPort -> api $OrchPort)"
}

function Invoke-OrchBuild {
    Write-Host "-- building" -ForegroundColor Cyan
    Push-Location $RepoDir
    Write-Host "  orchestrator (npm ci)"
    & npm ci --no-audit --no-fund --loglevel error
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  npm ci failed - trying npm install"
        & npm install --no-audit --no-fund --loglevel error
        if ($LASTEXITCODE -ne 0) { Pop-Location; throw "orchestrator npm install failed" }
    }
    Write-Host "  orchestrator web (npm ci)"
    & npm --prefix web ci --no-audit --no-fund --loglevel error
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  web npm ci failed - trying npm install"
        & npm --prefix web install --no-audit --no-fund --loglevel error
        if ($LASTEXITCODE -ne 0) { Pop-Location; throw "orchestrator web npm install failed" }
    }
    Write-Host "  orchestrator (npm run build)"
    & npm run build
    if ($LASTEXITCODE -ne 0) { Pop-Location; throw "orchestrator build failed" }
    Pop-Location
    Write-ViteLocalConfig
}

# ------------------------------------------------------------------ -Down / -Status

if ($Down) {
    Write-Host "== orchestrator down ==" -ForegroundColor Cyan
    Stop-Orch
    Write-Host "== orchestrator stopped (wisper stack untouched) ==" -ForegroundColor Green
    return
}

if ($Status) {
    Write-Host "== orchestrator status ==" -ForegroundColor Cyan
    $pids = Read-Pids
    foreach ($svc in @("orchestrator", "orchestrator-web")) {
        $entry = $null
        if ($null -ne $pids) { $entry = $pids.PSObject.Properties[$svc].Value }
        $alive = Test-SvcAlive $entry
        $url = "$OrchUrl/api/health"
        if ($svc -eq "orchestrator-web") { $url = "http://localhost:$WebUiPort" }
        $health = "-"
        if ($alive) { $health = @("unhealthy", "healthy")[[int](Test-HttpOk $url)] }
        Write-Host ("  {0,-17} {1}  {2}" -f $svc, @("STOPPED", "running")[[int]$alive], $health)
    }
    Write-Host ("  wisper-api        {0} at $WisperUrl" -f @("UNREACHABLE", "reachable")[[int](Test-HttpOk "$WisperUrl/healthz")])
    return
}

# ------------------------------------------------------------------ state + PAT

foreach ($d in $Dirs.Values) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$state = Get-State
if ($null -eq $state) { $state = [pscustomobject]@{} }

if ($null -eq $state.wckKey) {
    throw "No wck_ API key in state - stand up the manager first: .\wisper.ps1 -Init <branch>"
}

# ------------------------------------------------------------------ install / refetch

$needClone = -not (Test-Path (Join-Path $RepoDir ".git"))

if ($Init) {
    if (-not $needClone) {
        Write-Host "Orchestrator already cloned - treating -Init '$Init' as -Refetch '$Init'." -ForegroundColor Yellow
        $Refetch = $Init
    } else {
        Set-StateProp $state "orchBranch" $Init
        Save-State $state
    }
}
if ($needClone -and $null -eq $state.orchBranch) {
    throw "Orchestrator not installed yet - cold start with: .\orchestrator.ps1 -Init <branch>"
}

if ($needClone) {
    Write-Host "== orchestrator install ==" -ForegroundColor Cyan
    foreach ($tool in @("git", "node", "npm")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Missing required tool: $tool" }
    }
    Write-Host "  cloning orchestrator (branch $($state.orchBranch))"
    & git clone --quiet --branch $state.orchBranch "https://github.com/$GitHubUser/orchestrator.git" $RepoDir
    if ($LASTEXITCODE -ne 0) { throw "clone of orchestrator failed (branch '$($state.orchBranch)' missing?)" }
    Invoke-OrchBuild
    Write-Host "== orchestrator install done ==" -ForegroundColor Green
}

if ($Refetch) {
    Write-Host "== orchestrator refetch '$Refetch' ==" -ForegroundColor Cyan
    Stop-Orch
    Set-StateProp $state "orchBranch" $Refetch
    Save-State $state
    Write-Host "  orchestrator : fetch + checkout $Refetch"
    & git -C $RepoDir fetch --quiet origin
    if ($LASTEXITCODE -ne 0) { throw "orchestrator fetch failed" }
    & git -C $RepoDir checkout --quiet $Refetch
    if ($LASTEXITCODE -ne 0) { throw "orchestrator has no branch '$Refetch'" }
    & git -C $RepoDir pull --ff-only --quiet origin $Refetch
    if ($LASTEXITCODE -ne 0) { throw "orchestrator pull --ff-only failed (diverged/local changes in repos\orchestrator)" }
    Invoke-OrchBuild
    # SQLite migrations run automatically when the API boots below.
}

# ------------------------------------------------------------------ start

$oldPids = Read-Pids
if ($null -ne $oldPids) {
    $alive = @($oldPids.PSObject.Properties | Where-Object { Test-SvcAlive $_.Value })
    if ($alive.Count -gt 0) {
        Write-Host "Orchestrator already running ($(($alive | ForEach-Object { $_.Name }) -join ', ')). Use -Down first, or -Status." -ForegroundColor Yellow
        return
    }
}

Write-Host "== orchestrator up ==" -ForegroundColor Cyan

if (-not (Test-HttpOk "$WisperUrl/healthz")) {
    Write-Warning "wisper-api is not reachable at $WisperUrl - orchestrator will boot, but dispatches will fail until .\wisper.ps1 (and .\host.ps1) are up"
}

$distEntry = Join-Path $RepoDir "dist\index.js"
if (-not (Test-Path $distEntry)) { throw "dist\index.js missing - run .\orchestrator.ps1 -Init $($state.orchBranch)" }

$pids = @{}
$node = (Get-Command node).Source
$pids.orchestrator = Start-Svc -Name "orchestrator" -File $node -Arguments @($distEntry) -Cwd $RepoDir -Env @{
    PORT            = "$OrchPort"
    ORCH_DB_PATH    = (Join-Path $Dirs.State "orchestrator.sqlite")
    WISPER_MODE     = "v1"
    WISPER_BASE_URL = $WisperUrl
    WISPER_HOST_ID  = "local-host"
    WISPER_CREATE_LEASE_TIMEOUT_MS = "$CreateLeaseTimeoutMs"
}
Save-Pids $pids   # save after every start so -Down can clean up a failed run
Wait-Http -Url "$OrchUrl/api/health" -TimeoutSec 60 -Name "orchestrator"

# Seed/refresh the wisper API key into the orchestrator secret store on every
# start, so it always matches the stack's key. The value is never logged; the
# orchestrator stores it encrypted (keychain-backed) in %APPDATA%\orchestrator.
try {
    Invoke-WebRequest -Uri "$OrchUrl/api/secrets" -Method Put -UseBasicParsing -TimeoutSec 15 `
        -ContentType "application/json" `
        -Body (@{ key = "WISPER_API_KEY"; value = $state.wckKey } | ConvertTo-Json) | Out-Null
    Write-Host "  seeded secret WISPER_API_KEY into the orchestrator secret store"
} catch {
    Write-Warning "could not seed WISPER_API_KEY ($($_.Exception.Message)) - set it in the orchestrator UI before dispatching"
}

$npm = (Get-Command npm.cmd).Source
$pids."orchestrator-web" = Start-Svc -Name "orchestrator-web" -File $npm `
    -Arguments @("run", "dev", "--", "--config", "vite.config.local.ts") `
    -Cwd (Join-Path $RepoDir "web")
Save-Pids $pids
# Dev servers may bind IPv6 ::1 - probe localhost, not 127.0.0.1.
Wait-Http -Url "http://localhost:$WebUiPort" -TimeoutSec 90 -Name "orchestrator-web"

Write-Host "`n== orchestrator is up ==" -ForegroundColor Green
Write-Host @"
orchestrator API   $OrchUrl   (branch $($state.orchBranch); db state\orchestrator.sqlite)
orchestrator web   http://localhost:$WebUiPort
wisper wiring      v1 mode -> $WisperUrl, host 'local-host', WISPER_API_KEY seeded

Full stack order:  .\wisper.ps1  ->  .\host.ps1  ->  .\orchestrator.ps1
Stop:   .\orchestrator.ps1 -Down       Update:  .\orchestrator.ps1 -Refetch <branch>
Status: .\orchestrator.ps1 -Status     Logs:    $($Dirs.Logs)
"@
