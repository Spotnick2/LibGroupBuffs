<#
    run.ps1 - Run all LibGroupBuffs unit tests, through WowTestKit's runner at
    the commit tests\kit.pin names (the kit's README).

    The tests are plain Lua 5.1 scripts that load the library against
    tests/wow_stubs.lua (on the kit), with LibGlass-1.0 from a checkout
    ($env:LIBGLASS, else ..\LibGlass) loaded first, as every consumer's TOC
    does. WoW uses Lua 5.1, so the tests do too - not the newer Lua that may be
    first on PATH. The library has no TOC: the XML is the list of runtime files,
    and those, the probe and the tests are syntax-checked first.

    Usage:
        pwsh tests/run.ps1
        pwsh tests/run.ps1 -Lua "C:\path\to\lua5.1.exe"
        pwsh tests/run.ps1 -KitDev        # the ..\WowTestKit working copy instead of the pin
#>

param(
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe",
    [switch]$KitDev
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Lua)) {
    Write-Error "Lua 5.1 interpreter not found at: $Lua  (pass -Lua <path>)"
    exit 1
}

$RepoRoot = Split-Path -Parent $PSScriptRoot

# LibGlass-1.0 is a dependency consumers embed beside this library, so the
# tests load it from a checkout: $env:LIBGLASS, else ..\LibGlass. CI fetches
# the ref in tests/libglass-ref.txt; a local checkout elsewhere still runs,
# with a warning, because a LibGlass change is often tested before a bump.
$libGlass = if ($env:LIBGLASS) { $env:LIBGLASS } else { Join-Path (Split-Path -Parent $RepoRoot) "LibGlass" }
if (-not (Test-Path -LiteralPath (Join-Path $libGlass "LibGlass-1.0.xml"))) {
    Write-Host "LibGlass checkout not found at $libGlass - clone github.com/Spotnick2/LibGlass there or set LIBGLASS" -ForegroundColor Red
    exit 1
}
$env:LIBGLASS = $libGlass
$ref = (Get-Content (Join-Path $PSScriptRoot "libglass-ref.txt") -TotalCount 1).Trim()
$want = git -C $libGlass rev-parse --verify --quiet "$ref^{commit}" 2>$null
$head = git -C $libGlass rev-parse HEAD 2>$null
$dirty = git -C $libGlass status --porcelain 2>$null
if (-not $want -or $want -ne $head -or $dirty) {
    Write-Host "WARNING: LibGlass at $libGlass is not $ref$(if ($dirty) { ', or has uncommitted changes' }); CI tests $ref" -ForegroundColor Yellow
} else {
    Write-Host "LibGlass: $libGlass at $ref" -ForegroundColor DarkGray
}

. (Join-Path $PSScriptRoot "kit.ps1")
$kit = Get-WowTestKit -RepoRoot $RepoRoot -KitDev:$KitDev

# Syntax-check the shipping files first (the XML's list, LibStub included): a
# parse error there would show up as a confusing load failure inside every
# test. The probe (never packaged) and the tests are checked too.
$xml = (Get-Content (Join-Path $RepoRoot "LibGroupBuffs-1.0.xml") -Raw) -replace '(?s)<!--.*?-->', ''
$extra = @([regex]::Matches($xml, '<Script\s+file="([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\', '/' })
$extra += @(Get-ChildItem (Join-Path $RepoRoot "Tools\*\*.lua") | ForEach-Object { $_.FullName })
$extra += @(Get-ChildItem (Join-Path $PSScriptRoot "*.lua") -Recurse | ForEach-Object { $_.FullName })
& (Join-Path $kit "scripts\run.ps1") -RepoRoot $RepoRoot -Extra $extra -Lua $Lua
exit $LASTEXITCODE
