<#
    deploy.ps1 - Deploy LibGroupBuffsProbe, a ForeverProbe module, for an in-game check.

    In order, each step stopping the rest if it refuses:
      1. ForeverProbe, the host (..\ForeverProbe, or $env:FOREVERPROBE), with its own deploy;
      2. LibGlass (..\LibGlass, or $env:LIBGLASS) into AddOns\LibGroupBuffsProbe\Libs\LibGlass-1.0;
      3. this checkout's runtime files into AddOns\LibGroupBuffsProbe\Libs\LibGroupBuffs-1.0;
      4. the module's TOC and Lua.

    Usage, from the repo root:
        pwsh Tools\deploy.ps1
    Then /reload in game and /fp steps gb look.
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns",
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ProbeDir = Join-Path $PSScriptRoot "LibGroupBuffsProbe"
$Parent = Split-Path -Parent $RepoRoot
$ForeverProbe = if ($env:FOREVERPROBE) { $env:FOREVERPROBE } else { Join-Path $Parent "ForeverProbe" }
$LibGlass = if ($env:LIBGLASS) { $env:LIBGLASS } else { Join-Path $Parent "LibGlass" }
$ProbeFiles = @("LibGroupBuffsProbe.toc", "LibGroupBuffsProbe.lua")

foreach ($f in $ProbeFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $ProbeDir $f))) { Write-Error "Missing probe file: $f"; exit 1 }
}
$luac = Join-Path (Split-Path -Parent $Lua) "luac.exe"
if (Test-Path -LiteralPath $luac) {
    & $luac -p (Join-Path $ProbeDir "LibGroupBuffsProbe.lua") (Join-Path $RepoRoot "LibGroupBuffs.lua")
    if ($LASTEXITCODE -ne 0) { Write-Error "luac -p failed"; exit 1 }
    Remove-Item -LiteralPath "luac.out" -ErrorAction SilentlyContinue
} else {
    Write-Host "  luac -p SKIPPED (no $luac)" -ForegroundColor Yellow
}

# 1. The host.
$hostDeploy = Join-Path $ForeverProbe "Tools\deploy.ps1"
if (-not (Test-Path -LiteralPath $hostDeploy)) { Write-Error "ForeverProbe checkout not found at $ForeverProbe (or set `$env:FOREVERPROBE)"; exit 1 }
& pwsh -NoProfile -File $hostDeploy -AddOnsPath $AddOnsPath
if ($LASTEXITCODE -ne 0) { Write-Error "ForeverProbe deploy refused; LibGroupBuffsProbe was not touched"; exit 1 }

# 2. LibGlass, from its own deploy.
$glassDeploy = Join-Path $LibGlass "Tools\deploy.ps1"
if (-not (Test-Path -LiteralPath $glassDeploy)) { Write-Error "LibGlass checkout not found at $LibGlass (or set `$env:LIBGLASS)"; exit 1 }
& pwsh -NoProfile -File $glassDeploy -Addon LibGroupBuffsProbe -AddOnsPath $AddOnsPath -Lua $Lua
if ($LASTEXITCODE -ne 0) { Write-Error "LibGlass deploy refused; LibGroupBuffsProbe was not copied"; exit 1 }

# 3. This library: exactly what its XML loads, plus LICENSE.
$AddOnsPath = (Resolve-Path -LiteralPath $AddOnsPath).ProviderPath
$dest = Join-Path $AddOnsPath "LibGroupBuffsProbe"
$libDest = Join-Path $dest "Libs\LibGroupBuffs-1.0"
$xml = (Get-Content -LiteralPath (Join-Path $RepoRoot "LibGroupBuffs-1.0.xml") -Raw) -replace '(?s)<!--.*?-->', ''
$scripts = @([regex]::Matches($xml, '<Script\s+file="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
$files = @("LibGroupBuffs-1.0.xml", "LICENSE") + $scripts
$missing = @($files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_)) })
if ($missing.Count -gt 0) { Write-Error ("checkout is incomplete, missing: " + ($missing -join ", ")); exit 1 }
$commit = "unknown"
try {
    $commit = (git -C $RepoRoot rev-parse --short HEAD).Trim()
    if (git -C $RepoRoot status --porcelain) { $commit += " (with uncommitted changes)" }
} catch { }
Write-Host "Deploying LibGroupBuffs $commit -> $libDest" -ForegroundColor Cyan
foreach ($f in $files) {
    $target = Join-Path $libDest $f
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot $f) -Destination $target -Force
}

# 4. The module.
foreach ($f in $ProbeFiles) { Copy-Item -LiteralPath (Join-Path $ProbeDir $f) -Destination (Join-Path $dest $f) -Force }
Write-Host "LibGroupBuffsProbe deployed to $dest. /reload, then /fp steps gb look (or /fp gb)." -ForegroundColor Cyan
