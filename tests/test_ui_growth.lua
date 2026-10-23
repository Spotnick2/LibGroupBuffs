dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
H.loadLibrary()

WoW.reset()
H.TeachSpells({ "FORT_SINGLE", "SPIRIT_SINGLE" })
local host = H.PriestUI({ minimizable = true })
host.ui_config.growth = "down"
host.saved.pos = { point = "CENTER", relPoint = "CENTER", x = 120, y = 80 }
host.engine:RefreshSpells()
H.Party3()
local ui = host.ui
ui:Update()

local main = ui.main
local point, _, relPoint, x, y = main:GetPoint()
H.eq(point, "TOPLEFT", "old centre position migrated to fixed top edge")
H.eq(relPoint, "CENTER", "relative anchor preserved")
H.near(x, 120 - main:GetWidth() / 2, 0.001, "migration preserves horizontal placement")
H.near(y, 80 + main:GetHeight() / 2, 0.001, "migration preserves top placement")
H.eq(host.saved.pos.point, "TOPLEFT", "migrated position saved")
H.near(host.saved.pos.y, y, 0.001, "saved top edge matches visible edge")

local top = y
host.config.enabled.spirit = false
ui:Update()
local _, _, _, _, after = main:GetPoint()
H.near(after, top, 0.001, "removing a row keeps the top edge fixed")
host.config.enabled.spirit = true
ui:Update()
_, _, _, _, after = main:GetPoint()
H.near(after, top, 0.001, "adding a row keeps the top edge fixed")

local height = main:GetHeight()
host.ui_config.growth = "up"
ui:Update()
point, _, _, _, y = main:GetPoint()
H.eq(point, "BOTTOMLEFT", "direction switch anchors the bottom")
H.near(y, top - height, 0.001, "direction switch preserves the current rectangle")
H.eq(host.saved.pos.point, "BOTTOMLEFT", "direction switch persists the new anchor")
local bottom = y
host.config.enabled.spirit = false
ui:Update()
_, _, _, _, after = main:GetPoint()
H.near(after, bottom, 0.001, "removing a row keeps the bottom edge fixed")

ui:ToggleMinimized()
_, _, _, _, after = main:GetPoint()
H.near(after, bottom, 0.001, "minimizing keeps the selected edge fixed")
ui:ToggleMinimized()
_, _, _, _, after = main:GetPoint()
H.near(after, bottom, 0.001, "restoring keeps the selected edge fixed")

WoW.inCombat = true
WoW.blockedCalls = {}
host.ui_config.growth = "down"
ui:Update()
H.eq(#WoW.blockedCalls, 0, "combat growth change touches no protected frame")
point = main:GetPoint()
H.eq(point, "BOTTOMLEFT", "combat growth change waits")
WoW.inCombat = false
ui:OnCombatEnd()
WoW.flushTimers(1)
point = main:GetPoint()
H.eq(point, "TOPLEFT", "combat growth change applies afterward")

H.eq(ui:ResetPosition(), true, "reset succeeds")
point = main:GetPoint()
H.eq(point, "TOPLEFT", "reset uses selected fixed edge")
H.eq(host.saved.pos, nil, "reset leaves no saved position")

H.done("ui growth")
