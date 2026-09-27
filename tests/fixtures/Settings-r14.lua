-- ============================================================================
-- Settings.lua  -  one write path for an addon's saved table, and the two
-- checks that watch for the client being fixed or updated.
--
-- On WoW: Forever 1.60.1 nothing an addon writes survives a real restart:
-- account-wide and per-character SavedVariables, and CVars too. The fix is
-- Blizzard's. Until it lands, every addon on the library routes its settings
-- through one setter, so whatever the fix needs - a migration, a validation
-- pass, a different store - lands in one place instead of in each handler.
--
--     local settings = LibStub("LibGroupBuffs-1.0").Settings.New({
--         owner  = "Priestly",
--         scopes = {                     -- the FIRST scope is the settings store
--             { label = "per-character", get = function() ... return PriestlyDB end },
--             { label = "account-wide",  get = function() ... return PriestlySVCheck end },
--         },
--         measuredOnBuild = "69913",     -- in the addon's SOURCE; see CheckBuild
--         -- svBrokenSince / svBrokenOnBuild are accepted and no longer used; see CheckLoad
--         report    = function(text, kind) ... end,  -- required: the library never prints
--         onChanged = function(key) ... end,         -- optional
--     })
--     settings:Set("lockFrame", true)
--     settings:HandleEnteringWorld(isInitialLogin, isReloadingUi)
--
-- The addon owns its SavedVariables: `get` creates the table if it is missing
-- and returns it, and is called on every operation, never cached, so a table
-- replaced or cleared later is still the one written to.
-- ============================================================================

-- Same MINOR as Compat.lua; tests/test_versions.lua checks they agree. Compat
-- claims the version, so this file only installs when that claim is ours:
-- older after newer, the active MINOR is not ours; equal after equal, it is
-- already installed and reinstalling would replace functions others hold.
local MAJOR, MINOR = "LibGroupBuffs-1.0", 14
local lib, active = LibStub:GetLibrary(MAJOR, true)
if not lib or active ~= MINOR then return end
if lib.settingsMinor == MINOR then return end

-- Reused across upgrades. Objects hold the shared metatable, and methods are
-- assigned into the shared table, so an object made by an older copy runs the
-- newer methods once one loads.
lib.Settings = lib.Settings or {}
lib.SettingsMethods = lib.SettingsMethods or {}
lib.SettingsMeta = lib.SettingsMeta or {}
local Settings, Methods = lib.Settings, lib.SettingsMethods
lib.SettingsMeta.__index = Methods

-- Written by the load check, so no setter may touch it and no DEFAULTS table
-- may contain it: a default would recreate it every session, and the check
-- could never tell a real load from a fresh start.
Settings.LOAD_CHECK_KEY = "svLoadCheck"

local function Fail(msg) error("LibGroupBuffs Settings.New: " .. msg, 3) end

function Settings.New(spec)
    if type(spec) ~= "table" then Fail("spec must be a table") end
    if type(spec.owner) ~= "string" or spec.owner == "" then
        Fail("owner must name the addon")
    end
    if type(spec.report) ~= "function" then
        Fail("report must be a function - the checks would have no way to speak")
    end
    if spec.onChanged ~= nil and type(spec.onChanged) ~= "function" then
        Fail("onChanged must be a function or nil")
    end
    if type(spec.measuredOnBuild) ~= "string" or spec.measuredOnBuild == "" then
        Fail("measuredOnBuild must be a build number string")
    end
    -- Which build loading is broken on is no longer part of the decision:
    -- the marker carries the build it was written on, and that settles it
    -- (CheckLoad). Both names stay ACCEPTED so the three addons that pass one
    -- keep working until they drop it, and a wrong TYPE is still refused -
    -- silence about a field you passed is worse than an error.
    for _, key in ipairs({ "svBrokenSince", "svBrokenOnBuild" }) do
        if spec[key] ~= nil and (type(spec[key]) ~= "string" or spec[key] == "") then
            Fail(key .. " must be a build number string (it is no longer used; you may drop it)")
        end
    end
    if type(spec.scopes) ~= "table" or #spec.scopes == 0 then
        Fail("scopes must list at least one saved table; the first is the settings store")
    end
    local scopes = {}
    for i, scope in ipairs(spec.scopes) do
        if type(scope) ~= "table" or type(scope.label) ~= "string" or type(scope.get) ~= "function" then
            Fail("scope " .. i .. " needs a label and a get function")
        end
        scopes[i] = { label = scope.label, get = scope.get }
    end
    -- Nothing is created here: the addon's tables may not exist yet.
    return setmetatable({
        owner = spec.owner,
        scopes = scopes,
        report = spec.report,
        onChanged = spec.onChanged,
        measuredOnBuild = spec.measuredOnBuild,
    }, lib.SettingsMeta)
end

local function Store(self)
    local db = self.scopes[1].get()
    if type(db) ~= "table" then
        error(self.owner .. ": the settings scope's get returned no table", 3)
    end
    return db
end

local function Reserved(key)
    if key == Settings.LOAD_CHECK_KEY then
        error("LibGroupBuffs Settings: " .. key .. " belongs to the load check", 3)
    end
end

-- Report a write the owner made itself: a migration, a cache replaced from
-- inside a getter, a write through a local alias. No equality check - the
-- caller already knows it changed something.
function Methods:Changed(key)
    if self.onChanged then self.onChanged(key) end
end

-- An unchanged value is not a change: a caller that sets the same value on
-- every refresh would otherwise run the hook on a hot path. Tables are always
-- reported - the caller may have built a new one with new contents, and
-- comparing them is not this function's job.
function Methods:Set(key, value)
    Reserved(key)
    local db = Store(self)
    if type(value) ~= "table" and db[key] == value then return end
    db[key] = value
    self:Changed(key)
end

-- One entry of a nested table, created if missing. Reported under the table's
-- own key, since that is what was saved.
function Methods:SetIn(tableKey, subKey, value)
    Reserved(tableKey)
    local db = Store(self)
    local t = db[tableKey]
    if type(t) ~= "table" then
        t = {}
        db[tableKey] = t
    end
    if t[subKey] == value then return end
    t[subKey] = value
    self:Changed(tableKey)
end

-- API.ClientBuild answers "?" when the build cannot be read; for these checks
-- that is "unknown", never "a new build".
local function CurrentBuild()
    local api = lib.API
    local build = api and api.ClientBuild and api.ClientBuild()
    if not build or build == "?" then return nil end
    return build
end

-- --- Has Blizzard fixed it? --------------------------------------------------
--
-- Every scope keeps a marker, written every session. If it is there at login,
-- the client read that file. Each scope is checked on its own, because they
-- can be fixed separately.
--
-- A returning marker can still be a false positive, and each case is handled:
--
--   * /reload keeps the client running and can hand back its cached copy.
--     Never announced (`announce` is false).
--   * Logging out to character select and back in is an initial login in the
--     same process, and can be served from the same cache. Lua cannot tell it
--     from a real start, and no clock helps: GetTime on this client is system
--     uptime, not client uptime, so it does not reset across a restart either.
--   * Every login after a real fix, and every later patch. The marker
--     latches `loads` once a restart has proven loading works, and carries it
--     forward for as long as it keeps coming back.
--
-- THE MARKER ANSWERS THIS ITSELF, and no constant is needed for it.
--
-- It records the build it was written on. A build only changes when the
-- client is patched, and applying a patch requires a full exit - so a marker
-- that comes back carrying a DIFFERENT build than the one now running cannot
-- have come from the cache. That process is gone. It was read from disk, and
-- loading works.
--
-- The same build is the ambiguous case, and stays silent: it is what a relog
-- to character select looks like, and it is also what a healthy client looks
-- like session after session. Nothing is lost by saying nothing there. The
-- transition this check exists to catch - broken, then fixed - always arrives
-- WITH a patch, so it always arrives as a build change.
--
-- What this replaces, and why it was wrong in both directions: trusting any
-- build except one named constant announced a fix on every relog (#27, three
-- addons at once, on 69913 -> 69977, which patched WITHOUT fixing loading).
-- Presuming broken from a constant onward then took the noise away but left
-- the detector needing a human to re-measure and ship a new constant before
-- it could ever speak. This needs neither: it is the one comparison that is
-- actually decisive, and it is in data the addon already writes.
local function Marker(holder)
    local previous = holder[Settings.LOAD_CHECK_KEY]
    if type(previous) ~= "table" or previous.stamp == nil then return nil end
    return previous
end

-- A marker written by a build other than the one running now survived a
-- client restart. That proves loading works now, not that it was ever broken:
-- the first such marker is the fix, and the `loads` latch keeps each later
-- patch on a healthy client from announcing it again. An older copy of this library may not have stamped a build
-- at all; unknown is not evidence, so it stays silent.
local function CrossedARestart(previous, build)
    return previous ~= nil and build ~= nil
        and type(previous.build) == "string" and previous.build ~= ""
        and previous.build ~= build
end

function Methods:CheckLoad(announce)
    local build = CurrentBuild()
    local key = Settings.LOAD_CHECK_KEY

    local cameBack = {}
    for _, scope in ipairs(self.scopes) do
        local holder = scope.get()
        if type(holder) == "table" then
            local previous = Marker(holder)
            local crossed = CrossedARestart(previous, build)
            local proven = previous ~= nil and previous.loads == true
            if announce and crossed and not proven then
                cameBack[#cameBack + 1] = { label = scope.label, build = previous.build }
            end
            -- Rewritten with the build running NOW, which is what stops this
            -- repeating within a build: every later login reads its own build
            -- back. `loads` stops it repeating across builds: once a restart
            -- has proven loading, the next patch on a healthy client is not
            -- news. It lives only as long as the marker keeps coming back, so
            -- a REGRESSION clears it - the marker stops loading, a fresh one
            -- is written without it - and the fix after that speaks again.
            -- A /reload never sets it: it cannot follow a patch, so it would
            -- latch a claim nobody was told.
            holder[key] = {
                stamp = (type(date) == "function" and date("%Y-%m-%d %H:%M:%S")) or "?",
                build = build,
                loads = (proven or (announce and crossed)) or nil,
            }
        end
    end
    self:Changed(key)

    if #cameBack == 0 then return end
    local labels, builds, oneBuild = {}, {}, true
    for i, entry in ipairs(cameBack) do
        labels[i] = entry.label
        builds[i] = entry.build .. " (" .. entry.label .. ")"
        if entry.build ~= cameBack[1].build then oneBuild = false end
    end
    -- Each scope's marker carries its own build: one character can last have
    -- played on an older build than the account-wide table another updated.
    local saved = oneBuild and ("game build " .. cameBack[1].build)
        or ("game builds " .. table.concat(builds, " and "))
    self.report("Saved settings came back (" .. table.concat(labels, " and ")
        .. "). They were saved on " .. saved .. " and read back on " .. tostring(build)
        .. ", so the game was fully restarted in between - the settings bug is fixed.",
        "settingsLoaded")
end

-- --- Which build were the findings measured on? -----------------------------
--
-- The addon's notes on how this beta behaves were measured on one client
-- build, and the beta updates without announcement. The build lives in the
-- addon's SOURCE, the one thing that survives a restart here: a stored build
-- could never fire, because the build only changes across a restart, which is
-- when stored data is lost.
--
-- Reported at every real login until someone re-measures and bumps the
-- constant. Deliberately not latched: a notice shown once and missed would
-- leave the addon running on stale findings with nothing left to say so.
function Methods:CheckBuild()
    local build = CurrentBuild()
    if not build or build == self.measuredOnBuild then return end
    self.report("This version was tested on game build " .. self.measuredOnBuild
        .. "; you are on " .. build .. ". It should still work, but if anything "
        .. "misbehaves, please report it.", "newBuild")
end

-- PLAYER_LOGIN fires on /reload too and cannot tell the two apart.
-- PLAYER_ENTERING_WORLD can: on 1.60.1.69913 it carries (isInitialLogin,
-- isReloadingUi). It also fires on every zone change with both false, which
-- is ignored. The addon registers the event and passes the payload on.
function Methods:HandleEnteringWorld(isInitialLogin, isReloadingUi)
    if not (isInitialLogin or isReloadingUi) then return end
    local realLogin = isInitialLogin and not isReloadingUi
    self:CheckLoad(realLogin)
    if realLogin then self:CheckBuild() end
end

-- Last, so a file that threw partway through is not marked installed.
lib.settingsMinor = MINOR
lib.fileMinors.Settings = MINOR
