------------------------------------------------------------
-- test_settings.lua - the settings write path, the SavedVariables-fix
-- detector and the build watch (Settings.lua).
--
-- Ported from Priestly's tests/test_config_seam.lua, which covered the same
-- code before it moved here, and made addon-agnostic: a "host" below is any
-- addon, with its own saved tables and reporter.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_settings.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
local lib = H.loadLibrary()
local Settings = lib.Settings

-- FIXED is NEWER than BROKEN, which is the whole point now: builds compare
-- as numbers, and anything at or below BROKEN is presumed broken.
local BROKEN, MEASURED, FIXED = "69913", "69913", "70123"
local OLDER = "69800"   -- a build BEHIND the one loading broke on

-- A host with a per-character store and an account-wide check table, like
-- Priestly. The tables are globals in the addon; plain upvalues here, reached
-- only through the accessors, which is all the library ever sees.
local function Host(owner, opts)
    opts = opts or {}
    local h = { said = {}, changed = {}, char = nil, account = nil }
    local scopes = {
        { label = "per-character", get = function()
            if not h.char then h.char = {} end
            return h.char
        end },
    }
    if not opts.oneScope then
        scopes[2] = { label = "account-wide", get = function()
            if not h.account then h.account = {} end
            return h.account
        end }
    end
    h.settings = Settings.New({
        owner = owner,
        scopes = scopes,
        measuredOnBuild = opts.measured or MEASURED,
        svBrokenSince = (not opts.specAlias) and (opts.broken or BROKEN) or nil,
        svBrokenOnBuild = opts.specAlias and (opts.broken or BROKEN) or nil,
        report = function(text, kind) h.said[#h.said + 1] = { text = text, kind = kind } end,
        onChanged = function(key) h.changed[#h.changed + 1] = key end,
    })
    return h
end

-- The newest message of one kind; a real login on a new build can report both.
local function saidKind(h, kind)
    for i = #h.said, 1, -1 do
        if h.said[i].kind == kind then return h.said[i].text end
    end
    return ""
end

------------------------------------------------------------
-- Construction
------------------------------------------------------------

local function spec(over)
    local s = {
        owner = "Test", report = function() end,
        measuredOnBuild = "1", svBrokenSince = "1",
        scopes = { { label = "x", get = function() return {} end } },
    }
    for k, v in pairs(over) do s[k] = v end
    return s
end
H.check(pcall(Settings.New, spec({})), "a complete spec builds")
H.check(not pcall(Settings.New, spec({ report = false })),
    "no reporter is an error - the checks would have no way to speak")
H.check(not pcall(Settings.New, spec({ owner = "" })), "no owner is an error")
H.check(not pcall(Settings.New, spec({ scopes = {} })), "no scopes is an error")
H.check(not pcall(Settings.New, spec({ scopes = { { label = "x" } } })),
    "a scope without an accessor is an error")
H.check(not pcall(Settings.New, spec({ measuredOnBuild = 69913 })),
    "a build that is not a string is an error: GetBuildInfo returns strings")
H.check(not pcall(Settings.New, spec({ onChanged = "yes" })), "a non-function hook is an error")

local created = false
Settings.New(spec({ scopes = { { label = "x", get = function() created = true return {} end } } }))
H.check(not created, "construction touches no saved table")

------------------------------------------------------------
-- The setters
------------------------------------------------------------

WoW.reset()
local h = Host("Priestly")
local s = h.settings

s:Set("frameAlpha", 0.5)
H.eq(h.char and h.char.frameAlpha, 0.5, "Set creates the store when missing, and assigns")
H.eq(h.changed[#h.changed], "frameAlpha", "and reports the key")

s:Set("pos", { point = "RIGHT" })
s:Set("pos", nil)
H.eq(h.char.pos, nil, "Set can clear a key that was set")
H.eq(h.changed[#h.changed], "pos", "and reports the clear")

local count = #h.changed
s:Set("frameAlpha", 0.5)
H.eq(#h.changed, count, "setting the same value again does not report")
local t = {}
s:Set("list", t)
s:Set("list", t)
H.eq(#h.changed, count + 2, "a table is reported every time, even the same one")

-- The store is fetched on every call, never cached: the addon may replace or
-- clear its table, and the write must land in the one that is there now.
h.char = nil
s:Set("lockFrame", true)
H.eq(h.char and h.char.lockFrame, true, "a cleared store is recreated through the accessor")
local replacement = {}
h.char = replacement
s:Set("lockFrame", true)
H.eq(replacement.lockFrame, true, "and a replaced one is the one written to")

s:SetIn("shadowInstances", "Scholomance", false)
H.eq(h.char.shadowInstances and h.char.shadowInstances.Scholomance, false,
    "SetIn creates the nested table and writes one entry")
H.eq(h.changed[#h.changed], "shadowInstances", "reported under the table's own key")
count = #h.changed
s:SetIn("shadowInstances", "Scholomance", false)
H.eq(#h.changed, count, "an unchanged entry does not report")

count = #h.changed
s:Changed("learnedDurations")
H.eq(h.changed[#h.changed], "learnedDurations", "Changed reports a write the owner made itself")
H.eq(#h.changed, count + 1, "exactly once")

H.check(not pcall(s.Set, s, "svLoadCheck", {}), "the load check's key cannot be Set")
H.check(not pcall(s.SetIn, s, "svLoadCheck", "x", 1), "or SetIn")

-- The hook is optional.
local quiet = Settings.New(spec({}))
H.check(pcall(quiet.Set, quiet, "a", 1), "a host without onChanged can still Set")

------------------------------------------------------------
-- The load check: has Blizzard fixed it?
------------------------------------------------------------

local function freshSession(build, opts)
    WoW.reset()
    WoW.build = build
    return Host("Priestly", opts)
end

-- Today: broken build, nothing loaded. Nothing announced, markers written.
h = freshSession(BROKEN)
h.settings:HandleEnteringWorld(true, false)
H.eq(#h.said, 0, "no marker at login, nothing announced - today's state")
H.check(type(h.char.svLoadCheck) == "table", "the first scope's marker is written")
H.check(type(h.account.svLoadCheck) == "table", "and the second's")
H.eq(h.char.svLoadCheck.build, BROKEN, "with the build it was written on")
local reports = 0
for _, key in ipairs(h.changed) do if key == "svLoadCheck" then reports = reports + 1 end end
H.eq(reports, 1, "reported once for all scopes, not once per scope")

-- The broken build with the marker still in memory: a relog or /reload served
-- from the client's cache. Neither may announce.
h.settings:HandleEnteringWorld(true, false)
H.eq(#h.said, 0, "on the broken build a returning marker is the client's cache, not a fix")
h.settings:HandleEnteringWorld(false, true)
H.eq(#h.said, 0, "and a /reload never announces")

local marker = h.char.svLoadCheck
h.settings:HandleEnteringWorld(false, false)
H.check(h.char.svLoadCheck == marker, "a zone change leaves the marker alone")
h.settings:HandleEnteringWorld(false, true)
H.check(h.char.svLoadCheck ~= marker, "a /reload renews it")

-- A build BEHIND the one loading broke on is presumed broken too. Nothing
-- was ever measured there, and a relog on it looks the same as everywhere
-- else - a player who has not updated must not be told the bug is gone.
h = freshSession(OLDER)
h.char = { svLoadCheck = { stamp = "then", build = OLDER } }
h.settings:HandleEnteringWorld(true, false)
-- The build notice fires here too - it is a different detector, and this
-- build is not the measured one either - so ask about the settings message.
H.eq(saidKind(h, "settingsUnverified"), "",
    "a build older than svBrokenSince announces nothing either")

-- A build PAST it: unproven, not fixed. Something is said, because a real fix
-- is worth catching, but it claims nothing and carries no green kind.
h = freshSession(BROKEN)
h.settings:HandleEnteringWorld(true, false)
WoW.build = FIXED
h.settings:HandleEnteringWorld(true, false)
local msg = saidKind(h, "settingsUnverified")
H.check(msg:find("came back", 1, true),
    "a returning marker on a newer build is reported, tagged for the host: " .. msg)
H.check(msg:find("has not been checked", 1, true), "as unchecked, not as a fix: " .. msg)
H.check(not msg:find("the settings bug is fixed", 1, true),
    "never claiming the fix, which a relog would fake: " .. msg)
H.check(msg:find("fully exited", 1, true) and msg:find("rather than relogging", 1, true),
    "naming the one procedure that would make it news: " .. msg)
H.check(msg:find("report", 1, true), "and asking for that report: " .. msg)
H.check(msg:find("per-character", 1, true) and msg:find("account-wide", 1, true),
    "naming the scopes that came back: " .. msg)
H.check(msg:find(FIXED, 1, true), "and the build: " .. msg)
H.check(not msg:find("|c", 1, true), "plain text: colour is the host's business")
H.eq(saidKind(h, "settingsLoaded"), "",
    "the old kind is gone, so a host's green styling cannot fire on a guess")

-- Once per build: the latch persists by then, because the store works.
local n = #h.said
h.settings:HandleEnteringWorld(true, false)
local repeated = false
for i = n + 1, #h.said do
    if h.said[i].kind == "settingsUnverified" then repeated = true end
end
H.check(not repeated, "it does not repeat at the next login on that build")

-- But a LATER build is a different claim about a different client, so the
-- latch does not carry over. This is what the old single-build check got
-- wrong in the other direction: a patch that does not fix loading also
-- changes the build.
WoW.build = "70500"
n = #h.said
h.settings:HandleEnteringWorld(true, false)
msg = ""
for i = n + 1, #h.said do
    if h.said[i].kind == "settingsUnverified" then msg = h.said[i].text end
end
H.check(msg:find("70500", 1, true), "a later build asks again, naming it: " .. msg)

-- One scope coming back on its own is worth knowing.
h = freshSession(FIXED)
h.account = { svLoadCheck = { stamp = "then", build = FIXED } }
h.settings:HandleEnteringWorld(true, false)
msg = saidKind(h, "settingsUnverified")
H.check(msg:find("account-wide", 1, true) and not msg:find("per-character", 1, true),
    "a fix to one scope alone is reported as that: " .. msg)

-- An unreadable build is not evidence of anything.
h = freshSession(FIXED)
h.char = { svLoadCheck = { stamp = "then" } }
local realClientBuild = lib.API.ClientBuild
lib.API.ClientBuild = function() return "?" end    -- GetBuildInfo failed
h.settings:HandleEnteringWorld(true, false)
H.eq(#h.said, 0, "an unknown build announces nothing")
lib.API.ClientBuild = realClientBuild

-- A host with one account-wide table, like Wildly and Magely: the marker lives
-- in the settings store itself.
h = freshSession(FIXED, { oneScope = true })
h.char = { svLoadCheck = { stamp = "then" } }
h.settings:HandleEnteringWorld(true, false)
H.check(saidKind(h, "settingsUnverified"):find("came back", 1, true),
    "a single-scope host is checked the same way")

-- A build string that will not compare is presumed broken, not assumed newer.
h = freshSession(FIXED)
h.char = { svLoadCheck = { stamp = "then" } }
local realBuild = lib.API.ClientBuild
lib.API.ClientBuild = function() return "1.60.1-ptr" end
h.settings:HandleEnteringWorld(true, false)
H.eq(saidKind(h, "settingsUnverified"), "", "a build that is not a number announces nothing")
lib.API.ClientBuild = realBuild

-- The old spec name still works, because three addons pin their own tags and
-- adopt on their own schedule. Both names at once is refused instead.
h = freshSession(FIXED, { specAlias = true })
h.char = { svLoadCheck = { stamp = "then" } }
h.settings:HandleEnteringWorld(true, false)
H.check(saidKind(h, "settingsUnverified"):find("came back", 1, true),
    "svBrokenOnBuild is accepted as the old name for svBrokenSince")
H.check(not pcall(Settings.New, spec({ svBrokenSince = "1", svBrokenOnBuild = "1" })),
    "but not both at once, which would disagree the moment one moved")

------------------------------------------------------------
-- The build watch
------------------------------------------------------------

local function warned(h)
    for _, s in ipairs(h.said) do if s.kind == "newBuild" then return s.text end end
    return nil
end

h = freshSession(MEASURED)
h.settings:HandleEnteringWorld(true, false)
H.eq(warned(h), nil, "the measured build is silent")

h = freshSession(FIXED)
h.settings:HandleEnteringWorld(false, true)
H.eq(warned(h), nil, "a /reload never shows the build warning")
h.settings:HandleEnteringWorld(false, false)
H.eq(warned(h), nil, "nor a zone change")

h.settings:HandleEnteringWorld(true, false)
msg = warned(h) or ""
H.check(msg:find(FIXED, 1, true) and msg:find(MEASURED, 1, true),
    "a real login on a new build warns, naming both: " .. msg)
H.check(msg:find("report", 1, true), "worded for players: " .. msg)
H.check(not msg:find("MEASURED", 1, true), "with no developer vocabulary: " .. msg)

-- Not latched: it repeats at every real login until the constant is bumped.
h.said = {}
h.settings:HandleEnteringWorld(true, false)
H.check(warned(h) ~= nil, "it warns again at the next real login")
for key in pairs(h.char) do
    H.check(key ~= "warnedBuild", "and records nothing that could silence it")
end

h = freshSession(FIXED)
lib.API.ClientBuild = function() return "?" end
h.settings:HandleEnteringWorld(true, false)
H.eq(warned(h), nil, "an unreadable build is not a new one")
lib.API.ClientBuild = realClientBuild

------------------------------------------------------------
-- Two addons on one library: nothing shared but the code
------------------------------------------------------------

WoW.reset()
WoW.build = FIXED
local p, w = Host("Priestly"), Host("Wildly", { oneScope = true, measured = FIXED })
p.settings:Set("lockFrame", true)
H.eq(w.char, nil, "one addon's write does not touch another's store")
H.eq(#w.changed, 0, "or run its hook")
w.settings:HandleEnteringWorld(true, false)
p.settings:HandleEnteringWorld(true, false)
H.eq(warned(w), nil, "each addon has its own measured build")
H.check(warned(p) ~= nil, "so one can warn while the other is current")
H.check(getmetatable(p.settings) == getmetatable(w.settings),
    "and both run the one shared set of methods, so an upgrade reaches both")

H.done("test_settings")
