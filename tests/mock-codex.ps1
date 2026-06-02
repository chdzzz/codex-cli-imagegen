[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Version,
    [string]$disable,
    [string]$a,
    [string]$s,
    [switch]${skip-git-repo-check},

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"

function Get-OutputDirectoryFromPrompt {
    param([string]$Prompt)

    $match = [regex]::Match($Prompt, "Save the final image file under this absolute directory:\s*\r?\n([^\r\n]+)")
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }

    return $env:MOCK_CODEX_OUTPUT_DIR
}

$AllArgs = New-Object System.Collections.Generic.List[string]
if ($PSBoundParameters.ContainsKey("disable")) {
    $AllArgs.Add("--disable") | Out-Null
    $AllArgs.Add($disable) | Out-Null
}
if ($PSBoundParameters.ContainsKey("a")) {
    $AllArgs.Add("-a") | Out-Null
    $AllArgs.Add($a) | Out-Null
}
if ($PSBoundParameters.ContainsKey("s")) {
    $AllArgs.Add("-s") | Out-Null
    $AllArgs.Add($s) | Out-Null
}
foreach ($arg in $RemainingArgs) {
    $AllArgs.Add($arg) | Out-Null
}

if ($Version -or $AllArgs.Contains("--version")) {
    Write-Output "codex-cli mock 0.0.0"
    exit 0
}

if ($AllArgs.Count -ge 2 -and $AllArgs[0] -eq "login" -and $AllArgs[1] -eq "status") {
    Write-Output "Logged in using ChatGPT"
    exit 0
}

if ($AllArgs.Count -ge 1 -and $AllArgs[0] -eq "login") {
    Write-Output "Mock login complete"
    exit 0
}

if ($AllArgs.Contains("exec") -or $AllArgs.Count -eq 0) {
    $prompt = [Console]::In.ReadToEnd()
    $outputDirectory = Get-OutputDirectoryFromPrompt -Prompt $prompt
    if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
        throw "Mock Codex could not determine output directory."
    }

    if ($env:MOCK_CODEX_MODE -eq "fallback") {
        $codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
            Join-Path $env:USERPROFILE ".codex"
        } else {
            $env:CODEX_HOME
        }
        $outputDirectory = Join-Path $codexHome "generated_images\mock-session"
    }

    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $imagePath = Join-Path $outputDirectory ("mock-{0}.png" -f ([Guid]::NewGuid().ToString("N")))
    $pngBytes = [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")
    [System.IO.File]::WriteAllBytes($imagePath, $pngBytes)
    Write-Output $imagePath

    if ($env:MOCK_CODEX_HANG -eq "1") {
        Start-Sleep -Seconds 120
    }

    if (-not [string]::IsNullOrWhiteSpace($env:MOCK_CODEX_EXIT_CODE)) {
        exit ([int]$env:MOCK_CODEX_EXIT_CODE)
    }

    exit 0
}

Write-Output "mock codex: unsupported args $($AllArgs -join ' ')"
exit 0
