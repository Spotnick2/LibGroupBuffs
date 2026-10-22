dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
H.loadLibrary()
local lib = LibStub("LibGroupBuffs-1.0")
local function setup(enabled)
    WoW.reset()
    H.TeachSpells({ "FORT_SINGLE", "SPIRIT_SINGLE" })
    H.Party3()
    local h = H.PriestUI({ minimizable = enabled })
    h.config.visible.shadow = false
    h.footer = { { itemID = 17029 } }
    h.engine:RefreshSpells()
    h.ui:Update()
    return h, h.ui
end
local function settle() WoW.flushTimers(); WoW.flushTimers() end
local function cleanCombat(label)
    H.eq(#WoW.blockedCalls, 0, label .. ": no protected-frame mutation")
    H.eq(#WoW.combatWrites, 0, label .. ": no secure attribute write")
end

local host, ui = setup()
H.eq(ui.main.minimizeBtn, nil, "existing hosts do not gain a new control")
H.eq(ui:SetMinimized(true), false, "existing hosts cannot minimize accidentally")
H.check(not ui:IsMinimized(), "existing host remains expanded")
H.check(not pcall(lib.UI.New, { engine = host.engine, owner = "Bad", minimizable = 1 }),
    "opt-in must be a boolean")

host, ui = setup(true)
local fullHeight = ui.main:GetHeight()
local btn = ui.main.minimizeBtn
H.check(btn ~= nil, "opted-in host gets minimize control")
H.eq(btn.label:GetText(), "-", "expanded window offers minimize")
H.runScript(btn, "OnEnter")
H.check(GameTooltip:IsShown(), "minimize has a tooltip")
H.runScript(btn, "OnLeave")
H.check(not GameTooltip:IsShown(), "leaving control dismisses tooltip")
local row = H.ActiveRows(ui)[1]
H.runScript(row, "OnEnter")
H.check(ui.pop:IsShown(), "popup initially open")
ui.main:ClearAllPoints()
ui.main:SetPoint("CENTER", UIParent, "CENTER", 100, -50)
H.runScript(btn, "OnClick")
H.check(ui:IsMinimized() and ui:IsVisible() and ui.main:IsShown(), "minimized is still open")
H.check(ui.main:GetHeight() < fullHeight, "body collapses to header")
H.eq(#H.ActiveRows(ui), 0, "collapsed rows are inactive")
for _, r in ipairs(ui.rows) do H.check(not r:IsShown(), "secure rows hidden outside combat") end
for _, b in ipairs(ui.footerBtns) do H.check(not b:IsShown(), "footer hidden") end
H.check(not ui.main.ftrLine:IsShown(), "footer separator hidden")
H.check(not ui.pop:IsShown(), "popup dismissed")
ui:UpdatePopover(row, row._members, row._def)
H.check(not ui.pop:IsShown(), "direct popup refresh cannot reopen collapsed content")
H.eq(btn.label:GetText(), "+", "restore remains accessible")
H.eq(host.saved.visible, true, "minimize does not save a close")
local p, _, rp, x, y = ui.main:GetPoint()
H.eq(p, "TOPLEFT", "header is anchored instead of the changing centre")
H.near(x, 100 - ui.main:GetWidth() / 2, 0.001, "left edge is unchanged")
H.near(y, -50 + fullHeight / 2, 0.001, "top edge is unchanged")
ui:ScheduleRefresh(); settle()
H.check(ui:IsMinimized() and ui.main:GetHeight() < fullHeight, "routine refresh retains minimized state")
H.runScript(btn, "OnClick")
H.eq(ui.main:GetHeight(), fullHeight, "restore rebuilds full layout")
local p2, _, rp2, x2, y2 = ui.main:GetPoint()
H.check(p == p2 and rp == rp2 and x == x2 and y == y2, "restore keeps header position")
H.check(#H.ActiveRows(ui) > 0 and ui.footerBtns[1]:IsShown(), "rows and footer return")

-- Latest requested mode wins, without any protected writes until combat ends.
for _, modes in ipairs({ { true }, { true, false }, { true, false, true } }) do
    host, ui = setup(true)
    local height = ui.main:GetHeight()
    WoW.inCombat = true
    for _, mode in ipairs(modes) do ui:SetMinimized(mode) end
    ui:SetMinimized(modes[#modes]) -- duplicate request is not reported again
    H.eq(#host.minimizeRequests, #modes, "only state changes report deferral")
    H.eq(ui.main:GetHeight(), height, "layout waits for combat end")
    H.check(#H.ActiveRows(ui) > 0, "rows stay usable until combat ends")
    H.runScript(ui.main.minimizeBtn, "OnEnter")
    H.runScript(ui.main.minimizeBtn, "OnLeave")
    cleanCombat("queued minimize")
    WoW.inCombat = false
    ui:OnCombatEnd(); settle()
    H.eq(ui.main._minimized, modes[#modes], "last mode applied after combat")
end

host, ui = setup(true)
ui:SetMinimized(true)
local smallHeight = ui.main:GetHeight()
WoW.inCombat = true
ui:SetMinimized(false)
H.eq(ui.main:GetHeight(), smallHeight, "restore waits for combat end too")
H.check(#H.ActiveRows(ui) == 0, "restoring cannot expose secure rows during combat")
cleanCombat("queued restore")
WoW.inCombat = false
ui:OnCombatEnd(); settle()
H.check(not ui.main._minimized and #H.ActiveRows(ui) > 0, "restore completes")

-- Close beats either mode, regardless of the order it was requested.
for _, closeFirst in ipairs({ false, true }) do
    host, ui = setup(true)
    WoW.inCombat = true
    if closeFirst then ui:Close(true) end
    ui:SetMinimized(true)
    if not closeFirst then ui:Close(true) end
    cleanCombat("close and minimize")
    WoW.inCombat = false
    ui:OnCombatEnd(); settle()
    H.check(not ui:IsVisible() and not ui.main:IsShown(), "minimize cannot resurrect a closed window")
    H.eq(host.saved.visible, false, "manual close preference retained")
    ui:Open(0); settle()
    H.check(ui:IsVisible() and ui.main._minimized, "reopen retains session minimize preference")
end
host, ui = setup(true)
ui:Open(2)
ui:SetMinimized(true)
ui:Close(true)
settle()
H.check(not ui.main:IsShown(), "older queued show cannot beat close after minimize")

-- Empty roster is still an automatic close; a later roster can reopen collapsed.
host, ui = setup(true)
ui:SetMinimized(true)
host.config.showSolo = false
WoW.groupMembers = 0
ui:Update()
H.check(not ui:IsVisible(), "empty roster closes even when minimized")
H.Party3()
ui:Open(0); settle()
H.check(ui.main._minimized, "automatic reopen does not expand the header")

-- A collapsed drag is stored with a stable top anchor, including at a scale.
host, ui = setup(true)
host.ui_config.scale = 1.75
ui:SetMinimized(true)
H.eq(ui.main:GetScale(), 1.75, "scale applies to header")
ui.main:ClearAllPoints()
ui.main:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -80, 50)
H.runScript(ui.main.dragHandle, "OnDragStart")
H.runScript(ui.main.dragHandle, "OnDragStop")
local saved = host.saved.pos
H.eq(saved.point, "TOPLEFT", "collapsed drag saves top anchor for next login")
ui:SetMinimized(false)
local _, _, _, restoredX, restoredY = ui.main:GetPoint()
H.check(restoredX == saved.x and restoredY == saved.y, "restoring after drag keeps saved top")
host.ui_config.locked = true
ui:SetMinimized(true)
H.runScript(ui.main.dragHandle, "OnDragStart")
H.runScript(ui.main.dragHandle, "OnDragStop")
H.eq(host.saved.pos, saved, "lock preserves saved position")
ui:ResetPosition()
ui:SetMinimized(false)
H.eq(host.saved.pos, nil, "reset remains available when locked and minimized")

-- Companion hosts opt in only after honoring IsMinimized in their layout hook.
host, ui = setup(true)
local pane = CreateFrame("Frame", nil, UIParent)
ui.host.onLayout = function(u)
    if u:IsVisible() and not u:IsMinimized() then pane:Show() else pane:Hide() end
end
ui:Update()
H.check(pane:IsShown(), "opted-in companion follows expanded layout")
ui:SetMinimized(true)
H.check(not pane:IsShown(), "companion hides on minimized layout")
ui:Update()
H.check(not pane:IsShown(), "routine minimized rebuild does not resurrect companion")
ui:SetMinimized(false)
H.check(pane:IsShown(), "companion restores with body")
H.done("test_minimize")
