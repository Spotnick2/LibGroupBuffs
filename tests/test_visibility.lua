------------------------------------------------------------
-- test_visibility.lua - when the window opens itself, and when it must not.
--
-- This decision used to live in each addon, near line-for-line, and the copies
-- produced five defects: a roster arriving after login counting as a join, a
-- settings change reopening a window the player closed, a solo toggle dropped
-- in combat, and two more. Each was found in one addon, fixed there, and left
-- standing in the others (#22).
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_visibility.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
H.loadLibrary()
local lib = LibStub("LibGroupBuffs-1.0")

-- A window stand-in. The real UI is exercised in test_ui_window.lua; what
-- matters here is WHICH request the policy makes, so this records them.
local function fakeUI()
    local ui = { calls = {}, visible = false }
    function ui:IsVisible() return self.visible end
    function ui:Open(delay) self.calls[#self.calls + 1] = { "open", delay } end
    function ui:Close() self.calls[#self.calls + 1] = { "close" } end
    function ui:ScheduleRefresh() self.calls[#self.calls + 1] = { "refresh" } end
    function ui:last() return self.calls[#self.calls] and self.calls[#self.calls][1] end
    function ui:clear() self.calls = {} end
    return ui
end

local function newPolicy(opts)
    opts = opts or {}
    local host = {
        ui = fakeUI(),
        preference = opts.preference,   -- true / false / nil
        solo = opts.solo or false,
        eligible = (opts.eligible ~= false),
    }
    host.vis = lib.Visibility.New({
        ui            = host.ui,
        isMyClass     = function() return host.eligible end,
        showSolo      = function() return host.solo end,
        getPreference = function() return host.preference end,
        setPreference = function(v) host.preference = v end,
    })
    return host
end

------------------------------------------------------------
-- The spec is checked, because a typo here is a window that never opens
------------------------------------------------------------

H.check(not pcall(lib.Visibility.New), "New() needs a spec")
H.check(not pcall(lib.Visibility.New, { getPreference = function() end,
    setPreference = function() end }), "and a ui")
H.check(not pcall(lib.Visibility.New, { ui = {}, setPreference = function() end }),
    "and somewhere to read the player's preference")
H.check(not pcall(lib.Visibility.New, { ui = {}, getPreference = function() end }),
    "and somewhere to write it")
H.check(not pcall(lib.Visibility.New, { ui = {}, getPreference = function() end,
    setPreference = function() end, showSolo = "yes" }),
    "a hook that is not a function is an error")
H.check(pcall(lib.Visibility.New, { ui = {}, getPreference = function() end,
    setPreference = function() end }), "isMyClass and showSolo are optional")

------------------------------------------------------------
-- Login
------------------------------------------------------------

WoW.reset()
WoW.groupMembers = 3
local h = newPolicy()
h.vis:Login()
H.eq(h.ui:last(), "open", "a fresh login in a group opens the window")

WoW.reset()
local alone = newPolicy()
alone.vis:Login()
H.eq(alone.ui:last(), nil, "logging in alone does not")

WoW.reset()
local soloOn = newPolicy({ solo = true })
soloOn.vis:Login()
H.eq(soloOn.ui:last(), "open", "unless solo display is on")

WoW.reset()
WoW.groupMembers = 3
local closed = newPolicy({ preference = false })
closed.vis:Login()
H.eq(closed.ui:last(), nil, "and a window the player closed stays closed")

WoW.reset()
WoW.groupMembers = 3
local other = newPolicy({ eligible = false })
other.vis:Login()
H.eq(other.ui:last(), nil, "nor does it open for a character it is not for")

------------------------------------------------------------
-- A roster arriving after login is the client catching up, not a join
--
-- GetNumGroupMembers() can read 0 at login while already in a group. Treating
-- that 0-to-n change as a join reopened a window the player closed AND
-- overwrote the preference, every login.
------------------------------------------------------------

WoW.reset()
local catchUp = newPolicy({ preference = false })
catchUp.vis:Login()
WoW.groupMembers = 5
catchUp.ui:clear()
catchUp.vis:RosterChanged()
H.eq(catchUp.preference, false, "the first roster of a session is not a join")
H.eq(catchUp.ui:last(), "refresh", "and the window is not opened")

-- ...but once we have SEEN them alone, an invite is a real join.
WoW.groupMembers = 0
catchUp.vis:RosterChanged()
WoW.groupMembers = 4
catchUp.ui:clear()
catchUp.vis:RosterChanged()
H.eq(catchUp.preference, true, "a 0-to-n change we watched happen is a join")
H.eq(catchUp.ui:last(), "open", "and it reopens the window")

------------------------------------------------------------
-- A login forgets what the session before it saw
--
-- Every other case here builds a fresh object, so none of them can tell
-- whether Login clears the observation or merely inherits a clean one. This
-- one logs in on an object that has already watched a roster - which is what
-- a /reload is - and the reset is what makes the rule true rather than
-- incidentally true.
------------------------------------------------------------

WoW.reset()
local reloaded = newPolicy({ preference = false })
WoW.groupMembers = 0
reloaded.vis:RosterChanged()          -- seen them alone, in the session before
H.eq(reloaded.vis.lastGroupSize, 0, "the old session saw an empty group")

reloaded.vis:Login()
H.eq(reloaded.vis.lastGroupSize, nil, "and the new one has not looked yet")
WoW.groupMembers = 5
reloaded.ui:clear()
reloaded.vis:RosterChanged()
H.eq(reloaded.preference, false,
    "so the roster arriving after THIS login is not a join either")

------------------------------------------------------------
-- The client's own join event, for when there was no 0 to watch
--
-- Log in alone, get invited, and if no zero-member roster arrived in between
-- the invite IS the first observation - so the fallback cannot see it.
------------------------------------------------------------

WoW.reset()
local invited = newPolicy({ preference = false })
invited.vis:Login()
WoW.groupMembers = 3
invited.ui:clear()
invited.vis:GroupJoined()
invited.vis:RosterChanged()
H.eq(invited.preference, true, "the client saying you joined is a join")
H.eq(invited.ui:last(), "open", "and the window comes back")

-- Spent, not sticky: the next roster change is ordinary churn.
invited.preference = false
WoW.groupMembers = 4
invited.ui:clear()
invited.vis:RosterChanged()
H.eq(invited.preference, false, "a later roster change is not a second join")

------------------------------------------------------------
-- Leaving, and staying solo
------------------------------------------------------------

WoW.reset()
WoW.groupMembers = 3
local leaving = newPolicy({ preference = true })
leaving.vis:Login()
leaving.vis:RosterChanged()
WoW.groupMembers = 0
leaving.ui:clear()
leaving.vis:RosterChanged()
H.eq(leaving.ui:last(), "close", "leaving the group closes the window")
H.eq(leaving.preference, true, "without calling that the player's choice")

WoW.reset()
local stillSolo = newPolicy({ preference = true, solo = true })
stillSolo.vis:Login()
stillSolo.ui:clear()
stillSolo.vis:RosterChanged()
H.eq(stillSolo.ui:last(), "refresh", "in solo mode it stays and just refreshes")

------------------------------------------------------------
-- A ready check
------------------------------------------------------------

WoW.reset()
WoW.groupMembers = 3
local ready = newPolicy()
ready.vis:ReadyCheck()
H.eq(ready.ui:last(), "open", "a ready check is a good moment to rebuff")

local readyClosed = newPolicy({ preference = false })
readyClosed.vis:ReadyCheck()
H.eq(readyClosed.ui:last(), nil, "but not a reason to override a close")

------------------------------------------------------------
-- The solo toggle, which must survive combat
--
-- ui:Open and ui:Close both remember what was asked and carry it out when the
-- fight ends, so refusing here loses the request instead of deferring it.
------------------------------------------------------------

WoW.reset()
local solo = newPolicy({ preference = false })
WoW.inCombat = true
solo.vis:SoloToggled(true)
H.eq(solo.preference, true, "ticking solo mode in combat is recorded")
H.eq(solo.ui:last(), "open", "and the window is asked for")
WoW.inCombat = false

WoW.reset()
local unsolo = newPolicy({ preference = true, solo = true })
unsolo.vis:SoloToggled(false)
H.eq(unsolo.ui:last(), "close", "unticking it alone closes the window")

WoW.reset()
WoW.groupMembers = 3
local unsoloGrouped = newPolicy({ preference = true })
unsoloGrouped.vis:SoloToggled(false)
H.eq(unsoloGrouped.ui:last(), nil, "but not while there is still a group to buff")

------------------------------------------------------------
-- Something gave the window rows, or took them away
--
-- One method for every source - a setting, a spell learned, a tank appearing,
-- an aura landing - because the decision is the same, and splitting it is what
-- left a copy of it in each host's handlers.
------------------------------------------------------------

WoW.reset()
WoW.groupMembers = 3
local content = newPolicy({ preference = false })
content.vis:ContentChanged()
H.eq(content.ui:last(), nil, "a settings change does not reopen a closed window")

-- A window that closed ITSELF for want of rows never wrote false, so this is
-- what tells the two apart.
local autoClosed = newPolicy({ preference = true })
autoClosed.vis:ContentChanged()
H.eq(autoClosed.ui:last(), "open", "but one that closed itself may come back")

local openAlready = newPolicy({ preference = true })
openAlready.ui.visible = true
openAlready.vis:ContentChanged()
H.eq(openAlready.ui:last(), "open", "an open window is rebuilt")

WoW.inCombat = true
local openInFight = newPolicy({ preference = true })
openInFight.ui.visible = true
openInFight.vis:ContentChanged()
H.eq(openInFight.ui:last(), nil, "and left alone in combat, which the library rebuilds at the end")
WoW.inCombat = false

------------------------------------------------------------
-- An upgrade keeps what a running session has already seen
--
-- The state that matters is not a fresh object's: it is one that has already
-- watched a roster or latched a join. A newer copy must inherit both, because
-- losing "we have seen them alone" turns the next invite into a first sighting
-- and loses the reopen.
------------------------------------------------------------

WoW.reset()
local live = newPolicy({ preference = false })
live.vis:Login()
WoW.groupMembers = 0
live.vis:RosterChanged()            -- now we HAVE seen them alone
live.vis:GroupJoined()              -- and a join is outstanding

H.eq(live.vis.lastGroupSize, 0, "the object remembers what it saw")
H.check(live.vis.joinedPending, "and that a join is pending")

-- What an upgrade does: new methods into the shared table, the object kept.
local before = lib.VisibilityMethods
H.check(getmetatable(live.vis).__index == before, "the object runs the shared methods")
lib.VisibilityMethods.Probe = function(self) return self.lastGroupSize end
H.eq(live.vis:Probe(), 0, "so a newer copy's methods reach an older copy's object")
lib.VisibilityMethods.Probe = nil

WoW.groupMembers = 4
live.ui:clear()
live.vis:RosterChanged()
H.eq(live.preference, true, "and the join it was holding is still honoured")

H.done("test_visibility")
