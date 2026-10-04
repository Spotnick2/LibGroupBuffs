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

ok, err = pcall(lib.New, lib, { owner = "Priestly", report = report, needs = MINOR + 1 })
H.check(not ok and tostring(err):find("out of date", 1, true),
    "a copy older than the host needs is too old, and says nothing crashed: " .. tostring(err))
H.check(not tostring(err):find("lua:", 1, true), "a message for players, with no file position")

local ready = lib.ready
lib.ready = MINOR - 1
ok, err = pcall(lib.New, lib, { owner = "Priestly", report = report })
H.check(not ok and tostring(err):find("did not finish loading", 1, true),
    "a copy that did not finish is refused: " .. tostring(err))
lib.ready = ready

local glassLib = LibStub("LibGlass-1.0")
local glassReady = glassLib.ready
glassLib.ready = nil
ok, err = pcall(lib.New, lib, { owner = "Priestly", report = report })
H.check(not ok and tostring(err):find("needs LibGlass-1.0", 1, true),
    "and so is one whose LibGlass is not usable: " .. tostring(err))
glassLib.ready = glassReady
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

H.done("test_new")
