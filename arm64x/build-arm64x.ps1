#Requires -Version 5.1
<#
.SYNOPSIS
  Build MoqiTextServiceARM64X.dll, the ARM64X forwarder DLL for Windows ARM64.

.DESCRIPTION
  On Windows ARM64, System32\MoqiTextService.dll is an ARM64X DLL whose exports
  forward to MoqiTextServiceARM64.dll (ARM64 native processes) and
  MoqiTextServiceX64.dll (x64 emulation processes). Only the forwarder is
  registered with the native ARM64 regsvr32.exe; SetupHelper.exe deploys the
  three DLLs at install time.

  Requires the VS 2022 "MSVC v143 - VS 2022 C++ ARM64 build tools" component
  (Microsoft.VisualStudio.Component.VC.Tools.ARM64, VS 17.2 or newer) on an
  x64 host. This mirrors rime/weasel's arm64x_wrapper/build.bat.

.PARAMETER OutputDir
  Where to place MoqiTextServiceARM64X.dll (default: arm64x\build).

.PARAMETER VsRoot
  Optional Visual Studio installation path (auto-detected via vswhere).
#>
param(
    [string] $OutputDir = "",
    [string] $VsRoot = ""
)

$ErrorActionPreference = "Stop"

function Invoke-Tool {
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

if (-not $OutputDir) {
    $OutputDir = Join-Path $PSScriptRoot "build"
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

if (-not $VsRoot) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "vswhere.exe not found. Install Visual Studio 2022 with the ARM64 build tools component."
    }
    $VsRoot = & $vswhere -Latest -Products * `
        -Requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 `
        -Property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($VsRoot)) {
        throw "Visual Studio 2022 with 'MSVC v143 - VS 2022 C++ ARM64 build tools' not found."
    }
}
if (-not (Test-Path -LiteralPath $VsRoot)) {
    throw "Visual Studio installation path not found: $VsRoot"
}

$toolsRoot = Join-Path $VsRoot "VC\Tools\MSVC"
$toolchainDirs = Get-ChildItem -Path $toolsRoot -Directory |
    Sort-Object Name -Descending
$arm64ToolDir = $null
foreach ($dir in $toolchainDirs) {
    $candidate = Join-Path $dir.FullName "bin\Hostx64\arm64"
    if ((Test-Path -LiteralPath (Join-Path $candidate "cl.exe")) -and
        (Test-Path -LiteralPath (Join-Path $candidate "link.exe")) -and
        (Test-Path -LiteralPath (Join-Path $candidate "lib.exe"))) {
        $arm64ToolDir = $candidate
        break
    }
}
if (-not $arm64ToolDir) {
    $fallback = Join-Path $toolchainDirs[0].FullName "bin\Hostx64\arm64"
    throw "ARM64 cross toolchain (bin\Hostx64\arm64) not found under $toolsRoot. Checked last candidate: $fallback"
}

$cl = Join-Path $arm64ToolDir "cl.exe"
$link = Join-Path $arm64ToolDir "link.exe"
$lib = Join-Path $arm64ToolDir "lib.exe"
$arm64Def = Join-Path $PSScriptRoot "MoqiTextService_arm64.def"
$x64Def = Join-Path $PSScriptRoot "MoqiTextService_x64.def"
$dummy = Join-Path $PSScriptRoot "dummy.c"
foreach ($required in @($cl, $link, $lib, $arm64Def, $x64Def, $dummy)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required file not found: $required"
    }
}

function Import-VsDevCmdEnvironment {
    param([string] $VsRoot)

    # weasel's arm64x wrapper links inside "vsdevcmd.bat -arch=arm64"; this
    # script runs outside vcvars, so import the same environment (LIB/INCLUDE
    # with both arm64 and arm64ec MSVC + Windows SDK libraries) into the
    # current process before invoking link.exe.
    $vsdevcmd = Join-Path $VsRoot "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path -LiteralPath $vsdevcmd)) {
        throw "VsDevCmd.bat not found: $vsdevcmd"
    }

    $output = & $env:ComSpec /s /c " `"$vsdevcmd`" -arch=arm64 -host_arch=x64 -no_logo && set" 2>&1 |
        Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_()]*=' }
    foreach ($entry in $output) {
        $separator = $entry.IndexOf('=')
        Set-Item -LiteralPath ("env:" + $entry.Substring(0, $separator)) -Value $entry.Substring($separator + 1)
    }
    if (-not $env:LIB) {
        throw "VsDevCmd did not export a LIB environment"
    }
}

Import-VsDevCmdEnvironment -VsRoot $VsRoot

$workDir = Join-Path $OutputDir "obj"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# dummy ARM64 object: gives the linker an ARM64 entry for the native side.
Invoke-Tool -FilePath $cl -ArgumentList @(
    "/c", "/Fo:$(Join-Path $workDir 'dummy_arm64.obj')", $dummy
) -WorkingDirectory $workDir

# dummy ARM64EC object: lets the linker emit the x64/ARM64EC thunks.
Invoke-Tool -FilePath $cl -ArgumentList @(
    "/c", "/arm64EC", "/Fo:$(Join-Path $workDir 'dummy_arm64ec.obj')", $dummy
) -WorkingDirectory $workDir

# Import libraries describing both export tables of the ARM64X DLL.
Invoke-Tool -FilePath $lib -ArgumentList @(
    "/machine:arm64",
    "/def:$arm64Def",
    "/out:$(Join-Path $workDir 'MoqiTextService_arm64.lib')",
    "/ignore:4104"
) -WorkingDirectory $workDir
Invoke-Tool -FilePath $lib -ArgumentList @(
    "/machine:arm64ec",
    "/def:$x64Def",
    "/out:$(Join-Path $workDir 'MoqiTextService_x64.lib')",
    "/ignore:4104"
) -WorkingDirectory $workDir

$outDll = Join-Path $OutputDir "MoqiTextServiceARM64X.dll"
# Default libraries stay enabled: the EC thunks reference
# __os_arm64x_dispatch_icall from the arm64/arm64ec libraries, resolved via
# the LIB paths imported from VsDevCmd above (same setup as weasel).
Invoke-Tool -FilePath $link -ArgumentList @(
    "/dll", "/noentry", "/machine:arm64x",
    "/defArm64Native:$arm64Def",
    "/def:$x64Def",
    "/out:$outDll",
    (Join-Path $workDir 'dummy_arm64.obj'),
    (Join-Path $workDir 'dummy_arm64ec.obj'),
    (Join-Path $workDir 'MoqiTextService_x64.lib'),
    (Join-Path $workDir 'MoqiTextService_arm64.lib'),
    "/ignore:4104"
) -WorkingDirectory $workDir

if (-not (Test-Path -LiteralPath $outDll)) {
    throw "ARM64X forwarder DLL was not produced: $outDll"
}
Write-Host "OK: $outDll"
