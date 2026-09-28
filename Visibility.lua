-- ============================================================================
-- Visibility.lua  -  when the window opens itself, and when it must not.
--
-- Priestly, Wildly and Magely each carried their own copy of this, near
-- line-for-line, and the copies produced five separate defects: a roster
-- arriving after login counting as a join, a settings change reopening a
-- window the player closed, a solo toggle dropped in combat, and two more
-- besides. Each was found in one addon, fixed there, and left standing in the
-- others (LibGroupBuffs#22).
--
-- So the DECISION lives here. The addon still owns its events, its slash
-- commands and its class: it reports what changed, this decides whether that
-- warrants opening, closing or refreshing, and UI carries the request out
-- safely.
--
--     local vis = LibStub("LibGroupBuffs-1.0").Visibility.New({
--         ui            = ui,
--         isMyClass     = function() return g_IsPriest end,   -- optional
--         showSolo      = function() return Priestly_ShowSolo() end,
--         getPreference = function() return Priestly_WindowVisible() end,
--         setPreference = function(v) Priestly_SetWindowVisible(v) end,
--     })
--
-- and from the addon's own event handler:
--
--     vis:Login()            -- a new session; opens if it should
--     vis:ReadyCheck()
--     vis:GroupJoined()      -- the client's own join event
--     vis:RosterChanged()    -- after the host has pruned its caches
--     vis:SoloToggled(on)
--     vis:ContentChanged()   -- something may have given the window rows
--
-- PREFERENCE is not VISIBILITY. `getPreference` is the saved "the player wants
-- this window", which is true, false, or nil for never said; `ui:IsVisible()`
-- is whether the window is logically open right now, and the two disagree all
-- the time - in combat the frame can still be on screen after a close, and a
-- window that closed itself for want of rows never wrote false. Never cache
-- the preference: the close button and the addon's own slash commands change
-- it without passing through here.
-- ============================================================================

-- Same MINOR as Compat.lua; tests/test_versions.lua checks they agree. Compat
-- claims the version, so this file only installs when that claim is ours.
local MAJOR, MINOR = "LibGroupBuffs-1.0", 24
local lib, active = LibStub:GetLibrary(MAJOR, true)
if not lib or active ~= MINOR then return end
if lib.visibilityMinor == MINOR then return end

-- Reused across upgrades. Objects hold the shared metatable, and methods are
-- assigned into the shared table, so an object an older copy made runs the
-- newer methods once one loads - including one that has already observed a
-- roster or latched a join, which is the state that matters.
lib.Visibility = lib.Visibility or {}
lib.VisibilityMethods = lib.VisibilityMethods or {}
lib.VisibilityMeta = lib.VisibilityMeta or {}
local Visibility, Methods = lib.Visibility, lib.VisibilityMethods
lib.VisibilityMeta.__index = Methods

local function Fail(msg)
    error("LibGroupBuffs Visibility: " .. msg, 3)
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    return fn(...)
end

function Visibility.New(spec)
    if type(spec) ~= "table" then Fail("New(spec) needs a table") end
    if type(spec.ui) ~= "table" then Fail("spec.ui must be the window object") end
    for _, name in ipairs({ "getPreference", "setPreference" }) do
        if type(spec[name]) ~= "function" then
            Fail(name .. " must be a function: the addon owns where its settings live")
        end
    end
    for _, name in ipairs({ "isMyClass", "showSolo" }) do
        if spec[name] ~= nil and type(spec[name]) ~= "function" then
            Fail(name .. " must be a function or nil")
        end
    end

    local self = setmetatable({
        ui            = spec.ui,
        isMyClass     = spec.isMyClass,
        showSolo      = spec.showSolo,
        getPreference = spec.getPreference,
        setPreference = spec.setPreference,
        -- How many people we have SEEN, or nil for "not looked yet". The
        -- difference is the whole point: a join is a 0-to-n change where the 0
        -- was observed, and GetNumGroupMembers() can read 0 at login while
        -- already in a group.
        lastGroupSize = nil,
        -- Set by the client's own join event, spent by the roster that follows.
        joinedPending = false,
    }, lib.VisibilityMeta)
    return self
end

-- Is this addon's window for this character at all? A host that does not say
-- is always eligible.
function Methods:Eligible()
    if self.isMyClass == nil then return true end
    return Call(self.isMyClass) and true or false
end

-- Would the window open by itself right now? In a group, or solo mode - and
-- never over a close the player asked for.
function Methods:WantsOpen()
    if not self:Eligible() then return false end
    if Call(self.getPreference) == false then return false end
    if GetNumGroupMembers() > 0 then return true end
    return Call(self.showSolo) and true or false
end

-- A new session. Whatever was seen before this login was not seen in it, and
-- an upgrade mid-session deliberately does NOT reset these - only a login does.
function Methods:Login()
    self.lastGroupSize = nil
    self.joinedPending = false
    if self:WantsOpen() then self.ui:Open(0.6) end
end

-- A ready check is a good moment to rebuff, but not a reason to override
-- someone who closed the window.
function Methods:ReadyCheck()
    if not self:Eligible() then return end
    if Call(self.getPreference) == false then return end
    self.ui:Open(0.4)
end

-- The client saying you joined, rather than us inferring it from the roster
-- changing. It fires: Blizzard's own UI for this build registers and acts on
-- it (Blizzard_DamageMeter/DamageMeter.lua:78 in C:/Projects/wow-ui-source).
-- Latched rather than acted on here: the roster that follows is what knows how
-- many people there are.
function Methods:GroupJoined()
    self.joinedPending = true
end

-- The roster changed. Joining is the one case that reopens a window the player
-- deliberately closed - that is advertised behaviour - and any other churn
-- leaves the close alone.
function Methods:RosterChanged()
    local n = GetNumGroupMembers()
    -- The join event if the client sent one, and otherwise the roster: nil is
    -- not 0, so the first roster we ever see tells us where we are and not
    -- that somebody just invited us. The event is what makes logging in alone
    -- and then being invited work, because there may be no zero-member roster
    -- in between for the fallback to measure against.
    local joined = self.joinedPending or (self.lastGroupSize == 0 and n > 0)
    self.joinedPending = false
    self.lastGroupSize = n

    if joined then Call(self.setPreference, true) end
    local ui = self.ui
    if n > 0 and not ui:IsVisible() and self:Eligible()
        and (joined or Call(self.getPreference) ~= false)
    then
        ui:Open(0.5)
    elseif n == 0 and not (Call(self.showSolo) and true or false) then
        ui:Close()   -- auto-close, not manual
    else
        ui:ScheduleRefresh()
    end
end

-- The solo checkbox. Not refused in combat: ui:Open and ui:Close both remember
-- what was asked and carry it out when the fight ends, so ticking the box
-- mid-fight is honoured rather than lost.
function Methods:SoloToggled(enabled)
    if not self:Eligible() then return end
    local ui = self.ui
    if enabled then
        if not ui:IsVisible() then
            Call(self.setPreference, true)
            ui:Open(0.1)
        end
    elseif GetNumGroupMembers() == 0 then
        ui:Close()
    end
end

-- Something may have given the window rows, or taken them away: a setting, a
-- spell learned, a tank appearing, an aura landing. One method for all of
-- them, because the decision is the same and splitting it is what left copies
-- of it in each host's handlers.
--
-- A window that closed ITSELF for want of rows is not a close the player
-- asked for, so this may reopen it - WantsOpen is what tells the two apart.
-- Whether the notification is meaningful at all stays with the host: Magely
-- does not ask after an aura in combat, because an aura cannot be read then.
function Methods:ContentChanged()
    local ui = self.ui
    if ui:IsVisible() then
        if not InCombatLockdown() then ui:Open(0.1) end
    elseif self:WantsOpen() then
        ui:Open(0.1)
    end
end

-- Last, so a file that threw partway through is not marked installed.
lib.visibilityMinor = MINOR
lib.fileMinors.Visibility = MINOR
