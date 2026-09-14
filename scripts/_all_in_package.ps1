#Requires -Version 5.1
<#
.SYNOPSIS
  One-click build for moqi-ime backend, moqi-im-windows binaries, and installer package.

.DESCRIPTION
  Builds the moqi-ime backend twice (x64 for Intel/AMD machines and ARM64 for
  Windows on ARM) plus the Win32/x64/ARM64 moqi-im-windows binaries, then
  produces a single installer that covers all architectures.

.PARAMETER RepoRoot
  Root of moqi-im-windows (defaults to the parent directory of this script).

.PARAMETER MoqiImeRoot
  Root of sibling moqi-ime repository (defaults to RepoRoot\..\moqi-ime).

.PARAMETER Configuration
  Build configuration for moqi-im-windows (default: Release).

.PARAMETER Generator
  CMake generator for moqi-im-windows (default: Visual Studio 17 2022).

.PARAMETER SkipArm64
  Skip all ARM64 builds and produce an x64/x86-only installer.

.PARAMETER ProtobufRoot
  Optional local protobuf/protoc install root forwarded to scripts\build.ps1.

.PARAMETER ProtobufSourceDir
  Optional local protobuf source tree forwarded to scripts\build.ps1.
#>
param(
    [string] $RepoRoot = "",
    [string] $MoqiImeRoot = "",
    [string] $Configuration = "Release",
    [string] $Generator = "Visual Studio 17 2022",
    [switch] $SkipArm64,
    [string] $ProtobufRoot = "",
    [string] $ProtobufSourceDir = ""
)

$ErrorActionPreference = "Stop"

function Invoke-Step {
    param(
        [string] $FilePath,
        [string[]] $ArgumentList,
        [string] $WorkingDirectory
    )

    Write-Host ">> $FilePath $($ArgumentList -join ' ')"
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        & $FilePath @ArgumentList
    } else {
        Push-Location $WorkingDirectory
        try {
            & $FilePath @ArgumentList
        }
        finally {
            Pop-Location
        }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath"
    }
}

$scriptRepoRoot = Join-Path $PSScriptRoot ".."
if (-not $RepoRoot) { $RepoRoot = $scriptRepoRoot }
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

if (-not $MoqiImeRoot) { $MoqiImeRoot = Join-Path $RepoRoot "..\moqi-ime" }
$MoqiImeRoot = [System.IO.Path]::GetFullPath($MoqiImeRoot)

$moqiImeBuildScript = Join-Path $MoqiImeRoot "scripts\build.ps1"
$windowsBuildScript = Join-Path $RepoRoot "scripts\build.ps1"
$windowsInstallScript = Join-Path $RepoRoot "scripts\install.ps1"

if (-not $ProtobufRoot) {
    $candidatePaths = @()
    $defaultRoot = "D:\a_dev\protoc-33.5-win64"
    if (Test-Path -LiteralPath $defaultRoot) {
        $candidatePaths += $defaultRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($env:MOQI_PROTOBUF_ROOT)) {
        $candidatePaths += $env:MOQI_PROTOBUF_ROOT
    }

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath (Join-Path $candidate "bin\protoc.exe")) {
            $ProtobufRoot = [System.IO.Path]::GetFullPath($candidate)
            break
        }
    }
}

if (-not $ProtobufSourceDir) {
    $candidatePaths = @()
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $cacheRoot = Join-Path $env:USERPROFILE ".cache\moqi-protobuf"
        $candidatePaths += @(
            (Join-Path $cacheRoot "protobuf-33.5"),
            (Join-Path $cacheRoot "protobuf-34.1"),
            (Join-Path $cacheRoot "protobuf-29.5")
        )
    }

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath (Join-Path $candidate "CMakeLists.txt")) {
            $ProtobufSourceDir = [System.IO.Path]::GetFullPath($candidate)
            break
        }
    }
}

if ($ProtobufSourceDir) {
    Write-Host "[INFO] Using local protobuf source: $ProtobufSourceDir"
}
if ($ProtobufRoot) {
    Write-Host "[INFO] Using local protobuf root: $ProtobufRoot"
}

foreach ($path in @($moqiImeBuildScript, $windowsBuildScript, $windowsInstallScript)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required script not found: $path"
    }
}

if ($SkipArm64) {
    Write-Host "== Step 1/3: Build moqi-ime runtime (x64) =="
} else {
    Write-Host "== Step 1/3: Build moqi-ime runtime (x64 + ARM64) =="
}

$moqiImeBuildDir = Join-Path $MoqiImeRoot "scripts\build\moqi-ime"
$moqiImeAmd64Dir = Join-Path $MoqiImeRoot "scripts\build\moqi-ime-amd64"
$moqiImeArm64Dir = Join-Path $MoqiImeRoot "scripts\build\moqi-ime-arm64"

foreach ($dir in @($moqiImeAmd64Dir, $moqiImeArm64Dir)) {
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}

Invoke-Step -FilePath "powershell.exe" -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$moqiImeBuildScript`"",
    "-RepoRoot", "`"$MoqiImeRoot`""
) -WorkingDirectory $MoqiImeRoot

if (-not (Test-Path -LiteralPath (Join-Path $moqiImeBuildDir "server.exe"))) {
    throw "moqi-ime runtime was not produced: $moqiImeBuildDir"
}
Move-Item -LiteralPath $moqiImeBuildDir -Destination $moqiImeAmd64Dir

if (-not $SkipArm64) {
    $previousGoarch = $env:GOARCH
    $env:GOARCH = "arm64"
    try {
        Invoke-Step -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$moqiImeBuildScript`"",
            "-RepoRoot", "`"$MoqiImeRoot`""
        ) -WorkingDirectory $MoqiImeRoot
    }
    finally {
        if ($null -ne $previousGoarch) {
            $env:GOARCH = $previousGoarch
        } else {
            Remove-Item -LiteralPath 'env:GOARCH' -ErrorAction SilentlyContinue
        }
    }

    $arm64Server = Join-Path $moqiImeBuildDir "server.exe"
    if (-not (Test-Path -LiteralPath $arm64Server)) {
        throw "ARM64 moqi-ime runtime was not produced: $moqiImeBuildDir"
    }
    $serverBytes = [System.IO.File]::ReadAllBytes($arm64Server)
    $peOffset = [BitConverter]::ToInt32($serverBytes, 0x3C)
    $serverMachine = [BitConverter]::ToUInt16($serverBytes, $peOffset + 4)
    if ($serverMachine -ne 0xAA64) {
        throw ("ARM64 moqi-ime server.exe has unexpected PE machine type 0x{0:X4} (expected 0xAA64); does moqi-ime's build script honor GOARCH?" -f $serverMachine)
    }
    Move-Item -LiteralPath $moqiImeBuildDir -Destination $moqiImeArm64Dir
}

$moqiImeRuntimeDir = $moqiImeAmd64Dir

Write-Host "== Step 2/3: Build moqi-im-windows binaries =="
$windowsBuildArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$windowsBuildScript`"",
    "-RepoRoot", "`"$RepoRoot`"",
    "-Configuration", $Configuration,
    "-Generator", "`"$Generator`""
)
if ($SkipArm64) {
    $windowsBuildArgs += "-SkipArm64"
}
if ($ProtobufSourceDir) {
    $windowsBuildArgs += @("-ProtobufSourceDir", "`"$ProtobufSourceDir`"")
}
if ($ProtobufRoot) {
    $windowsBuildArgs += @("-ProtobufRoot", "`"$ProtobufRoot`"")
}
Invoke-Step -FilePath "powershell.exe" -ArgumentList $windowsBuildArgs -WorkingDirectory $RepoRoot

Write-Host "== Step 3/3: Build installer package =="
$windowsInstallArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$windowsInstallScript`"",
    "-RepoRoot", "`"$RepoRoot`"",
    "-MoqiImeSource", "`"$moqiImeRuntimeDir`""
)
if ($SkipArm64) {
    $windowsInstallArgs += "-SkipArm64"
} else {
    $windowsInstallArgs += @("-MoqiImeArm64Source", "`"$moqiImeArm64Dir`"")
}
Invoke-Step -FilePath "powershell.exe" -ArgumentList $windowsInstallArgs -WorkingDirectory $RepoRoot

$installerPath = Join-Path $RepoRoot "installer\dist\moqi-im-windows-setup.exe"
if (Test-Path -LiteralPath $installerPath) {
    Write-Host "OK: $installerPath"
} else {
    throw "Installer was not produced: $installerPath"
}
