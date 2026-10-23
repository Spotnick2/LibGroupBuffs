dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
H.loadLibrary()

WoW.reset()
H.TeachSpells({ "FORT_SINGLE", "SPIRIT_SINGLE" })
local host = H.PriestUI({ minimizable = true })
host.engine:RefreshSpells()
H.Party3()
local ui = host.ui
ui:Update()
H.eq(H.ActiveRows(ui)[1]:GetAttribute("type1"), "spell", "live row begins castable")
local saved = host.saved.visible

H.eq(ui:SetPreview(5), true, "five-group preview accepted outside combat")
ui:Update()
H.eq(#H.ActiveRows(ui), 15, "preview shows every definition for five groups")
H.eq(host.saved.visible, saved, "preview does not write visibility")
H.check(not ui.main.closeBtn:IsShown() and not ui.main.minimizeBtn:IsShown(),
    "preview disables controls that would change window state")
for _, row in ipairs(ui.rows) do
    H.eq(row:GetAttribute("type1"), nil, "preview leaves no primary secure action")
    H.eq(row:GetAttribute("type2"), nil, "preview leaves no secondary secure action")
    H.eq(row:GetAttribute("unit1"), nil, "preview leaves no old target")
end
local row = H.ActiveRows(ui)[1]
H.runScript(row, "OnEnter")
H.check(ui.pop:IsShown(), "preview popover opens on hover")
H.eq(ui.popRows[1].nameTxt:GetText(), "Member 1", "preview popover shows synthetic member")
H.eq(ui.popRows[1]:GetAttribute("type1"), nil, "preview popover cannot cast")
H.eq(ui.popRows[1]:GetAttribute("unit1"), nil, "preview popover has no target")
H.runScript(row, "PreClick", "LeftButton")
H.runScript(row, "PostClick", "LeftButton")
H.eq(row:GetAttribute("spell1"), nil, "preview click cannot rearm a spell")

H.eq(ui:SetPreview(8), true, "eight-group preview accepted")
ui:Update()
H.eq(#H.ActiveRows(ui), 24, "eight groups render at full size")
WoW.inCombat = true
WoW.blockedCalls = {}
H.eq(ui:SetPreview(nil), false, "leaving preview waits for combat")
ui:Update()
H.eq(#WoW.blockedCalls, 0, "combat preview touches no protected frame")
H.check(ui:IsPreview(), "preview remains active in combat")
WoW.inCombat = false
H.eq(ui:SetPreview(nil), true, "preview exits after combat")
ui:Update()
H.check(not ui:IsPreview(), "live UI restored")
H.eq(#H.ActiveRows(ui), 2, "real roster replaces synthetic groups")
H.eq(H.ActiveRows(ui)[1]:GetAttribute("type1"), "spell", "real row is rearmed")
H.check(ui.main.closeBtn:IsShown(), "normal close control returns")
H.eq(host.saved.visible, saved, "restoring live UI preserves visibility")

H.done("ui preview")
