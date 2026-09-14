#Requires -Version 5.1
<#
.SYNOPSIS
  Stage Moqi IM for Windows binaries and invoke the installer builder.

  Does not install files into Program Files directly. Instead it prepares an
  installer stage tree and calls installer\build-installer.ps1 to produce the
  setup executable.

.PARAMETER RepoRoot
  Root of moqi-im-windows (defaults to the parent directory of this script).

.PARAMETER Win32BuildDir
  CMake Win32 build directory (default: RepoRoot\build-vs32).

.PARAMETER X64BuildDir
  CMake x64 build directory (default: RepoRoot\build-vs64).

.PARAMETER Arm64BuildDir
  CMake ARM64 build directory (default: RepoRoot\build-vsarm64). Must contain
  MoqiTextService.dll and MoqiTextServiceARM64X.dll unless -SkipArm64 is set.

.PARAMETER SkipArm64
  Produce an x64/x86-only installer without the ARM64 payload and without the
  architecture-split moqi-ime backends.

.PARAMETER MoqiImeSource
  Path to the x64 (amd64) moqi-ime runtime tree to copy as backend.
  Default detection order:
    1. sibling ..\moqi-ime\scripts\build\moqi-ime-amd64
    2. sibling ..\moqi-ime\scripts\build\moqi-ime
    3. sibling ..\moqi-ime

.PARAMETER MoqiImeArm64Source
  Path to the ARM64 moqi-ime runtime tree. Only server.exe is taken from it.
  Default detection order:
    1. sibling ..\moqi-ime\scripts\build\moqi-ime-arm64
    2. sibling ..\moqi-ime-arm64

.PARAMETER SkipMoqiImeCopy
  If set, do not include the backend tree in the staged installer payload.

.PARAMETER StageDir
  Installer staging directory (default: RepoRoot\installer\stage).

.PARAMETER IssPath
  Optional path to the Inno Setup script (default: RepoRoot\installer\MoqiTsf.iss).
#>
param(
    [string] $RepoRoot = "",
    [string] $Win32BuildDir = "",
    [string] $X64BuildDir = "",
    [string] $Arm64BuildDir = "",
    [switch] $SkipArm64,
    [string] $MoqiImeSource = "",
    [string] $MoqiImeArm64Source = "",
    [switch] $SkipMoqiImeCopy,
    [string] $StageDir = "",
    [string] $IssPath = ""
)

$ErrorActionPreference = "Stop"

function New-CleanDirectory {
    param([string] $Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Copy-IfExists {
    param(
        [string] $Source,
        [string] $Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Required file not found: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Resolve-ArtifactPath {
    param(
        [string[]] $Candidates,
        [string] $Label
    )

    $existingCandidates = foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate) {
            Get-Item -LiteralPath $candidate
        }
    }

    if (-not $existingCandidates) {
        throw "$Label not found. Checked: $($Candidates -join ', ')"
    }

    $selected = $existingCandidates |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

    Write-Host ("Using {0}: {1} ({2})" -f $Label, $selected.FullName, $selected.LastWriteTime)
    return $selected.FullName
}

function Get-PEMachine {
    param([string] $Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        return $null
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -le 0 -or ($peOffset + 6) -gt $bytes.Length) {
        return $null
    }
    return [BitConverter]::ToUInt16($bytes, $peOffset + 4)
}

function Assert-PEMachine {
    param(
        [string] $Path,
        [UInt16] $Machine,
        [string] $Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }
    $actual = Get-PEMachine -Path $Path
    if ($null -eq $actual) {
        throw "$Label is not a valid PE file: $Path"
    }
    if ($actual -ne $Machine) {
        throw ("{0} has unexpected PE machine type 0x{1:X4} (expected 0x{2:X4}): {3}" -f $Label, $actual, $Machine, $Path)
    }
    Write-Host ("Verified {0} (machine 0x{1:X4}): {2}" -f $Label, $actual, $Path)
}

function Resolve-MoqiImeSource {
    param(
        [string] $RepoRoot,
        [string] $RequestedSource
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedSource)) {
        return [System.IO.Path]::GetFullPath($RequestedSource)
    }

    $candidates = @(
        (Join-Path $RepoRoot "..\moqi-ime\scripts\build\moqi-ime-amd64"),
        (Join-Path $RepoRoot "..\moqi-ime\scripts\build\moqi-ime"),
        (Join-Path $RepoRoot "..\moqi-ime")
    )

    foreach ($candidate in $candidates) {
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
        if (Test-Path -LiteralPath (Join-Path $fullPath "server.exe")) {
            return $fullPath
        }
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot "..\moqi-ime\scripts\build\moqi-ime"))
}

function Resolve-MoqiImeArm64Source {
    param(
        [string] $RepoRoot,
        [string] $RequestedSource
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedSource)) {
        return [System.IO.Path]::GetFullPath($RequestedSource)
    }

    $candidates = @(
        (Join-Path $RepoRoot "..\moqi-ime\scripts\build\moqi-ime-arm64"),
        (Join-Path $RepoRoot "..\moqi-ime-arm64")
    )

    foreach ($candidate in $candidates) {
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
        if (Test-Path -LiteralPath (Join-Path $fullPath "server.exe")) {
            return $fullPath
        }
    }

    return ""
}

function Copy-MoqiImeRuntime {
    param(
        [string] $SourceRoot,
        [string] $DestinationRoot
    )

    $serverExe = Join-Path $SourceRoot "server.exe"
    if (-not (Test-Path -LiteralPath $serverExe)) {
        throw "moqi-ime server.exe not found: $serverExe"
    }

    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null

    $directories = Get-ChildItem -Path $SourceRoot -Recurse -Force -Directory |
    Where-Object { $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' }
    foreach ($directory in $directories) {
        $relativePath = $directory.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $targetDir = Join-Path $DestinationRoot $relativePath
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $files = Get-ChildItem -Path $SourceRoot -Recurse -Force -File | Where-Object {
        $_.Extension -ne ".go" -and $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)'
    }
    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $targetPath = Join-Path $DestinationRoot $relativePath
        $targetDir = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $file.FullName -Destination $targetPath -Force
    }
}

$scriptRepoRoot = Join-Path $PSScriptRoot ".."
if (-not $RepoRoot) { $RepoRoot = $scriptRepoRoot }
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

if (-not $Win32BuildDir) { $Win32BuildDir = Join-Path $RepoRoot "build-vs32" }
if (-not $X64BuildDir) { $X64BuildDir = Join-Path $RepoRoot "build-vs64" }
if (-not $Arm64BuildDir) { $Arm64BuildDir = Join-Path $RepoRoot "build-vsarm64" }
$MoqiImeSource = Resolve-MoqiImeSource -RepoRoot $RepoRoot -RequestedSource $MoqiImeSource
if (-not $StageDir) { $StageDir = Join-Path $RepoRoot "installer\stage" }
if (-not $IssPath) { $IssPath = Join-Path $RepoRoot "installer\MoqiTsf.iss" }
$Win32BuildDir = [System.IO.Path]::GetFullPath($Win32BuildDir)
$X64BuildDir = [System.IO.Path]::GetFullPath($X64BuildDir)
$Arm64BuildDir = [System.IO.Path]::GetFullPath($Arm64BuildDir)
$StageDir = [System.IO.Path]::GetFullPath($StageDir)
$IssPath = [System.IO.Path]::GetFullPath($IssPath)

$MoqiImeArm64Source = ""
if (-not $SkipArm64) {
    if ($SkipMoqiImeCopy) {
        throw "-SkipMoqiImeCopy cannot be combined with the ARM64 payload: the ARM64 installer needs the architecture-split server.exe files. Also pass -SkipArm64 for an x64/x86-only payload."
    }
    $MoqiImeArm64Source = Resolve-MoqiImeArm64Source -RepoRoot $RepoRoot -RequestedSource $MoqiImeArm64Source
    if (-not $MoqiImeArm64Source) {
        throw "ARM64 moqi-ime runtime not found. Build it with GOARCH=arm64 or pass -MoqiImeArm64Source (or use -SkipArm64)."
    }
}

$stageWin32Root = Join-Path $StageDir "win32\MoqiIM"
$stageX64Root = Join-Path $StageDir "x64\MoqiIM"
$stageWin32X64Root = Join-Path $stageWin32Root "x64"
New-CleanDirectory -Path $StageDir
New-Item -ItemType Directory -Path $stageWin32Root -Force | Out-Null
New-Item -ItemType Directory -Path $stageX64Root -Force | Out-Null
New-Item -ItemType Directory -Path $stageWin32X64Root -Force | Out-Null

$backends = Join-Path $RepoRoot "backends.json"
if (-not (Test-Path -LiteralPath $backends)) {
    throw "Missing backends.json at $backends"
}
Copy-Item -LiteralPath $backends -Destination (Join-Path $stageWin32Root "backends.json") -Force

$launcher = Resolve-ArtifactPath -Label "MoqiLauncher.exe" -Candidates @(
    (Join-Path $Win32BuildDir "MoqiLauncher.exe"),
    (Join-Path $Win32BuildDir "Release\MoqiLauncher.exe"),
    (Join-Path $Win32BuildDir "MoqLauncher\Release\MoqiLauncher.exe")
)
Copy-IfExists -Source $launcher -Destination (Join-Path $stageWin32Root "MoqiLauncher.exe")
Assert-PEMachine -Path (Join-Path $stageWin32Root "MoqiLauncher.exe") -Machine 0x14C -Label "Win32 MoqiLauncher.exe"

$setupHelper = Resolve-ArtifactPath -Label "SetupHelper.exe" -Candidates @(
    (Join-Path $Win32BuildDir "SetupHelper.exe"),
    (Join-Path $Win32BuildDir "Release\SetupHelper.exe"),
    (Join-Path $Win32BuildDir "SetupHelper\Release\SetupHelper.exe")
)
Copy-IfExists -Source $setupHelper -Destination (Join-Path $stageWin32Root "SetupHelper.exe")
Assert-PEMachine -Path (Join-Path $stageWin32Root "SetupHelper.exe") -Machine 0x14C -Label "Win32 SetupHelper.exe"

$dll32 = Resolve-ArtifactPath -Label "Win32 MoqiTextService.dll" -Candidates @(
    (Join-Path $Win32BuildDir "MoqiTextService.dll"),
    (Join-Path $Win32BuildDir "Release\MoqiTextService.dll"),
    (Join-Path $Win32BuildDir "MoqiTextService\Release\MoqiTextService.dll")
)
Copy-IfExists -Source $dll32 -Destination (Join-Path $stageWin32Root "MoqiTextService.dll")
Assert-PEMachine -Path (Join-Path $stageWin32Root "MoqiTextService.dll") -Machine 0x14C -Label "Win32 MoqiTextService.dll"

$dll64 = Resolve-ArtifactPath -Label "x64 MoqiTextService.dll" -Candidates @(
    (Join-Path $X64BuildDir "MoqiTextService.dll"),
    (Join-Path $X64BuildDir "Release\MoqiTextService.dll"),
    (Join-Path $X64BuildDir "MoqiTextService\Release\MoqiTextService.dll")
)
Copy-IfExists -Source $dll64 -Destination (Join-Path $stageX64Root "MoqiTextService.dll")
Copy-IfExists -Source $dll64 -Destination (Join-Path $stageWin32X64Root "MoqiTextService.dll")
Assert-PEMachine -Path (Join-Path $stageX64Root "MoqiTextService.dll") -Machine 0x8664 -Label "x64 MoqiTextService.dll"

if (-not $SkipArm64) {
    $stageWin32Arm64Root = Join-Path $stageWin32Root "arm64"
    New-Item -ItemType Directory -Path $stageWin32Arm64Root -Force | Out-Null

    $dllArm64 = Resolve-ArtifactPath -Label "ARM64 MoqiTextService.dll" -Candidates @(
        (Join-Path $Arm64BuildDir "MoqiTextService.dll"),
        (Join-Path $Arm64BuildDir "Release\MoqiTextService.dll"),
        (Join-Path $Arm64BuildDir "MoqiTextService\Release\MoqiTextService.dll")
    )
    $dllArm64X = Resolve-ArtifactPath -Label "ARM64X MoqiTextServiceARM64X.dll" -Candidates @(
        (Join-Path $Arm64BuildDir "MoqiTextServiceARM64X.dll")
    )
    Copy-IfExists -Source $dllArm64 -Destination (Join-Path $stageWin32Arm64Root "MoqiTextService.dll")
    Copy-IfExists -Source $dllArm64X -Destination (Join-Path $stageWin32Arm64Root "MoqiTextServiceARM64X.dll")
    Assert-PEMachine -Path (Join-Path $stageWin32Arm64Root "MoqiTextService.dll") -Machine 0xAA64 -Label "ARM64 MoqiTextService.dll"
    Assert-PEMachine -Path (Join-Path $stageWin32Arm64Root "MoqiTextServiceARM64X.dll") -Machine 0xAA64 -Label "ARM64X MoqiTextServiceARM64X.dll"
}

if (-not $SkipMoqiImeCopy) {
    if (-not (Test-Path -LiteralPath $MoqiImeSource)) {
        throw "Moqi IME source not found: $MoqiImeSource (use -MoqiImeSource or -SkipMoqiImeCopy)."
    }
    $imeDest = Join-Path $stageWin32Root "moqi-ime"
    Copy-MoqiImeRuntime -SourceRoot $MoqiImeSource -DestinationRoot $imeDest

    if (-not $SkipArm64) {
        $arm64Server = Join-Path $MoqiImeArm64Source "server.exe"
        Assert-PEMachine -Path (Join-Path $imeDest "server.exe") -Machine 0x8664 -Label "amd64 server.exe"
        Assert-PEMachine -Path $arm64Server -Machine 0xAA64 -Label "arm64 server.exe"
        Copy-Item -LiteralPath (Join-Path $imeDest "server.exe") -Destination (Join-Path $StageDir "server-amd64.exe") -Force
        Copy-Item -LiteralPath $arm64Server -Destination (Join-Path $StageDir "server-arm64.exe") -Force
        Remove-Item -LiteralPath (Join-Path $imeDest "server.exe") -Force
    }
}
else {
    Write-Warning "Skipped copying moqi-ime backend; ensure the final installer payload is sufficient for your deployment."
}

$installerScript = Join-Path $RepoRoot "installer\build-installer.ps1"
if (-not (Test-Path -LiteralPath $installerScript)) {
    throw "Installer builder script not found: $installerScript"
}
if (-not (Test-Path -LiteralPath $IssPath)) {
    throw "Installer ISS file not found: $IssPath"
}

Write-Host "Stage prepared at: $StageDir"
Write-Host "Win32 payload: $stageWin32Root"
Write-Host "x64 payload: $stageX64Root"
if (-not $SkipArm64) {
    Write-Host "ARM64 payload: $(Join-Path $stageWin32Root 'arm64')"
}

& $installerScript -StageDir $StageDir -IssPath $IssPath

Write-Host "Installer build finished."
