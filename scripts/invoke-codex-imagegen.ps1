param(
    [Parameter(Mandatory = $true)]
    [string]$Prompt,

    [string]$OutDir = (Join-Path (Get-Location) "codex-imagegen-output"),

    [string]$CodexCommand = "",

    [switch]$LoginFirst,

    [switch]$Interactive,

    [string]$ExtraInstruction = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ImageFiles {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $extensions = @(".png", ".jpg", ".jpeg", ".webp")
    if (-not (Test-Path -LiteralPath $Directory)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $Directory -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() })
}

if ([string]::IsNullOrWhiteSpace($CodexCommand)) {
    $standaloneCodex = Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin\codex.exe"
    if (Test-Path -LiteralPath $standaloneCodex -PathType Leaf) {
        $CodexCommand = $standaloneCodex
    } else {
        $CodexCommand = "codex"
    }
}

$command = Get-Command $CodexCommand -ErrorAction SilentlyContinue
if (-not $command) {
    throw "Codex CLI command '$CodexCommand' was not found. Install Codex CLI or pass -CodexCommand with the executable path."
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$resolvedOutDir = (Resolve-Path -LiteralPath $OutDir).Path

if ($LoginFirst) {
    & $CodexCommand login
    if ($LASTEXITCODE -ne 0) {
        throw "codex login failed with exit code $LASTEXITCODE."
    }
}

$before = @{}
foreach ($file in Get-ImageFiles -Directory $resolvedOutDir) {
    $before[$file.FullName] = $true
}

$message = @"
`$imagegen
Generate the requested image using Codex CLI's built-in image generation.
Save the final image file under this absolute directory:
$resolvedOutDir

User prompt:
$Prompt

After saving, print the absolute path of each created image file.
"@

if ($ExtraInstruction.Trim().Length -gt 0) {
    $message = "$message`n`nAdditional instruction:`n$ExtraInstruction"
}

$started = Get-Date
if ($Interactive) {
    & $CodexCommand $message
} else {
    & $CodexCommand exec $message
}

if ($LASTEXITCODE -ne 0) {
    throw "Codex CLI failed with exit code $LASTEXITCODE."
}

$newFiles = @(Get-ImageFiles -Directory $resolvedOutDir |
    Where-Object { -not $before.ContainsKey($_.FullName) -and $_.LastWriteTime -ge $started.AddSeconds(-2) })

if ($newFiles.Count -eq 0) {
    Write-Warning "No new image files were detected under '$resolvedOutDir'. Check the Codex CLI output for the actual saved path."
    exit 0
}

$newFiles | Sort-Object LastWriteTime | ForEach-Object { $_.FullName }
