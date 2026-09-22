------------------------------------------------------------
-- test_ui_clicks.lua - what the secure buttons are wired to, and what their
-- click handlers do to that wiring.
--
-- A row whose spell1 attribute names a spell the character does not have is a
-- click that does nothing, and the frame gives no hint of it. Asserting the
-- attributes is the closest a test gets to clicking without a game client.
-- Ported from Priestly's tests/test_clicks.lua with the same scenarios and
-- expected results, against a Priestly-shaped window (H.PriestUI).
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_ui_clicks.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
local lib = H.loadLibrary()

local host, ui

local function setup(known)
    WoW.reset()
    H.TeachSpells(known)
    host = H.PriestUI()
    ui = host.ui
    host.config.visible.shadow = false
    host.engine:RefreshSpells()
    H.Party3()
    ui:Update()
    return H.ActiveRows(ui)
end

local function click(row, button, script)
    H.runScript(row, script or "PreClick", button)
end

------------------------------------------------------------
-- Level 20: only the single-target spell exists
------------------------------------------------------------

local active = setup({ "FORT_SINGLE" })
H.eq(#active, 1, "one row: the one buff this character has")
local row = active[1]
H.eq(row:GetAttribute("type1"), "spell", "left-click casts a spell")
H.eq(row:GetAttribute("spell1"), "Power Word: Fortitude",
    "left-click falls back to the single-target spell, never a group spell that does not exist")
H.eq(row:GetAttribute("spell2"), "Power Word: Fortitude", "right-click likewise")
local u1 = row:GetAttribute("unit1")
H.check(u1 == "player" or u1 == "party1" or u1 == "party2",
    "the target is a group member, got " .. tostring(u1))

------------------------------------------------------------
-- The target follows who is actually missing the buff
------------------------------------------------------------

setup({ "FORT_SINGLE" })
WoW.SetAura("player", "Power Word: Fortitude", 3600, 3000)
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 3000)
ui:Update()
row = H.ActiveRows(ui)[1]
H.eq(row:GetAttribute("unit2"), "party2", "right-click aims at the one missing it")
H.eq(row:GetAttribute("unit1"), "party2", "and so does left-click, single-target here")

------------------------------------------------------------
-- With the group spell learned, left-click becomes the group cast
------------------------------------------------------------

setup({ "FORT_SINGLE", "FORT_GROUP" })
row = H.ActiveRows(ui)[1]
H.eq(row:GetAttribute("spell1"), "Prayer of Fortitude", "left-click is the group spell")
H.eq(row:GetAttribute("spell2"), "Power Word: Fortitude", "right-click stays single-target")

------------------------------------------------------------
-- Nobody valid: clear the spell rather than cast on yourself
------------------------------------------------------------

setup({ "FORT_SINGLE" })
for _, u in ipairs({ "player", "party1", "party2" }) do WoW.units[u].dead = true end
ui:Update()
row = H.ActiveRows(ui)[1]
H.check(row:GetAttribute("spell1") == nil, "nobody valid -> no spell on left-click")
H.check(row:GetAttribute("spell2") == nil, "same for right-click")

------------------------------------------------------------
-- PreClick re-picks at click time; in combat it leaves the wiring alone
------------------------------------------------------------

setup({ "FORT_SINGLE" })
for _, u in ipairs({ "player", "party1", "party2" }) do
    WoW.SetAura(u, "Power Word: Fortitude", 3600, 3000)
end
ui:Update()
row = H.ActiveRows(ui)[1]
WoW.ClearAuras("party1")                   -- falls off after the rebuild
click(row, "RightButton")
H.eq(row:GetAttribute("unit2"), "party1", "PreClick aims at whoever is missing it now")

WoW.inCombat = true
WoW.combatWrites = {}
WoW.ClearAuras("party2")
click(row, "RightButton")
H.eq(row:GetAttribute("unit2"), "party1", "in combat the wiring is left alone")
click(row, "RightButton", "PostClick")
H.eq(#WoW.combatWrites, 0, "and neither PreClick nor PostClick tried a protected write")
WoW.inCombat = false

------------------------------------------------------------
-- A button PreClick disarmed re-arms itself
------------------------------------------------------------

setup({ "FORT_SINGLE" })
row = H.ActiveRows(ui)[1]
for _, u in ipairs({ "player", "party1", "party2" }) do WoW.units[u].dead = true end
click(row, "RightButton")
H.check(row:GetAttribute("spell2") == nil, "nobody valid disarms the button")
WoW.units.party1.dead = false
click(row, "RightButton")
H.eq(row:GetAttribute("unit2"), "party1", "the next click retargets to them")
H.eq(row:GetAttribute("spell2"), "Power Word: Fortitude", "and re-arms the spell")

WoW.units.party1.dead = true
click(row, "LeftButton")
H.check(row:GetAttribute("spell1") == nil, "left-click disarms too")
WoW.units.party1.dead = false
click(row, "LeftButton")
H.eq(row:GetAttribute("spell1"), "Power Word: Fortitude", "and re-arms")

-- Range is not what disarms: the second pass ignores it.
WoW.range.player, WoW.range.party1, WoW.range.party2 = false, false, false
click(row, "RightButton")
H.eq(row:GetAttribute("spell2"), "Power Word: Fortitude", "out of range still arms the click")
H.check(row:GetAttribute("unit2") ~= nil, "and still aims at somebody")
WoW.range.player, WoW.range.party1, WoW.range.party2 = nil, nil, nil

------------------------------------------------------------
-- PostClick re-arms, but never at the build-time "player" fallback
------------------------------------------------------------

setup({ "FORT_SINGLE", "FORT_GROUP" })
row = H.ActiveRows(ui)[1]
row:SetAttribute("spell1", nil)
row:SetAttribute("spell2", nil)
click(row, "LeftButton", "PostClick")
H.eq(row:GetAttribute("spell1"), "Prayer of Fortitude", "spell1 is restored")
H.eq(row:GetAttribute("spell2"), "Power Word: Fortitude", "spell2 is restored")

for _, u in ipairs({ "player", "party1", "party2" }) do WoW.units[u].dead = true end
click(row, "LeftButton", "PostClick")
H.check(row:GetAttribute("spell1") == nil and row:GetAttribute("spell2") == nil,
    "with nobody valid PostClick leaves both disarmed rather than aiming at yourself")
WoW.flushTimers()

------------------------------------------------------------
-- Popover rows
------------------------------------------------------------

setup({ "FORT_SINGLE" })
row = H.ActiveRows(ui)[1]
H.runScript(row, "OnEnter")
local prs = ui.popRows
H.check(ui.pop:IsShown(), "hovering a row opens the popover")
H.check(prs[1]._active, "the popover has a row per member")
H.eq(prs[1]:GetAttribute("unit1"), "player", "each row targets its own member")
H.eq(prs[2]:GetAttribute("unit1"), "party1", "...the second one too")
H.eq(prs[1]:GetAttribute("spell1"), "Power Word: Fortitude", "with the spell the row casts")
H.check(prs[4]._active == false, "unused rows are released")

-- Popover PreClick blocks a cast at somebody dead; PostClick re-arms only the valid.
WoW.units.party1.dead = true
H.runScript(prs[2], "PreClick", "LeftButton")
H.check(prs[2]:GetAttribute("spell1") == nil, "a popover click at somebody dead is blocked")
H.runScript(prs[2], "PostClick", "LeftButton")
H.check(prs[2]:GetAttribute("spell1") == nil, "and not re-armed while they stay dead")
WoW.units.party1.dead = false
H.runScript(prs[2], "PostClick", "LeftButton")
H.eq(prs[2]:GetAttribute("spell1"), "Power Word: Fortitude", "and re-armed once they are back")
WoW.flushTimers()

------------------------------------------------------------
-- Two buffs, two rows, in the engine's def order
------------------------------------------------------------

active = setup({ "FORT_SINGLE", "SPIRIT_SINGLE" })
H.eq(#active, 2, "one row per buff")
H.eq(active[1]:GetAttribute("spell1"), "Power Word: Fortitude", "first row is Fortitude")
H.eq(active[2]:GetAttribute("spell1"), "Divine Spirit", "second row is Spirit")

------------------------------------------------------------
-- Both mouse edges, on every button in both pools
------------------------------------------------------------

local function bothEdges(btn)
    local set = {}
    for _, v in ipairs(btn._clicks or {}) do set[v] = true end
    for _, edge in ipairs({ lib.API.ClickEdges() }) do
        if not set[edge] then return false end
    end
    return set.LeftButtonDown and set.LeftButtonUp and set.RightButtonDown and set.RightButtonUp
end
local all = true
for _, r in ipairs(ui.rows) do all = all and bothEdges(r) and true or false end
for _, pr in ipairs(ui.popRows) do all = all and bothEdges(pr) and true or false end
H.check(all, "every row and popover button registers both mouse edges")
local typerelease = false
for _, r in ipairs(ui.rows) do
    if r:GetAttribute("typerelease") ~= nil then typerelease = true end
end
H.check(not typerelease, "and none sets typerelease, which would cast a second time")

------------------------------------------------------------
-- Which side the popover opens on
------------------------------------------------------------

setup({ "FORT_SINGLE" })
local anchor = H.ActiveRows(ui)[1]
WoW.centers[anchor] = 200
H.eq(ui:PopoverSide(anchor), "right", "a frame on the left opens the popover to the right")
WoW.centers[anchor] = 1700
H.eq(ui:PopoverSide(anchor), "left", "and a frame on the right opens it to the left")
host.ui_config.popoverSide = "left"
WoW.centers[anchor] = 200
H.eq(ui:PopoverSide(anchor), "left", "'always left' overrides a frame on the left")
host.ui_config.popoverSide = "right"
WoW.centers[anchor] = 1700
H.eq(ui:PopoverSide(anchor), "right", "'always right' overrides a frame on the right")
host.ui_config.popoverSide = "auto"
WoW.centers[anchor] = nil
H.eq(ui:PopoverSide(anchor), "left", "an unplaced row falls back to the left")
WoW.centers[anchor] = 200
WoW.screenWidth = 0
H.eq(ui:PopoverSide(anchor), "left", "and so does a zero-width screen, which is truthy")
WoW.screenWidth = 1920

WoW.centers[anchor] = 200
ui:UpdatePopover(anchor, anchor._members, anchor._def)
local point, rel, relPoint = ui.pop:GetPoint()
H.eq(point .. "/" .. relPoint, "LEFT/RIGHT", "the popover hangs off the row's right edge")
H.check(rel == anchor, "anchored to that row")

------------------------------------------------------------
-- Click hints
------------------------------------------------------------

local function hint(r)
    WoW.clearTooltip()
    ui:ShowClickHint(r)
    return WoW.tooltipText()
end

setup({ "FORT_SINGLE" })
row = H.ActiveRows(ui)[1]
local text = hint(row)
H.check(text:find("Power Word: Fortitude"), "the hint names the spell: " .. text)
H.check(not text:find("Prayer"), "never a group spell that cannot be cast: " .. text)
H.check(text:find("Left") and text:find("Right"), "a line per mouse button: " .. text)

setup({ "FORT_SINGLE", "FORT_GROUP" })
row = H.ActiveRows(ui)[1]
text = hint(row)
H.check(text:find("Prayer of Fortitude") and text:find("your party"),
    "the group cast names the group, not one member: " .. text)
H.check(text:find("Karuzo Elegia") or text:find("Sten Thornbeard") or text:find("Mirel Dawnsong"),
    "the single-target line names who it lands on: " .. text)

for _, u in ipairs({ "player", "party1", "party2" }) do WoW.units[u].dead = true end
text = hint(row)
H.check(text:find("nothing to buff"), "a row with no valid target says so: " .. text)
for _, u in ipairs({ "player", "party1", "party2" }) do WoW.units[u].dead = false end

-- In combat the hint reads the wired attributes: PreClick cannot re-aim there.
WoW.inCombat = true
row:SetAttribute("unit2", "party2")
text = hint(row)
H.check(text:find("Mirel Dawnsong"), "in combat the hint names the wired target: " .. text)
WoW.inCombat = false

host.ui_config.hints = false
H.eq(hint(row), "", "off by preference means no hint at all")
host.ui_config.hints = true

-- RowEnter shows the hint too; RowLeave drops it.
WoW.clearTooltip()
H.runScript(row, "OnEnter")
H.check(WoW.tooltipText() ~= "", "hovering a row shows its hint")
H.runScript(row, "OnLeave")
H.eq(WoW.tooltipText(), "", "and leaving it hides it")

------------------------------------------------------------
-- In combat the hint lists who still needs the buff
--
-- The popover cannot open then - it parents secure buttons - so the one
-- thing it was for goes in the tooltip, which is not protected.
------------------------------------------------------------

setup({ "FORT_SINGLE" })
row = H.ActiveRows(ui)[1]
WoW.SetAura("player", "Power Word: Fortitude", 3600, 1500)
ui:Update()
row = H.ActiveRows(ui)[1]

text = hint(row)
H.check(not text:find("Needs it"), "out of combat there is no list: the popover shows it")

WoW.inCombat = true
text = hint(row)
H.check(text:find("Needs it"), "in combat the hint lists them: " .. text)
H.check(text:find("Sten Thornbeard") and text:find("Mirel Dawnsong"),
    "naming those who need it: " .. text)
H.check(text:find("MISS"), "with what each one is missing: " .. text)
H.check(not text:find("Karuzo Elegia", 1, true),
    "and not the member who already has it: " .. text)
H.check(text:find("Power Word: Fortitude"), "the click lines are still there: " .. text)

-- Offline and unreadable are worth knowing too, and are not the same as MISS.
WoW.units.party1.connected = false
text = hint(row)
H.check(text:find("offline"), "an offline member is listed as that: " .. text)
WoW.units.party1.connected = true

H.secrecy(true)
for k in pairs(host.engine.cache) do host.engine.cache[k] = nil end
text = hint(row)
H.check(text:find("?"), "an unreadable member is listed with a question mark: " .. text)
H.secrecy(false)
WoW.inCombat = true

-- The mouse stays on the row and somebody gets buffed: OnEnter does not fire
-- again, so the ticker has to redraw the list or it keeps naming them.
WoW.clearTooltip()
H.runScript(row, "OnEnter")
WoW.mouseOver[row] = true
H.check(WoW.tooltipText():find("Sten Thornbeard"), "the list names them while hovering")
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 1500)
ui:RefreshTimers()
-- Only the list is asserted: in combat the click lines name whoever the
-- button is still wired to, which is the point of reading the attributes.
local needs = WoW.tooltipText():match("Needs it:(.*)$") or ""
H.check(not needs:find("Sten Thornbeard"),
    "and drops them once they are buffed, without leaving the row: " .. needs)
H.check(needs:find("Mirel Dawnsong"), "while still naming who is left")
WoW.mouseOver[row] = nil
H.runScript(row, "OnLeave")
ui:RefreshTimers()
H.eq(WoW.tooltipText(), "", "once the mouse leaves, nothing is redrawn")
WoW.ClearAuras("party1")

-- Nobody needs it: say so rather than leaving the section empty.
for _, u in ipairs({ "party1", "party2" }) do
    WoW.SetAura(u, "Power Word: Fortitude", 3600, 1500)
end
text = hint(row)
H.check(text:find("Everyone here has it"), "with everyone buffed it says so: " .. text)
H.check(not text:find("Needs it"), "and lists nobody")
WoW.inCombat = false

------------------------------------------------------------
-- Pet rows: the group spell's hint names the unit, not "the pets"
------------------------------------------------------------

WoW.reset()
H.TeachSpells({ "FORT_SINGLE", "FORT_GROUP" })
host = H.PriestUI()
ui = host.ui
host.config.visible.shadow = false
host.engine:RefreshSpells()
H.Party3()
WoW.SetUnit("partypet1", { name = "Broll", guid = "PET1" })
ui:Update()
local petRow
for _, r in ipairs(H.ActiveRows(ui)) do
    if r._gNum and r._gNum >= lib.Engine.PET_GROUP then petRow = r end
end
H.check(petRow ~= nil, "a pet row exists")
text = hint(petRow)
H.check(not text:find("pets") and text:find("Broll"),
    "a group spell on a pet row names the pet it lands on: " .. text)
H.eq(ui:GroupLabel(nil), "this group", "a group label for nothing still reads")

H.done("test_ui_clicks")
