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

    [int]$PollSeconds = 5,

    [int]$StableSeconds = 3,

    [switch]$NoEarlyExitOnImage,

    [switch]$NoSkipGitRepoCheck,

    [switch]$NoGeneratedImagesFallback,

    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsWindows {
    return ($env:OS -eq "Windows_NT" -or [System.IO.Path]::DirectorySeparatorChar -eq "\")
}

function Get-HomeDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return $env:USERPROFILE
    }

    if (-not [string]::IsNullOrWhiteSpace($HOME)) {
        return $HOME
    }

    return [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
}

function Get-FullPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$BaseDirectory = (Get-Location).Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $trimChars = [char[]]@([char]92, [char]47)
    $leftFull = (Get-FullPath -Path $Left).TrimEnd($trimChars)
    $rightFull = (Get-FullPath -Path $Right).TrimEnd($trimChars)
    if (Test-IsWindows) {
        return $leftFull -ieq $rightFull
    }

    return $leftFull -ceq $rightFull
}

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

    $homeDir = Get-HomeDirectory
    if (-not [string]::IsNullOrWhiteSpace($homeDir)) {
        return (Join-Path $homeDir ".codex")
    }

    return ".codex"
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

function Add-CodexStandaloneCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Candidates,

        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }

    Add-Candidate -Candidates $Candidates -Value (Join-Path $Root "packages\standalone\current\bin\codex.exe")
    Add-Candidate -Candidates $Candidates -Value (Join-Path $Root "packages\standalone\current\codex.exe")
    Add-Candidate -Candidates $Candidates -Value (Join-Path $Root "packages/standalone/current/bin/codex")
    Add-Candidate -Candidates $Candidates -Value (Join-Path $Root "packages/standalone/current/codex")

    $releasesDir = Join-Path $Root "packages\standalone\releases"
    if (Test-Path -LiteralPath $releasesDir -PathType Container) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $releasesDir -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)) {
            Add-Candidate -Candidates $Candidates -Value (Join-Path $dir.FullName "bin\codex.exe")
            Add-Candidate -Candidates $Candidates -Value (Join-Path $dir.FullName "codex.exe")
            Add-Candidate -Candidates $Candidates -Value (Join-Path $dir.FullName "bin/codex")
            Add-Candidate -Candidates $Candidates -Value (Join-Path $dir.FullName "codex")
        }
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

    $codexHome = Get-CodexHome
    Add-CodexStandaloneCandidates -Candidates $candidates -Root $codexHome

    $homeDir = Get-HomeDirectory
    if (-not [string]::IsNullOrWhiteSpace($homeDir)) {
        Add-CodexStandaloneCandidates -Candidates $candidates -Root (Join-Path $homeDir ".codex")
        Add-Candidate -Candidates $candidates -Value (Join-Path $homeDir ".local/bin/codex")
        Add-Candidate -Candidates $candidates -Value (Join-Path $homeDir ".codex/bin/codex")
        Add-Candidate -Candidates $candidates -Value (Join-Path $homeDir ".codex\bin\codex.exe")
    }

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

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        Add-Candidate -Candidates $candidates -Value (Join-Path $env:ProgramFiles "OpenAI\Codex\bin\codex.exe")
    }

    Add-Candidate -Candidates $candidates -Value "/opt/homebrew/bin/codex"
    Add-Candidate -Candidates $candidates -Value "/usr/local/bin/codex"
    Add-Candidate -Candidates $candidates -Value "/usr/bin/codex"
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

function Test-StableImageFile {
    param(
        [Parameter(Mandatory = $true)]$File,
        [int]$StableSeconds = 3
    )

    try {
        $File.Refresh()
    } catch {
        return $false
    }

    if ($File.Length -le 0) {
        return $false
    }

    if ($StableSeconds -le 0) {
        return $true
    }

    return (((Get-Date) - $File.LastWriteTime).TotalSeconds -ge $StableSeconds)
}

function Test-NewImageCandidate {
    param(
        [Parameter(Mandatory = $true)]$File,
        [Parameter(Mandatory = $true)][hashtable]$Before,
        [Parameter(Mandatory = $true)][datetime]$Started,
        [int]$StableSeconds = 3
    )

    if ($Before.ContainsKey($File.FullName)) {
        return $false
    }

    if ($File.LastWriteTime -lt $Started.AddSeconds(-2)) {
        return $false
    }

    return (Test-StableImageFile -File $File -StableSeconds $StableSeconds)
}

function Get-NewResultFiles {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][hashtable]$Before,
        [Parameter(Mandatory = $true)][datetime]$Started,
        [string[]]$FallbackDirectories = @(),
        [int]$StableSeconds = 3
    )

    $newFiles = New-Object System.Collections.Generic.List[object]

    foreach ($file in @(Get-ImageFiles -Directory $OutputDirectory)) {
        if (Test-NewImageCandidate -File $file -Before $Before -Started $Started -StableSeconds $StableSeconds) {
            $Before[$file.FullName] = $true
            $newFiles.Add($file) | Out-Null
        }
    }

    foreach ($directory in $FallbackDirectories) {
        if ([string]::IsNullOrWhiteSpace($directory) -or -not (Test-Path -LiteralPath $directory)) {
            continue
        }

        if (Test-SamePath -Left $directory -Right $OutputDirectory) {
            continue
        }

        foreach ($file in @(Get-ImageFiles -Directory $directory)) {
            if (-not (Test-NewImageCandidate -File $file -Before $Before -Started $Started -StableSeconds $StableSeconds)) {
                continue
            }

            $destination = Get-UniqueDestination -Directory $OutputDirectory -FileName $file.Name
            Copy-Item -LiteralPath $file.FullName -Destination $destination
            $Before[$file.FullName] = $true
            $Before[$destination] = $true
            $newFiles.Add((Get-Item -LiteralPath $destination)) | Out-Null
        }
    }

    return $newFiles.ToArray()
}

function Stop-ProcessTree {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    if (Test-IsWindows) {
        $taskkill = Get-Command taskkill.exe -ErrorAction SilentlyContinue
        if ($taskkill) {
            try {
                & $taskkill.Source /PID $ProcessId /T /F *> $null
                return
            } catch {
                Write-Verbose "taskkill failed for ${ProcessId}: $($_.Exception.Message)"
            }
        }
    }

    $getCim = Get-Command Get-CimInstance -ErrorAction SilentlyContinue
    if ($getCim) {
        try {
            foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)) {
                Stop-ProcessTree -ProcessId $child.ProcessId
            }
        } catch {
            Write-Verbose "Could not enumerate child processes for ${ProcessId}: $($_.Exception.Message)"
        }
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "Could not stop process ${ProcessId}: $($_.Exception.Message)"
    }
}

function Join-CommandLineArguments {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $escapedArgs = foreach ($arg in $Arguments) {
        $text = [string]$arg
        if ($text.Length -eq 0) {
            '""'
        } elseif ($text -notmatch '[\s"]') {
            $text
        } else {
            $escaped = $text -replace '(\\*)"', '$1$1\"'
            $escaped = $escaped -replace '(\\+)$', '$1$1'
            '"' + $escaped + '"'
        }
    }

    return ($escapedArgs -join " ")
}

function Set-ProcessArguments {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$ProcessStartInfo,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if ($ProcessStartInfo.PSObject.Properties.Name -contains "ArgumentList") {
        foreach ($argument in $Arguments) {
            $ProcessStartInfo.ArgumentList.Add($argument)
        }
    } else {
        $ProcessStartInfo.Arguments = Join-CommandLineArguments -Arguments $Arguments
    }
}

function Set-ProcessUtf8Input {
    param([Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$ProcessStartInfo)

    if ($ProcessStartInfo.PSObject.Properties.Name -contains "StandardInputEncoding") {
        $ProcessStartInfo.StandardInputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
}

function Invoke-CodexWithStdin {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][hashtable]$Before,
        [Parameter(Mandatory = $true)][datetime]$Started,
        [string[]]$FallbackDirectories = @(),
        [int]$TimeoutSeconds = 900,
        [int]$PollSeconds = 5,
        [int]$StableSeconds = 3,
        [switch]$NoEarlyExitOnImage
    )

    if ($PollSeconds -lt 1) {
        $PollSeconds = 1
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Command
    Set-ProcessArguments -ProcessStartInfo $psi -Arguments $Arguments
    $psi.WorkingDirectory = $Directory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    Set-ProcessUtf8Input -ProcessStartInfo $psi

    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()

        $deadline = $null
        if ($TimeoutSeconds -gt 0) {
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        }

        while (-not $process.HasExited) {
            Start-Sleep -Seconds $PollSeconds

            if (-not $NoEarlyExitOnImage) {
                $detectedFiles = @(Get-NewResultFiles `
                        -OutputDirectory $OutputDirectory `
                        -Before $Before `
                        -Started $Started `
                        -FallbackDirectories $FallbackDirectories `
                        -StableSeconds $StableSeconds)

                if ($detectedFiles.Count -gt 0) {
                    Write-Warning "Detected generated image file(s) before Codex CLI exited. Stopping Codex CLI and treating detected files as the result."
                    Stop-ProcessTree -ProcessId $process.Id
                    return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; EarlyResult = $true; Files = $detectedFiles }
                }
            }

            if ($deadline -and (Get-Date) -ge $deadline) {
                Write-Warning "Codex CLI timed out after $TimeoutSeconds seconds. Stopping the process and scanning for generated images."
                Stop-ProcessTree -ProcessId $process.Id
                return [pscustomobject]@{ ExitCode = 124; TimedOut = $true; EarlyResult = $false; Files = @() }
            }
        }

        return [pscustomobject]@{ ExitCode = $process.ExitCode; TimedOut = $false; EarlyResult = $false; Files = @() }
    } finally {
        $process.Dispose()
    }
}

$codex = Resolve-CodexCommand -ExplicitCommand $CodexCommand
$CodexCommand = $codex.Path

$resolvedWorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$resolvedOutDir = Get-FullPath -Path $OutDir
if (-not $CheckOnly) {
    New-Item -ItemType Directory -Path $resolvedOutDir -Force | Out-Null
    $resolvedOutDir = (Resolve-Path -LiteralPath $resolvedOutDir).Path
}

$generatedImagesDirs = @()
if (-not $NoGeneratedImagesFallback) {
    $generatedImagesDirs += (Join-Path (Get-CodexHome) "generated_images")
}

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
        foreach ($directory in $generatedImagesDirs) {
            Write-Host "Generated-images fallback: $directory"
        }
    }
    exit 0
}

$before = @{}
foreach ($file in Get-ImageFiles -Directory $resolvedOutDir) {
    $before[$file.FullName] = $true
}
foreach ($directory in $generatedImagesDirs) {
    foreach ($file in Get-ImageFiles -Directory $directory) {
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
$newFiles = New-Object System.Collections.Generic.List[object]
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
        $result = Invoke-CodexWithStdin `
            -Command $CodexCommand `
            -Arguments $codexArgs `
            -InputText $message `
            -Directory $resolvedWorkDir `
            -OutputDirectory $resolvedOutDir `
            -Before $before `
            -Started $started `
            -FallbackDirectories $generatedImagesDirs `
            -TimeoutSeconds $TimeoutSeconds `
            -PollSeconds $PollSeconds `
            -StableSeconds $StableSeconds `
            -NoEarlyExitOnImage:$NoEarlyExitOnImage
        $exitCode = $result.ExitCode
        $timedOut = $result.TimedOut
        foreach ($file in @($result.Files)) {
            $newFiles.Add($file) | Out-Null
        }
    }
} finally {
    Pop-Location
}

foreach ($file in @(Get-NewResultFiles `
        -OutputDirectory $resolvedOutDir `
        -Before $before `
        -Started $started `
        -FallbackDirectories $generatedImagesDirs `
        -StableSeconds 0)) {
    $newFiles.Add($file) | Out-Null
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
