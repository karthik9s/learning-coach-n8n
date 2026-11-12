<#
.SYNOPSIS
  Starts n8n behind a public HTTPS tunnel and verifies the Telegram webhook.

.DESCRIPTION
  Removes every manual step that caused "wrong address" errors:
    1. Validates the Telegram bot token.
    2. Starts the tunnel: a permanent ngrok domain if configured,
       otherwise a Cloudflare quick tunnel.
    3. Reads the real public URL from the tunnel itself (no copy/paste).
    4. Waits until that hostname resolves on public DNS, so Telegram
       never sees "Failed to resolve host".
    5. Starts n8n with WEBHOOK_URL set to that URL. Published workflows
       with a Telegram Trigger register the correct webhook on startup.
    6. Asks Telegram which webhook is registered and reports any mismatch.

.EXAMPLE
  .\start-n8n.ps1                                   # quick tunnel, new URL each run (handled automatically)
  .\start-n8n.ps1 -NgrokDomain my-bot.ngrok-free.app # permanent URL
  .\start-n8n.ps1 -Check                            # only verify the current webhook
  .\start-n8n.ps1 -Stop                             # stop tunnel + n8n started by this script
#>
param(
    [string]$NgrokDomain = $env:N8N_NGROK_DOMAIN,
    [int]$Port = 5678,
    [switch]$Check,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'
$stateDir  = Join-Path $env:LOCALAPPDATA 'n8n-launcher'
$stateFile = Join-Path $stateDir 'state.json'
$tunnelLog = Join-Path $stateDir 'tunnel.log'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "OK: $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "WARNING: $msg" -ForegroundColor Yellow }
function Fail($msg)       { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

function Get-State {
    if (Test-Path $stateFile) { return Get-Content $stateFile -Raw | ConvertFrom-Json }
    return $null
}

function Stop-Tree($procId) {
    # /T kills the whole tree (the PowerShell window AND the node.exe running n8n).
    # Run through cmd so taskkill's stderr ("process not found") never reaches PowerShell,
    # where $ErrorActionPreference = 'Stop' would turn it into a fatal error.
    if ($procId -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
        cmd.exe /c "taskkill /PID $procId /T /F >nul 2>&1"
    }
}

function Stop-Launched {
    $state = Get-State
    if (-not $state) { return }
    foreach ($procId in @($state.tunnelPid, $state.n8nPid)) { Stop-Tree $procId }
    Remove-Item $stateFile -Force
    Write-Ok 'Stopped previous tunnel and n8n.'
}

function Get-BotToken {
    $token = $env:TELEGRAM_BOT_TOKEN
    if (-not $token) { $token = [Environment]::GetEnvironmentVariable('TELEGRAM_BOT_TOKEN', 'User') }
    if ($token -notmatch '^\d+:[\w-]{30,}$') {
        Fail "TELEGRAM_BOT_TOKEN is missing or malformed (expected '<digits>:<secret>'). Set it once with:`n  [Environment]::SetEnvironmentVariable('TELEGRAM_BOT_TOKEN', '<full token>', 'User')"
    }
    return $token
}

function Test-Webhook([string]$tgApi, [string]$publicUrl) {
    $info = (Invoke-RestMethod "$tgApi/getWebhookInfo").result
    if (-not $info.url) {
        Write-Warn 'No webhook registered. No PUBLISHED workflow has a Telegram Trigger that uses this bot.'
        Write-Host  '  Fix: open the Telegram workflow in n8n, check its credential uses this bot token, click Publish, then run: .\start-n8n.ps1 -Check'
        return $false
    }
    if ($publicUrl -and -not $info.url.StartsWith("$publicUrl/")) {
        Write-Warn "Webhook points to the WRONG address:`n  $($info.url)`n  expected it to start with $publicUrl/"
        Write-Host  '  Fix: in n8n unpublish and re-publish the Telegram workflow, then run: .\start-n8n.ps1 -Check'
        return $false
    }
    if ($info.last_error_message) {
        $when = [DateTimeOffset]::FromUnixTimeSeconds($info.last_error_date).LocalDateTime
        Write-Warn "Telegram's last delivery error ($when): $($info.last_error_message)"
    }
    Write-Ok "Webhook: $($info.url)"
    Write-Host "    pending updates: $($info.pending_update_count)"
    return $true
}

function Test-Resolves([string]$name, [string]$server) {
    $q = @{ Name = $name; Type = 'A'; DnsOnly = $true; ErrorAction = 'Stop' }
    if ($server) { $q.Server = $server }
    try { return [bool](Resolve-DnsName @q | Where-Object Type -eq 'A') } catch { return $false }
}

function Wait-PublicDns([string]$name, [int]$seconds) {
    # Ask the zone's own nameserver first, and only then public resolvers. Asking public
    # resolvers too early makes them cache "does not exist", which is what Telegram then sees.
    $zone = ($name.Split('.') | Select-Object -Last 2) -join '.'
    $authNs = $null
    try { $authNs = (Resolve-DnsName $zone -Type NS -Server 1.1.1.1 -ErrorAction Stop | Where-Object Type -eq 'NS' | Select-Object -First 1).NameHost } catch {}
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $atSource = (-not $authNs) -or (Test-Resolves $name $authNs)
        if ($atSource -and ((Test-Resolves $name '1.1.1.1') -or (Test-Resolves $name '8.8.8.8') -or (Test-Resolves $name $null))) { return $true }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 5
    }
    return $false
}

function Start-QuickTunnel([string]$exe) {
    Remove-Item $tunnelLog -ErrorAction SilentlyContinue
    # --protocol http2: QUIC (UDP 7844) is blocked on many networks. Over QUIC the tunnel can
    # report "Registered" and still never get a DNS record.
    $proc = Start-Process $exe -ArgumentList "tunnel --no-autoupdate --protocol http2 --url http://localhost:$Port" `
        -RedirectStandardError $tunnelLog -WindowStyle Hidden -PassThru
    $url = $null
    $registered = $false
    $deadline = (Get-Date).AddSeconds(45)
    while (-not ($url -and $registered) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($proc.HasExited) { break }
        try {
            $text = Get-Content $tunnelLog -Raw
            $m = [regex]::Match($text, 'https://(?!api\.)[a-z0-9-]+\.trycloudflare\.com')
            if ($m.Success) { $url = $m.Value }
            $registered = $text -match 'Registered tunnel connection'
        } catch {}
    }
    return [pscustomobject]@{ Process = $proc; Url = $url; Ready = [bool]($url -and $registered) }
}

# --- Stop / Check modes ------------------------------------------------------
if ($Stop) { Stop-Launched; exit 0 }

$token = Get-BotToken
$tgApi = "https://api.telegram.org/bot$token"
try { $me = (Invoke-RestMethod "$tgApi/getMe").result }
catch { Fail "Telegram rejected the token: $($_.Exception.Message)" }
Write-Ok "Bot token valid: @$($me.username)"

if ($Check) {
    $state = Get-State
    $ok = Test-Webhook $tgApi $(if ($state) { $state.publicUrl } else { $null })
    exit $(if ($ok) { 0 } else { 1 })
}

# --- 1. Free the port --------------------------------------------------------
Stop-Launched
$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
    $name = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    Fail "Port $Port is already used by PID $($listener.OwningProcess) ($name) - probably an n8n you started by hand with the wrong WEBHOOK_URL. Press Ctrl+C in that window (or: Stop-Process -Id $($listener.OwningProcess)) and run this again."
}

# --- 2. Start the tunnel and learn its real URL ------------------------------
Remove-Item $tunnelLog -ErrorAction SilentlyContinue
$publicUrl = $null

if ($NgrokDomain) {
    $ngrok = Get-Command ngrok -ErrorAction SilentlyContinue
    if (-not $ngrok) { Fail 'ngrok not found. Install it with: winget install ngrok.ngrok' }
    Write-Step "Starting ngrok on permanent domain $NgrokDomain ..."
    $tunnel = Start-Process $ngrok.Source -ArgumentList "http --url=$NgrokDomain $Port --log=stdout" `
        -RedirectStandardOutput $tunnelLog -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(30)
    while (-not $publicUrl -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($tunnel.HasExited) { Fail "ngrok exited. See $tunnelLog" }
        try {
            $t = (Invoke-RestMethod 'http://127.0.0.1:4040/api/tunnels').tunnels | Where-Object { $_.public_url -like 'https://*' } | Select-Object -First 1
            if ($t) { $publicUrl = $t.public_url.TrimEnd('/') }
        } catch {}
    }
    if (-not $publicUrl) { Stop-Tree $tunnel.Id; Fail "ngrok gave no public URL. See $tunnelLog" }
} else {
    $cf = Get-Command cloudflared -ErrorAction SilentlyContinue
    if (-not $cf) {
        # Freshly installed: PATH of already-open windows doesn't include it yet
        $cf = @("${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe", "$env:ProgramFiles\cloudflared\cloudflared.exe") |
            Where-Object { Test-Path $_ } | Select-Object -First 1 | ForEach-Object { Get-Command $_ }
    }
    if (-not $cf) { Fail 'cloudflared not found. Install it with: winget install --id Cloudflare.cloudflared' }

    # --- 3. Tunnel must connect AND its hostname must exist in DNS; otherwise retry
    for ($attempt = 1; $attempt -le 3 -and -not $publicUrl; $attempt++) {
        Write-Step "Starting Cloudflare quick tunnel (attempt $attempt of 3) ..."
        $qt = Start-QuickTunnel $cf.Source
        $tunnel = $qt.Process
        if (-not $qt.Ready) {
            Write-Warn 'Tunnel did not connect. Last log lines:'
            Get-Content $tunnelLog -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
            Stop-Tree $tunnel.Id
            continue
        }
        Write-Step "Tunnel connected: $($qt.Url)"
        Write-Host '    waiting for its DNS record ' -NoNewline
        if (Wait-PublicDns ([uri]$qt.Url).Host 90) {
            Write-Host ''
            $publicUrl = $qt.Url
        } else {
            Write-Host ''
            Write-Warn 'Its DNS record never appeared; discarding this tunnel and trying a new one.'
            Stop-Tree $tunnel.Id
        }
    }
    if (-not $publicUrl) { Fail "Could not get a working tunnel after 3 attempts. See $tunnelLog" }
    Start-Sleep -Seconds 5   # let other public resolvers (Telegram's) catch up
}
@{ tunnelPid = $tunnel.Id; publicUrl = $publicUrl } | ConvertTo-Json | Set-Content $stateFile
Write-Ok "Public URL (resolves on public DNS): $publicUrl"

# --- 4. Start n8n with the correct WEBHOOK_URL -------------------------------
$env:WEBHOOK_URL    = "$publicUrl/"
$env:N8N_PROXY_HOPS = '1'   # n8n sits behind the tunnel proxy
Write-Step "Starting n8n with WEBHOOK_URL=$($env:WEBHOOK_URL) in a new window ..."
$n8n = Start-Process powershell.exe -PassThru -ArgumentList '-NoExit', '-Command',
    "`$Host.UI.RawUI.WindowTitle = 'n8n - $publicUrl'; npx n8n"
@{ tunnelPid = $tunnel.Id; n8nPid = $n8n.Id; publicUrl = $publicUrl } | ConvertTo-Json | Set-Content $stateFile

$deadline = (Get-Date).AddMinutes(3)
$up = $false
while (-not $up -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if ($n8n.HasExited) { Fail 'The n8n window closed during startup. Run "npx n8n" by hand to see the error.' }
    try { $up = (Invoke-WebRequest "http://localhost:$Port/healthz" -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200 } catch {}
}
if (-not $up) { Fail 'n8n did not become healthy within 3 minutes. Check the n8n window.' }
Write-Ok 'n8n is running locally.'

try   { Invoke-WebRequest "$publicUrl/healthz" -UseBasicParsing -TimeoutSec 15 | Out-Null; Write-Ok 'n8n is reachable through the tunnel.' }
catch { Write-Warn "n8n is NOT reachable through the tunnel: $($_.Exception.Message)" }

# --- 5. Verify the Telegram webhook ------------------------------------------
Write-Step 'Waiting for n8n to register the Telegram webhook ...'
$deadline = (Get-Date).AddSeconds(30)
do {
    Start-Sleep -Seconds 3
    $url = (Invoke-RestMethod "$tgApi/getWebhookInfo").result.url
} until (($url -and $url.StartsWith("$publicUrl/")) -or (Get-Date) -gt $deadline)

Write-Host ''
$ok = Test-Webhook $tgApi $publicUrl
Write-Host ''
Write-Host "Editor:  $publicUrl" -ForegroundColor Cyan
Write-Host 'Stop everything with: .\start-n8n.ps1 -Stop'
if (-not $NgrokDomain) {
    Write-Host 'Note: quick-tunnel URLs change every run. Re-run this script after any restart; for a URL that never changes, use -NgrokDomain.' -ForegroundColor DarkGray
}
exit $(if ($ok) { 0 } else { 1 })
