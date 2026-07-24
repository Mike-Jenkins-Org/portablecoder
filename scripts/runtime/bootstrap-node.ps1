# Downloads a portable Node.js into runtime\node without needing Node.js.
#
# This is the no-Node escape hatch for a fresh clone on a bare Windows machine:
# runtime/node is gitignored, so a clone has no bundled Node, and
# bootstrap-host-native.cjs cannot download one because it is itself a Node
# script. pcoder.cmd calls this from its :no_node branch, then re-runs.
#
# Mirrors downloadAndExtractNode() in bootstrap-host-native.cjs: same dist URL,
# same SHASUMS256.txt verification, same runtime\node layout. The version is
# read from that file so the two cannot drift.
#
# Must run under Windows PowerShell 5.1 as well as pwsh, so: ASCII only (5.1
# reads a UTF-8 file as CP1252, and a mangled byte can terminate a string
# early), and no 5.1-incompatible syntax.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# PS 5.1 on older builds negotiates TLS 1.0 by default; nodejs.org requires 1.2+.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Invoke-WebRequest renders a progress bar per chunk, which dominates runtime on
# 5.1 and can turn a ~30 MB download into a multi-minute one. Suppressing it is
# the single biggest speed win here.
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$nodeDir = Join-Path $repoRoot 'runtime\node'
$tmpDir = Join-Path $repoRoot 'state\tmp'

# Plain stderr rather than Write-Error: under $ErrorActionPreference = 'Stop' the
# latter throws and prints a multi-line exception blob, burying the message the
# user actually needs to act on.
function Fail($message) {
    [Console]::Error.WriteLine("Error: $message")
    exit 1
}

# Single source of truth for the version: scripts/runtime/bootstrap-host-native.cjs
function Get-NodeVersion {
    $bootstrapCjs = Join-Path $PSScriptRoot 'bootstrap-host-native.cjs'
    if (-not (Test-Path -LiteralPath $bootstrapCjs)) {
        Fail "Missing $bootstrapCjs - cannot determine the pinned Node.js version."
    }
    # .NET regex rather than Select-String, for the same 5.1 module reason as Get-Sha256.
    $match = [regex]::Match(
        [IO.File]::ReadAllText($bootstrapCjs),
        "(?m)^const NODE_VERSION = '(v[\d.]+)';"
    )
    if (-not $match.Success) {
        Fail "Could not parse NODE_VERSION from $bootstrapCjs."
    }
    return $match.Groups[1].Value
}

function Get-NodeArch {
    # A 32-bit PowerShell on a 64-bit OS reports x86 in PROCESSOR_ARCHITECTURE and
    # puts the real one in PROCESSOR_ARCHITEW6432; without this, an ARM64 host
    # would silently get the x64 build and run Node under emulation.
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if ($arch -eq 'ARM64') { return 'arm64' }
    return 'x64'
}

# .NET rather than Get-FileHash: the Utility module cmdlet is not always
# resolvable under a stripped-down Windows PowerShell 5.1 host.
function Get-Sha256($path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($path)
    try {
        $bytes = $sha.ComputeHash($stream)
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Save-File($url, $dest) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
            return
        } catch {
            if ($attempt -eq 3) {
                Fail "Failed to download $url after 3 attempts: $($_.Exception.Message)"
            }
            Write-Host "  Attempt $attempt failed, retrying..."
            Start-Sleep -Seconds 2
        }
    }
}

$nodeVersion = Get-NodeVersion
$arch = Get-NodeArch
$fileName = "node-$nodeVersion-win-$arch.zip"
$url = "https://nodejs.org/dist/$nodeVersion/$fileName"
$shasumsUrl = "https://nodejs.org/dist/$nodeVersion/SHASUMS256.txt"

Write-Host "No Node.js found. Bootstrapping a portable copy."
Write-Host "Platform: win32/$arch"
Write-Host "Node.js:  $nodeVersion"
Write-Host ''

New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$downloadPath = Join-Path $tmpDir $fileName
$shasumsPath = Join-Path $tmpDir 'node-SHASUMS256.txt'

Write-Host "Downloading Node.js from $url..."
Save-File $url $downloadPath
Save-File $shasumsUrl $shasumsPath
Write-Host "Downloaded: $downloadPath"

# Verify against the official checksums before extracting anything.
$expected = $null
foreach ($line in [IO.File]::ReadAllLines($shasumsPath)) {
    $parts = $line -split '\s+'
    if ($parts.Length -ge 2 -and $parts[-1] -eq $fileName) {
        $expected = $parts[0].ToLowerInvariant()
        break
    }
}
if (-not $expected) {
    Fail "$fileName not listed in SHASUMS256.txt - refusing to extract."
}
$actual = Get-Sha256 $downloadPath
if ($expected -ne $actual) {
    Remove-Item -LiteralPath $downloadPath -Force
    Fail "SHA-256 mismatch for ${fileName}: expected $expected, got $actual."
}
Write-Host "Checksum verified: $actual"

Write-Host 'Extracting...'
$extractDir = Join-Path $tmpDir 'node-extract'
if (Test-Path -LiteralPath $extractDir) {
    Remove-Item -LiteralPath $extractDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

# tar.exe ships with Windows 10 1803+ and is much faster than Expand-Archive.
$extracted = $false
$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
if ($tar) {
    & $tar.Source -xf $downloadPath -C $extractDir
    if ($LASTEXITCODE -eq 0) { $extracted = $true }
}
if (-not $extracted) {
    # ZipFile rather than Expand-Archive, for the same 5.1 module reason as above.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($downloadPath, $extractDir)
}

$inner = [IO.Directory]::GetDirectories($extractDir, 'node-*') | Select-Object -First 1
if (-not $inner) {
    Fail "Could not find extracted Node.js directory in $extractDir"
}

if (Test-Path -LiteralPath $nodeDir) {
    Remove-Item -LiteralPath $nodeDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $nodeDir) | Out-Null
Move-Item -LiteralPath $inner -Destination $nodeDir

Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue

$nodeExe = Join-Path $nodeDir 'node.exe'
if (-not (Test-Path -LiteralPath $nodeExe)) {
    Fail "Bootstrap finished but $nodeExe is missing."
}

Write-Host "Node.js extracted to $nodeDir"
Write-Host "Bundled Node.js version: $(& $nodeExe --version)"
