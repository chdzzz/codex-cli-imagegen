param(
    [Parameter(Mandatory = $true)]
    [string]$Prompt,

    [string]$OutDir = (Join-Path (Get-Location) "codex-imagegen-output"),

    [string]$CodexCommand = "",

    [switch]$LoginFirst,

    [switch]$Interactive,

    [string]$ExtraInstruction = "",

    [string]$RequestedSize = "",

    [switch]$RequireExactSize,

    [string]$WorkDir = (Get-Location).Path,

    [string]$ApprovalPolicy = "never",

    [string]$Sandbox = "danger-full-access",

    [bool]$DisablePlugins = $true,

    [int]$TimeoutSeconds = 900,

    [int]$PollSeconds = 5,

    [int]$StableSeconds = 3,

    [switch]$NoEarlyExitOnImage,

    [string]$ChildCodexHome = "",

    [switch]$NoIsolatedCodexHome,

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

function Join-PathParts {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Parts
    )

    $path = $Root
    foreach ($part in $Parts) {
        $path = Join-Path $path $part
    }

    return $path
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

function ConvertFrom-BigEndianUInt16 {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset
    )

    return ((([int]$Bytes[$Offset]) -shl 8) -bor ([int]$Bytes[$Offset + 1]))
}

function ConvertFrom-BigEndianUInt32 {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset
    )

    return ((([int]$Bytes[$Offset]) -shl 24) -bor (([int]$Bytes[$Offset + 1]) -shl 16) -bor (([int]$Bytes[$Offset + 2]) -shl 8) -bor ([int]$Bytes[$Offset + 3]))
}

function ConvertFrom-LittleEndianUInt24 {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset
    )

    return (([int]$Bytes[$Offset]) -bor (([int]$Bytes[$Offset + 1]) -shl 8) -bor (([int]$Bytes[$Offset + 2]) -shl 16))
}

function Get-ImageDimensions {
    param([Parameter(Mandatory = $true)]$File)

    $path = if ($File -is [string]) { $File } else { $File.FullName }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 24) {
        return $null
    }

    $isPng = ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47)
    if ($isPng -and $bytes.Length -ge 24) {
        return [pscustomobject]@{
            Width  = ConvertFrom-BigEndianUInt32 -Bytes $bytes -Offset 16
            Height = ConvertFrom-BigEndianUInt32 -Bytes $bytes -Offset 20
        }
    }

    $isJpeg = ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8)
    if ($isJpeg) {
        $offset = 2
        while ($offset -lt ($bytes.Length - 9)) {
            while ($offset -lt $bytes.Length -and $bytes[$offset] -ne 0xFF) {
                $offset++
            }
            while ($offset -lt $bytes.Length -and $bytes[$offset] -eq 0xFF) {
                $offset++
            }
            if ($offset -ge $bytes.Length) {
                break
            }

            $marker = $bytes[$offset]
            $offset++
            if ($marker -eq 0xD9 -or $marker -eq 0xDA) {
                break
            }
            if ($offset + 1 -ge $bytes.Length) {
                break
            }

            $segmentLength = ConvertFrom-BigEndianUInt16 -Bytes $bytes -Offset $offset
            if ($segmentLength -lt 2 -or ($offset + $segmentLength) -gt $bytes.Length) {
                break
            }

            if (($marker -ge 0xC0 -and $marker -le 0xC3) -or
                ($marker -ge 0xC5 -and $marker -le 0xC7) -or
                ($marker -ge 0xC9 -and $marker -le 0xCB) -or
                ($marker -ge 0xCD -and $marker -le 0xCF)) {
                return [pscustomobject]@{
                    Width  = ConvertFrom-BigEndianUInt16 -Bytes $bytes -Offset ($offset + 5)
                    Height = ConvertFrom-BigEndianUInt16 -Bytes $bytes -Offset ($offset + 3)
                }
            }

            $offset += $segmentLength
        }
    }

    $isWebp = ($bytes.Length -ge 30 -and
        [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq "RIFF" -and
        [System.Text.Encoding]::ASCII.GetString($bytes, 8, 4) -eq "WEBP")
    if ($isWebp) {
        $chunkType = [System.Text.Encoding]::ASCII.GetString($bytes, 12, 4)
        if ($chunkType -eq "VP8X" -and $bytes.Length -ge 30) {
            return [pscustomobject]@{
                Width  = (ConvertFrom-LittleEndianUInt24 -Bytes $bytes -Offset 24) + 1
                Height = (ConvertFrom-LittleEndianUInt24 -Bytes $bytes -Offset 27) + 1
            }
        }
    }

    return $null
}

function Resolve-RequestedDimensions {
    param(
        [string]$RequestedSize,
        [string]$Prompt
    )

    $candidate = $RequestedSize
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $match = [regex]::Match($Prompt, "(?i)\b(?<width>\d{1,5})\s*[x×]\s*(?<height>\d{1,5})\b")
        if ($match.Success) {
            $candidate = "$($match.Groups["width"].Value)x$($match.Groups["height"].Value)"
        } elseif ($Prompt -match "(?i)\b4k\b") {
            if ($Prompt -match "(?i)portrait|vertical") {
                $candidate = "2160x3840"
            } else {
                $candidate = "3840x2160"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    $sizeMatch = [regex]::Match($candidate, "^\s*(?<width>\d{1,5})\s*[x×]\s*(?<height>\d{1,5})\s*$")
    if (-not $sizeMatch.Success) {
        throw "Requested size '$candidate' is invalid. Use WIDTHxHEIGHT, for example 3840x2160."
    }

    return [pscustomobject]@{
        Width  = [int]$sizeMatch.Groups["width"].Value
        Height = [int]$sizeMatch.Groups["height"].Value
        Text   = "{0}x{1}" -f $sizeMatch.Groups["width"].Value, $sizeMatch.Groups["height"].Value
    }
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

function Initialize-ChildCodexHome {
    param(
        [Parameter(Mandatory = $true)][string]$ParentCodexHome,
        [string]$RequestedChildCodexHome,
        [switch]$NoIsolated
    )

    if ($NoIsolated) {
        return (Get-FullPath -Path $ParentCodexHome)
    }

    if ([string]::IsNullOrWhiteSpace($RequestedChildCodexHome)) {
        $RequestedChildCodexHome = Join-Path $ParentCodexHome ".codex-cli-imagegen-isolated-home"
    }

    New-Item -ItemType Directory -Path $RequestedChildCodexHome -Force | Out-Null
    $resolvedChildCodexHome = (Resolve-Path -LiteralPath $RequestedChildCodexHome).Path

    $authPath = Join-Path $ParentCodexHome "auth.json"
    if (Test-Path -LiteralPath $authPath -PathType Leaf) {
        Copy-Item -LiteralPath $authPath -Destination (Join-Path $resolvedChildCodexHome "auth.json") -Force
    }

    $configPath = Join-Path $resolvedChildCodexHome "config.toml"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        @"
[features]
image_generation = true
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8
    }

    return $resolvedChildCodexHome
}

function Invoke-CodexCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$CodexHome
    )

    $oldCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $CodexHome
        & $Command @Arguments
        return $LASTEXITCODE
    } finally {
        if ($null -eq $oldCodexHome) {
            Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue
        } else {
            $env:CODEX_HOME = $oldCodexHome
        }
    }
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

    Add-Candidate -Candidates $Candidates -Value (Join-PathParts -Root $Root -Parts @("packages", "standalone", "current", "bin", "codex.exe"))
    Add-Candidate -Candidates $Candidates -Value (Join-PathParts -Root $Root -Parts @("packages", "standalone", "current", "codex.exe"))
    Add-Candidate -Candidates $Candidates -Value (Join-PathParts -Root $Root -Parts @("packages", "standalone", "current", "bin", "codex"))
    Add-Candidate -Candidates $Candidates -Value (Join-PathParts -Root $Root -Parts @("packages", "standalone", "current", "codex"))

    $releasesDir = Join-PathParts -Root $Root -Parts @("packages", "standalone", "releases")
    if (Test-Path -LiteralPath $releasesDir -PathType Container) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $releasesDir -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)) {
            Add-Candidate -Candidates $Candidates -Value (Join-PathParts -Root $dir.FullName -Parts @("bin", "codex.exe"))
            Add-Candidate -Candidates $Candidates -Value (Join-Path $dir.FullName "codex.exe")
            Add-Candidate -Candidates $Candidates -Value (Join-PathParts -Root $dir.FullName -Parts @("bin", "codex"))
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
        Add-Candidate -Candidates $candidates -Value (Join-PathParts -Root $homeDir -Parts @(".local", "bin", "codex"))
        Add-Candidate -Candidates $candidates -Value (Join-PathParts -Root $homeDir -Parts @(".codex", "bin", "codex"))
        Add-Candidate -Candidates $candidates -Value (Join-PathParts -Root $homeDir -Parts @(".codex", "bin", "codex.exe"))
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $versionedBin = Join-PathParts -Root $env:LOCALAPPDATA -Parts @("OpenAI", "Codex", "bin")
        if (Test-Path -LiteralPath $versionedBin -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $versionedBin -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter "codex.exe" -File -ErrorAction SilentlyContinue } |
                    Sort-Object LastWriteTime -Descending)) {
                Add-Candidate -Candidates $candidates -Value $file.FullName
            }
        }

        Add-Candidate -Candidates $candidates -Value (Join-PathParts -Root $env:LOCALAPPDATA -Parts @("OpenAI", "Codex", "bin", "codex.exe"))
        Add-Candidate -Candidates $candidates -Value (Join-PathParts -Root $env:LOCALAPPDATA -Parts @("Programs", "OpenAI", "Codex", "bin", "codex.exe"))
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        Add-Candidate -Candidates $candidates -Value (Join-PathParts -Root $env:ProgramFiles -Parts @("OpenAI", "Codex", "bin", "codex.exe"))
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

function Get-ChildProcessIds {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $ids = New-Object System.Collections.Generic.List[int]

    if (Test-IsWindows) {
        $getCim = Get-Command Get-CimInstance -ErrorAction SilentlyContinue
        if ($getCim) {
            try {
                foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)) {
                    if ($child.ProcessId -and $child.ProcessId -ne $ProcessId) {
                        $ids.Add([int]$child.ProcessId) | Out-Null
                    }
                }
            } catch {
                Write-Verbose "Could not enumerate child processes for ${ProcessId}: $($_.Exception.Message)"
            }
        }

        return $ids.ToArray()
    }

    $pgrep = Get-Command pgrep -ErrorAction SilentlyContinue
    if ($pgrep) {
        try {
            foreach ($line in @(& $pgrep.Source -P $ProcessId 2> $null)) {
                $childId = 0
                if ([int]::TryParse(([string]$line).Trim(), [ref]$childId) -and $childId -ne $ProcessId) {
                    $ids.Add($childId) | Out-Null
                }
            }

            return $ids.ToArray()
        } catch {
            Write-Verbose "pgrep failed for ${ProcessId}: $($_.Exception.Message)"
        }
    }

    $ps = Get-Command ps -ErrorAction SilentlyContinue
    if ($ps) {
        try {
            foreach ($line in @(& $ps.Source -o pid= -ppid $ProcessId 2> $null)) {
                $childId = 0
                if ([int]::TryParse(([string]$line).Trim(), [ref]$childId) -and $childId -ne $ProcessId) {
                    $ids.Add($childId) | Out-Null
                }
            }
        } catch {
            Write-Verbose "ps child process lookup failed for ${ProcessId}: $($_.Exception.Message)"
        }
    }

    return $ids.ToArray()
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

    foreach ($childId in @(Get-ChildProcessIds -ProcessId $ProcessId)) {
        Stop-ProcessTree -ProcessId $childId
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
        [Parameter(Mandatory = $true)][string]$CodexHome,
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
    $psi.EnvironmentVariables["CODEX_HOME"] = $CodexHome
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
$requestedDimensions = Resolve-RequestedDimensions -RequestedSize $RequestedSize -Prompt $Prompt
$parentCodexHome = Get-CodexHome
$childCodexHomeResolved = Initialize-ChildCodexHome -ParentCodexHome $parentCodexHome -RequestedChildCodexHome $ChildCodexHome -NoIsolated:$NoIsolatedCodexHome
if (-not $CheckOnly) {
    New-Item -ItemType Directory -Path $resolvedOutDir -Force | Out-Null
    $resolvedOutDir = (Resolve-Path -LiteralPath $resolvedOutDir).Path
}

$generatedImagesDirs = @()
if (-not $NoGeneratedImagesFallback) {
    $generatedImagesDirs += (Join-Path $childCodexHomeResolved "generated_images")
}

Write-Host "Codex CLI: $CodexCommand"
if ($codex.Version) {
    Write-Host "Codex CLI version: $($codex.Version)"
}
Write-Host "Output directory: $resolvedOutDir"
Write-Host "Working directory: $resolvedWorkDir"
Write-Host "Child CODEX_HOME: $childCodexHomeResolved"
if ($requestedDimensions) {
    Write-Host "Requested native size: $($requestedDimensions.Text)"
}

if ($LoginFirst) {
    $loginExitCode = Invoke-CodexCommand -Command $CodexCommand -Arguments @("login") -CodexHome $childCodexHomeResolved
    if ($loginExitCode -ne 0) {
        throw "codex login failed with exit code $loginExitCode."
    }
}

if ($CheckOnly) {
    try {
        [void](Invoke-CodexCommand -Command $CodexCommand -Arguments @("login", "status") -CodexHome $childCodexHomeResolved)
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

$resolutionInstruction = ""
if ($requestedDimensions) {
    $resolutionInstruction = @"

Native resolution requirement:
- Create the image at exactly $($requestedDimensions.Text) pixels.
- This must be the actual image metadata size, not a post-upscaled or resized copy.
- If the built-in image generator exposes any size or resolution control, use $($requestedDimensions.Text) directly.
"@
}

$message = @"
`$imagegen
Generate the requested image using Codex CLI's built-in image generation.
Save the final image file under this absolute directory:
$resolvedOutDir
$resolutionInstruction

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
        if ($DisablePlugins) { $codexArgs += @("--disable", "plugins") }
        if (-not [string]::IsNullOrWhiteSpace($ApprovalPolicy)) { $codexArgs += @("-a", $ApprovalPolicy) }
        if (-not [string]::IsNullOrWhiteSpace($Sandbox)) { $codexArgs += @("-s", $Sandbox) }
        $codexArgs += $message
        $exitCode = Invoke-CodexCommand -Command $CodexCommand -Arguments $codexArgs -CodexHome $childCodexHomeResolved
    } else {
        $codexArgs = @()
        if ($DisablePlugins) { $codexArgs += @("--disable", "plugins") }
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
            -CodexHome $childCodexHomeResolved `
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

$sortedNewFiles = @($newFiles | Sort-Object LastWriteTime)
$matchingSizeCount = 0
foreach ($file in $sortedNewFiles) {
    $dimensions = Get-ImageDimensions -File $file
    if ($dimensions) {
        Write-Host ("Image dimensions: {0}x{1} {2}" -f $dimensions.Width, $dimensions.Height, $file.FullName)
        if ($requestedDimensions -and $dimensions.Width -eq $requestedDimensions.Width -and $dimensions.Height -eq $requestedDimensions.Height) {
            $matchingSizeCount++
        }
    } else {
        Write-Warning "Could not read image dimensions for '$($file.FullName)'."
    }

    $file.FullName
}

if ($requestedDimensions -and $matchingSizeCount -eq 0) {
    $message = "No generated image matched requested native size $($requestedDimensions.Text). Codex CLI may have ignored the resolution request."
    if ($RequireExactSize) {
        throw $message
    }

    Write-Warning $message
}

if ($exitCode -ne 0) {
    if ($timedOut) {
        Write-Warning "Codex CLI timed out after image files were detected; treating detected files as the result."
        exit 0
    }

    Write-Warning "Codex CLI exited with code $exitCode after image files were detected."
    exit $exitCode
}
