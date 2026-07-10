<#
.SYNOPSIS
    Read the JamboFlow Diagnostic's real visitor conversations.

.DESCRIPTION
    Pulls transcripts from the D1 log and prints them formatted for reading,
    newest conversation first. Requires wrangler to be logged in (it already
    is on this machine).

.EXAMPLE
    .\review.ps1                  # last 7 days of conversations
    .\review.ps1 -Days 1          # today's
    .\review.ps1 -Funnel          # the numbers: conversations, diagnoses, rate-limit hits
#>
param(
    [int]$Days = 7,
    [switch]$Funnel
)

$ErrorActionPreference = "Stop"
$workerDir = Join-Path $PSScriptRoot "..\worker"

if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}

function Invoke-D1([string]$Sql) {
    $flat = ($Sql -replace '\s+', ' ').Trim()
    Push-Location $workerDir
    try {
        $raw = npx -y wrangler d1 execute jamboflow-diagnostic-logs --remote --json --command $flat 2>$null
        if ($LASTEXITCODE -ne 0) { throw "wrangler d1 query failed: $raw" }
        ($raw | ConvertFrom-Json)[0].results
    } finally { Pop-Location }
}

$gold = "Yellow"; $dim = "DarkGray"; $cyan = "Cyan"

if ($Funnel) {
    $stats = Invoke-D1 @"
SELECT
  COUNT(DISTINCT convo_id)                                          AS conversations,
  COUNT(CASE WHEN kind = 'exchange' THEN 1 END)                     AS exchanges,
  COUNT(DISTINCT CASE WHEN diagnosis = 1 THEN convo_id END)         AS reached_diagnosis,
  COUNT(CASE WHEN kind = 'rate_limited' THEN 1 END)                 AS rate_limit_hits
FROM turns WHERE ts >= datetime('now', '-$Days days');
"@
    Write-Host ""
    Write-Host "  DIAGNOSTIC FUNNEL - last $Days day(s)" -ForegroundColor $gold
    Write-Host "  Conversations started:  $($stats.conversations)"
    Write-Host "  Total exchanges:        $($stats.exchanges)"
    Write-Host "  Reached a diagnosis:    $($stats.reached_diagnosis)"
    Write-Host "  Rate-limit rejections:  $($stats.rate_limit_hits)"
    Write-Host ""
    exit 0
}

$rows = Invoke-D1 @"
SELECT convo_id, ts, country, kind, user_msg, assistant_msg, diagnosis
FROM turns
WHERE ts >= datetime('now', '-$Days days')
ORDER BY convo_id, id;
"@

if (-not $rows) {
    Write-Host "No conversations in the last $Days day(s)." -ForegroundColor $dim
    exit 0
}

$byConvo = $rows | Group-Object convo_id | Sort-Object { ($_.Group | Select-Object -First 1).ts } -Descending

foreach ($convo in $byConvo) {
    $first = $convo.Group | Select-Object -First 1
    $hasDiagnosis = ($convo.Group | Where-Object { $_.diagnosis -eq 1 }).Count -gt 0
    $badge = if ($hasDiagnosis) { " [REACHED DIAGNOSIS]" } else { "" }
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor $dim
    Write-Host "$($first.ts) UTC | $($first.country) | $($convo.Name)$badge" -ForegroundColor $gold
    Write-Host ("=" * 70) -ForegroundColor $dim
    foreach ($t in $convo.Group) {
        if ($t.kind -eq "rate_limited") {
            Write-Host "  -- rate-limited here --" -ForegroundColor Red
            continue
        }
        Write-Host ""
        Write-Host "  Visitor> " -ForegroundColor $cyan -NoNewline
        Write-Host $t.user_msg
        Write-Host "  Diagnostic> " -ForegroundColor $gold -NoNewline
        Write-Host $t.assistant_msg
    }
}
Write-Host ""
Write-Host "$($byConvo.Count) conversation(s). Run with -Funnel for the numbers." -ForegroundColor $dim
