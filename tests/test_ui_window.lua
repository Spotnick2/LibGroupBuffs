------------------------------------------------------------
-- test_ui_window.lua - the window's life: every handler it installs, combat
-- parking, showing and closing, position, appearance, the footer, pool sizes,
-- and two addons' windows side by side.
--
-- Strict globals only catch what actually runs, so every script handler the
-- library installs is executed here. And the stub's frames answer unknown
-- METHODS with a silent no-op, so each handler's effect is asserted, not
-- just that it ran.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_ui_window.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
local lib = H.loadLibrary()

local host, ui

local function setup(known)
    WoW.reset()
    H.TeachSpells(known or { "FORT_SINGLE", "SPIRIT_SINGLE" })
    host = H.PriestUI()
    ui = host.ui
    host.config.visible.shadow = false
    host.engine:RefreshSpells()
    H.Party3()
end

------------------------------------------------------------
-- Construction
------------------------------------------------------------

do
    WoW.reset()
    local e = H.PriestEngine().engine
    local function newWith(over)
        local h = { engine = e, owner = "X" }
        for k, v in pairs(over) do h[k] = v end
        return pcall(lib.UI.New, h)
    end
    H.check(newWith({}), "an engine and an owner are enough")
    H.check(not newWith({ engine = {} }), "the engine must be one of this library's")
    H.check(not newWith({ owner = "" }), "an owner is required")
    H.check(not newWith({ footerItems = {} }), "a hook that is not a function is an error")
    local bare = lib.UI.New({ engine = e, owner = "X" })
    H.eq(bare.main, nil, "construction builds no frames: the addon may be loading into combat")
    WoW.inCombat = true
    H.eq(bare:Init(), false, "and Init refuses in combat - secure buttons cannot be created there")
    H.eq(bare.main, nil, "leaving nothing half-built")
    WoW.inCombat = false
end

------------------------------------------------------------
-- Frames are anonymous: the library creates no globals
------------------------------------------------------------

setup()
local before = {}
for k in pairs(_G) do before[k] = true end
ui:Update()
local added = {}
for k in pairs(_G) do
    if not before[k] then added[#added + 1] = tostring(k) end
end
H.eq(#added, 0, "building the window adds no globals: " .. table.concat(added, ", "))

------------------------------------------------------------
-- Pool sizes come from the worst roster the engine can produce
------------------------------------------------------------

do
    local groups, rows, pop = ui:Capacity()
    H.eq(groups, 13, "8 subgroups + 5 pet buckets of 8")
    H.eq(rows, 13 * 3, "a row for every group and every def")
    H.eq(pop, 8, "a popover row per bucket member")
    H.eq(#ui.rows, rows, "that many row buttons")
    H.eq(#ui.popRows, pop, "and popover buttons")
    H.eq(#ui.headers, groups, "and group headers")

    -- A small popover still has to fit a whole raid subgroup: only pets are
    -- split into buckets.
    WoW.reset()
    local small = lib.Engine.New({ defs = { { id = "x", snglID = 1243 } }, bucketSize = 2 })
    local smallUI = lib.UI.New({ engine = small, owner = "Small" })
    local g2, r2, p2 = smallUI:Capacity()
    H.eq(g2, 8 + 20, "a 2-member popover means 20 pet buckets")
    H.eq(r2, 28, "one def, one row per group")
    H.eq(p2, 5, "but a popover row for every member of a subgroup of five")
end

-- The whole worst roster renders, for more than one bucket size.
for _, size in ipairs({ 8, 3 }) do
    WoW.reset()
    H.TeachSpells({ "FORT_SINGLE", "SPIRIT_SINGLE", "SHADOW_SINGLE" })
    WoW.inRaid = true
    WoW.groupMembers = 40
    for i = 1, 40 do
        local nm = "Raider" .. i .. " Sur"
        WoW.raidRoster[i] = { name = nm, subgroup = math.ceil(i / 5) }
        WoW.SetUnit("raid" .. i, { name = nm, guid = "R" .. i, class = "HUNTER" })
        WoW.SetUnit("raidpet" .. i, { name = "Pet" .. i, guid = "PET" .. i })
    end
    local eh = H.PriestEngine()
    local defs = eh.defs
    local e = lib.Engine.New({ defs = defs, bucketSize = size })
    e:RefreshSpells()
    local w = lib.UI.New({ engine = e, owner = "Big" })
    w:Update()
    local seen, rendered = {}, 0
    for _, r in ipairs(w.rows) do
        if r._active then
            rendered = rendered + 1
            for _, m in ipairs(r._members) do seen[m.unit] = true end
        end
    end
    local groups = 8 + math.ceil(40 / size)
    H.eq(rendered, groups * 3, "bucket size " .. size .. ": every group gets all three rows")
    local missing = 0
    for i = 1, 40 do
        if not seen["raid" .. i] or not seen["raidpet" .. i] then missing = missing + 1 end
    end
    H.eq(missing, 0, "bucket size " .. size .. ": every raider and every pet is on screen")
end

------------------------------------------------------------
-- Rows: order, headers, visuals
------------------------------------------------------------

setup()
ui:Update()
local active = H.ActiveRows(ui)
H.eq(#active, 2, "two buffs, two rows for a party")
H.eq(active[1]._def.id, "fort", "in the engine's def order")
H.check(ui.main:IsShown() and ui:IsVisible(), "the window is shown and logically open")
H.eq(host.saved.visible, true, "and the addon is told to remember that")
H.eq(host.layouts, 1, "onLayout ran once for the rebuild")
H.eq(host.visibility[#host.visibility], true, "and onVisibility heard it open")

local shown = 0
for _, h in ipairs(ui.headers) do if h:IsShown() then shown = shown + 1 end end
H.eq(shown, 0, "a party gets no group headers")

-- A pet row gets a header; the second bucket is numbered.
setup()
WoW.SetUnit("partypet1", { name = "Broll", guid = "PET1" })
ui:Update()
shown = 0
for _, h in ipairs(ui.headers) do if h:IsShown() then shown = shown + 1 end end
H.eq(shown, 1, "the pet group gets a header")

-- Everyone missing, some missing, all present, unreadable.
setup({ "FORT_SINGLE" })
ui:Update()
local row = H.ActiveRows(ui)[1]
H.check(row.missAll:IsShown(), "nobody buffed: MISS is shown")
WoW.SetAura("player", "Power Word: Fortitude", 3600, 1800)
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 1800)
WoW.SetAura("party2", "Power Word: Fortitude", 3600, 1800)
ui:RefreshTimers()
H.check(row.timer:IsShown() and not row.missAll:IsShown(), "everyone buffed: the timer shows")
H.eq(row.timer:GetText(), "30:00", "with the lowest time left")
H.check(not row.missCount:IsShown(), "and no missing count")
WoW.ClearAuras("party2")
ui:RefreshTimers()
H.check(row.missCount:IsShown(), "one missing: the count shows")
H.eq(row.missCount:GetText(), 1, "and says one")
H.secrecy(true)
for k in pairs(host.engine.cache) do host.engine.cache[k] = nil end
ui:RefreshTimers()
H.check(row.missAll:IsShown() and not row.timer:IsShown(), "unreadable and nothing cached")
H.eq(row.missAll:GetText(), "?", "shows '?', not a confident MISS")
H.secrecy(false)

-- A member's state looks the same wherever it is drawn. The row's MISS and
-- the popover's used different reds until they were put in one table.
setup({ "FORT_SINGLE" })
ui:Update()
do
    local r = H.ActiveRows(ui)[1]
    ui:RefreshTimers()
    H.eq(r.missAll:GetText(), "MISS", "nobody buffed: the row says MISS")
    H.eq(r.missAll._textColor[1] .. "," .. r.missAll._textColor[2],
        lib.UI.STATE_COLOUR.MISS[1] .. "," .. lib.UI.STATE_COLOUR.MISS[2],
        "in the shared MISS colour")
    H.runScript(r, "OnEnter")
    local pr = ui.popRows[1]
    H.eq(pr.timeTxt:GetText(), "MISS", "and so does the popover row")
    H.eq(pr.timeTxt._textColor[2], lib.UI.STATE_COLOUR.MISS[2],
        "in the same colour, not a second red")
    WoW.units.party1.connected = false
    ui:RefreshTimers()
end

------------------------------------------------------------
-- The ticker and the popover's hover poll
------------------------------------------------------------

setup({ "FORT_SINGLE" })
host.footer = { { itemID = 17056, usedBy = "Levitate" } }
ui:Update()
local reads = 0
local realRead = lib.API.ReadBuff
lib.API.ReadBuff = function(...) reads = reads + 1 return realRead(...) end
H.runScript(ui.main, "OnUpdate", 0.2)
H.eq(reads, 0, "under half a second the ticker does nothing")
H.runScript(ui.main, "OnUpdate", 0.4)
H.check(reads > 0, "past half a second it refreshes the timers")
lib.API.ReadBuff = realRead
WoW.itemCounts[17056] = 7
H.runScript(ui.main, "OnUpdate", 3.0)
H.eq(ui.footerBtns[1].countTxt:GetText(), 7, "and every three seconds the footer recounts")

ui:Close()
reads = 0
lib.API.ReadBuff = function(...) reads = reads + 1 return realRead(...) end
H.runScript(ui.main, "OnUpdate", 1.0)
lib.API.ReadBuff = realRead
H.eq(reads, 0, "a closed window's ticker reads nothing")

setup({ "FORT_SINGLE" })
ui:Update()
row = H.ActiveRows(ui)[1]
H.runScript(row, "OnEnter")
H.check(ui.pop:IsShown(), "the popover is open")
WoW.mouseOver[row] = true
H.runScript(ui.pop, "OnUpdate", 0.2)
H.check(ui.pop:IsShown(), "it stays while the mouse is on its row")
WoW.mouseOver[row] = nil
WoW.mouseOver[ui.popRows[1]] = true
H.runScript(ui.pop, "OnUpdate", 0.2)
H.check(ui.pop:IsShown(), "or on one of its buttons")
WoW.mouseOver[ui.popRows[1]] = nil
H.runScript(ui.pop, "OnUpdate", 0.05)
H.check(ui.pop:IsShown(), "it waits a moment before deciding")
H.runScript(ui.pop, "OnUpdate", 0.2)
H.check(not ui.pop:IsShown(), "and hides once the mouse is elsewhere")

-- In combat it cannot be hidden at all: it parents secure buttons, so the
-- client refuses. It waits for the fight to end instead.
H.runScript(row, "OnEnter")
WoW.inCombat = true
WoW.blockedCalls = {}
H.runScript(ui.pop, "OnUpdate", 0.2)
H.check(ui.pop:IsShown(), "in combat the popover stays on screen")
H.eq(#WoW.blockedCalls, 0, "without attempting anything the client would block")
H.runScript(ui.pop, "OnUpdate", 0.2)
H.eq(#WoW.blockedCalls, 0, "and it stops polling rather than trying every tick")
WoW.inCombat = false
ui:OnCombatEnd()
H.check(not ui.pop:IsShown(), "combat's end hides it")
WoW.flushTimers()

-- The offline tooltip on a popover row belongs to that row's member.
setup({ "FORT_SINGLE" })
ui:Update()
row = H.ActiveRows(ui)[1]
H.runScript(row, "OnEnter")
WoW.units.party1.connected = false
local offlineRow
for _, pr in ipairs(ui.popRows) do if pr._unit == "party1" then offlineRow = pr end end
WoW.clearTooltip()
H.runScript(offlineRow, "OnEnter")
H.check(WoW.tooltipText():find("offline"), "an offline member's row says so: " .. WoW.tooltipText())
H.check(WoW.tooltipText():find("Sten Thornbeard"), "naming them")
H.runScript(offlineRow, "OnLeave")
H.eq(WoW.tooltipText(), "", "and the tooltip goes on leaving")
WoW.clearTooltip()
H.runScript(ui.popRows[1], "OnEnter")
H.eq(WoW.tooltipText(), "", "an online member's row shows nothing")

------------------------------------------------------------
-- Showing and closing
------------------------------------------------------------

setup()
ui:Update()
H.runScript(ui.main.closeBtn, "OnClick")
H.check(not ui:IsVisible() and not ui.main:IsShown(), "the close button closes the window")
H.eq(host.saved.visible, false, "and it was the player's choice, so it is remembered")

ui:Update()
ui:Close()
H.eq(host.saved.visible, true, "closing for the addon's own reasons is not remembered")

-- Closing wins over a show queued before it.
setup()
ui:Open(0.5)
ui:Close()
WoW.flushTimers(1)
H.check(not ui:IsVisible(), "a queued show does not reopen a window closed after it")
ui:Open(0.5)
WoW.flushTimers(1)
H.check(ui:IsVisible(), "a show queued after the close does open it")

-- Opening coalesces too. The events that open a window arrive in pairs -
-- RAID_ROSTER_UPDATE with GROUP_ROSTER_UPDATE, PLAYER_TALENT_UPDATE with
-- SPELLS_CHANGED - and each queued Update is a full rebuild.
setup()
host.layouts = 0
ui:Open(0.5); ui:Open(0.5); ui:Open(0.5)
WoW.flushTimers(1)
H.eq(host.layouts, 1, "three shows queued in one frame are one rebuild")

-- A sooner request supersedes a pending later one rather than being dropped.
setup()
ui:Update()
host.layouts = 0
ui:Close()
ui:Open(0.6)
ui:Open(0.2)
WoW.flushTimers(0.3)
H.eq(host.layouts, 1, "a 0.2s show queued behind a 0.6s one happens at 0.2s")
WoW.flushTimers(1)
H.eq(host.layouts, 1, "and the later timer does not rebuild again")

-- A later request behind a sooner one is absorbed AND does not push the
-- rebuild back: dropping the "something sooner is already waiting" check
-- leaves one rebuild either way, but at 0.6s instead of 0.2s.
setup()
ui:Update()
host.layouts = 0
ui:Close()
ui:Open(0.2)
ui:Open(0.6)
WoW.flushTimers(0.3)
H.eq(host.layouts, 1, "the sooner show still happens at 0.2s")
WoW.flushTimers(1)
H.eq(host.layouts, 1, "and the later one is absorbed rather than rebuilding again")

-- Closing still beats a queued show, which is why this lives in the library:
-- a host-side coalescer would call Update directly and lose the check.
setup()
ui:Open(0.5)
ui:Close()
WoW.flushTimers(1)
H.check(not ui:IsVisible(), "a close after a queued show still wins")
ui:Open(0.5)
WoW.flushTimers(1)
H.check(ui:IsVisible(), "and a show queued after that close opens it")

-- The same, without the clock moving in between: a close and a reopen in one
-- frame queue two timers with the IDENTICAL deadline. If the pending request
-- were identified by its deadline, the cancelled timer would recognise the
-- live request as its own, clear it, and then bail on the generation check -
-- and the window would never open.
setup()
host.layouts = 0
ui:Open(0.5)
ui:Close()
ui:Open(0.5)
WoW.flushTimers(1)
H.check(ui:IsVisible(), "a reopen at the same deadline as the show it cancelled still opens")
H.eq(host.layouts, 1, "once")

-- ScheduleRefresh never opens a closed window, and coalesces bursts.
setup()
ui:ScheduleRefresh()
WoW.flushTimers(1)
H.check(not ui:IsVisible(), "a refresh never opens a closed window")
ui:Update()
local layouts = host.layouts
ui:ScheduleRefresh(); ui:ScheduleRefresh(); ui:ScheduleRefresh()
WoW.flushTimers(1)
H.eq(host.layouts, layouts + 1, "three refresh requests are one rebuild")

-- In combat: Update refreshes only, a show waits, Close parks.
setup()
WoW.inCombat = true
WoW.combatWrites = {}
ui:Update()
H.check(not ui:IsVisible(), "a show asked for in combat does not happen yet")
H.eq(#WoW.combatWrites, 0, "and writes nothing")
WoW.inCombat = false
ui:OnCombatEnd()
WoW.flushTimers(1)
H.check(ui:IsVisible(), "it happens when combat ends")

WoW.inCombat = true
WoW.combatWrites = {}
ui:Update()
H.eq(#WoW.combatWrites, 0, "a rebuild in combat is visual only: no attribute is written")
ui:ScheduleRefresh()
WoW.flushTimers(1)
H.eq(#WoW.combatWrites, 0, "nor by a refresh that fires in combat")
WoW.blockedCalls = {}
host.deferredCloses = 0
H.eq(ui:Close(), false, "closing in combat cannot hide the window, and says so")
H.eq(host.deferredCloses, 0, "a close the addon made itself tells nobody")
H.check(ui:IsVisible() == false, "though it is logically closed")
ui:Update(); WoW.inCombat = false; ui:Update(); WoW.inCombat = true
H.runScript(ui.main.closeBtn, "OnClick")
H.eq(host.deferredCloses, 1, "but the X button in combat asks the addon to explain")
H.runScript(ui.main.closeBtn, "OnClick")
H.eq(host.deferredCloses, 1, "and asks once per pending close, not once per click")
H.eq(#WoW.blockedCalls, 0, "without attempting a call the client blocks")
H.check(ui.main:IsShown(), "the frame is still up - it parents secure buttons")
H.check(not ui:IsVisible(), "but the window is logically closed")
H.eq(host.visibility[#host.visibility], false, "onVisibility hears it, though the frame is still shown")
local ticks = 0
local realRead2 = lib.API.ReadBuff
lib.API.ReadBuff = function(...) ticks = ticks + 1 return realRead2(...) end
H.runScript(ui.main, "OnUpdate", 1.0)
lib.API.ReadBuff = realRead2
H.eq(ticks, 0, "and stops refreshing")
WoW.inCombat = false
ui:OnCombatEnd()
H.check(not ui.main:IsShown(), "combat's end hides it for real")
WoW.flushTimers(1)
H.check(not ui:IsVisible(), "and does not reopen it")

-- Closing between combat's end and its deferred rebuild wins.
setup()
ui:Update()
WoW.inCombat = true
ui:Close()
WoW.inCombat = false
ui:Update()                       -- asked to show again right after the fight
ui:OnCombatEnd()
ui:Close()                        -- and closed before the deferred rebuild
WoW.flushTimers(1)
H.check(not ui:IsVisible(), "a close after combat's end beats the rebuild it queued")

-- The window can close ITSELF during a fight - the group empties - and the
-- frame stays up because the client refuses to hide it. The player clicking X
-- on a window they can still see has to be answered, even though it is
-- already logically closed.
setup()
ui:Update()
WoW.inCombat = true
host.deferredCloses = 0
ui:Close()                                  -- the addon's own close: the group emptied
H.check(ui.main:IsShown() and not ui:IsVisible(), "still on screen, logically closed")
H.eq(host.deferredCloses, 0, "its own close explains nothing")
H.runScript(ui.main.closeBtn, "OnClick")
H.eq(host.deferredCloses, 1, "but the player clicking X on the visible window is answered")
H.runScript(ui.main.closeBtn, "OnClick")
H.eq(host.deferredCloses, 1, "once")
WoW.inCombat = false
ui:OnCombatEnd()
H.check(not ui.main:IsShown(), "and the fight's end hides it")
WoW.flushTimers(1)

-- Once it is really hidden, closing again says nothing: there is no window.
WoW.inCombat = true
host.deferredCloses = 0
ui:Close(true)
H.eq(host.deferredCloses, 0, "closing a window that is not on screen explains nothing")
WoW.inCombat = false
WoW.flushTimers(1)

------------------------------------------------------------
-- Dragging, lock and position
------------------------------------------------------------

setup()
ui:Update()
H.eq(ui:RestoreInfo().log, "used the DEFAULT - no saved pos", "no saved position: the default, and why")
H.runScript(ui.main.dragHandle, "OnDragStart")
H.check(ui.main._moving, "dragging the header moves the window")
ui.main:ClearAllPoints()
ui.main:SetPoint("TOPLEFT", nil, "TOPLEFT", 120, -80)
H.runScript(ui.main.dragHandle, "OnDragStop")
H.check(not ui.main._moving, "releasing stops it")
H.eq(host.saved.pos and host.saved.pos.x, 120, "and the addon is asked to save where it went")

host.ui_config.locked = true
H.runScript(ui.main.dragHandle, "OnDragStart")
H.check(not ui.main._moving, "a locked window does not start moving")
ui.main._moving = true              -- the lock flipped mid-drag
host.saved.pos = { point = "CENTER", relPoint = "CENTER", x = 1, y = 1 }
H.runScript(ui.main.dragHandle, "OnDragStop")
H.check(not ui.main._moving, "a drag interrupted by the lock is still released")
H.eq(host.saved.pos.x, 1, "but the interrupted position is not saved")
host.ui_config.locked = false

WoW.inCombat = true
WoW.blockedCalls = {}
H.runScript(ui.main.dragHandle, "OnDragStart")
H.check(not ui.main._moving, "in combat the window does not start moving: it parents secure buttons")
H.eq(#WoW.blockedCalls, 0, "and nothing the client blocks is attempted")
WoW.inCombat = false

-- A drag combat interrupts: the release is blocked too, so the frame follows
-- the cursor until the fight ends, and the position is saved then.
setup()
ui:Update()
host.saved.pos = nil
H.runScript(ui.main.dragHandle, "OnDragStart")
H.check(ui.main._moving, "the drag starts out of combat")
WoW.inCombat = true
WoW.blockedCalls = {}
H.runScript(ui.main.dragHandle, "OnDragStop")
H.eq(#WoW.blockedCalls, 0, "releasing in combat attempts nothing the client blocks")
H.check(ui.main._moving, "so the window is still following the cursor")
H.eq(host.saved.pos, nil, "and nothing is saved yet")
WoW.inCombat = false
ui.main:ClearAllPoints()
ui.main:SetPoint("TOPLEFT", nil, "TOPLEFT", 42, -42)
ui:OnCombatEnd()
H.check(not ui.main._moving, "combat's end releases it")
H.eq(host.saved.pos and host.saved.pos.x, 42, "and saves where it ended up")
WoW.flushTimers(1)

-- The saved position is applied once per session, and refreshes are counted.
setup()
host.saved.pos = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 50, y = -60 }
ui:Update()
H.check(ui:RestoreInfo().log:find("applied saved TOPLEFT/TOPLEFT 50.0,%-60.0"),
    "a saved position is applied: " .. ui:RestoreInfo().log)
ui:Update(); ui:Update()
H.eq(ui:RestoreInfo().skips, 2, "later rebuilds skip the restore and are only counted")
H.check(ui:RestoreInfo().log:find("applied saved"), "without overwriting what it decided")

-- Reset ignores the lock; in combat it waits.
host.ui_config.locked = true
H.eq(ui:ResetPosition(), true, "reset moves the window now, lock or not")
H.eq(host.saved.pos, nil, "and forgets the saved spot")
local p, _, _, x = ui.main:GetPoint()
H.check(p == "CENTER" and x == 300, "back at the default")
host.ui_config.locked = false

ui.main:ClearAllPoints()
ui.main:SetPoint("TOPLEFT", nil, "TOPLEFT", 5, 5)
WoW.inCombat = true
WoW.blockedCalls = {}
H.eq(ui:ResetPosition(), false, "in combat reset only records the wish")
H.eq(#WoW.blockedCalls, 0, "without attempting to move a protected frame")
WoW.inCombat = false
ui:OnCombatEnd()
p, _, _, x = ui.main:GetPoint()
H.check(p == "CENTER" and x == 300, "it moves when combat ends")
WoW.flushTimers(1)

------------------------------------------------------------
-- Appearance and alpha
------------------------------------------------------------

setup()
host.look = { icon = "SPEC_ICON" }
ui:Update()
H.eq(ui.main.specIcon:GetTexture(), "SPEC_ICON", "the addon's spec icon is used")
local custom = ui:Appearance()
H.eq(custom.icon, "SPEC_ICON", "the appearance carries the addon's icon")
H.eq(custom.border[1], 0.40, "and the default colours for everything it does not set")
host.look = { header = { 0.5, 0.2, 0.0, 1 } }
H.eq(ui:Appearance().header[1], 0.5, "an addon can recolour the header (Wildly's orange)")
host.ui_config.alpha = 0.5
H.eq(ui:Alpha(), 0.5, "opacity comes from the addon")
H.check(pcall(ui.ApplyAppearance, ui), "and is applied without touching the frame alpha")
host.ui_config.alpha = "bad"
H.eq(ui:Alpha(), 0.96, "a nonsense opacity falls back to the default")

------------------------------------------------------------
-- The footer
------------------------------------------------------------

setup()
host.footer = {
    { itemID = 17029, usedBy = "the group Prayers",
      color = function(n) if n >= 50 then return 0, 1, 0 end return 1, 0, 0 end },
    { itemID = 17056, usedBy = "Levitate" },
}
WoW.itemCounts[17029] = 12
ui:Update()
H.check(ui.footerBtns[1]:IsShown() and ui.footerBtns[2]:IsShown(), "one button per footer item")
H.check(ui.main.ftrLine:IsShown(), "under a divider")
WoW.clearTooltip()
H.runScript(ui.footerBtns[1], "OnEnter")
local tip = WoW.tooltipText()
H.check(tip:find("Item 17029") and tip:find("12 in your bags") and tip:find("group Prayers"),
    "the tooltip names the item, the count and what uses it: " .. tip)
-- The item's quality reaches the PLAYER, not just API.ItemInfo. Until the
-- stub kept the colour arguments this could only be checked coming out of the
-- API: the call site could shuffle r, g and b, or drop them, and stay green.
local tr, tg, tb = WoW.tooltipColour(1)
H.check(tr and tg and tb, "the item's name line is coloured at all")
H.near(tr, 0.1, 0.001, "by its quality - a common reagent here")
WoW.itemQuality[17029] = 4
WoW.clearTooltip()
H.runScript(ui.footerBtns[1], "OnEnter")
H.near(select(1, WoW.tooltipColour(1)), 0.4, 0.001,
    "and a rarer item is coloured differently, in that order")
WoW.itemQuality[17029] = nil

H.runScript(ui.footerBtns[1], "OnLeave")
H.eq(WoW.tooltipText(), "", "and goes away")

WoW.itemsUncached[17056] = true
WoW.clearTooltip()
H.runScript(ui.footerBtns[2], "OnEnter")
H.check(WoW.tooltipText():find("Loading"), "an uncached item shows a placeholder")
WoW.itemsUncached[17056] = nil

-- And the footer asks for what it draws, so that placeholder is rare. A
-- tooltip opened on a cache miss has nothing to re-run it, so it reads
-- "Loading..." for as long as the cursor stays on it; the refresh runs at
-- build time and every few seconds, well before anyone can hover.
WoW.itemsRequested = {}
WoW.itemsUncached[60101] = true
WoW.time = (WoW.time or 0) + 100
host.footer = { { itemID = 60101, usedBy = "something uncached" } }
ui:Update()
H.check(WoW.itemsRequested[60101],
    "drawing a reagent asks the client to load its name")

-- A hover that lands BEFORE the data does. The load is asynchronous, so
-- preloading lowers the odds of a miss without removing it: a player can
-- hover the moment the window appears. The placeholder has nothing to re-run
-- it, so without this it stays under the cursor for the whole hover.
setup()
host.footer = { { itemID = 60201, usedBy = "something slow" } }
WoW.itemsUncached[60201] = true
ui:Update()
WoW.clearTooltip()
H.runScript(ui.footerBtns[1], "OnEnter")
H.check(WoW.tooltipText():find("Loading"), "hovering before the data arrives shows the placeholder")

-- ... the item lands, and the ticker finishes the job.
WoW.itemsUncached[60201] = nil
ui:MainTick(1)
H.check(WoW.tooltipText():find("Item 60201"),
    "and the tooltip catches up once the item arrives: " .. WoW.tooltipText())
H.check(WoW.tooltipText():find("in your bags"), "with the rest of its lines intact")

-- Only OUR tooltip. Between the hover and the data landing the player may
-- have moved onto something else, and GameTooltip is shared.
setup()
host.footer = { { itemID = 60202, usedBy = "something slow" } }
WoW.itemsUncached[60202] = true
ui:Update()
WoW.clearTooltip()
H.runScript(ui.footerBtns[1], "OnEnter")
H.check(WoW.tooltipText():find("Loading"), "the placeholder is showing")
GameTooltip:SetOwner(UIParent, "ANCHOR_RIGHT")
GameTooltip:SetText("Somebody else's tooltip")
WoW.itemsUncached[60202] = nil
ui:MainTick(1)
H.check(WoW.tooltipText():find("Somebody else"),
    "a tooltip that is no longer ours is left alone: " .. WoW.tooltipText())

-- And leaving the button stops it waiting.
setup()
host.footer = { { itemID = 60203, usedBy = "something slow" } }
WoW.itemsUncached[60203] = true
ui:Update()
WoW.clearTooltip()
H.runScript(ui.footerBtns[1], "OnEnter")
H.runScript(ui.footerBtns[1], "OnLeave")
H.check(not ui.tipPending, "leaving the reagent stops the tooltip waiting for it")

host.footer = {}
ui:Update()
H.check(not ui.footerBtns[1]:IsShown() and not ui.main.ftrLine:IsShown(),
    "no items: no footer at all")
ui.footerBtns[1]._itemID = nil
WoW.clearTooltip()
H.runScript(ui.footerBtns[1], "OnEnter")
H.eq(WoW.tooltipText(), "", "a button with no item opens no tooltip")

------------------------------------------------------------
-- An open popover follows a rebuild
------------------------------------------------------------

setup({ "FORT_SINGLE" })
ui:Update()
row = H.ActiveRows(ui)[1]
H.runScript(row, "OnEnter")
H.eq(ui.popRows[3]:GetAttribute("unit1"), "party2", "the popover lists party2")
WoW.RemoveUnit("party2")
WoW.groupMembers = 2
ui:Update()
H.check(not ui.popRows[3]._active, "after party2 leaves, the open popover drops them")
WoW.RemoveUnit("party1")
WoW.groupMembers = 0
host.config.showSolo = false
ui:Update()
H.check(not ui:IsVisible(), "and with nobody left the window closes")

------------------------------------------------------------
-- A host filter that leaves a group with nobody
--
-- Wildly's Thorns goes on tanks only. A group with no tank has no Thorns row,
-- so it must get no header either - and a window where every buff filtered
-- down to nobody must not open empty.
------------------------------------------------------------

local function tankHost(tanks)
    WoW.reset()
    H.TeachSpells({ "FORT_SINGLE" })
    local e = lib.Engine.New({
        defs = { { id = "thorns", snglID = 1243, sngl = "Power Word: Fortitude" } },
        bucketSize = 8,
        membersFor = function(_, members)
            local out = {}
            for _, m in ipairs(members) do
                if tanks[m.unit] then out[#out + 1] = m end
            end
            return out
        end,
    })
    e:RefreshSpells()
    return lib.UI.New({ engine = e, owner = "Wildly" })
end

local w = tankHost({})
H.Party3()
w:Update()
H.check(not w:IsVisible() and not (w.main and w.main:IsShown()),
    "a party with no tank does not open an empty window")

w = tankHost({ raid1 = true })
WoW.inRaid = true
WoW.groupMembers = 10
for i = 1, 10 do
    WoW.raidRoster[i] = { name = "R" .. i, subgroup = (i <= 5) and 1 or 2 }
    WoW.SetUnit("raid" .. i, { name = "R" .. i, guid = "G" .. i })
end
w:Update()
local headers = 0
for _, h in ipairs(w.headers) do if h:IsShown() then headers = headers + 1 end end
H.eq(#H.ActiveRows(w), 1, "a raid with a tank only in group 1 gets one row")
H.eq(headers, 1, "and one header - group 2 has nobody to buff, so no header")
-- Em dashes, written as UTF-8 bytes so this file stays ASCII: the client
-- takes the bytes either way, and a literal dash here would depend on how
-- the editor saved it.
local EM = "\226\128\148"
H.eq(w.headers[1]:GetText(), EM .. " Group 1 " .. EM, "the header is group 1's")
H.eq(w.headers[1]:GetJustifyH(), "CENTER", "centred across the row, not tucked against it")
H.eq(#H.ActiveRows(w)[1]._members, 1, "the row covers just the tank")

------------------------------------------------------------
-- Appearance changes reach what is already on screen
------------------------------------------------------------

setup()
WoW.inRaid = true
WoW.groupMembers = 3
WoW.raidRoster = { { name = "Karuzo Elegia", subgroup = 1 } }
WoW.SetUnit("raid1", { name = "Karuzo Elegia", guid = "P0" })
ui:Update()
host.look = { groupText = { 1, 0.5, 0 } }
ui:ApplyAppearance()
H.eq(ui.headers[1]._textColor and ui.headers[1]._textColor[2], 0.5,
    "a new header colour recolours the existing group labels")

------------------------------------------------------------
-- The popover's divider follows the appearance: Wildly draws it orange
------------------------------------------------------------

local function sameColour(got, want, msg)
    H.check(type(got) == "table", msg .. ": a colour was set")
    for i = 1, 4 do
        H.eq(got and got[i], want[i], msg .. " (component " .. i .. ")")
    end
end
local DEFAULT_DIVIDER = lib.UI.DEFAULT_APPEARANCE.popDivider
local ORANGE = { 0.95, 0.47, 0.06, 0.55 }

-- Building alone, with nothing else run: Init is where it must be coloured.
setup()
ui:Init()
sameColour(ui.pop._hdiv._colorTexture, DEFAULT_DIVIDER, "a freshly built divider is the default colour")

-- An override the addon already has when the window is built.
setup()
host.look = { popDivider = ORANGE }
ui:Init()
sameColour(ui.pop._hdiv._colorTexture, ORANGE, "an override present at build time is used from the start")
H.eq(ui.main.hdrLine._colorTexture and ui.main.hdrLine._colorTexture[1],
    lib.UI.DEFAULT_APPEARANCE.headerLine[1], "while the keys it leaves out keep their defaults")

-- A popover that has no divider at all - nothing to adopt - gets exactly one,
-- built out of combat and never under lockdown.
setup()
ui:Init()
local lost = ui.pop._hdiv
lost:ClearAllPoints()           -- no longer where a divider sits, so not adoptable
ui.pop._hdiv = nil
WoW.inCombat = true
H.eq(ui:PopDivider(), nil, "in combat, a missing divider is not built")
WoW.inCombat = false
local rebuilt = ui:PopDivider()
H.check(rebuilt ~= nil and rebuilt ~= lost, "out of combat it is built")
H.eq(ui:PopDivider(), rebuilt, "once: asking again returns the same line")

-- And one that changes later, on a window already built.
setup()
ui:Init()
host.look = { popDivider = ORANGE }
ui:ApplyAppearance()
sameColour(ui.pop._hdiv._colorTexture, ORANGE, "a changed divider colour recolours the built popover")
host.look = nil
ui:ApplyAppearance()
sameColour(ui.pop._hdiv._colorTexture, DEFAULT_DIVIDER, "and dropping the override restores the default")

-- Every built-in icon is a real texture path, backslashes intact: Lua reads
-- "\I" in a string as a plain "I", so a lost backslash is silent.
for class, icon in pairs(lib.UI.CLASS_ICONS) do
    H.check(icon:sub(1, 16) == "Interface\\Icons\\", class .. "'s icon is a texture path: " .. icon)
end


------------------------------------------------------------
-- The stub refuses every protected call, so the check below means something
------------------------------------------------------------

setup({ "FORT_SINGLE" })
ui:Update()
do
    local protectedFrame = ui.rows[1]         -- a secure button
    local parent = ui.main                    -- protected: it parents them
    WoW.inCombat = true
    for _, method in ipairs({ "Show", "Hide", "SetPoint", "ClearAllPoints",
                              "SetClampedToScreen", "SetAlpha", "SetSize", "SetScale",
                              "StartMoving", "StopMovingOrSizing", "SetParent" }) do
        for _, f in ipairs({ protectedFrame, parent }) do
            WoW.blockedCalls = {}
            f[method](f, 1, 2)
            H.eq(#WoW.blockedCalls, 1, method .. " on a protected frame is refused and recorded")
        end
    end
    -- The refusal must also leave the frame alone.
    WoW.inCombat = false
    parent:SetAlpha(1)
    parent:Show()
    WoW.inCombat = true
    parent:SetAlpha(0)
    parent:Hide()
    H.eq(parent:GetAlpha(), 1, "a refused SetAlpha changes nothing")
    H.check(parent:IsShown(), "and a refused Hide leaves the frame up")
    WoW.inCombat = false
end

------------------------------------------------------------
-- Nothing the window does in combat is a blocked call
------------------------------------------------------------

setup({ "FORT_SINGLE" })
ui:Update()
row = H.ActiveRows(ui)[1]
H.runScript(row, "OnEnter")
WoW.inCombat = true
WoW.blockedCalls, WoW.combatWrites = {}, {}
ui:Update()
ui:RefreshTimers()
ui:RefreshFooter()
ui:ApplyAppearance()
ui:ScheduleRefresh()
ui:UpdatePopover(row, row._members, row._def)
ui:ShowClickHint(row)
H.runScript(row, "PreClick", "LeftButton")
H.runScript(row, "PostClick", "LeftButton")
H.runScript(ui.popRows[1], "PreClick", "LeftButton")
H.runScript(ui.popRows[1], "PostClick", "LeftButton")
H.runScript(ui.main, "OnUpdate", 1.0)
H.runScript(ui.pop, "OnUpdate", 1.0)
H.runScript(ui.main.dragHandle, "OnDragStart")
H.runScript(ui.main.dragHandle, "OnDragStop")
H.runScript(ui.main.closeBtn, "OnClick")
ui:ResetPosition()
WoW.flushTimers(1)
H.eq(#WoW.blockedCalls, 0, "not one protected call is attempted during a fight")
H.eq(#WoW.combatWrites, 0, "and not one secure attribute is written")
WoW.inCombat = false
ui:OnCombatEnd()
WoW.flushTimers(1)

------------------------------------------------------------
-- Two addons, two windows
------------------------------------------------------------

setup()
local other = H.PriestUI({ owner = "Wildly", title = "Wildly" })
other.config.visible.shadow = false
other.engine:RefreshSpells()
ui:Update()
H.check(ui:IsVisible() and not other.ui:IsVisible(), "opening one window leaves the other closed")
other.ui:Update()
H.check(ui.main ~= other.ui.main and ui.rows[1] ~= other.ui.rows[1], "each has its own frames")
ui:Close(true)
H.check(other.ui:IsVisible(), "closing one leaves the other open")
H.eq(other.saved.visible, true, "and only the closed one's addon hears about it")
H.check(getmetatable(ui) == getmetatable(other.ui), "both run one shared set of methods")

------------------------------------------------------------
-- The glass material
--
-- None of this asserts that it LOOKS right - only a client can say that.
-- What it asserts is that the layers exist and carry what they were given,
-- because the stub answers an unknown widget method with a no-op: a material
-- that drew nothing at all would otherwise pass every test in this file.
------------------------------------------------------------

setup()
ui:Update()

-- The window is a glass panel, not a Blizzard dialog backdrop.
local glass = ui.main.glass
H.check(type(glass) == "table", "the window has a glass panel")
H.check(glass.mask and glass.mask._isMask, "with a rounded mask")
H.check(glass.tint and glass.tint._masks and #glass.tint._masks == 1,
    "a tint clipped to it")
H.check(glass.shadow and glass.shadow._slice ~= nil, "a nine-sliced drop shadow")
H.check(glass.rim and glass.rim._slice ~= nil, "and a sliced rim")
H.check(glass.top and glass.top:GetFrameLevel() > ui.main:GetFrameLevel(),
    "with the rim's layer above the panel, so content cannot draw over it")

-- Every texture the material names must be a file that ships: a typo here is
-- a green suite and a missing texture in game.
local media = lib.Glass.MEDIA
H.check(type(media) == "string" and media:find("Media"), "media path: " .. tostring(media))
H.check(glass.shadow._texture:find(media, 1, true) == 1,
    "and the layers are loaded from it: " .. tostring(glass.shadow._texture))

-- A row's colour is a glass bar's colour now.
local row = ui.rows[1]
H.check(type(row.fill) == "table", "a row has a glass fill")
H.check(row.fill.mask and row.fill.mask._isMask, "rounded by a mask")
-- Each layer clipped to it, or the colour keeps its square corners while the
-- gloss above it is rounded - which reads as a sticker rather than as glass.
for _, layer in ipairs({ "bg", "gloss", "inner" }) do
    local masks = row.fill[layer]._masks
    H.check(masks and #masks == 1, "the " .. layer .. " is clipped to the rounded shape")
end
H.check(row.fill.gloss and row.fill.gloss._blend == "ADD", "with the gloss added over it")
H.check(row.fill.edge and row.fill.edge._slice ~= nil, "and a sliced edge")
local a = row.fill:Colour()[4]
H.check(a and a > 0, "and a colour with some opacity: " .. tostring(a))

-- On the ROW, not in a child frame: a child draws above its parent's regions
-- whatever the draw layers say, and a fill in one put its gloss over the
-- class icon and washed it green.
H.eq(row.fill.bg._parent, row, "the fill belongs to the row, not to a child frame")
H.eq(row.fill.bg._drawLayer, "BACKGROUND", "and is drawn behind everything the row draws")
H.eq(row.icon._drawLayer, "ARTWORK", "while the class icon is in front of it")

-- Reused, never rebuilt. The client has no way to destroy a frame, so a bar
-- made on every refresh would leak one per row per tick, for the session.
local firstFill = row.fill
ui:ApplyRowVisuals(row, { nUnknown = 0, nTotal = 3, nMiss = 0, allHave = true,
                          minR = 600, minDur = 3600 })
H.check(row.fill == firstFill, "the fill is kept, not built again on the next refresh")

-- The four states still differ, which is the row's entire meaning.
local seen = {}
for _, st in ipairs({
    { nUnknown = 3, nTotal = 3, nMiss = 0, allHave = false, minR = 0, minDur = 3600 },
    { nUnknown = 0, nTotal = 3, nMiss = 0, allHave = true, minR = 600, minDur = 3600 },
    { nUnknown = 0, nTotal = 3, nMiss = 3, allHave = false, minR = 0, minDur = 3600 },
    { nUnknown = 0, nTotal = 3, nMiss = 1, allHave = false, minR = 300, minDur = 3600 },
}) do
    ui:ApplyRowVisuals(row, st)
    local c = row.fill:Colour()
    local key = string.format("%.2f/%.2f/%.2f", c[1], c[2], c[3])
    H.check(not seen[key], "state colour is distinct: " .. key)
    seen[key] = true
end

-- A WINDOW built by an older copy has no glass either, and Init() returns
-- early because the frames already exist - so without this it would keep the
-- dialog backdrop for the whole session while its rows turned to glass.
setup()
ui:Update()
-- Shaped as r16 left it: a dialog backdrop and no glass.
ui.main.glass = nil
ui.pop.glass = nil
ui.main:SetBackdrop({ bgFile = "Interface\DialogFrame\UI-DialogBox-Background" })
ui.pop:SetBackdrop({ bgFile = "Interface\DialogFrame\UI-DialogBox-Background" })
ui:ApplyAppearance()
H.check(type(ui.main.glass) == "table", "an older copy's window is adopted on the next refresh")
H.check(type(ui.pop.glass) == "table", "and so is its popover")
H.eq(ui.main:GetBackdrop(), nil,
    "and the dialog backdrop is removed, not left under the glass")

-- In combat it waits rather than touching a frame that parents secure
-- buttons, and picks it up afterwards.
setup()
ui:Update()
ui.main.glass = nil
WoW.inCombat = true
ui:ApplyAppearance()
H.check(type(ui.main.glass) ~= "table", "in combat the adoption waits")
WoW.inCombat = false
ui:ApplyAppearance()
H.check(type(ui.main.glass) == "table", "and happens once the fight ends")

-- The host's opacity and panel colour have to reach the tint: it IS the
-- panel now, so pointing them at the backdrop that used to be there made the
-- opacity setting do nothing at all.
setup()
ui:Update()
host.ui_config.alpha = 0.2
ui:ApplyAppearance()
local tint = ui.main.glass.tint._colorTexture
local base = lib.Glass.STYLE.tint[4]
H.near(tint[4], base * 0.2, 0.001, "the host's opacity scales the glass tint: " .. tostring(tint[4]))
host.ui_config.alpha = 1
ui:ApplyAppearance()
H.near(ui.main.glass.tint._colorTexture[4], base, 0.001,
    "and at full opacity the material looks as it was designed to")

-- Each addon's border colour is its identity - Wildly orange, Magely cyan -
-- and it is the rim that carries it now. Multiplied in, so the light stays
-- where the material puts it and only the hue changes.
setup()
ui:Update()
host.look = { mainBg = { 0.05, 0.05, 0.08 }, border = { 1.0, 0.5, 0.1, 0.85 },
              popBg = { 0.06, 0.06, 0.09 }, popBorder = { 0.1, 0.9, 0.9, 1 },
              header = { 0, 0, 0, 0.4 }, headerLine = { 1, 1, 1, 0.1 },
              footerLine = { 1, 1, 1, 0.1 }, groupText = { 0.8, 0.8, 0.8 },
              popDivider = { 1, 1, 1, 0.1 } }
ui:ApplyAppearance()
local rr, rg, rb = ui.main.glass.rim:GetVertexColor()
H.near(rr, 1.0, 0.001, "the window's rim takes the host's border colour")
H.near(rg, 0.5, 0.001, "every channel of it")
H.near(rb, 0.1, 0.001, "not just the first")
local pr2, pg2, pb2 = ui.pop.glass.rim:GetVertexColor()
H.near(pr2, 0.1, 0.001, "and the popover takes its own")
H.near(pg2, 0.9, 0.001, "which differs from the window's")

-- An r17 row has a fill, but the WRONG KIND: a child StatusBar, whose gloss
-- draws over the class icon. Forgetting the reference is not enough - the
-- frame stays parented to the row and keeps drawing, and this client cannot
-- destroy one. It has to be hidden.
setup()
ui:Update()
local r17Row = ui.rows[3]
local oldBar = WoW.makeFrame("r17Fill", r17Row)
oldBar:Show()
oldBar.SetStatusBarColor = function() end
r17Row.fill = oldBar
ui:ApplyRowVisuals(r17Row, { nUnknown = 0, nTotal = 2, nMiss = 0, allHave = true,
                             minR = 300, minDur = 3600 })
H.check(r17Row.fill ~= oldBar, "an r17 row's StatusBar is replaced")
H.check(r17Row.fill.SetColour ~= nil, "by a fill drawn on the row itself")
H.check(not oldBar:IsShown(), "and the old bar is hidden, not just forgotten")

-- A row built by an OLDER copy has no fill: LibStub hands these methods the
-- frames r16 created, and asking one for a bar it never had is a nil index in
-- the middle of a refresh. It is built on demand instead.
-- Shaped exactly like one r16 left behind: every widget it built, a flat
-- background texture, and no fill.
local legacyRow = ui.rows[2]
legacyRow.fill = nil
legacyRow.bg = legacyRow:CreateTexture(nil, "BACKGROUND")
legacyRow.bg:SetColorTexture(1, 0, 0, 0.5)
ui:ApplyRowVisuals(legacyRow,
    { nUnknown = 0, nTotal = 2, nMiss = 2, allHave = false, minR = 0, minDur = 3600 })
H.check(type(legacyRow.fill) == "table", "an older copy's row gets a fill when first drawn")
H.eq(legacyRow.bg._colorTexture[4], 0,
    "and its flat background is cleared, so it cannot show through the corners")

-- The box a region really occupies, or nil when it cannot be told. A region
-- given an explicit size answers for itself; one stretched between two
-- anchors on another region is that region's box less the two insets - which
-- is exactly how every mask here is built, and the only reason this check can
-- see them at all. GetWidth() would answer with the stub's stand-in and the
-- assertion below would be comparing two constants.
local function Box(r)
    if r._width and r._height then return r._width, r._height end
    local pts = r._points
    if not pts or #pts < 2 then return nil end
    -- Which corner is which, rather than which call came first: the sign of an
    -- offset means the opposite at the two ends. +x on TOPLEFT pulls the edge
    -- in; +x on BOTTOMRIGHT pushes it out. Taking absolute values made the
    -- panel's shadow - anchored OUTSIDE its host, which is the whole point of
    -- a shadow - read as 44px narrower than the window instead of 44 wider,
    -- and the assertion below failed on a region that was never wrong.
    local tl, br
    for _, p in ipairs(pts) do
        if p[1] == "TOPLEFT" then tl = p elseif p[1] == "BOTTOMRIGHT" then br = p end
    end
    if not (tl and br and tl[2] and tl[2] == br[2]) then return nil end
    local pw, ph = Box(tl[2])
    if not pw then return nil end
    return pw - (tl[4] or 0) + (br[4] or 0),
           ph + (tl[5] or 0) - (br[5] or 0)
end

------------------------------------------------------------
-- The glass layout
--
-- Sizes and positions, not looks. What these pin is the reasoning: a row
-- shorter than about twice the mask's 8px corner radius has its corners
-- squeezed flat and the fill reads as a painted rectangle again, which is
-- how the first pass at 15px looked in game.
------------------------------------------------------------

setup()
ui:Update()

local row = ui.rows[1]
H.check(row:GetHeight() >= 16,
    "a row is tall enough for the mask's corners: " .. tostring(row:GetHeight()))
local iw = select(1, Box(row.icon))
H.check(iw and iw < row:GetHeight(),
    "its icon fits inside it with room to spare: " .. tostring(iw))
H.check(row.iconEdge ~= nil and row.iconEdge._slice ~= nil,
    "and sits in a tile with the same sliced edge as the fill")
H.check(row.icon._masks and #row.icon._masks == 1,
    "rounded like everything else, rather than a square pasted on")

-- The close button is ours, not Blizzard's gold disc.
local x = ui.main.closeBtn
H.check(x ~= nil, "the window has a close button")
H.eq(x.label:GetText(), "\195\151", "drawn as a multiplication sign we place")
H.check(x:IsMouseEnabled(), "which takes the mouse")
H.check(x._ui ~= nil, "and knows the window it closes")

-- It brightens under the cursor, which is the only affordance a flat square
-- has - a Blizzard button announces itself by being gold.
H.runScript(x, "OnLeave")
local r1 = { x.label:GetTextColor() }
H.runScript(x, "OnEnter")
local r2 = { x.label:GetTextColor() }
H.check(r2[1] > r1[1], "and brightens when the cursor is on it")

-- Through the ui object, not in the handler's own body. Handlers are
-- installed once and the frames outlive an upgrade, so a closure that
-- recolours the label itself keeps doing what THIS copy decided in a window a
-- later copy is otherwise driving. Checking the colour alone cannot tell the
-- two apart - a direct closure passes that just as well.
local dispatched
ui.CloseButtonHover = function(self, btn, over) dispatched = over end
H.runScript(x, "OnEnter")
H.eq(dispatched, true, "the hover handler dispatches through the ui object")
H.runScript(x, "OnLeave")
H.eq(dispatched, false, "and so does the one that undoes it")
ui.CloseButtonHover = nil

-- Every string the window draws is the addon's own font, not a Blizzard
-- template. One string left on GameFontNormalSmall is one line in the wrong
-- typeface, which on a panel this small is the whole difference between a
-- designed window and a patched one - and it is invisible to every other
-- assertion here.
setup()
host.footer = { { itemID = 17029, usedBy = "the group Prayers" } }
ui:Update()
ui:UpdatePopover(ui.rows[1], ui.rows[1]._members, ui.rows[1]._def)

local strings = {
    ["the row timer"]        = ui.rows[1].timer,
    ["the missing count"]    = ui.rows[1].missCount,
    ["the MISS label"]       = ui.rows[1].missAll,
    ["the group separator"]  = ui.headers[1],
    ["the window title"]     = ui.main.title,
    ["the version"]          = ui.main.version,
    ["the close button"]     = ui.main.closeBtn.label,
    ["the reagent count"]    = ui.footerBtns[1].countTxt,
    ["the popover title"]    = ui.pop.hdrTxt,
    ["a popover name"]       = ui.popRows[1].nameTxt,
    ["a popover timer"]      = ui.popRows[1].timeTxt,
    ["a popover range"]      = ui.popRows[1].rangeTxt,
}
for what, fs in pairs(strings) do
    H.check(fs ~= nil, what .. " exists")
    local file, size = fs:GetFont()
    H.check(file == "Fonts\\ARIALN.TTF",
        what .. " is set in the addon's font, not left on a template: " .. tostring(file))
    H.check((size or 0) >= 11, what .. " is legible at arm's length: " .. tostring(size))
    local _, sy = fs:GetShadowOffset()
    H.check(sy ~= 0,
        what .. " carries a shadow, because the panel behind it is see-through")
end

-- The two icons outside the rows get the same tile, or they are the only
-- square corners left on the window.
H.check(ui.main.specIcon._masks and #ui.main.specIcon._masks == 1,
    "the header icon is rounded too")
H.check(ui.main.specEdge ~= nil and ui.main.specEdge._slice ~= nil,
    "with the sliced edge")
H.check(ui.pop.hdrIcon._masks and #ui.pop.hdrIcon._masks == 1,
    "and so is the popover's")
H.check(ui.footerBtns[1].icon._masks and #ui.footerBtns[1].icon._masks == 1,
    "and the reagent's")

------------------------------------------------------------
-- No texture is both masked and cropped
--
-- This client applies a mask in the texture's UNTRANSFORMED space, so a
-- texture that is masked AND carries a SetTexCoord shows a fraction of its
-- art in one corner of the shape. Nothing throws and nothing here failed - it
-- just drew wrong, which is exactly how it reached the game: r19 cropped the
-- client's baked icon border with SetTexCoord and masked the same texture,
-- and every icon on the window came out a sliver. The crop is the mask's
-- inset now. Stated as a rule over every region the window builds rather than
-- as a check on the icons, because the next texture to want both will not be
-- an icon.
------------------------------------------------------------

setup()
host.footer = { { itemID = 17029, usedBy = "the group Prayers" } }
ui:Update()
ui:UpdatePopover(ui.rows[1], ui.rows[1]._members, ui.rows[1]._def)

local walked, both, early = 0, {}, {}
local sliced, crushed = 0, {}

local function walk(frame, name, depth)
    if depth > 4 or type(frame) ~= "table" then return end
    for _, r in ipairs(frame._regions or {}) do
        walked = walked + 1
        if r._masks and #r._masks > 0 and r._texCoord then
            both[#both + 1] = name
        end
        -- A mask built before the texture it clips was placed has no
        -- rectangle, and never gets one. See the stub's SetPoint.
        if r._isMask and r._anchoredBeforePlaced then
            early[#early + 1] = name
        end
        -- A 9-slice draws its corners at native size and stretches what is
        -- between them. Margins that meet or cross leave no centre and no
        -- edge strips, and this client draws a fragment in one corner rather
        -- than nothing - which is how it reached the game three times.
        local sl, w, h = r._slice, Box(r)
        if sl and w and h then
            sliced = sliced + 1
            if (sl[1] + sl[3]) >= w or (sl[2] + sl[4]) >= h then
                crushed[#crushed + 1] = name .. " (" .. w .. "x" .. h
                    .. " with margins " .. sl[1] .. "/" .. sl[2] .. ")"
            end
        end
        walk(r, name, depth + 1)
    end
    for _, child in ipairs(frame._children or {}) do walk(child, name, depth + 1) end
end
walk(ui.main, "the window", 0)
walk(ui.pop, "the popover", 0)
H.check(walked > 20, "the walk found the window's regions: " .. walked)
H.eq(#both, 0,
    "no region is masked and cropped at once, which this client draws wrong: "
    .. (both[1] or "none"))
H.eq(#early, 0,
    "and no mask was anchored to a texture that had no position yet, which "
    .. "leaves it with no rectangle at all: " .. (early[1] or "none"))
H.check(sliced >= 8, "the walk found the sliced textures: " .. sliced)

-- A small mask must not be sliced.
--
-- Measured in game, not reasoned about: four explanations were deployed as
-- fixes and none of them was it, so the window's five icon tiles were set to
-- four different arrangements at once and one screenshot answered. No mask
-- drew a whole square icon. An unsliced mask drew a whole rounded one. Both
-- SLICED cells drew a fragment in the top-left corner and nothing else, and
-- differed from the working cell only in being sliced.
--
-- It is NOT about being short. The same asset sliced is right on a row's
-- fill at 123x26, and in GlassUnitFrames on power bars 300x12 and 330x7.
-- Every case that fails is small in BOTH directions - 16, 18, 20 and 22
-- square - so what this pins is "small in both", not a bound on either axis
-- alone. Which axis actually decides has not been measured, and the honest
-- shape of that is a rule that only fires when neither side is large.
local MASK_ASSET_PX = 32
local slicedSmall = {}
local function checkMasks(frame, name, depth)
    if depth > 4 or type(frame) ~= "table" then return end
    for _, r in ipairs(frame._regions or {}) do
        if r._isMask and r._slice then
            local w, h = Box(r)
            if w and h and math.max(w, h) < MASK_ASSET_PX then
                slicedSmall[#slicedSmall + 1] = name .. " (" .. w .. "x" .. h .. ")"
            end
        end
        checkMasks(r, name, depth + 1)
    end
    for _, c in ipairs(frame._children or {}) do checkMasks(c, name, depth + 1) end
end
checkMasks(ui.main, "the window", 0)
checkMasks(ui.pop, "the popover", 0)
H.eq(#slicedSmall, 0,
    "no mask small in BOTH directions is sliced, which this client renders as "
    .. "a fragment in one corner: " .. (slicedSmall[1] or "none"))
H.eq(#crushed, 0,
    "and every one has room between its margins for a middle: " .. (crushed[1] or "none"))

-- Tooltips clear the window instead of landing on it. ANCHOR_RIGHT measures
-- from the ROW, which is inset from the panel edge and inset again from the
-- glass shadow around it, so with no offset the tooltip covers the thing it
-- is describing - which is what the game showed.
WoW.clearTooltip()
H.runScript(ui.rows[1], "OnEnter")
H.check(GameTooltip._anchor == "ANCHOR_RIGHT" or GameTooltip._anchor == "ANCHOR_LEFT",
    "a row's tooltip sits beside it: " .. tostring(GameTooltip._anchor))
local off = GameTooltip._anchorOffset
H.check(off and math.abs(off[1]) >= 10,
    "and clear of the panel rather than on it: " .. tostring(off and off[1]))
H.check(off and ((GameTooltip._anchor == "ANCHOR_RIGHT") == (off[1] > 0)),
    "pushed away from the window, not further over it")

WoW.clearTooltip()
H.runScript(ui.footerBtns[1], "OnEnter")
local foff = GameTooltip._anchorOffset
H.check(foff and foff[1] >= 10,
    "the reagent tooltip clears it too: " .. tostring(foff and foff[1]))

-- And it is drawn at the window's size, not the default UI's. GameTooltip is
-- SHARED, so what matters as much as the scale is that it is given back:
-- leaving it at 0.8 shrinks every other addon's tooltips for the rest of the
-- session, and nothing in this addon would ever show it.
H.near(GameTooltip:GetScale(), 0.8, 0.001,
    "the tooltip is drawn at the window's size while we own it")
H.runScript(ui.footerBtns[1], "OnLeave")
H.near(GameTooltip:GetScale(), 1.0, 0.001,
    "and handed back at its old size, because every addon shares it")

-- The header is glass too, not an opaque band with square corners sitting on
-- a translucent panel - which is the one piece r19 left flat.
local hdr = ui.main.hdr
H.check(hdr ~= nil and hdr.gloss ~= nil, "the header has the material's gloss")
H.check(hdr.mask == nil,
    "and is NOT masked: the band is a region of the window, so a mask would "
    .. "have to anchor to a sibling texture, which this client draws wrong")
local band = ui.main.hdrBg._colorTexture
H.check(band and band[4] < 0.5,
    "and lets the panel through rather than painting over it: " .. tostring(band and band[4]))

-- The host still chooses the hue. Wildly's orange header and Magely's
-- per-spec colours go through this, and the material only decides how solid
-- it is.
local before = ui.main.hdrBg._colorTexture[1]
host.look = { header = { 0.9, 0.4, 0.1, 1 } }
ui:ApplyAppearance()
H.check(ui.main.hdrBg._colorTexture[1] > before,
    "a host's header colour still reaches the band")
H.check(ui.main.hdrBg._colorTexture[4] < 1,
    "with the material deciding how solid it is, not the host")

------------------------------------------------------------
-- What a refresh costs at raid scale (#6)
--
-- The measurement that opened the issue: a 40-man raid where everybody
-- carries 21 auras, three buffs tracked, a refresh twice a second. Each
-- member's auras were walked once PER BUFF to confirm three absences.
--
-- This asserts the shape of the cost, not a number: reads should grow with
-- the roster, not with the roster times the buff list. It runs the real
-- RefreshTimers, so it also catches a pass that is opened and then not
-- reached by the reads.
------------------------------------------------------------

WoW.reset()
H.TeachSpells({ "FORT_SINGLE", "SPIRIT_SINGLE", "SHADOW_SINGLE" })
WoW.inRaid = true
WoW.groupMembers = 40
for i = 1, 40 do
    local nm = "Raider" .. i .. " Sur"
    WoW.raidRoster[i] = { name = nm, subgroup = math.ceil(i / 5) }
    WoW.SetUnit("raid" .. i, { name = nm, guid = "R" .. i, class = "PRIEST" })
    -- Everyone is carrying a load of somebody else's buffs and none of ours,
    -- which is the expensive case: an absence is what costs a walk.
    for a = 1, 21 do WoW.SetAura("raid" .. i, "Filler" .. a, 600, 300) end
end
local rh = H.PriestUI()
rh.engine:RefreshSpells()
-- The by-name lookup only resolves spells the player knows, so a walk is the
-- ordinary path, not a corner: see API.ReadBuff.
WoW.byNameBlind = true
rh.ui:Update()

WoW.auraReads.byIndex = 0
rh.ui:RefreshTimers()
local pooled = WoW.auraReads.byIndex

-- The same refresh with the pass taken away, which is what this used to be.
local realBegin = rh.engine.BeginAuraPass
rh.engine.BeginAuraPass = function() end
WoW.auraReads.byIndex = 0
rh.ui:RefreshTimers()
local perBuff = WoW.auraReads.byIndex
rh.engine.BeginAuraPass = realBegin

local defs = #rh.defs
H.check(defs >= 3, "three buffs are being tracked, or this measures nothing")
H.check(perBuff > pooled * 2,
    "a refresh walks each member once, not once per buff: "
    .. pooled .. " reads against " .. perBuff)

-- And the window says exactly the same thing either way.
rh.engine:BeginAuraPass()
local before = {}
for _, r in ipairs(rh.ui.rows) do
    if r._active then
        local st = rh.engine:GroupStat(r._members, r._def)
        before[#before + 1] = r._def.id .. ":" .. st.nMiss .. "/" .. st.nTotal
    end
end
rh.engine:EndAuraPass()
local after = {}
for _, r in ipairs(rh.ui.rows) do
    if r._active then
        local st = rh.engine:GroupStat(r._members, r._def)
        after[#after + 1] = r._def.id .. ":" .. st.nMiss .. "/" .. st.nTotal
    end
end
H.check(#before > 0, "there are rows to compare")
H.eq(table.concat(after, " "), table.concat(before, " "),
    "and every row counts the same members missing with the pass as without")
WoW.byNameBlind = false

H.done("test_ui_window")
