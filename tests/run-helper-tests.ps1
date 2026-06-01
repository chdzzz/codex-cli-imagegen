$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $repoRoot "scripts\invoke-codex-imagegen.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-cli-imagegen-tests-" + [Guid]::NewGuid().ToString("N"))

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

try {
    $mockPs1 = Join-Path $PSScriptRoot "mock-codex.ps1"
    $mockCmd = Join-Path $testRoot "mock-codex.cmd"
@"
@echo off
if "%1"=="--version" (
  echo codex-cli mock 0.0.0
  exit /b 0
)
if "%1"=="login" (
  echo Logged in using ChatGPT
  exit /b 0
)
powershell -NoProfile -ExecutionPolicy Bypass -File "$mockPs1"
exit /b %ERRORLEVEL%
"@ | Set-Content -LiteralPath $mockCmd -Encoding ASCII

    $env:CODEX_HOME = Join-Path $testRoot "codex-home"
    $checkOnlyOut = Join-Path $testRoot "check-only-should-not-exist"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $helper -Prompt "check only" -CheckOnly -CodexCommand $mockCmd -OutDir $checkOnlyOut
    Assert-True -Condition (-not (Test-Path -LiteralPath $checkOnlyOut)) -Message "CheckOnly created the output directory."

    $directOut = Join-Path $testRoot "direct-output"
    $env:MOCK_CODEX_MODE = "direct"
    $env:MOCK_CODEX_HANG = ""
    & powershell -NoProfile -ExecutionPolicy Bypass -File $helper `
        -Prompt "direct mock image" `
        -CodexCommand $mockCmd `
        -OutDir $directOut `
        -TimeoutSeconds 30 `
        -PollSeconds 1 `
        -StableSeconds 0
    Assert-True -Condition ((Get-ChildItem -LiteralPath $directOut -Filter *.png -File).Count -ge 1) -Message "Direct output image was not detected."

    $fallbackOut = Join-Path $testRoot "fallback-output"
    $env:MOCK_CODEX_MODE = "fallback"
    $env:MOCK_CODEX_HANG = "1"
    $started = Get-Date
    & powershell -NoProfile -ExecutionPolicy Bypass -File $helper `
        -Prompt "fallback mock image" `
        -CodexCommand $mockCmd `
        -OutDir $fallbackOut `
        -TimeoutSeconds 60 `
        -PollSeconds 1 `
        -StableSeconds 0
    $elapsed = ((Get-Date) - $started).TotalSeconds
    Assert-True -Condition ($elapsed -lt 30) -Message "Early image detection did not stop the hanging mock Codex process."
    Assert-True -Condition ((Get-ChildItem -LiteralPath $fallbackOut -Filter *.png -File).Count -ge 1) -Message "Fallback output image was not copied."

    Write-Host "All helper tests passed."
} finally {
    Remove-Item Env:MOCK_CODEX_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:MOCK_CODEX_HANG -ErrorAction SilentlyContinue
    Remove-Item Env:MOCK_CODEX_EXIT_CODE -ErrorAction SilentlyContinue
    Remove-Item Env:MOCK_CODEX_OUTPUT_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
