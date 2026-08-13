# host.ps1 - local wisper HOST stack: wisp (broker) + wisp-agent, wired to the
# wisper-api that wisper.ps1 runs on this same machine.
#
#   .\host.ps1 -Init <branch>                    cold start: clone + build wisp and
#                                                wisp-agent from <branch>, write config,
#                                                build the wisp-base docker image
#                                                (-Init grunt has all isolation support;
#                                                -AgentBranch <b> overrides the agent's
#                                                branch, e.g. wisp-agent-ui-grunt for
#                                                its embedded control panel)
#   .\host.ps1                                   start wisp + agent (manager must be up)
#   .\host.ps1 -Refetch <branch> [-AgentBranch <b>]   pull, rebuild, restart
#   .\host.ps1 -Down                             stop wisp + agent (postgres/api untouched)
#   .\host.ps1 -Status                           health + tunnel-online overview
#
# What it runs (loopback-only, no services):
#   wisp          http://127.0.0.1:3009   broker; needs Docker running to lease
#   wisp-agent    dials ws://127.0.0.1:3006/agent; control panel http://localhost:4600
#
# Shares this folder with wisper.ps1: repos\ (adds wisp, wisp-agent), logs\, and
# state\stack-state.json (wck_ API key, plus host-side entries). Uses its own
# pid file (state\host-pids.json) so the two scripts never fight.
#
# First start auto-registers host "local-host" against wisper-api (its one-time
# wht_ agent token lands in the state file) and seeds "hostImages" in the state
# file with one zero-priced image so leases cost $0 with no Stripe.
#
# WHAT THE HOST ADVERTISES is the "hostImages" array in state\stack-state.json:
#   { image_ref, price_cents_per_min, networks, max_ttl_seconds, enabled }
# Edit it and re-run .\host.ps1 - a changed list is re-published to the manager
# on start (PUT /v1/hosts/{id}/images). Each image_ref must also be in the
# images.allow list of config\wisp.config.json AND exist in the local docker
# daemon (wisp never pulls images).
#
# If you ever wipe pgdata\, delete the "host" and "hostImagesPublished" entries
# from state\stack-state.json so the host re-registers and re-publishes.

[CmdletBinding()]
param(
    [string]$Init = "",         # branch for a cold start (also refetches if installed)
    [string]$Refetch = "",      # branch: pull wisp + wisp-agent, rebuild, restart
    [string]$AgentBranch = "",  # wisp-agent branch override (default: same as -Init/-Refetch)
    [switch]$Down,
    [switch]$Status,
    [int]$WispPort = 3009,
    [int]$ApiPort = 3006,
    # How long the agent waits for wisp's create-contract call (Go duration,
    # e.g. "50m"). Lease creation is SYNCHRONOUS through the container's entire
    # userdata provision (fx-sandbox-base builds ~6 min, worst case much
    # longer); the agent's built-in default is a fatal 60s. Must match the
    # manager/orchestrator ceilings - see LEASE-TIMEOUTS-RUNBOOK.md.
    [string]$CreateTimeout = "50m"
)

$ErrorActionPreference = "Stop"

# $PSScriptRoot is empty in param defaults under `powershell -File` - resolve here.
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$Dirs = @{
    Repos  = Join-Path $Root "repos"
    Logs   = Join-Path $Root "logs"
    State  = Join-Path $Root "state"
    Config = Join-Path $Root "config"
}
$StateFile = Join-Path $Dirs.State "stack-state.json"
$PidsFile  = Join-Path $Dirs.State "host-pids.json"
$GitHubUser = "benjaminfkile"
$ApiUrl  = "http://127.0.0.1:$ApiPort"
$WispUrl = "http://127.0.0.1:$WispPort"

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
function Stop-HostStack {
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
function Invoke-WisperApi {
    param([string]$Method, [string]$Path, $Body = $null, [string]$ApiKey)
    $params = @{
        Method          = $Method
        Uri             = "$ApiUrl$Path"
        Headers         = @{ Authorization = "Bearer $ApiKey" }
        UseBasicParsing = $true
        TimeoutSec      = 30
    }
    if ($null -ne $Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = "application/json"
    }
    (Invoke-WebRequest @params).Content | ConvertFrom-Json
}
function Get-Sha256Hex([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) | ForEach-Object { $_.ToString("x2") }) -join ""
    } finally { $sha.Dispose() }
}
function Get-DockerOsType {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return "" }
    Invoke-Capture "docker" @("info", "--format", "{{.OSType}}")
}
function Invoke-HostBuilds {
    Write-Host "-- building" -ForegroundColor Cyan
    foreach ($r in @("wisp", "wisp-agent")) {
        Write-Host "  $r (go build)"
        Push-Location (Join-Path $Dirs.Repos $r)
        # go run is blocked by App Control on this machine - always build to an exe.
        if ($r -eq "wisp") { & go build -o wispd.exe .\cmd\wispd }
        else { & go build -o wisp-agent.exe .\cmd\wisp-agent }
        if ($LASTEXITCODE -ne 0) { Pop-Location; throw "$r build failed" }
        Pop-Location
    }
}

# ------------------------------------------------------------------ -Down / -Status

if ($Down) {
    Write-Host "== host down ==" -ForegroundColor Cyan
    Stop-HostStack
    Write-Host "== host stopped (manager stack untouched) ==" -ForegroundColor Green
    return
}

if ($Status) {
    Write-Host "== host status ==" -ForegroundColor Cyan
    $st = Get-State
    $pids = Read-Pids
    foreach ($svc in @("wisp", "wisp-agent")) {
        $entry = $null
        if ($null -ne $pids) { $entry = $pids.PSObject.Properties[$svc].Value }
        $alive = Test-SvcAlive $entry
        $health = "-"
        if ($alive -and $svc -eq "wisp") { $health = @("unhealthy", "healthy")[[int](Test-HttpOk "$WispUrl/healthz")] }
        if ($alive -and $svc -eq "wisp-agent") { $health = "see tunnel below" }
        Write-Host ("  {0,-11} {1}  {2}" -f $svc, @("STOPPED", "running")[[int]$alive], $health)
    }
    if ($null -ne $st -and $null -ne $st.host -and (Test-HttpOk "$ApiUrl/healthz")) {
        try {
            $mine = Invoke-WisperApi -Method GET -Path "/v1/hosts/mine" -ApiKey $st.wckKey
            $h = $mine.data | Where-Object { $_.id -eq $st.host.id } | Select-Object -First 1
            if ($null -ne $h) { Write-Host ("  tunnel      host '{0}' online={1}" -f $st.host.name, $h.online) }
            else { Write-Host "  tunnel      host $($st.host.id) not found on manager (DB reset? clear 'host' in state)" }
        } catch { Write-Host "  tunnel      could not query manager: $($_.Exception.Message)" }
    } else {
        Write-Host "  tunnel      manager not reachable at $ApiUrl or host not registered yet"
    }
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
if ($null -eq $state.wispAppToken) { Set-StateProp $state "wispAppToken" (New-RandomHex 24); Save-State $state }

# ------------------------------------------------------------------ install / refetch

$HostRepos = @("wisp", "wisp-agent")
$needClone = @($HostRepos | Where-Object { -not (Test-Path (Join-Path (Join-Path $Dirs.Repos $_) ".git")) })

if ($Init) {
    if ($needClone.Count -eq 0) {
        Write-Host "Host repos already cloned - treating -Init '$Init' as -Refetch '$Init'." -ForegroundColor Yellow
        $Refetch = $Init
    } else {
        Set-StateProp $state "hostBranch" $Init
        if ($AgentBranch) { Set-StateProp $state "agentBranch" $AgentBranch }
        else { Set-StateProp $state "agentBranch" $Init }
        Save-State $state
    }
}
if ($needClone.Count -gt 0 -and $null -eq $state.hostBranch) {
    throw "Host not installed yet - cold start with: .\host.ps1 -Init <branch> [-AgentBranch <branch>]"
}

function Get-RepoBranch([string]$Repo) {
    if ($Repo -eq "wisp-agent" -and $null -ne $state.agentBranch) { return $state.agentBranch }
    return $state.hostBranch
}

if ($needClone.Count -gt 0) {
    Write-Host "== host install ==" -ForegroundColor Cyan
    foreach ($tool in @("git", "go")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Missing required tool: $tool" }
    }
    foreach ($r in $needClone) {
        $b = Get-RepoBranch $r
        Write-Host "  cloning $r (branch $b)"
        & git clone --quiet --branch $b "https://github.com/$GitHubUser/$r.git" (Join-Path $Dirs.Repos $r)
        if ($LASTEXITCODE -ne 0) { throw "clone of $r failed (branch '$b' missing?)" }
    }
    Invoke-HostBuilds

    # wisp config: image allow-list + limits. No BOM - Go's JSON decoder is strict.
    # Seeded ONCE; wisp reads it via WISP_CONFIG and this block never overwrites an
    # existing file, so YOUR limits survive -Down/up. To change them, edit limits.*
    # in config\wisp.config.json and re-run host.ps1 (0 = unlimited). Two kinds of cap:
    #   max_cpus / max_memory_mb     = PER-LEASE ceiling (one lease's max). These are
    #       what wisp advertises to the manager; the image editor bounds vCPU/RAM by
    #       them, and 0 here is exactly what makes it warn "not reporting per-lease
    #       capacity".
    #   total_cpus / total_memory_mb = AGGREGATE budget across ALL concurrent leases.
    # Defaults below are HALF of whatever machine this runs on (auto-detected - no
    # machine-specific numbers hardcoded); total must be >= max (wisp validates this).
    $wispConfig = Join-Path $Dirs.Config "wisp.config.json"
    if (-not (Test-Path $wispConfig)) {
        $cs = Get-CimInstance Win32_ComputerSystem
        $capCpus  = [int][math]::Max(1,   [math]::Floor($cs.NumberOfLogicalProcessors / 2))
        $capMemMB = [int][math]::Max(512, [math]::Floor(($cs.TotalPhysicalMemory / 1MB) / 2))
        [System.IO.File]::WriteAllText($wispConfig, @"
{
  "images": {
    "allow": ["wisp-base", "wisp-base-windows"],
    "default": "wisp-base"
  },
  "limits": {
    "max_ttl_seconds": 0,
    "max_cpus": $capCpus,
    "max_memory_mb": $capMemMB,
    "pids_limit": 0,
    "total_cpus": $capCpus,
    "total_memory_mb": $capMemMB,
    "networks": ["none", "open"],
    "isolations": ["shared"]
  }
}
"@)
        Write-Host "  wrote config\wisp.config.json (per-lease + aggregate caps = half this machine: $capCpus cpus / $capMemMB MB - edit limits.* + re-run to change)"
    }

    # Base image: wisp never pulls images, so the local daemon needs one built.
    $osType = Get-DockerOsType
    if ($osType -eq "linux") {
        Write-Host "  building docker image wisp-base (linux daemon mode)"
        & docker build -t wisp-base (Join-Path $Dirs.Repos "wisp\examples\wisp-base")
        if ($LASTEXITCODE -ne 0) { Write-Warning "wisp-base build failed - build it manually before leasing" }
    } elseif ($osType -eq "windows") {
        Write-Host "  building docker image wisp-base-windows (windows daemon mode)"
        & docker build -t wisp-base-windows (Join-Path $Dirs.Repos "wisp\examples\wisp-base-windows")
        if ($LASTEXITCODE -ne 0) { Write-Warning "wisp-base-windows build failed - build it manually before leasing" }
    } else {
        Write-Warning "docker daemon unreachable - skipping base image build (wisp can't lease until it exists)"
    }
    Write-Host "== host install done ==" -ForegroundColor Green
}

if ($Refetch) {
    Write-Host "== host refetch '$Refetch' ==" -ForegroundColor Cyan
    Stop-HostStack
    Set-StateProp $state "hostBranch" $Refetch
    if ($AgentBranch) { Set-StateProp $state "agentBranch" $AgentBranch }
    else { Set-StateProp $state "agentBranch" $Refetch }
    Save-State $state
    foreach ($r in $HostRepos) {
        $b = Get-RepoBranch $r
        $dest = Join-Path $Dirs.Repos $r
        Write-Host "  $r : fetch + checkout $b"
        & git -C $dest fetch --quiet origin
        if ($LASTEXITCODE -ne 0) { throw "$r fetch failed" }
        & git -C $dest checkout --quiet $b
        if ($LASTEXITCODE -ne 0) { throw "$r has no branch '$b'" }
        & git -C $dest pull --ff-only --quiet origin $b
        if ($LASTEXITCODE -ne 0) { throw "$r pull --ff-only failed (diverged/local changes in repos\$r)" }
    }
    Invoke-HostBuilds
}

# ------------------------------------------------------------------ start

$oldPids = Read-Pids
if ($null -ne $oldPids) {
    $alive = @($oldPids.PSObject.Properties | Where-Object { Test-SvcAlive $_.Value })
    if ($alive.Count -gt 0) {
        Write-Host "Host already running ($(($alive | ForEach-Object { $_.Name }) -join ', ')). Use -Down first, or -Status." -ForegroundColor Yellow
        return
    }
}

Write-Host "== host up ==" -ForegroundColor Cyan

if (-not (Test-HttpOk "$ApiUrl/healthz")) {
    throw "wisper-api is not reachable at $ApiUrl - start the manager first: .\wisper.ps1"
}
$osType = Get-DockerOsType
if (-not $osType) { Write-Warning "docker daemon unreachable - wisp will start but leases will fail" }

$pids = @{}

$wispExe = Join-Path $Dirs.Repos "wisp\wispd.exe"
if (-not (Test-Path $wispExe)) { throw "wispd.exe missing - run .\host.ps1 -Init <branch>" }
$pids.wisp = Start-Svc -Name "wisp" -File $wispExe -Cwd (Split-Path $wispExe) -Env @{
    WISP_ADDR      = "127.0.0.1:$WispPort"
    WISP_CONFIG    = (Join-Path $Dirs.Config "wisp.config.json")
    WISP_APP_TOKEN = $state.wispAppToken
}
Save-Pids $pids   # save after every start so -Down can clean up a failed run
Wait-Http -Url "$WispUrl/healthz" -TimeoutSec 30 -Name "wisp"

# One-time host registration (the wht_ agent token is shown once by the API -
# captured straight into the state file).
if ($null -eq $state.host) {
    Write-Host "  bootstrap: registering host 'local-host'" -ForegroundColor Yellow
    $reg = Invoke-WisperApi -Method POST -Path "/v1/hosts" -ApiKey $state.wckKey -Body @{ name = "local-host" }
    Set-StateProp $state "host" ([pscustomobject]@{
        id         = $reg.id
        name       = "local-host"
        agentToken = $reg.agent_token
    })
    Save-State $state
    Write-Host "  bootstrap: host $($reg.id) registered; agent token captured into state"
}

$agentExe = Join-Path $Dirs.Repos "wisp-agent\wisp-agent.exe"
if (-not (Test-Path $agentExe)) { throw "wisp-agent.exe missing - run .\host.ps1 -Init <branch>" }
# The agent derives the ws tunnel URL from the manager URL (http->ws, path
# normalized to /agent), so pass our known-local manager explicitly rather than
# trusting anything stale in state.
$pids."wisp-agent" = Start-Svc -Name "wisp-agent" -File $agentExe -Cwd (Split-Path $agentExe) -Arguments @(
    "--manager", "ws://127.0.0.1:$ApiPort/agent",
    "--host-token", $state.host.agentToken,
    "--wisp", $WispUrl,
    "--wisp-token", $state.wispAppToken,
    "--wisp-create-timeout", $CreateTimeout
)
Save-Pids $pids

# Wait for the tunnel: image pricing 409s host_offline until the host is online.
Write-Host "  waiting for the host tunnel to come online"
$online = $false
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    try {
        $mine = Invoke-WisperApi -Method GET -Path "/v1/hosts/mine" -ApiKey $state.wckKey
        $h = $mine.data | Where-Object { $_.id -eq $state.host.id } | Select-Object -First 1
        if ($null -ne $h -and $h.online) { $online = $true; break }
    } catch { }
    Start-Sleep -Milliseconds 1500
}
if (-not $online) {
    throw "host tunnel did not come online within 60s - see logs\wisp-agent.*.log (stale agent token after a DB reset? delete 'host' from state\stack-state.json and re-run)"
}

# The advertised images come from "hostImages" in the state file. Seeded once
# with a zero-priced default matching the docker daemon mode; edit the array
# freely - a changed list is re-published on the next start. (Publishing must
# happen while the tunnel is online or the API 409s host_offline.)
if ($null -eq $state.hostImages) {
    $imageRef = "wisp-base"
    if ($osType -eq "windows") { $imageRef = "wisp-base-windows" }
    Set-StateProp $state "hostImages" @(
        [pscustomobject]@{
            image_ref           = $imageRef
            # ~$20/hr. price is integer cents-PER-MINUTE, so $20/hr (=33.33c/min)
            # isn't exact; 33 = $19.80/hr (closest under). Edit here or in
            # state\stack-state.json + re-run host.ps1 to change what's advertised.
            price_cents_per_min = 33
            networks            = @("none", "open")
            max_ttl_seconds     = 3600
            enabled             = $true
        }
    )
    Save-State $state
    Write-Host "  seeded default image list in state\stack-state.json (hostImages) - edit it to change what's advertised"
}
$images = @($state.hostImages)
$imagesHash = Get-Sha256Hex (ConvertTo-Json -InputObject $images -Depth 5 -Compress)
if ($state.hostImagesPublished -ne $imagesHash) {
    Write-Host "  publishing image list ($($images.Count) image(s)) to the manager" -ForegroundColor Yellow
    Invoke-WisperApi -Method PUT -Path "/v1/hosts/$($state.host.id)/images" -ApiKey $state.wckKey -Body @{ images = $images } | Out-Null
    Set-StateProp $state "hostImagesPublished" $imagesHash
    Save-State $state
    Write-Host "  images published (remember: each image_ref must be in config\wisp.config.json allow + exist in docker)"
} else {
    Write-Host "  image list unchanged - not re-publishing"
}

Write-Host "`n== host is up ==" -ForegroundColor Green
Write-Host @"
wisp            $WispUrl   (branch $($state.hostBranch))
wisp-agent      tunneled to ws://127.0.0.1:$ApiPort/agent  (branch $($state.agentBranch))
agent panel     http://localhost:4600  (only on branches with the control panel, e.g. wisp-agent-ui-grunt)
docker mode     $osType

Host 'local-host' should show online in wisper-web Host tools.
Stop:   .\host.ps1 -Down       Update:  .\host.ps1 -Refetch <branch> [-AgentBranch <b>]
Status: .\host.ps1 -Status     Logs:    $($Dirs.Logs)
"@
