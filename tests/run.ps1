<#
    run.ps1 - Run all LibGroupBuffs unit tests.

    The tests are plain Lua 5.1 scripts that load the library against
    tests/wow_stubs.lua, with LibGlass-1.0 from a checkout ($env:LIBGLASS, else
    ..\LibGlass) loaded first, as every consumer's TOC does. WoW uses Lua 5.1,
    so the tests do too - not the newer Lua that may be first on PATH.

    Usage:
        pwsh tests/run.ps1
        pwsh tests/run.ps1 -Lua "C:\path\to\lua5.1.exe"
#>

param(
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Lua)) {
    Write-Error "Lua 5.1 interpreter not found at: $Lua  (pass -Lua <path>)"
    exit 1
}

# Run from the repo root so the tests can dofile('tests/...') and
# loadfile('Priestly.lua') with paths relative to the project.
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot
try {
    $failed = 0

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

    # Syntax-check the shipping files first: a parse error there would show up
    # as a confusing load failure inside every test.
    $luac = Join-Path (Split-Path -Parent $Lua) "luac.exe"
    if (Test-Path $luac) {
        & $luac -p LibStub/LibStub.lua (Get-ChildItem "*.lua" | ForEach-Object { $_.FullName })
        if ($LASTEXITCODE -ne 0) {
            Write-Host "luac -p FAILED" -ForegroundColor Red
            exit 1
        }
        Remove-Item -LiteralPath (Join-Path $RepoRoot "luac.out") -ErrorAction SilentlyContinue
        Write-Host "luac -p: ok" -ForegroundColor DarkGray
    }

    Get-ChildItem (Join-Path $PSScriptRoot "test_*.lua") | Sort-Object Name | ForEach-Object {
        Write-Host "-- $($_.Name) " -NoNewline -ForegroundColor Cyan
        & $Lua $_.FullName
        if ($LASTEXITCODE -ne 0) { $failed++ }
    }

    if ($failed -gt 0) {
        Write-Host "$failed test file(s) FAILED" -ForegroundColor Red
        exit 1
    }
    Write-Host "All test files passed." -ForegroundColor Green
}
finally {
    Pop-Location
}
