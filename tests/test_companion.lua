------------------------------------------------------------
-- test_companion.lua - a pane of the addon's own under the window (#24),
-- and a deferred close that explains itself however it was asked for (#45).
--
-- Magely's cooldown pane is the consumer: Innervate and Power Infusion
-- providers, counting down every half second, in combat too. It is a plain
-- frame parented to UIParent and anchored under the window, which the client
-- lets an addon move, size and hide during a fight (measured on 70009,
-- Spotnick2/Magely#12). This builds one the way AGENTS.md says to, on the
-- window's hooks only, and runs every hook it relies on.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_companion.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
H.loadLibrary()
local lib = LibStub("LibGroupBuffs-1.0")

------------------------------------------------------------
-- The seams are validated like the others
------------------------------------------------------------

for _, key in ipairs({ "onTick", "onAppearance" }) do
    local engineHost = H.PriestEngine()
    local ok, err = pcall(lib.UI.New, { engine = engineHost.engine, owner = "Magely", [key] = 5 })
    H.check(not ok and tostring(err):find(key .. " must be a function", 1, true),
        key .. " must be a function or nil: " .. tostring(err))
end

------------------------------------------------------------
-- A Magely-shaped host with a companion pane
------------------------------------------------------------

local function Setup()
    WoW.reset()
    H.TeachSpells({ "FORT_SINGLE" })
    H.Party3()
    local host = H.PriestEngine()
    host.ticks, host.looks, host.saved = {}, {}, {}
    host.config.alpha = 0.9
    host.ui = lib.UI.New({
        engine = host.engine,
        owner  = "Magely",
        alpha  = function() return host.config.alpha end,
        getPos = function() return nil, "no saved pos" end,
        setPos = function() end,
        setVisible = function(v) host.saved.visible = v end,
        onCloseDeferred = function() host.deferredCloses = (host.deferredCloses or 0) + 1 end,
        -- The pane, built and anchored where the window lays itself out.
        onLayout = function(ui)
            local main = ui:MainFrame()
            if not host.pane then host.pane = CreateFrame("Frame", nil, UIParent) end
            host.pane:ClearAllPoints()
            host.pane:SetPoint("TOPLEFT", main, "BOTTOMLEFT", 0, -2)
            host.pane:SetWidth(main:GetWidth())
            host.pane:Show()
        end,
        -- Its visibility follows ui:IsVisible(), not the window's frame.
        onVisibility = function(_, visible)
            if host.pane then host.pane:SetShown(visible) end
        end,
        onTick = function(ui, elapsed) host.ticks[#host.ticks + 1] = elapsed end,
        -- What the window itself now wears, not what the host asked for.
        onAppearance = function(ui)
            host.looks[#host.looks + 1] = ui.main.glass.tint._colorTexture[4]
        end,
    })
    host.engine:RefreshSpells()
    host.ui:Update()
    return host
end

local host = Setup()
local ui, pane = host.ui, host.pane
H.check(pane ~= nil, "onLayout built the pane when the window laid itself out")
H.check(pane:IsShown(), "and showed it")
local point, relTo, relPoint = pane:GetPoint(1)
H.eq(relTo, ui:MainFrame(), "anchored to the window")
H.eq(point .. "/" .. relPoint, "TOPLEFT/BOTTOMLEFT", "under it")
H.eq(pane:GetWidth(), ui:MainFrame():GetWidth(), "at its width")
-- Parented to UIParent, not to the window: a child of a frame that parents
-- secure buttons is protected itself, and could not hide in combat.
H.eq(pane:GetParent(), UIParent, "and parented to UIParent, not to the protected window")

------------------------------------------------------------
-- onTick: the window's own half-second clock
------------------------------------------------------------

host.ticks = {}
H.runScript(ui.main, "OnUpdate", 0.3)
H.eq(#host.ticks, 0, "no tick before half a second has passed")
H.runScript(ui.main, "OnUpdate", 0.3)
H.eq(#host.ticks, 1, "one on the half-second tick")
H.near(host.ticks[1], 0.6, 0.0001, "with the time since the previous tick")

WoW.inCombat = true
host.ticks = {}
H.runScript(ui.main, "OnUpdate", 0.5)
H.eq(#host.ticks, 1, "and it keeps ticking in combat, when the cooldowns matter most")
WoW.inCombat = false

------------------------------------------------------------
-- onAppearance: the look reaches the pane without an Update
------------------------------------------------------------

host.looks = {}
host.config.alpha = 0.4
ui:ApplyAppearance()            -- what Magely's alpha slider calls, with no Update
H.eq(#host.looks, 1, "ApplyAppearance tells the pane, once")
H.near(host.looks[1], lib.glass.STYLE.tint[4] * 0.4, 0.0001,
    "after the window took the new look, so the pane matches what is on screen")

------------------------------------------------------------
-- A close in combat: the pane goes at once, the window when the fight ends
------------------------------------------------------------

WoW.inCombat = true
WoW.blockedCalls = {}
host.deferredCloses = 0
ui:Close(true)
H.check(ui.main:IsShown(), "the window's frame stays up: the client refuses to hide it")
H.check(not pane:IsShown(), "the pane hides AT ONCE, following ui:IsVisible()")
H.eq(#WoW.blockedCalls, 0, "which the client allows, the pane being non-secure")
host.ticks = {}
H.runScript(ui.main, "OnUpdate", 1.0)
H.eq(#host.ticks, 0, "and onTick stops with the window")
WoW.inCombat = false
ui:OnCombatEnd()
H.check(not ui.main:IsShown(), "the fight's end hides the window too")
WoW.flushTimers(1)

------------------------------------------------------------
-- #45: an automatic close in combat explains itself
--
-- A solo player unticks "show when solo" mid-fight. The close is the
-- addon's, not the player's - it must not save "never show" - but the window
-- visibly does not close, and used to say nothing about why.
------------------------------------------------------------

host = Setup()
ui = host.ui
WoW.groupMembers = 0                       -- solo
host.config.showSolo = true
local vis = lib.Visibility.New({
    ui = ui,
    isMyClass = function() return true end,
    showSolo = function() return host.config.showSolo end,
    getPreference = function() return true end,
    setPreference = function(v) host.preferenceWritten = v end,
})
WoW.inCombat = true
host.deferredCloses = 0
host.saved.visible = nil
host.config.showSolo = false
vis:SoloToggled(false)
H.check(not ui:IsVisible() and ui.main:IsShown(), "the window is closed but still on screen")
H.eq(host.deferredCloses, 1, "and the addon is asked to explain, though it was not the player's close")
H.eq(host.saved.visible, nil, "while the player's preference is left alone")
H.eq(host.preferenceWritten, nil, "on both sides")
vis:SoloToggled(false)
H.eq(host.deferredCloses, 1, "once per fight, not once per call")
WoW.inCombat = false
ui:OnCombatEnd()
WoW.flushTimers(1)

H.done("test_companion")
