# orchestrator.ps1 — Tween build orchestrator (Windows/PowerShell)
param(
    [string]$StartFrom = ""
)

$ErrorActionPreference = "Stop"
$PromptsDir = ".\prompts"
$LogsDir = ".\logs"

# Preflight
if (-not (Get-Command "claude" -ErrorAction SilentlyContinue)) {
    Write-Host "X claude CLI not found. Install: npm install -g @anthropic-ai/claude-code" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir | Out-Null }

$phases = Get-ChildItem -Path $PromptsDir -Filter "[0-9]*.md" | Sort-Object Name
if ($phases.Count -eq 0) {
    Write-Host "No phase files found in $PromptsDir\" -ForegroundColor Red
    exit 1
}

Write-Host "`nTween build — $($phases.Count) phases (Windows mode)`n" -ForegroundColor Cyan

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

    # Read the phase prompt
    $prompt = Get-Content -Path $phase.FullName -Raw

    # Feed to Claude Code
    $logFile = Join-Path $LogsDir "$name.log"
    try {
        claude -p $prompt 2>&1 | Tee-Object -FilePath $logFile
        if ($LASTEXITCODE -ne 0) {
            Write-Host "`nX Claude Code failed on $name" -ForegroundColor Red
            Write-Host "  Check: $logFile" -ForegroundColor Gray
            Write-Host "  Resume: .\orchestrator.ps1 -StartFrom $name" -ForegroundColor Yellow
            exit 1
        }
    } catch {
        Write-Host "`nX Claude Code failed on $name : $_" -ForegroundColor Red
        Write-Host "  Resume: .\orchestrator.ps1 -StartFrom $name" -ForegroundColor Yellow
        exit 1
    }

    # File gate: check Swift files exist
    Write-Host "`n--- File gate ---" -ForegroundColor Gray
    $swiftFiles = Get-ChildItem -Path . -Filter "*.swift" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "*\.git*" }
    $emptyFiles = $swiftFiles | Where-Object { $_.Length -eq 0 }

    if ($swiftFiles.Count -eq 0) {
        Write-Host "X No .swift files found after $name" -ForegroundColor Red
        Write-Host "  Resume: .\orchestrator.ps1 -StartFrom $name" -ForegroundColor Yellow
        exit 1
    }

    if ($emptyFiles.Count -gt 0) {
        Write-Host "!! $($emptyFiles.Count) empty .swift files:" -ForegroundColor Yellow
        $emptyFiles | ForEach-Object { Write-Host "   $($_.FullName)" }
    }

    Write-Host "OK $name complete — $($swiftFiles.Count) Swift files" -ForegroundColor Green

    # Auto-commit
    git add -A 2>$null
    $commitMsg = (Select-String -Path $phase.FullName -Pattern 'Commit with message: "(.+)"' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }) 
    if (-not $commitMsg) { $commitMsg = "phase: $name" }
    git commit -m $commitMsg --allow-empty 2>$null

    Write-Host ""
}

Write-Host "=========================================" -ForegroundColor White
Write-Host "All $($phases.Count) phases complete." -ForegroundColor Green
$finalCount = (Get-ChildItem -Path . -Filter "*.swift" -Recurse |
    Where-Object { $_.FullName -notlike "*\.git*" }).Count
Write-Host "Swift files: $finalCount" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. git push origin main"
Write-Host "  2. Friend pulls, runs 'xcodegen generate', opens in Xcode"
Write-Host "  3. Build + test on Mac"
Write-Host "=========================================" -ForegroundColor White
