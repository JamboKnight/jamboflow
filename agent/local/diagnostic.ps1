<#
.SYNOPSIS
    JamboFlow Diagnostic — local, fully offline runner.

.DESCRIPTION
    Runs the same diagnostic brain as the website agent, but against a local
    model via Ollama. No internet, no accounts, no cost. Useful as a private
    copilot during client calls, or for rehearsing the diagnostic itself.

    Prerequisites (one-time, needs internet only for the download):
      1. Install Ollama:  https://ollama.com/download/windows
      2. Pull a model:    ollama pull llama3.1:8b

.EXAMPLE
    .\diagnostic.ps1
    .\diagnostic.ps1 -Model qwen3:8b
#>
param(
    [string]$Model = "llama3.1:8b",
    [string]$OllamaUrl = "http://localhost:11434"
)

$ErrorActionPreference = "Stop"

# ── Load the shared brain ─────────────────────────────────────
$brainPath = Join-Path $PSScriptRoot "..\brain\system-prompt.md"
if (-not (Test-Path $brainPath)) {
    Write-Host "Cannot find the brain at $brainPath" -ForegroundColor Red
    exit 1
}
$systemPrompt = Get-Content $brainPath -Raw

# ── Check Ollama is up and the model exists ───────────────────
try {
    $tags = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 5
} catch {
    Write-Host "Ollama isn't running. Start it (it usually runs as a tray app) or install it from https://ollama.com/download/windows" -ForegroundColor Red
    exit 1
}
if (-not ($tags.models.name -contains $Model)) {
    Write-Host "Model '$Model' isn't pulled yet. Run:  ollama pull $Model" -ForegroundColor Red
    exit 1
}

# ── Conversation state ────────────────────────────────────────
$greeting = "Jambo - I'm the JamboFlow Diagnostic, an automated first pass of the diagnosis we run at the start of every engagement. Tell me what your operation looks like, and where it hurts most day to day."
$messages = [System.Collections.Generic.List[object]]::new()
$messages.Add(@{ role = "system"; content = $systemPrompt })

$gold = "Yellow"; $dim = "DarkGray"
Write-Host ""
Write-Host "  JAMBOFLOW DIAGNOSTIC  (local / offline / $Model)" -ForegroundColor $gold
Write-Host "  Type 'exit' to quit." -ForegroundColor $dim
Write-Host ""
Write-Host "Diagnostic> " -ForegroundColor $gold -NoNewline
Write-Host $greeting
Write-Host ""

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromMinutes(10)

while ($true) {
    Write-Host "You> " -ForegroundColor Cyan -NoNewline
    $userInput = Read-Host
    if ([string]::IsNullOrWhiteSpace($userInput)) { continue }
    if ($userInput.Trim() -in @("exit", "quit")) { break }

    $messages.Add(@{ role = "user"; content = $userInput })

    $body = @{
        model    = $Model
        messages = $messages
        stream   = $true
    } | ConvertTo-Json -Depth 6

    Write-Host ""
    Write-Host "Diagnostic> " -ForegroundColor $gold -NoNewline

    $req = [System.Net.Http.HttpRequestMessage]::new("Post", "$OllamaUrl/api/chat")
    $req.Content = [System.Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, "application/json")
    $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $reader = [System.IO.StreamReader]::new($stream)

    $full = New-Object System.Text.StringBuilder
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $chunk = $line | ConvertFrom-Json
        if ($chunk.message.content) {
            Write-Host $chunk.message.content -NoNewline
            [void]$full.Append($chunk.message.content)
        }
        if ($chunk.done) { break }
    }
    $reader.Dispose()
    Write-Host ""
    Write-Host ""

    $messages.Add(@{ role = "assistant"; content = $full.ToString() })
}

$client.Dispose()
Write-Host "Kwaheri." -ForegroundColor $dim
