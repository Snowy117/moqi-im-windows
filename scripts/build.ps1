#Requires -Version 5.1
<#
.SYNOPSIS
  Build Win32, x64, and ARM64 Moqi IM for Windows binaries with CMake.

.DESCRIPTION
  Win32 builds the full solution (MoqiLauncher.exe, SetupHelper.exe, and the
  x86 MoqiTextService.dll). x64 and ARM64 build MoqiTextService.dll only,
  which is all a TSF IME needs on those architectures. The ARM64 pass also
  links MoqiTextServiceARM64X.dll, the ARM64X forwarder DLL that dispatches
  to the ARM64 and x64 builds on Windows ARM64 (see arm64x\).

.PARAMETER RepoRoot
  Root of moqi-im-windows (defaults to the parent directory of this script).

.PARAMETER Win32BuildDir
  CMake Win32 build directory (default: RepoRoot\build-vs32).

.PARAMETER X64BuildDir
  CMake x64 build directory (default: RepoRoot\build-vs64).

.PARAMETER Arm64BuildDir
  CMake ARM64 build directory (default: RepoRoot\build-vsarm64).

.PARAMETER SkipArm64
  Skip the ARM64 build and the ARM64X forwarder DLL (for hosts without the
  VS 2022 ARM64 build tools).

.PARAMETER Configuration
  Build configuration (default: Release).

.PARAMETER Generator
  CMake generator (default: Visual Studio 17 2022).

.PARAMETER ProtobufRoot
  Optional local protobuf/protoc install root passed to CMake as MOQI_PROTOBUF_ROOT.

.PARAMETER ProtobufSourceDir
  Optional local protobuf source tree passed to CMake as MOQI_PROTOBUF_SOURCE_DIR.
#>
param(
  [string] $RepoRoot = "",
  [string] $Win32BuildDir = "",
  [string] $X64BuildDir = "",
  [string] $Arm64BuildDir = "",
  [switch] $SkipArm64,
  [string] $Configuration = "Release",
  [string] $Generator = "Visual Studio 17 2022",
  [string] $ProtobufRoot = "",
  [string] $ProtobufSourceDir = ""
)

$ErrorActionPreference = "Stop"

function Invoke-Step {
  param(
    [string] $FilePath,
    [string[]] $ArgumentList
  )

  Write-Host ">> $FilePath $($ArgumentList -join ' ')"
  & $FilePath @ArgumentList
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: $FilePath"
  }
}

function Resolve-ProtobufSourceDir {
  param(
    [string] $RequestedPath,
    [string] $RepoRoot
  )

  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
    $candidates += $RequestedPath
  }
  if (-not [string]::IsNullOrWhiteSpace($env:MOQI_PROTOBUF_SOURCE_DIR)) {
    $candidates += $env:MOQI_PROTOBUF_SOURCE_DIR
  }
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $cacheRoot = Join-Path $env:USERPROFILE ".cache\moqi-protobuf"
    $candidates += @(
      (Join-Path $cacheRoot "protobuf-33.5"),
      (Join-Path $cacheRoot "protobuf-34.1"),
      (Join-Path $cacheRoot "protobuf-29.5")
    )
  }

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    if (Test-Path -LiteralPath (Join-Path $fullPath "CMakeLists.txt")) {
      return $fullPath
    }
  }

  return ""
}

function Resolve-ProtobufRoot {
  param(
    [string] $RequestedPath
  )

  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
    $candidates += $RequestedPath
  }
  if (-not [string]::IsNullOrWhiteSpace($env:MOQI_PROTOBUF_ROOT)) {
    $candidates += $env:MOQI_PROTOBUF_ROOT
  }
  $defaultRoot = "D:\a_dev\protoc-33.5-win64"
  if (Test-Path -LiteralPath $defaultRoot) {
    $candidates += $defaultRoot
  }

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    if ((Test-Path -LiteralPath (Join-Path $fullPath "bin\protoc.exe")) -or
        (Test-Path -LiteralPath (Join-Path $fullPath "include"))) {
      return $fullPath
    }
  }

  return ""
}

$scriptRepoRoot = Join-Path $PSScriptRoot ".."
if (-not $RepoRoot) { $RepoRoot = $scriptRepoRoot }
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

if (-not $Win32BuildDir) { $Win32BuildDir = Join-Path $RepoRoot "build-vs32" }
if (-not $X64BuildDir) { $X64BuildDir = Join-Path $RepoRoot "build-vs64" }
if (-not $Arm64BuildDir) { $Arm64BuildDir = Join-Path $RepoRoot "build-vsarm64" }
$Win32BuildDir = [System.IO.Path]::GetFullPath($Win32BuildDir)
$X64BuildDir = [System.IO.Path]::GetFullPath($X64BuildDir)
$Arm64BuildDir = [System.IO.Path]::GetFullPath($Arm64BuildDir)
$ProtobufRoot = Resolve-ProtobufRoot -RequestedPath $ProtobufRoot
$ProtobufSourceDir = Resolve-ProtobufSourceDir -RequestedPath $ProtobufSourceDir -RepoRoot $RepoRoot

$commonConfigureArgs = @("-S", $RepoRoot)
if (-not [string]::IsNullOrWhiteSpace($ProtobufRoot)) {
  Write-Host "[INFO] Using local protobuf root: $ProtobufRoot"
  $commonConfigureArgs += "-DMOQI_PROTOBUF_ROOT=$ProtobufRoot"
  $protocExe = Join-Path $ProtobufRoot "bin\protoc.exe"
  if (Test-Path -LiteralPath $protocExe) {
    $commonConfigureArgs += "-DMOQI_PROTOC_EXECUTABLE=$protocExe"
  }
}
if (-not [string]::IsNullOrWhiteSpace($ProtobufSourceDir)) {
  Write-Host "[INFO] Using local protobuf source: $ProtobufSourceDir"
  $commonConfigureArgs += "-DMOQI_PROTOBUF_SOURCE_DIR=$ProtobufSourceDir"
}
$win32ConfigureArgs = $commonConfigureArgs + @(
  "-B", $Win32BuildDir,
  "-G", $Generator,
  "-A", "Win32"
)
$x64ConfigureArgs = $commonConfigureArgs + @(
  "-B", $X64BuildDir,
  "-G", $Generator,
  "-A", "x64"
)

Invoke-Step -FilePath "cmake" -ArgumentList $win32ConfigureArgs
Invoke-Step -FilePath "cmake" -ArgumentList @(
  "--build", $Win32BuildDir,
  "--config", $Configuration
)

Invoke-Step -FilePath "cmake" -ArgumentList $x64ConfigureArgs
Invoke-Step -FilePath "cmake" -ArgumentList @(
  "--build", $X64BuildDir,
  "--config", $Configuration,
  "--target", "MoqiTextService"
)

if (-not $SkipArm64) {
  $arm64ConfigureArgs = $commonConfigureArgs + @(
    "-B", $Arm64BuildDir,
    "-G", $Generator,
    "-A", "ARM64"
  )
  Invoke-Step -FilePath "cmake" -ArgumentList $arm64ConfigureArgs
  Invoke-Step -FilePath "cmake" -ArgumentList @(
    "--build", $Arm64BuildDir,
    "--config", $Configuration,
    "--target", "MoqiTextService"
  )

  $arm64xDll = Join-Path $Arm64BuildDir "MoqiTextServiceARM64X.dll"
  $arm64xScript = Join-Path $RepoRoot "arm64x\build-arm64x.ps1"
  if (-not (Test-Path -LiteralPath $arm64xScript)) {
    throw "ARM64X build script not found: $arm64xScript"
  }
  Invoke-Step -FilePath "powershell.exe" -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$arm64xScript`"",
    "-OutputDir", "`"$Arm64BuildDir`""
  )
  if (-not (Test-Path -LiteralPath $arm64xDll)) {
    throw "ARM64X forwarder DLL was not produced: $arm64xDll"
  }
}

if ($SkipArm64) {
  Write-Host "OK: Win32 $Configuration (full solution), x64 $Configuration (MoqiTextService). ARM64 skipped."
} else {
  Write-Host "OK: Win32 $Configuration (full solution), x64/ARM64 $Configuration (MoqiTextService), ARM64X forwarder."
}
