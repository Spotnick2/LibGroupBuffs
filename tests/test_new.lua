------------------------------------------------------------
-- test_new.lua - lib:New, the per-addon entry point.
--
-- One call replaces the bridge each consumer used to carry: the version
-- check, copying the library's tables onto the addon, and wiring its owner
-- and reporter into every constructor. What it hands back is an instance,
-- dot-called like LibGlass's, whose functions find the newest copy's code
-- when they run (test_versions.lua covers that across an upgrade).
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_new.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
local lib = H.loadLibrary()
local MINOR = select(2, LibStub:GetLibrary("LibGroupBuffs-1.0"))

local said = {}
local function report(text, kind) said[#said + 1] = { text = text, kind = kind } end

------------------------------------------------------------
-- Arguments
------------------------------------------------------------

local ok, err = pcall(lib.New, { owner = "Priestly", report = report })
H.check(not ok and tostring(err):find("colon", 1, true), "a dot call errors instead of dropping opts: " .. tostring(err))
ok, err = pcall(lib.New, lib)
H.check(not ok and tostring(err):find("options table", 1, true), "no options is an error: " .. tostring(err))
ok, err = pcall(lib.New, lib, { report = report })
H.check(not ok and tostring(err):find("opts.owner", 1, true), "an owner is required: " .. tostring(err))
ok, err = pcall(lib.New, lib, { owner = "", report = report })
H.check(not ok and tostring(err):find("opts.owner", 1, true), "and must not be empty")
ok, err = pcall(lib.New, lib, { owner = "Priestly" })
H.check(not ok and tostring(err):find("opts.report", 1, true), "a reporter is required: " .. tostring(err))
ok, err = pcall(lib.New, lib, { owner = "Priestly", report = report, needs = "26" })
H.check(not ok and tostring(err):find("opts.needs", 1, true), "needs is a number: " .. tostring(err))
H.eq(next(lib.instances), nil, "and a refused call registers nothing")

------------------------------------------------------------
-- The version check a host used to carry itself
------------------------------------------------------------

-- New refuses with a plain STRING, as it always has: a table would break a
-- host joining it with `..`, and the client's error handler (string.format
-- "%s" ignores __tostring in Lua 5.1). The reason, with a code, comes from
-- lib:Refusal(needs) - the very function New decides with (#54).
local function Refused(opts, label)
    local ok, err = pcall(lib.New, lib, opts)
    H.check(not ok, label .. " is refused")
    H.eq(type(err), "string", label .. ": with a string, safe to `..` and to format")
    H.check(not tostring(err):find("lua:%d+:"), label .. ": a message for players, no file position")
    local why = lib:Refusal(opts.needs)
    H.check(type(why) == "table", label .. ": lib:Refusal gives the reason")
    why = why or {}
    H.eq(err, why.text, label .. ": and New's message is that reason's text")
    return why
end
local GLASS_MINOR = select(2, LibStub:GetLibrary("LibGlass-1.0"))
local libs, minors = LibStub.libs["LibGlass-1.0"], LibStub.minors["LibGlass-1.0"]
local function DropGlass() LibStub.libs["LibGlass-1.0"], LibStub.minors["LibGlass-1.0"] = nil, nil end
local function RestoreGlass() LibStub.libs["LibGlass-1.0"], LibStub.minors["LibGlass-1.0"] = libs, minors end
local glassLib = LibStub("LibGlass-1.0")
local glassReady, ready = glassLib.ready, lib.ready

H.eq(lib:Refusal(), nil, "nothing wrong: lib:Refusal answers nil")
H.eq(lib:Refusal(MINOR), nil, "and nil at the active MINOR")
local okDot, errDot = pcall(lib.Refusal, MINOR)
H.check(not okDot and tostring(errDot):find("colon", 1, true), "a dot call errors: " .. tostring(errDot))

local r = Refused({ owner = "Priestly", report = report, needs = MINOR + 1 }, "a copy older than needs")
H.eq(r.code, "too-old", "with code too-old")
H.eq(r.active, MINOR, "the active MINOR")
H.eq(r.needs, MINOR + 1, "what the host needs")
H.eq(r.glassMinor, GLASS_MINOR, "and LibGlass's MINOR")
H.check(r.text:find("reinstalling the addon", 1, true),
    "telling the player to reinstall THIS addon: the newest copy runs, so its own is stale: " .. r.text)

lib.ready = MINOR - 1
r = Refused({ owner = "Priestly", report = report, needs = MINOR + 1 }, "an incomplete copy")
H.eq(r.code, "incomplete", "with code incomplete - before too-old")
H.eq(r.glassMinor, GLASS_MINOR, "every field filled: LibGlass's MINOR too")
H.check(r.text:find("scriptErrors", 1, true), "telling the player how to see which addon: " .. r.text)
DropGlass()
r = lib:Refusal()
H.eq(r and r.code, "incomplete", "incomplete comes before a missing LibGlass as well")
RestoreGlass()
lib.ready = ready

glassLib.ready = nil
r = Refused({ owner = "Priestly", report = report, needs = MINOR + 1 }, "a half-loaded LibGlass")
H.eq(r.code, "glass-incomplete", "with code glass-incomplete - before too-old")
H.eq(r.glassMinor, GLASS_MINOR, "naming the LibGlass MINOR that did not finish")
glassLib.ready = glassReady

DropGlass()
r = Refused({ owner = "Priestly", report = report, needs = MINOR + 1 }, "no LibGlass at all")
H.eq(r.code, "glass-missing", "with code glass-missing - before too-old")
H.eq(r.glassMinor, nil, "and no LibGlass MINOR to name")
RestoreGlass()

-- The host's own mistakes are strings at the host's line.
local okDev, errDev = pcall(function() lib:New({ owner = "Priestly" }) end)
H.check(not okDev and errDev:find("test_new%.lua:%d+:") ~= nil,
    "a host's own mistake points at the host's line: " .. tostring(errDev))
H.eq(lib:Refusal(), nil, "and is not a refusal")
H.eq(next(lib.instances), nil, "none of which registers anything")

------------------------------------------------------------
-- An instance
------------------------------------------------------------

local GB = lib:New({ owner = "Priestly", report = report, needs = MINOR })
H.eq(lib.instances.Priestly, GB, "the instance is registered under its owner")
ok, err = pcall(lib.New, lib, { owner = "Priestly", report = report })
H.check(not ok and tostring(err):find("already has an instance", 1, true),
    "a second instance for the same owner is an error: " .. tostring(err))

for _, name in ipairs(lib._test.FUNCTIONS) do
    H.eq(type(GB[name]), "function", "the instance has " .. name)
end
H.check(GB.API == lib.API, "API is the library's own table")
H.check(GB.STATES == lib.Engine.STATES and GB.STATES.MISSING == "MISSING", "and STATES")
H.eq(GB.PET_GROUP, lib.Engine.PET_GROUP, "PET_GROUP")
H.eq(GB.LOAD_CHECK_KEY, lib.Settings.LOAD_CHECK_KEY, "LOAD_CHECK_KEY")
H.check(GB.CLASS_ICONS == lib.UI.CLASS_ICONS, "CLASS_ICONS")
H.eq(GB.MINOR, MINOR, "and the active MINOR, for a host's /help line")
H.eq(rawget(GB, "API"), nil, "shared data is read through, not copied onto the instance")
H.eq(GB.FmtTime(90), lib.UI.FmtTime(90), "the helpers answer like the library's own")
H.eq(GB.Pct(30, 60), lib.UI.Pct(30, 60), "Pct too")
H.eq(GB.TimerColor(0.5), lib.UI.TimerColor(0.5), "and TimerColor")

-- The constructors, with the owner and reporter filled in.
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
H.Party3()
local engine = GB.Engine({ defs = { { id = "fort", snglID = H.SPELL.FORT_SINGLE,
    grpID = H.SPELL.FORT_GROUP, sngl = H.NAME.FORT_SINGLE, grp = H.NAME.FORT_GROUP,
    duration = 3600 } }, bucketSize = 5 })
H.eq(getmetatable(engine), lib.EngineMeta, "GB.Engine builds an engine")
local uiHost = { engine = engine }
local ui = GB.UI(uiHost)
H.eq(getmetatable(ui), lib.UIMeta, "GB.UI builds a window")
H.eq(uiHost.owner, "Priestly", "with the instance's owner filled in")
local named = GB.UI({ engine = engine, owner = "PriestlyProbe" })
H.eq(named.host.owner, "PriestlyProbe", "but never over one the host gave")

local store = {}
local settings = GB.Settings({ measuredOnBuild = "1",
    scopes = { { label = "per-character", get = function() return store end } } })
H.eq(settings.owner, "Priestly", "GB.Settings fills in the owner")
H.eq(settings.report, report, "and the instance's reporter")
local vis = GB.Visibility({ ui = ui, isMyClass = function() return true end,
    showSolo = function() return false end, getPreference = function() return nil end,
    setPreference = function() end })
H.eq(getmetatable(vis), lib.VisibilityMeta, "GB.Visibility builds the visibility rules")

-- A constructor's argument error names the HOST's line, as the direct
-- lib.Settings.New call does - not a line inside the library, and not nothing.
local okBad, errBad = pcall(function() GB.Settings({ scopes = "not a list" }) end)
H.check(not okBad, "a bad spec through the instance is an error")
H.check(tostring(errBad):find("test_new%.lua:%d+:") ~= nil,
    "pointing at the line that called GB.Settings: " .. tostring(errBad))
H.check(tostring(errBad):find("LibGroupBuffs Settings.New", 1, true) ~= nil,
    "with the constructor's own message")
local okEng, errEng = pcall(function() GB.UI({ engine = "not an engine" }) end)
H.check(not okEng and tostring(errEng):find("test_new%.lua:%d+:") ~= nil,
    "and the same for GB.UI: " .. tostring(errEng))

------------------------------------------------------------
-- One reporter for everything an instance says
------------------------------------------------------------

WoW.badEvents.NO_SUCH_EVENT = true
WoW.badEvents.ANOTHER_BAD_EVENT = true
local frame = CreateFrame("Frame")
said = {}
local registered = GB.RegisterEvents(frame, "PLAYER_LOGIN", "NO_SUCH_EVENT")
H.eq(registered, false, "a rejected event is reported as a failure")
H.eq(#said, 1, "through the instance's reporter, once")
H.eq(said[1] and said[1].kind, "events", "with kind 'events'")
H.check(said[1] and said[1].text:find("NO_SUCH_EVENT", 1, true),
    "as text naming the event, like every other message: " .. tostring(said[1] and said[1].text))
H.check(GB.EventFailures() and GB.EventFailures().NO_SUCH_EVENT ~= nil,
    "and recorded for this owner")

-- The same reporter speaks for the settings checks, with their own kinds.
said = {}
settings:CheckBuild()
H.eq(#said, 1, "the build check speaks once: this build is not the one measured")
H.eq(said[1] and said[1].kind, "newBuild", "with its own kind")
H.eq(type(said[1] and said[1].text), "string", "and text, never a table")

------------------------------------------------------------
-- Isolation: two addons, two instances
------------------------------------------------------------

local magelySaid = {}
local MG = lib:New({ owner = "Magely", report = function(text, kind)
    magelySaid[#magelySaid + 1] = kind end })
H.check(MG ~= GB and MG.Engine ~= GB.Engine, "another addon gets its own instance and functions")
H.eq(MG.EventFailures(), nil, "with none of the first addon's event failures")
MG.RegisterEvents(CreateFrame("Frame"), "ANOTHER_BAD_EVENT")
H.eq(#magelySaid, 1, "its rejections reach its own reporter")
H.eq(GB.EventFailures().ANOTHER_BAD_EVENT, nil, "and are not recorded for the first addon")
H.check(MG.API == GB.API, "while the read-only data is shared")
local magelyUI = { engine = engine }
MG.UI(magelyUI)
H.eq(magelyUI.owner, "Magely", "and each fills in its own owner")

------------------------------------------------------------
-- Migration reads the instance itself, never through the shared table
------------------------------------------------------------

-- A later copy could put a data key in lib.shared with the name of a later
-- instance function. Read through __index, that value would look like the
-- function already being there, and the function would never be installed.
lib.shared.Engine = { "shared data, not a function" }
local fresh = setmetatable({ owner = "Probe", report = report }, lib.instanceMT)
lib._test.Migrate(fresh)
H.eq(type(rawget(fresh, "Engine")), "function", "a shared value never stands in for a function")
lib.shared.Engine = nil

H.done("test_new")
