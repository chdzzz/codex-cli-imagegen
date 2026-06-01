$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $repoRoot "scripts\invoke-codex-imagegen.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-cli-imagegen-tests-" + [Guid]::NewGuid().ToString("N"))
$envNames = @("CODEX_HOME", "MOCK_CODEX_MODE", "MOCK_CODEX_HANG", "MOCK_CODEX_EXIT_CODE", "MOCK_CODEX_OUTPUT_DIR")
$originalEnv = @{}

foreach ($name in $envNames) {
    $originalEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

function Test-IsWindows {
    return ($env:OS -eq "Windows_NT" -or [System.IO.Path]::DirectorySeparatorChar -eq "\")
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-PowerShellCommand {
    try {
        $currentProcess = Get-Process -Id $PID -ErrorAction Stop
        if ($currentProcess.Path -and (Test-Path -LiteralPath $currentProcess.Path -PathType Leaf)) {
            return $currentProcess.Path
        }
    } catch {
        # Fall back to PATH lookup below.
    }

    foreach ($name in @("pwsh", "powershell")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source) {
            return $command.Source
        }
    }

    throw "Could not find a PowerShell executable for running helper tests."
}

function Get-PowerShellFileArgs {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add("-NoProfile") | Out-Null
    if (Test-IsWindows) {
        $args.Add("-ExecutionPolicy") | Out-Null
        $args.Add("Bypass") | Out-Null
    }
    $args.Add("-File") | Out-Null
    $args.Add($ScriptPath) | Out-Null
    return $args.ToArray()
}

function Join-CmdCommandLine {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    return (($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " ")
}

function Join-ShCommandLine {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    foreach ($argument in $Arguments) {
        if ($argument.Contains("'")) {
            throw "Test paths containing single quotes are not supported by the POSIX mock wrapper."
        }
    }

    return (($Arguments | ForEach-Object { "'" + $_ + "'" }) -join " ")
}

function New-MockCodexCommand {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellCommand,
        [Parameter(Mandatory = $true)][string]$MockScript,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $psFileArgs = Get-PowerShellFileArgs -ScriptPath $MockScript
    if (Test-IsWindows) {
        $mockCommand = Join-Path $Directory "mock-codex.cmd"
        $psCommandLine = Join-CmdCommandLine -Arguments (@($PowerShellCommand) + @($psFileArgs))
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
$psCommandLine
exit /b %ERRORLEVEL%
"@ | Set-Content -LiteralPath $mockCommand -Encoding ASCII
        return $mockCommand
    }

    $mockCommand = Join-Path $Directory "mock-codex"
    $psCommandLine = Join-ShCommandLine -Arguments (@($PowerShellCommand) + @($psFileArgs))
@"
#!/usr/bin/env sh
if [ "`$1" = "--version" ]; then
  echo "codex-cli mock 0.0.0"
  exit 0
fi
if [ "`$1" = "login" ]; then
  echo "Logged in using ChatGPT"
  exit 0
fi
exec $psCommandLine
"@ | Set-Content -LiteralPath $mockCommand -Encoding UTF8
    & chmod +x $mockCommand
    return $mockCommand
}

function Invoke-Helper {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $psArgs = @(Get-PowerShellFileArgs -ScriptPath $helper) + @($Arguments)
    & $powerShell @psArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Helper exited with code $LASTEXITCODE for arguments: $($Arguments -join ' ')"
    }
}

function Restore-TestEnvironment {
    foreach ($name in $envNames) {
        if ($null -eq $originalEnv[$name]) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        } else {
            [Environment]::SetEnvironmentVariable($name, [string]$originalEnv[$name], "Process")
        }
    }
}

$powerShell = Get-PowerShellCommand
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

try {
    $mockPs1 = Join-Path $PSScriptRoot "mock-codex.ps1"
    $mockCommand = New-MockCodexCommand -PowerShellCommand $powerShell -MockScript $mockPs1 -Directory $testRoot

    $env:CODEX_HOME = Join-Path $testRoot "codex-home"
    $checkOnlyOut = Join-Path $testRoot "check-only-should-not-exist"
    Invoke-Helper -Arguments @("-Prompt", "check only", "-CheckOnly", "-CodexCommand", $mockCommand, "-OutDir", $checkOnlyOut)
    Assert-True -Condition (-not (Test-Path -LiteralPath $checkOnlyOut)) -Message "CheckOnly created the output directory."

    $directOut = Join-Path $testRoot "direct-output"
    $env:MOCK_CODEX_MODE = "direct"
    $env:MOCK_CODEX_HANG = ""
    Invoke-Helper -Arguments @(
        "-Prompt", "direct mock image",
        "-CodexCommand", $mockCommand,
        "-OutDir", $directOut,
        "-TimeoutSeconds", "30",
        "-PollSeconds", "1",
        "-StableSeconds", "0"
    )
    Assert-True -Condition ((Get-ChildItem -LiteralPath $directOut -Filter *.png -File).Count -ge 1) -Message "Direct output image was not detected."

    $fallbackOut = Join-Path $testRoot "fallback-output"
    $env:MOCK_CODEX_MODE = "fallback"
    $env:MOCK_CODEX_HANG = "1"
    $started = Get-Date
    Invoke-Helper -Arguments @(
        "-Prompt", "fallback mock image",
        "-CodexCommand", $mockCommand,
        "-OutDir", $fallbackOut,
        "-TimeoutSeconds", "60",
        "-PollSeconds", "1",
        "-StableSeconds", "0"
    )
    $elapsed = ((Get-Date) - $started).TotalSeconds
    Assert-True -Condition ($elapsed -lt 30) -Message "Early image detection did not stop the hanging mock Codex process."
    Assert-True -Condition ((Get-ChildItem -LiteralPath $fallbackOut -Filter *.png -File).Count -ge 1) -Message "Fallback output image was not copied."

    Write-Host "All helper tests passed."
} finally {
    Restore-TestEnvironment
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
