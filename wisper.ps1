# wisper.ps1 - one-command local wisper MANAGER stack (no host components).
#
#   .\wisper.ps1 -Init <branch>        cold start: install everything from <branch>
#   .\wisper.ps1                       start the stack (after it has been installed)
#   .\wisper.ps1 -Refetch <branch>     pull <branch> in all repos, rebuild, restart
#                                      (-Init on an installed stack does the same)
#   .\wisper.ps1 -Down                 stop everything (services + postgres)
#   .\wisper.ps1 -Status               health overview
#
# What it runs (all loopback-only, no Windows services, no firewall changes):
#   postgres      127.0.0.1:3005   portable EDB binaries in pgsql\, cluster in pgdata\
#   wisper-api    http://127.0.0.1:3006    (DbUp migrations run automatically at boot)
#   wisper-web    http://127.0.0.1:3007
#   wisper-admin  http://127.0.0.1:3008
#
# Everything lives inside this folder: repos\ pgsql\ pgdata\ downloads\ state\ logs\.
# Uninstall = .\wisper.ps1 -Down, then delete the folder. The system PostgreSQL
# service (5432) is never touched.
#
# Secrets: state\stack-state.json holds generated passwords + the wck_ API key
# (plaintext; OS user boundary is the security model). The repos are public, so
# git needs no authentication.
#
# Host-side pieces (wisp, wisp-agent) are deliberately NOT here - point a host's
# wisp-agent at http://<this-machine>:8090 only if you also rebind/expose the API.

[CmdletBinding()]
param(
    [string]$Init = "",         # branch name for a cold start: install + build from it
                                # (on an already-installed stack, same as -Refetch)
    [string]$Refetch = "",      # branch name: pull all repos on it, rebuild, restart
    [switch]$Down,
    [switch]$Status,
    [int]$PgPort = 3005,
    [int]$ApiPort = 3006,
    [int]$WebPort = 3007,
    [int]$AdminPort = 3008,
    [string]$PgVersion = "17.5-3",
    # Tunnel relay deadline (ms) for a single host request, incl. lease.create.
    # Lease creation is SYNCHRONOUS through the container's entire userdata
    # provision (fx-sandbox-base builds ~6 min, worst case much longer), so this
    # must exceed the longest provision. Default 50 min; wisper-api's built-in
    # default is a fatal 120s. See LEASE-TIMEOUTS-RUNBOOK.md.
    [int]$RelayTimeoutMs = 3000000
)

$ErrorActionPreference = "Stop"

# $PSScriptRoot is empty in param defaults under `powershell -File` - resolve here.
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$Dirs = @{
    Repos     = Join-Path $Root "repos"
    Pgsql     = Join-Path $Root "pgsql"
    PgData    = Join-Path $Root "pgdata"
    Downloads = Join-Path $Root "downloads"
    Logs      = Join-Path $Root "logs"
    State     = Join-Path $Root "state"
}
$StateFile = Join-Path $Dirs.State "stack-state.json"
$PidsFile  = Join-Path $Dirs.State "pids.json"
$Repos     = @("wisper-api", "wisper-web", "wisper-admin")
$GitHubUser = "benjaminfkile"
$ApiUrl    = "http://127.0.0.1:$ApiPort"

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
function New-RandomHex([int]$Bytes) {
    $buf = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
    ($buf | ForEach-Object { $_.ToString("x2") }) -join ""
}

# Run a native command silently, return exit code. Drops ErrorActionPreference so
# PS 5.1 doesn't promote redirected native stderr into terminating errors.
function Invoke-Quiet([string]$File, [string[]]$Arguments = @()) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & $File @Arguments 2>&1 | Out-Null; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $eap }
}
function Invoke-Capture([string]$File, [string[]]$Arguments = @()) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = & $File @Arguments 2>$null; return ([string](@($out) -join "`n")).Trim() }
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

# Launch a background service, stdout/stderr to logs\<name>.*.log. Runs under a
# HIDDEN cmd.exe wrapper: Start-Process's own redirect params force a visible
# console per service (closing it kills the service); cmd does the redirection
# and -WindowStyle Hidden hides the console. taskkill /T on the cmd PID still
# kills the whole tree. Env vars are set on this process (inherited) then restored.
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
        # Record the process name so a recycled PID after a reboot is not
        # mistaken for a still-running service.
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

function Get-PgBin([string]$Exe) { Join-Path (Join-Path $Dirs.Pgsql "bin") $Exe }
function Test-PgRunning {
    $pgCtl = Get-PgBin "pg_ctl.exe"
    if (-not (Test-Path $pgCtl)) { return $false }
    (Invoke-Quiet $pgCtl @("status", "-D", $Dirs.PgData)) -eq 0
}
# Never pipe pg_ctl's output: the postgres daemon inherits the pipe handle and
# the caller blocks forever. Launch detached and poll pg_isready.
function Start-Postgres([int]$TimeoutSec = 30) {
    if (Test-PgRunning) { return }
    Start-Process -FilePath (Get-PgBin "pg_ctl.exe") -WindowStyle Hidden -ArgumentList @(
        "start", "-D", (Format-Arg $Dirs.PgData), "-l", (Format-Arg (Join-Path $Dirs.Logs "postgres.log"))
    ) | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Invoke-Quiet (Get-PgBin "pg_isready.exe") @("-h", "127.0.0.1", "-p", "$PgPort")) -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "postgres did not accept connections on port $PgPort within ${TimeoutSec}s (see logs\postgres.log)"
}
function Stop-Postgres {
    if (Test-PgRunning) {
        Write-Host "  stopping postgres"
        & (Get-PgBin "pg_ctl.exe") -D $Dirs.PgData -m fast -w stop | Out-Null
    }
}

function Stop-Stack {
    $pids = Read-Pids
    if ($null -ne $pids) {
        foreach ($p in $pids.PSObject.Properties) {
            if (Test-SvcAlive $p.Value) {
                Write-Host "  stopping $($p.Name) (pid $($p.Value.pid))"
                # /T kills the tree - required for npm.cmd -> node children.
                Invoke-Quiet "taskkill" @("/PID", "$($p.Value.pid)", "/T", "/F") | Out-Null
            }
        }
        Remove-Item $PidsFile -Force -ErrorAction SilentlyContinue
    }
    Stop-Postgres
}

function Invoke-Builds {
    Write-Host "-- building" -ForegroundColor Cyan
    Write-Host "  wisper-api (dotnet build -c Release)"
    Push-Location (Join-Path $Dirs.Repos "wisper-api")
    & dotnet build -c Release src\Wisper.Api --nologo -v q
    if ($LASTEXITCODE -ne 0) { Pop-Location; throw "wisper-api build failed" }
    Pop-Location
    foreach ($fe in @("wisper-web", "wisper-admin")) {
        Write-Host "  $fe (npm ci)"
        Push-Location (Join-Path $Dirs.Repos $fe)
        & npm ci --no-audit --no-fund --loglevel error
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  npm ci failed for $fe - trying npm install"
            & npm install --no-audit --no-fund --loglevel error
            if ($LASTEXITCODE -ne 0) { Pop-Location; throw "$fe npm install failed" }
        }
        Pop-Location
    }
}

# ------------------------------------------------------------------ -Down / -Status

if ($Down) {
    Write-Host "== wisper down ==" -ForegroundColor Cyan
    Stop-Stack
    Write-Host "== stopped ==" -ForegroundColor Green
    return
}

if ($Status) {
    Write-Host "== wisper status ==" -ForegroundColor Cyan
    $st = Get-State
    if ($null -eq $st) { Write-Host "  not installed (no state file) - run .\wisper.ps1 -Init <branch>"; return }
    if ($null -ne $st.pgPort) { $PgPort = [int]$st.pgPort }
    $pg = Test-PgRunning
    Write-Host ("  postgres      {0}  (127.0.0.1:{1})" -f @("STOPPED", "running")[[int]$pg], $PgPort)
    $pids = Read-Pids
    foreach ($svc in @("wisper-api", "wisper-web", "wisper-admin")) {
        $entry = $null
        if ($null -ne $pids) { $entry = $pids.PSObject.Properties[$svc].Value }
        $alive = Test-SvcAlive $entry
        $url = switch ($svc) {
            "wisper-api"   { "$ApiUrl/healthz" }
            "wisper-web"   { "http://localhost:$WebPort" }
            "wisper-admin" { "http://localhost:$AdminPort" }
        }
        $health = "-"
        if ($alive) { $health = @("unhealthy", "healthy")[[int](Test-HttpOk $url)] }
        Write-Host ("  {0,-13} {1}  {2}" -f $svc, @("STOPPED", "running")[[int]$alive], $health)
    }
    Write-Host "  API key: $($st.wckKey)"
    return
}

# ------------------------------------------------------------------ state + PAT

foreach ($d in $Dirs.Values) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$state = Get-State
if ($null -eq $state) { $state = [pscustomobject]@{} }

if ($null -eq $state.pgSuperPassword)  { Set-StateProp $state "pgSuperPassword"  (New-RandomHex 18) }
if ($null -eq $state.pgWisperPassword) { Set-StateProp $state "pgWisperPassword" (New-RandomHex 18) }
if ($null -eq $state.wckKey)    { Set-StateProp $state "wckKey" ("wck_live_" + (New-RandomHex 32)) }
if ($null -eq $state.wckUserId) { Set-StateProp $state "wckUserId" ([guid]::NewGuid().ToString()) }
if ($null -eq $state.wckEmail)  { Set-StateProp $state "wckEmail" "admin@local.dev" }
# The cluster's port is written into pgdata\postgresql.conf at initdb, so the
# stored value wins on later runs - a changed -PgPort can't silently mismatch it.
if ($null -eq $state.pgPort) {
    Set-StateProp $state "pgPort" $PgPort
} elseif ($PgPort -ne [int]$state.pgPort) {
    if ($PSBoundParameters.ContainsKey("PgPort")) {
        Write-Warning "cluster was initialized on port $($state.pgPort) - using that (to move it, edit pgdata\postgresql.conf AND state\stack-state.json)"
    }
    $PgPort = [int]$state.pgPort
}
Save-State $state

# ------------------------------------------------------------------ first-run install

$needClone = @($Repos | Where-Object { -not (Test-Path (Join-Path (Join-Path $Dirs.Repos $_) ".git")) })
$needPg    = -not (Test-Path (Join-Path $Dirs.PgData "PG_VERSION"))
$firstRun  = ($needClone.Count -gt 0) -or $needPg

# -Init <branch>: pick the branch for a cold start; on an installed stack it is
# just a refetch of that branch.
if ($Init) {
    if ($needClone.Count -eq 0) {
        Write-Host "Repos already cloned - treating -Init '$Init' as -Refetch '$Init'." -ForegroundColor Yellow
        $Refetch = $Init
    } else {
        Set-StateProp $state "branch" $Init
        Save-State $state
    }
}
if ($needClone.Count -gt 0 -and $null -eq $state.branch) {
    throw "Not installed yet - cold start with: .\wisper.ps1 -Init <branch>"
}

if ($firstRun) {
    Write-Host "== wisper install (first run) ==" -ForegroundColor Cyan

    $missing = @()
    foreach ($tool in @("git", "node", "npm", "dotnet")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $missing += $tool }
    }
    if ($missing.Count -gt 0) { throw "Missing required tools: $($missing -join ', ')" }
    $sdks = Invoke-Capture "dotnet" @("--list-sdks")
    if ($sdks -notmatch "(^|`n)8\.") { throw ".NET 8 SDK not found (wisper-api targets net8.0)" }

    foreach ($r in $needClone) {
        Write-Host "  cloning $r (branch $($state.branch))"
        & git clone --quiet --branch $state.branch "https://github.com/$GitHubUser/$r.git" (Join-Path $Dirs.Repos $r)
        if ($LASTEXITCODE -ne 0) { throw "clone of $r failed (branch '$($state.branch)' missing?)" }
    }

    if ($needClone.Count -gt 0) { Invoke-Builds }

    # ---- portable PostgreSQL: binaries, cluster, role, database
    if (-not (Test-Path (Get-PgBin "pg_ctl.exe"))) {
        $zip = Join-Path $Dirs.Downloads "postgresql-$PgVersion-windows-x64-binaries.zip"
        if (-not (Test-Path $zip)) {
            Write-Host "  downloading portable PostgreSQL $PgVersion (~350 MB)..."
            $ProgressPreference = "SilentlyContinue"
            Invoke-WebRequest -Uri "https://get.enterprisedb.com/postgresql/postgresql-$PgVersion-windows-x64-binaries.zip" -OutFile $zip -UseBasicParsing
        }
        Write-Host "  extracting (zip root is pgsql\)..."
        Expand-Archive -Path $zip -DestinationPath $Root -Force
        if (-not (Test-Path (Get-PgBin "pg_ctl.exe"))) { throw "extract did not produce pgsql\bin\pg_ctl.exe" }
    }
    if ($needPg) {
        Write-Host "  initdb new cluster in pgdata\ (port $PgPort)"
        $pwFile = Join-Path $Dirs.State "pg-super.pw.tmp"
        [System.IO.File]::WriteAllText($pwFile, $state.pgSuperPassword)
        try {
            & (Get-PgBin "initdb.exe") -D $Dirs.PgData -U postgres -A scram-sha-256 --pwfile $pwFile -E UTF8 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "initdb failed" }
        } finally {
            Remove-Item $pwFile -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path (Join-Path $Dirs.PgData "postgresql.conf") -Encoding ascii -Value @(
            "", "# wisper-local overrides", "port = $PgPort", "listen_addresses = '127.0.0.1'"
        )
    }
    Start-Postgres
    try {
        $env:PGPASSWORD = $state.pgSuperPassword
        $psql = Get-PgBin "psql.exe"
        $pgArgs = @("-h", "127.0.0.1", "-p", "$PgPort", "-U", "postgres", "-d", "postgres")
        if ((Invoke-Capture $psql ($pgArgs + @("-tAc", "SELECT 1 FROM pg_roles WHERE rolname='wisper'"))) -ne "1") {
            Write-Host "  creating role 'wisper'"
            & $psql @pgArgs -c "CREATE ROLE wisper LOGIN PASSWORD '$($state.pgWisperPassword)'" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "CREATE ROLE wisper failed" }
        }
        if ((Invoke-Capture $psql ($pgArgs + @("-tAc", "SELECT 1 FROM pg_database WHERE datname='wisper'"))) -ne "1") {
            Write-Host "  creating database 'wisper'"
            & $psql @pgArgs -c "CREATE DATABASE wisper OWNER wisper" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "CREATE DATABASE wisper failed" }
        }
    } finally {
        Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    }
    Write-Host "== install done ==" -ForegroundColor Green
}

# ------------------------------------------------------------------ -Refetch <branch>

if ($Refetch) {
    Write-Host "== refetch branch '$Refetch' ==" -ForegroundColor Cyan
    Stop-Stack
    foreach ($r in $Repos) {
        $dest = Join-Path $Dirs.Repos $r
        Write-Host "  $r : fetch + checkout $Refetch"
        & git -C $dest fetch --quiet origin
        if ($LASTEXITCODE -ne 0) { throw "$r fetch failed" }
        & git -C $dest checkout --quiet $Refetch
        if ($LASTEXITCODE -ne 0) { throw "$r has no branch '$Refetch'" }
        & git -C $dest pull --ff-only --quiet origin $Refetch
        if ($LASTEXITCODE -ne 0) { throw "$r pull --ff-only failed (diverged/local changes in repos\$r)" }
    }
    Set-StateProp $state "branch" $Refetch
    Save-State $state
    Invoke-Builds
    # fall through to start; wisper-api applies its DbUp migrations at boot
}

# ------------------------------------------------------------------ start

$oldPids = Read-Pids
if ($null -ne $oldPids) {
    $alive = @($oldPids.PSObject.Properties | Where-Object { Test-SvcAlive $_.Value })
    if ($alive.Count -gt 0) {
        Write-Host "Stack already running ($(($alive | ForEach-Object { $_.Name }) -join ', ')). Use -Down first, or -Status." -ForegroundColor Yellow
        return
    }
}

$pids = @{}
Write-Host "== wisper up ==" -ForegroundColor Cyan

if (Test-PgRunning) { Write-Host "  postgres already running (port $PgPort)" }
else { Write-Host "  starting postgres (port $PgPort)"; Start-Postgres }

$apiDll = Get-ChildItem (Join-Path $Dirs.Repos "wisper-api\src\Wisper.Api\bin\Release") -Recurse `
    -Filter "Wisper.Api.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $apiDll) { throw "Wisper.Api.dll not found - run .\wisper.ps1 -Refetch $($state.branch) to build" }
$k = $state.wckKey
# Development is required: the JWT-audience check fails closed outside it, and it
# gates the dev endpoints. Loopback-only, so leaving dev endpoints on is fine.
$pids."wisper-api" = Start-Svc -Name "wisper-api" -File "dotnet" `
    -Arguments @($apiDll.FullName, "--urls", "http://127.0.0.1:$ApiPort") `
    -Cwd $apiDll.DirectoryName -Env @{
        ASPNETCORE_ENVIRONMENT           = "Development"
        ConnectionStrings__Wisper        = "Host=127.0.0.1;Port=$PgPort;Database=wisper;Username=wisper;Password=$($state.pgWisperPassword)"
        Tunnel__EnableDevEndpoints       = "true"
        Tunnel__ManagerWebSocketUrl      = "ws://127.0.0.1:$ApiPort/agent"
        Tunnel__RelayRequestTimeoutMs    = "$RelayTimeoutMs"
        "Auth__ApiKeys__${k}__UserId"    = $state.wckUserId
        "Auth__ApiKeys__${k}__Email"     = $state.wckEmail
        "Auth__ApiKeys__${k}__Scopes__0" = "consumer"
        "Auth__ApiKeys__${k}__Scopes__1" = "host"
        "Auth__ApiKeys__${k}__Scopes__2" = "admin"
    }
Save-Pids $pids   # save after every start so -Down can clean up a failed run
# First boot after a refetch runs DbUp migrations - allow extra time.
Wait-Http -Url "$ApiUrl/healthz" -TimeoutSec 120 -Name "wisper-api"

# ---- Fund the dev wallet -------------------------------------------------------
# Seed the wck user's wallet with a huge balance so PRICED leases "just work"
# with no Stripe (see host.ps1 for the priced default image). Pure data seed via
# a balanced double-entry topup (credit user_wallet / debit platform_cash) that
# respects the ledger triggers - NO wisper-api code change. Idempotent (guarded
# by a ledger idempotency_key), so it funds once per database and self-heals
# after a pgdata wipe. Edit $FundCents to change the amount.
$FundCents = [long]100000000000   # $1,000,000,000.00
$seedFile = Join-Path $Dirs.State "fund-wallet.sql"
try {
    $seedSql = @'
DO $fund$
DECLARE
  v_user   uuid;
  v_wallet uuid;
  v_cash   uuid;
  v_txn    uuid;
BEGIN
  INSERT INTO users (cognito_sub, email, status)
    VALUES ('__SUB__', '__EMAIL__', 'active')
    ON CONFLICT (cognito_sub) DO NOTHING;
  SELECT id INTO v_user FROM users WHERE cognito_sub = '__SUB__';

  -- The host owner (this same wck user) must be Connect-enabled to advertise a
  -- PRICED image and go online (Domain/ConnectGate.ChargesRequireConnect). No
  -- Stripe locally, so flip it directly.
  UPDATE users SET connect_status = 'enabled' WHERE id = v_user AND connect_status <> 'enabled';

  -- Paid metering needs an active platform_policy row: MeteringService's fee
  -- split calls GetActiveOrThrowAsync, so with ZERO rows a priced lease's meter
  -- flush throws (free leases never hit it). Seed one 10% policy if none exists.
  INSERT INTO platform_policy (fee_bps)
    SELECT 1000 WHERE NOT EXISTS (SELECT 1 FROM platform_policy);

  INSERT INTO ledger_accounts (kind, owner_user_id, currency)
    VALUES ('user_wallet', v_user, 'usd')
    ON CONFLICT (kind, owner_user_id) DO NOTHING;
  SELECT id INTO v_wallet FROM ledger_accounts
    WHERE kind = 'user_wallet' AND owner_user_id = v_user;

  INSERT INTO ledger_accounts (kind, owner_user_id, currency)
    VALUES ('platform_cash', NULL, 'usd')
    ON CONFLICT DO NOTHING;
  SELECT id INTO v_cash FROM ledger_accounts
    WHERE kind = 'platform_cash' AND owner_user_id IS NULL;

  IF NOT EXISTS (SELECT 1 FROM ledger_transactions
                 WHERE idempotency_key = 'seed:local-bootstrap-fund') THEN
    INSERT INTO ledger_transactions (kind, idempotency_key, memo)
      VALUES ('topup', 'seed:local-bootstrap-fund', 'local bootstrap: fund dev wallet')
      RETURNING id INTO v_txn;
    INSERT INTO ledger_entries (transaction_id, account_id, credit_cents) VALUES (v_txn, v_wallet, __AMOUNT__);
    INSERT INTO ledger_entries (transaction_id, account_id, debit_cents)  VALUES (v_txn, v_cash,   __AMOUNT__);
  END IF;
END $fund$;
'@
    $seedSql = $seedSql.Replace('__SUB__', $state.wckUserId).Replace('__EMAIL__', $state.wckEmail).Replace('__AMOUNT__', "$FundCents")
    [System.IO.File]::WriteAllText($seedFile, $seedSql)
    $env:PGPASSWORD = $state.pgWisperPassword
    $pg = @("-h", "127.0.0.1", "-p", "$PgPort", "-U", "wisper", "-d", "wisper")
    & (Get-PgBin "psql.exe") @pg -v ON_ERROR_STOP=1 -q -f $seedFile | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $bal = Invoke-Capture (Get-PgBin "psql.exe") ($pg + @("-tAc", "SELECT a.balance_cents FROM ledger_accounts a JOIN users u ON u.id = a.owner_user_id WHERE a.kind='user_wallet' AND u.cognito_sub='$($state.wckUserId)'"))
        Write-Host "  funded dev wallet: $bal cents ($($state.wckEmail))" -ForegroundColor Green
    } else {
        Write-Warning "wallet funding seed failed - stack still usable but the wallet is unfunded (priced leases will 402). See logs."
    }
} finally {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    Remove-Item $seedFile -ErrorAction SilentlyContinue
}

$npm = (Get-Command npm.cmd).Source
$pids."wisper-web" = Start-Svc -Name "wisper-web" -File $npm `
    -Arguments @("run", "dev", "--", "-p", "$WebPort", "-H", "127.0.0.1") `
    -Cwd (Join-Path $Dirs.Repos "wisper-web") -Env @{ WISPER_API_URL = $ApiUrl; NEXT_PUBLIC_WISPER_API_ORIGIN = $ApiUrl }
Save-Pids $pids
$pids."wisper-admin" = Start-Svc -Name "wisper-admin" -File $npm `
    -Arguments @("run", "dev", "--", "-p", "$AdminPort", "-H", "127.0.0.1") `
    -Cwd (Join-Path $Dirs.Repos "wisper-admin") -Env @{ WISPER_API_URL = $ApiUrl; NEXT_PUBLIC_WISPER_API_ORIGIN = $ApiUrl }
Save-Pids $pids
# Dev servers may bind IPv6 ::1 - probe localhost, not 127.0.0.1.
Wait-Http -Url "http://localhost:$WebPort" -TimeoutSec 90 -Name "wisper-web"
Wait-Http -Url "http://localhost:$AdminPort" -TimeoutSec 90 -Name "wisper-admin"

Write-Host "`n== stack is up ==" -ForegroundColor Green
Write-Host @"
wisper-api      $ApiUrl        (branch $($state.branch))
wisper-web      http://localhost:$WebPort
wisper-admin    http://localhost:$AdminPort
postgres        127.0.0.1:$PgPort  (db/user wisper; folder-local, not a service)

Sign in to wisper-web / wisper-admin by pasting the API key:
  $($state.wckKey)

Stop:     .\wisper.ps1 -Down          Update:  .\wisper.ps1 -Refetch <branch>
Status:   .\wisper.ps1 -Status        Logs:    $($Dirs.Logs)
"@
