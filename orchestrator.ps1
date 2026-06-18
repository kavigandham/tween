param(
    [string]$StartFrom = ""
)

$ErrorActionPreference = "Stop"
$LogsDir = ".\logs"

if (-not (Get-Command "claude" -ErrorAction SilentlyContinue)) {
    Write-Host "X claude CLI not found. Install: npm install -g @anthropic-ai/claude-code" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir | Out-Null }

$phases = Get-ChildItem -Path ".\prompts" -Filter "*.md" | Where-Object { $_.Name -match "^\d" } | Sort-Object Name
if ($phases.Count -eq 0) {
    Write-Host "No phase files found in prompts folder" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Tween build - $($phases.Count) phases" -ForegroundColor Cyan
Write-Host ""

$skipping = $StartFrom -ne ""

foreach ($phase in $phases) {
    $name = $phase.BaseName

    if ($skipping) {
        if ($name -eq $StartFrom) {
            $skipping = $false
        } else {
            Write-Host ">> Skipping $name" -ForegroundColor DarkGray
            continue
        }
    }

    Write-Host "=========================================" -ForegroundColor White
    Write-Host "  Phase: $name" -ForegroundColor Yellow
    Write-Host "  Started: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Gray
    Write-Host "=========================================" -ForegroundColor White

    $prompt = Get-Content -Path $phase.FullName -Raw
    $tempFile = Join-Path $env:TEMP "tween_prompt.txt"
    Set-Content -Path $tempFile -Value $prompt -Encoding UTF8

    $logFile = Join-Path $LogsDir "$name.log"
    try {
        Get-Content $tempFile -Raw | claude -p --dangerously-skip-permissions --output-format text 2>&1 | Tee-Object -FilePath $logFile
        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Host "X Claude Code failed on $name" -ForegroundColor Red
            Write-Host "  Resume: .\orchestrator.ps1 -StartFrom $name" -ForegroundColor Yellow
            exit 1
        }
    } catch {
        Write-Host ""
        Write-Host "X Claude Code error on $name" -ForegroundColor Red
        Write-Host "  Resume: .\orchestrator.ps1 -StartFrom $name" -ForegroundColor Yellow
        exit 1
    }

    Write-Host ""
    Write-Host "--- File gate ---" -ForegroundColor Gray
    $swiftFiles = @(Get-ChildItem -Path . -Filter "*.swift" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "\.git" })
    $emptyFiles = @($swiftFiles | Where-Object { $_.Length -eq 0 })

    if ($swiftFiles.Count -eq 0) {
        Write-Host "X No .swift files found after $name" -ForegroundColor Red
        Write-Host "  Resume: .\orchestrator.ps1 -StartFrom $name" -ForegroundColor Yellow
        exit 1
    }

    if ($emptyFiles.Count -gt 0) {
        Write-Host "!! $($emptyFiles.Count) empty .swift files" -ForegroundColor Yellow
    }

    Write-Host "OK $name complete - $($swiftFiles.Count) Swift files" -ForegroundColor Green

    git add -A 2>$null
    $commitMsg = "phase: $name"
    $match = Select-String -Path $phase.FullName -Pattern 'Commit with message: "(.+)"'
    if ($match) { $commitMsg = $match.Matches[0].Groups[1].Value }
    git commit -m "$commitMsg" --allow-empty 2>$null

    Write-Host ""
}

Write-Host "=========================================" -ForegroundColor White
Write-Host "All $($phases.Count) phases complete." -ForegroundColor Green
Write-Host ""
Write-Host "Next: git push origin main" -ForegroundColor Yellow
Write-Host "=========================================" -ForegroundColor White
