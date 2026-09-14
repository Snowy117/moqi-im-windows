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

function Write-MoqiServerVersionInfo {
    param(
        [string] $VersionInfoPath,
        [string] $IconPath
    )

    # Mirrors moqi-ime scripts/build.ps1 Write-ServerVersionInfo so both
    # server.exe architectures carry the same version resource.
    $fileDescription = ([char]0x58A8).ToString() + ([char]0x5947) + ([char]0x8F93) + ([char]0x5165) + ([char]0x6CD5) + ([char]0x5F15) + ([char]0x64CE) + ([char]0x670D) + ([char]0x52A1)
    $productName = ([char]0x58A8).ToString() + ([char]0x5947) + ([char]0x8F93) + ([char]0x5165) + ([char]0x6CD5)

    $versionInfo = [ordered]@{
        FixedFileInfo  = [ordered]@{
            FileVersion    = [ordered]@{
                Major = 1
                Minor = 0
                Patch = 0
                Build = 0
            }
            ProductVersion = [ordered]@{
                Major = 1
                Minor = 0
                Patch = 0
                Build = 0
            }
            FileFlagsMask  = "3f"
            FileFlags      = "00"
            FileOS         = "040004"
            FileType       = "01"
            FileSubType    = "00"
        }
        StringFileInfo = [ordered]@{
            Comments         = ""
            CompanyName      = ""
            FileDescription  = $fileDescription
            FileVersion      = "1.0.0.0"
            InternalName     = "server.exe"
            LegalCopyright   = ""
            LegalTrademarks  = ""
            OriginalFilename = "server.exe"
            PrivateBuild     = ""
            ProductName      = $productName
            ProductVersion   = "1.0.0.0"
            SpecialBuild     = ""
        }
        VarFileInfo    = [ordered]@{
            Translation = [ordered]@{
                LangID    = "0804"
                CharsetID = "04B0"
            }
        }
        IconPath       = $IconPath
        ManifestPath   = ""
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        $VersionInfoPath,
        ($versionInfo | ConvertTo-Json -Depth 6),
        $utf8NoBom
    )
}

function Resolve-Goversioninfo {
    $command = Get-Command "goversioninfo" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $goBin = (& go env GOBIN).Trim()
    if (-not $goBin) {
        $goPath = (& go env GOPATH).Trim()
        if (-not $goPath) {
            throw "Unable to resolve GOPATH for the goversioninfo tool."
        }
        $goBin = Join-Path ($goPath.Split([System.IO.Path]::PathSeparator)[0]) "bin"
    }
    $candidate = Join-Path $goBin "goversioninfo.exe"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    Invoke-Step -FilePath "go" -ArgumentList @(
        "install", "github.com/josephspurrier/goversioninfo/cmd/goversioninfo@latest"
    )
    if (-not (Test-Path -LiteralPath $candidate)) {
        throw "goversioninfo was not installed to $goBin"
    }
    return $candidate
}

if (-not $SkipArm64) {
    # moqi-ime's build.ps1 hardcodes GOARCH=amd64, so cross-compile the ARM64
    # server.exe here instead of invoking the script a second time. Only
    # server.exe is architecture-specific; install.ps1 takes everything else
    # from the amd64 package, so this directory needs the exe alone.
    New-Item -ItemType Directory -Path $moqiImeArm64Dir -Force | Out-Null
    $arm64ServerExe = Join-Path $moqiImeArm64Dir "server.exe"

    $serverIcon = Join-Path $MoqiImeRoot "icons\mo.ico"
    if (-not (Test-Path -LiteralPath $serverIcon)) {
        throw "Missing moqi-ime server icon: $serverIcon"
    }

    $arm64BuildDir = Join-Path $MoqiImeRoot "scripts\build\arm64-cross"
    New-Item -ItemType Directory -Path $arm64BuildDir -Force | Out-Null
    $versionInfoPath = Join-Path $arm64BuildDir "server.versioninfo.json"
    # The $GOARCH suffix in the name makes go build pick the resource up only
    # for the ARM64 pass, mirroring moqi-ime's resource_windows_amd64.syso.
    $sysoPath = Join-Path $MoqiImeRoot "resource_windows_arm64.syso"

    Write-MoqiServerVersionInfo -VersionInfoPath $versionInfoPath -IconPath $serverIcon
    $goversioninfo = Resolve-Goversioninfo

    $previousGoos = $env:GOOS
    $previousGoarch = $env:GOARCH
    $previousCgoEnabled = $env:CGO_ENABLED
    $env:GOOS = "windows"
    $env:GOARCH = "arm64"
    $env:CGO_ENABLED = "0"
    try {
        # goversioninfo needs both -64 and -arm to emit an ARM64 COFF object;
        # with only -64 it writes AMD64 relocations that the ARM64 Go linker
        # rejects (goversioninfo >= 1.6.0 also derives both from GOARCH, which
        # is set above as a belt-and-braces default).
        Invoke-Step -FilePath $goversioninfo -ArgumentList @(
            "-64", "-arm", "-o", $sysoPath, $versionInfoPath
        ) -WorkingDirectory $MoqiImeRoot

        Invoke-Step -FilePath "go" -ArgumentList @(
            "build", "-ldflags", "-s -w", "-o", $arm64ServerExe, "."
        ) -WorkingDirectory $MoqiImeRoot
    }
    finally {
        Remove-Item -LiteralPath $sysoPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $previousGoos) { $env:GOOS = $previousGoos } else { Remove-Item -LiteralPath 'env:GOOS' -ErrorAction SilentlyContinue }
        if ($null -ne $previousGoarch) { $env:GOARCH = $previousGoarch } else { Remove-Item -LiteralPath 'env:GOARCH' -ErrorAction SilentlyContinue }
        if ($null -ne $previousCgoEnabled) { $env:CGO_ENABLED = $previousCgoEnabled } else { Remove-Item -LiteralPath 'env:CGO_ENABLED' -ErrorAction SilentlyContinue }
    }

    $serverBytes = [System.IO.File]::ReadAllBytes($arm64ServerExe)
    $peOffset = [BitConverter]::ToInt32($serverBytes, 0x3C)
    $serverMachine = [BitConverter]::ToUInt16($serverBytes, $peOffset + 4)
    if ($serverMachine -ne 0xAA64) {
        throw ("ARM64 server.exe has unexpected PE machine type 0x{0:X4} (expected 0xAA64)." -f $serverMachine)
    }
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
