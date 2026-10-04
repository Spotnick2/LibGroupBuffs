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
-- One runtime file, one MINOR, one completion marker
--
-- Up to r25 the library was six files, each with its own guard and marker.
-- Since r26 it is one. The released multi-file copies below stay exactly as
-- they shipped, because they are what other addons still carry.
------------------------------------------------------------

-- The current copy: every file the XML loads except the bundled LibStub.
local CURRENT_FILES = {}
for _, file in ipairs(H.xmlScripts()) do
    if file ~= "LibStub/LibStub.lua" then
        CURRENT_FILES[#CURRENT_FILES + 1] = { name = file, src = ReadFile(file) }
    end
end
H.eq(#CURRENT_FILES, 1, "the XML loads one runtime file besides LibStub")
H.eq(CURRENT_FILES[1].name, "LibGroupBuffs.lua", "and it is LibGroupBuffs.lua")

local CURRENT_SRC = CURRENT_FILES[1].src:gsub("\r\n", "\n")
local CURRENT = tonumber(CURRENT_SRC:match(MINOR_PATTERN))
H.check(CURRENT ~= nil, "LibGroupBuffs.lua declares its MINOR")
local _, declared = CURRENT_SRC:gsub(MINOR_PATTERN, "")
H.eq(declared, 1, "exactly once: a second literal is a bump that can be forgotten")
H.eq(CURRENT_SRC:match("([^\n]+)%s*$"), "lib.ready = MINOR",
    "and the completion marker is its last line, so a copy that threw is not marked ready")

-- A copy is a list of { name, src }, loaded in order like the XML, with the
-- embedding addon's name as `...` the way the client passes it.
local function load(copy, label, host)
    for _, file in ipairs(copy) do
        local chunk = assert(loadstring(file.src, "=" .. file.name .. " (" .. label .. ")"))
        chunk(host or H.HOST, {})
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
local R6 = {}
for i, name in ipairs({ "Compat.lua", "Settings.lua", "Engine.lua", "UI.lua" }) do
    R6[i] = { name = name, src = ReadFile("tests/fixtures/" .. name:gsub("%.lua$", "") .. "-r6.lua") }
    H.eq(tonumber(R6[i].src:match(MINOR_PATTERN)), 6, "the r6 fixture's " .. name .. " is r6")
end
local function Fixtures(minor, files)
    local out = {}
    for i, name in ipairs(files or { "Compat.lua", "Settings.lua", "Engine.lua", "UI.lua" }) do
        out[i] = { name = name,
                   src = ReadFile("tests/fixtures/" .. name:gsub("%.lua$", "") .. "-r" .. minor .. ".lua") }
        H.eq(tonumber(out[i].src:match(MINOR_PATTERN)), minor,
            "the r" .. minor .. " fixture's " .. name .. " is r" .. minor)
    end
    return out
end
local R7, R8, R9, R10, R11, R12, R13 = Fixtures(7), Fixtures(8), Fixtures(9), Fixtures(10), Fixtures(11), Fixtures(12), Fixtures(13)
local R14, R15, R16 = Fixtures(14), Fixtures(15), Fixtures(16)
-- r17 added Glass.lua, so its fixture is five files rather than four.
local GLASS_FILES = { "Compat.lua", "Glass.lua", "Settings.lua", "Engine.lua", "UI.lua" }
local R17, R18 = Fixtures(17, GLASS_FILES), Fixtures(18, GLASS_FILES)
local R19, R20 = Fixtures(19, GLASS_FILES), Fixtures(20, GLASS_FILES)
local R21, R22 = Fixtures(21, GLASS_FILES), Fixtures(22, GLASS_FILES)
local R23 = Fixtures(23, GLASS_FILES)
-- r24 added Visibility.lua, so its fixture is six files rather than five.
local SIX_FILES = { "Compat.lua", "Glass.lua", "Settings.lua", "Engine.lua", "UI.lua",
                    "Visibility.lua" }
local R24 = Fixtures(24, SIX_FILES)
-- r25 is the last multi-file release: what Priestly, Magely and Wildly ship
-- until each moves to r26 in a release of its own.
local R25 = Fixtures(25, SIX_FILES)
H.check(CURRENT > 10, "the current MINOR is newer than every fixture")

-- A session starting: nothing registered but LibGlass-1.0, which every
-- consumer's TOC loads before this library. `noGlass` leaves it out.
local function freshLibStub(noGlass)
    LibStub = nil
    load({ { name = "LibStub.lua", src = ReadFile("LibStub/LibStub.lua") } }, "bundled")
    if not noGlass then H.loadLibGlass() end
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

-- Every runtime file marks itself complete with the active MINOR, which is
-- what a consumer checks: a marker that merely exists can be an older copy's.
H.eq(lib.ready, CURRENT, "lib.ready is the active MINOR")
H.eq(lib.fileMinors.LibGroupBuffs, CURRENT, "and so is the record lib.Status reads")

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

-- Every released copy, oldest to newest: each must return before touching
-- anything. A fixture that is never loaded proves nothing.
for _, older in ipairs({ { 6, R6 }, { 7, R7 }, { 8, R8 }, { 9, R9 }, { 10, R10 }, { 11, R11 }, { 12, R12 }, { 13, R13 }, { 14, R14 }, { 15, R15 }, { 16, R16 }, { 17, R17 }, { 18, R18 }, { 19, R19 }, { 20, R20 }, { 21, R21 }, { 22, R22 }, { 23, R23 }, { 24, R24 }, { 25, R25 } }) do
    load(older[2], "r" .. older[1])
    H.check(lib.UI.New == uiNew and lib.UIMethods.Update == uiUpdate,
        "r" .. older[1] .. "-after-newer leaves UI alone, though it has a UI.lua of its own")
    H.eq(activeMinor(), CURRENT, "and the newer MINOR stays registered")
end
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
H.eq(lib.ready, CURRENT, "installed by the claiming copy")
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
H.eq(lib.ready, CURRENT, "newer-after-r4 installs the newer copy")
H.check(getmetatable(r4Settings) == r4Meta, "an object r4 created keeps its metatable")
r4Settings:Set("lockFrame", true)
H.eq(r4Store.lockFrame, true, "and still works")
H.check(type(lib.Engine.New) == "function", "Engine arrives")
H.eq(lib.ready, CURRENT, "installed by the claiming copy")

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
-- A newer copy after r13: the load check changes behaviour, not just shape.
--
-- r13 trusted a returning marker on every build but svBrokenOnBuild, so a
-- relog to character select on any other build announced a fix. A copy that
-- kept MINOR 13 would return early here and leave that running; the object
-- r13 made must run the new rule once the newer copy loads.
------------------------------------------------------------

freshLibStub()
load(R13, "r13")
lib = LibStub("LibGroupBuffs-1.0")
local r13Said = {}
local r13Store = {}
local r13Settings = lib.Settings.New({
    owner = "Priestly", report = function(text) r13Said[#r13Said + 1] = text end,
    measuredOnBuild = WoW.build, svBrokenOnBuild = "1",
    scopes = { { label = "per-character", get = function() return r13Store end } },
})
r13Store.svLoadCheck = { stamp = "then", build = WoW.build }
r13Settings:CheckLoad(true)
H.eq(#r13Said, 1, "r13 announces a marker back on the same build - the relog false positive")

load(CURRENT_FILES, "current")
H.eq(activeMinor(), CURRENT, "newer-after-r13 claims the library")
H.eq(lib.ready, CURRENT, "and installs itself")
r13Said = {}
r13Store.svLoadCheck = { stamp = "then", build = WoW.build }
r13Settings:CheckLoad(true)
H.eq(#r13Said, 0, "and the object r13 made stops announcing a same-build marker")
r13Store.svLoadCheck = { stamp = "then", build = "1" }
r13Settings:CheckLoad(true)
H.eq(#r13Said, 1, "while a marker from another build is still the fix")

------------------------------------------------------------
-- The real r12 announces the fix, then a newer copy takes over (issue #31).
--
-- r12 latched "already told" as `announced = true`; r14 read only `loads` and
-- told every such player again at the next patch. Run the released r12 code
-- to write that marker, then the current copy across a patch.
------------------------------------------------------------

freshLibStub()
load(R12, "r12")
lib = LibStub("LibGroupBuffs-1.0")
local r12Said = {}
local r12Store = {}
local r12Settings = lib.Settings.New({
    owner = "Priestly", report = function(text) r12Said[#r12Said + 1] = text end,
    measuredOnBuild = WoW.build, svBrokenOnBuild = "1",
    scopes = { { label = "per-character", get = function() return r12Store end } },
})
r12Store.svLoadCheck = { stamp = "then", build = "1" }
r12Settings:CheckLoad(true)
H.eq(#r12Said, 1, "the real r12 announces the fix")
H.eq(r12Store.svLoadCheck.announced, true, "and latches it its own way, as announced")

load(CURRENT_FILES, "current")
H.eq(activeMinor(), CURRENT, "newer-after-r12 claims the library")
r12Said = {}
r12Settings:CheckLoad(true)
H.eq(#r12Said, 0, "the current copy stays silent on the same build")
local savedBuild = WoW.build
WoW.build = "70900"
r12Settings:CheckLoad(true)
H.eq(#r12Said, 0, "and across the next patch: the player r12 told is not told again")
H.eq(r12Store.svLoadCheck.loads, true, "the latch now reads as loads")
WoW.build = savedBuild

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
    ["LibGroupBuffs.lua"] = "LibStub('LibGroupBuffs-1.0').SettingsMethods.Probe = function() return 'next' end",
})
load(NEXT, "next")
H.eq(activeMinor(), CURRENT + 1, "the next copy claims the library")
H.eq(lib.ready, CURRENT + 1, "and installs itself")
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
    ["LibGroupBuffs.lua"] = "LibStub('LibGroupBuffs-1.0').EngineMethods.Probe = function() return 'next' end",
}), "next")
H.eq(lib.ready, CURRENT + 1, "the next copy installs itself")
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
H.eq(lib.ready, CURRENT, "newer-after-r5 installs UI")
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
local appearance, border, icons = lib.UI.DEFAULT_APPEARANCE, lib.UI.DEFAULT_APPEARANCE.border, lib.UI.CLASS_ICONS
w:Open(0.5)                                  -- queued before the upgrade

load(withMinor(CURRENT_FILES, CURRENT + 1, {
    ["LibGroupBuffs.lua"] = [[
local m = LibStub('LibGroupBuffs-1.0').UIMethods
m.RowPreClick = function(self, r) r._probe = 'next' end
local oldUpdate = m.Update
m.Update = function(self) self._probeUpdate = 'next' return oldUpdate(self) end
]],
}), "next")
H.eq(lib.ready, CURRENT + 1, "the next copy installs itself and marks the new MINOR complete")
H.check(lib.UI.DEFAULT_APPEARANCE == appearance and lib.UI.DEFAULT_APPEARANCE.border == border,
    "the public appearance table, and its colours, are the same tables after the upgrade")
H.check(lib.UI.CLASS_ICONS == icons, "and so is the class icon map")
H.eq(icons.WARRIOR, "Interface\\Icons\\ClassIcon_Warrior", "still filled in")
H.check(w.main == mainFrame and w.rows[1] == row, "the window keeps its frames")
row._scripts.PreClick(row, "LeftButton")
H.eq(row._probe, "next", "a click handler installed by the old copy runs the new code")
WoW.flushTimers(1)
H.eq(w._probeUpdate, "next", "and so does a show the old copy queued")

------------------------------------------------------------
-- An r6 window upgraded mid-fight: its deferred hide must survive
--
-- r6 parked frames - or tried to; the client refused - and left
-- `_combatHidden` behind. If another addon loads this copy before the fight
-- ends, that flag is the only record that the player closed the window.
------------------------------------------------------------

freshLibStub()
load(R6, "r6")
lib = LibStub("LibGroupBuffs-1.0")
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
H.Party3()
local r6Host = H.PriestUI()
local r6UI = r6Host.ui
r6Host.config.visible.shadow = false
r6Host.engine:RefreshSpells()
r6UI:Update()
H.check(r6UI.main:IsShown(), "r6 built and opened the window")

WoW.inCombat = true
r6UI:Close(true)
H.check(r6UI.main:IsShown() and not r6UI:IsVisible(),
    "r6's close in combat leaves the frame up and the window logically closed")
H.eq(r6UI.main._combatHidden, true, "with only r6's flag to say so")
H.eq(r6UI.closePending, nil, "and none of the newer copy's state")

load(CURRENT_FILES, "current")             -- another addon's newer copy
WoW.inCombat = false
r6UI:OnCombatEnd()
H.check(not r6UI.main:IsShown(), "the newer copy honours the close r6 recorded")
H.eq(r6UI.main._combatHidden, nil, "and clears the old flag")
WoW.flushTimers(1)
H.check(not r6UI:IsVisible(), "without reopening the window")

-- The same for a popover r6 left up when the mouse moved away in combat.
freshLibStub()
load(R6, "r6")
lib = LibStub("LibGroupBuffs-1.0")
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
H.Party3()
local r6b = H.PriestUI()
r6b.config.visible.shadow = false
r6b.engine:RefreshSpells()
r6b.ui:Update()
H.runScript(H.ActiveRows(r6b.ui)[1], "OnEnter")
H.check(r6b.ui.pop:IsShown(), "r6 opened the popover")
WoW.inCombat = true
H.runScript(r6b.ui.pop, "OnUpdate", 1.0)
H.eq(r6b.ui.pop._combatHidden, true, "r6 recorded the hide it could not do")
load(CURRENT_FILES, "current")
WoW.inCombat = false
r6b.ui:OnCombatEnd()
H.check(not r6b.ui.pop:IsShown(), "the newer copy hides it when the fight ends")
H.check(r6b.ui.main:IsShown(), "and leaves the window itself alone")
WoW.flushTimers(1)

------------------------------------------------------------
-- An r10 window's popover divider is one this copy does not hold
--
-- r11 made the divider's colour an appearance key and keeps the texture on
-- the popover. r10 drew the same line but kept it in a local, so a window it
-- built reaches the newer copy with a divider nothing points at. Colouring it
-- must neither crash, nor be quietly dropped, nor draw a second line over the
-- first: two half-opaque lines in one place blend the asked colour with the
-- old one. r10's own line is adopted.
------------------------------------------------------------

-- Every texture anchored where the divider goes, at ANY header height this
-- library has shipped: r19 made the header 30px, so a line r10 drew under a
-- 24px one has to be found where r10 put it AND where it ends up.
local DIV_YS = { -26, -32 }
local function dividers(pop)
    local found = {}
    for _, r in ipairs({ pop:GetRegions() }) do
        local point, rel, _, x, y = r:GetPoint()
        if r:GetObjectType() == "Texture" and point == "TOPLEFT" and rel == pop and x == 5 then
            for _, known in ipairs(DIV_YS) do
                if y == known then found[#found + 1] = r end
            end
        end
    end
    return found
end

freshLibStub()
load(R10, "r10")
lib = LibStub("LibGroupBuffs-1.0")
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
H.Party3()
local r10Host = H.PriestUI()
r10Host.config.visible.shadow = false
r10Host.engine:RefreshSpells()
r10Host.ui:Update()
H.check(r10Host.ui.main:IsShown(), "r10 built and opened the window")
H.eq(r10Host.ui.pop._hdiv, nil, "with a divider this copy holds no reference to")
local r10Lines = dividers(r10Host.ui.pop)
H.eq(#r10Lines, 1, "r10 drew exactly one divider")
local r10Line = r10Lines[1]
local regionsBefore = select("#", r10Host.ui.pop:GetRegions())

load(CURRENT_FILES, "current")
H.eq(activeMinor(), CURRENT, "the current copy took over")
r10Host.look = { popDivider = { 0.95, 0.47, 0.06, 0.55 } }

-- In combat: adopting and colouring an existing line touches no protected call.
WoW.inCombat = true
local blockedBefore = #WoW.blockedCalls
H.check(pcall(r10Host.ui.ApplyAppearance, r10Host.ui), "colouring an r10 window in combat does not throw")
H.eq(r10Host.ui.pop._hdiv, r10Line, "the newer copy adopts r10's own divider")
H.eq(select("#", r10Host.ui.pop:GetRegions()), regionsBefore, "and adds no region to the protected popover")
H.eq(#WoW.blockedCalls, blockedBefore, "with no call the client would refuse")
H.eq(r10Line._colorTexture and r10Line._colorTexture[1], 0.95,
    "and r10's line takes the colour the addon asked for, not silently the old one")

WoW.inCombat = false
H.check(pcall(r10Host.ui.Update, r10Host.ui), "the first rebuild after the fight runs on the r10 window")
H.eq(#dividers(r10Host.ui.pop), 1, "and there is still exactly one divider - no second line blending over it")
H.eq(r10Host.ui.pop._hdiv, r10Line, "the same one")
-- And it was MOVED, not just kept: r10 put it under a 24px header, and this
-- copy's header is 30. A line left where it was sits across the rows.
local _, _, _, _, dy = r10Line:GetPoint()
H.eq(dy, -32, "and the adopted line moved under THIS copy's header")

------------------------------------------------------------
-- An r18 window takes this copy's LAYOUT, not just its colours
--
-- Frames are built once: Init returns early when self.main exists. So a
-- window r18 built reaches r19's code with 15px rows, a bare unmasked icon,
-- the old font and Blizzard's close button - and every position r19 computes
-- is measured against metrics the frames do not have. Panel and Fill already
-- adopt around this; the geometry did not, until Codex found it on #37.
------------------------------------------------------------

freshLibStub()
load(R18, "r18")
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
H.Party3()
local oldHost = H.PriestUI()
oldHost.config.visible.shadow = false
-- With a reagent, so the footer's buttons exist BEFORE the upgrade: they are
-- built lazily, one per item, so a window with no footer would leave that
-- part of the pass untested while looking covered.
oldHost.footer = { { itemID = 17029, usedBy = "the group Prayers" } }
oldHost.engine:RefreshSpells()
oldHost.ui:Update()
H.check(oldHost.ui.main:IsShown(), "r18 built and opened the window")

local oldBtn = oldHost.ui.footerBtns[1]
H.check(type(oldBtn) == "table", "with a reagent button r18 built")
local oldBtnH = oldBtn:GetHeight()
H.check(oldBtnH < 20, "at r18's footer height: " .. tostring(oldBtnH))
H.check(type(oldBtn.iconEdge) ~= "table", "whose icon is a bare texture")

local oldPopIcon = oldHost.ui.pop.hdrIcon
H.check(type(oldHost.ui.pop.hdrEdge) ~= "table",
    "and a popover header icon that is one too")

local oldPop = oldHost.ui.popRows[1]
local oldPopH = oldPop:GetHeight()
H.check(oldPopH < 26, "whose popover rows are r18's height: " .. tostring(oldPopH))

local oldRow = oldHost.ui.rows[1]
local oldRowH = oldRow:GetHeight()
local oldIcon = oldRow.icon
H.check(oldRowH < 20, "whose rows are r18's height: " .. tostring(oldRowH))
H.check(type(oldRow.iconEdge) ~= "table", "and whose icons are bare textures")

-- Shown explicitly: a region in the stub starts hidden, so "the old icon is
-- not shown" would hold whether or not anything hid it.
oldIcon:Show()
H.check(oldIcon:IsShown(), "r18's icon is on screen before the upgrade")

load(CURRENT_FILES, "current")
H.eq(activeMinor(), CURRENT, "the current copy took over")
H.check(pcall(oldHost.ui.Update, oldHost.ui), "and rebuilds the window r18 made")

H.check(oldRow:GetHeight() > oldRowH,
    "the existing row is resized to this copy's height: " .. tostring(oldRow:GetHeight()))
H.check(type(oldRow.iconEdge) == "table", "its icon becomes a tile")
H.check(oldRow.icon ~= oldIcon, "drawn by a new texture, since one cannot be destroyed")
H.check(not oldIcon:IsShown(), "with r18's own icon hidden rather than left underneath")
H.eq(oldIcon:GetTexture(), nil,
    "and emptied, since a texture cannot be destroyed on this client")
H.check(oldRow.timer:GetFont() == "Fonts" .. string.char(92) .. "ARIALN.TTF",
    "and its text restyled, not left on r18's font")
H.check(type(oldHost.ui.main.closeBtn.label) == "table",
    "Blizzard's close button is replaced by ours")
H.check(type(oldHost.ui.main.specEdge) == "table", "and the header icon gets its tile")
-- The popover is built by the same Init and skipped by the same early return.
H.check(oldPop:GetHeight() > oldPopH,
    "the popover rows are resized too: " .. tostring(oldPop:GetHeight()))
H.check(type(oldPop.classEdge) == "table", "and their class icons get tiles")
H.check(oldPop.nameTxt:GetFont() == "Fonts" .. string.char(92) .. "ARIALN.TTF",
    "with their names restyled")
H.check(oldHost.ui.headers[1]:GetFont() == "Fonts" .. string.char(92) .. "ARIALN.TTF",
    "and the group separators are restyled as well")
H.eq(oldHost.ui.headers[1]:GetJustifyH(), "CENTER",
    "and centred, which is what r19 changed them to")

-- The popover's own header and the footer's buttons: built by the same Init,
-- skipped by the same early return, and missed by the first version of this
-- pass. An adopted window reached _layout == 2 with both still on r18.
H.eq(oldHost.ui.main.dragHandle:GetHeight(), oldHost.ui.main.hdrBg:GetHeight(),
    "the drag strip still covers the whole header, which is taller now")
H.check(type(oldHost.ui.pop.hdrEdge) == "table",
    "the popover's header icon gets its tile")
H.check(oldHost.ui.pop.hdrIcon ~= oldPopIcon, "drawn by a new texture")
H.check(oldHost.ui.pop.hdrTxt:GetFont() == "Fonts" .. string.char(92) .. "ARIALN.TTF",
    "and its title is restyled")
H.check(oldBtn:GetHeight() > oldBtnH,
    "the reagent button is resized: " .. tostring(oldBtn:GetHeight()))
H.check(type(oldBtn.iconEdge) == "table", "its icon gets a tile")
H.check(oldBtn.countTxt:GetFont() == "Fonts" .. string.char(92) .. "ARIALN.TTF",
    "and its count is restyled")

-- Once, not on every rebuild: this walks every row and popover row.
local builtBefore = select("#", oldRow:GetRegions())
oldHost.ui:Update()
H.eq(select("#", oldRow:GetRegions()), builtBefore,
    "a second rebuild adopts nothing further - the pass runs once")

-- In combat it must not touch a thing: rows are secure buttons and resizing
-- one is a protected call.
freshLibStub()
load(R18, "r18 again")
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
H.Party3()
local combatHost = H.PriestUI()
combatHost.config.visible.shadow = false
combatHost.engine:RefreshSpells()
combatHost.ui:Update()
load(CURRENT_FILES, "current again")
WoW.inCombat = true
local blocked = #WoW.blockedCalls
H.check(pcall(combatHost.ui.Update, combatHost.ui), "a rebuild in combat on an r18 window does not throw")
H.eq(#WoW.blockedCalls, blocked, "and makes no call the client would refuse")
-- Called DIRECTLY, because Update returns on lockdown long before it would
-- reach the pass: going through Update here asserts nothing about the guard,
-- and a version of this test that did passed with the guard deleted.
H.eq(combatHost.ui:AdoptLayout(), false, "the pass itself refuses under lockdown")
H.eq(#WoW.blockedCalls, blocked, "having touched no protected call on the way out")
H.check(combatHost.ui.main._layout == nil, "so the layout is not adopted")
WoW.inCombat = false
H.check(pcall(combatHost.ui.Update, combatHost.ui), "the first rebuild after the fight runs")
H.check(combatHost.ui.main._layout ~= nil, "and adopts it then")

------------------------------------------------------------
-- lib.Status: is this copy usable?
--
-- Every host carried this check by hand - the marker names, a type() test per
-- entry point - and got it wrong the same way twice. The library answers it
-- now, from its own list of files, so a fifth file added here does not need
-- every consumer edited in lockstep.
------------------------------------------------------------

freshLibStub()
load(CURRENT_FILES, "current")
lib = LibStub("LibGroupBuffs-1.0")

H.eq(lib.Status(CURRENT), "ok", "a complete copy at the host's floor is ok")
H.eq(lib.Status(CURRENT - 1), "ok", "and one newer than the floor")
H.eq(select(2, lib.Status(CURRENT)), CURRENT, "with the active MINOR for the host's message")
H.eq(lib.Status(CURRENT + 1), "too-old", "older than the host needs is too-old, not broken")
H.eq(lib.Status(), "ok", "no floor given: only completeness is judged")

-- The list is the copy's own, and covers every file the XML loads.
local expected = {}
for _, name in ipairs(lib.FILES) do expected[name] = true end
for _, file in ipairs(H.xmlScripts()) do
    if file ~= "LibStub/LibStub.lua" then
        local name = file:gsub("%.lua$", "")
        H.check(expected[name], name .. " is in lib.FILES, so Status accounts for it")
    end
end
H.eq(#lib.FILES, #H.xmlScripts() - 1, "and lib.FILES names no file the XML does not load")

-- A file that threw before its last line leaves no record.
for _, name in ipairs(lib.FILES) do
    local kept = lib.fileMinors[name]
    lib.fileMinors[name] = nil
    H.eq(lib.Status(CURRENT), "incomplete", name .. " missing its record is incomplete")
    -- An older copy's record under a newer MINOR is the same thing: half a
    -- table, with that file's functions still the old copy's.
    lib.fileMinors[name] = CURRENT - 1
    H.eq(lib.Status(CURRENT), "incomplete", name .. " recorded by an older copy is incomplete")
    lib.fileMinors[name] = kept
end
H.eq(lib.Status(CURRENT), "ok", "and putting them back makes it ok again")

-- Incomplete beats too-old: a half-loaded ancient copy is broken, not merely
-- behind, and the host should say so.
do
    local kept = lib.fileMinors.LibGroupBuffs
    lib.fileMinors.LibGroupBuffs = nil
    H.eq(lib.Status(CURRENT + 5), "incomplete", "a broken copy reports broken, not too-old")
    lib.fileMinors.LibGroupBuffs = kept
end

-- A copy that throws partway never reaches its last line. Whatever Status a
-- host then finds - the thrower's own, if it got that far, or the previous
-- copy's - must answer "incomplete", never "ok".
local function Throwing(before)
    local src = CURRENT_SRC:gsub(MINOR_PATTERN, 'local MAJOR, MINOR = "LibGroupBuffs-1.0", '
        .. (CURRENT + 1), 1)
    local at = src:find(before, 1, true)
    H.check(at ~= nil, "the section marker '" .. before .. "' exists")
    return { { name = "LibGroupBuffs.lua",
               src = src:sub(1, at - 1) .. 'error("thrown mid-load")\n' .. src:sub(at) } }
end
for _, case in ipairs({
    { before = "do -- UI ",         label = "before UI, so before its Status" },
    { before = "do -- Visibility ", label = "after UI, so with its own Status" },
}) do
    freshLibStub()
    load(R25, "r25")
    local ok = pcall(load, Throwing(case.before), "throws " .. case.label)
    H.check(not ok, "the throwing copy really threw (" .. case.label .. ")")
    local half = LibStub("LibGroupBuffs-1.0")
    H.eq(activeMinor(), CURRENT + 1, "NewLibrary already counted the thrower's MINOR")
    H.eq(half.Status(25), "incomplete", "an r25 host is told incomplete (" .. case.label .. ")")
    H.check(half.ready ~= CURRENT + 1, "and the thrower is not marked ready")
end
do
    freshLibStub()
    pcall(load, Throwing("do -- UI "), "fresh throw")
    local half = LibStub("LibGroupBuffs-1.0")
    H.eq(half.Status, nil, "a fresh copy that threw before UI has no Status: absence means incomplete")
end

-- An upgrade keeps the same tables, like everything else public here.
freshLibStub()
load(R11, "r11")
lib = LibStub("LibGroupBuffs-1.0")
H.eq(lib.Status, nil, "r11 predates Status")
load(CURRENT_FILES, "current")
H.eq(lib.Status(CURRENT), "ok", "and a newer copy installs it over the upgraded library")
local records = lib.fileMinors
load(withMinor(CURRENT_FILES, CURRENT + 1, {}), "next")
H.check(lib.fileMinors == records, "the record table survives the next upgrade")
H.eq(lib.Status(CURRENT), "ok", "and every file re-recorded itself")

------------------------------------------------------------
-- The XML the client loads is the list the tests load.
------------------------------------------------------------

local scripts = H.xmlScripts()
H.eq(scripts[1], "LibStub/LibStub.lua", "LibStub loads first")
H.eq(scripts[2], "LibGroupBuffs.lua", "then the library, in one file")
H.eq(#scripts, 2, "and nothing else")
-- Inside it, the sections keep the order the files had.
local position = {}
for _, name in ipairs({ "Compat", "Glass", "Settings", "Engine", "UI", "Visibility" }) do
    position[name] = CURRENT_SRC:find("\ndo %-%- " .. name .. " ") or 0
    H.check(position[name] > 0, "the " .. name .. " section exists")
end
H.check(position.Engine > position.Compat, "Engine after the API it calls")
H.check(position.UI > position.Engine, "UI after the engine it draws")
H.check(position.Visibility > position.UI, "and Visibility last, after the window whose opening it decides")
for _, file in ipairs(scripts) do
    local f = io.open(file, "rb")
    H.check(f ~= nil, "the XML lists " .. file .. ", which must exist")
    if f then f:close() end
end

------------------------------------------------------------
-- An engine built by r15, running under r16
--
-- LibStub hands the NEW code the OLD tables, so a def created by r15 reaches
-- r16 carrying a name r15 may already have resolved from the client - with no
-- record of where it came from, because r15 kept none. Calling that the
-- host's English literal would report a correctly localized addon as broken,
-- which is the opposite of what the report is for.
------------------------------------------------------------

freshLibStub()
load(R15, "r15")
local r15lib = LibStub("LibGroupBuffs-1.0")
local defs = { { id = "fort", label = "Fort", snglID = 1243, grpID = 21562,
                 sngl = "Power Word: Fortitude", grp = "Prayer of Fortitude" } }
local r15engine = r15lib.Engine.New({
    defs = defs, bucketSize = 5,
    config = { enabled = function() return true end },
    store = { get = function() end, set = function() end },
})

-- r15 resolves it from a German client.
WoW.reset()
WoW.spells[1243] = { name = "Machtwort: Seelenstaerke", iconID = 1 }
WoW.spells[21562] = { name = "Gebet der Seelenstaerke", iconID = 2 }
WoW.locale = "deDE"
r15engine:RefreshSpells()
H.eq(defs[1].sngl, "Machtwort: Seelenstaerke", "r15 resolved the localized name")
H.eq(defs[1].snglFrom, nil, "and recorded nothing about where it came from")

-- r16 loads over it. The same def table, now under new code.
load(CURRENT_FILES, "current")
local nowLib = LibStub("LibGroupBuffs-1.0")
H.eq(activeMinor(), CURRENT, "the newer copy is the active one")

local report = r15engine:SpellReport()
H.eq(report[1].forms[1].name, "Machtwort: Seelenstaerke", "the localized name survives the upgrade")
H.eq(report[1].forms[1].from, "unknown",
    "and is reported as unknown provenance, not as the host's English literal")
H.eq(report.unresolved, 0, "so nothing claims the addon is unlocalized")

-- A failed lookup afterwards must not turn "unknown" into "fallback": the
-- name is still whatever r15 put there.
local realName = nowLib.API.SpellName
nowLib.API.SpellName = function() return nil end
r15engine:RefreshSpells()
report = r15engine:SpellReport()
H.eq(report[1].forms[1].name, "Machtwort: Seelenstaerke", "a failed refresh keeps it")
H.eq(report[1].forms[1].from, "unknown", "and still does not claim to know where it came from")
H.eq(report.unresolved, 0, "nor count it against the addon")

-- Once the client answers again, provenance is established for good.
nowLib.API.SpellName = realName
r15engine:RefreshSpells()
report = r15engine:SpellReport()
H.eq(report[1].forms[1].from, "resolved", "a successful lookup settles it")

-- An engine built BY r16 starts stamped, so a name that never resolves is
-- reported as the fallback it is - the signal the whole report exists for.
nowLib.API.SpellName = function() return nil end
local freshDefs = { { id = "fort", label = "Fort", snglID = 1243,
                      sngl = "Power Word: Fortitude" } }
local freshEngine = nowLib.Engine.New({
    defs = freshDefs, bucketSize = 5,
    config = { enabled = function() return true end },
    store = { get = function() end, set = function() end },
})
freshEngine:RefreshSpells()
report = freshEngine:SpellReport()
H.eq(report[1].forms[1].from, "fallback", "a def this copy created is stamped from the start")
H.eq(report.unresolved, 1, "so a name that never resolved is counted")
nowLib.API.SpellName = realName

------------------------------------------------------------
-- A window r25 built, running under the single-file copy
--
-- r25 is what every consumer ships until it moves on, so this is the upgrade
-- most players meet: one addon carries r25 and built the window, another
-- carries the newer copy, which takes over the same frames mid-session.
------------------------------------------------------------

freshLibStub()
load(R25, "r25")
lib = LibStub("LibGroupBuffs-1.0")
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
H.Party3()
local r25Host = H.PriestUI()
r25Host.config.visible.shadow = false
r25Host.engine:RefreshSpells()
r25Host.ui:Update()
H.check(r25Host.ui.main:IsShown(), "r25 built and opened the window")
local r25Main, r25Row, r25Glass = r25Host.ui.main, r25Host.ui.rows[1], r25Host.ui.main.glass

load(CURRENT_FILES, "current")
H.eq(activeMinor(), CURRENT, "the single-file copy took over")
H.eq(lib.Status(25), "ok", "and an r25 host asking on it is told ok")
H.check(pcall(r25Host.ui.Update, r25Host.ui), "the r25 window rebuilds under the new code")
H.check(r25Host.ui.main == r25Main and r25Host.ui.rows[1] == r25Row, "keeping its frames")
H.check(r25Host.ui.main.glass == r25Glass, "and the glass r25 built: nothing is rebuilt")
H.check(#H.ActiveRows(r25Host.ui) > 0, "with its rows still drawn")

-- Its panels wear r25's own v1 glass, and the new code colours them through
-- the same region fields LibGlass builds: g.tint and g.rim.
r25Host.ui_config.alpha = 0.5
r25Host.ui:ApplyAppearance()
H.near(r25Glass.tint._colorTexture[4], lib.glass.STYLE.tint[4] * 0.5, 0.001,
    "the host's opacity reaches the tint r25 built")
r25Host.look = { mainBg = { 0.05, 0.05, 0.08 }, border = { 1.0, 0.5, 0.1, 0.85 },
                 popBg = { 0.06, 0.06, 0.09 }, popBorder = { 0.1, 0.9, 0.9, 1 },
                 header = { 0, 0, 0, 0.4 }, headerLine = { 1, 1, 1, 0.1 },
                 footerLine = { 1, 1, 1, 0.1 }, groupText = { 0.8, 0.8, 0.8 },
                 popDivider = { 1, 1, 1, 0.1 } }
r25Host.ui:ApplyAppearance()
H.near((r25Glass.rim:GetVertexColor()), 1.0, 0.001, "and the host's border colour the rim r25 built")
-- Stated limitation, not a bug: a panel built by r25 keeps its v1 rim, drawn
-- opaque, until /reload. Repainting it would overwrite what a host set itself.
H.eq(r25Glass.rim._alpha, nil, "the r25 rim is not repainted to LibGlass's alpha")

------------------------------------------------------------
-- LibGlass-1.0 is a dependency every consumer embeds beside this library
--
-- Without it - or with a LibGlass copy that threw partway through loading -
-- the window cannot draw, so the copy is not usable. That is what lib.Status
-- answers, and it is asked of the ACTIVE copy: an r25 host (Magely, Wildly)
-- asks it of another addon's newer copy, and must not be told "ok" by one
-- that shipped without LibGlass.
------------------------------------------------------------

local GLASS_SRC = ReadFile(H.libGlassScripts()[#H.libGlassScripts()]):gsub("\r\n", "\n")
local GLASS_MINOR_PATTERN = 'local MAJOR, MINOR = "LibGlass%-1%.0", (%d+)'
local glassMinor = tonumber(GLASS_SRC:match(GLASS_MINOR_PATTERN))
H.check(glassMinor ~= nil, "the LibGlass checkout declares its MINOR")
-- A newer LibGlass that throws before its completion marker: registered under
-- its MINOR, with the previous copy's marker and functions still in place.
local GLASS_THROWS = GLASS_SRC:gsub(GLASS_MINOR_PATTERN,
    'local MAJOR, MINOR = "LibGlass-1.0", ' .. (glassMinor + 1), 1)
    :gsub("\nlib%.ready = MINOR%s*$", '\nerror("LibGlass thrown mid-load")\nlib.ready = MINOR\n')
H.check(GLASS_THROWS:find("LibGlass thrown mid-load", 1, true) ~= nil, "the throwing LibGlass is built")

for _, case in ipairs({
    { glass = "absent",            window = false },
    { glass = "absent",            window = true },
    { glass = "thrown mid-load",   window = false },
    { glass = "thrown mid-load",   window = true },
}) do
    local label = "LibGlass " .. case.glass .. (case.window and ", r25 window up" or ", no window")
    freshLibStub(case.glass == "absent")
    if case.glass == "thrown mid-load" then
        H.check(not pcall(load, { { name = "LibGlass.lua", src = GLASS_THROWS } }, "throwing LibGlass"),
            "the newer LibGlass threw (" .. label .. ")")
    end
    WoW.reset()
    H.TeachSpells({ "FORT_SINGLE" })
    H.Party3()
    local host
    if case.window then
        load(R25, "r25")
        host = H.PriestUI()
        host.engine:RefreshSpells()
        host.ui:Update()
    end
    load(CURRENT_FILES, "current")
    lib = LibStub("LibGroupBuffs-1.0")
    H.eq(lib.Status(25), "incomplete", "an r25 host is told incomplete (" .. label .. ")")
    H.eq(lib.Status(), "incomplete", "and so is anyone asking without a floor (" .. label .. ")")
    if not host then
        host = H.PriestUI()
        host.engine:RefreshSpells()
    end
    local ok, err = pcall(host.ui.Update, host.ui)
    H.check(not ok and tostring(err):find("needs LibGlass-1.0", 1, true) ~= nil,
        "and drawing says what is missing rather than failing somewhere obscure ("
        .. label .. "): " .. tostring(err))
end

-- The media path is LibGlass's business: it follows the addon whose LibGlass
-- copy won, whichever addon's LibGroupBuffs copy did.
freshLibStub(true)
H.loadLibGlass("Wildly")
load(CURRENT_FILES, "current", "Priestly")
lib = LibStub("LibGroupBuffs-1.0")
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
H.Party3()
local mixed = H.PriestUI()
mixed.engine:RefreshSpells()
mixed.ui:Update()
H.eq(lib.Status(), "ok", "LibGlass from one addon and LibGroupBuffs from another is ok")
H.eq(lib.glass.MEDIA, "Interface\\AddOns\\Wildly\\Libs\\LibGlass-1.0\\Media\\",
    "and the textures come from the folder of the addon whose LibGlass loaded")

-- One instance, kept across an upgrade of this library: a newer copy must not
-- make a second one (LibGlass keeps a registry, and would migrate both).
local glassInst = lib.glass
local glassCount = 0
for _ in pairs(LibStub("LibGlass-1.0").instances) do glassCount = glassCount + 1 end
load(withMinor(CURRENT_FILES, CURRENT + 1, {}), "next")
mixed.ui:Update()
H.check(lib.glass == glassInst, "the LibGlass instance survives an upgrade of this library")
local after = 0
for _ in pairs(LibStub("LibGlass-1.0").instances) do after = after + 1 end
H.eq(after, glassCount, "and no second one is made")

H.done("test_versions")
