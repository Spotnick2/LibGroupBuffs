------------------------------------------------------------
-- test_methods.lua - every widget method the library calls exists on the
-- client, for that widget type (WowTestKit's Kit.checkMethods, against the
-- build tests/kit.pin names).
--
-- The stub is the list of what this client has, methods included: a method
-- the build lacks reads as nil and fails where it is called. That does not
-- catch a method the stub IMPLEMENTS called on the wrong type (a
-- FontString:SetTexCoord), which this does. So the exercise below reaches as
-- much of the window as is cheap - built, filled, hovered, clicked, dragged,
-- minimized, closed in combat and reopened - plus the instance surface.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
H.loadLibrary()
local lib = LibStub("LibGroupBuffs-1.0")

-- A priest's window over a party of three, one of them buffed.
WoW.reset()
H.TeachSpells({ "FORT_SINGLE", "FORT_GROUP", "SPIRIT_SINGLE", "SHADOW_SINGLE" })
H.Party3()
WoW.SetAura("party1", H.NAME.FORT_SINGLE, 3600, 1200)
local host = H.PriestUI({ minimizable = true })
host.footer = { { itemID = 17029, usedBy = "the group Prayers" }, { itemID = 17028 } }
local ui = host.ui
host.engine:RefreshSpells()
ui:Update()
WoW.flushTimers(); WoW.flushTimers()

local rows = H.ActiveRows(ui)
check(#rows > 0, "the window has rows to exercise")
for _, r in ipairs(rows) do
    H.runScript(r, "OnEnter")
    H.runScript(r, "PreClick", "LeftButton", false)
    H.runScript(r, "PostClick", "LeftButton", false)
    H.runScript(r, "OnLeave")
end
ui:UpdatePopover(rows[1], rows[1]._members, rows[1]._def)
for _, pr in ipairs(ui.popRows) do
    if pr._unit then
        H.runScript(pr, "OnEnter")
        H.runScript(pr, "PreClick", "LeftButton", false)
        H.runScript(pr, "PostClick", "LeftButton", false)
        H.runScript(pr, "OnLeave")
    end
end
ui:ShowClickHint(rows[1])
ui:HideClickHint()
for _, b in ipairs(ui.footerBtns) do
    if b:IsShown() then H.runScript(b, "OnEnter"); H.runScript(b, "OnLeave") end
end
H.runScript(ui.main, "OnUpdate", 0.6)
ui:RefreshTimers()
H.runScript(ui.main.dragHandle, "OnDragStart")
H.runScript(ui.main.dragHandle, "OnDragStop")
ui:ResetPosition()

local mb = ui.main.minimizeBtn
H.runScript(mb, "OnEnter")
H.runScript(mb, "OnClick")
H.runScript(mb, "OnLeave")
H.runScript(mb, "OnClick")

host.ui_config.alpha, host.ui_config.scale, host.ui_config.growth = 0.5, 1.2, "UP"
host.look = { popDivider = { 1, 0.5, 0 } }
ui:ApplyAppearance()
ui:SetPreview(5)
ui:SetPreview(nil)
ui:Update()

-- A close in combat, kept until the fight ends; then the close button.
WoW.inCombat = true
ui:Update()
ui:Close(true)
WoW.inCombat = false
ui:OnCombatEnd()
ui:Open()
WoW.flushTimers(); WoW.flushTimers()
local close = ui.main.closeBtn
H.runScript(close, "OnEnter")
H.runScript(close, "OnLeave")
H.runScript(close, "OnClick", "LeftButton")

-- The instance surface: New, its events and its settings.
local inst = lib:New({ owner = "MethodsHost", report = function() end })
local events = CreateFrame("Frame")
events:SetScript("OnEvent", function() end)
inst.RegisterEvents(events, "PLAYER_LOGIN", "GROUP_ROSTER_UPDATE", "UNIT_AURA")
local saved = {}
local settings = inst.Settings({
    scopes = { { label = "per-character", get = function() return saved end } },
})
settings:Set("alpha", 0.8)
settings:HandleEnteringWorld(true, false)
for frame, set in pairs(WoW.events) do
    for e in pairs(set) do WoW.dispatch(e) end
end

-- Every method recorded must be on that widget type in the pinned build. The
-- BackdropTemplate methods are allowed by tests/wow_stubs.lua, with their
-- Blizzard file. The floor is what the exercise records today, rounded down:
-- it keeps the exercise from quietly shrinking.
local recorded = Kit.checkMethods()
check(recorded >= 90, "the exercise reached the window (" .. recorded .. " recorded)")

H.done("test_methods")
