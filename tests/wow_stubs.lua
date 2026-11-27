------------------------------------------------------------
-- wow_stubs.lua - the client surface LibGroupBuffs and its hosts test against,
-- on WowTestKit.
--
-- The mechanics (strict globals, widgets that record every method called and
-- exist only as the pinned build has them, protected frames in combat,
-- timers, print, hooksecurefunc, secrets, the assertions) are the kit's:
-- tests/kit.lua loads it at the commit and build tests/kit.pin names. This
-- file adds what is LibGroupBuffs' own: the unit, aura, spell and item APIs,
-- the tooltip and chat frame, and the driver the tests and the hosts call
-- (WoW.SetUnit, WoW.SetAura, WoW.dispatch, WoW.flushTimers, WoW.messages,
-- WoW.blockedCalls, WoW.combatWrites, WoW.combatTouches...).
--
--     dofile("tests/wow_stubs.lua")     -- FIRST, in every test file
--     WoW.reset()
--     WoW.SetUnit("party1", { name = "Karuzo Elegia", class = "MAGE" })
--     WoW.SetAura("party1", "Power Word: Fortitude", 3600, 1200)
--
-- CONSUMING ADDONS SHARE THIS FILE, the way they share tests/config_scan.lua:
-- every client absence and refusal measured here is measured once. A host
-- loads it from its library checkout and layers its own differences on top:
--
--     loadfile(LIBRARY .. "/tests/wow_stubs.lua")()
--     WoW.SetPlayerDefaults({ name = "Wildly Testcase", class = "DRUID" })
--     WoW.allowGlobal("Wildly", "WildlyDB")   -- the host's own globals
--     function EJ_GetNumTiers() ... end       -- APIs only the host calls
--
-- Both calls work after the file has run: the defaults are read on every
-- WoW.reset(), and the allow-list is consulted when a global is read, not
-- when strict globals are installed. Defining a global after it is fine too
-- (strict globals only refuse READS of undefined names). A host whose layer
-- builds widgets calls WoW.strictGlobals() again at its end, so the methods
-- check sees only what the tests make the addon call.
--
-- WHICH KIT. This file runs `dofile("tests/kit.lua")` relative to the
-- current directory, which is the root of the repo running the tests: here,
-- this repo's pin; in a host, the HOST's own tests/kit.lua and kit.pin. So a
-- host chooses its kit commit and build, never this library.
--
-- A repo with no tests/kit.pin is refused with the reason. Every host is on
-- the kit (Priestly, Wildly, Magely, Buffy and ForeverCombatAssistant), so the
-- frozen pre-kit fallback is gone; a new host adopts the kit first
-- (WowTestKit's docs/ADOPTING.md).
------------------------------------------------------------

local pinFile = io.open("tests/kit.pin", "rb")
if not pinFile then
    error("LibGroupBuffs tests/wow_stubs.lua runs on WowTestKit: this repo has no "
        .. "tests/kit.pin (run from the repo's root, after adopting the kit: "
        .. "WowTestKit docs/ADOPTING.md)", 0)
end
pinFile:close()

dofile("tests/kit.lua")
local Methods = WoW.Methods

------------------------------------------------------------
-- The driver's names over the kit's
--
-- The tests and all three hosts say WoW.time and WoW.inCombat; the kit's
-- clock and combat flag are WoW.now and WoW.combat (GetTime, timers,
-- InCombatLockdown and the protected-frame refusals read those). One state,
-- two names: neither alias is ever stored on WoW itself, so a write to
-- either lands in the kit's field.
------------------------------------------------------------

local ALIAS = { time = "now", inCombat = "combat" }
setmetatable(WoW, {
    __index = function(t, k)
        local a = ALIAS[k]
        if a then return rawget(t, a) end
    end,
    __newindex = function(t, k, v)
        rawset(t, ALIAS[k] or k, v)
    end,
})

-- Event registrations are a load-time fact, not per-test state: the addon
-- registers once when its files load, so WoW.reset() must not wipe them or
-- WoW.dispatch would find nothing to fire at.
WoW.events = {}              -- [frame] = { [event] = true }

------------------------------------------------------------
-- State
------------------------------------------------------------

table.insert(WoW.onReset, function()
    WoW.time        = 10000
    WoW.inCombat    = false
    WoW.secret      = false      -- C_Secrets.ShouldAurasBeSecret()
    -- The CLIENT's build, not any host's measuredOnBuild. Hosts re-probe at
    -- different times - one can be sitting on an older measured build on
    -- purpose - and a stub that follows a host
    -- would then model a client nobody is running. .build.info in the World
    -- of Warcraft root names the installed build without launching the game.
    -- (tests/kit.pin's build is which API lists the kit checks against: the
    -- kit has none for 70338.)
    WoW.build       = "70338"    -- 1.60.1.70338, built Oct  9 2026
    WoW.locale      = "enUS"
    WoW.units       = {}         -- [unit] = { name, guid, class, connected, dead, level }
    WoW.auras       = {}         -- [unit] = { auraData, ... }
    WoW.knownSpells = {}         -- [spellID] = true
    WoW.spells      = {}         -- [spellID] = { name, iconID }
    WoW.spellbook   = {}         -- { { name, subText }, ... }
    WoW.range       = {}         -- [unit] = true | false | nil
    WoW.inRaid      = false
    WoW.groupMembers = 0
    WoW.raidRoster  = {}         -- { { name, rank, subgroup }, ... }
    WoW.instanceName = ""
    WoW.instanceType = nil       -- nil = derive from instanceName
    WoW.itemCounts  = {}         -- [itemID] = count, treated as sitting in bag 0
    WoW.itemsUncached = {}       -- [itemID] = true -> GetItemInfo returns nothing
    -- [itemID] = true -> IsItemDataCachedByID says YES and GetItemInfo still
    -- returns nothing. Measured on this client: the flag runs ahead of the
    -- data, which is why nothing here may trust it.
    WoW.itemsCachedButEmpty = {}
    WoW.itemQuality = {}         -- [itemID] = quality; 1 (common) when unset
    WoW.itemsRequested = {}      -- [itemID] = true once a load was requested
    WoW.bags        = {}         -- [bagID] = { {itemID=, stackCount=}, ... }
    WoW.bagFree     = { [0] = 16 }
    WoW.merchantItems = {}
    WoW.money       = 0
    WoW.purchases   = {}
    WoW.messages    = {}         -- everything printed to DEFAULT_CHAT_FRAME
    WoW.badEvents   = {}         -- event names RegisterEvent should throw on
    WoW.refusedEvents = {}       -- event names RegisterEvent should return false for
    WoW.mouseOver   = {}         -- [frame] = true; drives frame:IsMouseOver()
    WoW.auraReads   = { byIndex = 0, byName = 0 }
    WoW.centers     = {}         -- [frame] = x; drives frame:GetCenter()
    WoW.screenWidth = 1920       -- what UIParent:GetWidth() reports
    WoW.instanceMapID = 0        -- GetInstanceInfo's 8th return; 0 outdoors
    WoW.combatWrites = {}        -- SetAttribute calls refused while WoW.inCombat
    WoW.blockedCalls = {}        -- protected calls refused while WoW.inCombat
    WoW.combatTouches = {}       -- EVERY state write to a protected frame in combat
    WoW.byNameBlind = false      -- simulate GetAuraDataBySpellName not resolving
    WoW.auraReadsThrow = false   -- combat secrecy: index reads throw
    WoW.aurasAreSecret = false   -- combat secrecy: the struct's fields throw

    WoW.SetUnit("player", WoW.playerDefaults)
end)

-- WoW.reset() here resets the client's STATE only. These suites load the
-- library or the host ONCE, at the top of the file, and reset between
-- sections: the frames built at load must survive, or WoW.dispatch finds
-- nothing to fire at and a window walked after a reset has lost its
-- children. So the frames, widgets and recorded method calls are kept: the
-- kit's WoW.reset({ keepFrames = true }) (WowTestKit #80).
local kitReset = WoW.reset
-- The kit has the hook list from 38c8a6c on, the commit that also brought
-- keepFrames (#80), the hook on every call (#81) and the masks list (#82).
local KIT_HOOKS = type(WoW.onMethodCall) == "table"
if KIT_HOOKS then
    function WoW.reset() return kitReset({ keepFrames = true }) end
else
    -- WowTestKit #80, for a host still pinned before 38c8a6c: its reset
    -- discards every frame, so it runs with none to discard. Drop this once
    -- every host has bumped.
    function WoW.reset()
        local frames, widgets, called = WoW.frames, WoW.widgets, WoW.methodsCalled
        WoW.frames = {}
        kitReset()
        WoW.frames, WoW.widgets, WoW.methodsCalled = frames, widgets, called
    end
end

-- Who "player" is, and what any unit is when a test does not say. A host sets
-- these once after loading the file; every WoW.reset() then uses them.
WoW.playerDefaults = { name = "Priestly Testcase", class = "PRIEST", level = 20 }

function WoW.SetPlayerDefaults(info)
    for k, v in pairs(info or {}) do WoW.playerDefaults[k] = v end
    -- Applied now as well as on the next reset, so a host that sets them at
    -- the top of its stub layer does not need a reset to see them.
    if WoW.units and WoW.units.player then WoW.SetUnit("player", WoW.playerDefaults) end
    return WoW.playerDefaults
end

function WoW.SetUnit(unit, info)
    info = info or {}
    WoW.units[unit] = {
        name      = info.name or unit,
        guid      = info.guid or ("GUID-" .. (info.name or unit)),
        class     = info.class or WoW.playerDefaults.class,
        connected = info.connected ~= false,
        dead      = info.dead or false,
        level     = info.level or WoW.playerDefaults.level,
        -- Declared in the 69913 dump, never measured on this client. Tests
        -- that care set it; nothing should assume the live value.
        role      = info.role or "NONE",
        realm     = info.realm,     -- set it to get 69913's joined-name shape
    }
    return WoW.units[unit]
end

function WoW.RemoveUnit(unit)
    WoW.units[unit] = nil
    WoW.auras[unit] = nil
end

-- duration/remaining in seconds; remaining nil means "permanent" (exp 0).
function WoW.SetAura(unit, name, duration, remaining, spellID)
    local list = WoW.auras[unit]
    if not list then list = {} WoW.auras[unit] = list end
    list[#list + 1] = {
        name           = name,
        duration       = duration or 0,
        expirationTime = remaining and (WoW.time + remaining) or 0,
        spellId        = spellID,
        isHelpful      = true,
    }
end

-- An aura struct whose fields throw, the way a secret one does. The UNIT_AURA
-- payload carries these, so anything reading .name off it must be guarded.
function WoW.SecretAura()
    return setmetatable({}, {
        __index = function()
            error("Auras cannot be accessed when secret while tainted by 'Test'", 2)
        end,
    })
end

-- A UNIT_AURA payload whose fields are secret values. Measured on the live
-- client, `isFullUpdate` comes back as a <secret boolean> and
-- `updatedAuraInstanceIDs` as a <secret table>, and on this client a secret
-- value throws when it is TRUTH-TESTED, not only when it is read. Lua has no
-- way to make a boolean throw on `if x then`, so the closest model is a field
-- access that raises - which exercises the same guard.
function WoW.SecretUpdateInfo()
    return setmetatable({}, {
        __index = function(_, k)
            error("attempt to perform boolean test on field '" .. tostring(k)
                .. "' (a secret boolean value, while execution tainted by 'Test')", 2)
        end,
    })
end

function WoW.ClearAuras(unit)
    WoW.auras[unit] = nil
end

function WoW.Know(spellID, name, subText)
    WoW.knownSpells[spellID] = true
    if name then
        WoW.spells[spellID] = { name = name, iconID = 100000 + spellID }
        WoW.spellbook[#WoW.spellbook + 1] = { name = name, subText = subText }
    end
end

-- Make a spell exist in the client's spell database without the player knowing
-- it (GetSpellInfo resolves, IsSpellKnown does not).
function WoW.DefineSpell(spellID, name)
    WoW.spells[spellID] = { name = name, iconID = 100000 + spellID }
end

-- Run pending C_Timer callbacks (the kit's C_Timer and its WoW.timers).
--
-- With `advance`, move the clock forward by that many seconds and run only
-- what comes due, oldest first - which is how a test says "this much time
-- passed", catches a callback that fires too early, and lets a timer from an
-- earlier action still be pending while a later one is measured. Each
-- callback sees the time it fell due (WoW.time), and a timer it schedules
-- waits for the next flush. Without it, everything pending runs, as the
-- kit's WoW.flushTimers() does. The kit's WoW.advance(dt) is not the same:
-- its callbacks all see the end of the step, and that is a different test.
local kitFlush = WoW.flushTimers
function WoW.flushTimers(advance)
    if advance == nil then return kitFlush() end
    local target = WoW.time + advance
    local pending = WoW.timers
    WoW.timers = {}
    table.sort(pending, function(a, b) return a.at < b.at end)
    for _, t in ipairs(pending) do
        if t.cancelled then -- dropped, as the kit does
        elseif t.at <= target then
            WoW.time = t.at          -- callbacks see the time they ran at
            t.fn(t.handle)
        else
            WoW.timers[#WoW.timers + 1] = t
        end
    end
    WoW.time = target
end

------------------------------------------------------------
-- Frames: protection in combat
--
-- The kit models it: a frame built from a secure template is protected, and
-- so is every frame that parents one; in combat the client REFUSES hide,
-- move, re-anchor, unclamp, stop-drag and resize on those (silently, as far
-- as the addon can tell), and the kit records each refusal in WoW.blocked.
-- Measured on build 69913 (Priestly FOREVER-PROBE section 13; the kit's
-- WoW.PROTECTED cites the porting guide). This file keeps three records the
-- tests and the hosts assert on:
--   WoW.blockedCalls  - each refused call, { frame, method };
--   WoW.combatWrites  - each refused SetAttribute, { frame, key, value };
--   WoW.combatTouches - EVERY state write to a protected frame in combat,
--                       refused or not, { frame, method }.
-- The last is wider than the client's rule on purpose. The window's contract
-- is stronger - it touches NOTHING in combat (AGENTS.md, UI) - so a test
-- asserts it is empty without having to know which methods this build
-- refuses, and a regression through a method the client refuses but nobody
-- measured still goes red. Script handlers are not frame state.
------------------------------------------------------------

local function TOUCHES_FRAME_STATE(name)
    if name == "SetScript" or name == "HookScript" then return false end
    if name == "Show" or name == "Hide" or name == "EnableMouse"
        or name == "Raise" or name == "Lower" then
        return true
    end
    return name:match("^Set") ~= nil or name:match("^Start") ~= nil
        or name:match("^Stop") ~= nil or name:match("^Clear") ~= nil
end

-- SetAttribute is refused below, with its key and value recorded.
WoW.PROTECTED.SetAttribute = nil
-- On a window that parents secure buttons (the owner's /fp sweep in combat,
-- build 70959), SetScale, SetFrameStrata, SetFrameLevel and EnableMouse are
-- REFUSED (ADDON_ACTION_BLOCKED for each; #82, porting guide section 3), as
-- are SetShown and the rest of the kit's list. SetAlpha is ALLOWED: it took
-- effect with no ADDON_ACTION_BLOCKED, so it is not refused here (the pre-kit
-- stub refused it, wrongly). SetParent is still unmeasured: refused here as
-- a strict guess, and the window touches none of them in combat anyway
-- (combatTouches).
WoW.PROTECTED.SetParent = true
-- WowTestKit #83: the kit lists the other four from db287d2 on. A host still
-- pinned before it gets them here; drop this once every host has bumped.
if not WoW.PROTECTED.SetFrameStrata then
    WoW.PROTECTED.SetScale, WoW.PROTECTED.SetFrameStrata = true, true
    WoW.PROTECTED.SetFrameLevel, WoW.PROTECTED.EnableMouse = true, true
end

-- combatTouches and blockedCalls are filled by the kit's hook on every widget
-- call (WowTestKit #81), which runs before its combat refusal: a frame-state
-- write, or a call the kit's list refuses, to a protected frame in combat is
-- a touch, and the refused ones are blocked calls too. WoW.PROTECTED and
-- WoW.refused stay the kit's.
if KIT_HOOKS then
    table.insert(WoW.onMethodCall, function(w, what)
        if not (WoW.combat and WoW.isProtected(w)) then return end
        local refusedHere = WoW.PROTECTED[what]
        if not (refusedHere or TOUCHES_FRAME_STATE(what)) then return end
        WoW.combatTouches[#WoW.combatTouches + 1] = { frame = w, method = what }
        if refusedHere then
            WoW.blockedCalls[#WoW.blockedCalls + 1] = { frame = w, method = what }
        end
    end)
else
    -- WowTestKit #81, for a host still pinned before 38c8a6c: no hook, so the
    -- kit's dispatch is used instead. It asks WoW.PROTECTED[method] and then
    -- WoW.refused(frame, method) before every call, so a frame-state method
    -- reads as "ask" here and the wrapper records the touch, then refuses
    -- only what the kit's own list refuses. Drop this once every host has
    -- bumped.
    local REFUSED = WoW.PROTECTED
    setmetatable(REFUSED, {
        __index = function(_, k)
            if type(k) == "string" and TOUCHES_FRAME_STATE(k) then return "touch" end
        end,
    })
    local kitRefused = WoW.refused
    function WoW.refused(w, what)
        if WoW.combat and WoW.isProtected(w) then
            WoW.combatTouches[#WoW.combatTouches + 1] = { frame = w, method = what }
        end
        if rawget(REFUSED, what) and kitRefused(w, what) then
            WoW.blockedCalls[#WoW.blockedCalls + 1] = { frame = w, method = what }
            return true
        end
        return false
    end
end

-- A write to a secure attribute under combat lockdown is refused by the
-- client on a protected frame - silently, as far as the addon can tell
-- (PORTING-TBC-TO-FOREVER "Secure click-casting": SetAttribute does nothing
-- under lockdown). On a frame that is not protected it lands as usual. The
-- write is not stored: until the r33 audit it was, so a test reading the
-- attribute back saw a cast the client would never have made.
local kitSetAttribute = Methods.SetAttribute
function Methods.SetAttribute(w, k, v)
    if WoW.combat and WoW.isProtected(w) then
        WoW.combatWrites[#WoW.combatWrites + 1] = { frame = w, key = k, value = v }
        table.insert(WoW.blocked, (w._name or w._type) .. ":SetAttribute")
        return
    end
    return kitSetAttribute(w, k, v)
end

------------------------------------------------------------
-- Frames: events
------------------------------------------------------------

-- The client declares `RegisterEvent(eventName:cstring) -> registered:bool`
-- and throws on a name it does not know (the kit checks the name against the
-- pinned build). WoW.badEvents models a throw for a name a test picks,
-- WoW.refusedEvents a refusal by return value. Each registration is also
-- kept in WoW.events, which WoW.dispatch reads.
local kitRegisterEvent = Methods.RegisterEvent
function Methods.RegisterEvent(w, ev)
    if type(ev) ~= "string" then error("bad argument #1 to 'RegisterEvent'", 3) end
    if WoW.badEvents[ev] then error("unknown event " .. tostring(ev), 3) end
    if WoW.refusedEvents[ev] then return false end
    if not WoW.KNOWN_EVENTS[ev] then
        error("Attempt to register unknown event \"" .. tostring(ev) .. "\"", 3)
    end
    kitRegisterEvent(w, ev)
    local set = WoW.events[w]
    if not set then set = {} WoW.events[w] = set end
    set[ev] = true
    return true
end
local kitUnregisterEvent = Methods.UnregisterEvent
function Methods.UnregisterEvent(w, ev)
    kitUnregisterEvent(w, ev)
    local set = WoW.events[w]
    if set then set[ev] = nil end
end
local kitUnregisterAll = Methods.UnregisterAllEvents
function Methods.UnregisterAllEvents(w)
    kitUnregisterAll(w)
    WoW.events[w] = nil
end

-- Fire an event the way the game does: to EVERY frame registered for it
-- (WoW.events, kept across WoW.reset). Errors are not caught. Returns how
-- many frames it reached. The kit's WoW.fire(event, ...) is the same over
-- the frames made since the last kit reset; this one is what the suites and
-- the hosts call.
function WoW.dispatch(event, ...)
    local targets = {}
    for frame, events in pairs(WoW.events) do
        if events[event] then targets[#targets + 1] = frame end
    end
    for _, frame in ipairs(targets) do
        local fn = frame._scripts and frame._scripts.OnEvent
        if fn then fn(frame, event, ...) end
    end
    return #targets
end

------------------------------------------------------------
-- Frames: what the tests read back
--
-- Each of these calls the kit's model where it has one and also records the
-- field the tests and the hosts read (the pre-kit stub's names: _colorTexture,
-- _texture, _moving, _clicks, _mouseEnabled, _slice...), or models a return
-- the kit leaves out.
------------------------------------------------------------

local function wrap(name, after)
    local kit = Methods[name]
    Methods[name] = function(w, ...)
        local r1, r2 = nil, nil
        if kit then r1, r2 = kit(w, ...) end
        after(w, ...)
        return r1, r2
    end
end

wrap("SetColorTexture", function(t, r, g, b, a) t._colorTexture = { r, g, b, a } end)
wrap("SetTexture", function(t, tex) t._texture = tex end)
function Methods.GetTexture(t) return t._texture end
wrap("StartMoving", function(w) w._moving = true end)
wrap("StopMovingOrSizing", function(w) w._moving = false end)
wrap("RegisterForClicks", function(w, ...) w._clicks = { ... } end)
-- Whether a frame takes the mouse decides whether a tooltip or a click can
-- ever reach it. The kit keeps it in _mouse; _mouseEnabled is the hosts' name.
wrap("EnableMouse", function(w, on) w._mouseEnabled = on and true or false end)
wrap("SetClampedToScreen", function(w, v) w._clamped = v end)
function Methods.IsClampedToScreen(w) return w._clamped == true end
-- The glass material's layers, recorded so a test can assert the layer
-- exists and what it was given.
wrap("SetTextureSliceMargins", function(t, l, top, r, b) t._slice = { l, top, r, b } end)
wrap("SetTextureSliceMode", function(t, mode) t._sliceMode = mode end)
wrap("SetHorizTile", function(t, on) t._horizTile = on and true or false end)
wrap("SetVertTile", function(t, on) t._vertTile = on and true or false end)
-- Recorded because it does not compose with AddMaskTexture: this client
-- applies a mask in the texture's UNTRANSFORMED space, so a masked texture
-- that is also cropped shows a fraction of its art in one corner.
wrap("SetTexCoord", function(t, ...) t._texCoord = { ... } end)
function Methods.GetTexCoord(t)
    local c = t._texCoord
    if not c then return nil end
    return unpack(c)
end
function Methods.GetVertexColor(t)
    local c = t._vertex or { 1, 1, 1, 1 }
    return c[1], c[2], c[3], c[4]
end
-- The draw layer decides what covers what: a fill created in the wrong place
-- drew its gloss over the class icons and washed them green, in game, with a
-- green suite. The kit keeps it as _layer / _sublevel.
local kitCreateTexture = Methods.CreateTexture
function Methods.CreateTexture(w, name, layer, template, sublevel)
    local t = kitCreateTexture(w, name, layer, template, sublevel)
    t._drawLayer, t._subLayer = layer, sublevel
    return t
end
local kitCreateFontString = Methods.CreateFontString
function Methods.CreateFontString(w, name, layer, template)
    local fs = kitCreateFontString(w, name, layer, template)
    fs._drawLayer, fs._template = layer, template
    return fs
end
function Methods.GetDrawLayer(r) return r._drawLayer, r._subLayer end
-- A frame's masks are in w._maskTextures (WowTestKit #82), not its regions:
-- whether the client's GetRegions lists them is not measured. A test that
-- walks a window's masks walks that list (tests/test_ui_window.lua).
local kitCreateMaskTexture = Methods.CreateMaskTexture
function Methods.CreateMaskTexture(w, ...)
    local m = kitCreateMaskTexture(w, ...)
    m._isMask = true
    -- WowTestKit #82, for a host still pinned before 38c8a6c: that kit lists
    -- a mask nowhere, so it goes in the regions, as before the kit. Drop
    -- this once every host has bumped.
    local listed = w._maskTextures
    if not (listed and listed[#listed] == m) then WoW.addRegion(w, m) end
    return m
end
-- Whether a size was SET: the kit starts every widget at 0 x 0, so a test
-- deriving a region's box from its anchors (no size of its own) asks these.
wrap("SetSize", function(w) w._sizedW, w._sizedH = true, true end)
wrap("SetWidth", function(w) w._sizedW = true end)
wrap("SetHeight", function(w) w._sizedH = true end)
-- Text alignment and shadow, recorded: a label meant to be centred and one
-- left against an edge are otherwise indistinguishable.
function Methods.SetJustifyH(fs, justify) fs._justifyH = justify end
function Methods.GetJustifyH(fs) return fs._justifyH or "LEFT" end
function Methods.SetJustifyV(fs, justify) fs._justifyV = justify end
function Methods.GetJustifyV(fs) return fs._justifyV or "MIDDLE" end
function Methods.SetShadowColor(fs, r, g, b, a) fs._shadowColor = { r, g, b, a or 1 } end
function Methods.SetShadowOffset(fs, x, y) fs._shadowOffset = { x, y } end
function Methods.GetShadowOffset(fs)
    local o = fs._shadowOffset
    if not o then return 0, 0 end
    return o[1], o[2]
end
-- Set WoW.zeroHeights to model a FontString that has not been laid out yet,
-- which is what the live client reports inside a scroll child during OnShow.
function Methods.GetStringHeight() return WoW.zeroHeights and 0 or 12 end
function Methods.GetStatusBarColor(b)
    local c = b._color or { 1, 1, 1, 1 }
    return c[1], c[2], c[3], c[4] or 1
end
-- The range that was SET, not a constant: a fill drawn from it looked right
-- whatever the slider was for while every slider answered 0, 1.
function Methods.GetMinMaxValues(b)
    if b._min == nil then return 0, 1 end
    return b._min, b._max
end
-- Scale, and the product up the parent chain the way the client computes it.
-- Without it a frame's own coordinates and UIParent's look like the same
-- space, and every comparison between them is right only at scale 1.
function Methods.SetScale(w, s) w._scale = s end
function Methods.GetScale(w) return w._scale or 1 end
function Methods.GetEffectiveScale(w)
    if w._escale ~= nil then return w._escale end
    local scale, p = w._scale or 1, w._parent
    while p do
        scale = scale * (p._scale or 1)
        p = p._parent
    end
    return scale
end
-- The pointer: WoW.mouseOver[frame], or the kit's w._mouseOver.
local kitIsMouseOver = Methods.IsMouseOver
function Methods.IsMouseOver(w)
    if WoW.mouseOver[w] then return true end
    return kitIsMouseOver(w)
end
-- nil until a test places the frame (WoW.centers[frame] = x), which is what
-- the live client returns before layout - a case the caller has to handle.
-- The kit's edges (w._left...) answer when a test sets those instead.
local kitGetCenter = Methods.GetCenter
function Methods.GetCenter(w)
    local x = WoW.centers[w]
    if x then return x, 300 end
    return kitGetCenter(w)
end
-- UIParent is as wide as the screen; the popover's side depends on it.
local kitGetWidth = Methods.GetWidth
function Methods.GetWidth(w)
    if w == UIParent then return WoW.screenWidth end
    return kitGetWidth(w)
end
-- SetPoint(point, x, y) is the short form, and a number in the second slot
-- is the only thing that distinguishes it from SetPoint(point, relativeTo,
-- relativePoint): stored as the five-value anchor GetPoint returns.
-- A MASK anchored to a texture that has not been placed yet gets no
-- rectangle, and this client does not go back and give it one when the
-- texture is anchored afterwards: the masked texture then draws only where
-- that empty mask is, which looks like a sliver of the art in one corner.
-- Nothing throws, so the order is recorded here or no test can see it.
local kitSetPoint = Methods.SetPoint
function Methods.SetPoint(w, point, rel, relPoint, x, y)
    if type(rel) == "number" then
        rel, relPoint, x, y = nil, nil, rel, relPoint
    end
    if w._isMask and type(rel) == "table" and rel._type == "Texture"
        and not (rel._points and #rel._points > 0) then
        w._anchoredBeforePlaced = true
    end
    return kitSetPoint(w, point, rel, relPoint, x, y)
end
-- Recorded as the two corners it really is: a region anchored this way has
-- a size, and a test that cannot derive it silently skips the region instead
-- of checking it. (The kit records { "ALL", rel }.)
function Methods.SetAllPoints(w, rel)
    w._points = { { "TOPLEFT", rel, "TOPLEFT", 0, 0 },
                  { "BOTTOMRIGHT", rel, "BOTTOMRIGHT", 0, 0 } }
end

-- BackdropTemplate's methods: Lua in FrameXML, not the C widget API, so the
-- build's method lists can't see them. The window is built with the template.
Kit.allowMethods({
    ["Frame:SetBackdrop"] = "BackdropTemplateMixin (Blizzard_SharedXML/Backdrop.lua:336)",
    ["Frame:GetBackdrop"] = "BackdropTemplateMixin (Blizzard_SharedXML/Backdrop.lua:354)",
    ["Frame:SetBackdropColor"] = "BackdropTemplateMixin (Blizzard_SharedXML/Backdrop.lua:406)",
    ["Frame:SetBackdropBorderColor"] = "BackdropTemplateMixin (Blizzard_SharedXML/Backdrop.lua:429)",
})
-- Recorded, including the nil that CLEARS it: a backdrop left under the glass
-- shows through as a dark square-cornered rectangle.
function Methods.SetBackdrop(w, backdrop) w._backdrop = backdrop end
function Methods.GetBackdrop(w) return w._backdrop end

-- What each template brings with it. A template's text is a FontString with
-- the template's font, so SetText works on it as in game.
local function templateText(w, key, name)
    local fs = WoW.addRegion(w, WoW.newWidget("FontString", w, name))
    fs._fontTemplate = "GameFontHighlight"
    w[key] = fs
end
local TEMPLATE_REGIONS = {
    UICheckButtonTemplate               = { "text" },
    InterfaceOptionsCheckButtonTemplate = { "Text" },
    UIRadioButtonTemplate               = { "text" },
    OptionsSliderTemplate               = { "Low", "High", "Text" },
    UISliderTemplateWithLabels          = { "Low", "High", "Text" },
    MinimalSliderTemplate               = { "Low", "High" },
    UIPanelButtonTemplate               = { "Text" },
}
for template, keys in pairs(TEMPLATE_REGIONS) do
    WoW.templates[template] = function(w)
        for _, key in ipairs(keys) do templateText(w, key, w._name and (w._name .. key) or nil) end
    end
end
-- ScrollFrameTemplate's ScrollBar, the way the kit builds
-- UIPanelScrollFrameTemplate's.
WoW.templates.ScrollFrameTemplate = function(sf)
    sf.ScrollBar = CreateFrame("Slider", sf._name and (sf._name .. "ScrollBar") or nil, sf)
end

-- A plain frame (name, parent, template), for tests that need one.
function WoW.makeFrame(name, parent, template)
    return CreateFrame("Frame", name, parent, template)
end

------------------------------------------------------------
-- Globals the addon expects at load
------------------------------------------------------------

UNKNOWNOBJECT = "Unknown"
BOOKTYPE_SPELL = "spell"

RAID_CLASS_COLORS = setmetatable({}, {
    __index = function() return { r = 0.5, g = 0.5, b = 0.5 } end,
})

-- The chat frame. What it is told goes to WoW.messages, and each line is
-- checked for a stray "|" the way the kit's print is (done() fails on one).
DEFAULT_CHAT_FRAME = CreateFrame("ScrollingMessageFrame", nil, UIParent)
function Methods.AddMessage(_, msg)
    msg = tostring(msg)
    if WoW.StrayPipe(msg) then WoW.strays[#WoW.strays + 1] = msg end
    WoW.messages[#WoW.messages + 1] = msg
end

GameTooltip = CreateFrame("GameTooltip", "GameTooltip", UIParent)
GameTooltip:Hide()
-- Records what was put in it, so a test can assert what the player is told.
-- Declared on this client (GameTooltip:GetOwner, 70009 dump). Modelled
-- because GameTooltip is shared: an addon that redraws a tooltip it opened
-- earlier has to check it still owns it.
function Methods.GetOwner(tt) return tt._owner end
function Methods.SetOwner(tt, owner, anchor, xOff, yOff)
    tt._owner, tt._anchor, tt._lines = owner, anchor, {}
    -- The offsets too: ANCHOR_RIGHT measures from the OWNER, and an owner
    -- inset inside a panel puts the tooltip on top of that panel unless the
    -- caller pushes it clear.
    tt._anchorOffset = { xOff or 0, yOff or 0 }
end
-- The colour is kept, not discarded. It was the only thing carrying an item's
-- quality to the player, and with it thrown away the argument order could be
-- shuffled - or the colour dropped entirely - and every test stayed green.
local kitSetText = Methods.SetText
function Methods.SetText(w, text, r, g, b, ...)
    if w._type == "GameTooltip" then
        w._lines = { text }
        w._colours = { { r, g, b } }
        return
    end
    return kitSetText(w, text, r, g, b, ...)
end
function Methods.AddLine(tt, text, r, g, b)
    tt._lines = tt._lines or {}
    tt._lines[#tt._lines + 1] = text
    tt._colours = tt._colours or {}
    tt._colours[#tt._lines] = { r, g, b }
end
function Methods.AddDoubleLine(tt, left, right)
    return Methods.AddLine(tt, tostring(left) .. "  " .. tostring(right))
end
function WoW.clearTooltip()
    GameTooltip:Hide()
    GameTooltip._lines = nil
    GameTooltip._colours = nil
end

-- The colour of one tooltip line, 1-based, as { r, g, b }.
function WoW.tooltipColour(i)
    local c = GameTooltip._colours and GameTooltip._colours[i or 1]
    if not c then return nil end
    return c[1], c[2], c[3]
end

-- Everything the tooltip is showing, colour codes stripped.
function WoW.tooltipText()
    if not GameTooltip:IsShown() then return "" end
    local joined = table.concat(GameTooltip._lines or {}, " / ")
    return (joined:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
SlashCmdList = {}

-- Present on the live client, so the options panel's real registration and
-- OpenToCategory paths are the ones the tests exercise.
Settings = {
    RegisterCanvasLayoutCategory = function(frame, name)
        return { GetID = function() return 42 end, name = name }
    end,
    RegisterAddOnCategory = function() end,
    OpenToCategory = function(id) WoW.settingsOpenedTo = id end,
}

Enum = {
    SpellBookSpellBank = { Player = 0, Pet = 1 },
    -- The reagent bag sits past the ordinary 0..NUM_BAG_SLOTS range.
    BagIndex = { Backpack = 0, ReagentBag = 5 },
}

WOW_PROJECT_MAINLINE = 1
WOW_PROJECT_ID = 1
NUM_BAG_SLOTS = 4                -- measured on this client

function GetBuildInfo() return "1.60.1", WoW.build, "Oct  9 2026", 16001 end
-- NOT defined on purpose: MouseIsOver does not exist on this client. The stub
-- must model the client's absences, not just its presences - defining it here
-- is what let a call to it survive into a shipped build.

function CreateColor(r, g, b, a)
    return { r = r, g = g, b = b, a = a,
             GetRGBA = function(self) return self.r, self.g, self.b, self.a end }
end

function strtrim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
-- The real strsplit KEEPS empty fields: strsplit("-", "a--b") is "a", "", "b",
-- and a trailing separator yields a trailing "". A gmatch over "[^sep]+" drops
-- them, which turns a missing field into a shifted one - the kind of bug a
-- test using the stub would never see. `sep` is a set of characters, as in
-- game.
function strsplit(sep, s)
    s = tostring(s)
    local class = "[" .. (tostring(sep):gsub("(%W)", "%%%1")) .. "]"
    local out, start = {}, 1
    while true do
        local a, b = s:find(class, start)
        if not a then break end
        out[#out + 1] = s:sub(start, a - 1)
        start = b + 1
    end
    out[#out + 1] = s:sub(start)
    return unpack(out)
end
function date(fmt) return "2026-09-20 00:00:00" end

C_AddOns = {
    GetAddOnMetadata = function(_, key)
        if key == "Version" then return "2.0.0-test" end
        return nil
    end,
}

------------------------------------------------------------
-- Units
------------------------------------------------------------

local function unitInfo(unit) return unit and WoW.units[unit] or nil end

function UnitExists(unit) return unitInfo(unit) ~= nil end
function UnitIsConnected(unit)
    local u = unitInfo(unit)
    return u ~= nil and u.connected
end
function UnitIsDeadOrGhost(unit)
    local u = unitInfo(unit)
    return u ~= nil and u.dead
end
-- UnitName's SECOND return is the realm slot, and what lands in it is the
-- unsettled part. Measured on 70009: every unit, player included, comes back
-- split - `"Karuzo", "Elegia"` - so the surname sits where the realm goes.
-- Measured on 69913: the player alone came back joined, with a real realm
-- second. Whether the client changed or the two runs sat on different realms
-- is unresolved, so the stub does the 70009 reading by default and a test
-- that gives a unit a `realm` gets the other - which is also the only way to
-- model a real realm arriving there, for code doing `local name, realm = ...`.
-- GetUnitName joins under both, which is what hosts actually read.
function UnitName(unit)
    local u = unitInfo(unit)
    if not u then return nil end
    if u.realm then return u.name, u.realm end
    local first, surname = u.name:match("^(%S+)%s+(%S+)$")
    if first then return first, surname end
    return u.name
end
function GetUnitName(unit, showServer)
    local u = unitInfo(unit)
    return u and u.name or nil
end
UnitFullName = UnitName
UnitNameUnmodified = UnitName
function UnitGUID(unit)
    local u = unitInfo(unit)
    return u and u.guid or nil
end
function UnitClass(unit)
    local u = unitInfo(unit)
    if not u then return nil, nil end
    return u.class, u.class
end
function UnitLevel(unit)
    local u = unitInfo(unit)
    return u and u.level or 1
end
-- Two tokens can be the same player: "party1" and "raid3", or "player" and
-- whichever raid index you occupy. Identity is the GUID, not the token.
function UnitIsUnit(a, b)
    if a == b then return true end
    local x, y = unitInfo(a), unitInfo(b)
    return (x ~= nil and y ~= nil and x.guid == y.guid)
end
function UnitGroupRolesAssigned(unit)
    local u = unitInfo(unit)
    return u and u.role or "NONE"
end

function IsInRaid() return WoW.inRaid end
function GetNumGroupMembers() return WoW.groupMembers end
-- Undocumented on this client: the 69913 dump lists the name with no
-- signature, so only the first three returns are measured (Engine.lua reads
-- name and subgroup). The rest is Retail's shape, which is what the Mainline
-- codebase should give - a host that starts depending on one of them should
-- probe it first rather than trust this line.
function GetRaidRosterInfo(i)
    local e = WoW.raidRoster[i]
    if not e then return nil end
    local u = e.unit and WoW.units[e.unit]
    local class = e.class or (u and u.class) or WoW.playerDefaults.class
    return e.name, e.rank or 0, e.subgroup or 1,
        e.level or (u and u.level) or WoW.playerDefaults.level,
        class, class, e.zone or "", e.online ~= false,
        e.isDead or (u and u.dead) or false,
        -- The roster's role is NOT UnitGroupRolesAssigned's. This one is
        -- Retail's MAINTANK/MAINASSIST slot, empty for everyone who is
        -- neither, so it comes from the roster entry alone and defaults to
        -- nil - inventing "NONE" here would be inventing data about a tuple
        -- that has no measured signature on this client.
        e.role, e.isML or false, e.combatRole
end
function GetInstanceInfo()
    -- Outdoors the live client returns the continent name with instanceType
    -- "none" - it does not return an empty name.
    local t = WoW.instanceType
    if not t then t = (WoW.instanceName == "" and "none") or "party" end
    -- Eleven returns, measured on 70009 (nine on 69913): the last two are
    -- new. A stub that models the old arity is a stub that disagrees with the
    -- client, which is the one thing this file must not do.
    -- The EIGHTH return is the instance's own id - `instanceID` in the 70009
    -- declaration, and what `/pprobe here` prints as instanceMapID (2999 for
    -- Ruins of Lordaeron). It is the locale-proof way to know where you are,
    -- so a stub that answers 0 for every instance cannot tell a test that
    -- matches on it from one that does not.
    return WoW.instanceName, t, 0, "", 5, 0, false, WoW.instanceMapID or 0, 0, nil, false
end
function GetRealZoneText() return WoW.instanceName end

------------------------------------------------------------
-- C_UnitAuras
------------------------------------------------------------

-- Measured on build 69913: once combat taints an addon, EVERY aura read
-- throws ("Auras cannot be accessed when secret while tainted by '<addon>'")
-- for every unit - while GetAuraDataBySpellName merely returns nil, which
-- looks exactly like "not buffed".
local function liveAuras(unit)
    if WoW.auraReadsThrow then
        error("Auras cannot be accessed when secret while tainted by 'Test'", 2)
    end
    local list = WoW.auras[unit]
    if not list then return nil end
    local out = {}
    for _, aura in ipairs(list) do
        if aura.expirationTime == 0 or aura.expirationTime > WoW.time then
            out[#out + 1] = aura
        end
    end
    return out
end

-- How many times the client was asked for an aura, by route. The cost of the
-- aura path is not visible in any assertion about what the window SHOWS - it
-- shows the same thing either way - so it is counted here instead (#6).
C_UnitAuras = {
    GetAuraDataByIndex = function(unit, index, filter)
        WoW.auraReads.byIndex = WoW.auraReads.byIndex + 1
        local list = liveAuras(unit)
        local aura = list and list[index] or nil
        if aura and WoW.aurasAreSecret then return WoW.SecretAura() end
        return aura
    end,
    GetBuffDataByIndex = function(unit, index)
        WoW.auraReads.byIndex = WoW.auraReads.byIndex + 1
        local list = liveAuras(unit)
        local aura = list and list[index] or nil
        if aura and WoW.aurasAreSecret then return WoW.SecretAura() end
        return aura
    end,
    -- Set WoW.aurasAreSecret to hand back aura structs whose fields throw,
    -- rather than throwing from the getter itself - the other shape secrecy
    -- can take.
    GetAuraDataBySpellName = function(unit, name, filter)
        -- Set WoW.byNameBlind = true to simulate the by-name lookup failing to
        -- resolve a spell the player does not know, which is the reason
        -- API.ReadBuff never trusts a by-name miss.
        WoW.auraReads.byName = WoW.auraReads.byName + 1
        if WoW.byNameBlind then return nil end
        -- Under secrecy this one returns nil rather than throwing.
        if WoW.auraReadsThrow then return nil end
        local list = WoW.auras[unit]
        if not list then return nil end
        for _, aura in ipairs(list) do
            if aura.name == name
                and (aura.expirationTime == 0 or aura.expirationTime > WoW.time) then
                if WoW.aurasAreSecret then return WoW.SecretAura() end
                return aura
            end
        end
        return nil
    end,
}

C_Secrets = {
    ShouldAurasBeSecret = function() return WoW.secret end,
    GetSpellAuraSecrecy = function() return false end,
}

------------------------------------------------------------
-- C_Spell / C_SpellBook
------------------------------------------------------------

-- By name, the highest rank the player knows, as the client answers
-- (measured on 71037, #97: "Power Word: Fortitude" -> 1245 at level 36, the
-- rank a cast by that name sends). With no known rank, any one, which the
-- callers below then refuse.
local function findSpell(spell)
    if type(spell) == "number" then return WoW.spells[spell], spell end
    local best, bestID, any, anyID
    for id, info in pairs(WoW.spells) do
        if info.name == spell then
            if WoW.knownSpells[id] and (not bestID or id > bestID) then best, bestID = info, id end
            any, anyID = any or info, anyID or id
        end
    end
    if best then return best, bestID end
    return any, anyID
end

C_Spell = {
    -- Measured on build 69913: by ID this resolves any spell in the client's
    -- database; by NAME it resolves only spells the player knows. Resolving a
    -- name for an unlearned spell must therefore fail here too, or the tests
    -- would bless a lookup direction the live client rejects.
    GetSpellInfo = function(spell)
        local info, id = findSpell(spell)
        if not info then return nil end
        if type(spell) ~= "number" and not WoW.knownSpells[id] then return nil end
        return { name = info.name, iconID = info.iconID, castTime = 0, spellID = id }
    end,
    GetSpellTexture = function(spell)
        local info, id = findSpell(spell)
        if not info then return nil end
        if type(spell) ~= "number" and not WoW.knownSpells[id] then return nil end
        return info.iconID
    end,
    IsSpellInRange = function(spell, unit)
        -- The live API answers nil for a spell the player does not know, the
        -- same as for a missing unit.
        local info, id = findSpell(spell)
        if not info or not WoW.knownSpells[id] then return nil end
        -- WoW.range[unit] is a boolean, or a table keyed by spell name when a
        -- test needs the spells to differ - the Prayers reach 40 yards where
        -- the single-target forms reach 30.
        local r = WoW.range[unit]
        if type(r) == "table" then return r[info.name] end
        return r
    end,
    SpellHasRange = function() return true end,
}

C_SpellBook = {
    IsSpellKnown = function(spellID) return WoW.knownSpells[spellID] == true end,
    IsSpellInSpellBook = function(spellID) return WoW.knownSpells[spellID] == true end,
    IsSpellKnownOrInSpellBook = function(spellID) return WoW.knownSpells[spellID] == true end,
    GetNumSpellBookSkillLines = function() return 1 end,
    GetSpellBookSkillLineInfo = function() return { name = "General", itemIndexOffset = 0,
        numSpellBookItems = #WoW.spellbook } end,
    GetSpellBookItemName = function(index)
        local e = WoW.spellbook[index]
        if not e then return nil end
        return e.name, e.subText
    end,
}

------------------------------------------------------------
-- Items / containers
------------------------------------------------------------

-- Bag 0 holds whatever WoW.itemCounts names; WoW.bags places items in a
-- specific bag. Forever's carried inventory includes the reagent bag at
-- Enum.BagIndex.ReagentBag, which is outside the 0..NUM_BAG_SLOTS range.
local function bagContents(bag)
    if bag == 0 then
        local out = {}
        for itemID, count in pairs(WoW.itemCounts) do
            out[#out + 1] = { itemID = itemID, stackCount = count }
        end
        for _, entry in ipairs(WoW.bags[0] or {}) do out[#out + 1] = entry end
        return out
    end
    return WoW.bags[bag] or {}
end

local function carriedBags()
    local ids = { 0, 1, 2, 3, 4, 5 }
    return ids
end

C_Item = {
    GetItemIconByID = function(itemID) return "icon:" .. tostring(itemID) end,
    GetItemMaxStackSizeByID = function() return 20 end,
    -- Returns NOTHING on a cache miss, not nil - the live behaviour, and the
    -- reason API.ItemInfo checks the cache before trusting a result.
    GetItemInfo = function(itemID)
        if WoW.itemsUncached[itemID] or WoW.itemsCachedButEmpty[itemID] then return end
        -- Ordinary white by default, not Rare. The reagents all three addons
        -- actually read - 17028, 17029, 17056 - were measured as common in
        -- Priestly's docs/FOREVER-PROBE.md section 6, so a stub that called
        -- every item Rare started all of them from a wrong model of the only
        -- items they look at. Set WoW.itemQuality[id] for a test that wants
        -- the colour path.
        local quality = WoW.itemQuality[itemID] or 1
        return "Item " .. tostring(itemID), "link", quality, 1, 1, "", "", 20, "",
            "icon:" .. tostring(itemID)
    end,
    IsItemDataCachedByID = function(itemID) return not WoW.itemsUncached[itemID] end,
    RequestLoadItemDataByID = function(itemID) WoW.itemsRequested[itemID] = true end,
    GetItemQualityColor = function(quality)
        return 0.1 * quality, 0.2, 0.3, "quality" .. tostring(quality)
    end,
    -- The live API answers for the whole carried inventory, reagent bag
    -- included.
    GetItemCount = function(itemID)
        local total = 0
        for _, bag in ipairs(carriedBags()) do
            for _, entry in ipairs(bagContents(bag)) do
                if entry.itemID == itemID then total = total + (entry.stackCount or 0) end
            end
        end
        return total
    end,
}

C_Container = {
    GetContainerNumFreeSlots = function(bag) return WoW.bagFree[bag] or 0, 0 end,
    GetContainerNumSlots = function(bag)
        return #bagContents(bag) > 0 and 16 or 0
    end,
    GetContainerItemInfo = function(bag, slot)
        return bagContents(bag)[slot]
    end,
}

C_MerchantFrame = {
    GetItemInfo = function(index) return WoW.merchantItems[index] end,
}
function GetMerchantNumItems() return #WoW.merchantItems end
function GetMerchantItemID(index) return WoW.merchantItems[index] and WoW.merchantItems[index].itemID end
function GetMoney() return WoW.money end
function BuyMerchantItem(index, quantity)
    WoW.purchases[#WoW.purchases + 1] = { index = index, quantity = quantity }
end

------------------------------------------------------------
-- Addon messages, groups and menus (r37's assignments)
--
-- Signatures from the 71037 dump (forever-api-1.60.1.71037.md:745-764 and
-- 5215): SendAddonMessage(prefix, message, chatType?, target?) ->
-- SendAddonMessageResult (0 Success, 3 AddonMessageThrottle, 5 NotInGroup,
-- 8 ChannelThrottle, 11 AddOnMessageLockdown), RegisterAddonMessagePrefix ->
-- RegisterAddonMessagePrefixResult (0 Success, 1 DuplicatePrefix),
-- InChatMessagingLockdown -> bool, GetServerTime -> number. IsInGroup is
-- listed with no signature; Retail's optional category is what Blizzard's own
-- shipped code passes (Blizzard_CooldownBroadcaster.lua:148), which is also
-- where LE_PARTY_CATEGORY_HOME and _INSTANCE are read unguarded. MenuUtil is
-- Blizzard Lua (Blizzard_Menu/MenuUtil.lua): only CreateContextMenu and the
-- element calls the panel makes are modelled, and a test reads what was built
-- from WoW.menus.
------------------------------------------------------------

LE_PARTY_CATEGORY_HOME, LE_PARTY_CATEGORY_INSTANCE = 1, 2

C_ChatInfo = C_ChatInfo or {}
function C_ChatInfo.RegisterAddonMessagePrefix(prefix)
    if WoW.prefixes[prefix] then return 1 end
    WoW.prefixes[prefix] = true
    return 0
end
function C_ChatInfo.SendAddonMessage(prefix, message, chatType, target)
    WoW.addonSent[#WoW.addonSent + 1] = { prefix = prefix, message = message, chatType = chatType, target = target }
    return WoW.sendResult
end
function C_ChatInfo.InChatMessagingLockdown() return WoW.chatLockdown == true end
function GetServerTime() return WoW.serverTime or (1800000000 + math.floor(WoW.time or 0)) end
function IsInGroup(category)
    if category == LE_PARTY_CATEGORY_INSTANCE then return WoW.instanceGroup == true end
    return WoW.inRaid == true or (WoW.groupMembers or 0) > 0
end

local function MenuDescription()
    local d = { elements = {} }
    local function add(kind, text, a, b, data)
        local e = { kind = kind, text = text, a = a, b = b, data = data }
        d.elements[#d.elements + 1] = e
        return e
    end
    function d:CreateTitle(text) return add("title", text) end
    function d:CreateButton(text, callback, data) return add("button", text, callback, nil, data) end
    function d:CreateRadio(text, isSelected, setSelected, data) return add("radio", text, isSelected, setSelected, data) end
    function d:CreateCheckbox(text, isSelected, setSelected, data) return add("checkbox", text, isSelected, setSelected, data) end
    function d:CreateDivider() return add("divider") end
    function d:SetScrollMode(extent) d.scrollExtent = extent end
    return d
end

MenuUtil = {}
function MenuUtil.CreateContextMenu(ownerRegion, generator)
    local root = MenuDescription()
    root.owner = ownerRegion
    generator(ownerRegion, root)
    WoW.menus[#WoW.menus + 1] = root
    return root
end

local resetBeforeChat = WoW.reset
function WoW.reset(...)
    local r = resetBeforeChat(...)
    WoW.prefixes, WoW.addonSent, WoW.menus = {}, {}, {}
    WoW.sendResult, WoW.chatLockdown, WoW.instanceGroup, WoW.serverTime = 0, false, false, nil
    return r
end

------------------------------------------------------------
-- Strict globals
--
-- Everything above is stubbed because it was *verified present* on the live
-- client (see docs/FOREVER-PROBE.md). So any global the addon reads that is
-- not stubbed is either a genuine typo or - the interesting case - an API that
-- quietly went away in the move to the Retail codebase. `MouseIsOver` was
-- exactly that: still called, nil on this client, and it only surfaced as a
-- Lua error on mouseover in game.
--
-- Reading an unstubbed global fails the test run (the kit's Kit.strict). To
-- add one: confirm it exists with Tools/PriestlyProbe and stub it, or list it
-- here as deliberately absent.
------------------------------------------------------------

local KNOWN_ABSENT = {
    -- Gone on this client; the addon may probe for them but must not depend
    -- on them.
    MouseIsOver = true, UnitBuff = true, UnitDebuff = true,
    GetSpellInfo = true, GetSpellTexture = true, IsSpellInRange = true,
    GetItemIcon = true, GetItemInfo = true, GetItemCount = true,
    GetNumSpellTabs = true, GetSpellTabInfo = true, GetSpellBookItemName = true,
    GetNumTalentTabs = true, GetTalentTabInfo = true, IsSpellKnown = true,
    GetAddOnMetadata = true, InterfaceOptions_AddCategory = true,
    InterfaceOptionsFrame_OpenToCategory = true,
    loadstring_untainted = true,
    -- LibStub itself, and the host table a consuming addon would own.
    LibStub = true, LibGroupBuffs = true,
    -- Lua/runtime names the test files themselves touch.
    arg = true, jit = true,
}

-- Installs strict globals and forgets the method calls made so far (the
-- kit's Kit.strict): the stub's own, while it was being built. A host whose
-- layer builds widgets calls it again at its end.
function WoW.strictGlobals()
    Kit.strict(KNOWN_ABSENT)
end

-- Consulted when a global is READ, so a host can call this after this file
-- has installed strict globals - which is the only order available to it.
function WoW.allowGlobal(...)
    for i = 1, select("#", ...) do KNOWN_ABSENT[(select(i, ...))] = true end
end

-- A widget method the stub models as doing nothing, for a host that calls
-- one this library does not. Confirm it in the build dump first: the kit's
-- methods check (Kit.checkMethods) still fails on a method the pinned build
-- lacks on that widget type. A method the build has needs no allowing: it
-- already reads as one.
function WoW.allowMethod(...)
    for i = 1, select("#", ...) do
        local name = select(i, ...)
        if not Methods[name] then Methods[name] = function() end end
    end
end

WoW.reset()
WoW.strictGlobals()
