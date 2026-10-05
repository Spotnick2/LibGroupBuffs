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

-- A window built but never laid out: its first rebuild found nobody to buff
-- (solo, "show when solo" off), so Init made the frames and onLayout never
-- ran - there is no pane yet. The alpha slider must not reach onAppearance.
do
    WoW.reset()
    H.TeachSpells({ "FORT_SINGLE" })
    local early = H.PriestEngine()
    early.config.showSolo = false
    local paneless, heard = nil, 0
    local eui = lib.UI.New({
        engine = early.engine, owner = "Magely",
        onLayout = function() paneless = paneless or CreateFrame("Frame", nil, UIParent) end,
        onAppearance = function() heard = heard + 1; paneless:SetAlpha(1) end,
    })
    early.engine:RefreshSpells()
    eui:Update()
    H.check(eui.main ~= nil and paneless == nil, "built, but never laid out: no pane")
    H.check(pcall(eui.ApplyAppearance, eui), "the slider moving then does not reach a pane that is not there")
    H.eq(heard, 0, "onAppearance waits for the first onLayout")
end

-- The first show runs onVisibility(true) BEFORE the first onLayout. A host
-- syncing its look from there (ApplyAppearance) must not reach onAppearance
-- yet: the pane onLayout builds does not exist (Codex review of #53).
do
    WoW.reset()
    H.TeachSpells({ "FORT_SINGLE" })
    H.Party3()
    local first = H.PriestEngine()
    local order, firstPane = {}, nil
    local fui = lib.UI.New({
        engine = first.engine, owner = "Magely",
        onVisibility = function(u, visible)
            order[#order + 1] = "visibility:" .. tostring(visible)
            if visible then u:ApplyAppearance() end
        end,
        onLayout = function()
            order[#order + 1] = "layout"
            firstPane = firstPane or CreateFrame("Frame", nil, UIParent)
        end,
        onAppearance = function()
            order[#order + 1] = "appearance"
            firstPane:SetAlpha(1)
        end,
    })
    first.engine:RefreshSpells()
    H.check(pcall(fui.Update, fui), "the first show completes")
    H.eq(table.concat(order, ","), "visibility:true,layout",
        "and onAppearance waits for the first onLayout, even when asked from onVisibility")
    fui:ApplyAppearance()
    H.eq(order[#order], "appearance", "after which the slider reaches it")
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
        onCloseDeferred = function(_, manual)
            host.deferredCloses = (host.deferredCloses or 0) + 1
            host.deferredManual = manual
        end,
        -- The pane, built and anchored where the window lays itself out.
        onLayout = function(ui)
            local main = ui:MainFrame()
            if not host.pane then host.pane = CreateFrame("Frame", nil, UIParent) end
            host.pane:ClearAllPoints()
            host.pane:SetPoint("TOPLEFT", main, "BOTTOMLEFT", 0, -2)
            -- UIParent's child: it does not inherit the window's scale.
            host.pane:SetScale(main:GetScale())
            host.pane:SetWidth(main:GetWidth())
            host.pane:Show()
            host.layouts = (host.layouts or 0) + 1
        end,
        -- Its visibility follows ui:IsVisible(), not the window's frame.
        onVisibility = function(_, visible)
            if host.pane then host.pane:SetShown(visible) end
        end,
        onTick = function(ui, elapsed) host.ticks[#host.ticks + 1] = elapsed end,
        -- What the window itself now wears, not what the host asked for.
        -- Touches the pane straight away, as a host would: onLayout made it.
        onAppearance = function(ui)
            host.pane:SetScale(ui:MainFrame():GetScale())
            host.looks[#host.looks + 1] = ui.main.glass.tint._colorTexture[4]
        end,
        scale = function() return host.config.scale end,
    })
    host.engine:RefreshSpells()
    host.ui:Update()                -- would throw if onAppearance ran before onLayout
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
H.eq(#host.looks, 0, "and onAppearance did not run inside the rebuild: onLayout covers it")
ui:Update()
H.eq(#host.looks, 0, "nor inside any later rebuild")
-- Parented to UIParent: the shape measured free in combat (Magely#12). A
-- child of the window would hide whenever it does, and take its alpha.
H.eq(pane:GetParent(), UIParent, "and parented to UIParent, the shape measured in combat")

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

-- A host's onTick that throws is the host's script error - not hidden -
-- but it runs last, so the window's own refresh on that frame still happens.
do
    local footers = 0
    local realFooter = lib.UIMethods.RefreshFooter
    lib.UIMethods.RefreshFooter = function(self, ...) footers = footers + 1 return realFooter(self, ...) end
    local realTick = ui.host.onTick
    ui.host.onTick = function() error("the pane's own bug", 0) end
    ui.tick, ui.footerTick = 0.49, 2.99
    local ok, err = pcall(ui.main._scripts.OnUpdate, ui.main, 0.02)
    H.check(not ok and tostring(err):find("the pane's own bug", 1, true),
        "a throwing onTick surfaces: " .. tostring(err))
    H.eq(footers, 1, "after the footer refresh due on the same frame")
    lib.UIMethods.RefreshFooter = realFooter
    ui.host.onTick = realTick
end

------------------------------------------------------------
-- onAppearance: the look reaches the pane without an Update
------------------------------------------------------------

host.looks = {}
host.config.alpha = 0.4
ui:ApplyAppearance()            -- what Magely's alpha slider calls, with no Update
H.eq(#host.looks, 1, "ApplyAppearance tells the pane, once")
H.near(host.looks[1], lib.glass.STYLE.tint[4] * 0.4, 0.0001,
    "after the window took the new look, so the pane matches what is on screen")

-- The scale slider: ApplyAppearance rescales the window, and the pane, a
-- child of UIParent, has to follow or its width is wrong on screen.
host.config.scale = 1.3
ui:ApplyAppearance()
H.eq(ui:MainFrame():GetScale(), 1.3, "the window took the new scale")
H.eq(pane:GetScale(), 1.3, "and the pane followed it in onAppearance")
host.config.scale = nil
ui:ApplyAppearance()

------------------------------------------------------------
-- A fresh clock on every show
------------------------------------------------------------

host.ticks = {}
H.runScript(ui.main, "OnUpdate", 0.45)
ui:Close(true)
ui:Update()                     -- reopened later
H.runScript(ui.main, "OnUpdate", 0.06)
H.eq(#host.ticks, 0, "time left over from before a close does not tick the reopened window")
H.eq(ui.footerTick, 0.06, "and the footer's clock restarted with it")
H.runScript(ui.main, "OnUpdate", 0.45)
H.eq(#host.ticks, 1, "half a second of THIS showing does")

------------------------------------------------------------
-- A close in combat: the pane goes at once, the window when the fight ends
------------------------------------------------------------

WoW.inCombat = true
WoW.blockedCalls = {}
host.deferredCloses = 0
ui:Close(true)
H.check(ui.main:IsShown(), "the window's frame stays up: the client refuses to hide it")
H.check(not pane:IsShown(), "the pane hides AT ONCE, following ui:IsVisible()")
H.eq(#WoW.blockedCalls, 0, "and the library made no call the client blocks")
host.ticks = {}
H.runScript(ui.main, "OnUpdate", 1.0)
H.eq(#host.ticks, 0, "and onTick stops with the window")
WoW.inCombat = false
ui:OnCombatEnd()
H.check(not ui.main:IsShown(), "the fight's end hides the window too")
WoW.flushTimers(1)

------------------------------------------------------------
-- Reopened after a fight, before the fight's end was handled
--
-- A timer can rebuild the window out of combat before PLAYER_REGEN_ENABLED
-- reaches OnCombatEnd. That later show wins over the close recorded in combat,
-- or OnCombatEnd would hide a window that is logically open - and leave a
-- pane that follows IsVisible on screen with nothing above it.
------------------------------------------------------------

ui:Update()
WoW.inCombat = true
ui:Close(true)
WoW.inCombat = false
ui:Update()                     -- shown again before the fight's end is handled
ui:OnCombatEnd()
H.check(ui:IsVisible() and ui.main:IsShown(), "the later show wins: open, and on screen")
H.check(pane:IsShown(), "with the pane under it")
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
H.eq(host.deferredManual, false, "told it was automatic, so it can word it as such")
H.eq(host.saved.visible, nil, "while the player's preference is left alone")
H.eq(host.preferenceWritten, nil, "on both sides")
vis:SoloToggled(false)
H.eq(host.deferredCloses, 1, "once per fight, not once per call")
-- Re-ticked in the same fight: the window is wanted again, so the close just
-- explained is reversed, and untick once more is a new close to explain.
host.config.showSolo = true
vis:SoloToggled(true)
WoW.flushTimers(1)                          -- the show it queued, refused in combat
H.check(ui.pendingShow, "the show is recorded for the fight's end")
host.config.showSolo = false
vis:SoloToggled(false)
H.eq(host.deferredCloses, 2, "and a close after it is explained again, not swallowed by the latch")
WoW.inCombat = false
ui:OnCombatEnd()
WoW.flushTimers(1)

H.done("test_companion")
