------------------------------------------------------------
-- test_versions.lua - what happens when several addons embed the library.
--
-- Priestly, Wildly and Magely each carry their own copy. LibStub resolves
-- them to one table, but only the registration: a copy that loads after a
-- newer one has to leave it alone, and a newer copy that loads after an older
-- one has to upgrade it in place without throwing away its state. Checked in
-- all three orders, with table identity and kept state asserted rather than
-- just the version number.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_versions.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local function ReadFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local SOURCE = ReadFile("Compat.lua")
local CURRENT = tonumber(SOURCE:match('local MAJOR, MINOR = "LibGroupBuffs%-1%.0", (%d+)'))
H.check(CURRENT ~= nil and CURRENT >= 2, "Compat.lua declares its MINOR: " .. tostring(CURRENT))

-- The older copy is the real r2, byte for byte (`git show r2:Compat.lua`):
-- Priestly v2.0.x ships it, so it is what a newer copy will actually meet in
-- game. A copy synthesised from the current source would already carry
-- everything added since, and hide exactly the upgrade under test.
local OLDER = ReadFile("tests/fixtures/Compat-r2.lua")
local OLDER_MINOR = tonumber(OLDER:match('local MAJOR, MINOR = "LibGroupBuffs%-1%.0", (%d+)'))
H.eq(OLDER_MINOR, 2, "the fixture is r2")
H.check(CURRENT > OLDER_MINOR, "the current MINOR is newer than r2")

local function run(src, label)
    local chunk = assert(loadstring(src, "=" .. label))
    chunk()
end

local function freshLibStub()
    LibStub = nil
    run(ReadFile("LibStub/LibStub.lua"), "LibStub.lua")
end

------------------------------------------------------------
-- The same version twice: the second load must change nothing.
------------------------------------------------------------

freshLibStub()
run(SOURCE, "Compat.lua")
local lib = LibStub("LibGroupBuffs-1.0")
local api, itemInfo = lib.API, lib.API.ItemInfo
api.eventFailures.PROBE = "recorded before the second load"

run(SOURCE, "Compat.lua (again)")
H.check(LibStub("LibGroupBuffs-1.0") == lib, "equal-after-equal keeps the library table")
H.check(lib.API == api, "and the API table")
H.check(lib.API.ItemInfo == itemInfo, "and its functions")
H.eq(lib.API.eventFailures.PROBE, "recorded before the second load", "and its recorded state")

------------------------------------------------------------
-- An older copy after a newer one: it must return before touching anything.
------------------------------------------------------------

local reportedFn = lib.API.RegisterEventsReported
run(OLDER, "Compat.lua (r2)")
H.check(lib.API == api, "older-after-newer keeps the API table")
H.check(lib.API.ItemInfo == itemInfo, "and its functions")
H.check(lib.API.RegisterEventsReported == reportedFn, "and does not remove what the newer copy added")
H.eq(lib.API.eventFailures.PROBE, "recorded before the second load", "or reset its state")
local _, minor = LibStub:GetLibrary("LibGroupBuffs-1.0")
H.eq(minor, CURRENT, "the newer MINOR stays registered")

------------------------------------------------------------
-- A newer copy after an older one: upgrade in place, keep the state.
------------------------------------------------------------

freshLibStub()
run(OLDER, "Compat.lua (r2)")
lib = LibStub("LibGroupBuffs-1.0")
api = lib.API
H.eq(api.RegisterEventsReported, nil, "r2 has no RegisterEventsReported")
H.eq(api.eventFailuresByOwner, nil, "or per-consumer failures")
local failures = api.eventFailures
failures.PROBE = "recorded by r2"

run(SOURCE, "Compat.lua")
H.check(LibStub("LibGroupBuffs-1.0") == lib, "newer-after-older upgrades the same library table")
H.check(lib.API == api, "and the same API table, so references taken earlier stay valid")
H.check(type(lib.API.RegisterEventsReported) == "function", "gaining what r2 lacked")
H.check(type(lib.API.eventFailuresByOwner) == "table", "including per-consumer failures")
H.check(lib.API.eventFailures == failures, "keeping r2's failure table, not replacing it")
H.eq(lib.API.eventFailures.PROBE, "recorded by r2", "or what r2 recorded in it")

-- Upgrading twice must not reset per-consumer failures either.
lib.API.eventFailuresByOwner.Priestly = { PROBE = "recorded for Priestly" }
run(SOURCE, "Compat.lua (again)")
H.eq((lib.API.eventFailuresByOwner.Priestly or {}).PROBE, "recorded for Priestly",
    "and a reload of the same version keeps per-consumer failures")
_, minor = LibStub:GetLibrary("LibGroupBuffs-1.0")
H.eq(minor, CURRENT, "and the newer MINOR is registered")

------------------------------------------------------------
-- The XML the client loads is the list the tests load.
------------------------------------------------------------

local scripts = H.xmlScripts()
H.eq(scripts[1], "LibStub/LibStub.lua", "LibStub loads first")
for _, file in ipairs(scripts) do
    local f = io.open(file, "rb")
    H.check(f ~= nil, "the XML lists " .. file .. ", which must exist")
    if f then f:close() end
end

H.done("test_versions")
