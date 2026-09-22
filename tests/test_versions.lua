------------------------------------------------------------
-- test_versions.lua - what happens when several addons embed the library.
--
-- Priestly, Wildly and Magely each carry their own copy. LibStub resolves
-- them to one table, but only the registration: a copy that loads after a
-- newer one has to leave it alone, and a newer copy that loads after an older
-- one has to upgrade it in place without throwing away its state. Checked in
-- all three orders, loading every runtime file the way the client does, with
-- table identity and kept state asserted rather than just the version number.
--
-- The older copies are real released source (tests/fixtures), never the
-- current source with a lower number: that would already contain whatever the
-- upgrade is supposed to add.
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

local MINOR_PATTERN = 'local MAJOR, MINOR = "LibGroupBuffs%-1%.0", (%d+)'

------------------------------------------------------------
-- Every runtime file declares the same MINOR
------------------------------------------------------------

-- The current copy: every file the XML loads except the bundled LibStub.
local CURRENT_FILES = {}
for _, file in ipairs(H.xmlScripts()) do
    if file ~= "LibStub/LibStub.lua" then
        CURRENT_FILES[#CURRENT_FILES + 1] = { name = file, src = ReadFile(file) }
    end
end
H.check(#CURRENT_FILES >= 2, "the XML lists the library's files")

local CURRENT = tonumber(CURRENT_FILES[1].src:match(MINOR_PATTERN))
H.check(CURRENT ~= nil, CURRENT_FILES[1].name .. " declares its MINOR")
for _, file in ipairs(CURRENT_FILES) do
    H.eq(tonumber(file.src:match(MINOR_PATTERN)), CURRENT,
        file.name .. " declares the same MINOR - one that disagreed would never install, "
        .. "or install over a newer copy")
end

-- A copy is a list of { name, src }, loaded in order like the XML.
local function load(copy, label)
    for _, file in ipairs(copy) do
        local chunk = assert(loadstring(file.src, "=" .. file.name .. " (" .. label .. ")"))
        chunk()
    end
end

local function withMinor(copy, minor, extra)
    local out = {}
    for i, file in ipairs(copy) do
        local src = file.src:gsub(MINOR_PATTERN,
            'local MAJOR, MINOR = "LibGroupBuffs-1.0", ' .. minor)
        if extra and extra[file.name] then src = src .. "\n" .. extra[file.name] end
        out[i] = { name = file.name, src = src }
    end
    return out
end

local R2 = { { name = "Compat.lua", src = ReadFile("tests/fixtures/Compat-r2.lua") } }
local R3 = { { name = "Compat.lua", src = ReadFile("tests/fixtures/Compat-r3.lua") } }
H.eq(tonumber(R2[1].src:match(MINOR_PATTERN)), 2, "the r2 fixture is r2")
H.eq(tonumber(R3[1].src:match(MINOR_PATTERN)), 3, "the r3 fixture is r3")
local R4 = {
    { name = "Compat.lua", src = ReadFile("tests/fixtures/Compat-r4.lua") },
    { name = "Settings.lua", src = ReadFile("tests/fixtures/Settings-r4.lua") },
}
for _, file in ipairs(R4) do
    H.eq(tonumber(file.src:match(MINOR_PATTERN)), 4, "the r4 fixture's " .. file.name .. " is r4")
end
local R5 = {
    { name = "Compat.lua", src = ReadFile("tests/fixtures/Compat-r5.lua") },
    { name = "Settings.lua", src = ReadFile("tests/fixtures/Settings-r5.lua") },
    { name = "Engine.lua", src = ReadFile("tests/fixtures/Engine-r5.lua") },
}
for _, file in ipairs(R5) do
    H.eq(tonumber(file.src:match(MINOR_PATTERN)), 5, "the r5 fixture's " .. file.name .. " is r5")
end
H.check(CURRENT > 5, "the current MINOR is newer than every fixture")

local function freshLibStub()
    LibStub = nil
    load({ { name = "LibStub.lua", src = ReadFile("LibStub/LibStub.lua") } }, "bundled")
end

local function activeMinor()
    local _, minor = LibStub:GetLibrary("LibGroupBuffs-1.0")
    return minor
end

------------------------------------------------------------
-- The same version twice: the second load must change nothing.
------------------------------------------------------------

freshLibStub()
load(CURRENT_FILES, "first")
local lib = LibStub("LibGroupBuffs-1.0")
local api, itemInfo = lib.API, lib.API.ItemInfo
local settings, new, set = lib.Settings, lib.Settings.New, lib.SettingsMethods.Set
local engine, engineNew, buffRem = lib.Engine, lib.Engine.New, lib.EngineMethods.BuffRem
local uiLib, uiNew, uiUpdate = lib.UI, lib.UI.New, lib.UIMethods.Update
api.eventFailures.PROBE = "recorded before the second load"

load(CURRENT_FILES, "again")
H.check(LibStub("LibGroupBuffs-1.0") == lib, "equal-after-equal keeps the library table")
H.check(lib.API == api, "and the API table")
H.check(lib.API.ItemInfo == itemInfo, "and its functions")
H.check(lib.Settings == settings and lib.Settings.New == new, "and Settings")
H.check(lib.SettingsMethods.Set == set, "and the settings methods")
H.check(lib.Engine == engine and lib.Engine.New == engineNew, "and Engine")
H.check(lib.EngineMethods.BuffRem == buffRem, "and the engine methods")
H.check(lib.UI == uiLib and lib.UI.New == uiNew and lib.UIMethods.Update == uiUpdate,
    "and UI with its methods")
H.eq(lib.API.eventFailures.PROBE, "recorded before the second load", "and its recorded state")

------------------------------------------------------------
-- An older copy after a newer one: it must return before touching anything.
-- r3 has no Settings.lua at all.
------------------------------------------------------------

local reported = lib.API.RegisterEventsReported
load(R3, "r3")
H.check(lib.API == api, "r3-after-newer keeps the API table")
H.check(lib.API.RegisterEventsReported == reported, "and its functions")
H.check(lib.Settings == settings and lib.Settings.New == new, "and leaves Settings in place")
H.eq(lib.API.eventFailures.PROBE, "recorded before the second load", "and its state")
H.eq(activeMinor(), CURRENT, "the newer MINOR stays registered")

load(R4, "r4")
H.check(lib.Settings.New == new and lib.SettingsMethods.Set == set,
    "r4-after-newer leaves Settings alone, though r4 has a Settings.lua of its own")
H.check(lib.Engine.New == engineNew, "and Engine, which r4 lacks")

load(R5, "r5")
H.check(lib.Engine.New == engineNew and lib.EngineMethods.BuffRem == buffRem,
    "r5-after-newer leaves Engine alone, though r5 has an Engine.lua of its own")
H.check(lib.UI.New == uiNew, "and UI, which r5 lacks")
H.eq(activeMinor(), CURRENT, "and the newer MINOR stays registered")

load(R2, "r2")
H.check(lib.API.RegisterEventsReported == reported, "r2 after it changes nothing either")
H.eq(activeMinor(), CURRENT, "and the newer MINOR still stands")

------------------------------------------------------------
-- A newer copy after r3: upgrade in place, keep the state, add Settings.
------------------------------------------------------------

freshLibStub()
load(R3, "r3")
lib = LibStub("LibGroupBuffs-1.0")
api = lib.API
H.eq(lib.Settings, nil, "r3 has no Settings")
local failures = api.eventFailures
failures.PROBE = "recorded by r3"
api.eventFailuresByOwner.Priestly = { PROBE = "recorded for Priestly by r3" }

load(CURRENT_FILES, "current")
H.check(LibStub("LibGroupBuffs-1.0") == lib, "newer-after-r3 upgrades the same library table")
H.check(lib.API == api, "and the same API table, so references taken earlier stay valid")
H.check(type(lib.Settings) == "table" and type(lib.Settings.New) == "function",
    "gaining Settings, which r3 lacked")
H.eq(lib.settingsMinor, CURRENT, "installed by the claiming copy")
H.check(lib.API.eventFailures == failures, "keeping r3's failure table")
H.eq(lib.API.eventFailures.PROBE, "recorded by r3", "and what r3 recorded in it")
H.eq((lib.API.eventFailuresByOwner.Priestly or {}).PROBE, "recorded for Priestly by r3",
    "including what it recorded per consumer")
H.eq(activeMinor(), CURRENT, "and the newer MINOR is registered")

------------------------------------------------------------
-- A newer copy after r4: Settings upgrades, Engine arrives.
------------------------------------------------------------

freshLibStub()
load(R4, "r4")
lib = LibStub("LibGroupBuffs-1.0")
H.eq(lib.Engine, nil, "r4 has no Engine")
local r4Store = {}
local r4Settings = lib.Settings.New({
    owner = "Priestly", report = function() end,
    measuredOnBuild = "1", svBrokenOnBuild = "1",
    scopes = { { label = "per-character", get = function() return r4Store end } },
})
local r4Meta = getmetatable(r4Settings)

load(CURRENT_FILES, "current")
H.eq(lib.settingsMinor, CURRENT, "newer-after-r4 installs the newer Settings")
H.check(getmetatable(r4Settings) == r4Meta, "an object r4 created keeps its metatable")
r4Settings:Set("lockFrame", true)
H.eq(r4Store.lockFrame, true, "and still works")
H.check(type(lib.Engine.New) == "function", "Engine arrives")
H.eq(lib.engineMinor, CURRENT, "installed by the claiming copy")

------------------------------------------------------------
-- A newer copy after r2: the upgrade Priestly v2.0.x players will meet.
------------------------------------------------------------

freshLibStub()
load(R2, "r2")
lib = LibStub("LibGroupBuffs-1.0")
api = lib.API
H.eq(api.RegisterEventsReported, nil, "r2 has no RegisterEventsReported")
H.eq(api.eventFailuresByOwner, nil, "or per-consumer failures")
failures = api.eventFailures
failures.PROBE = "recorded by r2"

load(CURRENT_FILES, "current")
H.check(lib.API == api, "newer-after-r2 upgrades the same API table")
H.check(type(lib.API.RegisterEventsReported) == "function", "gaining what r2 lacked")
H.check(type(lib.API.eventFailuresByOwner) == "table", "including per-consumer failures")
H.check(type(lib.Settings.New) == "function", "and Settings")
H.check(lib.API.eventFailures == failures, "keeping r2's failure table, not replacing it")
H.eq(lib.API.eventFailures.PROBE, "recorded by r2", "or what r2 recorded in it")

------------------------------------------------------------
-- A settings object made by one copy runs the next copy's methods.
--
-- Priestly creates its object at load; Wildly may embed a newer library that
-- loads afterwards. The object holds the shared metatable, and the newer copy
-- assigns into the shared methods table, so the upgrade reaches it.
------------------------------------------------------------

freshLibStub()
load(CURRENT_FILES, "current")
lib = LibStub("LibGroupBuffs-1.0")
local store = {}
local made = lib.Settings.New({
    owner = "Priestly", report = function() end,
    measuredOnBuild = "1", svBrokenOnBuild = "1",
    scopes = { { label = "per-character", get = function() return store end } },
})
made:Set("lockFrame", true)
local meta = getmetatable(made)

local NEXT = withMinor(CURRENT_FILES, CURRENT + 1, {
    ["Settings.lua"] = "LibStub('LibGroupBuffs-1.0').SettingsMethods.Probe = function() return 'next' end",
})
load(NEXT, "next")
H.eq(activeMinor(), CURRENT + 1, "the next copy claims the library")
H.eq(lib.settingsMinor, CURRENT + 1, "and installs its Settings")
H.check(getmetatable(made) == meta, "the object keeps its metatable")
H.eq(made.Probe and made:Probe(), "next", "and runs the newer copy's methods")
H.eq(store.lockFrame, true, "without losing what it wrote")

-- The same for an engine: its cache, host callbacks and defs survive.
freshLibStub()
load(CURRENT_FILES, "current")
lib = LibStub("LibGroupBuffs-1.0")
local defs = { { id = "fort", snglID = 1243, sngl = "Power Word: Fortitude", duration = 3600 } }
local visible = function() return true end
local eng = lib.Engine.New({ defs = defs, bucketSize = 8, isVisible = visible })
eng.cache["GUID-x"] = { fort = { exp = 0, dur = 0, stamp = 1 } }
local engMeta, cache, states = getmetatable(eng), eng.cache, lib.Engine.STATES

load(withMinor(CURRENT_FILES, CURRENT + 1, {
    ["Engine.lua"] = "LibStub('LibGroupBuffs-1.0').EngineMethods.Probe = function() return 'next' end",
}), "next")
H.eq(lib.engineMinor, CURRENT + 1, "the next copy installs its Engine")
H.check(getmetatable(eng) == engMeta, "an existing engine keeps its metatable")
H.eq(eng.Probe and eng:Probe(), "next", "and runs the newer copy's methods")
H.check(eng.cache == cache and eng.cache["GUID-x"] ~= nil, "with its aura cache intact")
H.check(eng.defs == defs and eng.isVisible == visible, "and its defs and host callbacks")
H.check(lib.Engine.STATES == states, "and the STATES table a consumer may hold")
H.eq(states.UNKNOWN, "UNKNOWN", "still filled in")

------------------------------------------------------------
-- A newer copy after r5: UI arrives
------------------------------------------------------------

freshLibStub()
load(R5, "r5")
lib = LibStub("LibGroupBuffs-1.0")
H.eq(lib.UI, nil, "r5 has no UI")
local r5Engine = lib.Engine.New({ defs = { { id = "x", snglID = 1243 } }, bucketSize = 8 })
load(CURRENT_FILES, "current")
H.eq(lib.uiMinor, CURRENT, "newer-after-r5 installs UI")
H.check(pcall(lib.UI.New, { engine = r5Engine, owner = "Priestly" }),
    "and it accepts an engine the r5 copy created")

------------------------------------------------------------
-- A window built by one copy runs the next copy's code - including the
-- handlers it installed on its frames and a timer it queued before the
-- upgrade. Handlers are installed once, so a closure over an implementation
-- function would keep running the old copy forever.
------------------------------------------------------------

freshLibStub()
load(CURRENT_FILES, "current")
lib = LibStub("LibGroupBuffs-1.0")
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
WoW.SetUnit("party1", { name = "A One", guid = "P1" })
WoW.groupMembers = 2
local e = lib.Engine.New({ defs = { { id = "fort", snglID = 1243, sngl = "Power Word: Fortitude" } },
    bucketSize = 8 })
e:RefreshSpells()
local w = lib.UI.New({ engine = e, owner = "Priestly" })
w:Update()
local row, mainFrame = w.rows[1], w.main
w:Open(0.5)                                  -- queued before the upgrade

load(withMinor(CURRENT_FILES, CURRENT + 1, {
    ["UI.lua"] = [[
local m = LibStub('LibGroupBuffs-1.0').UIMethods
m.RowPreClick = function(self, r) r._probe = 'next' end
local oldUpdate = m.Update
m.Update = function(self) self._probeUpdate = 'next' return oldUpdate(self) end
]],
}), "next")
H.eq(lib.uiMinor, CURRENT + 1, "the next copy installs its UI")
H.check(w.main == mainFrame and w.rows[1] == row, "the window keeps its frames")
row._scripts.PreClick(row, "LeftButton")
H.eq(row._probe, "next", "a click handler installed by the old copy runs the new code")
WoW.flushTimers(1)
H.eq(w._probeUpdate, "next", "and so does a show the old copy queued")

------------------------------------------------------------
-- The XML the client loads is the list the tests load.
------------------------------------------------------------

local scripts = H.xmlScripts()
H.eq(scripts[1], "LibStub/LibStub.lua", "LibStub loads first")
H.eq(scripts[2], "Compat.lua", "Compat.lua claims the version before any other file checks it")
local position = {}
for i, file in ipairs(scripts) do position[file] = i end
H.check((position["Engine.lua"] or 0) > (position["Compat.lua"] or 99), "Engine.lua loads after the API it calls")
H.eq(scripts[#scripts], "UI.lua", "and UI.lua last, after the engine it draws")
for _, file in ipairs(scripts) do
    local f = io.open(file, "rb")
    H.check(f ~= nil, "the XML lists " .. file .. ", which must exist")
    if f then f:close() end
end

H.done("test_versions")
