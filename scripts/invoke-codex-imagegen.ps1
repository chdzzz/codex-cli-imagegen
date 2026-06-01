param(
    [Parameter(Mandatory = $true)]
    [string]$Prompt,

    [string]$OutDir = (Join-Path (Get-Location) "codex-imagegen-output"),

    [string]$CodexCommand = "",

    [switch]$LoginFirst,

    [switch]$Interactive,

    [string]$ExtraInstruction = "",

    [string]$WorkDir = (Get-Location).Path,

    [string]$ApprovalPolicy = "never",

    [string]$Sandbox = "workspace-write",

    [int]$TimeoutSeconds = 900,

    [switch]$NoSkipGitRepoCheck,

    [switch]$NoGeneratedImagesFallback,

    [switch]$CheckOnly
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

function Get-CodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return $env:CODEX_HOME
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return (Join-Path $env:USERPROFILE ".codex")
    }

    return (Join-Path $HOME ".codex")
}

function Add-Candidate {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Candidates,

        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if (-not $Candidates.Contains($Value)) {
        $Candidates.Add($Value) | Out-Null
    }
}

function Resolve-CommandPath {
    param([Parameter(Mandatory = $true)][string]$Candidate)

    $paths = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
        Add-Candidate -Candidates $paths -Value ((Resolve-Path -LiteralPath $Candidate).Path)
        return @($paths)
    }

    foreach ($command in @(Get-Command $Candidate -All -ErrorAction SilentlyContinue)) {
        if ($command.Source) {
            Add-Candidate -Candidates $paths -Value $command.Source
        } elseif ($command.Path) {
            Add-Candidate -Candidates $paths -Value $command.Path
        }
    }

    return @($paths)
}

function Test-CodexCommand {
    param([Parameter(Mandatory = $true)][string]$Candidate)

    foreach ($path in Resolve-CommandPath -Candidate $Candidate) {
        try {
            $versionOutput = @(& $path --version 2>&1)
            if ($LASTEXITCODE -eq 0) {
                return [pscustomobject]@{
                    Path = $path
                    Version = (($versionOutput | Select-Object -First 1) -as [string])
                    Error = $null
                }
            }

            $errorText = ($versionOutput -join "`n")
            Write-Verbose "Skipping Codex candidate '$path': exit $LASTEXITCODE $errorText"
        } catch {
            Write-Verbose "Skipping Codex candidate '$path': $($_.Exception.Message)"
        }
    }

    return $null
}

function Resolve-CodexCommand {
    param([string]$ExplicitCommand)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitCommand)) {
        $resolvedExplicit = Test-CodexCommand -Candidate $ExplicitCommand
        if ($resolvedExplicit) {
            return $resolvedExplicit
        }

        throw "Codex CLI command '$ExplicitCommand' was found but could not run. Pass a working -CodexCommand path."
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    Add-Candidate -Candidates $candidates -Value $env:CODEX_CLI
    Add-Candidate -Candidates $candidates -Value $env:CODEX_COMMAND

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $versionedBin = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
        if (Test-Path -LiteralPath $versionedBin -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $versionedBin -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter "codex.exe" -File -ErrorAction SilentlyContinue } |
                    Sort-Object LastWriteTime -Descending)) {
                Add-Candidate -Candidates $candidates -Value $file.FullName
            }
        }

        Add-Candidate -Candidates $candidates -Value (Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin\codex.exe")
        Add-Candidate -Candidates $candidates -Value (Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin\codex.exe")
    }

    Add-Candidate -Candidates $candidates -Value "codex"

    foreach ($candidate in $candidates) {
        $resolved = Test-CodexCommand -Candidate $candidate
        if ($resolved) {
            return $resolved
        }
    }

    throw "No runnable Codex CLI was found. Install Codex CLI or pass -CodexCommand with a working executable path."
}

function Get-UniqueDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $candidate = Join-Path $Directory $FileName
    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext = [System.IO.Path]::GetExtension($FileName)
    for ($i = 1; $i -lt 1000; $i++) {
        $candidate = Join-Path $Directory ("{0}-{1}{2}" -f $base, $i, $ext)
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw "Could not choose a destination filename for '$FileName'."
}

function Stop-ProcessTree {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    try {
        foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)) {
            Stop-ProcessTree -ProcessId $child.ProcessId
        }
    } catch {
        Write-Verbose "Could not enumerate child processes for ${ProcessId}: $($_.Exception.Message)"
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "Could not stop process ${ProcessId}: $($_.Exception.Message)"
    }
}

function Invoke-CodexWithStdin {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][string]$Directory,
        [int]$TimeoutSeconds = 900
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Command
    $psi.Arguments = ($Arguments -join " ")
    $psi.WorkingDirectory = $Directory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $process.StandardInput.Write($InputText)
    $process.StandardInput.Close()

    if ($TimeoutSeconds -gt 0) {
        if (-not $process.WaitFor($TimeoutSeconds * 1000)) {
            Write-Warning "Codex CLI timed out after $TimeoutSeconds seconds. Stopping the process and scanning for generated images."
            Stop-ProcessTree -ProcessId $process.Id
            return [pscustomobject]@{ ExitCode = 124; TimedOut = $true }
        }
    } else {
        $process.WaitForExit()
    }

    return [pscustomobject]@{ ExitCode = $process.ExitCode; TimedOut = $false }
}

$codex = Resolve-CodexCommand -ExplicitCommand $CodexCommand
$CodexCommand = $codex.Path

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$resolvedOutDir = (Resolve-Path -LiteralPath $OutDir).Path
$resolvedWorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$generatedImagesDir = Join-Path (Get-CodexHome) "generated_images"

Write-Host "Codex CLI: $CodexCommand"
if ($codex.Version) {
    Write-Host "Codex CLI version: $($codex.Version)"
}
Write-Host "Output directory: $resolvedOutDir"
Write-Host "Working directory: $resolvedWorkDir"

if ($LoginFirst) {
    & $CodexCommand login
    if ($LASTEXITCODE -ne 0) {
        throw "codex login failed with exit code $LASTEXITCODE."
    }
}

if ($CheckOnly) {
    try {
        & $CodexCommand login status
    } catch {
        Write-Warning "Could not check login status: $($_.Exception.Message)"
    }
    if (-not $NoGeneratedImagesFallback) {
        Write-Host "Generated-images fallback: $generatedImagesDir"
    }
    exit 0
}

$before = @{}
foreach ($file in Get-ImageFiles -Directory $resolvedOutDir) {
    $before[$file.FullName] = $true
}
if (-not $NoGeneratedImagesFallback) {
    foreach ($file in Get-ImageFiles -Directory $generatedImagesDir) {
        $before[$file.FullName] = $true
    }
}

$message = @"
`$imagegen
Generate the requested image using Codex CLI's built-in image generation.
Save the final image file under this absolute directory:
$resolvedOutDir

User prompt:
$Prompt

After saving, print the absolute path of each created image file. Do not embed image bytes or base64 data in the final response.
"@

if ($ExtraInstruction.Trim().Length -gt 0) {
    $message = "$message`n`nAdditional instruction:`n$ExtraInstruction"
}

$started = Get-Date
Push-Location -LiteralPath $resolvedWorkDir
$exitCode = 0
$timedOut = $false
try {
    if ($Interactive) {
        $codexArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($ApprovalPolicy)) { $codexArgs += @("-a", $ApprovalPolicy) }
        if (-not [string]::IsNullOrWhiteSpace($Sandbox)) { $codexArgs += @("-s", $Sandbox) }
        $codexArgs += $message
        & $CodexCommand @codexArgs
        $exitCode = $LASTEXITCODE
    } else {
        $codexArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($ApprovalPolicy)) { $codexArgs += @("-a", $ApprovalPolicy) }
        if (-not [string]::IsNullOrWhiteSpace($Sandbox)) { $codexArgs += @("-s", $Sandbox) }
        $codexArgs += "exec"
        if (-not $NoSkipGitRepoCheck) { $codexArgs += "--skip-git-repo-check" }
        $codexArgs += "-"
        $result = Invoke-CodexWithStdin -Command $CodexCommand -Arguments $codexArgs -InputText $message -Directory $resolvedWorkDir -TimeoutSeconds $TimeoutSeconds
        $exitCode = $result.ExitCode
        $timedOut = $result.TimedOut
    }
} finally {
    Pop-Location
}

$newFiles = New-Object System.Collections.Generic.List[object]
foreach ($file in @(Get-ImageFiles -Directory $resolvedOutDir |
        Where-Object { -not $before.ContainsKey($_.FullName) -and $_.LastWriteTime -ge $started.AddSeconds(-2) })) {
    $newFiles.Add($file) | Out-Null
}

if (-not $NoGeneratedImagesFallback) {
    foreach ($file in @(Get-ImageFiles -Directory $generatedImagesDir |
            Where-Object { -not $before.ContainsKey($_.FullName) -and $_.LastWriteTime -ge $started.AddSeconds(-2) })) {
        $destination = Get-UniqueDestination -Directory $resolvedOutDir -FileName $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        $newFiles.Add((Get-Item -LiteralPath $destination)) | Out-Null
    }
}

if ($newFiles.Count -eq 0) {
    if ($exitCode -ne 0) {
        throw "Codex CLI failed with exit code $exitCode."
    }

    Write-Warning "No new image files were detected under '$resolvedOutDir'. Check the Codex CLI output for the actual saved path."
    exit 0
}

$newFiles | Sort-Object LastWriteTime | ForEach-Object { $_.FullName }

if ($exitCode -ne 0) {
    if ($timedOut) {
        Write-Warning "Codex CLI timed out after image files were detected; treating detected files as the result."
        exit 0
    }

    Write-Warning "Codex CLI exited with code $exitCode after image files were detected."
    exit $exitCode
}
