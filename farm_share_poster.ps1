# FarmTracker - Farm Share Poster (PowerShell)
# Run this script manually after clicking Share in-game.
# It processes any .lua files in the share/ folder, posts to Discord, then deletes them.
#
# Setup:
#   1. Place this script inside your farm_tracker/ folder
#   2. Edit config.ini with your Discord webhook URL
#   3. Right-click the script -> "Run with PowerShell"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile  = Join-Path $ScriptDir "config.ini"
$ShareFolder = Join-Path $ScriptDir "share"
$MsgIdFile   = Join-Path $ScriptDir "message_ids.json"

# ── Timezone offsets ──────────────────────────────────────────────────────────
$TzOffsets = @{
    EST = -5; EDT = -4
    CST = -6; CDT = -5
    MST = -7; MDT = -6
    PST = -8; PDT = -7
    UTC =  0; GMT =  0
}

# ── Load config ───────────────────────────────────────────────────────────────
function Load-Config {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "[ERROR] config.ini not found at: $ConfigFile"
        Read-Host "Press Enter to exit"
        exit 1
    }
    $content = Get-Content $ConfigFile
    foreach ($line in $content) {
        if ($line -match '^\s*webhook_url\s*=\s*(.+)$') {
            $url = $Matches[1].Trim()
            if ($url -and $url -ne "YOUR_WEBHOOK_URL_HERE") {
                return $url
            }
        }
    }
    Write-Host "[ERROR] webhook_url is not set in config.ini"
    Read-Host "Press Enter to exit"
    exit 1
}

# ── Message ID store ──────────────────────────────────────────────────────────
function Load-MessageIds {
    if (Test-Path $MsgIdFile) {
        try {
            return Get-Content $MsgIdFile -Raw | ConvertFrom-Json -AsHashtable
        } catch {}
    }
    return @{}
}

function Save-MessageIds($ids) {
    $ids | ConvertTo-Json | Set-Content $MsgIdFile -Encoding UTF8
}

# ── Expiry tag conversion ─────────────────────────────────────────────────────
function Convert-ExpiryTags($content) {
    $pattern = '\[expiry:(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) ([A-Z]+)\]'
    return [regex]::Replace($content, $pattern, {
        param($m)
        $dateStr = $m.Groups[1].Value
        $tzStr   = $m.Groups[2].Value.ToUpper()
        $offset  = if ($TzOffsets.ContainsKey($tzStr)) { $TzOffsets[$tzStr] } else { 0 }
        try {
            $dt      = [datetime]::ParseExact($dateStr, "yyyy-MM-dd HH:mm:ss", $null)
            $dtUtc   = $dt.AddHours(-$offset)
            $epoch   = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $unix    = [long]($dtUtc.ToUniversalTime() - $epoch).TotalSeconds
            return "<t:${unix}:R>"
        } catch {
            return $m.Value
        }
    })
}

# ── Lua content parser ────────────────────────────────────────────────────────
function Extract-Content($luaText) {
    if ($luaText -match '(?s)content\s*=\s*"((?:[^"\\]|\\.)*)"') {
        $raw = $Matches[1]
        # Lua serializes newlines as backslash + CRLF (line continuation)
        $raw = $raw -replace '\\\r\n', "`n"
        $raw = $raw -replace '\\\n', "`n"
        $raw = $raw -replace '\\"', '"'
        return $raw
    }
    return $null
}

function Get-FarmKey($content) {
    $lines = $content.Trim() -split "`n"
    if ($lines.Count -ge 2) { return ($lines[0..1] -join "`n").Trim() }
    return $lines[0].Trim()
}

# ── Discord ───────────────────────────────────────────────────────────────────
function Post-Message($webhookUrl, $content) {
    $body = [ordered]@{ content = $content } | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $resp = Invoke-RestMethod -Uri "${webhookUrl}?wait=true" -Method Post `
        -ContentType "application/json; charset=utf-8" -Body $bytes
    return [string]$resp.id
}

function Delete-Message($webhookUrl, $messageId) {
    try {
        Invoke-RestMethod -Uri "${webhookUrl}/messages/${messageId}" -Method Delete | Out-Null
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            Write-Host "[INFO] Previous message $messageId already gone, skipping delete."
        } else {
            Write-Host "[WARN] Could not delete message: $_"
        }
    }
}

# ── Process a share file ──────────────────────────────────────────────────────
function Process-File($filepath, $webhookUrl) {
    $filename = Split-Path -Leaf $filepath
    Start-Sleep -Milliseconds 200

    try {
        $luaText = Get-Content $filepath -Raw -Encoding UTF8
        $content = Extract-Content $luaText
        if (-not $content) {
            Write-Host "[WARN] Could not parse content from $filename, skipping."
            return
        }

        $content    = Convert-ExpiryTags $content
        $messageIds = Load-MessageIds
        $key        = Get-FarmKey $content

        if ($messageIds.ContainsKey($key)) {
            $firstLine = ($key -split "`n")[0]
            Write-Host "[DELETE] Removing previous post for: $firstLine"
            Delete-Message $webhookUrl $messageIds[$key]
        }

        $firstLine = ($key -split "`n")[0]
        Write-Host "[POST] $firstLine"
        $msgId = Post-Message $webhookUrl $content
        $messageIds[$key] = $msgId
        Save-MessageIds $messageIds
        Remove-Item $filepath -Force
        Write-Host "[DONE] Posted message $msgId`n"

    } catch {
        if ($_ -match "Cannot find path") { return }
        Write-Host "[ERROR] Failed to process ${filename}: $_"
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────
$webhookUrl = Load-Config

if (-not (Test-Path $ShareFolder)) {
    New-Item -ItemType Directory -Path $ShareFolder | Out-Null
}

Write-Host "FarmTracker Share Poster"
Write-Host "Processing share folder: $ShareFolder`n"

$files = Get-ChildItem -Path $ShareFolder -Filter "*.lua" -ErrorAction SilentlyContinue
if ($files.Count -eq 0) {
    Write-Host "[INFO] No share files found. Click 'Share' in-game first, then run this script."
} else {
    foreach ($file in $files) {
        Process-File $file.FullName $webhookUrl
    }
    Write-Host "Done."
}

Read-Host "`nPress Enter to close"
