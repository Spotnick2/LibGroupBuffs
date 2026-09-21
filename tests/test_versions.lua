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

-- An older copy of Compat: one MINOR lower, and without ItemInfo, which is how
-- an addon released before the resync would really look.
local OLDER = SOURCE
    :gsub('local MAJOR, MINOR = "LibGroupBuffs%-1%.0", %d+',
          'local MAJOR, MINOR = "LibGroupBuffs-1.0", ' .. (CURRENT - 1))
    :gsub("function API%.ItemInfo%(", "local function _olderHasNoItemInfo(")

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

run(OLDER, "Compat.lua (older)")
H.check(lib.API == api, "older-after-newer keeps the API table")
H.check(lib.API.ItemInfo == itemInfo, "and does not remove what the newer copy added")
H.eq(lib.API.eventFailures.PROBE, "recorded before the second load", "or reset its state")
local _, minor = LibStub:GetLibrary("LibGroupBuffs-1.0")
H.eq(minor, CURRENT, "the newer MINOR stays registered")

------------------------------------------------------------
-- A newer copy after an older one: upgrade in place, keep the state.
------------------------------------------------------------

freshLibStub()
run(OLDER, "Compat.lua (older)")
lib = LibStub("LibGroupBuffs-1.0")
api = lib.API
H.eq(api.ItemInfo, nil, "the older copy has no ItemInfo")
api.eventFailures.PROBE = "recorded by the older copy"
api.eventFailuresByOwner = api.eventFailuresByOwner or {}
api.eventFailuresByOwner.Priestly = { PROBE = "recorded for Priestly by the older copy" }

run(SOURCE, "Compat.lua")
H.check(LibStub("LibGroupBuffs-1.0") == lib, "newer-after-older upgrades the same library table")
H.check(lib.API == api, "and the same API table, so references taken earlier stay valid")
H.check(type(lib.API.ItemInfo) == "function", "gaining what the older copy lacked")
H.eq(lib.API.eventFailures.PROBE, "recorded by the older copy",
    "without resetting what the older copy recorded")
H.eq((lib.API.eventFailuresByOwner.Priestly or {}).PROBE, "recorded for Priestly by the older copy",
    "including what it recorded per consumer")
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
