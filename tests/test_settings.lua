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

-- Today: loading broken, nothing came back. Nothing announced, markers written.
h = freshSession(BROKEN)
h.settings:HandleEnteringWorld(true, false)
H.eq(saidKind(h, "settingsLoaded"), "", "no marker at login, nothing announced")
H.check(type(h.char.svLoadCheck) == "table", "the first scope's marker is written")
H.check(type(h.account.svLoadCheck) == "table", "and the second's")
H.eq(h.char.svLoadCheck.build, BROKEN, "with the build it was written on")
local reports = 0
for _, key in ipairs(h.changed) do if key == "svLoadCheck" then reports = reports + 1 end end
H.eq(reports, 1, "reported once for all scopes, not once per scope")

-- The marker back on the SAME build: a relog to character select, or a
-- healthy client on an ordinary day. Indistinguishable, so it says nothing.
h.settings:HandleEnteringWorld(true, false)
H.eq(saidKind(h, "settingsLoaded"), "",
    "a marker returning on the same build could be the client's cache, so it is not news")
h.settings:HandleEnteringWorld(false, true)
H.eq(saidKind(h, "settingsLoaded"), "", "and a /reload never announces")

local marker = h.char.svLoadCheck
h.settings:HandleEnteringWorld(false, false)
H.check(h.char.svLoadCheck == marker, "a zone change leaves the marker alone")
h.settings:HandleEnteringWorld(false, true)
H.check(h.char.svLoadCheck ~= marker, "a /reload renews it")

-- The fix, and the only thing that proves it: the marker comes back carrying
-- a DIFFERENT build. A build only changes when the client is patched, and
-- applying a patch requires a full exit - so the process that held the cache
-- is gone, and this was read from disk.
WoW.build = FIXED
h.settings:HandleEnteringWorld(true, false)
local msg = saidKind(h, "settingsLoaded")
H.check(msg:find("came back", 1, true),
    "a marker written on an earlier build is the fix, announced: " .. msg)
H.check(msg:find(BROKEN, 1, true) and msg:find(FIXED, 1, true),
    "naming the build it was saved on and the one it was read on: " .. msg)
H.check(msg:find("fully restarted", 1, true),
    "and why that settles it - the game restarted in between: " .. msg)
H.check(msg:find("is fixed", 1, true), "so it can say so plainly: " .. msg)
H.check(msg:find("per-character", 1, true) and msg:find("account-wide", 1, true),
    "naming the scopes that came back: " .. msg)
H.check(not msg:find("|c", 1, true), "plain text: colour is the host's business")

-- Once: the marker is rewritten with the build running now, so every later
-- login this session reads its own build back and has nothing to report.
local n = #h.said
h.settings:HandleEnteringWorld(true, false)
local repeated = false
for i = n + 1, #h.said do if h.said[i].kind == "settingsLoaded" then repeated = true end end
H.check(not repeated, "it does not repeat at the next login on that build")
H.eq(h.char.svLoadCheck.build, FIXED, "because the marker now carries the current build")

-- The next patch hands it back again, from the build before it. Still true,
-- still worth saying once - and it is what keeps a REGRESSION visible: if a
-- patch breaks loading again, the marker simply stops coming back.
WoW.build = "70500"
n = #h.said
h.settings:HandleEnteringWorld(true, false)
msg = ""
for i = n + 1, #h.said do
    if h.said[i].kind == "settingsLoaded" then msg = h.said[i].text end
end
H.check(msg:find("70500", 1, true) and msg:find(FIXED, 1, true),
    "a later patch says it again, naming both builds: " .. msg)

-- Not even one that WOULD be news. A /reload cannot follow a patch without a
-- login in between, so this is insurance rather than a live case: whatever
-- calls CheckLoad later, the rule stays "never on a /reload".
do
    local r = freshSession(FIXED)
    r.char = { svLoadCheck = { stamp = "then", build = BROKEN } }
    r.settings:HandleEnteringWorld(false, true)
    H.eq(saidKind(r, "settingsLoaded"), "",
        "a /reload stays silent even holding a marker from an earlier build")
end

-- A marker with NO build: written by an older copy of this library, before it
-- stamped one. Unknown is not evidence.
h = freshSession(FIXED)
h.char = { svLoadCheck = { stamp = "then" } }
h.settings:HandleEnteringWorld(true, false)
H.eq(saidKind(h, "settingsLoaded"), "", "a marker with no build announces nothing")

-- One scope coming back on its own is worth knowing.
h = freshSession(FIXED)
h.account = { svLoadCheck = { stamp = "then", build = BROKEN } }
h.settings:HandleEnteringWorld(true, false)
msg = saidKind(h, "settingsLoaded")
H.check(msg:find("account-wide", 1, true) and not msg:find("per-character", 1, true),
    "a scope that came back alone is reported as that: " .. msg)

-- An unreadable build is not evidence of anything.
h = freshSession(FIXED)
h.char = { svLoadCheck = { stamp = "then", build = BROKEN } }
local realClientBuild = lib.API.ClientBuild
lib.API.ClientBuild = function() return nil end    -- GetBuildInfo failed
h.settings:HandleEnteringWorld(true, false)
H.eq(saidKind(h, "settingsLoaded"), "", "an unknown build announces nothing")
lib.API.ClientBuild = realClientBuild

-- A host with one account-wide table, like Wildly and Magely: the marker lives
-- in the settings store itself.
h = freshSession(FIXED, { oneScope = true })
h.char = { svLoadCheck = { stamp = "then", build = BROKEN } }
h.settings:HandleEnteringWorld(true, false)
H.check(saidKind(h, "settingsLoaded"):find("came back", 1, true),
    "a single-scope host is checked the same way")

-- The old constants are accepted and ignored, so the three addons that still
-- pass one keep working; a wrong type is still refused, because silence about
-- a field you passed is worse than an error.
h = freshSession(FIXED, { specAlias = true })
h.char = { svLoadCheck = { stamp = "then", build = BROKEN } }
h.settings:HandleEnteringWorld(true, false)
H.check(saidKind(h, "settingsLoaded"):find("came back", 1, true),
    "a host still passing svBrokenOnBuild is unaffected")
H.check(pcall(Settings.New, spec({ svBrokenSince = nil, svBrokenOnBuild = nil })),
    "and a host that has dropped it entirely builds")
H.check(not pcall(Settings.New, spec({ svBrokenSince = 7 })),
    "but a non-string is refused rather than silently ignored")

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
